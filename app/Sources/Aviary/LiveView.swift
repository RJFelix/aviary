import AppKit
import AviaryCore
import Combine
import SwiftUI

/// Attach to Work, watch it stream, and steer it mid-flight.
///
/// The views on this screen are GUI attachments to Work. Detaching a view is not a stop request;
/// a service-backed Work remains owned by its Work Host when the window or GUI disappears.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var showLauncher = false

    private static let launcherDescription =
        "In-house runs are durable Work on the local Work Host. Aviary is only an attached "
        + "client: closing a window or quitting the GUI disconnects it without ending Work. "
        + "End is always an explicit command. Claude Code keeps its existing process path."

    var body: some View {
        Group {
            if let run = model.focusedRun {
                VStack(spacing: 0) {
                    if model.runs.count > 1 { runTabs }
                    RunPane(run: run)
                }
            } else {
                launcherLanding
            }
        }
        .sheet(isPresented: $showLauncher) { LauncherSheet() }
        .onNotification(.aviaryNewRun) { showLauncher = true }
    }

    private var runTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.runs) { run in
                    Button {
                        model.focusedRunID = run.id
                    } label: {
                        HStack(spacing: 5) {
                            if run.isStreaming {
                                PulseDot(color: Design.success)
                            } else if run.hasExited {
                                Image(systemName: "stop.circle").font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(run.title).font(.system(size: 11)).lineLimit(1)
                            Button {
                                if run.hasExited {
                                model.closeRun(run)
                                } else {
                                    model.detachRun(run)
                                }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                            .accessibilityLabel(
                                run.hasExited
                                    ? "Close view" : "Detach view"
                            )
                            .help(
                                run.hasExited
                                    ? "Close this completed view"
                                    : "Detach this view; the run continues")
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                model.focusedRun?.id == run.id
                                ? Design.accentSoft : Color.secondary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 240)
                }
                Button {
                    showLauncher = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Design.accent)
                .accessibilityLabel("Start a new run")
                .help("Start a new run")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var launcherLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card("Start a run", symbol: "play.circle.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.launcherDescription)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            showLauncher = true
                        } label: {
                            Label("New run…", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("n")
                    }
                }

                if !model.detachedRuns.isEmpty {
                    Card("Detached Work", symbol: "rectangle.on.rectangle.slash") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "These are GUI attachments detached from their Work. Reattaching "
                                    + "does not resume or restart Work, and disconnecting the GUI "
                                    + "does not end it."
                            )
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            ForEach(model.detachedRuns) { run in
                                HStack(spacing: 8) {
                                    if run.isStreaming { PulseDot(color: Design.success) }
                                    Text(run.title).font(.system(size: 11.5)).lineLimit(1)
                                    Spacer()
                                    Text(run.presentationState)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                    Button("Reattach") { model.reattachRun(run) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                }

                // `RunningElsewhereCard` is deliberately not shown — it lists sessions the
                // harness daemon is holding, and the in-house engine holds its runs itself
                // (they are right here on this screen). Retired rather than deleted; see
                // docs/architecture.md, "Retired daemon surfaces".
                if !model.localServiceCatalogWorks.isEmpty {
                    Card("Available Work", symbol: "rectangle.stack") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                "These Work records are owned by the Work Host. Attach or inspect "
                                    + "is explicit; it does not start, resume, or terminate Work."
                            )
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(model.localServiceCatalogWorks, id: \.work) { descriptor in
                                ForEach(model.serviceAttachTargets(for: descriptor), id: \.self) { target in
                                    let hasOwnAttachment = descriptor.attachments.contains {
                                        $0.client == model.localWorkServiceClient
                                            && $0.session == target.session
                                            && $0.sessionJournal == target.sessionJournal
                                            && $0.sessionAttachment == target.sessionAttachment
                                    }
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(descriptor.work.workID)
                                                .font(Design.mono(11))
                                            Text(
                                                "\(target.session.sessionID) · "
                                                    + "\(model.workspaceLabel(for: descriptor)) · "
                                                    + "\(descriptor.execution.rawValue)"
                                            )
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(hasOwnAttachment ? "Inspect" : "Attach") {
                                            model.attachServiceWork(
                                                descriptor,
                                                targetSessionAttachment: target.sessionAttachment)
                                        }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .help(
                                                hasOwnAttachment
                                                    ? "Inspect this Session attachment without starting it"
                                                    : "Attach this exact Session without starting it")
                                    }
                                }
                                ForEach(
                                    model.serviceSessionCreationAuthorizers(for: descriptor),
                                    id: \.attachment
                                ) { authorizer in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("New conversation")
                                                .font(.system(size: 11.5, weight: .medium))
                                            Text(
                                                "Create an independent Session on this Work"
                                                    + (authorizer.session.map {
                                                        " via \($0.sessionID)"
                                                    } ?? "")
                                            )
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Button("New Session") {
                                            model.createServiceSession(
                                                descriptor,
                                                authorizingAttachment: authorizer.attachment)
                                        }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .help(
                                                "Ask the Work Host to create and attach a new Session; this does not start a Run")
                                    }
                                }
                            }
                        }
                    }
                }

            }
            .padding(Design.gutter)
        }
    }
}

// MARK: - Run pane

struct RunPane: View {
    private struct SelectedAction: Identifiable, Hashable {
        let id: String
    }

    @Environment(AppModel.self) private var model
    var run: LiveRun
    /// Cockpit owns its two-column layout, so it reuses the chat/composer without a third
    /// technical column. Live keeps the detailed inspector.
    var showsInspector = true

    @State private var showMarkdownPreview = true
    @State private var showLaunchDetails = false
    @State private var selectedItem: TranscriptItem?
    @State private var selectedAction: SelectedAction?
    @State private var confirmEndRun = false
    @State private var showInputDeliveryReview = false
    @State private var showCockpitInspector = false
    @State private var showRepositoryReview = false
    @State private var composerDelivery: ComposerDelivery = .steerNext

    private enum ComposerDelivery: String, CaseIterable, Identifiable {
        case steerNext
        case queueFollowUp

        var id: String { rawValue }
        var label: String {
            switch self {
            case .steerNext: "Steer next"
            case .queueFollowUp: "Queue follow-up"
            }
        }
        var detail: String {
            switch self {
            case .steerNext: "Deliver before the next model call"
            case .queueFollowUp: "Start a distinct turn after current work"
            }
        }
    }

