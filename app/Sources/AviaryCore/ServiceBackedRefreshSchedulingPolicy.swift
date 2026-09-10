import Foundation

/// Pure timer-poll scheduling for attached Work-service rows.
///
/// Explicit refresh remains outside this policy and observes every row immediately. Background
/// callers mark rows that need prompt reconciliation; quiescent rows and catalog discovery are
/// sampled less often. The state contains only opaque process-local row keys and timestamps.
public enum ServiceBackedRefreshSchedulingPolicy {
    public static let promptInterval: TimeInterval = 1.5
    public static let quiescentInterval: TimeInterval = 12
    public static let maximumRowsPerPass = 32

    public struct Candidate: Hashable, Sendable {
        public let key: String
        public let needsPromptRefresh: Bool

        public init(key: String, needsPromptRefresh: Bool) {
            self.key = key
            self.needsPromptRefresh = needsPromptRefresh
        }
    }

    public struct State: Hashable, Sendable {
        fileprivate var lastRefreshByKey: [String: Date]
        fileprivate var lastCatalogRefresh: Date?
        fileprivate var rotationOffset: Int

        public init() {
            lastRefreshByKey = [:]
            lastCatalogRefresh = nil
            rotationOffset = 0
        }
    }

    public struct Plan: Hashable, Sendable {
        public let selectedKeys: [String]
        public let refreshCatalog: Bool
        public let state: State

        fileprivate init(selectedKeys: [String], refreshCatalog: Bool, state: State) {
            self.selectedKeys = selectedKeys
            self.refreshCatalog = refreshCatalog
            self.state = state
        }
    }

    /// Select one bounded background pass using an injected clock value.
    ///
    /// Rows are ordered by how many of their own cadence intervals have elapsed. This keeps the
    /// prompt lane responsive under its normal bound while allowing overdue quiescent rows to
    /// participate when the row count exceeds the per-pass budget. Stable rotation resolves ties
    /// without relying on dictionary order.
    public static func plan(
        candidates: [Candidate],
        now: Date,
        previous: State,
        forceCatalogRefresh: Bool = false,
        maximumRows: Int = maximumRowsPerPass
    ) -> Plan {
        let unique = deduplicated(candidates)
        let keys = Set(unique.map(\.key))
        var state = previous
        state.lastRefreshByKey = state.lastRefreshByKey.filter { keys.contains($0.key) }
        guard !unique.isEmpty else {
            state.rotationOffset = 0
            let catalogDue = forceCatalogRefresh
                || isDue(last: state.lastCatalogRefresh, now: now, interval: quiescentInterval)
            if catalogDue { state.lastCatalogRefresh = now }
            return Plan(selectedKeys: [], refreshCatalog: catalogDue, state: state)
        }

        let offset = normalized(state.rotationOffset, count: unique.count)
        let ranked = unique.enumerated().compactMap { index, candidate
            -> (candidate: Candidate, urgency: Double, rotatedIndex: Int)? in
            let interval = candidate.needsPromptRefresh ? promptInterval : quiescentInterval
            guard let urgency = urgency(
                last: state.lastRefreshByKey[candidate.key], now: now, interval: interval)
            else { return nil }
            let rotatedIndex = normalized(index - offset, count: unique.count)
            return (candidate, urgency, rotatedIndex)
        }.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            return lhs.rotatedIndex < rhs.rotatedIndex
        }
        let limit = max(0, maximumRows)
        let selected = ranked.prefix(limit).map(\.candidate)
        for candidate in selected {
            state.lastRefreshByKey[candidate.key] = now
        }
        state.rotationOffset = normalized(offset + selected.count, count: unique.count)

        let catalogDue = forceCatalogRefresh
            || isDue(last: state.lastCatalogRefresh, now: now, interval: quiescentInterval)
        if catalogDue { state.lastCatalogRefresh = now }
        return Plan(
            selectedKeys: selected.map(\.key), refreshCatalog: catalogDue, state: state)
    }

    /// Record an explicit all-scope refresh so the next timer pass does not immediately repeat it.
    public static func recordingExplicitRefresh(
        candidates: [Candidate], now: Date, previous: State
    ) -> State {
        let unique = deduplicated(candidates)
        let keys = Set(unique.map(\.key))
        var state = previous
        state.lastRefreshByKey = state.lastRefreshByKey.filter { keys.contains($0.key) }
        for candidate in unique { state.lastRefreshByKey[candidate.key] = now }
        state.lastCatalogRefresh = now
        state.rotationOffset = unique.isEmpty
            ? 0 : normalized(state.rotationOffset, count: unique.count)
        return state
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var positions: [String: Int] = [:]
        var result: [Candidate] = []
        for candidate in candidates {
            if let position = positions[candidate.key] {
                if candidate.needsPromptRefresh && !result[position].needsPromptRefresh {
                    result[position] = candidate
                }
            } else {
                positions[candidate.key] = result.count
                result.append(candidate)
            }
        }
        return result
    }

    private static func urgency(
        last: Date?, now: Date, interval: TimeInterval
    ) -> Double? {
        guard let last else { return .infinity }
        let elapsed = now.timeIntervalSince(last)
        // A wall-clock correction must not strand a row behind a future timestamp.
        if elapsed < 0 { return .infinity }
        guard elapsed >= interval else { return nil }
        return elapsed / interval
    }

    private static func isDue(
        last: Date?, now: Date, interval: TimeInterval
    ) -> Bool {
        urgency(last: last, now: now, interval: interval) != nil
    }

    private static func normalized(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = value % count
        return remainder >= 0 ? remainder : remainder + count
    }
}
