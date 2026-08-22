import SwiftUI
import AppKit
import AviaryCore

/// The landing screen: what is happening right now, what just happened, and anything
/// that needs a decision.
///
/// Ordered by urgency rather than by category. A wedged daemon or an unresolvable
/// credential goes above the pretty numbers, because those are the states that stop work.
struct CockpitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                notices
                headline
                // `workingNow` is deliberately not shown — it lists sessions the harness
                // daemon is holding, which the in-house engine does not have. Retired rather
                // than deleted; see docs/architecture.md, "Retired daemon surfaces".
                // Re-balanced after `workingNow` retired: the chart is paired with the
                // launcher so both rows sit on the same two-column grid.
                //
                // This row is still narrower than the one below it, and the cause is measured
                // rather than guessed. `Card` is already `maxWidth: .infinity`, so it is not
                // that the card refuses to stretch — a `GeometryReader` probe showed the
                // second row being re-offered the full width and growing (380 → 800, row
                // 724 → 1144) while this row never fires `onChange` at all: it keeps its
                // first-pass 724 and is never re-offered. Left for a layout pass; four
                // attempts at fixing it by adding `maxWidth` frames only moved the dead space
                // around, because the frames were treating a proposal problem as a sizing one.
                HStack(alignment: .top, spacing: 14) {
                    todayPanel
                    quickLaunch.frame(width: 330)
                }
                HStack(alignment: .top, spacing: 14) {
                    recentSessions
                    environmentPanel.frame(width: 330)
                }
            }
            .padding(Design.gutter)
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if model.daemon.health == .wedged {
                NoticeBanner(
                    level: .danger,
                    title: "The background service is wedged",
                    message: model.daemon.diagnostic,
                    actionLabel: "Force shutdown") {
                        Task { await model.shutdownDaemon(force: true) }
                    }
            }
            if model.daemon.health == .versionMismatch {
                NoticeBanner(
                    level: .warning,
                    title: "A different engine build owns the daemon",
                    message: model.daemon.diagnostic,
                    actionLabel: "Open Health") { model.section = .health }
            }
            if !model.loginShellEnvironmentLoaded {
                NoticeBanner(
                    level: .warning,
                    title: "Running with launchd's environment",
                    message: "Aviary could not read your login shell's environment, so "
                        + "credentials stored in environment variables may resolve to their "
                        + "own names and 401. Check Health → Environment.",
                    actionLabel: "Health") { model.section = .health }
            }
            if let failing = failingProvider {
                NoticeBanner(
                    level: .warning,
                    title: "\(failing.0) cannot authenticate",
                    message: failing.1,
                    actionLabel: "Models") { model.section = .models }
            }
            if model.engine == nil && !model.preferInHouseEngine {
                NoticeBanner(
                    level: .danger,
                    title: "No engine found",
                    message: "Aviary needs a prime-agent build to run agents. Build the "
                        + "bundled fork with `just build-engine`, or point at an install in "
                        + "Settings.")
            }
        }
    }

    /// A provider whose key expression will not resolve — worth surfacing before the
    /// first 401, not after.
    private var failingProvider: (String, String)? {
        for p in model.modelsConfig.providers {
            guard let expr = p.apiKeyExpression else { continue }
            if case .environmentVariable(let name) = ApiKeyForm.classify(expr),
               !ProcessEnvironment.shared.has(name)
            {
                return (p.displayName,
                        "$\(name) is not set in the environment Aviary captured, so the "
                            + "harness will send the literal string \"\(name)\" as the credential.")
            }
        }
        return nil
    }

    // MARK: Headline

    private var headline: some View {
        HStack(spacing: 14) {
            // "Working now" and "Kernels" tiles retired with the daemon surfaces: both
            // counted things only the harness supervisor knows about.
            StatTile(
                label: "Sub-agents",
                value: "\(model.tree.allNodes.count)",
                caption: model.tree.runningCount > 0
                    ? "\(model.tree.runningCount) still running"
                    : "none running",
                symbol: "bird.fill",
                tint: Design.agentMessage)
            Divider().frame(height: 46)
            StatTile(
                label: "Sessions",
                value: "\(model.sessions.count)",
                caption: model.sessions.first.map { "last active \(Fmt.ago($0.updatedAt))" } ?? "—",
                symbol: "tray.full.fill",
                tint: Design.user)
            Divider().frame(height: 46)
            StatTile(
                label: "All-time tokens",
                value: Fmt.tokens(model.analytics.total.totalTokens),
                caption: model.analytics.total.cost.total > 0
                    ? "\(Fmt.cost(model.analytics.total.cost.total)) attributed"
                    : "no pricing reported",
                symbol: "number",
                tint: Design.assistant)
        }
        .padding(Design.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .fill(.background.secondary))
        .overlay(
            RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1))
    }

    // MARK: Working now

    private var workingNow: some View {
        Card("Working now", symbol: "dot.radiowaves.left.and.right",
             accessory: AnyView(
                Button("Flock") { model.section = .flock }
                    .buttonStyle(.link).font(.system(size: 10.5))))
        {
            let working = model.liveSessions.sorted { a, b in
                if a.isWorking != b.isWorking { return a.isWorking }
                return (a.lastActivityAt ?? .distantPast) > (b.lastActivityAt ?? .distantPast)
            }
            if working.isEmpty {
                Text("Nothing is running. Start something from Live, or the terminal — "
                    + "Aviary sees both.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(working.prefix(9)) { s in
                        LiveSessionRow(session: s)
                            .onTapGesture { model.openTranscript(sessionID: s.sessionID) }
                        if s.id != working.prefix(9).last?.id { Divider().opacity(0.5) }
                    }
                    if working.count > 9 {
                        Button("Show all \(working.count)") { model.section = .flock }
                            .buttonStyle(.link)
                            .font(.system(size: 10.5))
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    // MARK: Today

    private var todayPanel: some View {
        Card("Last 14 days", symbol: "chart.bar.fill",
             accessory: AnyView(
                Button("Usage") { model.section = .usage }
                    .buttonStyle(.link).font(.system(size: 10.5))))
        {
            let days = model.analytics.days(last: 14)
            let peak = max(1, days.map(\.usage.totalTokens).max() ?? 1)
            // A `Card` stretches only when its content does. This card used to be stretched by
            // sharing a row with `workingNow`; once that retired it collapsed to the width of
            // 14 bars, so the fill has to come from here.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days) { d in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(d.usage.totalTokens > 0
                                    ? Design.accent.opacity(0.85)
                                    : Color.secondary.opacity(0.12))
                                .frame(height: max(3, 74 * CGFloat(d.usage.totalTokens) / CGFloat(peak)))
                            Text(Fmt.day(d.day).suffix(2))
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        .help("\(Fmt.day(d.day)) · \(Fmt.tokens(d.usage.totalTokens)) tokens · \(d.sessions) sessions")
                    }
                }
                .frame(height: 92, alignment: .bottom)

                Divider().opacity(0.5)

                HStack(spacing: 12) {
                    let window = days.reduce(into: Usage()) { $0 += $1.usage }
                    StatTile(label: "tokens", value: Fmt.tokens(window.totalTokens))
                    StatTile(label: "cost", value: Fmt.cost(window.cost.total))
                    StatTile(
                        label: "cached",
                        value: Fmt.percent(window.cacheHitRate),
                        caption: "of input tokens")
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380)
    }

    // MARK: Recent sessions

    private var recentSessions: some View {
        Card("Recent sessions", symbol: "clock.arrow.circlepath",
             accessory: AnyView(
                Button("All sessions") { model.section = .sessions }
                    .buttonStyle(.link).font(.system(size: 10.5))))
        {
            if model.sessions.isEmpty {
                Text(model.isScanning ? "Scanning…" : "No sessions found in \(model.home.sessionsDir.path)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.sessions.prefix(8)) { s in
                        Button {
                            model.section = .sessions
                            model.select(session: s)
                        } label: {
                            SessionRow(session: s, compact: true)
                        }
                        .buttonStyle(.plain)
                        if s.id != model.sessions.prefix(8).last?.id { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }

    // MARK: Quick launch

    private var quickLaunch: some View {
        Card("Start a run", symbol: "play.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.settings.defaultModelQualified ?? "no default model set")
                    .font(Design.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let level = model.settings.defaultThinkingLevel {
                    Chip(text: "thinking \(level)", symbol: "brain", tint: Design.thinking)
                }
                Button {
                    model.section = .live
                    NotificationCenter.default.post(name: .aviaryNewRun, object: nil)
                } label: {
                    Label("New run…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                if !model.recentCwds.isEmpty {
                    Text("RECENT DIRECTORIES")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    ForEach(model.recentCwds.prefix(4), id: \.self) { cwd in
                        Button {
                            model.startRun(
                                config: RunConfiguration(
                                    cwd: cwd,
                                    provider: model.settings.defaultProvider,
                                    model: model.settings.defaultModel,
                                    thinkingLevel: model.settings.defaultThinkingLevel),
                                firstPrompt: nil)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                Text(URL(fileURLWithPath: cwd).lastPathComponent)
                                    .font(.system(size: 11))
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Design.accent)
                        .help(cwd)
                    }
                }
            }
        }
    }

    // MARK: Environment

    private var environmentPanel: some View {
        Card("Engine", symbol: "cpu") {
            VStack(alignment: .leading, spacing: 7) {
                if let engine = model.engine {
                    DetailRow(label: "Source", value: engine.kind.label)
                    DetailRow(label: "Version", value: engine.version ?? "unknown", mono: true)
                    // The daemon health row and supervisor pid retired with the other daemon
                    // surfaces: this card is about which engine Aviary would launch, which is a
                    // question the harness supervisor does not answer.
                    DetailRow(
                        label: "Environment",
                        value: model.loginShellEnvironmentLoaded ? "login shell" : "launchd",
                        tint: model.loginShellEnvironmentLoaded ? nil : Design.warning)
                } else {
                    Text("No engine configured").font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Divider().opacity(0.5)
                HStack {
                    Button("Health") { model.section = .health }
                        .buttonStyle(.link).font(.system(size: 10.5))
                    Spacer()
                    Button("Reveal agent dir") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.home.root])
                    }
                    .buttonStyle(.link).font(.system(size: 10.5))
                }
            }
        }
    }
}

// MARK: - Rows

struct LiveSessionRow: View {
    var session: LiveSession

    var body: some View {
        HStack(spacing: 8) {
            if session.isWorking {
                PulseDot(color: session.isSubagent ? Design.agentMessage : Design.success)
            } else {
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if session.isSubagent {
                        Chip(text: "depth \(session.rlmDepth)", tint: Design.agentMessage)
                    }
                    if session.isCompacting {
                        Chip(text: "compacting", tint: Design.warning)
                    }
                    if session.queuedCount > 0 {
                        Chip(text: "\(session.queuedCount) queued", symbol: "tray.full",
                             tint: Design.warning)
                    }
                }
                HStack(spacing: 6) {
                    if let m = session.modelLabel {
                        Text(m).font(Design.mono(9.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Text("\(session.messageCount) msgs")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    if !session.cwd.isEmpty {
                        Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(session.activity)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(session.isWorking ? Design.success : .secondary)
                Text(Fmt.ago(session.lastActivityAt))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if session.attachedClients > 0 {
                Image(systemName: "person.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("\(session.attachedClients) attached client(s)")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct SessionRow: View {
    var session: SessionSummary
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                if session.isBusy {
                    PulseDot(color: Design.success)
                } else if session.isLive {
                    Circle().fill(Design.accent.opacity(0.8)).frame(width: 7, height: 7)
                } else {
                    Circle().fill(Color.secondary.opacity(0.22)).frame(width: 7, height: 7)
                }
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
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
                    Text(Fmt.ago(session.updatedAt))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                if !compact {
                    HStack(spacing: 5) {
                        if let m = session.model {
                            Chip(text: m, symbol: "cpu", tint: Design.assistant)
                        }
                        if session.counts.toolCalls > 0 {
                            Chip(text: "\(session.counts.toolCalls) tools", tint: Design.tool)
                        }
                        if session.counts.toolErrors > 0 {
                            Chip(text: "\(session.counts.toolErrors) errors", tint: Design.danger)
                        }
                        if session.childCount > 0 {
                            Chip(text: "\(session.childCount) sub-agents", symbol: "bird",
                                 tint: Design.agentMessage)
                        }
                        if session.counts.compactions > 0 {
                            Chip(text: "\(session.counts.compactions)×compact",
                                 tint: Design.warning)
                        }
                    }
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
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
        .padding(.vertical, compact ? 5 : 7)
        .contentShape(Rectangle())
    }
}
