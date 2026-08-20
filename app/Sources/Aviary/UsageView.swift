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
                label: "total tokens", value: Fmt.tokens(a.total.totalTokens),
                caption: "\(a.sessionCount) sessions", symbol: "number",
                tint: Design.accent, emphasis: true)
            Divider().frame(height: 46)
            StatTile(
                label: "attributed cost", value: Fmt.cost(a.total.cost.total),
                caption: a.costIsPartial ? "partial — see below" : "from provider pricing",
                symbol: "dollarsign.circle",
                tint: a.costIsPartial ? Design.warning : Design.success)
            Divider().frame(height: 46)
            StatTile(
                label: "cache hit rate", value: Fmt.percent(a.total.cacheHitRate),
                caption: "of all input tokens", symbol: "bolt.horizontal", tint: Design.tool)
            Divider().frame(height: 46)
            StatTile(
                label: "sub-agent tokens", value: Fmt.tokens(a.childTotal.totalTokens),
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
            title: "Cost here is a floor, not a bill",
            message: "\(model.analytics.sessionsWithoutPricing) session(s) used tokens but "
                + "reported no price. Subscription routes bill quota rather than dollars, and "
                + "some gateways return no pricing at all. Token counts are always real; "
                + "reconcile money against the provider's own billing.")
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
            if days.allSatisfy({ $0.usage.totalTokens == 0 }) {
                Text("No usage recorded in this window.")
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
            }
        }
    }

    private func metricValue(_ d: UsageAnalytics.DayPoint) -> Double {
        metric == .tokens ? Double(d.usage.totalTokens) : d.usage.cost.total
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
                                    ? Fmt.tokens(b.usage.totalTokens)
                                    : Fmt.cost(b.usage.cost.total))
                                    .font(Design.numeric(10.5, weight: .semibold))
                                    .frame(width: 62, alignment: .trailing)
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
                    value: a.total.totalTokens > 0
                        ? Fmt.percent(Double(a.total.output) / Double(a.total.totalTokens))
                        : "—")
                DetailRow(
                    label: "Sub-agent share",
                    value: a.total.totalTokens > 0
                        ? Fmt.percent(Double(a.childTotal.totalTokens)
                            / Double(a.total.totalTokens + a.childTotal.totalTokens))
                        : "—")
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
                                Text(Fmt.tokens(s.usage.totalTokens))
                                    .font(Design.numeric(11, weight: .semibold))
                                    .frame(width: 62, alignment: .trailing)
                                Text(Fmt.cost(s.usage.cost.total))
                                    .font(Design.numeric(10.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 62, alignment: .trailing)
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
