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
        /// A budget and a finishing condition. Nil means the only limit is `maxIterations`,
        /// which the agent cannot see and therefore cannot plan against.
        public var goal: Goal?
        /// Prior turns to continue from, replayed by `SessionResume`. Carried in the
        /// configuration rather than set afterwards so it cannot be supplied too late — the
        /// history has to be in place before the first model call, and a `seed()` method
        /// callable at any time is a bug waiting for a refactor.
        ///
        /// Must not contain a system message; the agent builds its own from the current skills
        /// and context files, which is the point of resuming rather than replaying.
        public var resumedHistory: [ChatMessage] = []

        public init(
            model: ModelSpec, cwd: String, systemPrompt: String,
            maxIterations: Int = 40, maxTokens: Int? = nil, reasoningEffort: String? = nil,
            compactAtContextShare: Double = 0.7, maxDepth: Int = 3, depth: Int = 0,
            goal: Goal? = nil, resumedHistory: [ChatMessage] = []
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
            self.goal = goal
            self.resumedHistory = resumedHistory
        }
    }

    public enum Event: Sendable {
        case started(session: String)
        /// A queued message was taken up. Emitted so a UI can stop showing it as pending.
        case steered(String)
        case textDelta(String)
        case thinkingDelta(String)
        case toolStarted(id: String, name: String, arguments: JSONValue)
        case toolFinished(id: String, name: String, output: String, isError: Bool)
        case turnFinished(usage: Usage?, stopReason: String?)
        case compacted(before: Int, after: Int, summary: String)
        case goalExhausted(String)
        case childStarted(id: String, name: String, prompt: String)
        case childFinished(id: String, name: String, answer: String, isError: Bool)
        /// The agent put an image in front of itself.
        case imageAttached(path: String, width: Int, height: Int)
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
    /// The prompt that opened the run, kept for memory provenance.
    private var firstPrompt: String?
    /// Messages to inject before the next model call, and after the run finishes.
    ///
    /// Two queues because they answer different questions. Steering is "change course now" and
    /// lands at the next turn boundary — not mid-turn, because a tool call already in flight
    /// has to be answered before the model can be told anything. A follow-up is "and then do
    /// this", and waits for the run to settle.
    private var pendingSteering: [String] = []
    private var pendingFollowUps: [String] = []

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
    /// Images the cell asked to look at, waiting for the end of the tool call that queued them.
    private var pendingImages: [(image: AttachedImage, note: String?)] = []
    /// Where `remember` writes and `recall` reads. Absent means the run has no memory, which
    /// is a legitimate configuration rather than an error.
    private var memory: MemoryStore?
    /// Where `artifact` writes. Installed by whoever knows the agent home, which the loop does
    /// not; every real caller installs one, so an absent store means a harness in a test.
    private var artifacts: ArtifactStore?
    /// Where request payloads go, when a run is recording them. Off unless asked for: it writes
    /// the full system prompt and conversation to disk, which should never be implicit.
    private var wireLogURL: URL?
    /// Whether any hooks are loaded. Checked so a run with none pays nothing for the feature.
    private var hooksEnabled = false

    public init(
        provider: ChatProvider, host: RuntimeHost, writer: SessionWriter,
        hostSession: String, config: Configuration
    ) {
        self.provider = provider
        self.host = host
        self.writer = writer
        self.hostSession = hostSession
        self.config = config
        // A defensive filter rather than a precondition: a stale system prompt from a previous
        // run would silently override the one just built, and the failure would look like the
        // agent ignoring its own configuration.
        self.messages = [.system(config.systemPrompt)]
            + config.resumedHistory.filter { $0.role != .system }
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

    public func setMemory(_ store: MemoryStore?) {
        memory = store
    }

    public func setArtifacts(_ store: ArtifactStore?) {
        artifacts = store
    }

    /// Record every request payload, so the run can show where its input tokens went.
    public func recordPayloads(to url: URL?) {
        wireLogURL = url
    }

    public func enableHooks(_ enabled: Bool) {
        hooksEnabled = enabled
    }

    /// Serve a request from the runtime. Wire this to `RuntimeHost.onCallback`.
    ///
    /// Answers with an `error` key rather than throwing, always: the agent asked a question in
    /// code and is blocked on the reply, so a refusal it can read beats a hang it cannot.
    public func serveCallback(kind: String, payload: JSONValue) async -> JSONValue {
        switch kind {
        case "attach_image":
            guard config.model.supportsImages else {
                return .object(["error": .string(
                    "\(config.model.id) does not accept images. Describe what you need from "
                        + "the file instead, or switch the run to a vision model.")])
            }
            guard let path = payload["path"]?.stringValue, !path.isEmpty else {
                return .object(["error": .string("attach_image() needs a path.")])
            }
            do {
                let image = try AttachedImage.read(path: path)
                // Queued rather than returned: an image has to reach the model as a content
                // block in the conversation, and a tool result is text. The loop drains this
                // straight after the result that produced it, so the picture arrives with the
                // reasoning that asked for it rather than a turn later.
                pendingImages.append((image, payload["note"]?.stringValue))
                return image.summary
            } catch {
                return .object(["error": .string(error.localizedDescription)])
            }

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

        case "remember":
            guard let memory else {
                return .object(["error": .string("This run has no memory store.")])
            }
            let text = (payload["text"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .object(["error": .string("remember() needs some text.")])
            }
            let scope = MemoryScope(rawValue: payload["scope"]?.stringValue ?? "project")
                ?? .project
            var expiresAt: Date?
            if let days = payload["days"]?.intValue, days > 0 {
                expiresAt = Date().addingTimeInterval(Double(days) * 86_400)
            }
            let entry = MemoryEntry(
                id: MemoryStore.newID(), scope: scope, text: text,
                tags: (payload["tags"]?.arrayValue ?? []).compactMap { $0.stringValue },
                createdAt: Date(), updatedAt: Date(), expiresAt: expiresAt,
                sessionID: writer.sessionID,
                // Provenance, because the harness recorded none and "why does it think that?"
                // was unanswerable. The prompt that produced the belief is the answer.
                provenance: firstPrompt)
            do {
                try memory.append(entry, sessionID: writer.sessionID)
                // Recorded in the transcript too, so a reader sees the agent deciding to
                // believe something at the moment it decided.
                try? await writer.appendNote(
                    "Remembered (\(scope.rawValue)): \(text)", customType: "aviary.memory")
                return .object(["id": .string(entry.id), "scope": .string(scope.rawValue)])
            } catch {
                return .object(["error": .string(error.localizedDescription)])
            }

        case "recall":
            guard let memory else {
                return .object(["error": .string("This run has no memory store.")])
            }
            let query = payload["query"]?.stringValue ?? ""
            let all = memory.load(sessionID: writer.sessionID)
            let terms = SkillGate.terms(in: query)
            let hits = terms.isEmpty ? all : all.filter { entry in
                let haystack = SkillGate.terms(
                    in: entry.text + " " + entry.tags.joined(separator: " "))
                return !terms.intersection(haystack).isEmpty
            }
            return .object(["memories": .array(hits.prefix(20).map { entry in
                .object([
                    "id": .string(entry.id),
                    "text": .string(entry.text),
                    "scope": .string(entry.scope.rawValue),
                    "tags": .array(entry.tags.map { .string($0) }),
                ])
            })])

        case "artifact":
            guard let artifacts else {
                return .object(["error": .string(
                    "This run has nowhere to write artifacts.")])
            }
            do {
                let written = try artifacts.write(
                    text: payload["text"]?.stringValue ?? "",
                    title: payload["title"]?.stringValue,
                    format: payload["format"]?.stringValue ?? "md")
                // Recorded in the transcript as well as returned, because the return value is
                // read once by the model and the transcript is what a person opens tomorrow.
                try? await writer.appendNote(
                    written.note.text, customType: ArtifactNote.customType)
                return written.payload
            } catch {
                return .object(["error": .string(error.localizedDescription)])
            }

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

    /// Change course at the next turn boundary.
    ///
    /// Queued rather than applied immediately: a tool call in flight must be answered before
    /// the model can be told anything, and injecting a message between a call and its result
    /// produces a conversation the provider rejects.
    public func steer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSteering.append(trimmed)
    }

    /// Queue a prompt for after this run settles.
    public func queueFollowUp(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingFollowUps.append(trimmed)
    }

    public var queued: (steering: [String], followUps: [String]) {
        (pendingSteering, pendingFollowUps)
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
    /// Rendered from `Builtins`, not written here. It used to be written here *and* again in
    /// `ClaudeCodeKernel`, which is how a description drifts from the namespace it describes —
    /// and a capability the model is not told about does not exist. `spawn()` proved it: in the
    /// namespace, absent from this text, and a real run spent twenty turns grepping the
    /// codebase for it before giving up.
    public static func tools(
        cwd: String, canSpawn: Bool = false, spawnBudget: Int = 0, hasMemory: Bool = false,
        supportsImages: Bool = false
    ) -> [ChatTool] {
        let description = Builtins.description(Builtins.Context(
            cwd: cwd, hasMemory: hasMemory, canSpawn: canSpawn, spawnBudget: spawnBudget,
            supportsImages: supportsImages))
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
            spawnBudget: max(0, config.maxDepth - config.depth),
            hasMemory: memory != nil,
            supportsImages: config.model.supportsImages)
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
        if firstPrompt == nil { firstPrompt = prompt }
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

            // The budget is checked before spending more of it, and the stop is recorded —
            // an agent that ran out of allowance and one that finished must not look alike.
            if let goal = config.goal {
                let status = goal.status(spent: totalUsage.totalTokens)
                if status.isFinished, let note = goal.exhaustionNote(status) {
                    try? await writer.appendNote(note, customType: "aviary.goal")
                    emit(.goalExhausted(note))
                    emit(.finished(reason: "goal budget"))
                    return
                }
            }

            // Steering lands here, between turns, where the conversation is well-formed.
            if !pendingSteering.isEmpty {
                let messagesToInject = pendingSteering
                pendingSteering.removeAll()
                for text in messagesToInject {
                    try? await writer.appendUser(text)
                    messages.append(.user(text))
                    emit(.steered(text))
                }
            }

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
                // Nothing more to do this turn — but a queued message means the run is not
                // actually over, so continue rather than making the caller start again.
                if !pendingSteering.isEmpty { continue }
                if let next = pendingFollowUps.first {
                    pendingFollowUps.removeFirst()
                    try? await writer.appendUser(next)
                    messages.append(.user(next))
                    emit(.steered(next))
                    continue
                }
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
                await drainPendingImages()
            }
        }

        // Hitting the ceiling is a real outcome, not a silent stop: the transcript says so,
        // because a run that quietly stopped looks identical to one that finished.
        let note = "Stopped after \(config.maxIterations) model calls without finishing. "
            + "Raise maxIterations, or narrow the task."
        try? await writer.appendNote(note)
        emit(.finished(reason: "iteration limit"))
    }

    /// Move anything `attach_image` queued into the conversation.
    ///
    /// A user message rather than part of the tool result, because that is the one shape all
    /// three providers accept: Anthropic allows images inside a tool result, the OpenAI
    /// completions shape does not, and a capability that works on two routes out of three is
    /// worse than one that works everywhere.
    private func drainPendingImages() async {
        guard !pendingImages.isEmpty else { return }
        let queued = pendingImages
        pendingImages.removeAll()
        for (image, note) in queued {
            var content: [ChatContent] = []
            let caption = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            content.append(.text(caption.map { "\($0)\n\n" } ?? ""
                + "[\(image.path) — \(image.width)×\(image.height)]"))
            content.append(.image(mimeType: image.mimeType, base64: image.base64))
            messages.append(ChatMessage(role: .user, content: content))
            try? await writer.appendImage(
                mimeType: image.mimeType, base64: image.base64, path: image.path, note: caption)
            emit(.imageAttached(path: image.path, width: image.width, height: image.height))
        }
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
        var messagesForTurn = messages
        if let goal = config.goal, let first = messagesForTurn.first, first.role == .system {
            // Refreshed every turn rather than stated once: the remaining budget is the part
            // that changes, and a stale number is worse than none.
            messagesForTurn[0] = .system(
                first.plainText + "\n\n" + goal.briefing(spent: totalUsage.totalTokens))
        }
        let request = ChatRequest(
            model: config.model.id,
            messages: messagesForTurn,
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
            case .requestBody(let payload):
                record(payload)
            case .usage(let u):
                // Priced here rather than at display time, so the transcript carries dollars
                // and every screen that reads it agrees without re-deriving them.
                turn.usage = config.model.priced(u)
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
                    var text = result.text
                    if !result.images.isEmpty {
                        if config.model.supportsImages {
                            // The same queue `attach_image` uses, drained by the loop right
                            // after this tool result — so a tool that answers with a
                            // screenshot answers with the screenshot, not with a note saying
                            // one existed.
                            for image in result.images {
                                pendingImages.append((image, "From \(call.name)."))
                            }
                            let plural = result.images.count == 1 ? "image" : "images"
                            text += (text.isEmpty ? "" : "\n")
                                + "[\(result.images.count) \(plural) attached below]"
                        } else {
                            // Degraded honestly rather than dropped: this model cannot see it,
                            // and an agent that thinks it has been shown something it has not
                            // will answer confidently about a picture it never received.
                            text += (text.isEmpty ? "" : "\n")
                                + "[\(result.images.count) image(s) returned, which "
                                + "\(config.model.id) cannot read]"
                        }
                    }
                    return (text, result.isError)
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
        guard var code = call.arguments["code"]?.stringValue, !code.isEmpty else {
            return ("The `python` tool needs a non-empty `code` argument.", true)
        }
        // A hook may block this call or rewrite it. Because `ipython` is the only tool, a
        // single hook here is a complete permission system — and it can edit the code rather
        // than only veto it, which is the difference between a gate and a wall.
        if hooksEnabled,
           let decision = await host.callHook("before_tool", payload: .object([
               "name": .string(call.name),
               "code": .string(code),
               "session": .string(hostSession),
           ]))
        {
            if decision["block"]?.boolValue == true {
                let reason = decision["reason"]?.stringValue
                    ?? "A hook blocked this. Try a different approach."
                try? await writer.appendNote(
                    "A hook blocked a tool call: \(reason)", customType: "aviary.hook")
                return (reason, true)
            }
            if let rewritten = decision["code"]?.stringValue, rewritten != code {
                // Recorded, because a rewritten call that looks like the agent's own would
                // make the transcript lie about what ran.
                try? await writer.appendNote(
                    "A hook rewrote a tool call.", customType: "aviary.hook")
                code = rewritten
            }
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

    /// Append one payload to the wire log, in the shape `WireLog` already reads.
    private func record(_ payload: JSONValue) {
        guard let wireLogURL else { return }
        let record = JSONValue.object([
            "v": .number(1),
            "seq": .number(Double(recordedRequests)),
            "at": .string(SessionWriter.stamp()),
            "kind": .string("request"),
            "sessionFile": .string(writer.fileURL.path),
            "payload": payload,
        ])
        recordedRequests += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return }
        data.append(UInt8(ascii: "\n"))
        try? FileManager.default.createDirectory(
            at: wireLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: wireLogURL.path) {
            FileManager.default.createFile(atPath: wireLogURL.path, contents: nil)
        }
        // Best-effort, and silent on failure: diagnostics must never take down a run, and a
        // full disk should not produce one error per model call.
        guard let handle = try? FileHandle(forWritingTo: wireLogURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private var recordedRequests = 0

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
