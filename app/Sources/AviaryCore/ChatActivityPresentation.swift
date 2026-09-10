import Foundation

/// Presentation only. These sections never change command admission or infer a human decision
/// from a failed action. Parent-activity links are not treated as cross-action hierarchy.
public struct ChatActivityPresentation: Hashable, Sendable {
    public static let maximumActions = 256
    public let current: [WorkActionPresentation]
    public let problems: [WorkActionPresentation]
    public let completed: [WorkActionPresentation]
    public let omittedCount: Int
    public let sourceIsComplete: Bool

    public init(actions: [WorkActionPresentation], sourceIsComplete: Bool) {
        let bounded = Array(actions.prefix(Self.maximumActions))
        var counts = bounded.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
        // Inspect the omitted tail for conflicts with retained identities, without growing the
        // bounded identity table or pretending that a cap makes a conflicting winner safe.
        for action in actions.dropFirst(Self.maximumActions) where counts[action.id] != nil {
            counts[action.id] = 2
        }
        // An ambiguous identity is not an arbitrary first winner or a duplicate SwiftUI row.
        let retained = bounded.filter { counts[$0.id] == 1 }
        current = retained.filter { !$0.state.isTerminal }
        problems = retained.filter { $0.state == .failed || $0.state == .indeterminateEffect }
        completed = retained.filter { $0.state == .succeeded || $0.state == .canceled }
        omittedCount = actions.count - retained.count
        self.sourceIsComplete = sourceIsComplete && omittedCount == 0
    }

    public var summary: String {
        let count = current.count + problems.count + completed.count
        guard count > 0 else {
            return sourceIsComplete ? "No actions recorded yet." : "Action records are unavailable in this view."
        }
        return "\(current.count) unsettled · \(problems.count) failed or uncertain · \(completed.count) completed in view"
    }

    /// A fresh read is not runtime liveness, but an older/disconnected read must not look live.
    public static func sourceIsCurrent(_ projection: WorkServiceAttachedWorkProjection) -> Bool {
        guard case .connected = projection.connectivity else { return false }
        return projection.isCanonical
            && !projection.requiresRefresh && projection.readDiagnostics.isEmpty
            && projection.workSnapshot.unknownDomains.isEmpty
            && projection.sessionSnapshot.unknownDomains.isEmpty
            && projection.workOmissions.isEmpty && projection.sessionOmissions.isEmpty
    }
}

/// Work-wide, last-recorded child lifecycle. It is not a census of live processes, current-Run
/// children, arbitrary Python Futures, or independently verified task results.
public struct ChatChildActivityPresentation: Hashable, Sendable {
    public let isAvailable: Bool
    public let sourceIsCurrent: Bool
    public let running: Int
    public let done: Int
    public let failed: Int
    public let canceled: Int
    public let unknown: Int
    public let omittedCount: Int

    public init(workingState: CanonicalWorkingStateProjection?, sourceIsCurrent: Bool) {
        let recorded = workingState.flatMap { $0.isCanonical ? $0 : nil }
        isAvailable = recorded != nil
        self.sourceIsCurrent = isAvailable && sourceIsCurrent
        let children = recorded?.children ?? []
        running = children.filter { $0.state == .running }.count
        done = children.filter { $0.state == .done }.count
        failed = children.filter { $0.state == .failed }.count
        canceled = children.filter { $0.state == .canceled }.count
        unknown = children.filter { $0.state == .unknown }.count
        omittedCount = max(0, recorded?.omittedChildCount ?? 0)
    }

    public var hasRecords: Bool {
        isAvailable && (running > 0 || done > 0 || failed > 0 || canceled > 0 || unknown > 0 || omittedCount > 0)
    }

    public var summary: String {
        guard isAvailable else { return "Child-agent records are unavailable in this view." }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) recorded running") }
        if done > 0 { parts.append("\(done) finished") }
        if failed > 0 { parts.append("\(failed) failed") }
        if canceled > 0 { parts.append("\(canceled) canceled") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        if omittedCount > 0 { parts.append("\(omittedCount) outside this view") }
        return parts.isEmpty ? "No child agents recorded in this view." : parts.joined(separator: " · ")
    }

    public var disclosure: String {
        let freshness = sourceIsCurrent ? "" : "The latest state is not confirmed. "
        return freshness + "Latest recorded states for this agent workspace, including earlier sessions. "
            + "Not proof that a child is still running or that its result is correct. "
            + "Other Python background tasks are not included."
    }
}