    // Fixed trailing inspector column rather than `.inspector` or a conditional split
    // pane — see the note on SessionsView.body for why both of those misbehave.
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                runHeader
                Divider()
                if let banner = run.errorBanner {
                    NoticeBanner(level: .danger, title: "Run needs attention", message: banner)
                        .padding(Design.gutter)
                }
                if let notice = run.commandNotice {
                    NoticeBanner(
                        level: notice.level == .success ? .success : .warning,
                        title: notice.level == .success
                            ? "Command acknowledged" : "Command not accepted",
                        message: notice.message
                    )
                        .padding(Design.gutter)
                }
                if let omissions = run.serviceProjectionOmissionSummary {
                    NoticeBanner(
                        level: .info,
                        title: "Bounded canonical view",
                        message: omissions)
                        .padding(Design.gutter)
                }
                if let omissions = run.serviceInputDeliveryOmissionSummary {
                    NoticeBanner(
                        level: .warning,
                        title: "Input delivery view incomplete",
                        message: omissions)
                        .padding(Design.gutter)
                }
                if let action = run.currentServiceActions.first {
                    WorkActivityStrip(
                        action: action,
                        concurrentActions: run.currentServiceActions,
                        onInspect: {
                            selectedAction = SelectedAction(id: $0.id)
                        })
                    Divider()
                }
                TranscriptView(
                    items: run.items,
                    hideThinking: model.hideThinking,
                    isStreaming: run.isStreaming,
                    autoScroll: true,
                    hasEarlierHistory: run.serviceHistoryHasEarlier,
                    hasNewerHistory: run.serviceHistoryHasNewer,
                    isLoadingEarlierHistory: run.serviceHistoryIsLoading,
                    earlierHistoryError: run.serviceHistoryError,
                    onLoadEarlierHistory: run.isServiceBacked ? {
                        Task { await run.loadEarlierServiceHistory() }
                    } : nil,
                    onJumpToLatestHistory: run.isServiceBacked ? {
                        await run.jumpServiceHistoryToLatest()
                    } : nil,
                    onSelect: { selectedItem = $0 })
                Divider()
                composer
            }
            .frame(minWidth: 380)

            if showsInspector && model.showInspector {
                Divider()
                RunInspector(run: run, selectedItem: $selectedItem)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .confirmationDialog(
            "End this run?",
            isPresented: $confirmEndRun,
            titleVisibility: .visible
        ) {
            Button("End run", role: .destructive) {
                Task { await run.end() }
            }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text(
                run.isServiceBacked
                    ? "This sends an explicit End command to the Work Host. The GUI can detach "
                        + "without ending it, and the transcript remains available."
                    : "This stops the agent and destroys its current Python runtime. "
                        + "The transcript remains available.")
        }
        .sheet(item: $selectedAction) { selection in
            if let action = run.serviceActionPresentations.first(where: {
                $0.id == selection.id
            }) {
                WorkActionDetailSheet(action: action)
            } else {
                WorkActionUnavailableSheet(actionID: selection.id)
            }
        }
        .sheet(isPresented: $showInputDeliveryReview) {
            InputDeliveryReviewSheet(
                pending: run.servicePendingInputs,
                attention: run.serviceInputDeliveryAttention,
                omissionSummary: run.serviceInputDeliveryOmissionSummary)
        }
        .sheet(isPresented: $showCockpitInspector) {
            RunInspector(run: run, selectedItem: $selectedItem)
                .frame(minWidth: 360, idealWidth: 420, minHeight: 520, idealHeight: 720)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Run context and working state")
        }
        .sheet(isPresented: $showRepositoryReview) {
            RepositoryReviewView(run: run)
                .frame(minWidth: 560, idealWidth: 760, minHeight: 620, idealHeight: 780)
        }
    }

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if run.isStreaming {
                    PulseDot()
                } else if run.hasExited {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    Circle().fill(Design.accent.opacity(0.7)).frame(width: 7, height: 7)
                }
                Text(run.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Chip(
                    text: run.presentationState,
                    tint: run.presentationState == "failed"
                        ? Design.danger
                        : run.presentationState == "working" ? Design.success : .secondary)
                if run.isCompacting { Chip(text: "compacting", tint: Design.warning) }
                if run.hasExited {
                    Chip(
                        text: run.exitCode.map { "exited \($0)" } ?? "exited",
                         tint: (run.exitCode ?? 0) == 0 ? .secondary : Design.danger)
                }
                Spacer()
                if run.canLoadServiceRepositoryReview {
                    ViewThatFits(in: .horizontal) {
                        Button {
                            showRepositoryReview = true
                        } label: {
                            Label("Review changes", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            showRepositoryReview = true
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .frame(width: 20, height: 20)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .accessibilityLabel("Review changes")
                    .accessibilityHint(
                        "Opens the bounded current working-tree observation for this Work")
                    .help("Review current working-tree changes")
                }
                if !showsInspector {
                    Button {
                        showCockpitInspector = true
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("Inspect recorded model context and canonical working state")
                    .accessibilityLabel("Context and working state")
                    .accessibilityHint(
                        "Opens recorded provider context and current durable Work and Session evidence")
                }
                controls
            }

            runMetadata

            if hasPendingInputs {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(
                            run.serviceInputDeliveryAttention.isEmpty
                                ? Design.warning : Design.danger)
                    Text(queueSummary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(
                            run.serviceInputDeliveryAttention.isEmpty
                                ? Design.warning : Design.danger)
                    Spacer()
                    if !run.servicePendingInputs.isEmpty
                        || !run.serviceInputDeliveryAttention.isEmpty {
                        Button("Review") { showInputDeliveryReview = true }
                            .buttonStyle(.link)
                            .font(.system(size: 10.5, weight: .semibold))
                            .accessibilityHint(
                                "Shows canonical delivery evidence and host ordering")
                    }
                }
            }
        }
        .padding(.horizontal, Design.gutter)
        .padding(.vertical, 9)
        .background(.background.secondary)
    }

    private var runMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Chip(text: run.projectName, symbol: "folder", tint: Design.accent)
                    .help(run.config.cwd)
                if let m = run.modelLabel, !m.isEmpty {
                    Chip(text: m, symbol: "cpu", tint: Design.assistant)
                }
                if let level = run.thinkingLevel {
                    Chip(text: level, symbol: "brain", tint: Design.thinking)
                }
                if !run.usage.isEmpty {
                    Chip(
                        text: Fmt.tokens(run.usage.totalTokens), symbol: "number", tint: .secondary)
                }
                if run.usage.cost.total > 0 {
                    Chip(text: Fmt.cost(run.usage.cost.total), tint: Design.accent)
                }
                Chip(text: run.elapsedLabel, symbol: "clock", tint: .secondary)
                Spacer()
                if let share = run.contextShare, let tokens = run.contextTokens {
                    HStack(spacing: 5) {
                        Text("context")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        RatioBar(
                            fraction: share,
                            tint: share > 0.85
                                ? Design.danger
                                : share > 0.65 ? Design.warning : Design.accent
                        )
                            .frame(width: 90)
                        Text("\(Fmt.tokens(tokens)) / \(Fmt.tokens(run.contextWindow ?? 0))")
                            .font(Design.numeric(9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 5) {
                Chip(text: run.projectName, symbol: "folder", tint: Design.accent)
                    .help(run.config.cwd)
                if let m = run.modelLabel, !m.isEmpty {
                    Chip(text: m, symbol: "cpu", tint: Design.assistant)
                }
                Chip(text: run.elapsedLabel, symbol: "clock", tint: .secondary)
                Spacer(minLength: 4)
                if let share = run.contextShare {
                    Chip(
                        text: Fmt.percent(share), symbol: "rectangle.stack",
                        tint: share > 0.85
                            ? Design.danger
                            : share > 0.65 ? Design.warning : Design.accent)
                        .help("Share of the model context window currently in use")
                }
            }
        }
    }

    private var queueSummary: String {
        var parts: [String] = []
        if !run.servicePendingInputs.isEmpty {
            parts.append(
                "\(run.servicePendingInputs.count) host-accepted input"
                    + (run.servicePendingInputs.count == 1 ? " waiting for delivery" : "s waiting for delivery"))
        }
        if !run.serviceInputDeliveryAttention.isEmpty {
            parts.append(
                "\(run.serviceInputDeliveryAttention.count) delivery outcome"
                    + (run.serviceInputDeliveryAttention.count == 1 ? " needs review" : "s need review"))
        }
        if !run.queuedSteering.isEmpty {
            parts.append("\(run.queuedSteering.count) local steering")
        }
        if !run.queuedFollowUps.isEmpty {
            parts.append("\(run.queuedFollowUps.count) local follow-up")
        }
        return "Pending: " + parts.joined(separator: ", ")
    }

    private var hasPendingInputs: Bool {
        !run.servicePendingInputs.isEmpty
            || !run.serviceInputDeliveryAttention.isEmpty
            || !run.queuedSteering.isEmpty
            || !run.queuedFollowUps.isEmpty
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            fullControls
            compactControls
        }
    }

    private var fullControls: some View {
        HStack(spacing: 6) {
                Button {
                if run.hasExited { model.closeRun(run) } else { model.detachRun(run) }
                } label: {
                Label(
                    run.hasExited ? "Close view" : "Detach view",
                    systemImage: run.hasExited ? "xmark" : "rectangle.on.rectangle.slash"
                )
                .font(.system(size: 10.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(
                run.hasExited
                    ? "Close this completed view"
                    : "Hide this chat view without ending the run")

            if !run.hasExited {
                if run.commandCapabilities.supports(.agentLoop) && run.isStreaming {
                    Button {
                        Task { _ = await run.cancel(.agentLoop) }
                    } label: {
                        Label(
                            run.commandState == .canceling ? "Canceling…" : "Cancel at boundary",
                            systemImage: "pause.circle"
                        )
                        .font(.system(size: 10.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityValue(
                        run.commandState == .canceling ? "In progress" : "Available")
                    .disabled(run.commandState == .canceling || run.isEnding)
                    .help(
                        "Stop the agent loop at its next safe boundary; this cannot interrupt "
                            + "an in-flight model stream or Python action")
                }
                Button {
                    confirmEndRun = true
                } label: {
                    Label(run.isEnding ? "Ending…" : "End run", systemImage: "stop.fill")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Design.danger)
                .accessibilityValue(run.isEnding ? "In progress" : "Available")
                .disabled(run.isEnding || !run.serviceControlsAvailable)
                .help(
                    run.isServiceBacked
                        ? "Send an explicit End command to the Work Host"
                        : "Stop the agent and destroy this run's Python runtime")
            }

            RunOptionsMenu(
                run: run,
                models: model.pickerModels,
                hasExited: run.hasExited,
                isWorking: run.isStreaming,
                isCanceling: run.commandState == .canceling,
                cancellationScopes: run.commandCapabilities.cancellationScopes,
                sessionFile: run.sessionFile)
        }
    }

    private var compactControls: some View {
        HStack(spacing: 5) {
            Button {
                if run.hasExited { model.closeRun(run) } else { model.detachRun(run) }
            } label: {
                Image(systemName: run.hasExited ? "xmark" : "rectangle.on.rectangle.slash")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(run.hasExited ? "Close view" : "Detach view")
            .help(
                run.hasExited
                    ? "Close this completed view"
                    : "Hide this chat view without ending the run")

            if !run.hasExited {
                if run.commandCapabilities.supports(.agentLoop) && run.isStreaming {
                    Button {
                        Task { _ = await run.cancel(.agentLoop) }
                    } label: {
                        Image(systemName: "pause.circle")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(run.commandState == .canceling || run.isEnding)
                    .accessibilityLabel("Cancel at boundary")
                    .help("Stop the agent loop at its next safe boundary")
                }
                Button {
                    confirmEndRun = true
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Design.danger)
                .disabled(run.isEnding || !run.serviceControlsAvailable)
                .accessibilityLabel(run.isEnding ? "Ending run" : "End run")
                .help(
                    run.isServiceBacked
                        ? "Send an explicit End command to the Work Host"
                        : "Stop the agent and destroy this run's Python runtime")
            }

            RunOptionsMenu(
                run: run,
                models: model.pickerModels,
                hasExited: run.hasExited,
                isWorking: run.isStreaming,
                isCanceling: run.commandState == .canceling,
                cancellationScopes: run.commandCapabilities.cancellationScopes,
                sessionFile: run.sessionFile)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if run.draft.isEmpty {
                        Text(composerPlaceholder)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(
                        get: { run.draft },
                        set: { run.setDraft($0) }))
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 34, maxHeight: 130)
                        .padding(.horizontal, 1)
                        // No focus state is mutated by streaming or delivery callbacks. This
                        // remains the same editor identity while the parent observes the run.
                        .accessibilityLabel(composerAccessibilityLabel)
                        .accessibilityHint(composerAccessibilityHint)
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1))

                VStack(spacing: 5) {
                    Button {
                        showMarkdownPreview.toggle()
                    } label: {
                        Image(systemName: showMarkdownPreview ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                            .frame(width: 26, height: 20)
                    }
                    .buttonStyle(.bordered)
                    .disabled(run.draft.isEmpty)
                    .accessibilityLabel(
                        showMarkdownPreview ? "Hide Markdown preview" : "Show Markdown preview")
                    .accessibilityValue(showMarkdownPreview ? "Visible" : "Hidden")
                    .help(showMarkdownPreview ? "Hide Markdown preview" : "Show Markdown preview")

                    if run.isStreaming {
                        HStack(spacing: 4) {
                            Text("Delivery")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Picker(
                                "Delivery mode",
                                selection: Binding(
                                    get: { effectiveComposerDelivery ?? .steerNext },
                                    set: { composerDelivery = $0 })
                            ) {
                                ForEach(availableComposerDeliveries) { choice in
                                    Text(choice.label).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .disabled(availableComposerDeliveries.count < 2)
                            .accessibilityLabel("Delivery mode")
                            .accessibilityValue(
                                effectiveComposerDelivery?.detail
                                    ?? "No delivery mode available")
                        }
                    }

                    Button {
                        submitComposer()
                    } label: {
                        Label(
                            composerActionLabel,
                            systemImage: composerActionSymbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(minWidth: 104, minHeight: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!composerCanSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(composerActionLabel)
                    .accessibilityValue(
                        run.draft.trimmingCharacters(in: .whitespaces).isEmpty
                            ? "Unavailable: message is empty"
                            : composerCanSubmit ? "Ready" : "Unavailable")
                    .accessibilityHint(composerActionDetail + ". Sends with Command-Return.")
                    .help("\(composerActionDetail) (⌘↵)")
                }
            }
            .padding(.horizontal, Design.gutter)
            .padding(.vertical, 9)

            if let notice = run.draftPersistenceNotice {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Draft storage requires attention")
                        .accessibilityHint(notice)
                    if run.draftHandoffRecoveryAvailable {
                        HStack(spacing: 6) {
                            Button("Check Work again") {
                                Task { await run.refreshService() }
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Return to composer") {
                                Task { _ = await run.returnUnresolvedDraftToComposer() }
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(Design.warning)
                                .help(
                                    "Remove the local handoff guard after reviewing Work; "
                                        + "sending again remains a separate action")
                        }
                    }
                }
                .padding(.horizontal, Design.gutter)
                .padding(.vertical, 6)
            }

            if showMarkdownPreview, !run.draft.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("MARKDOWN PREVIEW")
                        .font(Design.sectionTitle).foregroundStyle(.secondary)
                    ScrollView {
                        MarkdownText(text: run.draft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
                .padding(.horizontal, Design.gutter)
                .padding(.vertical, 9)
                .background(.background.secondary)
            }
        }
        .background(.bar)
    }

    private var availableComposerDeliveries: [ComposerDelivery] {
        guard run.isStreaming else { return [] }
        var choices: [ComposerDelivery] = []
        if run.commandCapabilities.supportsSteering { choices.append(.steerNext) }
        if run.commandCapabilities.supportsQueuedFollowUps { choices.append(.queueFollowUp) }
        return choices
    }

    private var effectiveComposerDelivery: ComposerDelivery? {
        let choices = availableComposerDeliveries
        if choices.contains(composerDelivery) { return composerDelivery }
        return choices.first
    }

    private var composerActionLabel: String {
        guard run.isStreaming else { return "Send now" }
        return effectiveComposerDelivery?.label ?? "Working"
    }

    private var composerActionSymbol: String {
        guard run.isStreaming else { return "arrow.up" }
        return switch effectiveComposerDelivery {
        case .steerNext: "arrow.turn.down.right"
        case .queueFollowUp: "text.append"
        case nil: "hourglass"
        }
    }

    private var composerActionDetail: String {
        guard run.isStreaming else { return "Send as the next user turn" }
        return effectiveComposerDelivery?.detail
            ?? "This Work advertises no input mode while it is working"
    }

    private var composerPlaceholder: String {
        guard run.isStreaming else { return "Ask for something…" }
        return switch effectiveComposerDelivery {
        case .steerNext: "Steer the run — lands before the next model call…"
        case .queueFollowUp: "Queue a distinct follow-up turn…"
        case nil: "This Work is busy and advertises no input mode…"
        }
    }

    private var composerAccessibilityLabel: String {
        guard run.isStreaming else { return "Message composer" }
        return switch effectiveComposerDelivery {
        case .steerNext: "Steering message"
        case .queueFollowUp: "Queued follow-up message"
        case nil: "Unavailable message composer"
        }
    }

    private var composerAccessibilityHint: String {
        guard run.isStreaming else { return "Send as the next user turn" }
        return effectiveComposerDelivery?.detail
            ?? "This Work advertises no input mode while it is working"
    }

    private var composerCanSubmit: Bool {
        !run.hasExited && run.acceptsInput
            && !run.draft.trimmingCharacters(in: .whitespaces).isEmpty
            && (!run.isStreaming || effectiveComposerDelivery != nil)
    }

    private func submitComposer() {
        let text = run.draft
        let delivery: LiveRunComposerDelivery
        if run.isStreaming {
            switch effectiveComposerDelivery {
            case .steerNext: delivery = .steerNext
            case .queueFollowUp: delivery = .queueFollowUp
            case nil: return
            }
        } else {
            delivery = .sendNow
        }
        Task {
            let receipt = await run.submitComposer(text, delivery: delivery)
            if receipt.wasHandedOff, !run.isServiceBacked {
                await run.reconcileDraftAfterHandOff(text)
            }
        }
    }
}

private struct InputDeliveryReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pending: [CanonicalInputDeliveryRow]
    let attention: [CanonicalInputDeliveryRow]
    let omissionSummary: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input delivery")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Canonical Work evidence · input text remains in its Session")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let omissionSummary {
                        NoticeBanner(
                            level: .warning,
                            title: "Bounded evidence",
                            message: omissionSummary)
                    }
                    if !pending.isEmpty {
                        deliverySection(
                            "WAITING FOR RUNTIME DELIVERY", rows: pending,
                            explanation: "Already owned by the Work Host. Do not resend while unresolved.")
                    }
                    if !attention.isEmpty {
                        deliverySection(
                            "NEEDS REVIEW", rows: attention,
                            explanation: "Inspect Work before retrying; an uncertain input may have taken effect.")
                    }
                }
                .padding(14)
            }
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 300, idealHeight: 440)
    }

    private func deliverySection(
        _ title: String, rows: [CanonicalInputDeliveryRow], explanation: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Design.sectionTitle)
                .foregroundStyle(.secondary)
            Text(explanation)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                InputDeliveryEvidenceRow(row: row)
            }
        }
    }
}

private struct InputDeliveryEvidenceRow: View {
    let row: CanonicalInputDeliveryRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if let issue = row.issue {
                    Text("Evidence: \(issue.rawValue.replacingOccurrences(of: "_", with: " "))")
                        .font(Design.mono(9))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            if let sequence = row.hostSequence {
                Text("host #\(sequence)")
                    .font(Design.numeric(9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.22)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityHint(hint)
    }

    private var title: String {
        switch row.state {
        case .acceptedWaitingDelivery: "Accepted by Work Host · waiting for delivery"
        case .delivered: "Delivered to runtime"
        case .notDelivered: "Not delivered to runtime"
        case .indeterminateUnknownEffect: "Delivery outcome uncertain"
        case .provenanceUnavailable: "Delivery evidence unavailable"
        }
    }

    private var symbol: String {
        switch row.state {
        case .acceptedWaitingDelivery: "clock.badge.checkmark"
        case .delivered: "checkmark.circle.fill"
        case .notDelivered: "xmark.circle.fill"
        case .indeterminateUnknownEffect: "exclamationmark.triangle.fill"
        case .provenanceUnavailable: "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch row.state {
        case .acceptedWaitingDelivery, .indeterminateUnknownEffect: Design.warning
        case .delivered: Design.success
        case .notDelivered: Design.danger
        case .provenanceUnavailable: .secondary
        }
    }

    private var detail: String {
        let kind = row.commandKind?.rawValue.replacingOccurrences(of: "_", with: " ")
            ?? "input"
        let mode = row.deliveryMode?.rawValue.replacingOccurrences(of: "_", with: " ")
        return mode.map { "\(kind) · runtime crossing \($0)" } ?? kind
    }

    private var hint: String {
        switch row.state {
        case .acceptedWaitingDelivery:
            "Do not resend while delivery is unresolved."
        case .indeterminateUnknownEffect:
            "Inspect Work before retrying; the input may have taken effect."
        case .notDelivered:
            "Review Work before deciding whether to send again."
        case .delivered:
            "No action is needed."
        case .provenanceUnavailable:
            "Refresh or inspect Work before inferring delivery."
        }
    }
}

/// The run's menu, in a view of its own so that an open submenu survives the run streaming.
///
/// Not tidiness. `LiveRun` is `@Observable`, and the in-house and driven engines both mirror
/// their driver onto it from a 250ms loop that assigns every field *unconditionally* — the
/// Observation setter notifies on every assignment whether or not the value changed, so an
/// idle run invalidates `RunPane` four times a second forever. `RunPane` reads five of the
/// mirrored fields (`items`, `isStreaming`, `hasExited`, `usage`, `errorBanner`), so while the
/// menu lived in that body its content was rebuilt at 4Hz, and AppKit answers a rebuilt
/// NSMenu by tearing down and re-presenting whichever submenu is open. Hovering "Switch
/// model" flashed a submenu nothing could be clicked in.
///
/// So everything the menu *draws* arrives as a value and the comparison below decides when it
/// is redrawn. The `run` is held for its actions only: reading an observable property of it in
/// this body would re-open the same hole, and `launchCommand` is read inside a button's action
/// rather than beside it for exactly that reason — observation tracks what a body reads, not
/// what a closure will read later. The poll loop in `AppModel.startPolling` is not implicated;
/// it touches daemon state this screen never reads.
/// The run's overflow menu, taking values rather than observing the run.
///
/// It was briefly wrapped in `EquatableView` to stop it being rebuilt. That did not work and
/// made things worse — the root row lost its highlight as well as the submenu — because the
/// invalidation was upstream: `LiveRun`'s mirror re-published its state every 250ms whether or
/// not anything had changed, so the parent re-rendered regardless of what this view compared
/// equal to. The fix belongs there, and the shield is gone rather than left as cargo.
struct RunOptionsMenu: View {
    @Environment(AppModel.self) private var model
    var run: LiveRun
    var models: [ModelSpec]
    var hasExited: Bool
    var isWorking: Bool
    var isCanceling: Bool
    var cancellationScopes: Set<SessionCancellationScope>
    var sessionFile: String?
    @State private var choosingModel = false

    var body: some View {
        Menu {
            Button("Context compacts automatically") {}
                .disabled(true)
            Divider()
            Button("Change model…") { choosingModel = true }
                .disabled(hasExited || models.isEmpty)
            // Flat, not a submenu. Seven items inline cost less than a nested `Menu`, which
            // does not work under `.menuStyle(.borderlessButton)` — see `ModelChooserSheet`.
            Picker(
                "Thinking level",
                selection: Binding(
                get: { run.thinkingLevel ?? "off" },
                    set: { level in Task { await run.setThinking(level) } })
            ) {
                ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) {
                    Text($0).tag($0)
                }
            }
            .pickerStyle(.inline)
            .disabled(true)
            .help("Thinking level is fixed when this run starts")
            Divider()
            Button("Cancel at next safe boundary") {
                Task { _ = await run.cancel(.agentLoop) }
            }
            .accessibilityValue(
                cancellationScopes.contains(.agentLoop) ? "Available" : "Unavailable")
            .accessibilityHint(
                "Stops at the agent loop's next safe boundary; it does not interrupt a model stream or action")
            .disabled(
                hasExited || !isWorking || isCanceling
                    || !cancellationScopes.contains(.agentLoop))
            Button("Cancel model stream") {
                Task { _ = await run.cancel(.modelStream) }
            }
            .accessibilityValue(
                cancellationScopes.contains(.modelStream) ? "Available" : "Unavailable")
            .accessibilityHint("Interrupts the provider's model stream when supported")
            .disabled(
                hasExited || !isWorking || isCanceling
                    || !cancellationScopes.contains(.modelStream))
            Button("Cancel current action") {
                Task { _ = await run.cancel(.currentAction) }
            }
            .accessibilityValue(
                cancellationScopes.contains(.currentAction) ? "Available" : "Unavailable")
            .accessibilityHint("Interrupts the active action when supported")
            .disabled(
                hasExited || !isWorking || isCanceling
                    || !cancellationScopes.contains(.currentAction))
            if !cancellationScopes.contains(.modelStream)
                || !cancellationScopes.contains(.currentAction)
            {
                Text("Unavailable scopes are disabled; End run is broader teardown.")
            }
            Divider()
            Button("Copy launch command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.launchCommand, forType: .string)
            }
            if let sessionFile {
                Button("Reveal transcript") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: sessionFile)])
                }
            }
            Divider()
            Button(hasExited ? "Close view" : "Detach view") {
                if hasExited { model.closeRun(run) } else { model.detachRun(run) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Run actions")
        .accessibilityHint("Actions for this run, including cancellation scopes")
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Attached to the menu, not inside its content: a sheet modifier on a view that only
        // exists while the menu is open never gets the chance to present.
        .sheet(isPresented: $choosingModel) {
            RunSettingsSheet(run: run, models: models)
        }
    }

}

// MARK: - Launcher

struct LauncherSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("New run", systemImage: "play.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            LauncherFormBody(onStart: { dismiss() })
        }
        .frame(width: 560, height: 640)
    }
}

/// The launcher's cards and start action, shared by the modal (`LauncherSheet`, used from Live)
/// and Cockpit's inline composer (`NewSessionPane`). Same options either way — a run does not
/// need fewer of them just because it was started from a card instead of a sheet — so the form
/// lives once and each caller supplies its own chrome and its own `onStart`.
struct LauncherFormBody: View {
    @Environment(AppModel.self) private var model
    var onStart: () -> Void

    @State private var cwd = ""
    @State private var prompt = ""
    @State private var provider: String = ""
    @State private var modelID: String = ""
    @State private var thinking = "high"
    /// Which engine to go back to when you leave `claude-code` behind. Remembered because
    /// Harness and In-house are a real choice between themselves, and snapping to one of them
    /// arbitrarily would silently change what a run is.
    @State private var lastDirectEngine: AppModel.Engine = .inHouse
    @State private var persistSession = true
    @State private var noContextFiles = false
    @State private var recordPayloads = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card("Workspace", symbol: "folder") {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                TextField("", text: $cwd)
                                    .textFieldStyle(.roundedBorder)
                                    .font(Design.mono(11))
                                Button("Choose…") { chooseDirectory() }
                                    .controlSize(.small)
                            }
                            if !model.recentCwds.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(model.recentCwds, id: \.self) { path in
                                            Button {
                                                cwd = path
                                            } label: {
                                                Chip(
                                                    text: URL(fileURLWithPath: path)
                                                        .lastPathComponent,
                                                    symbol: "clock",
                                                    tint: cwd == path ? Design.accent : .secondary,
                                                    filled: cwd == path)
                                            }
                                            .buttonStyle(.plain)
                                            .help(path)
                                        }
                                    }
                                }
                            }
                            Text(
                                "This local folder is registered by the co-located Work Host. "
                                + "The GUI keeps the path here; Create and Start carry only "
                                    + "the host-minted opaque workspace ID. AGENTS.md and "
                                    + "CLAUDE.md discovery still starts from this choice."
                            )
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if model.engineChoice == .inHouse {
                                WorkHostStatusRow(
                                    handshake: model.localWorkServiceHandshake,
                                    catalog: model.localWorkspaceCatalog,
                                    error: model.localWorkServiceError)
                            }
                        }
                    }

                    Card("Engine", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker(
                                "",
                                selection: Binding(
                                get: { model.engineChoice },
                                    set: { model.engineChoice = $0 })
                            ) {
                                ForEach(AppModel.Engine.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            .onChange(of: model.engineChoice) { _, now in
                                if now != .claudeCode { lastDirectEngine = now }
                                if now == .claudeCode { recordPayloads = false }
                                // The engines offer disjoint catalogues, so a selection made
                                // under one is meaningless under the other. Re-seeded rather
                                // than left alone, because a picker showing a provider absent
                                // from its own list renders blank.
                                if !providers.contains(provider) {
                                    provider = providers.first ?? ""
                                }
                                if !modelsForProvider.contains(where: { $0.id == modelID }) {
                                    modelID = modelsForProvider.first?.id ?? ""
                                }
                            }
                            Text(engineExplanation)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if model.engineChoice == .claudeCode {
                                Divider().opacity(0.5)
                                if let auth = model.claudeCodeAuth {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(
                                                auth.isSubscription
                                                    ? Design.success : Design.warning
                                            )
                                            .frame(width: 6, height: 6)
                                        Text(
                                            auth.isSubscription
                                            ? "\(auth.summary) — draws on the plan"
                                                : "\(auth.summary) — bills metered API credit"
                                        )
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(
                                        "No `claude` binary found, or it is not signed in. "
                                            + "Install Claude Code and run `claude /login`."
                                    )
                                        .font(.system(size: 10))
                                        .foregroundStyle(Design.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .controlSize(.small)
                    }

                    Card("Model", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.pickerModels.isEmpty {
                                Text(
                                    model.runtimeModelsError
                                        ?? "Asking the engine which models it can reach…"
                                )
                                    .font(.system(size: 11))
                                .foregroundStyle(
                                    model.runtimeModelsError == nil
                                        ? .secondary : Design.danger)
                            } else {
                                Picker("Provider", selection: $provider) {
                                    ForEach(providers, id: \.self) { Text($0).tag($0) }
                                }
                                .onChange(of: provider) { _, now in
                                    // Picking the provider sets the engine, because for this
                                    // one they are the same fact: Claude Code *is* the thing
                                    // that answers, so choosing it as a provider is choosing
                                    // it as the engine. Making you say it twice — once here
                                    // and once in the segment above — is what sent somebody
                                    // hunting through the provider list for a route that was
                                    // gated behind a control they had not touched.
                                    if now == "claude-code" {
                                        model.engineChoice = .claudeCode
                                    } else if model.engineChoice == .claudeCode {
                                        model.engineChoice = lastDirectEngine
                                    }
                                    modelID = modelsForProvider.first?.id ?? ""
                                }
                                Picker("Model", selection: $modelID) {
                                    ForEach(modelsForProvider) { m in
                                        Text(m.displayName).tag(m.id)
                                    }
                                }
                                if let selected = modelsForProvider.first(where: {
                                    $0.id == modelID
                                }) {
                                    ModelFactsRow(model: selected, requestedThinking: thinking)
                                }
                            }
                            Picker("Thinking", selection: $thinking) {
                                ForEach(
                                    ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
                                    id: \.self
                                ) { Text($0).tag($0) }
                            }
                        }
                    }

                    Card("First prompt", symbol: "text.cursor") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $prompt)
                                .font(.system(size: 12.5))
                                .frame(minHeight: 90)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(.separator, lineWidth: 1))
                            Text("Optional — you can start empty and type into the run.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }

                    Card("Options", symbol: "slider.horizontal.3") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Save the session to disk", isOn: $persistSession)
                                .disabled(true)
                            Text("Aviary currently always keeps a crash-readable session journal.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Toggle("Skip AGENTS.md / CLAUDE.md discovery", isOn: $noContextFiles)
                            Divider().opacity(0.5)
                            Toggle("Record what's sent to the model", isOn: $recordPayloads)
                                .disabled(model.engineChoice == .claudeCode)
                            Text(Self.recordPayloadsExplanation)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            if model.engineChoice == .claudeCode {
                                Text(
                                    "Unavailable for a Claude Code-driven run: Claude Code owns "
                                        + "the provider request and does not expose its full payload."
                                )
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            } else if model.preferInHouseEngine {
                                Text(
                                    "On the in-house engine this is native — the provider "
                                    + "announces each payload as it sends it, so there is no "
                                        + "extension to install."
                                )
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            } else if EngineLocator.wireLogExtension() == nil {
                                Text(
                                    "Unavailable: harness-extensions/wire-log.ts is missing "
                                        + "from this checkout."
                                )
                                    .font(.system(size: 10))
                                    .foregroundStyle(Design.warning)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                if let engine = model.engine {
                    Text("\(engine.kind.label) · \(engine.version ?? "?")")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    if model.engineChoice == .claudeCode {
                        model.startClaudeCodeRun(
                            cwd: cwd.isEmpty ? model.defaultCwd : cwd,
                            // From the Model card, like every other engine. `claudeCodeModel`
                            // is still where the choice is remembered between runs, which is
                            // why it is written here rather than read.
                            model: modelID.isEmpty ? model.claudeCodeModel : modelID,
                            // "off" is the picker's no-reasoning value; Claude Code has no such
                            // level, so it is expressed by omitting the flag entirely.
                            effort: thinking == "off" ? nil : thinking,
                            prompt: prompt, noContextFiles: noContextFiles)
                        onStart()
                        return
                    }
                    model.startInHouseRun(
                        cwd: cwd.isEmpty ? model.defaultCwd : cwd,
                        providerID: provider.isEmpty ? nil : provider,
                        modelID: modelID.isEmpty ? nil : modelID,
                        prompt: prompt,
                        thinkingLevel: thinking == "off" ? nil : thinking,
                        noContextFiles: noContextFiles,
                        recordPayloads: recordPayloads)
                    onStart()
                } label: {
                    Label("Start run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            }
            .padding(14)
        }
        .onAppear {
            if cwd.isEmpty { cwd = model.defaultCwd }
            if model.engineChoice != .claudeCode { lastDirectEngine = model.engineChoice }
            // Seeded from the remembered engine, so reopening the sheet after a driven run
            // does not show `litellm` above an engine segment that says Claude Code. The
            // defaults in settings describe a provider route and cannot express this one.
            if model.engineChoice == .claudeCode {
                provider = "claude-code"
                if !modelsForProvider.contains(where: { $0.id == modelID }) {
                    modelID = model.claudeCodeModel
                }
            } else {
                if provider.isEmpty || provider == "claude-code" {
                    provider = model.settings.defaultProvider ?? providers.first ?? ""
                }
                if modelID.isEmpty
                    || !modelsForProvider.contains(where: { $0.id == modelID })
                {
                    modelID = model.settings.defaultModel ?? modelsForProvider.first?.id ?? ""
                }
            }
            thinking = model.settings.defaultThinkingLevel ?? "high"
        }
    }

    /// What each engine actually is, in the terms that matter when choosing one.
    ///
    /// The third entry is a different kind of thing from the first two and the text says so:
    /// the first two are Aviary's loop over a provider, and the third is somebody else's loop
    /// over Aviary's kernel. Hiding that behind a neutral label would make the picker lie.
    private var engineExplanation: String {
        switch model.engineChoice {
        case .inHouse:
            return "Aviary's durable Work Host owns the agent loop, provider client and Python "
                + "runtime. This GUI is an attached client: Work and its canonical transcript "
                + "survive a closed window or quit, and another GUI can reattach later. The "
                + "selected local folder is registered as a host workspace; only its opaque "
                + "ID crosses the service boundary. Steering, queued follow-ups, payload "
                + "recording and explicit End are available when the Work advertises them."
        case .claudeCode:
            return "Claude Code drives, and Aviary's kernel is the only tool it gets — its "
                + "loop, its history, its stopping decision; your interpreter, your skills, "
                + "your memory. Tokens come out of the Claude plan rather than metered API "
                + "credit, which is the point. What you give up: steering, sub-agents, model "
                + "switching mid-run, and resuming an Aviary session, because the "
                + "conversation belongs to Claude Code and it will not accept a prepared one."
        }
    }

    /// Hoisted out of the card's body: a multi-part string literal inside a ViewBuilder is
    /// enough to push the type checker past its limit here, and it reports the failure on an
    /// unrelated line when it does.
    private static let recordPayloadsExplanation =
        "Captures every provider request — system prompt, context files, skill catalogue, "
        + "tool schemas, messages — so the run can show where its input tokens went. Writes "
        + "them to a file in Aviary's support directory, which is why it is off by default."

    /// In catalogue order, de-duplicated by first appearance, so the picker agrees with the
    /// switcher and both follow your ordering.
    private var providers: [String] {
        var seen = Set<String>()
        return offeredModels.compactMap {
            seen.insert($0.providerID).inserted ? $0.providerID : nil
        }
    }

    private var modelsForProvider: [ModelSpec] {
        offeredModels.filter { $0.providerID == provider }
    }

    /// Every reachable route, `claude-code` included, whichever engine is selected.
    ///
    /// It is deliberately *not* filtered by engine. Filtering was the first attempt and it was
    /// wrong in a way that only shows up in use: `claude-code` was absent from the provider
    /// list until you had already found the Engine segment and switched it, so somebody looking
    /// for "Claude Code plus a Claude model" in the obvious place found four providers and
    /// concluded the feature was missing.
    ///
    /// Picking it instead *sets* the engine — see the provider picker's `onChange`. The two
    /// controls stay in step in both directions, and the engine segment remains because
    /// Harness versus In-house is a real choice that no model selection expresses.
    private var offeredModels: [ModelSpec] { model.pickerModels }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: cwd.isEmpty ? model.defaultCwd : cwd)
        if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
    }
}

/// A deliberately path-free status projection for the co-located Work Host. The directory
/// picker above is an administrator control; once the host has registered it, the GUI displays
/// only the host identity, catalog revision, and opaque workspace labels/IDs.
struct WorkHostStatusRow: View {
    let handshake: WorkServiceHandshakeResponse?
    let catalog: WorkHostWorkspaceCatalog
    let error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(error == nil && handshake != nil ? Design.success : Design.warning)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                if let handshake {
                    Text(
                        "Work Host \(handshake.host.workHostID) · catalog \(catalog.revision) · "
                            + "\(catalog.entries.count) workspace"
                            + (catalog.entries.count == 1 ? "" : "s")
                    )
                        .font(Design.mono(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !catalog.isComplete {
                        Text("Workspace catalog is incomplete; new Work is withheld.")
                            .font(.system(size: 10))
                            .foregroundStyle(Design.warning)
                    }
                } else {
                    Text(error ?? "Connecting to the local Work Host…")
                        .font(.system(size: 10))
                        .foregroundStyle(error == nil ? .secondary : Design.warning)
                }
            }
        }
    }
}

/// The facts about a model that change how you'd use it, including the ones that are
/// easy to be wrong about.
struct ModelFactsRow: View {
    var model: ModelSpec
    var requestedThinking: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let w = model.contextWindow {
                    Chip(text: "\(Fmt.tokens(w)) ctx", tint: .secondary)
                }
                if let m = model.maxTokens {
                    Chip(text: "\(Fmt.tokens(m)) out", tint: .secondary)
                }
                if model.reasoning {
                    Chip(text: "reasoning", symbol: "brain", tint: Design.thinking)
                }
                if model.supportsImages { Chip(text: "images", symbol: "photo", tint: .secondary) }
                if let i = model.costInput, let o = model.costOutput {
                    Chip(text: "$\(fmt(i))/$\(fmt(o))", tint: Design.accent)
                        .help("per million tokens, input / output")
                }
            }
            // A thinking level that the provider maps to null does not reach the model at
            // all. That is silent in the harness and expensive to discover by experiment.
            if let requested = requestedThinking,
               model.deadThinkingLevels.contains(requested)
            {
                Text(
                    "This provider maps “\(requested)” to nothing — the request would carry "
                    + "no reasoning effort. Levels that do map through: "
                        + mappedLevels.joined(separator: ", ") + "."
                )
                    .font(.system(size: 10))
                    .foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mappedLevels: [String] {
        guard let map = model.thinkingLevelMap else { return ["all"] }
        return map.filter { $0.value != nil }.keys.sorted()
    }

    private func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
    }
}

