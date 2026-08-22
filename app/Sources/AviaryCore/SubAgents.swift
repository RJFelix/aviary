import Foundation

/// Sub-agent bookkeeping, in the layout Aviary's Flock screen already reads.
///
/// The harness records children in `session-artifacts/<parent>/rlm-subagents.jsonl`, and
/// `AgentTreeReader` builds the tree from it — including a fan-out timeline and live status.
/// Writing the same records means an in-house sub-agent appears there with no new UI at all,
/// which is the same reasoning that made `SessionWriter` reuse the transcript format.
public struct SubAgentRecorder: Sendable {
    public let home: AgentHome
    public let parentSessionID: String

    public init(home: AgentHome, parentSessionID: String) {
        self.home = home
        self.parentSessionID = parentSessionID
    }

    public var artifactsDir: URL {
        home.artifacts(forSession: parentSessionID)
    }

    var ledgerURL: URL {
        artifactsDir.appending(path: "rlm-subagents.jsonl")
    }

    /// Where a child's own transcript goes, and its own artifacts alongside it.
    ///
    /// Nested under the parent so a grandchild's records sit inside its parent's directory —
    /// which is how the tree reader recovers depth without being told it.
    public func childDirectory(childID: String) -> URL {
        artifactsDir.appending(path: childID, directoryHint: .isDirectory)
    }

    /// A stable id for a child. `sub-` prefixed, like the harness's, so anything keying on
    /// that shape keeps working.
    public static func newChildID() -> String {
        "sub-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    /// Append a record. Later records supersede earlier ones for the same child, so status
    /// changes are appends rather than rewrites — the same event-sourced discipline as the
    /// workshop board, for the same reason: two writers, one file, no locking.
    public func record(
        childID: String, name: String, sessionFile: URL, prompt: String, spawnCode: String,
        depth: Int, maxDepth: Int, status: String, provider: String?, model: String?,
        createdAt: Date, updatedAt: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(
            at: artifactsDir, withIntermediateDirectories: true)
        var obj: [String: JSONValue] = [
            "type": .string("rlm_subagent"),
            "childId": .string(childID),
            "sessionName": .string(name),
            "sessionFile": .string(sessionFile.path),
            "sessionDir": .string(sessionFile.deletingLastPathComponent().path),
            "parentSessionId": .string(parentSessionID),
            "rlmDepth": .number(Double(depth)),
            "rlmMaxDepth": .number(Double(maxDepth)),
            "status": .string(status),
            "prompt": .string(prompt),
            "spawnCode": .string(spawnCode),
            "createdAt": .string(SessionWriter.stamp(createdAt)),
            "updatedAt": .string(SessionWriter.stamp(updatedAt)),
        ]
        if provider != nil || model != nil {
            obj["model"] = .object([
                "provider": provider.map { JSONValue.string($0) } ?? .null,
                "modelId": model.map { JSONValue.string($0) } ?? .null,
            ])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(obj))
        data.append(UInt8(ascii: "\n"))

        if !FileManager.default.fileExists(atPath: ledgerURL.path) {
            FileManager.default.createFile(atPath: ledgerURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: ledgerURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
