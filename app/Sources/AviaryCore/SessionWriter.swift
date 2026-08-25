import Foundation

/// Writes session files Aviary can already read.
///
/// The format is the harness's, on purpose. Aviary has a parser, a renderer, a catalog, usage
/// analytics and a sub-agent tree reader all built on it, and inventing a second format would
/// mean either duplicating all of that or losing it. So an in-house run produces files
/// indistinguishable from a harness run, and every existing screen works on day one.
///
/// Append-only, one JSON object per line, flushed per entry. A run that dies mid-turn leaves a
/// readable transcript up to that point rather than a truncated object — which matters because
/// the moment you most want to read a transcript is right after something went wrong.
public actor SessionWriter {
    // `nonisolated` because they are immutable and read constantly for logging and paths;
    // making a caller await an actor hop for a value that can never change is friction with
    // no safety behind it.
    public nonisolated let sessionID: String
    public nonisolated let fileURL: URL
    private let handle: FileHandle
    private var lastEntryID: String?
    private var entryCount = 0

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
    public init(home: AgentHome, resuming sessionID: String, cwd: String, model: ModelSpec?) throws {
        self.sessionID = sessionID
        self.fileURL = home.sessionFile(id: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ResumeFailure.noSuchSession(sessionID)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()

        let tail = Self.tailEntry(of: fileURL)
        lastEntryID = tail.id
        entryCount = tail.count

        // A model_change is written when resuming with a model, because a resumed run may use
        // a different one and the transcript already renders switches.
        if let model { try appendModelChange(model) }
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

    public init(home: AgentHome, sessionID: String? = nil, cwd: String, model: ModelSpec?) throws {
        let sid = sessionID ?? Self.newSessionID()
        self.sessionID = sid
        self.fileURL = home.sessionFile(id: sid)
        try FileManager.default.createDirectory(
            at: home.sessionsDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()

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
        ]
        if let model {
            header["model"] = .object([
                "id": .string(model.id), "provider": .string(model.providerID),
            ])
        }
        try writeRaw(.object(header))
        if let model { try appendModelChange(model) }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        try handle.write(contentsOf: data)
        entryCount += 1
    }

    /// Append an entry, threading `parentId` so the file is the entry *tree* the parser walks.
    @discardableResult
    private func append(type: String, fields: [String: JSONValue]) throws -> String {
        let id = Self.newEntryID()
        var obj = fields
        obj["type"] = .string(type)
        obj["id"] = .string(id)
        obj["timestamp"] = .string(Self.stamp())
        if let lastEntryID { obj["parentId"] = .string(lastEntryID) }
        try writeRaw(.object(obj))
        lastEntryID = id
        return id
    }

    // MARK: Messages

    public func appendUser(_ text: String) throws {
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
    ) throws {
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
            var u: [String: JSONValue] = [
                "input": .number(Double(usage.input)),
                "output": .number(Double(usage.output)),
                "cacheRead": .number(Double(usage.cacheRead)),
                "cacheWrite": .number(Double(usage.cacheWrite)),
                "totalTokens": .number(Double(usage.totalTokens)),
            ]
            // Written only when the provider said something. Absent and zero mean different
            // things on an encrypted-reasoning route, and flattening them loses the evidence.
            if let reasoning = usage.reasoning { u["reasoning"] = .number(Double(reasoning)) }
            // Cost, when the model published rates. Written into the transcript rather than
            // derived at display time, so the Usage and Cockpit screens read the same numbers
            // for an in-house run as for a harness one — and `sessionsWithoutPricing` keeps
            // meaning "no rates published" rather than "cost zero".
            if usage.cost.total > 0 {
                u["cost"] = .object([
                    "input": .number(usage.cost.input),
                    "output": .number(usage.cost.output),
                    "cacheRead": .number(usage.cost.cacheRead),
                    "cacheWrite": .number(usage.cost.cacheWrite),
                    "total": .number(usage.cost.total),
                ])
            }
            message["usage"] = .object(u)
        }
        if let stopReason { message["stopReason"] = .string(stopReason) }
        try append(type: "message", fields: ["message": .object(message)])
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

    public func close() {
        try? handle.close()
    }
}
