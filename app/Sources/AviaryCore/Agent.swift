import Foundation

/// The agent loop, in-house.
///
/// Send the conversation and the tool schema; stream back text, thinking and tool calls;
/// execute the calls in the runtime host; append the results; go again until the model stops
/// asking for tools. That is the whole of it — the loop is small, and everything interesting
/// lives in the three things it composes: a `ChatProvider`, a `RuntimeHost`, and a
/// `SessionWriter` producing files Aviary already knows how to render.
///
/// Written as an actor with a callback rather than returning a value, because a run is watched
/// while it happens. The same events drive a live view and a test.
public actor Agent {

    // MARK: Configuration

    public struct Configuration: Sendable {
        public var model: ModelSpec
        public var cwd: String
        public var systemPrompt: String
        /// A ceiling on model round trips per prompt. Not a budget — a stop, so a tool-calling
        /// loop that never converges cannot spend indefinitely while nobody is watching.
        public var maxIterations: Int
        public var maxTokens: Int?
        public var reasoningEffort: String?
        /// Compact when the conversation passes this share of the model's context window.
        ///
        /// 0.7 rather than something closer to 1.0 because compaction itself needs headroom:
        /// summarising requires sending what is being summarised, and a run that waits until
        /// it is nearly full cannot afford the call that would save it.
        public var compactAtContextShare: Double = 0.7
        /// How deep sub-agents may nest. A ceiling rather than a budget — recursion with no
        /// floor is the one failure mode that can spend without bound while nobody watches.
        public var maxDepth: Int = 3
        public var depth: Int = 0

        public init(
            model: ModelSpec, cwd: String, systemPrompt: String,
            maxIterations: Int = 40, maxTokens: Int? = nil, reasoningEffort: String? = nil,
            compactAtContextShare: Double = 0.7, maxDepth: Int = 3, depth: Int = 0
        ) {
            self.model = model
            self.cwd = cwd
            self.systemPrompt = systemPrompt
            self.maxIterations = maxIterations
            self.maxTokens = maxTokens
            self.reasoningEffort = reasoningEffort
            self.compactAtContextShare = compactAtContextShare
            self.maxDepth = maxDepth
            self.depth = depth
        }
    }

    public enum Event: Sendable {
        case started(session: String)
        case textDelta(String)
        case thinkingDelta(String)
        case toolStarted(id: String, name: String, arguments: JSONValue)
        case toolFinished(id: String, name: String, output: String, isError: Bool)
        case turnFinished(usage: Usage?, stopReason: String?)
        case compacted(before: Int, after: Int, summary: String)
        case childStarted(id: String, name: String, prompt: String)
        case childFinished(id: String, name: String, answer: String, isError: Bool)
        /// The loop stopped. `reason` is why, in words, because "it stopped" is never enough
        /// to act on.
        case finished(reason: String)
        case failed(String)
    }

    public typealias Observer = @Sendable (Event) -> Void

    // MARK: State

    private let provider: ChatProvider
    private let host: RuntimeHost
    private let writer: SessionWriter
    private let config: Configuration
    private let hostSession: String
    private var messages: [ChatMessage] = []
    private var observer: Observer?
    private var cancelled = false

    public private(set) var totalUsage = Usage()
    /// The last input-token count the provider reported. The cheapest available measure of
    /// how full the context is, and an exact one — unlike counting characters.
    private var lastInputTokens = 0
    private var compactions = 0
    /// How a child reports back to its parent, and who to notify.
    private var spawnDelegate: SpawnDelegate?
    /// MCP servers whose tools this run may call, keyed by the namespaced tool name the model
    /// sees. Namespaced because two servers may both offer `search`, and a bare name would
    /// make that collision silent.
    private var mcpTools: [String: (client: MCPClient, tool: MCPClient.Tool)] = [:]

    public init(
        provider: ChatProvider, host: RuntimeHost, writer: SessionWriter,
        hostSession: String, config: Configuration
    ) {
        self.provider = provider
        self.host = host
        self.writer = writer
        self.hostSession = hostSession
        self.config = config
        self.messages = [.system(config.systemPrompt)]
    }

    public func observe(_ observer: Observer?) {
        self.observer = observer
    }

    /// Somebody who can run a child agent. Injected rather than built in, so a caller decides
    /// what a sub-agent costs, where it writes, and whether it is allowed at all.
    public protocol SpawnDelegate: Sendable {
        func spawn(
            prompt: String, name: String?, model: String?, depth: Int
        ) async -> (answer: String, isError: Bool, childID: String, name: String)
    }

    public func setSpawnDelegate(_ delegate: SpawnDelegate?) {
        spawnDelegate = delegate
    }

    /// Offer this run a set of MCP tools.
    public func addMCPTools(_ tools: [MCPClient.Tool], from client: MCPClient) {
        for tool in tools { mcpTools[tool.qualifiedName] = (client, tool) }
    }

    /// Serve a request from the runtime. Wire this to `RuntimeHost.onCallback`.
    ///
    /// Answers with an `error` key rather than throwing, always: the agent asked a question in
    /// code and is blocked on the reply, so a refusal it can read beats a hang it cannot.
    public func serveCallback(kind: String, payload: JSONValue) async -> JSONValue {
        switch kind {
        case "spawn":
            guard let delegate = spawnDelegate else {
                return .object(["error": .string("Sub-agents are not enabled for this run.")])
            }
            guard config.depth < config.maxDepth else {
                return .object(["error": .string(
                    "Already at the maximum sub-agent depth (\(config.maxDepth)). Do this work "
                        + "yourself rather than delegating it.")])
            }
            let prompt = payload["prompt"]?.stringValue ?? ""
            guard !prompt.isEmpty else {
                return .object(["error": .string("spawn() needs a prompt.")])
            }
            let name = payload["name"]?.stringValue
            let result = await delegate.spawn(
                prompt: prompt, name: name, model: payload["model"]?.stringValue,
                depth: config.depth + 1)
            emit(.childFinished(
                id: result.childID, name: result.name, answer: result.answer,
                isError: result.isError))
            var out: [String: JSONValue] = [
                "answer": .string(result.answer),
                "name": .string(result.name),
                "id": .string(result.childID),
            ]
            if result.isError { out["error"] = .string(result.answer) }
            return .object(out)

        case "conversation":
            // The agent reading its own history, programmatically. Useful on its own — it can
            // grep what it already tried instead of re-deriving it — and it is what lets a
            // child be handed exactly the slice of context it needs rather than all or none.
            let limit = payload["limit"]?.intValue ?? 40
            let recent = messages.suffix(max(1, limit))
            return .object(["messages": .array(recent.map { message in
                .object([
                    "role": .string(message.role.rawValue),
                    "text": .string(message.plainText),
                    "toolCalls": .array(message.toolCalls.map { .string($0.name) }),
                ])
            })])

        default:
            return .object(["error": .string("Aviary does not serve \(kind) requests.")])
        }
    }

    public func cancel() {
        cancelled = true
    }

    /// The conversation so far, for a caller that wants to fork or inspect it.
    public var conversation: [ChatMessage] { messages }

    /// The last thing the agent said. For a sub-agent this is the entire deliverable — the
    /// parent never sees the transcript — which is why the child prompt insists the final
    /// message carry the answer rather than an announcement that it finished.
    public var lastAssistantText: String {
        for message in messages.reversed() where message.role == .assistant {
            let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    // MARK: The tool surface

    /// One tool, deliberately.
    ///
    /// The measured reason: across 5,574 real cells the agent used this environment as glue
    /// over `git`, `grep` and the filesystem — `subprocess` was the top import by 4x and two
    /// cells in total touched pandas. A menu of file and search tools would be a menu of
    /// things `sh()` already does, at the cost of a bigger schema on every request.
    /// The tool schema, which must describe *everything* the runtime can do.
    ///
    /// Learned the hard way: `spawn()` was in the namespace and absent from this description,
    /// and the agent spent twenty turns grepping the codebase looking for it before giving up.
    /// A capability the model is not told about does not exist — and worse, it looks like a
    /// broken environment rather than a missing sentence.
    public static func tools(cwd: String, canSpawn: Bool = false, spawnBudget: Int = 0) -> [ChatTool] {
        var description = """
            Run Python in a persistent interpreter. Variables, imports and open handles \
            survive between calls, so build up state instead of repeating work.

            Available without importing anything:
              sh(command)  – run a shell command. The working directory and environment \
            persist across calls, so `sh('cd subdir')` then `sh('pwd')` does what you \
            expect. Returns {'stdout', 'stderr', 'status'}.
              cwd()        – the current working directory.
              conversation(limit=40) – this conversation so far, as a list of \
            {'role', 'text', 'toolCalls'}. Use it to check what you already tried instead of \
            re-deriving it.
            """
        if canSpawn {
            description += """


                  spawn(prompt, name=None) – run a sub-agent and wait for its answer. Returns \
                {'answer': str, 'name': str, 'id': str}, or a dict with an 'error' key. \
                Blocking, so several spawns in one cell run one after another; write them in \
                separate cells if you want to interleave other work. You may nest \
                \(spawnBudget) more level(s).

                A sub-agent starts with none of your context and returns only its final \
                message, so the prompt must be self-contained and must say what to report \
                back. Delegate genuinely separable work; doing it yourself is usually cheaper.
                """
        }
        description += """


            The value of a trailing expression is echoed back, so ending a cell with a bare \
            name shows it. Starting directory: \(cwd)
            """
        return [ChatTool(
            name: "python",
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("Python source to execute."),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ]))]
    }

    /// The tools this run actually offers, given its depth and whether spawning is wired up.
    private var activeTools: [ChatTool] {
        var tools = Self.tools(
            cwd: config.cwd,
            canSpawn: spawnDelegate != nil && config.depth < config.maxDepth,
            spawnBudget: max(0, config.maxDepth - config.depth))
        // MCP tools are declared individually rather than behind one dispatcher, because a
        // model picks a tool by reading its schema and a single `call_mcp(name, args)` hides
        // every schema behind a string.
        for (qualified, entry) in mcpTools.sorted(by: { $0.key < $1.key }) {
            tools.append(ChatTool(
                name: qualified,
                description: entry.tool.description.isEmpty
                    ? "Tool `\(entry.tool.name)` from the \(entry.tool.server) MCP server."
                    : entry.tool.description,
                parameters: entry.tool.schema))
        }
        return tools
    }

    // MARK: Running

    /// Send a prompt and run until the model stops calling tools.
    public func send(_ prompt: String) async {
        cancelled = false
        emit(.started(session: writer.sessionID))
        try? await writer.appendUser(prompt)
        messages.append(.user(prompt))

        var iterations = 0
        while iterations < config.maxIterations {
            if cancelled {
                try? await writer.appendNote("Stopped at your request.")
                emit(.finished(reason: "cancelled"))
                return
            }
            iterations += 1

            // Before the call, not after: compaction needs room to run, and discovering the
            // window is full at the moment of sending is discovering it too late.
            await compactIfNeeded()

            let turn: Turn
            do {
                turn = try await runTurn()
            } catch {
                let detail = error.localizedDescription
                try? await writer.appendNote("The model call failed: \(detail)")
                emit(.failed(detail))
                return
            }

            try? await writer.appendAssistant(
                text: turn.text, thinking: turn.thinking, toolCalls: turn.toolCalls,
                usage: turn.usage, stopReason: turn.stopReason)
            if let usage = turn.usage {
                totalUsage += usage
                if usage.input > 0 { lastInputTokens = usage.input + usage.cacheRead }
            }
            emit(.turnFinished(usage: turn.usage, stopReason: turn.stopReason))

            var assistantContent: [ChatContent] = []
            if !turn.text.isEmpty { assistantContent.append(.text(turn.text)) }
            for call in turn.toolCalls {
                assistantContent.append(
                    .toolCall(id: call.id, name: call.name, arguments: call.arguments))
            }
            messages.append(ChatMessage(role: .assistant, content: assistantContent))

            if turn.toolCalls.isEmpty {
                emit(.finished(reason: turn.stopReason ?? "stopped"))
                return
            }

            for call in turn.toolCalls {
                emit(.toolStarted(id: call.id, name: call.name, arguments: call.arguments))
                let (output, isError) = await execute(call)
                try? await writer.appendToolResult(
                    id: call.id, name: call.name, text: output, isError: isError)
                emit(.toolFinished(id: call.id, name: call.name, output: output, isError: isError))
                messages.append(ChatMessage(role: .tool, content: [
                    .toolResult(id: call.id, name: call.name, text: output, isError: isError),
                ]))
            }
        }

        // Hitting the ceiling is a real outcome, not a silent stop: the transcript says so,
        // because a run that quietly stopped looks identical to one that finished.
        let note = "Stopped after \(config.maxIterations) model calls without finishing. "
            + "Raise maxIterations, or narrow the task."
        try? await writer.appendNote(note)
        emit(.finished(reason: "iteration limit"))
    }

    // MARK: Compaction

    /// Summarise the middle of the conversation when it approaches the context window.
    ///
    /// Keeps the system prompt, the first user message (the task, which is what everything
    /// else is in service of) and the most recent exchanges verbatim; replaces the span
    /// between them with a summary. Nothing is lost from the *transcript* — the file keeps
    /// every entry and records a `compaction` marker — so the model forgets while the record
    /// does not, and a reader can still see what was dropped.
    private func compactIfNeeded() async {
        guard let window = config.model.contextWindow, window > 0 else { return }
        let threshold = Int(Double(window) * config.compactAtContextShare)
        guard lastInputTokens > threshold else { return }
        // Needs enough middle to be worth summarising: system + task + a few recent turns.
        guard messages.count > 8 else { return }

        let keepRecent = 4
        let head = messages.prefix(2)                       // system, first task
        let middle = messages.dropFirst(2).dropLast(keepRecent)
        let tail = messages.suffix(keepRecent)
        guard middle.count >= 2 else { return }

        let transcriptText = middle.map { message -> String in
            var line = "\(message.role.rawValue.uppercased()): \(message.plainText)"
            let calls = message.toolCalls
            if !calls.isEmpty {
                line += "\n  ran: " + calls.map { call in
                    (call.arguments["code"]?.stringValue ?? call.name)
                        .split(separator: "\n").first.map(String.init) ?? call.name
                }.joined(separator: "; ")
            }
            return line
        }.joined(separator: "\n\n")

        let ask = ChatRequest(
            model: config.model.id,
            messages: [
                .system("You compress an agent's working transcript so it can keep going. "
                    + "Write a dense factual summary: what was attempted, what was learned, "
                    + "what is established fact about this codebase, what failed and why, and "
                    + "what remains. Keep file paths, commands, identifiers and numbers "
                    + "exactly. Omit pleasantries and narration. No preamble."),
                .user("Summarise this span of work:\n\n"
                    + String(transcriptText.prefix(60_000))),
            ])

        var summary = ""
        do {
            for try await event in provider.stream(ask) {
                if case .textDelta(let t) = event { summary += t }
            }
        } catch {
            // A failed compaction must not end the run: the next model call may still fit,
            // and if it does not, the provider's own error is a clearer thing to show than a
            // summariser's.
            try? await writer.appendNote(
                "Could not compact the conversation: \(error.localizedDescription)")
            return
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let before = lastInputTokens
        messages = Array(head)
            + [ChatMessage(role: .user, content: [.text(
                "[Earlier work, compacted]\n\n" + summary)])]
            + Array(tail)
        compactions += 1
        lastInputTokens = 0
        try? await writer.appendCompaction(
            summary: summary, tokensBefore: before, droppedMessages: middle.count)
        emit(.compacted(before: before, after: messages.count, summary: summary))
    }

    // MARK: One turn

    private struct Turn {
        var text = ""
        var thinking = ""
        var toolCalls: [(id: String, name: String, arguments: JSONValue)] = []
        var usage: Usage?
        var stopReason: String?
    }

    private func runTurn() async throws -> Turn {
        let request = ChatRequest(
            model: config.model.id,
            messages: messages,
            tools: activeTools,
            maxTokens: config.maxTokens,
            reasoningEffort: config.reasoningEffort)

        var turn = Turn()
        for try await event in provider.stream(request) {
            switch event {
            case .textDelta(let t):
                turn.text += t
                emit(.textDelta(t))
            case .thinkingDelta(let t):
                turn.thinking += t
                emit(.thinkingDelta(t))
            case .toolCall(let id, let name, let arguments):
                turn.toolCalls.append((id: id, name: name, arguments: arguments))
            case .usage(let u):
                turn.usage = u
            case .done(let reason):
                turn.stopReason = reason
            }
        }
        return turn
    }

    /// Exposed for tests: dispatching a tool call is worth asserting directly, and driving a
    /// whole model round trip to reach it would test the fixture more than the dispatch.
    public func executeForTesting(
        id: String, name: String, arguments: JSONValue
    ) async -> (String, Bool) {
        await execute((id: id, name: name, arguments: arguments))
    }

    private func execute(
        _ call: (id: String, name: String, arguments: JSONValue)
    ) async -> (String, Bool) {
        if call.name != "python" {
            if let entry = mcpTools[call.name] {
                do {
                    let result = try await entry.client.callTool(
                        entry.tool.name, arguments: call.arguments)
                    return (result.text, result.isError)
                } catch {
                    return ("The \(entry.tool.server) MCP server failed: "
                        + error.localizedDescription, true)
                }
            }
            // Answered rather than thrown: a model inventing a tool name is a thing to tell
            // it about, not a reason to end the run.
            let available = (["python"] + mcpTools.keys.sorted()).joined(separator: ", ")
            return ("No tool named \(call.name). Available: \(available).", true)
        }
        guard let code = call.arguments["code"]?.stringValue, !code.isEmpty else {
            return ("The `python` tool needs a non-empty `code` argument.", true)
        }
        do {
            let result = try await host.execute(code, in: hostSession)
            return (Self.render(result), result.failed)
        } catch {
            return ("The runtime host could not run that: \(error.localizedDescription)", true)
        }
    }

    /// Turn an execution into what the model sees.
    ///
    /// Order matters: output first, then the echoed value, then the traceback last so the
    /// most actionable part is nearest the model's attention. Empty output says so explicitly,
    /// because a blank tool result reads as a broken tool.
    public static func render(_ result: RuntimeHost.ExecResult) -> String {
        var parts: [String] = []
        if !result.stdout.isEmpty { parts.append(result.stdout.trimmingTrailingNewlines()) }
        if !result.stderr.isEmpty {
            parts.append("stderr:\n" + result.stderr.trimmingTrailingNewlines())
        }
        if let value = result.value { parts.append(value) }
        if let exception = result.exception {
            parts.append(exception.trimmingTrailingNewlines())
        }
        if parts.isEmpty { return "(no output)" }
        return parts.joined(separator: "\n")
    }

    private func emit(_ event: Event) {
        observer?(event)
    }
}

extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
