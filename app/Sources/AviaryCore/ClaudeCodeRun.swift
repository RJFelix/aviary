import Foundation

/// One driven Claude Code session, recorded as an Aviary session.
///
/// The recording is the point. Claude Code keeps its own history — that is the constraint the
/// whole design bends around — but Aviary's transcript, session catalogue, usage analytics and
/// search all read one format, so a driven run writes into that format as it goes. The result
/// is that a Claude Code session and an in-house session are the same kind of object
/// everywhere downstream, and neither the transcript view nor the usage rollup needs to know
/// which engine produced it.
///
/// What is *not* claimed: this is not Aviary's loop. Claude Code decides when to call the tool
/// and when to stop, and the transcript is a faithful record of its decisions rather than of
/// ours.
public actor ClaudeCodeRun {

    public struct Settings: Sendable {
        public var home: AgentHome
        public var cwd: String
        /// `sonnet`, `opus`, `haiku`, or a full model id.
        public var model: String
        public var systemPrompt: String
        public var effort: String?
        /// Path to the Aviary binary, which is re-launched as the MCP courier.
        public var bridgeExecutable: String
        /// A Claude Code session id to continue, rather than an Aviary session id.
        public var resumeClaudeSession: String?
        /// An Aviary session to append to. Independent of the above: the Aviary transcript and
        /// the Claude Code history are two different records of the same conversation, and
        /// resuming one without the other is a real (if lopsided) thing to want.
        public var resumeAviarySession: String?
        /// Preallocated identity bundle, resolved before Claude Code or the runtime starts.
        public var identity: SessionWorkIdentity?

        public init(
            home: AgentHome, cwd: String, model: String, systemPrompt: String,
            effort: String? = nil, bridgeExecutable: String,
            resumeClaudeSession: String? = nil, resumeAviarySession: String? = nil,
            identity: SessionWorkIdentity? = nil
        ) {
            self.home = home
            self.cwd = cwd
            self.model = model
            self.systemPrompt = systemPrompt
            self.effort = effort
            self.bridgeExecutable = bridgeExecutable
            self.resumeClaudeSession = resumeClaudeSession
            self.resumeAviarySession = resumeAviarySession
            self.identity = identity
        }
    }

    public enum Event: Sendable {
        case started(aviarySession: String)
        /// Claude Code's own session id, needed to resume it later.
        case claudeSession(String)
        /// A user input crossed both the journal and Claude stdin boundaries.
        case inputCommitted(id: String)
        case textDelta(String)
        case thinkingDelta(String)
        case toolStarted(name: String)
        case toolFinished(name: String, isError: Bool)
        /// One assistant message is durable. A driven turn may contain several of these,
        /// separated by tool calls, before the overall turn finishes.
        case messageCommitted(id: String)
        case turnFinished
        case rateLimit(ClaudeCode.Frame.RateLimit)
        /// Something worth a banner: a leaked API key, a missing tool, a denied call.
        case warning(String)
        case failed(String)
        case finished
    }

    public enum RunError: LocalizedError {
        case noBinary
        case launchFailed(String)
        case deliveryFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noBinary:
                return "No `claude` binary was found. Install Claude Code, or sign in with it "
                    + "once, and Aviary will find it."
            case .launchFailed(let detail):
                return "Could not start Claude Code: \(detail)"
            case .deliveryFailed(let detail):
                return "Could not deliver input to Claude Code: \(detail)"
            }
        }
    }

    private let settings: Settings
    private let bridge: KernelBridge
    private let writer: SessionWriter
    private var observer: (@Sendable (Event) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    /// One consumer for stdout. Spawning a Task per line lets later frames enter the actor
    /// before earlier ones, which can put tool results above calls or finish a turn early.
    private var outputPump: Task<Void, Never>?
    /// Claude Code's session id, learned from `system/init` and needed to resume.
    public private(set) var claudeSessionID: String?
    public private(set) var totalUsage = Usage()
    /// Turns Claude Code says it took, which is its own count and not derived from frames.
    public private(set) var turnsReported = 0
    /// Requests Claude Code retried. Not surfaced as warnings: a retry that then succeeded is
    /// normal, and one banner per retry is how the authentication warning goes unread.
    public private(set) var retries = 0
    public private(set) var lastRateLimit: ClaudeCode.Frame.RateLimit?
    public private(set) var isFinished = false
    /// Frame types this version does not model, counted so a protocol change is visible as a
    /// number rather than as silence.
    public private(set) var unmodelledFrames: [String: Int] = [:]
    /// The first terminal outcome recorded for this run. Keeping this guard in the run actor
    /// prevents End-after-failure from rewriting a truthful failure as cancellation.
    private var recordedOutcome: TranscriptOutcome.State?
    /// True after stdin delivery and until Claude Code reports a result for that turn. Process
    /// status zero is not success when the protocol ended before that acknowledgement.
    private var pendingTurnResult = false
    private var journalFailureDetail: String?

    /// Blocks of the assistant message currently being assembled.
    ///
    /// Claude Code emits one `assistant` frame per completed content block, all sharing a
    /// message id, so a turn is only whole once the id changes or the run reports a result.
    /// Writing each frame as its own transcript entry would split one reply into three.
    private var openMessageID: String?
    private var openBlocks: [ClaudeCode.Frame.Block] = []
    private var openUsage: Usage?
    private var openStopReason: String?
    /// Tool calls written but not yet resolved, so a result can be matched to its name.
    private var pendingToolNames: [String: String] = [:]

    // Nonisolated because `SessionWriter` publishes both as `nonisolated let`: a caller
    // wiring up the kernel needs the session file before the run has started, and awaiting the
    // actor for a value that was fixed at init would only invite a deadlock.
    public nonisolated var sessionID: String { writer.sessionID }
    public nonisolated var fileURL: URL { writer.fileURL }
    /// The launch boundary can reserve this exact writer before runtime/process setup.
    public nonisolated var sessionWriter: SessionWriter { writer }

    public init(
        settings: Settings, bridge: KernelBridge, writer suppliedWriter: SessionWriter? = nil
    ) throws {
        self.settings = settings
        self.bridge = bridge
        let identity = settings.identity
            ?? settings.resumeAviarySession.flatMap {
                SessionWriter.recoverIdentity(home: settings.home, sessionID: $0)
            }
            ?? SessionWorkIdentity.allocate(
                workHostID: settings.home.workHostID,
                sessionID: settings.resumeAviarySession ?? SessionWriter.newSessionID())
        // Recorded as the model that answered, with `claude-code` as the provider. Naming the
        // provider after the *client* rather than after Anthropic is deliberate: which client
        // Anthropic sees is exactly what decides whether a run draws on the plan or on metered
        // credit, so it is the distinction worth carrying into the ledger.
        let spec = Self.modelSpec(for: settings.model)
        if let suppliedWriter {
            self.writer = suppliedWriter
        } else if let resume = settings.resumeAviarySession {
            self.writer = try SessionWriter(
                home: settings.home, resuming: resume, cwd: settings.cwd, model: spec,
                identity: identity)
        } else {
            self.writer = try SessionWriter(
                home: settings.home, cwd: settings.cwd, model: spec,
                identity: identity)
        }
    }

    /// Record a machinery note in this run's transcript.
    ///
    /// For the kernel, which produces things worth recording — an artifact written — and must
    /// not open a second handle onto a file that has exactly one writer.
    @discardableResult
    public func note(_ text: String, customType: String) async -> Bool {
        do {
            try await writer.appendNote(text, customType: customType)
            return true
        } catch {
            await journalFailure(error.localizedDescription)
            return false
        }
    }

    public func writerIsHealthy() async -> Bool {
        if case .healthy = await writer.writerHealth { return true }
        return false
    }

    /// Fail closed after a journal error: the driven process must not continue making model,
    /// Python, MCP, or stdin effects against a transcript that can no longer record them.
    public func journalFailure(_ detail: String) async {
        guard journalFailureDetail == nil else { return }
        journalFailureDetail = detail
        if process?.isRunning == true {
            process?.terminate()
        } else if process == nil {
            isFinished = true
        }
    }

    private func requireWriter(_ effect: String) async -> Bool {
        guard journalFailureDetail == nil else { return false }
        if case .healthy = await writer.writerHealth { return true }
        await journalFailure("The session journal became unavailable before \(effect).")
        return false
    }

    /// Persist the run's terminal state before its journal closes. This is public so the driver
    /// can classify a failed input crossing, while the actor keeps duplicate outcome writes
    /// from racing result, exit, and teardown callbacks.
    @discardableResult
    public func recordOutcome(
        _ state: TranscriptOutcome.State, detail: String? = nil
    ) async -> String? {
        guard recordedOutcome == nil else { return nil }
        recordedOutcome = state
        return try? await writer.appendOutcome(
            state: state, detail: detail.map(Self.bounded))
    }

    public func observe(_ observer: (@Sendable (Event) -> Void)?) {
        self.observer = observer
    }

    // MARK: Running

    /// Start Claude Code and send the first prompt.
    public func start(prompt: String) async throws {
        guard await requireWriter("Claude Code startup") else {
            throw RunError.launchFailed(journalFailureDetail ?? "the session journal is unavailable")
        }
        guard let binary = await ClaudeCode.locate() else {
            let error = RunError.noBinary
            await recordOutcome(.failed, detail: error.localizedDescription)
            throw error
        }
        let endpoint: KernelBridge.Endpoint
        do {
            endpoint = try await bridge.start()
        } catch {
            await recordOutcome(.failed, detail: error.localizedDescription)
            throw error
        }

        let invocation = ClaudeCode.Invocation(
            model: settings.model,
            cwd: settings.cwd,
            systemPrompt: settings.systemPrompt,
            mcpServers: .object([
                "aviary": .object([
                    "command": .string(settings.bridgeExecutable),
                    "args": .array([.string("--mcp-bridge")]),
                    "env": .object(endpoint.environment.mapValues { JSONValue.string($0) }),
                ]),
            ]),
            allowedTools: Self.toolNames,
            effort: settings.effort,
            resume: settings.resumeClaudeSession)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: settings.cwd)
        // The courier inherits this environment, which is why the bridge endpoint is injected
        // per-server in `--mcp-config` rather than set here: a token in the environment of the
        // `claude` process would also reach every other MCP server it happens to start.
        process.environment = ClaudeCode.scrubbedEnvironment()

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let framer = LineFramer()
        let (outputLines, outputContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded)
        outputPump = Task { [weak self] in
            for await line in outputLines {
                guard let self else { return }
                await self.ingest(line: line)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                outputContinuation.finish()
                return
            }
            for line in framer.feed(chunk) {
                outputContinuation.yield(line)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            if let text = String(data: chunk, encoding: .utf8) {
                Task { await self?.noteStderr(text) }
            }
        }
        process.terminationHandler = { [weak self] p in
            Task { await self?.handleExit(status: p.terminationStatus) }
        }

        guard await requireWriter("Claude Code process launch") else {
            await bridge.stop()
            throw RunError.launchFailed(journalFailureDetail ?? "the session journal is unavailable")
        }
        do { try process.run() } catch {
            outputContinuation.finish()
            outputPump?.cancel()
            outputPump = nil
            await recordOutcome(.failed, detail: error.localizedDescription)
            throw RunError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.stdin = inPipe.fileHandleForWriting

        emit(.started(aviarySession: writer.sessionID))
        guard await note(
            "Driven by Claude Code. The loop, the history and the stopping decision are Claude "
                + "Code's; the kernel is Aviary's, reached over an MCP bridge.",
            customType: "aviary.claude-code") else {
            throw RunError.launchFailed(
                journalFailureDetail ?? "the session journal is unavailable")
        }
        if !prompt.isEmpty {
            let delivery = await send(prompt)
            guard delivery.isDelivered else {
                if case .notDelivered = delivery {
                    await recordOutcome(
                        .failed, detail: delivery.detail ?? "input delivery was not confirmed")
                }
                throw RunError.deliveryFailed(delivery.detail ?? "input delivery was not confirmed")
            }
        }
    }

    /// Queue another prompt in the same session.
    ///
    /// Claude Code's `--input-format stream-json` accepts a stream of user messages, and each
    /// one starts a fresh turn against the history it already holds. Only `user` lines are
    /// honoured — an `assistant` line is silently discarded, which is the finding that makes
    /// this a driven session rather than a transport.
    public func send(_ prompt: String) async -> SessionCommandDelivery {
        guard !prompt.isEmpty else {
            return .notDelivered(reason: "the input is empty")
        }
        // A user message starts a new parser projection and therefore a new terminal-outcome
        // window. Keep the guard per turn: a prior completed turn must not suppress the next
        // turn's failure or cancellation marker.
        recordedOutcome = nil
        guard await requireWriter("Claude Code stdin") else {
            return .notDelivered(reason: journalFailureDetail ?? "the session journal is unavailable")
        }
        guard let stdin, process?.isRunning == true else {
            await recordOutcome(.failed, detail: "the driven process is not accepting input")
            return .notDelivered(reason: "the driven process is not accepting input")
        }
        let inputID: String
        do {
            inputID = try await writer.appendUser(prompt)
        } catch {
            let detail = "the journal rejected the user message: \(error.localizedDescription)"
            await recordOutcome(.failed, detail: detail)
            return .notDelivered(
                reason: detail)
        }
        let line = JSONValue.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("text"), "text": .string(prompt),
                ])]),
            ]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded: Data
        do {
            encoded = try encoder.encode(line)
        } catch {
            let detail =
                "the stream-json input could not be encoded: \(error.localizedDescription)"
            await recordOutcome(.failed, detail: detail)
            return .notDelivered(
                reason: detail)
        }
        var data = encoded
        data.append(UInt8(ascii: "\n"))
        do {
            try stdin.write(contentsOf: data)
        } catch {
            _ = await note(
                "Aviary could not confirm whether Claude Code received the preceding user "
                    + "message because its stdin write failed: "
                    + error.localizedDescription,
                customType: "aviary.claude-code-delivery-failure")
            return .indeterminate(
                reason: "stdin write failed; delivery is unknown: \(error.localizedDescription)")
        }
        pendingTurnResult = true
        emit(.inputCommitted(id: inputID))
        return .delivered(referenceID: inputID)
    }

    /// Say that no more prompts are coming.
    ///
    /// Claude Code with `--input-format stream-json` waits on stdin indefinitely, which is
    /// right for a session that stays open and wrong for a one-shot: closing stdin is how it
    /// learns the conversation is over, finishes the turn in flight, and exits. A driven run
    /// that is never told this simply never ends.
    public func finishInput() {
        try? stdin?.close()
        stdin = nil
    }

    public func stop(cancelActiveTurn: Bool = false) async {
        // Order matters, and so does verifying. Closing stdin is the polite ending — Claude
        // Code finishes the turn in flight and exits, leaving no unresolved tool call in its
        // own history. But SIGTERM is a request, not an outcome: a `claude` that does not
        // take it becomes an orphan (reparented to launchd) still holding its MCP courier,
        // and it goes on calling a session that is being dismantled underneath it. One was
        // found alive thirteen minutes after its Aviary had exited.
        //
        // So the model process is ended *first and for certain*, and only then is anything it
        // might call taken away. Tearing the kernel down while the caller is still alive is
        // what produced twenty-six consecutive "the runtime host is not running" results in a
        // real session.
        if cancelActiveTurn && !isFinished {
            await recordOutcome(.cancelled, detail: "Claude Code run ended by request")
        }
        isFinished = true
        try? stdin?.close()
        stdin = nil

        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                // The same escalation `RuntimeHost.stop` already does for its own child.
                kill(process.processIdentifier, SIGKILL)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        self.process = nil

        await bridge.stop()
        do {
            try await writer.closeChecked()
        } catch {
            await journalFailure("The session journal close was not confirmed: \(error.localizedDescription)")
        }
    }

    // MARK: Frames

    /// Every raw frame, appended to the file named by `AVIARY_CLAUDE_RAW`.
    ///
    /// Kept because the shape of this stream is the one thing here that cannot be reasoned
    /// about from documentation — where the *true* token counts live took a capture to settle,
    /// having been wrong twice from inference.
    private nonisolated func recordRaw(_ line: Data) {
        guard let path = ProcessInfo.processInfo.environment["AVIARY_CLAUDE_RAW"] else { return }
        guard let handle = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }() else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        var data = line
        data.append(UInt8(ascii: "\n"))
        try? handle.write(contentsOf: data)
    }

    private func ingest(line: Data) async {
        recordRaw(line)
        guard let frame = ClaudeCode.decode(line: line) else { return }
        switch frame {
        case .initialized(let info):
            claudeSessionID = info.sessionID
            emit(.claudeSession(info.sessionID))
            if let complaint = info.complaint(expecting: Self.toolNames) {
                emit(.warning(complaint))
                _ = await note(complaint, customType: "aviary.claude-code")
            }

        case .textDelta(let text):
            emit(.textDelta(text))

        case .thinkingDelta(let text):
            emit(.thinkingDelta(text))

        case .toolArgumentsDelta:
            // Available, and unused: the completed `assistant` frame carries the whole
            // argument object a moment later, and a half-parsed one has nothing to show.
            break

        case .assistantBlock(let messageID, let block, let stopReason):
            if let open = openMessageID, open != messageID { await flushTurn() }
            openMessageID = messageID
            openBlocks.append(block)
            if let stopReason { openStopReason = stopReason }
            if case .toolCall(_, let name, _) = block {
                emit(.toolStarted(name: Self.display(tool: name)))
            }

        case .messageDone(let usage, let stopReason):
            // The message is complete, so the turn is written here rather than waiting for the
            // next message id. That ordering is what puts a tool call above its result in the
            // transcript instead of below it.
            if let usage { openUsage = usage }
            if let stopReason { openStopReason = stopReason }
            await flushTurn()

        case .toolResult(let id, let text, let isError):
            // The call itself is recorded when its turn flushes, so the result must come after
            // it — otherwise the transcript shows an answer above its question.
            await flushTurn()
            let name = pendingToolNames.removeValue(forKey: id) ?? "python"
            do {
                try await writer.appendToolResult(
                    id: id, name: name, text: text, isError: isError)
            } catch {
                await journalFailure("Could not record Claude Code's tool result: \(error.localizedDescription)")
                return
            }
            emit(.toolFinished(name: Self.display(tool: name), isError: isError))

        case .rateLimit(let limit):
            lastRateLimit = limit
            emit(.rateLimit(limit))
            if limit.usingOverage {
                // The single most important thing this session type can tell you: the plan
                // allowance is spent and the run is now costing money per token.
                let note = "This run is drawing on extra usage, not the plan allowance."
                emit(.warning(note))
                _ = await self.note(note, customType: "aviary.claude-code")
            }

        case .result(let result):
            await flushTurn()
            // `result.usage` is deliberately *not* added to the total. It re-reports the same
            // tokens as an aggregate, and the running total is summed per message so that it
            // equals the sum of the transcript's own entries — which is what the Usage screen
            // reads. Two screens disagreeing about one run is worse than either being coarse.
            turnsReported += result.turns
            if !result.permissionDenials.isEmpty {
                let note = "Claude Code tried to use "
                    + result.permissionDenials.joined(separator: ", ")
                    + ", which this run does not allow. It will have answered around the "
                    + "refusal rather than stopping."
                emit(.warning(note))
                _ = await self.note(note, customType: "aviary.claude-code")
            }
            if result.isError {
                let detail = result.apiErrorStatus ?? result.text
                let failure = detail.isEmpty ? "Claude Code reported a failure." : detail
                await recordOutcome(.failed, detail: failure)
                emit(.failed(failure))
            }
            pendingTurnResult = false
            emit(.turnFinished)

        case .retry(let category, let detail):
            // Authentication trouble is machine-detectable here rather than as a mysterious
            // stall, which is the difference between a banner and a support question.
            if category.contains("auth") || category.contains("oauth") {
                let note = "Claude Code's login is not working (\(category)). "
                    + "Run `claude /login`."
                emit(.warning(note))
                _ = await self.note(note, customType: "aviary.claude-code")
                return
            }
            // Everything else is noted in the transcript but not banner-worthy. A retry that
            // then succeeded is normal operation, and a warning per retry trains you to ignore
            // warnings — which is the state in which the auth one above goes unread.
            retries += 1
            let described = [category, detail]
                .filter { !$0.isEmpty }.joined(separator: ": ")
            _ = await note(
                "Claude Code retried a request" + (described.isEmpty ? "." : " — " + described),
                customType: "aviary.claude-code")

        case .other(let type):
            unmodelledFrames[type, default: 0] += 1
        }
    }

    /// Write the assembled assistant turn.
    private func flushTurn() async {
        guard openMessageID != nil, !openBlocks.isEmpty else { return }
        var text = "", thinking = ""
        var calls: [(id: String, name: String, arguments: JSONValue)] = []
        for block in openBlocks {
            switch block {
            case .text(let t): text += t
            case .thinking(let t): thinking += t
            case .toolCall(let id, let name, let arguments):
                // Recorded under the name Aviary offered, not the `mcp__aviary__` name Claude
                // Code addresses it by. The prefix is MCP's namespacing, not part of the tool,
                // and leaving it in would make a driven run's transcript disagree with an
                // in-house one about what the tool is called.
                calls.append((id: id, name: Self.display(tool: name), arguments: arguments))
                pendingToolNames[id] = Self.display(tool: name)
            }
        }
        do {
            let messageID = try await writer.appendAssistant(
                text: text, thinking: thinking, toolCalls: calls,
                usage: openUsage, stopReason: openStopReason)
            emit(.messageCommitted(id: messageID))
        } catch {
            let detail = "Could not record Claude Code's message: \(error.localizedDescription)"
            await recordOutcome(.failed, detail: detail)
            emit(.failed(detail))
            await journalFailure(detail)
        }
        if let usage = openUsage { totalUsage = totalUsage + usage }
        openMessageID = nil
        openBlocks = []
        openUsage = nil
        openStopReason = nil
    }

    private func noteStderr(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stderrTail.append(trimmed)
        if stderrTail.count > 40 { stderrTail.removeFirst() }
    }

    private var stderrTail: [String] = []
    public var diagnostics: String { stderrTail.joined(separator: "\n") }

    private func handleExit(status: Int32) async {
        if let outputPump { await outputPump.value }
        outputPump = nil
        await flushTurn()
        await bridge.stop()
        if !isFinished,
           let failure = Self.exitFailure(
               status: status, pendingTurnResult: pendingTurnResult,
               diagnostics: stderrTail.suffix(3).joined(separator: "\n"))
        {
            await recordOutcome(.failed, detail: failure)
            emit(.failed(failure))
        }
        pendingTurnResult = false
        isFinished = true
        do {
            try await writer.closeChecked()
        } catch {
            await journalFailure("The session journal close was not confirmed: \(error.localizedDescription)")
        }
        emit(.finished)
    }

    private func emit(_ event: Event) {
        observer?(event)
    }

    // MARK: Names

    /// Protocol-aware process-exit classification, kept independently testable. A clean
    /// process status only means the executable exited normally; it does not complete an
    /// input whose result frame never arrived.
    static func exitFailure(
        status: Int32, pendingTurnResult: Bool, diagnostics: String
    ) -> String? {
        guard status != 0 || pendingTurnResult else { return nil }
        if status == 0 {
            return "Claude Code exited before completing the active turn."
        }
        return diagnostics.isEmpty
            ? "Claude Code exited with status \(status)."
            : "Claude Code exited with status \(status): \(diagnostics)"
    }

    /// Keep provider diagnostics useful without allowing a failed response body to turn the
    /// durable outcome marker into an unbounded transcript entry.
    private static func bounded(_ text: String) -> String {
        guard text.count > 4000 else { return text }
        return String(text.prefix(4000)) + "\n\n[truncated by Aviary]"
    }

    /// The tools a driven run offers. One, deliberately: the kernel can already do anything a
    /// file-editing tool could, and every additional schema is context spent describing a
    /// capability Python already has.
    static let toolNames = ["mcp__aviary__python"]

    /// What a driven run records as its model.
    ///
    /// The provider is `claude-code` rather than `anthropic`, which is not cosmetic: which
    /// *client* Anthropic sees is what decides whether the tokens came out of the plan or out
    /// of metered credit, so it is the distinction the ledger needs to keep.
    ///
    /// No prices. A subscription run's tokens were not billed per token, and `total_cost_usd`
    /// in the stream is documented as a client-side estimate — so pricing them at list would
    /// invent spending. `sessionsWithoutPricing` already means "no rates published", which is
    /// exactly the true thing to say here.
    public static func modelSpec(for model: String) -> ModelSpec {
        let contextWindow: Int? = {
            switch model {
            case "sonnet", "claude-sonnet-5": return 1_000_000
            case "opus", "claude-opus-5": return 200_000
            case "haiku", "claude-haiku-4-5": return 200_000
            default: return nil
            }
        }()
        var json: [String: JSONValue] = [
            "id": .string(model),
            "provider": .string("claude-code"),
            "reasoning": .bool(true),
        ]
        if let contextWindow { json["contextWindow"] = .number(Double(contextWindow)) }
        return ModelSpec(rpc: .object(json))
    }

    /// Strip MCP's `mcp__<server>__` namespacing.
    static func display(tool name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? parts.dropFirst().joined(separator: "__") : name
    }
}
