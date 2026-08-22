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

        public init(
            model: ModelSpec, cwd: String, systemPrompt: String,
            maxIterations: Int = 40, maxTokens: Int? = nil, reasoningEffort: String? = nil
        ) {
            self.model = model
            self.cwd = cwd
            self.systemPrompt = systemPrompt
            self.maxIterations = maxIterations
            self.maxTokens = maxTokens
            self.reasoningEffort = reasoningEffort
        }
    }

    public enum Event: Sendable {
        case started(session: String)
        case textDelta(String)
        case thinkingDelta(String)
        case toolStarted(id: String, name: String, arguments: JSONValue)
        case toolFinished(id: String, name: String, output: String, isError: Bool)
        case turnFinished(usage: Usage?, stopReason: String?)
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

    public func cancel() {
        cancelled = true
    }

    /// The conversation so far, for a caller that wants to fork or inspect it.
    public var conversation: [ChatMessage] { messages }

    // MARK: The tool surface

    /// One tool, deliberately.
    ///
    /// The measured reason: across 5,574 real cells the agent used this environment as glue
    /// over `git`, `grep` and the filesystem — `subprocess` was the top import by 4x and two
    /// cells in total touched pandas. A menu of file and search tools would be a menu of
    /// things `sh()` already does, at the cost of a bigger schema on every request.
    public static func tools(cwd: String) -> [ChatTool] {
        [ChatTool(
            name: "python",
            description: """
                Run Python in a persistent interpreter. Variables, imports and open handles \
                survive between calls, so build up state instead of repeating work.

                Available without importing anything:
                  sh(command)  – run a shell command. The working directory and environment \
                persist across calls, so `sh('cd subdir')` then `sh('pwd')` does what you \
                expect. Returns {'stdout', 'stderr', 'status'}.
                  cwd()        – the current working directory.

                The value of a trailing expression is echoed back, so ending a cell with a \
                bare name shows it. Starting directory: \(cwd)
                """,
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
            if let usage = turn.usage { totalUsage += usage }
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
            tools: Self.tools(cwd: config.cwd),
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

    private func execute(
        _ call: (id: String, name: String, arguments: JSONValue)
    ) async -> (String, Bool) {
        guard call.name == "python" else {
            // Answered rather than thrown: a model inventing a tool name is a thing to tell
            // it about, not a reason to end the run.
            return ("No tool named \(call.name). The only tool is `python`.", true)
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
