import Foundation

/// Aggregate token and cost analytics over the session catalog.
///
/// The harness reports usage per session; nothing rolls it up. But the interesting
/// questions are all cross-session — which model is actually costing money, whether the
/// cache is working, how much a fan-out of sub-agents added on top of the parent's own
/// spend. All of it is already in the transcripts.
///
/// One honest caveat the UI repeats: cost is whatever the provider's catalog entry said at
/// the time, and several routes report zero (OAuth subscription routes bill quota, not
/// dollars; some gateways don't return pricing at all). Token counts are always real.
public struct UsageAnalytics: Sendable {
    public init() {}

    public struct Bucket: Sendable, Identifiable, Hashable {
        public var id: String { key }
        public var key: String
        public var usage: Usage
        public var sessions: Int
        public var messages: Int
    }

    public struct DayPoint: Sendable, Identifiable, Hashable {
        public var id: Date { day }
        public var day: Date
        public var usage: Usage
        public var sessions: Int
    }

    public var total = Usage()
    public var childTotal = Usage()
    public var byModel: [Bucket] = []
    public var byProvider: [Bucket] = []
    public var byProject: [Bucket] = []
    public var byDay: [DayPoint] = []
    public var sessionCount = 0
    public var toolCallCount = 0
    public var toolErrorCount = 0
    public var agentMessageCount = 0
    public var compactionCount = 0
    /// Sessions whose model reported no pricing at all — the reason a cost total can look
    /// implausibly low.
    public var sessionsWithoutPricing = 0

    public var costIsPartial: Bool { sessionsWithoutPricing > 0 }

    public var toolErrorRate: Double? {
        guard toolCallCount > 0 else { return nil }
        return Double(toolErrorCount) / Double(toolCallCount)
    }

    public static func build(from sessions: [SessionSummary], calendar: Calendar = .current) -> UsageAnalytics {
        var a = UsageAnalytics()
        var models: [String: Bucket] = [:]
        var providers: [String: Bucket] = [:]
        var projects: [String: Bucket] = [:]
        var days: [Date: DayPoint] = [:]

        for s in sessions {
            a.sessionCount += 1
            a.total += s.usage
            a.childTotal += s.childUsage
            a.toolCallCount += s.counts.toolCalls
            a.toolErrorCount += s.counts.toolErrors
            a.agentMessageCount += s.counts.agentMessages
            a.compactionCount += s.counts.compactions
            if s.usage.totalTokens > 0, s.usage.cost.total == 0 { a.sessionsWithoutPricing += 1 }

            let modelKey = s.model ?? "unknown"
            var mb = models[modelKey] ?? Bucket(key: modelKey, usage: Usage(), sessions: 0, messages: 0)
            mb.usage += s.usage
            mb.sessions += 1
            mb.messages += s.counts.assistant
            models[modelKey] = mb

            let providerKey = s.provider ?? "unknown"
            var pb = providers[providerKey]
                ?? Bucket(key: providerKey, usage: Usage(), sessions: 0, messages: 0)
            pb.usage += s.usage
            pb.sessions += 1
            pb.messages += s.counts.assistant
            providers[providerKey] = pb

            let projectKey = s.cwd.isEmpty ? "—" : s.projectName
            var jb = projects[projectKey]
                ?? Bucket(key: projectKey, usage: Usage(), sessions: 0, messages: 0)
            jb.usage += s.usage
            jb.sessions += 1
            jb.messages += s.counts.assistant
            projects[projectKey] = jb

            let day = calendar.startOfDay(for: s.updatedAt)
            var dp = days[day] ?? DayPoint(day: day, usage: Usage(), sessions: 0)
            dp.usage += s.usage
            dp.sessions += 1
            days[day] = dp
        }

        a.byModel = models.values.sorted { $0.usage.totalTokens > $1.usage.totalTokens }
        a.byProvider = providers.values.sorted { $0.usage.totalTokens > $1.usage.totalTokens }
        a.byProject = projects.values.sorted { $0.usage.totalTokens > $1.usage.totalTokens }
        a.byDay = days.values.sorted { $0.day < $1.day }
        return a
    }

    /// Trailing-window slice, for "last 14 days" style charts.
    public func days(last n: Int, calendar: Calendar = .current) -> [DayPoint] {
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(n - 1), to: today) else { return byDay }
        var index = Dictionary(uniqueKeysWithValues: byDay.map { ($0.day, $0) })
        var out: [DayPoint] = []
        var cursor = start
        while cursor <= today {
            out.append(index[cursor] ?? DayPoint(day: cursor, usage: Usage(), sessions: 0))
            index.removeValue(forKey: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}

// MARK: - Formatting

/// Number formatting used across the app. Centralised so a token count reads the same in
/// a chart axis, a table cell, and a tooltip.
public enum Fmt {
    public static func tokens(_ n: Int) -> String {
        switch abs(n) {
        case 0: return "0"
        case 1..<1_000: return "\(n)"
        case 1_000..<1_000_000:
            return String(format: "%.1fK", Double(n) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        case 1_000_000..<1_000_000_000:
            return String(format: "%.2fM", Double(n) / 1_000_000)
        default:
            return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }

    public static func cost(_ d: Double) -> String {
        if d == 0 { return "—" }
        if d < 0.01 { return String(format: "$%.4f", d) }
        if d < 1 { return String(format: "$%.3f", d) }
        if d < 1_000 { return String(format: "$%.2f", d) }
        return String(format: "$%.0f", d)
    }

    public static func percent(_ f: Double?) -> String {
        guard let f else { return "—" }
        return String(format: "%.0f%%", f * 100)
    }

    public static func duration(_ t: TimeInterval?) -> String {
        guard let t, t > 0 else { return "—" }
        if t < 1 { return String(format: "%.0fms", t * 1000) }
        if t < 60 { return String(format: "%.1fs", t) }
        if t < 3600 { return "\(Int(t / 60))m \(Int(t) % 60)s" }
        let h = Int(t / 3600), m = (Int(t) % 3600) / 60
        return "\(h)h \(m)m"
    }

    public static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    public static func ago(_ date: Date?) -> String {
        guard let date, date > .distantPast else { return "—" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    public static func day(_ d: Date) -> String { dayFormatter.string(from: d) }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    public static func timestamp(_ d: Date) -> String {
        guard d > .distantPast else { return "—" }
        return timestampFormatter.string(from: d)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }

    /// Context-window pressure as a share, when both numbers are known.
    public static func contextShare(used: Int, window: Int?) -> Double? {
        guard let window, window > 0 else { return nil }
        return min(1, Double(used) / Double(window))
    }
}
