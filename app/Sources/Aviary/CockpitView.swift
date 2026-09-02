import SwiftUI
import AviaryCore

/// The landing screen is a working set, not a second analytics dashboard. The rail is every
/// run Aviary currently owns; selecting one keeps its shared transcript and composer in view.
struct CockpitView: View {
    @Environment(AppModel.self) private var model
    /// Selected like a run, not sheet-presented: the New Session card lives in the same rail
    /// as every other run, and choosing it fills the same detail pane a run's chat would use
    /// rather than opening a modal over it. See `NewSessionPane`.
    @State private var composingNewSession = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                runRail
                    .frame(width: geo.size.width / 3)
                Divider()
                detail
                    .frame(width: geo.size.width * 2 / 3 - 1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var ongoingRuns: [LiveRun] {
        // An exited run is still valuable on Live until dismissed, but it is no longer an
        // ongoing conversation. Keep the front page about work that can receive a message.
        model.runs.filter { !$0.hasExited }
    }

    private var selectedRun: LiveRun? {
        if let focused = model.focusedRunID,
           let run = ongoingRuns.first(where: { $0.id == focused })
        {
            return run
        }
        return ongoingRuns.first
    }

    /// A run card reads as selected only when it is actually what's showing in the detail
    /// pane. Without this, an old selection would still look highlighted while the New
    /// Session card is the one open — two cards claiming the same state at once.
    private func isShowing(_ run: LiveRun) -> Bool {
        !composingNewSession && run.id == selectedRun?.id
    }

    private var runRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ONGOING")
                        .font(Design.sectionTitle).tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ongoingRuns.count)")
                        .font(Design.numeric(10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.top, 12)

                ForEach(ongoingRuns) { run in
                    RunRailCard(run: run, selected: isShowing(run)) {
                        model.focusedRunID = run.id
                        composingNewSession = false
                    }
                }

                NewRunRailCard(selected: composingNewSession) {
                    composingNewSession = true
                }
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 12)
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private var detail: some View {
        if composingNewSession {
            NewSessionPane(onStart: { composingNewSession = false },
                            onCancel: { composingNewSession = false })
        } else if let run = selectedRun {
            // Live keeps its optional diagnostics inspector. Cockpit promises chat space.
            RunPane(run: run, showsInspector: false)
        } else {
            EmptyStateView(
                symbol: "plus.bubble",
                title: "Start a session",
                message: "Your ongoing sessions appear in the left rail. Start one here, then "
                    + "its chat and Markdown-aware composer stay on this page.")
        }
    }
}

/// Cockpit's inline replacement for opening `LauncherSheet` over the window: the same
/// `LauncherFormBody`, given the detail pane's width instead of a modal's fixed frame, with a
/// header that reads "cancel back to whatever was selected" rather than "dismiss".
private struct NewSessionPane: View {
    var onStart: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("New session", systemImage: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            LauncherFormBody(onStart: onStart)
        }
    }
}

