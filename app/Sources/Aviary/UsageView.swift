import SwiftUI
import Charts
import AviaryCore

/// Token and cost analytics across every session on disk.
///
/// The harness reports usage per session and nothing rolls it up, so the questions that
/// actually matter — which model is spending the money, whether the cache is earning its
/// keep, how much a fan-out of sub-agents added on top of its parent — have no answer in
/// the terminal. They are all already in the transcripts.
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var window = 30
    @State private var breakdown: Breakdown = .model
    @State private var metric: Metric = .tokens

    enum Breakdown: String, CaseIterable {
        case model = "By model"
        case provider = "By provider"
        case project = "By project"
    }

    enum Metric: String, CaseIterable {
        case tokens = "Tokens"
        case cost = "Cost"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headline
                if model.analytics.costIsPartial { pricingCaveat }
                trendCard
                HStack(alignment: .top, spacing: 14) {
                    breakdownCard
                    efficiencyCard
                }
                heaviestSessions
            }
            .padding(Design.gutter)
        }
    }

    // MARK: Headline

    private var headline: some View {
        let a = model.analytics
        return HStack(spacing: 14) {
            StatTile(
                label: "token count", value: Fmt.tokens(a.total),
                caption: "\(a.sessionCount) sessions", symbol: "number",
                tint: Design.accent, emphasis: true)
            Divider().frame(height: 46)
            StatTile(
                label: "cost estimate", value: Fmt.cost(a.total),
                caption: a.sessionCount == 0 ? "no usage reports"
                    : a.total.isCostComplete ? "complete configured estimate"
                    : "incomplete estimates — see below",
                symbol: "dollarsign.circle",
                tint: a.costIsPartial ? Design.warning : Design.success)
            Divider().frame(height: 46)
            StatTile(
                label: "cache hit rate", value: Fmt.percent(a.total.cacheHitRate),
                caption: "of all input tokens", symbol: "bolt.horizontal", tint: Design.tool)
            Divider().frame(height: 46)
            StatTile(
                label: "sub-agent tokens", value: Fmt.tokens(a.childTotal),
                caption: "folded into parents", symbol: "bird.fill", tint: Design.agentMessage)
            Divider().frame(height: 46)
            StatTile(
                label: "tool calls", value: Fmt.tokens(a.toolCallCount),
                caption: a.toolErrorRate.map { "\(Fmt.percent($0)) errored" } ?? "—",
                symbol: "terminal.fill", tint: Design.tool)
        }
        .padding(Design.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1))
    }

    private var pricingCaveat: some View {
        NoticeBanner(
            level: .info,
            title: "Recorded cost estimates, not a bill",
            message: "\(model.analytics.sessionsWithIncompleteCost) session(s) have incomplete "
                + "or unclassified pricing; \(model.analytics.sessionsWithoutPricing) contribute "
                + "no known dollars. Values marked ≥ are known lower bounds; values marked "
                + "reported are unclassified historical estimates. Reconcile all money against "
                + "the provider's own billing.")
    }

    // MARK: Trend

    private var trendCard: some View {
        Card("Trend", symbol: "chart.xyaxis.line",
             accessory: AnyView(
                HStack(spacing: 6) {
                    Picker("", selection: $metric) {
                        ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .frame(width: 130)
                    Picker("", selection: $window) {
                        Text("14d").tag(14)
                        Text("30d").tag(30)
                        Text("90d").tag(90)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .frame(width: 120)
                }))
        {
            let days = model.analytics.days(last: window)
            if days.allSatisfy({ metricValue($0) == 0 }) {
                Text(trendEmptyMessage(days))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(height: 160)
            } else {
                Chart(days) { d in
                    BarMark(
                        x: .value("Day", d.day, unit: .day),
                        y: .value(metric.rawValue, metricValue(d)))
                        .foregroundStyle(Design.accent.gradient)
                        .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(metric == .tokens ? Fmt.tokens(Int(v)) : Fmt.cost(v))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, window / 8))) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                                       centered: true)
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 172)
                if days.contains(where: {
                    $0.sessions > 0 && !metricIsComplete($0.usage)
                }) {
                    Text("Bars show recorded estimates. Some daily values are incomplete or "
                        + "unclassified; they are not billing totals or evidence of free usage.")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
            Text("Days are session-attributed by each session's last update.")
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }

    private func metricValue(_ d: UsageAnalytics.DayPoint) -> Double {
        metric == .tokens ? Double(d.usage.totalTokens) : d.usage.cost.total
    }

    private func metricIsComplete(_ usage: Usage) -> Bool {
        metric == .tokens ? usage.isTokenTotalComplete : usage.isCostComplete
    }

    private func trendEmptyMessage(_ days: [UsageAnalytics.DayPoint]) -> String {
        let hasIncompleteSession = days.contains {
            $0.sessions > 0 && !metricIsComplete($0.usage)
        }
        if hasIncompleteSession {
            return metric == .tokens
                ? "No recorded token estimate is available in this window."
                : "No recorded cost estimate is available in this window."
        }
        return metric == .tokens
            ? "No token usage recorded in this window."
            : "No nonzero cost recorded in this window."
    }

    // MARK: Breakdown

    private var breakdownCard: some View {
        Card("Breakdown", symbol: "chart.pie",
             accessory: AnyView(
                Picker("", selection: $breakdown) {
                    ForEach(Breakdown.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small).frame(width: 122)))
        {
            let buckets = Array(currentBuckets.prefix(12))
            Text(breakdownAttribution)
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            if buckets.isEmpty {
                Text("Nothing to break down yet.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                let peak = max(1, buckets.map { bucketValue($0) }.max() ?? 1)
                VStack(spacing: 6) {
                    ForEach(buckets) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(b.key)
                                    .font(Design.mono(10.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text("\(b.sessions) sess")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                Text(metric == .tokens
                                    ? Fmt.tokens(b.usage)
                                    : Fmt.cost(b.usage))
                                    .font(Design.numeric(10.5, weight: .semibold))
                                    .frame(minWidth: 104, alignment: .trailing)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            RatioBar(fraction: bucketValue(b) / peak, tint: Design.accent, height: 4)
                        }
                    }
                }
            }
        }
    }

    private var currentBuckets: [UsageAnalytics.Bucket] {
        let base: [UsageAnalytics.Bucket]
        switch breakdown {
        case .model: base = model.analytics.byModel
        case .provider: base = model.analytics.byProvider
        case .project: base = model.analytics.byProject
        }
        return base.sorted { bucketValue($0) > bucketValue($1) }
    }

    private var breakdownAttribution: String {
        switch breakdown {
        case .model:
            return "Usage is session-attributed to each session's latest model."
        case .provider:
            return "Usage is session-attributed to each session's latest provider."
        case .project:
            return "Usage is session-attributed to each session's project."
        }
    }

    private func bucketValue(_ b: UsageAnalytics.Bucket) -> Double {
        metric == .tokens ? Double(b.usage.totalTokens) : b.usage.cost.total
    }

    // MARK: Efficiency

    private var efficiencyCard: some View {
        Card("Efficiency", symbol: "gauge.with.dots.needle.bottom.50percent") {
            let a = model.analytics
            VStack(alignment: .leading, spacing: 11) {
                gauge(
                    label: "Cache hit rate",
                    value: a.total.cacheHitRate,
                    tint: Design.tool,
                    note: "Share of input tokens served from cache. A long agent session "
                        + "re-sends its whole context every turn, so this is the single "
                        + "largest lever on cost.")
                gauge(
                    label: "Tool error rate",
                    value: a.toolErrorRate,
                    tint: Design.danger,
                    invert: true,
                    note: "\(a.toolErrorCount) of \(a.toolCallCount) tool calls returned an "
                        + "error. Some of that is the agent probing; a lot of it is a broken "
                        + "environment.")

                Divider().opacity(0.5)

                DetailRow(label: "Compactions", value: "\(a.compactionCount)")
                DetailRow(label: "Agent messages", value: "\(a.agentMessageCount)")
                DetailRow(
                    label: "Output share",
                    value: a.total.isTokenTotalComplete && a.total.isBreakdownComplete
                        && a.total.totalTokens > 0
                        ? Fmt.percent(Double(a.total.output) / Double(a.total.totalTokens))
                        : "—")
                DetailRow(
                    label: "Sub-agent share",
                    value: Fmt.percent(a.subagentShare))
            }
        }
        .frame(width: 340)
    }

    private func gauge(
        label: String, value: Double?, tint: Color, invert: Bool = false, note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(Fmt.percent(value))
                    .font(Design.numeric(12, weight: .semibold))
                    .foregroundStyle(value == nil ? .secondary : tint)
            }
            RatioBar(fraction: value ?? 0, tint: tint, height: 6)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Heaviest

    private var heaviestSessions: some View {
        Card("Heaviest sessions", symbol: "flame") {
            let top = model.sessions
                .sorted {
                    metric == .tokens
                        ? $0.usage.totalTokens > $1.usage.totalTokens
                        : $0.usage.cost.total > $1.usage.cost.total
                }
                .prefix(12)
            if top.isEmpty {
                Text("No sessions yet.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(top)) { s in
                        Button {
                            model.section = .sessions
                            model.select(session: s)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title).font(.system(size: 11.5)).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(s.projectName)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(Design.accent)
                                        if let m = s.model {
                                            Text(m).font(Design.mono(9))
                                                .foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        Text(Fmt.ago(s.updatedAt))
                                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer(minLength: 6)
                                if s.childCount > 0 {
                                    Chip(text: "\(s.childCount)", symbol: "bird",
                                         tint: Design.agentMessage)
                                }
                                Text(Fmt.tokens(s.usage))
                                    .font(Design.numeric(11, weight: .semibold))
                                    .frame(minWidth: 104, alignment: .trailing)
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(Fmt.cost(s.usage))
                                    .font(Design.numeric(10.5))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 104, alignment: .trailing)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if s.id != top.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }
}
