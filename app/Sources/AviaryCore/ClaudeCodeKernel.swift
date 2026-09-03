import Foundation

/// Aviary's kernel, packaged as the one tool a driven Claude Code gets.
///
/// This is where the design earns its keep. Claude Code brings the loop; everything that makes
/// an Aviary session worth more than a chat window lives *inside* the interpreter — persistent
/// variables, a shell whose working directory survives, the skill modules, `remember`. None of
/// that is in the agent loop, so none of it is lost by letting somebody else drive.
public actor ClaudeCodeKernel {

    private let host: RuntimeHost
    private let hostSession: String
    private let memory: MemoryStore?
    private let sessionFile: URL
    private let sessionID: String
    /// Where `artifact` writes. Defaulted rather than required so the existing callers keep
    /// compiling, but every real one passes it — a driven run that cannot write a document is
    /// a driven run that is not an Aviary session.
    private let artifacts: ArtifactStore?
    private let writer: SessionWriter?
    /// How a note reaches the transcript. The writer belongs to `ClaudeCodeRun`, which is
    /// constructed first and owns the file; the kernel produces events worth recording and has
    /// no business opening a second handle onto the same JSONL.
    private var appendNote: (@Sendable (String, String) async -> Bool)?
    private var onJournalFailure: (@Sendable (String) async -> Void)?
    /// The first prompt of the run, recorded as provenance on anything remembered — "why does
    /// it believe that?" is unanswerable without it.
    private var firstPrompt: String?
    private var onOutput: (@Sendable (String) -> Void)?
    /// Consecutive machinery failures. Counted because a driven run cannot be stopped from
    /// here — Claude Code decides when to stop — so the only lever is what the tool result
    /// says, and it has to change once retrying is hopeless.
    private var hostFailures = 0

    public init(
        host: RuntimeHost, hostSession: String, memory: MemoryStore?,
        sessionFile: URL, sessionID: String, artifacts: ArtifactStore? = nil,
        writer: SessionWriter? = nil
    ) {
        self.host = host
        self.hostSession = hostSession
        self.memory = memory
        self.sessionFile = sessionFile
        self.sessionID = sessionID
        self.artifacts = artifacts
        self.writer = writer
    }

    /// Wire the kernel's notes into the run's transcript.
    public func onNote(_ handler: (@Sendable (String, String) async -> Void)?) {
        guard let handler else {
            appendNote = nil
            return
        }
        let checked: @Sendable (String, String) async -> Bool = { text, customType in
            await handler(text, customType)
            return true
        }
        appendNote = checked
    }

    public func onCheckedNote(_ handler: (@Sendable (String, String) async -> Bool)?) {
        appendNote = handler
    }

    public func onJournalFailure(_ handler: (@Sendable (String) async -> Void)?) {
        onJournalFailure = handler
    }

    public func noteFirstPrompt(_ prompt: String) {
        if firstPrompt == nil { firstPrompt = prompt }
    }

    /// Streaming kernel output, for a UI that wants to watch a long cell run.
    public func onOutput(_ handler: (@Sendable (String) -> Void)?) {
        onOutput = handler
    }

    /// The tool to hand to `KernelBridge`.
    public func tool() -> KernelBridge.Tool {
        KernelBridge.Tool(
            name: "python",
            // Deliberately the same description the in-house agent gets, minus `spawn`. Two
            // engines describing the same kernel differently would make a transcript's meaning
            // depend on which one wrote it.
            description: Self.description(cwd: cwdHint, hasMemory: memory != nil),
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("Python source to execute."),
                    ]),
                ]),
                "required": .array([.string("code")]),
            ])
        ) { [weak self] arguments in
            guard let self else {
                return KernelBridge.Result(
                    text: "Aviary is no longer running this session.", isError: true)
            }
            return await self.run(arguments: arguments)
        }
    }

    private var cwdHint = FileManager.default.currentDirectoryPath
    /// Images this cell asked to look at, waiting for the cell to finish.
    private var pendingImages: [AttachedImage] = []

    public func setCwdHint(_ cwd: String) { cwdHint = cwd }

    private func run(arguments: JSONValue) async -> KernelBridge.Result {
        guard let code = arguments["code"]?.stringValue, !code.isEmpty else {
            return KernelBridge.Result(
                text: "The `code` argument is required and must not be empty.", isError: true)
        }
        guard await checkWriter() else {
            return KernelBridge.Result(
                text: "The Aviary session journal is unavailable; stop this run.", isError: true)
        }
        do {
            let result = try await host.execute(code, in: hostSession)
            hostFailures = 0
            // The same rendering the in-house agent sees, so a transcript reads identically
            // whichever engine produced it.
            // Drained here rather than returned by the callback, because the callback answers
            // the *cell* and the image has to reach Claude Code, which only ever sees the tool
            // result. So it waits for the call that queued it to finish.
            let images = pendingImages
            pendingImages.removeAll()
            return KernelBridge.Result(
                text: Agent.render(result), isError: result.failed, images: images)
        } catch {
            // A host failure is *the machinery* breaking, not agent code raising — and saying
            // so matters, because the model's correct response differs: retrying is right for
            // a traceback and pointless for a dead interpreter.
            //
            // Pointless, and not free. Claude Code owns the loop here, so "the tool errored"
            // is an invitation to try again — and against a dead kernel it will, indefinitely.
            // One real session produced twenty-six identical failures in a row before anyone
            // noticed. So the message stops being an error report and becomes an instruction
            // once it is clear the kernel is not coming back.
            hostFailures += 1
            let detail = error.localizedDescription
            if hostFailures >= 2 {
                return KernelBridge.Result(text: """
                    The Aviary runtime host is gone and is not coming back in this session: \
                    \(detail)

                    Do not call this tool again — every further call will fail the same way. \
                    Stop now and report what you had established before it died, so the work \
                    is not lost. A person has to restart the session to get an interpreter \
                    back.
                    """, isError: true)
            }
            return KernelBridge.Result(
                text: "The Aviary runtime host failed to run this: " + detail, isError: true)
        }
    }

    private func checkWriter() async -> Bool {
        guard let writer else { return true }
        if case .healthy = await writer.writerHealth { return true }
        let detail = "The Aviary session journal became unavailable."
        await onJournalFailure?(detail)
        return false
    }

    /// Serve a callback from inside the kernel — `remember`, `recall`, `conversation`,
    /// `artifact`.
    ///
    /// The same verbs the in-house engine serves, with one honest gap: `spawn` needs an
    /// `AgentRunner` to build a child agent, and a driven session has no runner. Refused with
    /// a reason rather than silently absent, because agent code that calls `spawn()` and hangs
    /// is worse than agent code that is told no.
    /// `rid` is stable across at-least-once runtime replay. The driven kernel currently returns
    /// callback outcomes directly, but the identifier is kept at this boundary so any durable
    /// effect consumer can deduplicate without treating transport delivery as exactly-once.
    public func serveCallback(rid: String, kind: String, payload: JSONValue) async -> JSONValue {
        guard await checkWriter() else {
            return .object(["error": .string(
                "The Aviary session journal is unavailable; stop this run.")])
        }
        switch kind {
        case "attach_image":
            guard let path = payload["path"]?.stringValue, !path.isEmpty else {
                return .object(["error": .string("attach_image() needs a path.")])
            }
            do {
                let image = try AttachedImage.read(path: path)
                pendingImages.append(image)
                if let ok = await appendNote?(
                    "Looked at \(URL(fileURLWithPath: image.path).lastPathComponent) "
                        + "(\(image.width)×\(image.height))",
                    "aviary.image"), !ok
                {
                    await onJournalFailure?("could not record attached image")
                }
                return image.summary
            } catch {
                return .object(["error": .string(error.localizedDescription)])
            }

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
                sessionID: sessionID, provenance: firstPrompt)
            do {
                try memory.append(entry, sessionID: sessionID)
                return .object(["id": .string(entry.id), "scope": .string(scope.rawValue)])
            } catch {
                return .object(["error": .string(error.localizedDescription)])
            }

        case "recall":
            guard let memory else {
                return .object(["error": .string("This run has no memory store.")])
            }
            let query = payload["query"]?.stringValue ?? ""
            let all = memory.load(sessionID: sessionID)
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
                if let ok = await appendNote?(written.note.text, ArtifactNote.customType), !ok {
                    await onJournalFailure?("could not record artifact")
                }
                return written.payload
            } catch {
                return .object(["error": .string(error.localizedDescription)])
            }

        case "conversation":
            // Read back out of the transcript Aviary is writing, rather than out of a message
            // list — a driven run has no message list, because the history is Claude Code's.
            // Going through the file means `conversation()` shows the agent exactly what a
            // person reading the session would see.
            let limit = max(1, payload["limit"]?.intValue ?? 40)
            guard let transcript = SessionParser.parse(fileURL: sessionFile) else {
                return .object(["messages": .array([])])
            }
            let turns = transcript.items.filter {
                $0.kind == .user || $0.kind == .assistant
            }.suffix(limit)
            return .object(["messages": .array(turns.map { item in
                .object([
                    "role": .string(item.kind == .user ? "user" : "assistant"),
                    "text": .string(item.plainText),
                    "toolCalls": .array(item.blocks.compactMap { block in
                        if case .toolCall(let call) = block { return .string(call.name) }
                        return nil
                    }),
                ])
            })])

        case "spawn":
            return .object(["error": .string(
                "Sub-agents are not available in a Claude-Code-driven session — spawning "
                    + "builds an Aviary agent, and this session's loop is Claude Code's. Do "
                    + "the work here, or start an in-house run for it.")])

        default:
            return .object(["error": .string("Aviary does not serve \(kind) requests.")])
        }
    }

    /// What the model is told the tool does.
    ///
    /// The same render the in-house engine uses, minus `spawn` — a driven session has no
    /// runner to spawn with. Two engines describing the same kernel in their own words would
    /// make a transcript's meaning depend on which one wrote it.
    static func description(cwd: String, hasMemory: Bool) -> String {
        // supportsImages unconditionally: this engine is always driven by a Claude model, and
        // every one of them reads images.
        Builtins.description(Builtins.Context(
            cwd: cwd, hasMemory: hasMemory, canSpawn: false, supportsImages: true))
    }
}
