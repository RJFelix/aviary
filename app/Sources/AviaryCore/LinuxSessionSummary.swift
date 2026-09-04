import Foundation

#if os(Linux)
/// The non-destructive compatibility row needed by canonical Work projections.
///
/// Linux deliberately does not compile the macOS SessionCatalog actor (whose API includes Trash
/// operations), but canonical reducers still retain the same legacy-summary mapping shape. This
/// value keeps that mapping type-compatible without exposing session-trash functionality in the
/// daemon target.
public struct SessionSummary: Sendable, Identifiable, Hashable {
    public var id: String
    public var headerID: String?
    public var fileURL: URL?
    public var name: String?
    public var cwd: String
    public var gitBranch: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var byteSize: Int
    public var provider: String?
    public var model: String?
    public var usage: Usage
    public var childUsage: Usage
    public var counts: Transcript.Counts
    public var firstPrompt: String
    public var lastAssistantText: String
    public var status: AgentStatus?
    public var sessionState: String?
    public var rlmDepth: Int
    public var parentSessionPath: String?
    public var childCount: Int = 0
    public var isLive: Bool = false
    public var isBusy: Bool = false
    public var liveOperation: String?
    public var isArchived: Bool = false
    public var isCanonicalOnly: Bool = false

    public var title: String {
        if let name, !name.isEmpty { return name }
        let prompt = firstPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return String(prompt.prefix(120)) }
        return "Untitled session"
    }

    public var projectName: String {
        cwd.isEmpty ? "—" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var totalUsage: Usage { usage }

    public var isSubstantial: Bool {
        counts.assistant >= 3 || counts.toolCalls >= 3
    }
}
#endif