// MARK: - Run inspector

struct RunInspector: View {
    var run: LiveRun
    @Binding var selectedItem: TranscriptItem?
    @State private var showBreakdown = false
    @State private var showRaw = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card("Run", symbol: "info.circle") {
                    VStack(alignment: .leading, spacing: 5) {
                        DetailRow(label: "Started", value: run.startedLabel)
                        DetailRow(label: "Elapsed", value: run.elapsedLabel)
                        if run.isServiceBacked {
                            DetailRow(label: "Workspace", value: run.projectName, mono: true)
                        } else {
                            DetailRow(label: "Working dir", value: run.config.cwd, mono: true)
                        }
                        if let id = run.sessionID {
                            DetailRow(label: "Session id", value: id, mono: true)
                        }
                        if let identity = run.config.identity {
                            DetailRow(label: "Work host", value: identity.workHostID, mono: true)
                            DetailRow(label: "Work id", value: identity.workID, mono: true)
                            DetailRow(label: "Run id", value: identity.runID, mono: true)
                        }
                        DetailRow(label: "Model", value: run.modelLabel ?? "—", mono: true)
                        DetailRow(label: "Thinking", value: run.thinkingLevel ?? "—")
                        DetailRow(
                            label: "Session saved",
                            value: run.config.persistSession ? "yes" : "no")
                        DetailRow(
                            label: "Project context",
                            value: run.config.noContextFiles ? "skipped" : "included")
                    }
                }

