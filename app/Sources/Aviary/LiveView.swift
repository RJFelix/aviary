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
                        model.focusRun(run)
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
    private struct ForwardedMessage: Identifiable {
        let id = UUID()
        let text: String
    }
    private struct SelectedCommand: Identifiable {
        let id = UUID()
        let command: SuggestedShellCommand
        let run: LiveRun
    }

    /// One sheet value captures both sides of the review association at the tap boundary.
    /// Keeping this as one item avoids an `isPresented` closure observing a newer descriptor
    /// state than the transcript button that opened it.
    private struct SelectedRepositoryReview: Identifiable {
        let id = UUID()
        let run: LiveRun
        let descriptor: WorkServiceArtifactDescriptor
    }

    @Environment(AppModel.self) private var model
    @Environment(\.usesChatWindowTitle) private var usesChatWindowTitle
    var run: LiveRun
    /// Cockpit owns its two-column layout, so it reuses the chat/composer without a third
    /// technical column. Live keeps the detailed inspector.
    var showsInspector = true

    @State private var showLaunchDetails = false
    @State private var selectedItem: TranscriptItem?
    @State private var selectedAction: SelectedAction?
    @State private var forwardedMessage: ForwardedMessage?
    @State private var selectedCommand: SelectedCommand?
    @State private var confirmEndRun = false
    @State private var showInputDeliveryReview = false
    @State private var showCockpitInspector = false
    @State private var selectedRepositoryReview: SelectedRepositoryReview?
    @State private var showActivityHistory = false
    @State private var showProjectReconfirmation = false
    @State private var projectCheckError: String?
    /// Persisted once for the person, shared by every busy composer. The choice controls the
    /// primary strip styling and Return; capability resolution still happens per Work.
    @AppStorage(ChatBusyDeliveryPreference.storageKey)
    private var busyDeliveryPreferenceRawValue = ChatBusyDeliveryPreference.default.rawValue

    // Fixed trailing inspector column rather than `.inspector` or a conditional split
    // pane — see the note on SessionsView.body for why both of those misbehave.
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                runHeader
                Divider()
                if let prompt = model.pendingChats.first(where: {
                    $0.createdAssociation != nil && $0.createdAssociation == run.serviceAttachmentKey
                })?.prompt ?? run.savedInitialPrompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("You · saved on this Mac", systemImage: "person.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ScrollView {
                            Text(prompt).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 160)
                        if let pending = run.serviceProjection?.pendingCommand, pending.kind == .start,
                           !run.serviceCommandAttemptActive, pending.state != .awaitingCanonicalEvidence {
                            HStack(spacing: 8) {
                                Button("Check delivery") { Task { await run.refreshService() } }
                                Button("Retry saved startup") { Task { _ = await run.retryServiceCommand() } }
                                    .disabled(run.hasExited || run.isEnding
                                        || pending.state == .awaitingCanonicalEvidence
                                        || !run.serviceRetryAvailable)
                            }.buttonStyle(.bordered).controlSize(.small)
                            Text("Retry uses the original saved request, not a new copy.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if run.serviceCommandAttemptActive || run.commandState == .preparing
                            || run.commandState == .committing {
                            Label("Starting…", systemImage: "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(Design.accentSoft.opacity(0.4))
                    Divider()
                }
                ChatStatusPanel(
                    presentation: model.chatStatus(for: run, projectCheckError: projectCheckError),
                    onConfirmProject: model.projectIssue(for: run) == nil ? nil : {
                        showProjectReconfirmation = true
                    },
                    onCheckProject: model.projectIssue(for: run) == nil ? nil : {
                        Task {
                            do {
                                try await model.refreshProjectAvailability()
                                projectCheckError = nil
                            } catch { projectCheckError = AppModel.serviceErrorMessage(error) }
                        }
                    },
                    onReviewDelivery: run.serviceInputDeliveryOmissionSummary == nil ? nil : {
                        showInputDeliveryReview = true
                    })
                if let action = run.currentServiceActions.first {
                    WorkActivityStrip(
                        action: action,
                        concurrentActions: run.currentServiceActions,
                        sourceIsCurrent: run.serviceActivitySourceIsCurrent,
                        onInspect: {
                            selectedAction = SelectedAction(id: $0.id)
                        })
                    Divider()
                } else if run.isServiceBacked && run.isStreaming {
                    Label(
                        run.serviceActivitySourceIsCurrent
                            ? "Agent is working · current step has not been reported"
                            : "Waiting to refresh agent activity",
                        systemImage: "ellipsis")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Design.gutter).padding(.vertical, 8)
                    Divider()
                }
                if run.childActivity.hasRecords {
                    Button { showActivityHistory = true } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "person.2")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recorded child agents").font(.system(size: 11, weight: .medium))
                                Text(run.childActivity.summary)
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, Design.gutter).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-child-activity")
                    .accessibilityHint("Shows recorded child lifecycle counts and their limits")
                    Divider()
                }
                let backgroundAgents = run.isServiceBacked
                    ? ChatAgentHandleActivityPresentation(
                        workingState: run.canonicalWorkingState,
                        sourceIsCurrent: run.serviceActivitySourceIsCurrent)
                    : nil
                if let backgroundAgents,
                   backgroundAgents.hasRecords || !backgroundAgents.isAvailable {
                    Button { showActivityHistory = true } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "person.2.wave.2")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recorded background agents")
                                    .font(.system(size: 11, weight: .medium))
                                Text(backgroundAgents.summary)
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, Design.gutter).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-recorded-background-agents")
                    .accessibilityHint("Shows recorded Work-owned agent states; this is not process liveness")
                    Divider()
                }
                TranscriptView(
                    items: run.items,
                    hideThinking: model.hideThinking,
                    isStreaming: run.isStreaming,
                    indicatesCurrentActivity: !run.isServiceBacked || run.serviceActivitySourceIsCurrent,
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
                    reviewDescriptorsByMessageID: run.serviceReviewsByTranscriptID,
                    onReviewMessage: { id in
                        guard let descriptor = run.serviceReviewsByTranscriptID[id] else { return }
                        selectedRepositoryReview = SelectedRepositoryReview(
                            run: run, descriptor: descriptor)
                    },
                    onForwardMessage: { forwardedMessage = ForwardedMessage(text: $0) },
                    onAskAgentToRun: { selectedCommand = SelectedCommand(command: $0, run: run) },
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
            "End the agent session?",
            isPresented: $confirmEndRun,
            titleVisibility: .visible
        ) {
            Button("End agent session", role: .destructive) {
                Task { await run.end() }
            }
            Button("Keep session open", role: .cancel) {}
        } message: {
            Text(
                run.isServiceBacked
                    ? "This ends the current agent session and releases its runtime. The chat stays saved. "
                        + "To leave without interrupting the agent, just select another chat or close the window."
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
        .sheet(item: $forwardedMessage) { message in
            AgentMessageForwardingView(text: message.text,
                sourceProject: run.config.cwd, sourceRunID: run.id)
        }
        .sheet(item: $selectedCommand) { selection in
            SuggestedCommandSheet(command: selection.command, run: selection.run)
        }
        .sheet(isPresented: $showInputDeliveryReview) {
            InputDeliveryReviewSheet(
                pending: run.servicePendingInputs,
                attention: run.serviceInputDeliveryAttention,
                omissionSummary: run.serviceInputDeliveryOmissionSummary)
        }
        .sheet(isPresented: $showCockpitInspector) {
            VStack(spacing: 0) {
                HStack {
                    Text("Chat details").font(.headline)
                    Spacer()
                    Button("Done") { showCockpitInspector = false }
                        .keyboardShortcut(.cancelAction)
                }.padding()
                Divider()
                RunInspector(run: run, selectedItem: $selectedItem)
            }
                .frame(minWidth: 360, idealWidth: 420, minHeight: 520, idealHeight: 720)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Run context and working state")
        }
        .sheet(item: $selectedRepositoryReview) { selection in
            RepositoryReviewView(run: selection.run, descriptor: selection.descriptor)
                .frame(minWidth: 560, idealWidth: 760, minHeight: 620, idealHeight: 780)
        }
        .sheet(isPresented: $showActivityHistory) {
            ChatActivityHistoryView(run: run)
                .frame(minWidth: 400, idealWidth: 580, minHeight: 480, idealHeight: 660)
        }
        .sheet(isPresented: $showProjectReconfirmation) {
            ProjectReconfirmationSheet(initialDirectory: run.config.cwd,
                prepare: { try model.prepareProjectReconfirmation(for: run, directory: $0) },
                confirm: { try await model.confirmProjectReconfirmation($0, for: run) })
        }
    }

    private var headerStatus: ChatRunHeaderStatusPresentation {
        ChatRunHeaderStatusPresentation.resolve(
            commandState: run.commandState, isStreaming: run.isStreaming,
            hasExited: run.hasExited, isServiceBacked: run.isServiceBacked,
            serviceSourceIsCurrent: run.serviceActivitySourceIsCurrent)
    }

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !usesChatWindowTitle {
            HStack(spacing: 8) {
                if headerStatus.showsPulse {
                    PulseDot()
                } else {
                    Image(systemName: headerStatus.symbol)
                        .font(.system(size: headerStatus.isNeutral || run.hasExited ? 11 : 7))
                        .foregroundStyle(headerStatus.isNeutral || run.hasExited
                            ? Color.secondary : Design.accent)
                }
                Text(run.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Chip(
                    text: headerStatus.label,
                    tint: headerStatus.isNeutral ? .secondary : run.presentationState == "failed"
                        ? Design.danger
                        : run.presentationState == "working" ? Design.success : .secondary)
                if run.isCompacting { Chip(text: "compacting", tint: Design.warning) }
                if run.hasExited {
                    Chip(
                        text: run.exitCode.map { "exited \($0)" } ?? "exited",
                         tint: (run.exitCode ?? 0) == 0 ? .secondary : Design.danger)
                }
                Spacer()
            }
            }
            runMetadata

            HStack(spacing: 8) {
                if !run.serviceActionPresentations.isEmpty || run.childActivity.hasRecords
                    || (run.isServiceBacked && ChatAgentHandleActivityPresentation(
                        workingState: run.canonicalWorkingState,
                        sourceIsCurrent: run.serviceActivitySourceIsCurrent).hasRecords)
                    || (run.isServiceBacked && run.canonicalWorkingState?.agentHandleFactsAvailable != true) {
                    Button { showActivityHistory = true } label: {
                        Label("Agent activity", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("See current and recently recorded agent actions")
                    .accessibilityLabel("Activity")
                }
                if run.canLoadServiceRepositoryReview {
                    ViewThatFits(in: .horizontal) {
                        Button {
                            presentLatestRepositoryReview()
                        } label: {
                            Label("Review latest", systemImage: "doc.text.magnifyingglass")
                        }
                        Button {
                            presentLatestRepositoryReview()
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .frame(width: 20, height: 20)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .accessibilityLabel("Review latest changes")
                    .accessibilityHint(
                        "Opens the latest saved working-tree observation for this Work")
                    .help("Review latest saved working-tree changes")
                }
                if !showsInspector {
                    Button {
                        showCockpitInspector = true
                    } label: {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help("View chat settings, model context, and runtime details")
                    .accessibilityLabel("Chat details")
                    .accessibilityHint(
                        "Opens recorded provider context and current durable Work and Session evidence")
                }
                Spacer(minLength: 0)
                controls
            }

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
        .preference(key: ChatWindowTitleKey.self, value: run.title)
        .preference(key: ChatWindowSubtitleKey.self, value: headerStatus.label)
    }

    private func presentLatestRepositoryReview() {
        guard let descriptor = run.serviceReviewDescriptor else { return }
        selectedRepositoryReview = SelectedRepositoryReview(
            run: run, descriptor: descriptor)
    }

    private var runMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Label(run.projectName, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(run.config.cwd)
                if let m = run.modelLabel, !m.isEmpty {
                    Label(m, systemImage: "cpu")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let level = run.thinkingLevel {
                    Label(level, systemImage: "brain")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !run.usage.isEmpty {
                    Chip(
                        text: Fmt.tokens(run.usage), symbol: "number", tint: .secondary)
                }
                if run.usage.cost.total > 0 || run.usage.completeness.cost != .neutral {
                    Chip(text: Fmt.cost(run.usage), tint: Design.accent)
                }
                if run.hasCanonicalStartTime && run.elapsedLabel != "time unknown" {
                    Chip(text: run.elapsedLabel, symbol: "clock", tint: .secondary)
                }
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
                Label(run.projectName, systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(run.config.cwd)
                if let m = run.modelLabel, !m.isEmpty {
                    Label(m, systemImage: "cpu")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if run.hasCanonicalStartTime && run.elapsedLabel != "time unknown" {
                    Chip(text: run.elapsedLabel, symbol: "clock", tint: .secondary)
                }
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
        HStack(spacing: 6) {
            if !run.hasExited && run.isStreaming
                && (run.commandCapabilities.supports(.agentLoop) || run.commandState == .canceling) {
                Button {
                    Task { _ = await run.cancel(.agentLoop) }
                } label: {
                    Label(run.commandState == .canceling ? "Stopping…" : "Stop",
                          systemImage: "stop.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(run.commandState == .canceling || run.isEnding
                    || !run.commandCapabilities.supports(.agentLoop))
                .help(ChatInteractionPresentation.stopExplanation)
                .accessibilityHint(ChatInteractionPresentation.stopExplanation)
            }
            RunOptionsMenu(
                run: run,
                models: model.pickerModels,
                hasExited: run.hasExited,
                isWorking: run.isStreaming,
                isCanceling: run.commandState == .canceling,
                cancellationScopes: run.commandCapabilities.cancellationScopes,
                sessionFile: run.sessionFile,
                onEnd: { confirmEndRun = true })
        }
    }
    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if composerStatus.kind == .blocked || composerReceiptPending {
                    Label(composerStatus.text, systemImage: composerStatus.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(composerStatus.kind == .blocked
                            && composerStatus.symbol != "hourglass"
                            ? Design.warning : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat-composer-status")
                }
                VStack(spacing: 0) {
                    ChatMessageEditor(text: Binding(
                        get: { run.draft },
                        set: { run.setDraft($0) }),
                        placeholder: composerPlaceholder,
                        canSubmit: composerCanSubmit,
                        onSubmit: submitComposer,
                        accessibilityLabel: composerAccessibilityLabel)
                        .id(run.id)
                        .frame(minHeight: 64, maxHeight: 115)
                HStack(spacing: 8) {
                    if run.isStreaming {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text("⇧ Return for a new line")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                                busyActionStrip
                            }
                            busyActionStrip
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text("⇧ Return for a new line")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
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
                        .accessibilityValue(composerCanSubmit ? "Ready" : composerStatus.text)
                        .accessibilityHint(composerStatus.text + ". Return sends; Shift-Return adds a new line.")
                        .help("\(composerStatus.text) (↵)")
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1))
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
                            Button("Check delivery") {
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

        }
        .background(.bar)
    }

    private var availableComposerDeliveries: [ChatBusyDelivery] {
        guard run.isStreaming else { return [] }
        return ChatBusyDelivery.available(
            supportsGuidance: run.commandCapabilities.supportsSteering,
            supportsFollowUp: run.commandCapabilities.supportsQueuedFollowUps)
    }

    private var effectiveComposerDelivery: ChatBusyDelivery? {
        let choices = availableComposerDeliveries
        return ChatBusyDeliveryPreference.load(rawValue: busyDeliveryPreferenceRawValue)
            .resolved(in: choices)
    }

    private var composerActionLabel: String {
        guard run.isStreaming else { return "Send" }
        return effectiveComposerDelivery?.buttonLabel ?? "Send unavailable"
    }

    private var composerActionSymbol: String {
        guard run.isStreaming else { return "arrow.up" }
        return switch effectiveComposerDelivery {
        case .guideCurrentWork: "arrow.turn.down.right"
        case .followUp: "text.append"
        case nil: "hourglass"
        }
    }

    private var composerStatus: ChatComposerStatusPresentation {
        ChatComposerStatusPresentation.resolve(
            submissionState: run.composerSubmissionState,
            // Storage details and their recovery controls remain together below the editor.
            persistenceNotice: nil,
            commandState: run.commandState, hasExited: run.hasExited,
            isEnding: run.isEnding,
            acceptsInput: run.acceptsInput, isStreaming: run.isStreaming,
            availableDeliveries: availableComposerDeliveries,
            effectiveDelivery: effectiveComposerDelivery,
            draftIsEmpty: run.draft.trimmingCharacters(in: .whitespaces).isEmpty,
            receiptPending: composerReceiptPending)
    }

    private var composerReceiptPending: Bool {
        ChatAcceptedMessageRefreshPolicy.shouldShow(
            notice: run.commandNotice?.serviceAcknowledgement,
            noticeWasSuccessful: run.commandNotice?.level == .success,
            projection: run.serviceProjection,
            hasErrorBanner: run.errorBanner != nil)
    }

    @ViewBuilder
    private var busyActionStrip: some View {
        if availableComposerDeliveries.isEmpty
            && (run.composerSubmissionState == .active || composerReceiptPending) {
            Label(run.composerSubmissionState == .active ? "Sending…" : "Updating…",
                  systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(composerStatus.text)
        } else {
            ChatDeliveryChoiceView(
                choices: availableComposerDeliveries,
                canSubmit: composerCanSubmit,
                statusText: composerStatus.text,
                preferenceRawValue: $busyDeliveryPreferenceRawValue,
                onSubmit: { choice in submitComposer(delivery: choice) })
        }
    }

    private var composerPlaceholder: String {
        guard run.isStreaming else { return "Ask a question or describe a change…" }
        return effectiveComposerDelivery?.placeholder ?? "Draft your next message…"
    }

    private var composerAccessibilityLabel: String {
        guard run.isStreaming else { return "Message composer" }
        return switch effectiveComposerDelivery {
        case .guideCurrentWork: "Guidance for current work"
        case .followUp: "Follow-up message"
        case nil: "Unavailable message composer"
        }
    }

    private var composerAccessibilityHint: String {
        composerStatus.text
    }

    private var composerCanSubmit: Bool {
        !run.hasExited && run.acceptsInput
            && !run.draft.trimmingCharacters(in: .whitespaces).isEmpty
            && run.composerSubmissionState == .idle
            && (!run.isStreaming || effectiveComposerDelivery != nil)
    }

    private func submitComposer() {
        submitComposer(delivery: effectiveComposerDelivery)
    }

    private func submitComposer(delivery selectedBusyDelivery: ChatBusyDelivery?) {
        let text = run.draft
        let delivery: LiveRunComposerDelivery
        // A Steer/Queue click stays that exact command even if Work settles before the view
        // redraws. LiveRun revalidates admission; never silently convert the click into Send.
        switch selectedBusyDelivery {
        case .guideCurrentWork: delivery = .steerNext
        case .followUp: delivery = .queueFollowUp
        case nil:
            guard !run.isStreaming else { return }
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
    var onEnd: () -> Void
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
            Button("Stop after current step") {
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
                Text("Immediate interruption is available only where supported.")
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
            Button("Hide chat view") {
                if hasExited { model.closeRun(run) } else { model.detachRun(run) }
            }
            .help("Leaves the agent running. Reopen this chat from the chat list or agent connections.")
            if !hasExited {
                Button("End agent session…", role: .destructive, action: onEnd)
                    .disabled(run.isEnding || !run.serviceControlsAvailable)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Chat options")
        .accessibilityHint("Agent settings, interruption options, and ending the agent session")
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

/// Only the header toggles expansion; controls inside the expanded form keep their own input.
private struct LauncherSettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Expands or collapses these settings")
            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, 13)
                    .padding(.bottom, 13)
            }
        }
    }
}

struct LauncherSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("What next?", systemImage: "plus.bubble")
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

/// The launcher's request, project, agent choice, and advanced settings, shared by the modal
/// sheet and Chats' inline composer.
struct LauncherFormBody: View {
    @Environment(AppModel.self) private var model
    var onStart: () -> Void
    var initiallyShowsAdvanced = false

    @State private var cwd = ""
    @State private var projectChosen = false
    @State private var prompt = ""
    @State private var selection = LauncherSelection.seeded(
        route: .direct, defaultProviderID: nil, defaultModelID: nil,
        claudeCodeModelID: "", models: [])
    @State private var selectionWasSeeded = false
    @State private var thinking = "high"
    @State private var noContextFiles = false
    @State private var recordPayloads = false
    @State private var logDirectory: URL?
    @State private var logDirectoryError: String?
    @State private var confirmsLogReset = false
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What next?")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))

                    requestEditor

                    Card(symbol: "slider.horizontal.3") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Workspace")
                                    .font(.system(size: 13, weight: .semibold))
                                HStack(spacing: 8) {
                                    TextField("Project path", text: Binding(get: { cwd }, set: {
                                        cwd = $0
                                        projectChosen = true
                                    }))
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
                                                    projectChosen = true
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
                            }

                            Divider()

                            if model.pickerModels.isEmpty {
                                Text(
                                    model.runtimeModelsError
                                        ?? "Asking the engine which models it can reach…"
                                )
                                    .font(.system(size: 12))
                                    .foregroundStyle(
                                        model.runtimeModelsError == nil
                                            ? .secondary : Design.danger)
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        providerPicker
                                        modelPicker
                                        thinkingPicker
                                    }
                                    VStack(alignment: .leading, spacing: 8) {
                                        providerPicker
                                        modelPicker
                                        thinkingPicker
                                    }
                                }
                                if let selected = modelsForProvider.first(where: {
                                    $0.id == modelID
                                }) {
                                    ModelFactsRow(model: selected, requestedThinking: thinking)
                                }
                            }
                        }
                    }

                    if selectedEngine == .inHouse {
                        agentServiceStatus
                    }

                    DisclosureGroup("Advanced settings", isExpanded: $advancedExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Engine", selection: engineBinding) {
                                ForEach(AppModel.Engine.allCases) { engine in
                                    Text(engine == .inHouse ? "Aviary" : engine.label)
                                        .tag(engine)
                                }
                            }
                            .pickerStyle(.segmented)
                            if selectedEngine == .claudeCode {
                                if let auth = model.claudeCodeAuth {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(auth.isSubscription ? Design.success : Design.warning)
                                            .frame(width: 6, height: 6)
                                        Text(
                                            auth.isSubscription
                                                ? "\(auth.summary) — draws on the plan"
                                                : "\(auth.summary) — bills metered API credit"
                                        )
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(
                                        "No `claude` binary found, or it is not signed in. "
                                            + "Install Claude Code and run `claude /login`."
                                    )
                                        .font(.system(size: 11))
                                        .foregroundStyle(Design.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Divider().opacity(0.5)
                            Toggle("Skip AGENTS.md / CLAUDE.md discovery", isOn: $noContextFiles)
                                .disabled(selectedEngine != .claudeCode)
                            Divider().opacity(0.5)
                            Toggle("Keep full session logs locally", isOn: $recordPayloads)
                                .disabled(selectedEngine == .claudeCode)
                                .help("Records full model requests, which may contain sensitive content.")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Log destination")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                HStack(alignment: .top, spacing: 8) {
                                    Text(supportsLogDirectorySelection
                                         ? (logDirectory?.path ?? "Choose a local folder")
                                         : WireLog.directory.path)
                                        .font(Design.mono(10))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Button("Change…", action: chooseLogDirectory)
                                        .disabled(selectedEngine == .claudeCode || !supportsLogDirectorySelection)
                                }
                                Text(supportsLogDirectorySelection
                                     ? "On this Mac · applies to new chats"
                                     : (model.localWorkServiceHandshake == nil
                                        ? "Connect to the local agent service to choose a folder"
                                        : "Restart the local agent service to enable folder selection"))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                                if let logDirectoryError {
                                    Text(logDirectoryError)
                                        .font(.system(size: 11)).foregroundStyle(Design.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Reset log folder…") { confirmsLogReset = true }
                                }
                            }
                        }
                        .padding(.top, 10)
                        .controlSize(.small)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .disclosureGroupStyle(LauncherSettingsDisclosureStyle())
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 1))
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .onChange(of: model.defaultCwd) { _, value in
            if !projectChosen { cwd = value }
        }
        .alert("Use the default log folder?", isPresented: $confirmsLogReset) {
            Button("Use default folder") {
                do {
                    logDirectory = try WireLogDirectoryStore(home: model.home).resetToDefault().directory
                    logDirectoryError = nil
                    model.refreshWireIndex()
                } catch {
                    logDirectoryError = "Could not reset log settings. \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing logs are not moved or deleted. The previous settings file is backed up before replacement.")
        }
        .onAppear {
            if initiallyShowsAdvanced { advancedExpanded = true }
            loadLogDirectory()
            if cwd.isEmpty { cwd = model.defaultCwd }
            if selectionWasSeeded {
                selection = selection.selectingRoute(
                    route(for: model.engineChoice),
                    defaultProviderID: model.settings.defaultProvider,
                    defaultModelID: model.settings.defaultModel,
                    fallbackClaudeCodeModelID: model.claudeCodeModel,
                    models: offeredModels)
            } else {
                selection = LauncherSelection.seeded(
                    route: route(for: model.engineChoice),
                    defaultProviderID: model.settings.defaultProvider,
                    defaultModelID: model.settings.defaultModel,
                    claudeCodeModelID: model.claudeCodeModel,
                    models: offeredModels)
                selectionWasSeeded = true
            }
            thinking = model.settings.defaultThinkingLevel ?? "high"
        }
        .onChange(of: model.pickerModels) { _, _ in
            if selectionWasSeeded { reconcileSelection() }
        }
    }

    private var engineBinding: Binding<AppModel.Engine> {
        Binding(get: { selectedEngine }, set: { selectEngine($0) })
    }

    private var providerBinding: Binding<String> {
        Binding(get: { selection.providerID }, set: { selectProvider($0) })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { selection.modelID }, set: {
            selection = selection.selectingModel($0, models: offeredModels)
        })
    }

    private var provider: String { selection.providerID }
    private var modelID: String { selection.modelID }
    private var selectedEngine: AppModel.Engine { engine(for: selection.route) }

    private var providerPicker: some View {
        Picker("Provider", selection: providerBinding) {
            ForEach(providers, id: \.self) { Text($0).tag($0) }
        }
    }

    private var modelPicker: some View {
        Picker("Model", selection: modelBinding) {
            ForEach(modelsForProvider) { m in
                Text(m.displayName).tag(m.id)
            }
        }
    }

    private var thinkingPicker: some View {
        Picker("Thinking", selection: $thinking) {
            ForEach(
                ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
                id: \.self
            ) { Text($0).tag($0) }
        }
    }

    private var supportsLogDirectorySelection: Bool {
        model.localWorkServiceHandshake?.capabilities.contains(.recordingDirectorySelection) == true
    }

    private func loadLogDirectory() {
        do {
            logDirectory = try WireLogDirectoryStore(home: model.home).load().directory
            logDirectoryError = nil
        } catch {
            logDirectory = nil
            logDirectoryError = "Saved log settings need repair. Your request can still be saved."
        }
    }

    private func chooseLogDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Session log folder"
        panel.prompt = "Use folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = logDirectory
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            logDirectory = try WireLogDirectoryStore(home: model.home)
                .select(directory: directory).directory
            logDirectoryError = nil
            model.refreshWireIndex()
        } catch {
            logDirectoryError = "Could not save that log folder. \(error.localizedDescription)"
        }
    }

    private func selectEngine(_ engine: AppModel.Engine) {
        selection = selection.selectingRoute(
            route(for: engine),
            defaultProviderID: model.settings.defaultProvider,
            defaultModelID: model.settings.defaultModel,
            fallbackClaudeCodeModelID: model.claudeCodeModel,
            models: offeredModels)
        if model.engineChoice != engine { model.engineChoice = engine }
        if engine == .claudeCode {
            recordPayloads = false
        } else {
            noContextFiles = false
        }
    }

    private func selectProvider(_ providerID: String) {
        selection = selection.selectingProvider(
            providerID,
            defaultProviderID: model.settings.defaultProvider,
            defaultModelID: model.settings.defaultModel,
            fallbackClaudeCodeModelID: model.claudeCodeModel,
            models: offeredModels)
        let selectedEngine = engine(for: selection.route)
        if model.engineChoice != selectedEngine { model.engineChoice = selectedEngine }
        if selection.route == .claudeCode {
            recordPayloads = false
        } else {
            noContextFiles = false
        }
    }

    private func reconcileSelection() {
        selection = selection.reconciling(
            defaultProviderID: model.settings.defaultProvider,
            defaultModelID: model.settings.defaultModel,
            fallbackClaudeCodeModelID: model.claudeCodeModel,
            models: offeredModels)
    }

    private func route(for engine: AppModel.Engine) -> LauncherSelection.Route {
        engine == .claudeCode ? .claudeCode : .direct
    }

    private func engine(for route: LauncherSelection.Route) -> AppModel.Engine {
        route == .claudeCode ? .claudeCode : .inHouse
    }

    private var requestEditor: some View {
        VStack(spacing: 0) {
            ChatMessageEditor(
                text: $prompt,
                placeholder: "Describe the coding task, question, or change…",
                canSubmit: canSubmit,
                onSubmit: startChat)
                .frame(minHeight: 156)
            HStack(spacing: 8) {
                Text("⇧ Return for a new line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    startChat()
                } label: {
                    Label("Start chat", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start chat")
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1))
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startChat() {
        guard canSubmit else { return }
        if selectedEngine == .claudeCode {
            let created = model.startClaudeCodeRun(
                cwd: cwd.isEmpty ? model.defaultCwd : cwd,
                // `claudeCodeModel` remains the remembered fallback for driven runs.
                model: modelID.isEmpty ? model.claudeCodeModel : modelID,
                // Claude Code has no explicit "off" effort flag.
                effort: thinking == "off" ? nil : thinking,
                prompt: prompt, noContextFiles: noContextFiles)
            if created { onStart() }
            return
        }
        let saved = model.createPendingChat(
            cwd: cwd.isEmpty ? model.defaultCwd : cwd,
            providerID: provider.isEmpty ? nil : provider,
            modelID: modelID.isEmpty ? nil : modelID,
            prompt: prompt,
            thinkingLevel: thinking == "off" ? nil : thinking,
            noContextFiles: noContextFiles,
            recordPayloads: recordPayloads)
        if saved { onStart() }
    }

    @ViewBuilder
    private var agentServiceStatus: some View {
        if let error = model.localWorkServiceError {
            Card(model.localWorkServiceHandshake == nil ? "Agent service unavailable" : "Chat setup needs attention",
                 symbol: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You can still save this chat. Aviary will keep your request here and will not claim it was sent.")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Retry connection") {
                            Task {
                                await model.retryLocalWorkService()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Open Diagnostics") { model.section = .health }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        } else if model.localWorkServiceHandshake == nil {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Connecting to the local agent service…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// In catalogue order, de-duplicated by first appearance.
    private var allProviders: [String] {
        var seen = Set<String>()
        return offeredModels.compactMap {
            seen.insert($0.providerID).inserted ? $0.providerID : nil
        }
    }

    private var providers: [String] {
        allProviders.filter {
            selectedEngine == .claudeCode
                ? $0 == LauncherSelection.claudeCodeProviderID
                : $0 != LauncherSelection.claudeCodeProviderID
        }
    }

    private var modelsForProvider: [ModelSpec] {
        offeredModels.filter { $0.providerID == provider }
    }

    /// Every reachable route, including the built-in Claude Code route.
    private var offeredModels: [ModelSpec] { model.pickerModels }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: cwd.isEmpty ? model.defaultCwd : cwd)
        if panel.runModal() == .OK, let url = panel.url {
            cwd = url.path
            projectChosen = true
        }
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
    @Environment(AppModel.self) private var model
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
                    if let usageInventory = run.serviceWorkUsageInventory {
                        ServiceWorkUsageInventoryCard(inventory: usageInventory)
                    }
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
                            StatTile(label: "in", value: Fmt.tokens(
                                run.usage.input, completeness: run.usage.completeness.breakdown))
                            StatTile(label: "out", value: Fmt.tokens(
                                run.usage.output, completeness: run.usage.completeness.breakdown))
                            StatTile(label: "cached", value: Fmt.tokens(
                                run.usage.cacheRead, completeness: run.usage.completeness.breakdown))
                        }
                        if run.usage.cost.total > 0 || run.usage.completeness.cost != .neutral {
                            DetailRow(
                                label: "Cost", value: Fmt.cost(run.usage), mono: true)
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

                wireContextCard

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
        .onAppear {
            if run.isServiceBacked { run.refreshLocalServiceWireLog(home: model.home) }
        }
    }

    @ViewBuilder
    private var wireContextCard: some View {
        if run.config.recordPayloads {
            Card(
                "Provider wire capture", symbol: "waveform.path.ecg",
                 accessory: AnyView(
                    HStack(spacing: 8) {
                        Button(run.wireRecords.isEmpty ? "Load" : "Refresh") { run.refreshWireLog() }
                            .buttonStyle(.link).font(.system(size: 10))
                            .disabled(run.wireLogURL == nil)
                        Button("Breakdown") { showBreakdown = true }
                            .buttonStyle(.link).font(.system(size: 10))
                            .disabled(run.latestAnalysis == nil)
                        Button("Raw") { showRaw = true }
                            .buttonStyle(.link).font(.system(size: 10))
                            .disabled(run.wireRecords.isEmpty)
                    })
            ) {
                if let url = run.wireLogURL {
                    HStack(alignment: .top) {
                        Text(url.path).font(Design.mono(10)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }.buttonStyle(.link).font(.system(size: 10))
                    }
                }
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
                    Text(run.wireLogURL == nil
                         ? "The recording location is not available on this Mac."
                         : "Full model requests may contain sensitive content. Load to inspect the recording.")
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
                        let waiting = projection.commandInFlight || pending.state == .awaitingCanonicalEvidence
                        Label(
                            projection.commandInFlight
                                ? "Waiting for the agent service to confirm this request. No retry is needed."
                                : pending.state == .awaitingCanonicalEvidence
                                ? "Request accepted. Updating the chat from the agent service; no retry is needed."
                                : "\(pending.kind.rawValue) is \(pending.state.rawValue); refresh and "
                                + "reconcile explicitly before retrying.",
                            systemImage: waiting ? "clock" : "exclamationmark.triangle"
                        )
                            .font(.system(size: 10))
                            .foregroundStyle(waiting ? Design.accent : Design.warning)
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
                                        : "Retry requires complete current state, permission, and the original request's ownership")
                            if pending.state == .stale {
                                Button("Abandon stale") {
                                    Task { _ = await run.abandonStaleServiceCommand() }
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(Design.warning)
                                    .disabled(run.hasExited || run.isEnding || projection.commandInFlight)
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

/// Work accounting is separate from transcript ``Usage``. This card renders the authenticated
/// Work-wide inventory as distinct Main agent and Background agents subtotals. A combined total
/// is shown only when the child inventory is complete; a direct subtotal is never relabeled as a
/// combined total when child facts are omitted or unavailable.
struct ServiceWorkUsageInventoryCard: View {
    private let direct: CanonicalWorkUsage?
    private let directAvailability: CanonicalWorkUsageInventory.DirectAvailability
    private let childrenTotal: CanonicalWorkUsage?
    private let childCount: Int
    private let omittedChildCount: Int
    private let invalidChildCount: Int
    private let combined: CanonicalWorkUsage?
    private let combinedAvailability: CanonicalWorkUsageInventory.CombinedAvailability

    init(inventory: CanonicalWorkUsageInventory) {
        direct = inventory.direct
        directAvailability = inventory.directAvailability
        childrenTotal = inventory.childrenTotal
        childCount = inventory.children.count
        omittedChildCount = inventory.omittedChildCount
        invalidChildCount = inventory.invalidChildCount
        combined = inventory.combined
        combinedAvailability = inventory.combinedAvailability
    }

    /// Presentation-only fixture seam. It intentionally accepts already-projected display
    /// values and does not construct or bypass Core's authenticated inventory initializer.
    init(fixture: ServiceWorkUsageInventoryFixture) {
        direct = fixture.direct
        directAvailability = fixture.directAvailability
        childrenTotal = fixture.childrenTotal
        childCount = fixture.childCount
        omittedChildCount = fixture.omittedChildCount
        invalidChildCount = fixture.invalidChildCount
        combined = fixture.combined
        combinedAvailability = fixture.combinedAvailability
    }

    var body: some View {
        Card("Shared model usage", symbol: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 9) {
                Text("One shared total across attached chats and background agents")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)

                if let combined, combinedAvailability == .complete {
                    WorkUsageSubtotal(title: "Combined", usage: combined, emphasis: true)
                } else {
                    Label(combinedUnavailableCopy, systemImage: "questionmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.5)

                if directAvailability == .complete, let direct {
                    WorkUsageSubtotal(title: "Main agent", usage: direct)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MAIN AGENT")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text("Usage is unavailable until the Work projection is complete.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().opacity(0.5)

                if let childrenTotal {
                    WorkUsageSubtotal(title: "Background agents", usage: childrenTotal)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BACKGROUND AGENTS")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text(backgroundUnavailableCopy)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Design.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Cost is a configured-rate estimate, not an invoice or billing total.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var combinedUnavailableCopy: String {
        switch combinedAvailability {
        case .complete:
            return "Combined usage is unavailable."
        case .childFactsUnavailable:
            return "Combined usage is unavailable while some background-agent results are unknown."
        case .childFactsOmitted:
            return "Combined usage is unavailable because some background-agent usage records are missing."
        case .childFactsInvalid:
            return "Combined usage is unavailable because some background-agent records need repair."
        case .arithmeticOverflow:
            return "Combined usage could not be calculated because the total is too large."
        }
    }

    private var backgroundUnavailableCopy: String {
        var parts: [String] = []
        if childCount > 0 { parts.append("\(childCount) known") }
        if omittedChildCount > 0 { parts.append("\(omittedChildCount) omitted") }
        if invalidChildCount > 0 { parts.append("\(invalidChildCount) invalid") }
        let detail = parts.isEmpty ? nil : parts.joined(separator: ", ")
        let status = detail.map {
            "Background-agent usage is unavailable (\($0))."
        } ?? "Background-agent usage is unavailable."
        let directCopy = directAvailability == .complete && direct != nil
            ? "The Main agent subtotal is still available on its own."
            : "Main-agent usage is also unavailable."
        return "\(status) \(directCopy)"
    }
}

private struct WorkUsageSubtotal: View {
    let title: String
    let usage: CanonicalWorkUsage
    var emphasis = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            if !usage.hasCrossingEvidence {
                Text("No model requests recorded yet.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    StatTile(
                        label: "tokens",
                        value: tokenValue(usage.knownTokenFloor, usage.totalTokenCertainty),
                        emphasis: emphasis)
                    StatTile(label: "estimated cost", value: costValue)
                }
                DisclosureGroup("Token breakdown") {
                    VStack(alignment: .leading, spacing: 4) {
                        DetailRow(
                            label: "Input floor",
                            value: tokenValue(usage.inputTokens, usage.breakdownCertainty),
                            mono: true)
                        DetailRow(
                            label: "Output floor",
                            value: tokenValue(usage.outputTokens, usage.breakdownCertainty),
                            mono: true)
                        if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
                            DetailRow(label: "Cache read floor", value: tokenValue(
                                usage.cacheReadTokens, usage.breakdownCertainty), mono: true)
                            DetailRow(label: "Cache write floor", value: tokenValue(
                                usage.cacheWriteTokens, usage.breakdownCertainty), mono: true)
                        }
                    }
                }
                .font(.system(size: 10))
                DetailRow(
                    label: "Requests",
                    value: requestSummary,
                    mono: true)
                if usage.outstandingCrossings > 0 {
                    DetailRow(
                        label: "Awaiting outcomes",
                        value: "\(usage.outstandingCrossings) "
                            + (usage.outstandingCrossings == 1 ? "request" : "requests"),
                        tint: Design.warning)
                }
                if usage.hasUnresolvedAccounting {
                    Label(
                        accountingCaveat,
                        systemImage: usage.tokenOverflow || usage.costOverflow
                            ? "exclamationmark.triangle" : "questionmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Design.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var costValue: String {
        switch usage.costCertainty {
        case .exact:
            return usage.knownCostFloor == 0 ? "$0.00" : Fmt.cost(usage.knownCostFloor)
        case .lowerBound, .unknown:
            return usage.knownCostFloor > 0
                ? "≥" + Fmt.cost(usage.knownCostFloor) : "unknown"
        }
    }

    private func tokenValue(
        _ value: Int, _ certainty: CanonicalWorkUsage.Certainty
    ) -> String {
        switch certainty {
        case .exact: return Fmt.tokens(value)
        case .lowerBound, .unknown:
            return value > 0 ? "≥" + Fmt.tokens(value) : "unknown"
        }
    }

    private var requestSummary: String {
        let noun = usage.startedCrossings == 1 ? "request" : "requests"
        let verb = usage.startedCrossings == 1 ? "has" : "have"
        return "\(usage.settledCrossings) of \(usage.startedCrossings) \(noun) \(verb) recorded outcomes"
    }

    private var accountingCaveat: String {
        var parts: [String] = []
        if usage.unresolvedTotal > 0 {
            parts.append("total usage is unresolved for \(usage.unresolvedTotal) "
                + (usage.unresolvedTotal == 1 ? "request" : "requests"))
        }
        if usage.unresolvedBreakdown > 0 {
            parts.append(
                "the token breakdown is unresolved for \(usage.unresolvedBreakdown) "
                    + (usage.unresolvedBreakdown == 1 ? "request" : "requests"))
        }
        if usage.unresolvedCost > 0 {
            parts.append("cost is unresolved for \(usage.unresolvedCost) "
                + (usage.unresolvedCost == 1 ? "request" : "requests"))
        }
        if usage.tokenOverflow { parts.append("the token total is too large to calculate") }
        if usage.costOverflow { parts.append("the cost total is too large to calculate") }
        let text = parts.joined(separator: "; ")
        let sentence = text.isEmpty
            ? "Accounting details are unavailable"
            : String(text.prefix(1)).uppercased() + String(text.dropFirst())
        return sentence
            + ". Values are known lower bounds or unknown, not billing totals."
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
