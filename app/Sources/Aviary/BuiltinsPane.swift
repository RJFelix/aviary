import SwiftUI
import Charts
import AppKit
import AviaryCore

/// The shelf inside the one tool.
///
/// Aviary offers the model exactly one tool — `python` — so everything else it can do arrives
/// as a name already bound in the namespace. That makes the list of those names the most
/// load-bearing thing in the whole product, and until now it was visible only by reading two
/// Swift files. This screen shows the list, the exact words the model is given for each name,
/// and how often anybody actually reached for it.
///
/// The last column is the point. A name that is described on every single request and called
/// by nobody is a standing token cost with nothing to show for it, and that is not a judgement
/// you can make from the source.
struct BuiltinsPane: View {
    @Environment(AppModel.self) private var model
    var search: String
    @Binding var selected: String?
    @Binding var window: Int

    private var entries: [Builtins.Entry] {
        let all = Builtins.all(.reference)
        let q = search.lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q)
                || $0.bullet.lowercased().contains(q)
        }
    }

    /// Grouped by what has to be true for the name to be bound, because that is the question
    /// a reader is actually asking: not "what exists" but "what does *this* run have".
    private struct RequirementGroup: Sendable {
        var requirement: Builtins.Requirement
        var entries: [Builtins.Entry]
    }

    private var groups: [RequirementGroup] {
        Builtins.Requirement.allCases.compactMap { requirement in
            let matching = entries.filter { $0.requirement == requirement }
            return matching.isEmpty ? nil : RequirementGroup(requirement: requirement, entries: matching)
        }
    }

    private var current: Builtins.Entry? {
        entries.first { $0.name == selected } ?? entries.first
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 520)
            Group {
                if let entry = current {
                    BuiltinDetail(
                        entry: entry,
                        usage: model.libraryUsage.builtin(named: entry.name),
                        scanned: model.libraryUsageScanned,
                        corpus: model.libraryUsage,
                        skills: model.builtinIndex.skills(for: entry.name),
                        window: $window)
                } else {
                    EmptyStateView(
                        symbol: "curlybraces",
                        title: "No builtin matches",
                        message: "Every name the agent finds already bound in its Python "
                            + "namespace is listed here.")
                }
            }
            .frame(minWidth: 380)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            corpusStrip
            Divider()
            List(selection: $selected) {
                ForEach(groups, id: \.requirement) { group in
                    // Qualified: the app has its own `Section` for navigation, and an
                    // unqualified one here resolves to that instead of SwiftUI's.
                    SwiftUI.Section(header: Text(group.requirement.label.uppercased())
                        .font(Design.sectionTitle).tracking(0.6))
                    {
                        ForEach(group.entries) { entry in
                            row(entry).tag(entry.name)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private func row(_ entry: Builtins.Entry) -> some View {
        let series = model.libraryUsage.builtin(named: entry.name)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.signature)
                    .font(Design.mono(11.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let series, series.calls > 0 {
                    Text("\(series.calls)")
                        .font(Design.numeric(10, weight: .semibold))
                        .foregroundStyle(Design.accent)
                } else if model.libraryUsageScanned {
                    Text("unused")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Text(entry.summary)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Chip(text: entry.mechanism.label,
                     symbol: entry.mechanism == .kernel ? "cube" : "arrow.left.arrow.right",
                     tint: entry.mechanism == .kernel ? Design.tool : Design.assistant)
                Spacer()
            }
        }
        .padding(.vertical, 3)
    }

    /// Every number on this screen is a fraction of this, so it goes at the top rather than in
    /// a footnote: an empty chart means "nobody called it", not "the scan is broken".
    private var corpusStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            if model.libraryUsageScanned {
                Text("\(model.libraryUsage.cellsScanned) cells · "
                    + "\(model.libraryUsage.transcriptsScanned) transcripts · "
                    + "\(Int(model.libraryUsage.scanDuration * 1000))ms")
                    .font(Design.numeric(9.5)).foregroundStyle(.secondary)
            } else {
                Text("reading trajectories…")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

// MARK: - Detail

private struct BuiltinDetail: View {
    var entry: Builtins.Entry
    var usage: LibraryUsage.Series?
    var scanned: Bool
    var corpus: LibraryUsage
    var skills: [String]
    @Binding var window: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                // The exact string, not a paraphrase. The whole reason this screen exists is
                // that these words are the model's only evidence the name is there at all.
                Card("What the model is told", symbol: "text.quote") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("  " + entry.bullet)
                            .font(Design.mono(11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let note = entry.note {
                            Text(note)
                                .font(Design.mono(11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Shared by every builtin in the \(entry.requirement.label) "
                                + "group — it is rendered once, after their lines.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }

                Card("Availability", symbol: "switch.2") {
                    Text(entry.requirement.explanation)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                usageCard
                skillsCard
            }
            .padding(Design.gutter)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(entry.signature).font(Design.mono(16, weight: .semibold))
                Spacer()
            }
            Text(entry.summary)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Chip(text: entry.requirement.label, tint: Design.accent)
                Chip(text: entry.mechanism.label,
                     symbol: entry.mechanism == .kernel ? "cube" : "arrow.left.arrow.right",
                     tint: entry.mechanism == .kernel ? Design.tool : Design.assistant)
                if let usage, let last = usage.lastUsed {
                    Chip(text: "last used \(Fmt.ago(last))", tint: .secondary)
                }
                Spacer()
            }
        }
    }

    private var usageCard: some View {
        Card("Use", symbol: "chart.bar.xaxis",
             accessory: AnyView(WindowPicker(window: $window)))
        {
            VStack(alignment: .leading, spacing: 10) {
                if !scanned {
                    Text("Reading the trajectories…")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .frame(height: 120)
                } else if let usage, usage.wasEverUsed {
                    UsageChart(days: usage.days(last: window), tint: Design.accent)
                    HStack(spacing: 14) {
                        Stat(label: "calls", value: "\(usage.calls)")
                        Stat(label: "cells", value: "\(usage.cells)")
                        Stat(label: "sessions", value: "\(usage.sessions)")
                        Spacer()
                    }
                    Text("A call is a textual call site in a cell's source, so a mention "
                        + "inside a string or comment counts too — an upper bound, not an "
                        + "invocation count.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Never called.")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("Described on every request that has it, across "
                            + "\(corpus.cellsScanned) cells of history, and reached for by "
                            + "nobody. Either the wording is not doing its job or the "
                            + "capability is not wanted.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var skillsCard: some View {
        Card("Skills that reference it", symbol: "wand.and.stars") {
            if skills.isEmpty {
                Text("No skill on disk mentions `\(entry.name)`. Skills written for another "
                    + "runtime's namespace teach names Aviary never binds, which is the same "
                    + "failure as an undescribed builtin seen from the other side.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(skills, id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 9)).foregroundStyle(Design.accent)
                            Text(name).font(.system(size: 11.5, weight: .medium))
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// One builtin's or skill's use over time.
///
/// Dense rather than sparse: the gaps are the information. A bar chart of only the days that
/// had activity would make three calls spread over a month look like a habit.
struct UsageChart: View {
    var days: [LibraryUsage.Day]
    var tint: Color
    var height: CGFloat = 120

    /// A day-wide bar centred on its day runs half a day past each end of the data, so the
    /// domain has to as well or today's bar is drawn sliced in half against the axis.
    private var domain: ClosedRange<Date> {
        let half: TimeInterval = 12 * 60 * 60
        guard let first = days.first?.day, let last = days.last?.day else {
            let now = Date()
            return now.addingTimeInterval(-half)...now.addingTimeInterval(half)
        }
        return first.addingTimeInterval(-half)...last.addingTimeInterval(half)
    }

    var body: some View {
        Chart(days) { d in
            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Calls", d.count))
                .foregroundStyle(tint.gradient)
                .cornerRadius(1.5)
        }
        .chartXScale(domain: domain)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)").font(.system(size: 9)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, days.count / 7))) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    .font(.system(size: 9))
            }
        }
        .frame(height: height)
    }
}

struct WindowPicker: View {
    @Binding var window: Int

    var body: some View {
        Picker("", selection: $window) {
            Text("14d").tag(14)
            Text("30d").tag(30)
            Text("90d").tag(90)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .frame(width: 120)
    }
}

private struct Stat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Design.numeric(15, weight: .semibold))
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}