                if let driver = run.inHouse {
                    ScheduleCard(driver: driver)
                }

                if let driver = run.claudeCode {
                    ClaudeCodeRunCard(driver: driver)
                }

                if run.isServiceBacked {
                    ServiceWorkCard(run: run)
                }

                if let context = run.recordedModelContext {
                    RecordedModelContextCard(projection: context)
                }

                if let workingState = run.canonicalWorkingState {
                    CanonicalWorkingStateCard(projection: workingState)
                }

                Card("Tokens", symbol: "number") {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            StatTile(label: "in", value: Fmt.tokens(run.usage.input))
                            StatTile(label: "out", value: Fmt.tokens(run.usage.output))
                            StatTile(label: "cached", value: Fmt.tokens(run.usage.cacheRead))
                        }
                        if run.usage.cost.total > 0 {
                            DetailRow(
                                label: "Cost", value: Fmt.cost(run.usage.cost.total), mono: true)
                        }
                        if let rate = run.usage.cacheHitRate {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("cache hit rate").font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Fmt.percent(rate)).font(
                                        Design.numeric(10, weight: .semibold))
                                }
                                RatioBar(fraction: rate, tint: Design.tool)
                            }
                        }
                    }
                }

                if hasQueuedInspectorRows {
                    Card("Input delivery", symbol: "tray.full") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(run.servicePendingInputs) { row in
                                canonicalInputRow(row)
                            }
                            ForEach(run.serviceInputDeliveryAttention) { row in
                                canonicalInputRow(row)
                            }
                            ForEach(Array(run.queuedSteering.enumerated()), id: \.offset) { _, m in
                                queueItem(m, label: "local steer", tint: Design.warning)
                            }
                            ForEach(Array(run.queuedFollowUps.enumerated()), id: \.offset) { _, m in
                                queueItem(m, label: "local follow-up", tint: Design.accent)
                            }
                        }
                    }
                }

                if !run.stderrTail.isEmpty {
                    Card("Engine stderr", symbol: "exclamationmark.bubble") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "Where the useful failures land — a 401 naming an unresolved "
                                    + "variable, a version-conflict refusal."
                            )
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            CodeBlock(
                                text: run.stderrTail.suffix(30).joined(),
                                maxLines: 12, tint: Design.danger)
                        }
                    }
                }

                if run.recordedModelContext == nil {
                    wireContextCard
                }

                Card("Launch command", symbol: "terminal") {
                    CodeBlock(text: run.launchCommand, maxLines: 8, tint: .secondary)
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $showBreakdown) {
            if let analysis = run.latestAnalysis {
                VStack(spacing: 0) {
                    HStack {
                        Text("Provider wire capture")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Done") { showBreakdown = false }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(12)
                    Divider()
                    ContextBreakdownView(
                        analysis: analysis,
                        actualInputTokens: run.lastInputTokens,
                        recordedAt: run.wireRecords.last(where: { $0.kind == .request })?.at)
                }
                .frame(width: 820, height: 720)
            }
        }
        .sheet(isPresented: $showRaw) {
            RawPayloadSheet(records: run.wireRecords)
        }
    }

    @ViewBuilder
    private var wireContextCard: some View {
        if run.config.recordPayloads {
            Card(
                "Provider wire capture", symbol: "waveform.path.ecg",
                 accessory: AnyView(
                    HStack(spacing: 8) {
                        Button("Breakdown") { showBreakdown = true }
                            .buttonStyle(.link).font(.system(size: 10))
                            .disabled(run.latestAnalysis == nil)
                        Button("Raw") { showRaw = true }
                            .buttonStyle(.link).font(.system(size: 10))
                            .disabled(run.wireRecords.isEmpty)
                    })
            ) {
                if let analysis = run.latestAnalysis {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Inferred from a recorded provider payload. This is diagnostic wire "
                                + "evidence, not canonical source provenance."
                        )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        DetailRow(
                            label: "Payload",
                            value:
                                "\(Fmt.bytes(analysis.totalCharacters)) · ≈\(Fmt.tokens(analysis.estimatedTokens)) tokens"
                        )
                        if let actual = run.lastInputTokens {
                            DetailRow(label: "Billed input", value: Fmt.tokens(actual), mono: true)
                        }
                        Divider().opacity(0.5)
                        // The three or four biggest parts answer the question on their own.
                        ForEach(analysis.segments.prefix(4)) { seg in
                            HStack(spacing: 6) {
                                Text(seg.label)
                                    .font(.system(size: 10.5))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(
                                    String(
                                        format: "%.0f%%",
                                        100 * seg.share(of: analysis.totalCharacters))
                                )
                                    .font(Design.numeric(10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Wire recording is on. The first provider request will appear here.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func queueItem(_ text: String, label: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Chip(text: label, tint: tint)
            Text(text).font(.system(size: 10.5)).lineLimit(3)
            Spacer()
        }
    }

    private var hasQueuedInspectorRows: Bool {
        !run.servicePendingInputs.isEmpty
            || !run.serviceInputDeliveryAttention.isEmpty
            || !run.queuedSteering.isEmpty
            || !run.queuedFollowUps.isEmpty
    }

    private func canonicalInputRow(_ row: CanonicalInputDeliveryRow) -> some View {
        let presentation = canonicalInputPresentation(row)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Chip(text: presentation.label, tint: presentation.tint)
                Spacer(minLength: 4)
                if let sequence = row.hostSequence {
                    Text("host #\(sequence)")
                        .font(Design.numeric(9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(canonicalInputDetail(row))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.hint)
        .help(presentation.hint)
    }

    private func canonicalInputPresentation(
        _ row: CanonicalInputDeliveryRow
    ) -> (label: String, tint: Color, accessibilityLabel: String, hint: String) {
        switch row.state {
        case .acceptedWaitingDelivery:
            return (
                "host accepted · waiting", Design.warning,
                "Accepted by Work Host, waiting for delivery",
                "Do not retry while runtime delivery remains unresolved.")
        case .delivered:
            return (
                "delivered", Design.success, "Delivered to runtime",
                "Canonical Work records prove delivery.")
        case .notDelivered:
            return (
                "not delivered", Design.danger, "Not delivered to runtime",
                "Review Work before choosing whether to send again.")
        case .indeterminateUnknownEffect:
            return (
                "delivery uncertain", Design.warning, "Delivery outcome uncertain",
                "Inspect Work before retrying; the input may have taken effect.")
        case .provenanceUnavailable:
            return (
                "evidence unavailable", .secondary, "Delivery evidence unavailable",
                "Refresh or inspect canonical Work before inferring delivery.")
        }
    }

    private func canonicalInputDetail(_ row: CanonicalInputDeliveryRow) -> String {
        let kind = row.commandKind?.rawValue.replacingOccurrences(of: "_", with: " ")
            ?? "input"
        let delivery = row.deliveryMode?.rawValue.replacingOccurrences(of: "_", with: " ")
        if let delivery { return "\(kind) · \(delivery)" }
        return kind
    }
}

/// The service-backed inspector is intentionally made from canonical Work/Session projections,
/// not transport logs or GUI timestamps. It gives a person enough evidence to understand what
/// the agent is doing while retaining the bounded-display and recovery caveats beside it.
private struct ServiceWorkCard: View {
    let run: LiveRun

    private var projection: WorkServiceAttachedWorkProjection? { run.serviceProjection }

    var body: some View {
        if let projection {
            Card("Work Host", symbol: "server.rack") {
                VStack(alignment: .leading, spacing: 7) {
                    DetailRow(label: "Host", value: projection.descriptor.work.workHostID, mono: true)
                    DetailRow(label: "Work", value: projection.descriptor.work.workID, mono: true)
                    DetailRow(label: "Workspace", value: run.serviceWorkspaceLabel ?? "—")
                    DetailRow(label: "Connection", value: connectionLabel)
                    DetailRow(label: "Execution", value: run.serviceExecutionLabel ?? "unknown")
                    if let currentRun = projection.descriptor.currentRun {
                        DetailRow(label: "Current run", value: currentRun.runID, mono: true)
                    }

                    if let pending = projection.pendingCommand {
                        Divider().opacity(0.5)
                        Label(
                            "\(pending.kind.rawValue) is \(pending.state.rawValue); refresh and "
                                + "reconcile explicitly before retrying.",
                            systemImage: "exclamationmark.triangle"
                        )
                            .font(.system(size: 10))
                            .foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Button("Refresh") {
                                Task { await run.refreshService() }
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Retry exact command") {
                                Task { _ = await run.retryServiceCommand() }
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(
                                    run.hasExited || run.isEnding
                                        || pending.state == .awaitingCanonicalEvidence
                                        || !run.serviceRetryAvailable)
                                .help(
                                    run.serviceRetryAvailable
                                        ? "Retry the exact retained command"
                                        : "Retry is disabled because this Session no longer owns the active Run")
                            if pending.state == .stale {
                                Button("Abandon stale") {
                                    Task { _ = await run.abandonStaleServiceCommand() }
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(Design.warning)
                                    .disabled(run.hasExited || run.isEnding)
                            }
                        }
                    }

                    if let omissions = run.serviceProjectionOmissionSummary {
                        Divider().opacity(0.5)
                        Label(
                            omissions + " This does not disable healthy commands.",
                            systemImage: "ellipsis.circle"
                        )
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if projection.needsRecovery || projection.requiresRefresh {
                        Label(
                            projection.requiresRefresh
                                ? "Canonical state is catching up; commands wait for refresh."
                                : "Recovery is required before this Work can accept commands.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                            .font(.system(size: 10))
                            .foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !run.serviceActionPresentations.isEmpty {
                        Divider().opacity(0.5)
                        let current = run.serviceActionPresentations.filter { !$0.state.isTerminal }
                        let recent = run.serviceActionPresentations.filter(\.state.isTerminal)
                        if !current.isEmpty {
                            Text("CURRENT ACTIONS")
                                .font(Design.sectionTitle)
                                .foregroundStyle(.secondary)
                            ForEach(current) { action in
                                WorkActionLensRow(action: action)
                            }
                        }
                        if !recent.isEmpty {
                            Text("RECENT OUTCOMES")
                                .font(Design.sectionTitle)
                                .foregroundStyle(.secondary)
                                .padding(.top, current.isEmpty ? 0 : 3)
                            ForEach(Array(recent.prefix(8))) { action in
                                WorkActionLensRow(action: action)
                            }
                        }
                    } else {
                        Text("No canonical actions recorded yet.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var connectionLabel: String {
        guard let projection else { return "unknown" }
        switch projection.connectivity {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .reconnecting: return "reconnecting"
        case .discovering: return "discovering"
        case .unavailable: return "unavailable"
        case .incompatible: return "incompatible"
        case .disconnected: return "disconnected"
        }
    }
}

// MARK: - Notification helper

extension View {
    /// A small bridge from NotificationCenter to SwiftUI, for menu commands that need to
    /// reach a view rather than the model.
    func onNotification(_ name: Notification.Name, perform: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in perform() }
    }
}

// MARK: - Schedules

/// Work a session does on its own, and a way to add some.
///
/// Only shown for in-house runs, because only they have a scheduler. The harness's own cron
/// jobs are readable through `list --json` but not settable from here, and offering one control
/// that silently does nothing for half the runs would be worse than offering none.
private struct ScheduleCard: View {
    let driver: InHouseDriver
    @State private var prompt = ""
    @State private var minutes = 15.0
    @State private var whenIdle = true
    @State private var adding = false

    var body: some View {
        Card(
            "On its own", symbol: "clock.arrow.2.circlepath",
             accessory: AnyView(
                Button {
                    adding.toggle()
                } label: {
                    Image(systemName: adding ? "xmark" : "plus").font(
                        .system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary))
        ) {
            VStack(alignment: .leading, spacing: 7) {
                if driver.jobs.isEmpty && !adding {
                    Text(
                        "Nothing scheduled. This session can poke itself on an interval — "
                            + "useful for watching a build, or checking back on something slow."
                    )
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(driver.jobs) { job in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: job.onlyWhenIdle ? "moon.zzz" : "clock")
                            .font(.system(size: 9)).foregroundStyle(Design.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.prompt)
                                .font(.system(size: 11)).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(job.summary)
                                .font(Design.numeric(9)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            driver.removeJob(id: job.id)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 8.5))
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                if adding {
                    Divider().opacity(0.5)
                    TextField("What should it ask?", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11)).lineLimit(1...3)
                    HStack(spacing: 6) {
                        Text("every")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        // Minutes, not a cron expression: every real case in the corpus was
                        // "every N minutes", and a cron parser is a class of bugs bought for a
                        // case nobody had.
                        Stepper("\(Int(minutes))m", value: $minutes, in: 1...240, step: 5)
                            .font(.system(size: 10))
                        Spacer(minLength: 4)
                        Toggle("only when idle", isOn: $whenIdle)
                            .toggleStyle(.checkbox).font(.system(size: 10))
                        Button("Add") {
                            driver.addJob(
                                prompt: prompt, everyMinutes: minutes, onlyWhenIdle: whenIdle)
                            prompt = ""
                            adding = false
                        }
                        .controlSize(.small)
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.mini)
                }
            }
        }
    }
}

/// What is only true of a driven run.
///
/// Two facts earn a card of their own. Which allowance the run is spending is the entire
/// economic premise of this session type, and it comes from Claude Code rather than from
/// anything Aviary can compute — so it is reported, never inferred. And Claude Code's own
/// session id is what `claude --resume` takes, which is the only way to reopen this
/// conversation with its history intact.
private struct ClaudeCodeRunCard: View {
    var driver: ClaudeCodeDriver

    var body: some View {
        Card("Claude Code", symbol: "wand.and.stars") {
            VStack(alignment: .leading, spacing: 7) {
                if let limit = driver.rateLimit {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(limit.usingOverage ? Design.warning : Design.success)
                            .frame(width: 6, height: 6)
                        Text(limit.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(limit.usingOverage ? Design.warning : .secondary)
                        Spacer()
                        if let resets = limit.resetsAt {
                            Text("resets \(Fmt.relative(resets))")
                                .font(Design.numeric(10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if let auth = driver.authSummary {
                    DetailRow(label: "Login", value: auth)
                }
                if let id = driver.claudeSessionID {
                    DetailRow(label: "Claude session", value: id, mono: true)
                    Text(
                        "`claude --resume \(id)` reopens this conversation in Claude Code "
                            + "itself, with the history Aviary cannot replay."
                    )
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let runtime = driver.runtimeSummary {
                    DetailRow(label: "Kernel", value: runtime, mono: true)
                }
                if let skills = driver.skillsNote {
                    DetailRow(label: "Skills", value: skills)
                }
                if let memory = driver.memoryNote {
                    DetailRow(label: "Memory", value: memory)
                }
                ForEach(Array(driver.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(Design.warning)
                        Text(warning)
                            .font(.system(size: 10)).foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