private struct RunRailCard: View {
    let run: LiveRun
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if run.isStreaming {
                        PulseDot()
                    } else {
                        Circle().fill(Design.accent.opacity(0.75)).frame(width: 7, height: 7)
                    }
                    Text(run.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Text(run.projectName).foregroundStyle(Design.accent)
                    if let model = run.modelLabel, !model.isEmpty {
                        Text(model).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                HStack {
                    Text(run.isStreaming ? "working" : "ready")
                        .foregroundStyle(run.isStreaming ? Design.success : .secondary)
                    Spacer()
                    Text(Fmt.duration(run.elapsed))
                }
                .font(Design.numeric(9.5))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Design.accentSoft) : AnyShapeStyle(.background)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected
                        ? AnyShapeStyle(Design.accent.opacity(0.7))
                        : AnyShapeStyle(.separator.opacity(0.55)),
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct NewRunRailCard: View {
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("New session")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(Design.accent)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Design.accentSoft : Design.accentSoft.opacity(0.45)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    // Dashed while idle, like an empty slot; solid once it's the one open in
                    // the detail pane, matching the selected treatment `RunRailCard` uses.
                    .strokeBorder(Design.accent.opacity(selected ? 0.85 : 0.5),
                        style: StrokeStyle(lineWidth: 1, dash: selected ? [] : [4, 3])))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rows

// `LiveSessionRow` lived here: a row describing a session the harness daemon was holding,
// with a lease, a worker and an attached-client count. Aviary runs its agents in-process, so
// a live run is simply one of `runs` — `RunRailCard` above is the whole of it now.

struct SessionRow: View {
    var session: SessionSummary
    /// Optional canonical projection supplied by the Sessions list. Cockpit rows remain
    /// compatible with live-only summaries until its consumer migrates.
    var canonical: CanonicalSessionCatalogSummary? = nil
    var compact: Bool = false

    private var canonicalIsProven: Bool {
        canonical?.sessionStructuralIntegrityValid == true
            && canonical?.sessionSemanticProjectionValid == true
            && canonical?.unknownDomains.contains(.session) == false
            && canonical?.unknownDomains.contains(.work) == false
    }

    private var projectedLive: Bool? {
        guard let canonical else { return session.isLive }
        guard canonicalIsProven else { return nil }
        return canonical.work.contains {
            $0.canProjectExecution && $0.lifecycle == .active
        }
    }

    private var projectedBusy: Bool? {
        guard let canonical else { return session.isBusy }
        guard canonicalIsProven else { return nil }
        return canonical.work.contains {
            $0.canProjectExecution
                && [.preparing, .running, .canceling].contains($0.execution)
        }
    }

    private var rowTitle: String {
        if let title = canonical?.title, !title.isEmpty { return title }
        return session.title
    }

    private var rowModel: String? {
        guard let canonical else { return session.model }
        guard canonicalIsProven else {
            return canonical.sessionSemanticProjectionValid ? nil : session.model
        }
        return canonical.sessionModelID
            ?? (canonical.modelIDs.count == 1 ? canonical.modelIDs.first : nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                if projectedBusy == true {
                    PulseDot(color: Design.success)
                } else if projectedLive == true {
                    Circle().fill(Design.accent.opacity(0.8)).frame(width: 7, height: 7)
                } else if projectedLive == nil {
                    Circle().stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                        .frame(width: 7, height: 7)
                        .overlay(Text("?").font(.system(size: 6, weight: .bold)))
                } else {
                    Circle().fill(Color.secondary.opacity(0.22)).frame(width: 7, height: 7)
                }
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Design.accent)
                    if let b = session.gitBranch {
                        Label(b, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .labelStyle(.titleAndIcon)
                    }
                    if session.isCanonicalOnly {
                        Text("metadata partial")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(Fmt.ago(session.updatedAt))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                if !compact {
                    HStack(spacing: 5) {
                        if let m = rowModel {
                            Chip(text: m, symbol: "cpu", tint: Design.assistant)
                        }
                        if !session.isCanonicalOnly, session.counts.toolCalls > 0 {
                            Chip(text: "\(session.counts.toolCalls) tools", tint: Design.tool)
                        }
                        if !session.isCanonicalOnly, session.counts.toolErrors > 0 {
                            Chip(text: "\(session.counts.toolErrors) errors", tint: Design.danger)
                        }
                        if !session.isCanonicalOnly, session.childCount > 0 {
                            Chip(text: "\(session.childCount) sub-agents", symbol: "bird",
                                 tint: Design.agentMessage)
                        }
                        if !session.isCanonicalOnly, session.counts.compactions > 0 {
                            Chip(text: "\(session.counts.compactions)×compact",
                                 tint: Design.warning)
                        }
                    }
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                if session.isCanonicalOnly {
                    Text("—")
                        .font(Design.numeric(11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(Fmt.tokens(session.usage.totalTokens))
                        .font(Design.numeric(11, weight: .semibold))
                    if session.usage.cost.total > 0 {
                        Text(Fmt.cost(session.usage.cost.total))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    } else if session.counts.assistant > 0 {
                        Text("\(session.counts.assistant) turns")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, compact ? 5 : 7)
        .contentShape(Rectangle())
    }
}
