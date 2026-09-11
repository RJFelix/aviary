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

/// The bounded status vocabulary for Work-owned agent Handles. These rows are recorded facts,
/// not a process census: an unsettled row never turns into a liveness claim merely because the
/// last canonical read came from a connected host.
public enum ChatAgentHandleActivityStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case cancellationRequested = "cancellation_requested"
    case terminalCleanupIndeterminate = "terminal_cleanup_indeterminate"
    case settled
    case reaped
}

/// A privacy-safe activity row for one Work-owned agent Handle. Labels, deadlines, command
/// envelopes, and request/result body references stay in the canonical Work journal and never
/// cross into this presentation value.
public struct ChatAgentHandleActivityRow: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let status: ChatAgentHandleActivityStatus
    public let terminalOutcome: WorkAgentHandleTerminalOutcome?
    public let cleanupState: WorkAgentHandleCleanupState?

    public init(
        id: String,
        status: ChatAgentHandleActivityStatus,
        terminalOutcome: WorkAgentHandleTerminalOutcome?,
        cleanupState: WorkAgentHandleCleanupState?
    ) {
        self.id = id
        self.status = status
        self.terminalOutcome = terminalOutcome
        self.cleanupState = cleanupState
    }
}

/// Presentation for durable, Work-owned agent children. This is intentionally separate from
/// ``ChatChildActivityPresentation``: the latter describes legacy Run-owned child records whose
/// lifetime and completion semantics are different.
public struct ChatAgentHandleActivityPresentation: Codable, Hashable, Sendable {
    public static let maximumRows = CanonicalWorkingStateProjection.maximumAgentHandles

    public let isAvailable: Bool
    public let sourceIsCurrent: Bool
    public let rows: [ChatAgentHandleActivityRow]
    public let queuedCount: Int
    public let runningCount: Int
    public let cancellationRequestedCount: Int
    public let terminalCleanupIndeterminateCount: Int
    public let settledCount: Int
    public let reapedCount: Int
    public let omittedCount: Int

    public init(workingState: CanonicalWorkingStateProjection?, sourceIsCurrent: Bool) {
        guard let workingState, workingState.isCanonical, workingState.agentHandleFactsAvailable else {
            isAvailable = false
            self.sourceIsCurrent = false
            rows = []
            queuedCount = 0
            runningCount = 0
            cancellationRequestedCount = 0
            terminalCleanupIndeterminateCount = 0
            settledCount = 0
            reapedCount = 0
            omittedCount = 0
            return
        }

        isAvailable = true
        self.sourceIsCurrent = sourceIsCurrent
        let facts = workingState.agentHandles
        let classified = facts.map(Self.classify)
        rows = Array(classified
            .sorted {
                if $0.blocksWorkCompletion != $1.blocksWorkCompletion {
                    return $0.blocksWorkCompletion
                }
                if $0.status != $1.status {
                    return Self.rank($0.status) < Self.rank($1.status)
                }
                return $0.id < $1.id
            }
            .prefix(Self.maximumRows))
            .map(\.row)
        queuedCount = classified.filter { $0.row.status == .queued }.count
        runningCount = classified.filter { $0.row.status == .running }.count
        cancellationRequestedCount = classified.filter {
            $0.row.status == .cancellationRequested
        }.count
        terminalCleanupIndeterminateCount = classified.filter {
            $0.row.status == .terminalCleanupIndeterminate
        }.count
        settledCount = classified.filter { $0.row.status == .settled }.count
        reapedCount = classified.filter { $0.row.status == .reaped }.count
        omittedCount = max(0, workingState.omittedAgentHandleCount)
            + max(0, classified.count - Self.maximumRows)
    }

    public var hasRecords: Bool {
        isAvailable && (!rows.isEmpty || omittedCount > 0)
    }

    public var blockingCount: Int {
        queuedCount + runningCount + cancellationRequestedCount
            + terminalCleanupIndeterminateCount
    }

    public var summary: String {
        guard isAvailable else { return "Recorded background agents are unavailable in this view." }
        var parts: [String] = []
        if queuedCount > 0 { parts.append("\(queuedCount) recorded queued") }
        if runningCount > 0 { parts.append("\(runningCount) recorded running") }
        if cancellationRequestedCount > 0 {
            parts.append("\(cancellationRequestedCount) cancellation requested")
        }
        if terminalCleanupIndeterminateCount > 0 {
            parts.append("\(terminalCleanupIndeterminateCount) cleanup not confirmed")
        }
        if settledCount > 0 { parts.append("\(settledCount) settled") }
        if reapedCount > 0 { parts.append("\(reapedCount) resources released") }
        if omittedCount > 0 { parts.append("\(omittedCount) outside this view") }
        return parts.isEmpty ? "No recorded background agents in this view." : parts.joined(separator: " · ")
    }

    public var disclosure: String {
        let freshness = sourceIsCurrent ? "" : "The latest state is not confirmed. "
        return freshness
            + "These are recorded background-agent states. "
            + "They are not proof that a process is still running, that execution resumed, "
            + "or that a result is correct."
    }

    private struct Classified {
        let id: String
        let status: ChatAgentHandleActivityStatus
        let blocksWorkCompletion: Bool
        let row: ChatAgentHandleActivityRow
    }

    private static func classify(_ fact: LocalTimelineCatalog.AgentHandleFact) -> Classified {
        let id = "agent-handle-sha256:"
            + AviarySHA256.hash(data: Data(fact.handleID.utf8)).description
        let status: ChatAgentHandleActivityStatus
        switch fact.state {
        case .queued:
            status = .queued
        case .running:
            status = .running
        case .cancelRequested:
            status = .cancellationRequested
        case .reaped:
            status = .reaped
        case .terminal:
            if fact.cleanupState == .notStarted || fact.cleanupState == .quiesced {
                status = .settled
            } else {
                status = .terminalCleanupIndeterminate
            }
        }
        let row = ChatAgentHandleActivityRow(
            id: id, status: status,
            terminalOutcome: fact.terminalOutcome, cleanupState: fact.cleanupState)
        return Classified(
            id: id, status: status,
            blocksWorkCompletion: fact.blocksWorkCompletion
                || status == .terminalCleanupIndeterminate,
            row: row)
    }

    private static func rank(_ status: ChatAgentHandleActivityStatus) -> Int {
        switch status {
        case .queued: return 0
        case .running: return 1
        case .cancellationRequested: return 2
        case .terminalCleanupIndeterminate: return 3
        case .settled: return 4
        case .reaped: return 5
        }
    }
}
