import Foundation

/// Writes session files Aviary can already read.
///
/// The format is the harness's, on purpose. Aviary has a parser, a renderer, a catalog, usage
/// analytics and a sub-agent tree reader all built on it, and inventing a second format would
/// mean either duplicating all of that or losing it. So an in-house run produces files
/// indistinguishable from a harness run, and every existing screen works on day one.
///
/// Append-only, one complete JSON object per line. A run that dies mid-turn leaves a
/// readable transcript up to that point rather than a truncated object — which matters because
/// the moment you most want to read a transcript is right after something went wrong.
public actor SessionWriter {
    // `nonisolated` because they are immutable and read constantly for logging and paths;
    // making a caller await an actor hop for a value that can never change is friction with
    // no safety behind it.
    public nonisolated let sessionID: String
    public nonisolated let identity: SessionWorkIdentity
    public nonisolated let fileURL: URL
    private let handle: FileHandle
    private var lastEntryID: String?
    private var entryCount = 0
    private var failurePlan: FailurePlan
    private var health: WriterHealth = .healthy
    private var isClosed = false
    private var intentCommitGate: IntentCommitGate? = nil

    /// A deterministic test seam for holding an intent before its append. Production writers
    /// never install one; it lets controller tests exercise a GUI End arriving while a prior
    /// commit is genuinely in flight rather than relying on scheduler timing.
    public actor IntentCommitGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        public init() {}

        public func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        public func release() {
            guard !released else { return }
            released = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters.removeAll()
        }
    }

    public enum FailurePoint: String, Sendable, Hashable, CaseIterable {
        case beforeWrite
        case partialWrite
        case afterWriteBeforeSync
    }

    /// A one-shot deterministic seam for proving that write and sync ambiguity fail closed.
    /// Production callers leave this at `.none`; tests can inject one failure at construction.
    public struct FailurePlan: Sendable, Hashable {
        public var point: FailurePoint?

        public init(point: FailurePoint? = nil) { self.point = point }

        public static let none = FailurePlan()
    }

    public enum WriterHealth: Sendable, Hashable {
        case healthy
        case failed(reason: String)
        case closed
    }

    public enum WriterError: LocalizedError, Sendable, Equatable {
        case unavailable(String)
        case injected(FailurePoint)
        case closed

        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "Session journal unavailable: \(reason)"
            case .injected(let point): return "Injected Session journal failure at \(point.rawValue)."
            case .closed: return "Session journal is closed."
            }
        }
    }

    /// Short ids, like the harness writes. Long enough to not collide within a session, short
    /// enough to read in a diff.
    private static func newEntryID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// A session id that sorts by creation time, like the harness's UUIDv7-ish names, so
    /// `ls` and the catalog agree with each other.
    public static func newSessionID(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        let hex = String(format: "%012llx", ms)
        let tail = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(hex.prefix(8))-\(hex.suffix(4))-7\(tail.prefix(3))-\(tail.dropFirst(3).prefix(4))-\(tail.dropFirst(7).prefix(12))"
    }

    public enum ResumeFailure: LocalizedError {
        case noSuchSession(String)

        public var errorDescription: String? {
            switch self {
            case .noSuchSession(let id): return "No session file for \(id) to resume."
            }
        }
    }

    /// Continue writing an existing session.
    ///
    /// Two things make this more than opening the file in append mode.
    ///
    /// No second `session` header: the file already has one, and a reader that meets a second
    /// treats the tail as a different session.
    ///
    /// And `lastEntryID` is seeded from the last entry already in the file. Entries thread
    /// `parentId`, and the parser walks the active branch backwards from the *last* line — so a
    /// resumed run whose first entry has no parent orphans the entire prior conversation. The
    /// transcript would show only the new turns and look perfectly well-formed doing it.
    public init(
        home: AgentHome, resuming sessionID: String, cwd: String, model: ModelSpec?,
        identity requestedIdentity: SessionWorkIdentity? = nil,
        failurePlan: FailurePlan = .none
    ) throws {
        let identity = Self.resumeIdentity(
            home: home, sessionID: sessionID, requested: requestedIdentity)
        self.identity = identity
        self.sessionID = identity.sessionID
        self.fileURL = home.sessionFile(id: identity.sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ResumeFailure.noSuchSession(sessionID)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        self.failurePlan = failurePlan

        // A previous process may have died after writing only part of a JSONL entry. Preserve
        // that evidence, but terminate the malformed record before appending the next one; an
        // otherwise valid run_start would be concatenated onto the fragment and become unreadable.
        try Self.quarantinePartialTail(of: fileURL, handle: handle)
        let tail = Self.tailEntry(of: fileURL)
        lastEntryID = tail.id
        entryCount = tail.count

        // A resumed run gets a new run id while keeping the session and Work ids. This is an
        // ignored-by-legacy-readers record, but gives future reducers a durable run boundary.
        try Self.append(
            type: "run_start", fields: [
            "runId": .string(identity.runID),
            "workHostId": .string(identity.workHostID),
            "workId": .string(identity.workID),
            ], handle: handle, lastEntryID: &lastEntryID, entryCount: &entryCount,
            failurePlan: &self.failurePlan)

        // A model_change is written when resuming with a model, because a resumed run may use
        // a different one and the transcript already renders switches.
        if let model {
            try Self.appendModelChange(
                model, handle: handle, lastEntryID: &lastEntryID, entryCount: &entryCount,
                failurePlan: &self.failurePlan)
        }
    }

    /// Reopen an existing projection without appending a run boundary.
    ///
    /// This is reserved for the narrow crash window where the canonical Work journal already
    /// contains the exact trailing `run.started` marker (or a prior process has written this
    /// Run's flat boundary) but the Start command was never accepted. The caller must prove that
    /// boundary from the native journal before choosing this initializer. A hosted engine may
    /// also use it for an exact producer-to-worker handoff after closing the initial writer
    /// and acquiring its exclusive lifetime lease. It is not a general transcript-resume API.
    public init(
        home: AgentHome,
        reopeningWithoutRunBoundary sessionID: String,
        identity requestedIdentity: SessionWorkIdentity,
        failurePlan: FailurePlan = .none
    ) throws {
        let identity = Self.resumeIdentity(
            home: home, sessionID: sessionID, requested: requestedIdentity)
        self.identity = identity
        self.sessionID = identity.sessionID
        self.fileURL = home.sessionFile(id: identity.sessionID)
        guard identity == requestedIdentity,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ResumeFailure.noSuchSession(sessionID)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        self.failurePlan = failurePlan
        try Self.quarantinePartialTail(of: fileURL, handle: handle)
        let tail = Self.tailEntry(of: fileURL)
        lastEntryID = tail.id
        entryCount = tail.count
    }

    /// The id of the last entry in an existing session, and how many entries it holds.
    ///
    /// Reads the whole file, which is the honest cost of resuming: the largest transcript in
    /// this agent directory is 12 MB, read once at run start.
    private static func tailEntry(of url: URL) -> (id: String?, count: Int) {
        guard let data = FileManager.default.contents(atPath: url.path) else { return (nil, 0) }
        var lastID: String?
        var count = 0
        for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var slice = Data(chunk)
            if slice.last == UInt8(ascii: "\r") { slice.removeLast() }
            guard !slice.isEmpty, let v = JSONValue.parse(slice) else { continue }
            count += 1
            // The header has an id too, and is a legitimate parent for a resumed run whose
            // session recorded nothing else.
            if let id = v["id"]?.stringValue { lastID = id }
        }
        return (lastID, count)
    }

    private static func quarantinePartialTail(of url: URL, handle: FileHandle) throws {
        guard let data = FileManager.default.contents(atPath: url.path),
              !data.isEmpty,
              data.last != UInt8(ascii: "\n")
        else { return }
        try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
        try handle.synchronize()
    }

    public init(
        home: AgentHome, sessionID: String? = nil, cwd: String, model: ModelSpec?,
        identity suppliedIdentity: SessionWorkIdentity? = nil,
        failurePlan: FailurePlan = .none
    ) throws {
        let identity = suppliedIdentity
            ?? SessionWorkIdentity.allocate(
                workHostID: home.workHostID,
                sessionID: sessionID ?? Self.newSessionID())
        let sid = identity.sessionID
        self.identity = identity
        self.sessionID = sid
        self.fileURL = home.sessionFile(id: sid)
        try FileManager.default.createDirectory(
            at: home.sessionsDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        self.failurePlan = failurePlan

        // The header is written immediately, unlike the harness — which defers file creation
        // until the first assistant message and so leaves a failed run with no transcript at
        // all. A run that dies during its first model call is exactly the one worth reading.
        var header: [String: JSONValue] = [
            "type": .string("session"),
            "version": .number(1),
            "id": .string(sid),
            "timestamp": .string(Self.stamp()),
            "cwd": .string(cwd),
            "writer": .string("aviary"),
            "workHostId": .string(identity.workHostID),
            "workId": .string(identity.workID),
            "runId": .string(identity.runID),
        ]
        if let model {
            header["model"] = .object([
                "id": .string(model.id), "provider": .string(model.providerID),
            ])
        }
        try Self.writeRaw(.object(header), handle: handle, entryCount: &entryCount,
                          failurePlan: &self.failurePlan)
        if let model {
            try Self.appendModelChange(
                model, handle: handle, lastEntryID: &lastEntryID, entryCount: &entryCount,
                failurePlan: &self.failurePlan)
        }
    }

    /// Recover Work identity from a session header, synthesizing stable legacy Work fields when
    /// old files predate them. A fresh run id is always allocated: this describes the resumed
    /// attempt, not the historical attempt that wrote the header.
    public static func recoverIdentity(
        home: AgentHome, sessionID: String
    ) -> SessionWorkIdentity? {
        let url = home.sessionFile(id: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let header = firstHeader(of: url)
        let host = header?["workHostId"]?.stringValue
            ?? header?["workHostID"]?.stringValue
            ?? home.workHostID
        let work = header?["workId"]?.stringValue
            ?? header?["workID"]?.stringValue
            ?? "legacy-work-\(sessionID)"
        return SessionWorkIdentity.allocate(
            workHostID: host, sessionID: sessionID, workID: work)
    }

    private static func resumeIdentity(
        home: AgentHome, sessionID: String, requested: SessionWorkIdentity?
    ) -> SessionWorkIdentity {
        if let requested, requested.sessionID == sessionID { return requested }
        if let recovered = recoverIdentity(home: home, sessionID: sessionID) {
            return recovered
        }
        if let requested {
            return SessionWorkIdentity(
                sessionID: sessionID, work: requested.work, runID: requested.runID)
        }
        return SessionWorkIdentity.allocate(
            workHostID: home.workHostID, sessionID: sessionID,
            workID: "legacy-work-\(sessionID)")
    }

    private static func firstHeader(of url: URL) -> JSONValue? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1)
                .first,
              let value = JSONValue.parse(Data(line)),
              value["type"]?.stringValue == "session"
        else { return nil }
        return value
    }

    /// Record which model is answering from here on.
    ///
    /// Threaded through `append` rather than written raw, and keyed `modelId`. Both were bugs:
    /// an unparented entry is not on the active branch, so the row never rendered — and the
    /// parser reads `modelId`, so the `model` key this used to write left every Aviary-written
    /// session with an empty model in its switch list. Each one hid the other.
    /// Public because a model can change mid-run, not only at the start. The transcript is
    /// what makes a switch legible afterwards: without this entry, half a conversation was
    /// answered by a model the file never names.
    public func appendModelChange(_ model: ModelSpec) throws {
        try append(type: "model_change", fields: [
            "provider": .string(model.providerID),
            "modelId": .string(model.id),
        ])
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func writeRaw(_ value: JSONValue) throws {
        try Self.writeRaw(value, handle: handle, entryCount: &entryCount,
                          failurePlan: &failurePlan)
    }

    private static func writeRaw(
        _ value: JSONValue, handle: FileHandle, entryCount: inout Int,
        failurePlan: inout FailurePlan
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        if failurePlan.point == .beforeWrite {
            failurePlan.point = nil
            throw WriterError.injected(.beforeWrite)
        }
        if failurePlan.point == .partialWrite {
            failurePlan.point = nil
            let prefixLength = max(1, data.count / 2)
            try handle.write(contentsOf: data.prefix(prefixLength))
            throw WriterError.injected(.partialWrite)
        }
        try handle.write(contentsOf: data)
        if failurePlan.point == .afterWriteBeforeSync {
            failurePlan.point = nil
            throw WriterError.injected(.afterWriteBeforeSync)
        }
        try handle.synchronize()
        entryCount += 1
    }

    /// Append an entry, threading `parentId` so the file is the entry *tree* the parser walks.
    @discardableResult
    private func append(type: String, fields: [String: JSONValue]) throws -> String {
        guard !isClosed else { throw WriterError.closed }
        guard case .healthy = health else {
            if case .failed(let reason) = health { throw WriterError.unavailable(reason) }
            throw WriterError.closed
        }
        do {
            return try Self.append(
                type: type, fields: fields, handle: handle,
                lastEntryID: &lastEntryID, entryCount: &entryCount,
                failurePlan: &failurePlan)
        } catch {
            health = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    private static func append(
        type: String, fields: [String: JSONValue], handle: FileHandle,
        lastEntryID: inout String?, entryCount: inout Int,
        failurePlan: inout FailurePlan
    ) throws -> String {
        let id = Self.newEntryID()
        var obj = fields
        obj["type"] = .string(type)
        obj["id"] = .string(id)
        obj["timestamp"] = .string(Self.stamp())
        if let lastEntryID { obj["parentId"] = .string(lastEntryID) }
        try writeRaw(.object(obj), handle: handle, entryCount: &entryCount,
                     failurePlan: &failurePlan)
        lastEntryID = id
        return id
    }

    private static func appendModelChange(
        _ model: ModelSpec, handle: FileHandle,
        lastEntryID: inout String?, entryCount: inout Int,
        failurePlan: inout FailurePlan
    ) throws {
        try append(
            type: "model_change", fields: [
                "provider": .string(model.providerID),
                "modelId": .string(model.id),
            ], handle: handle, lastEntryID: &lastEntryID, entryCount: &entryCount,
            failurePlan: &failurePlan)
    }

    // MARK: Messages

    @discardableResult
    public func appendUser(_ text: String) throws -> String {
        try append(type: "message", fields: [
            "message": .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ])
    }

    /// An image the agent asked to look at.
    ///
    /// Written into the transcript as a real user-role image block, the same shape the parser
    /// already reads, so a session replayed tomorrow shows the picture rather than a note
    /// saying one was here. The path and caption ride along as text in the same message —
    /// they are what makes the image legible in a list of thumbnails.
    public func appendImage(
        mimeType: String, base64: String, path: String, note: String?
    ) throws {
        var blocks: [JSONValue] = []
        let caption = [note, "[\(path)]"].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        blocks.append(.object(["type": .string("text"), "text": .string(caption)]))
        blocks.append(.object([
            "type": .string("image"),
            "mimeType": .string(mimeType),
            "data": .string(base64),
        ]))
        try append(type: "message", fields: [
            "message": .object(["role": .string("user"), "content": .array(blocks)]),
        ])
    }

    /// One assistant turn: its text, its visible thinking, its tool calls, and what it cost.
    public func appendAssistant(
        text: String, thinking: String, toolCalls: [(id: String, name: String, arguments: JSONValue)],
        usage: Usage?, stopReason: String?
    ) throws -> String {
        var blocks: [JSONValue] = []
        if !thinking.isEmpty {
            blocks.append(.object(["type": .string("thinking"), "thinking": .string(thinking)]))
        }
        if !text.isEmpty {
            blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for call in toolCalls {
            blocks.append(.object([
                "type": .string("toolCall"),
                "id": .string(call.id),
                "name": .string(call.name),
                "arguments": call.arguments,
            ]))
        }
        var message: [String: JSONValue] = [
            "role": .string("assistant"),
            "content": .array(blocks),
        ]
        if let usage {
            try usage.validateForPersistence()
            // `Usage()` is an in-memory additive identity, not evidence of a provider crossing.
            // An explicitly present zero identity becomes a visible unclassified record; a
            // numeric neutral was rejected by validation above.
            let persistedUsage = usage.completeness == .neutral
                ? Usage.unclassifiedRecord : usage
            try persistedUsage.validateForTranscript()
            var u: [String: JSONValue] = [
                "input": Usage.transcriptInteger(persistedUsage.input),
                "output": Usage.transcriptInteger(persistedUsage.output),
                "cacheRead": Usage.transcriptInteger(persistedUsage.cacheRead),
                "cacheWrite": Usage.transcriptInteger(persistedUsage.cacheWrite),
                "totalTokens": Usage.transcriptInteger(persistedUsage.totalTokens),
                "completeness": persistedUsage.completenessJSON,
            ]
            // Written only when the provider said something. Absent and zero mean different
            // things on an encrypted-reasoning route, and flattening them loses the evidence.
            if let reasoning = persistedUsage.reasoning {
                u["reasoning"] = Usage.transcriptInteger(reasoning)
            }
            // Persist all five fields even when zero. Completeness distinguishes known zero
            // from unavailable pricing; omission must never authenticate an exact zero later.
            u["cost"] = .object([
                "input": .number(persistedUsage.cost.input),
                "output": .number(persistedUsage.cost.output),
                "cacheRead": .number(persistedUsage.cost.cacheRead),
                "cacheWrite": .number(persistedUsage.cost.cacheWrite),
                "total": .number(persistedUsage.cost.total),
            ])
            message["usage"] = .object(u)
        }
        if let stopReason { message["stopReason"] = .string(stopReason) }
        return try append(type: "message", fields: ["message": .object(message)])
    }

    public func appendToolResult(
        id: String, name: String, text: String, isError: Bool, details: JSONValue? = nil
    ) throws {
        var message: [String: JSONValue] = [
            "role": .string("toolResult"),
            "toolCallId": .string(id),
            "toolName": .string(name),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ]
        if let details { message["details"] = details }
        try append(type: "message", fields: ["message": .object(message)])
    }

    /// A driven host reports session-cumulative usage independently of its message items.
    /// This replaces the aggregate at this point; it is not another billable message.
    public func appendUsageSnapshot(_ usage: Usage, source: String) throws {
        try usage.validateForTranscript()
        let raw = try JSONEncoder().encode(usage)
        try append(type: "custom_message", fields: [
            "customType": .string("aviary.usage-snapshot.v1"),
            "role": .string("custom"),
            "source": .string(source),
            // Keep exact Int counters through JSONValue's Double-backed envelope.
            "usageSnapshot": .string(String(decoding: raw, as: UTF8.self)),
        ])
    }

    /// Persist a terminal run outcome independently of assistant messages. A provider can fail
    /// before producing one, and cancellation can happen before the first token; a typed marker
    /// lets cold readers recover that truth without fabricating a model row.
    @discardableResult
    public func appendOutcome(
        state: TranscriptOutcome.State, detail: String? = nil
    ) throws -> String {
        var fields: [String: JSONValue] = [
            "customType": .string("aviary.outcome"),
            "role": .string("custom"),
            "outcomeState": .string(state.rawValue),
        ]
        if let detail, !detail.isEmpty {
            fields["detail"] = .string(detail)
            fields["content"] = .array([
                .object(["type": .string("text"), "text": .string(detail)]),
            ])
        }
        return try append(type: "custom_message", fields: fields)
    }

    /// Persist the controller's admission before an engine crosses into work. This uses the
    /// legacy session JSONL deliberately: old readers ignore the hidden custom record, while a
    /// raw reader can recover the complete intent and its controller ordering.
    @discardableResult
    public func appendCommandIntent(
        commandID: String,
        command: SessionCommand,
        identity: SessionWorkIdentity,
        actorID: String,
        controllerSequence: Int,
        previousState: SessionCommandState,
        state: SessionCommandState,
        timestamp: Date = Date()
    ) async throws -> String {
        if let intentCommitGate {
            await intentCommitGate.wait()
        }
        var commandFields: [String: JSONValue] = ["kind": .string(command.label)]
        switch command {
        case .start(let prompt), .send(let prompt):
            commandFields["value"] = .string(prompt)
        case .steer(let text), .queueFollowUp(let text):
            commandFields["value"] = .string(text)
        case .cancel(let scope):
            commandFields["scope"] = .string(scope.rawValue)
        case .endRun:
            break
        }
        return try append(type: "custom_message", fields: [
            "customType": .string("aviary.command-intent.v1"),
            "role": .string("custom"),
            "hidden": .bool(true),
            "commandID": .string(commandID),
            "command": .object(commandFields),
            "identity": .object([
                "sessionID": .string(identity.sessionID),
                "workHostID": .string(identity.workHostID),
                "workID": .string(identity.workID),
                "runID": .string(identity.runID),
            ]),
            "actorID": .string(actorID),
            "controllerSequence": .number(Double(controllerSequence)),
            "previousState": .string(previousState.rawValue),
            "state": .string(state.rawValue),
            "intentTimestamp": .string(Self.stamp(timestamp)),
        ])
    }

    /// A note from the machinery rather than from either party — a launch failure, a budget
    /// stop. Rendered distinctly by the parser, which is why it is not faked as an assistant
    /// message.
    public func appendNote(_ text: String, customType: String = "aviary.note") throws {
        try append(type: "custom_message", fields: [
            "customType": .string(customType),
            "role": .string("custom"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
    }

    /// Mark a compaction. The dropped entries stay in the file above this marker — the model
    /// forgets, the record does not, and a reader can still see exactly what went.
    public func appendCompaction(
        summary: String, tokensBefore: Int, droppedMessages: Int
    ) throws {
        try append(type: "compaction", fields: [
            "summary": .string(summary),
            "tokensBefore": .number(Double(tokensBefore)),
            "droppedMessages": .number(Double(droppedMessages)),
        ])
    }

    public func appendStatus(_ status: String) throws {
        try append(type: "session_state", fields: ["status": .string(status)])
    }

    public var count: Int { entryCount }

    public var writerHealth: WriterHealth { health }

    /// Test/diagnostic seam for exercising a specific next write boundary after construction.
    /// It is deliberately one-shot; normal callers never need to set it.
    public func injectFailure(_ point: FailurePoint?) {
        failurePlan.point = point
    }

    /// Install or clear the deterministic intent-commit gate used by focused controller tests.
    public func installIntentCommitGate(_ gate: IntentCommitGate?) {
        intentCommitGate = gate
    }

    /// Checked close for teardown paths that must surface a sync/close failure. `close()` below
    /// remains as a source-compatible best-effort shim for existing callers until drivers adopt
    /// this boundary.
    public func closeChecked() throws {
        guard !isClosed else { return }
        do {
            try handle.synchronize()
            try handle.close()
            isClosed = true
            health = .closed
        } catch {
            health = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    public func close() {
        try? closeChecked()
    }
}
