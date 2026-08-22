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
        if let model {
            try writeRaw(.object([
                "type": .string("model_change"),
                "id": .string(Self.newEntryID()),
                "timestamp": .string(Self.stamp()),
                "provider": .string(model.providerID),
                "model": .string(model.id),
            ]))
        }
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
