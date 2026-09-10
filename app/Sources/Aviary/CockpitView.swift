import SwiftUI
import AviaryCore

/// The landing screen is the Session workspace, not a second analytics dashboard. The rail joins
/// this GUI's live attachments with the canonical attention inbox, so Work remains visible when
/// it belongs to another GUI or has already completed.
struct CockpitView: View {
    @Environment(AppModel.self) private var model
    /// Selected like a run, not sheet-presented: the New Session card lives in the same rail
    /// as every other run, and choosing it fills the same detail pane a run's chat would use
    /// rather than opening a modal over it. See `NewSessionPane`.
    @State private var composingNewSession = false
    @State private var showsConnections = false
    @State private var selectedCanonicalEntryID: String?
    /// Selecting a Session does not select one of its Works. This exact key is set only by the
    /// relationship card in the Session pane, so several attached Works never collapse by order.
    @State private var selectedCanonicalWorkTarget: WorkSessionKey?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                runRail
                    .frame(width: min(280, max(190, geo.size.width * 0.27)))
                Divider()
                detail
                    .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: model.newChatRequested) { _, requested in
            if requested { beginNewChat() }
        }
        .onAppear { if model.newChatRequested { beginNewChat() } }
        .sheet(isPresented: $showsConnections) { ChatConnectionsView() }
    }

    private var ongoingRuns: [LiveRun] {
        // Retain ended chats until explicitly dismissed. Their state stays distinct from
        // an idle agent that can receive another message.
        model.runs
    }

    /// Live attachments without a canonical Session row remain visible as an explicit fallback.
    /// When a canonical row exists it owns the rail card and routes to the richer live pane.
    private var unrepresentedRuns: [LiveRun] {
        ongoingRuns.filter { run in
            !canonicalEntries.contains { entry in
                matchingRuns(for: entry).contains { $0.id == run.id }
            }
        }
    }

    private var selectedRun: LiveRun? {
        if let entry = selectedCanonicalEntry {
            return selectedMatchingRun(for: entry, target: effectiveSelectedCanonicalWorkTarget)
        }
        if let focused = model.focusedRunID,
           let run = unrepresentedRuns.first(where: { $0.id == focused })
        {
            return run
        }
        return unrepresentedRuns.first
    }

    /// The canonical projection owns every authority-qualified Session row. Bare Session IDs are
    /// never used to collapse authorities; live attachments are joined only by their exact key.
    private var canonicalEntries: [CanonicalSessionWorkspaceRailEntry] {
        model.canonicalWorkspaceRail.entries
    }

    private var focusedCanonicalEntryID: String? {
        guard let focused = model.focusedRunID,
              let entry = canonicalEntries.first(where: { entry in
                  matchingRuns(for: entry).contains { $0.id == focused }
              }) else { return nil }
        return entry.id
    }

    private var effectiveSelectedCanonicalWorkTarget: WorkSessionKey? {
        if let selectedCanonicalWorkTarget { return selectedCanonicalWorkTarget }
        if selectedCanonicalEntryID != nil { return nil }
        if let focused = model.focusedRunID,
           let run = ongoingRuns.first(where: { $0.id == focused }),
           let key = run.serviceAttachmentKey,
           selectedCanonicalEntry.map({ entryContains(key.workSession, in: $0) }) == true {
            return key.workSession
        }
        guard let entry = selectedCanonicalEntry else { return nil }
        let candidate = AppModel.CanonicalWorkspaceSelectionCandidate(entry: entry)
        return AppModel.canonicalWorkspacePreferredTarget(
            candidate: candidate,
            preferred: model.preferredServiceAttachmentKey,
            ownedKeys: model.ownedServiceAttachmentPresentationKeys,
            localClient: model.localWorkServiceClient)
    }

    private var selectedCanonicalEntry: CanonicalSessionWorkspaceRailEntry? {
        if model.selectedPendingChatID != nil { return nil }
        let hasFocusedUnrepresentedRun = model.focusedRunID.map { focused in
            ongoingRuns.contains { $0.id == focused } && focusedCanonicalEntryID == nil
        } ?? false
        let candidates = canonicalEntries.map {
            AppModel.CanonicalWorkspaceSelectionCandidate(entry: $0)
        }
        if let selectedID = AppModel.canonicalWorkspaceSelectionID(
            candidates: candidates, explicitID: selectedCanonicalEntryID,
            focusedID: focusedCanonicalEntryID,
            preferred: model.preferredServiceAttachmentKey,
            ownedKeys: model.ownedServiceAttachmentPresentationKeys,
            localClient: model.localWorkServiceClient,
            hasFocusedUnrepresentedRun: hasFocusedUnrepresentedRun),
           let entry = canonicalEntries.first(where: { $0.id == selectedID }) {
            return entry
        }
        if hasFocusedUnrepresentedRun { return nil }
        if let firstAttached = canonicalEntries.first(where: { !matchingRuns(for: $0).isEmpty }) {
            return firstAttached
        }
        return canonicalEntries.first
    }

    /// A run card reads as selected only when it is actually what's showing in the detail
    /// pane. Without this, an old selection would still look highlighted while the New
    /// Session card is the one open — two cards claiming the same state at once.
    private func isShowing(_ run: LiveRun) -> Bool {
        !composingNewSession && model.selectedPendingChatID == nil
            && run.id == selectedRun?.id
    }

    private var runRail: some View {
        let restoringIDs = model.serviceRestoringCanonicalEntryIDs()
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CHATS")
                        .font(Design.sectionTitle).tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.pendingChats.count + unrepresentedRuns.count + canonicalEntries.count)")
                        .font(Design.numeric(10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Button { showsConnections = true } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Manage agent connections")
                    .help("Manage agent connections and reopen detached chats")
                }
                .padding(.horizontal, 12).padding(.top, 12)

                NewRunRailCard(selected: composingNewSession) { beginNewChat() }

                if let error = model.pendingChatStoreError {
                    Text(error).font(.caption).foregroundStyle(Design.danger)
                        .textSelection(.enabled).padding(8)
                }
                ForEach(model.pendingChats) { chat in
                    Button {
                        model.selectedPendingChatID = chat.id
                        composingNewSession = false
                        selectedCanonicalEntryID = nil
                        selectedCanonicalWorkTarget = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(chat.prompt.isEmpty ? "New chat" : String(chat.prompt.prefix(90)))
                                .font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Label(model.pendingChatStatus(chat), systemImage: "bubble.left.and.exclamationmark.bubble.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(RoundedRectangle(cornerRadius: 9).fill(
                            model.selectedPendingChatID == chat.id && !composingNewSession
                                ? Design.accentSoft : Color.secondary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        model.selectedPendingChatID == chat.id && !composingNewSession
                            ? .isSelected : [])
                    .accessibilityRemoveTraits(
                        model.selectedPendingChatID == chat.id && !composingNewSession
                            ? [] : .isSelected)
                }

                if !needsAttentionEntries.isEmpty {
                    railHeading("NEEDS YOU")
                    ForEach(needsAttentionEntries) { entry in
                        workspaceCard(entry, isRestoring: restoringIDs.contains(entry.id))
                    }
                }

                if !unrepresentedRuns.isEmpty {
                    railHeading("RECENT")
                }
                ForEach(unrepresentedRuns) { run in
                    RunRailCard(run: run, selected: isShowing(run)) {
                        model.focusRun(run)
                        model.selectedPendingChatID = nil
                        selectedCanonicalEntryID = nil
                        selectedCanonicalWorkTarget = nil
                        composingNewSession = false
                    }
                }

                if !workingEntries.isEmpty {
                    railHeading("WORKING")
                    ForEach(workingEntries) { entry in
                        workspaceCard(entry, isRestoring: restoringIDs.contains(entry.id))
                    }
                }

                if !reviewEntries.isEmpty {
                    railHeading("READY FOR REVIEW")
                    ForEach(reviewEntries) { entry in
                        workspaceCard(entry, isRestoring: restoringIDs.contains(entry.id))
                    }
                }

                if !otherEntries.isEmpty {
                    railHeading("RECENT CONVERSATIONS")
                    ForEach(otherEntries) { entry in
                        workspaceCard(entry, isRestoring: restoringIDs.contains(entry.id))
                    }
                }

                if model.canonicalWorkspaceRail.omittedEntryCount > 0 {
                    Label(
                        "\(model.canonicalWorkspaceRail.omittedEntryCount) more canonical "
                            + "Session row(s) are outside this bounded page.",
                        systemImage: "ellipsis.circle")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
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
        } else if let chat = model.pendingChats.first(where: { $0.id == model.selectedPendingChatID }) {
            PendingChatPane(chat: chat)
        } else if let entry = selectedCanonicalEntry,
                  entry.workEvidence.count + entry.omittedWorkEvidenceCount > 1 {
            // Keep the Session's Work relationship selector visible even after one relationship
            // resolves to a local LiveRun. Otherwise that live attachment hides its peers.
            CanonicalSessionWorkspacePane(
                entry: entry,
                attachedRun: selectedMatchingRun(
                    for: entry, target: effectiveSelectedCanonicalWorkTarget),
                selectedWorkTarget: effectiveSelectedCanonicalWorkTarget
            ) { target in
                selectedCanonicalWorkTarget = target
            }
        } else if let run = selectedRun {
            // Keep chat space primary; context and working state open from the run header.
            RunPane(run: run, showsInspector: false)
        } else if let entry = selectedCanonicalEntry {
            CanonicalSessionWorkspacePane(
                entry: entry, attachedRun: nil,
                selectedWorkTarget: effectiveSelectedCanonicalWorkTarget
            ) { target in
                selectedCanonicalWorkTarget = target
            }
        } else {
            NewSessionPane(onStart: { composingNewSession = false })
        }
    }

    private var needsAttentionEntries: [CanonicalSessionWorkspaceRailEntry] {
        canonicalEntries.filter {
            [.needsInput, .needsConfirmation, .failed].contains($0.state)
        }
    }

    private var workingEntries: [CanonicalSessionWorkspaceRailEntry] {
        canonicalEntries.filter { $0.state == .working }
    }

    private var reviewEntries: [CanonicalSessionWorkspaceRailEntry] {
        canonicalEntries.filter { $0.state == .readyForReview }
    }

    private var otherEntries: [CanonicalSessionWorkspaceRailEntry] {
        canonicalEntries.filter {
            ![.needsInput, .needsConfirmation, .failed, .working, .readyForReview]
                .contains($0.state)
        }
    }

    private func matchingRuns(for entry: CanonicalSessionWorkspaceRailEntry) -> [LiveRun] {
        ongoingRuns.filter { run in
            if let key = run.serviceAttachmentKey?.workSession {
                return entryContains(key, in: entry)
            }
            return false
        }
    }

    private func entryContains(
        _ key: WorkSessionKey, in entry: CanonicalSessionWorkspaceRailEntry
    ) -> Bool {
        key.session == entry.session
            && key.sessionJournal == entry.sessionJournal
            && entry.workEvidence.contains {
                $0.work == key.work && $0.attachment == key.sessionAttachment
            }
    }

    /// One Session may be attached to several Works. Use the already-focused exact attachment or
    /// the sole match; otherwise keep the Session pane read-only until the user chooses a Work.
    private func selectedMatchingRun(
        for entry: CanonicalSessionWorkspaceRailEntry,
        target: WorkSessionKey? = nil
    ) -> LiveRun? {
        let matches = matchingRuns(for: entry)
        if let target,
           entryContains(target, in: entry) {
            let exact = matches.filter { $0.serviceAttachmentKey?.workSession == target }
            if let focused = model.focusedRunID,
               let run = exact.first(where: { $0.id == focused }) { return run }
            guard exact.count == 1 else { return nil }
            return exact[0]
        }
        if entry.workEvidence.count + entry.omittedWorkEvidenceCount > 1 { return nil }
        if let focused = model.focusedRunID,
           let exact = matches.first(where: { $0.id == focused }) { return exact }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    @ViewBuilder
    private func workspaceCard(
        _ entry: CanonicalSessionWorkspaceRailEntry, isRestoring: Bool
    ) -> some View {
        let attachedRuns = matchingRuns(for: entry)
        CanonicalWorkspaceRailCard(
            entry: entry,
            attachedRun: selectedMatchingRun(for: entry),
            isAttachedHere: !attachedRuns.isEmpty,
            isRestoringHere: isRestoring,
            selected: !composingNewSession && selectedCanonicalEntry?.id == entry.id
        ) {
            selectedCanonicalEntryID = entry.id
            if attachedRuns.count == 1, let run = attachedRuns.first {
                model.focusRun(run)
            }
            model.selectedPendingChatID = nil
            selectedCanonicalWorkTarget = nil
            composingNewSession = false
        }
    }

    private func beginNewChat() {
        composingNewSession = true
        model.selectedPendingChatID = nil
        selectedCanonicalEntryID = nil
        selectedCanonicalWorkTarget = nil
        model.newChatRequested = false
    }

    private func railHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.top, 5)
    }
}

/// Presentation-only identity retained while an exact attached Work outpaces the Session rail
/// catalog. The command state remains explicitly qualified as Work state; it is never promoted to
/// canonical Session state. An exact join can still be unknown when the canonical attachment
/// cursor is catching up, so this gate covers both incomplete and exact/unknown joins.
struct CanonicalWorkspaceRailAttachedFallback: Equatable, Sendable {
    let title: String
    let commandState: SessionCommandState
}

/// Pure gate for the rail's transient attached-chat fallback. Keep this independent of SwiftUI so
/// the AppModel journey probe can cover the safety cases without fabricating a view hierarchy.
enum CanonicalWorkspaceRailPresentation {
    static func attachedFallback(
        entryIsKnown: Bool,
        entryJoin: CanonicalSessionWorkspaceRailJoin,
        attachedServiceBacked: Bool,
        attachedProjectionIsCanonical: Bool,
        attachedTitle: String?,
        attachedCommandState: SessionCommandState?
    ) -> CanonicalWorkspaceRailAttachedFallback? {
        guard !entryIsKnown,
              [.incomplete, .exact].contains(entryJoin),
              attachedServiceBacked,
              attachedProjectionIsCanonical,
              let attachedTitle,
              attachedTitle != "New run",
              !attachedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let attachedCommandState
        else { return nil }
        return CanonicalWorkspaceRailAttachedFallback(
            title: attachedTitle, commandState: attachedCommandState)
    }
}

/// Cockpit's inline replacement for opening `LauncherSheet` over the window: the same
/// `LauncherFormBody`, given the detail pane's width instead of a modal's fixed frame, with a
/// header that reads "cancel back to whatever was selected" rather than "dismiss".
private struct NewSessionPane: View {
    var onStart: () -> Void
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("New chat", systemImage: "plus.bubble")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered).controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                }
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
                    Text(ChatInteractionPresentation.stateLabel(run.commandState))
                        .foregroundStyle(run.commandState == .failed ? Design.danger
                            : run.isStreaming ? Design.success : .secondary)
                    Spacer()
                    if run.hasCanonicalStartTime && run.elapsedLabel != "time unknown" {
                        Text(run.elapsedLabel)
                    }
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
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityRemoveTraits(selected ? [] : .isSelected)
    }
}

private struct CanonicalWorkspaceRailCard: View {
    let entry: CanonicalSessionWorkspaceRailEntry
    let attachedRun: LiveRun?
    let isAttachedHere: Bool
    let isRestoringHere: Bool
    let selected: Bool
    let action: () -> Void

    /// A live service attachment can retain the chat identity while the catalog is catching up.
    /// This is presentation-only: the canonical entry remains unknown and its state is never
    /// replaced by the attached Work's command state. Duplicate or missing-summary rows have no
    /// safe join, so they keep the explicit unavailable title.
    private var attachedCatchUpPresentation: CanonicalWorkspaceRailAttachedFallback? {
        CanonicalWorkspaceRailPresentation.attachedFallback(
            entryIsKnown: entry.isKnown,
            entryJoin: entry.join,
            attachedServiceBacked: attachedRun?.isServiceBacked ?? false,
            attachedProjectionIsCanonical: attachedRun?.serviceProjection?.isCanonical ?? false,
            attachedTitle: attachedRun?.title,
            attachedCommandState: attachedRun?.commandState)
    }

    private var displayTitle: String {
        attachedCatchUpPresentation?.title ?? entry.title
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: entry.state.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(entry.state.tint)
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    Text(entry.state.label)
                        .foregroundStyle(entry.state.tint)
                    if isAttachedHere {
                        Text("open here")
                            .foregroundStyle(Design.accent)
                    } else if isRestoringHere {
                        Text("Restoring chat…")
                            .foregroundStyle(Design.accent)
                    }
                    if let attachedCatchUpPresentation {
                        Text("Attached agent · \(ChatInteractionPresentation.stateLabel(attachedCatchUpPresentation.commandState))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let model = entry.modelID, !model.isEmpty {
                        Text(model).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                if entry.workEvidence.count > 1 || entry.omittedWorkEvidenceCount > 0 {
                    Text(
                        "\(entry.workEvidence.count) recorded agent workspaces"
                            + (entry.omittedWorkEvidenceCount > 0
                                ? " · \(entry.omittedWorkEvidenceCount) more not shown" : ""))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Design.accentSoft) : AnyShapeStyle(.background)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? AnyShapeStyle(Design.accent.opacity(0.7))
                            : AnyShapeStyle(.separator.opacity(0.55)),
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityRemoveTraits(selected ? [] : .isSelected)
        .accessibilityLabel(
            "\(displayTitle), \(entry.state.label), authority \(entry.authorityID)")
        .accessibilityValue(
            entry.isKnown
                ? "Canonical Session, \(entry.workEvidence.count) retained Work"
                    + (entry.omittedWorkEvidenceCount > 0
                        ? ", \(entry.omittedWorkEvidenceCount) Work omitted from this page" : "")
                    + (isAttachedHere ? ", attached to this GUI"
                        : isRestoringHere ? ", restoring this GUI attachment"
                        : ", not attached to this GUI")
                : attachedCatchUpPresentation.map {
                    "Conversation state not yet verified; attached agent "
                        + ChatInteractionPresentation.stateLabel($0.commandState)
                } ?? "Attention and state unknown")
        .help("Agent service: \(entry.authorityID)")
        .accessibilityHint("Opens this chat")
    }
}

/// A canonical Session that this GUI has not attached is still a real conversation. Its
/// transcript is readable from the catalog, while controls appear only for one exact advertised
/// Work/Session/attachment relationship. This is intentionally not a synthetic `LiveRun`.
private struct CanonicalSessionWorkspacePane: View {
    @Environment(AppModel.self) private var model
    let entry: CanonicalSessionWorkspaceRailEntry
    let attachedRun: LiveRun?
    let selectedWorkTarget: WorkSessionKey?
    let onSelectWork: (WorkSessionKey) -> Void

    private var transcriptPage: CanonicalWorkspaceTranscriptPage? {
        model.canonicalWorkspaceTranscripts[entry.id]
    }

    private var transcriptItems: [TranscriptItem] {
        guard entry.isKnown else { return [] }
        return transcriptPage?.items ?? []
    }

    private var hasOmittedTranscriptMessages: Bool {
        (transcriptPage?.omittedMessageCount ?? 0) > 0
    }

    private var hasSelectedWorkRelationship: Bool {
        guard let selectedWorkTarget else { return false }
        return entry.workEvidence.contains {
            $0.work == selectedWorkTarget.work
                && $0.attachment == selectedWorkTarget.sessionAttachment
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.localWorkServiceError {
                NoticeBanner(level: .warning, title: "Work Host status", message: error)
                Divider()
            }
            if !entry.isKnown || transcriptPage == nil {
                unavailablePane
            } else {
                if attachedRun == nil,
                   entry.workEvidence.count + entry.omittedWorkEvidenceCount > 1,
                   !hasSelectedWorkRelationship {
                    NoticeBanner(
                        level: .warning,
                        title: "Choose a Work attachment",
                        message: "This Session is attached to more than one Work. Choose an "
                            + "exact relationship below before sending or controlling it.")
                    Divider()
                }
                attachmentBar
                Divider()
                if let attachedRun {
                    VStack(spacing: 0) {
                        if let target = attachedRun.serviceAttachmentKey?.workSession {
                            HStack(spacing: 7) {
                                Label("Controlling Work", systemImage: "point.3.connected.trianglepath.dotted")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(target.work.workHostID) / \(target.work.workID)")
                                    .font(Design.mono(10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("attachment \(target.sessionAttachment.attachmentID)")
                                    .font(Design.mono(9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Design.accentSoft.opacity(0.55))
                            Divider()
                        }
                        RunPane(run: attachedRun, showsInspector: false)
                    }
                } else {
                    VStack(spacing: 0) {
                        if let transcriptPage, transcriptPage.omittedMessageCount > 0 {
                            Label(
                                "\(transcriptPage.omittedMessageCount) earlier or oversized "
                                    + "message\(transcriptPage.omittedMessageCount == 1 ? "" : "s") "
                                    + "outside this bounded transcript page.",
                                systemImage: "ellipsis.circle")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                            Divider()
                        }
                        if transcriptItems.isEmpty {
                            EmptyStateView(
                                symbol: "bubble.left.and.exclamationmark.bubble.right",
                                title: hasOmittedTranscriptMessages
                                    ? "Messages outside this page" : "No canonical messages",
                                message: hasOmittedTranscriptMessages
                                    ? "Every recorded message is outside this bounded transcript "
                                        + "page. Aviary will not substitute or truncate a body."
                                    : "This canonical Session has no recorded message body. "
                                        + "Aviary will not substitute a local transcript.")
                        } else {
                            TranscriptView(items: transcriptItems, autoScroll: false)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.state.symbol)
                    .foregroundStyle(entry.state.tint)
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Chip(text: entry.state.label, tint: entry.state.tint)
                Spacer()
            }
            HStack(spacing: 7) {
                Text(entry.authorityID)
                Text("Session \(entry.session.sessionID)")
                if let model = entry.modelID, !model.isEmpty { Text(model) }
            }
            .font(Design.mono(9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(14)
    }

    @ViewBuilder
    private var attachmentBar: some View {
        if entry.workEvidence.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.minus")
                    .foregroundStyle(.secondary)
                Text("No attached Work is recorded. This Session is available for inspection.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(entry.workEvidence) { evidence in
                        workAttachmentCard(evidence)
                    }
                    if entry.omittedWorkEvidenceCount > 0 {
                        Text("+\(entry.omittedWorkEvidenceCount) Work omitted")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .background(.background.secondary)
        }
    }

    @ViewBuilder
    private func workAttachmentCard(
        _ evidence: CanonicalAttentionAttachmentEvidence
    ) -> some View {
        let match = exactAttachMatch(for: evidence)
        let isSelected = match?.target == selectedWorkTarget
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(evidence.work.workID)
                    .font(Design.mono(10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("host \(evidence.work.workHostID)")
                    .font(Design.mono(9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("attachment \(evidence.attachment.attachmentID)")
                    .font(Design.mono(9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(workEvidenceLabel(evidence, match: match))
                    .font(.system(size: 9.5))
                    .foregroundStyle(match == nil ? Design.warning : .secondary)
            }
            .frame(width: 190, alignment: .leading)
            if let match {
                Button(
                    match.isInFlight ? "Opening…"
                        : isSelected ? "Selected"
                        : match.hasOwnAttachment ? "Inspect" : "Attach"
                ) {
                    onSelectWork(match.target)
                    model.attachServiceWork(
                        match.descriptor,
                        targetSessionAttachment: match.target.sessionAttachment,
                        destination: .cockpit)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(match.isInFlight)
                .help(
                    match.hasOwnAttachment
                        ? "Open this exact Session attachment without starting Work"
                        : "Attach this GUI to this exact Session without starting Work")
            }
        }
        .padding(8)
        .background(
            isSelected ? Design.accentSoft : Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? AnyShapeStyle(Design.accent.opacity(0.8))
                        : AnyShapeStyle(.separator.opacity(0.55)),
                    lineWidth: isSelected ? 1.5 : 1))
        .accessibilityValue(
            "Work \(evidence.work.workID) on host \(evidence.work.workHostID), attachment "
                + "\(evidence.attachment.attachmentID), "
                + (isSelected ? "selected relationship" : "relationship not selected"))
    }

    private var unavailablePane: some View {
        EmptyStateView(
            symbol: "exclamationmark.triangle",
            title: "Canonical Session unavailable",
            message: unavailableMessage)
    }

    private var unavailableMessage: String {
        switch entry.join {
        case .exact:
            return "The Session was discovered, but its current state is incomplete. Controls "
                + "are withheld until an exact catalog refresh succeeds."
        case .missingSummary:
            return "The attention row has no matching authority-qualified Session summary."
        case .duplicateSummary:
            return "More than one Session summary claims this canonical identity. Aviary will "
                + "not select an arbitrary copy."
        case .incomplete:
            return "The Session identity or source scan is incomplete. Controls are withheld."
        }
    }

    private struct AttachMatch {
        let descriptor: WorkServiceWorkDescriptor
        let target: WorkSessionKey
        let hasOwnAttachment: Bool
        let isInFlight: Bool
    }

    private func exactAttachMatch(
        for evidence: CanonicalAttentionAttachmentEvidence
    ) -> AttachMatch? {
        let descriptors = model.localServiceCatalogWorks.filter {
            $0.work == evidence.work
                && (evidence.workJournal == nil || $0.journal == evidence.workJournal)
        }
        guard descriptors.count == 1, let descriptor = descriptors.first else { return nil }
        let targets = descriptor.attachmentQualifiedSessionTargets.filter {
            $0.session == entry.session
                && $0.sessionJournal == entry.sessionJournal
                && $0.sessionAttachment == evidence.attachment
        }
        guard targets.count == 1, let target = targets.first else { return nil }
        guard let client = model.localWorkServiceClient,
              let decision = ServiceBackedGUIOrchestration.inspect(
                  descriptor: descriptor, client: client,
                  targetSessionAttachment: target.sessionAttachment),
              decision.target.workSession == target else { return nil }
        return AttachMatch(
            descriptor: descriptor, target: target,
            hasOwnAttachment: decision.existingAttachment != nil,
            isInFlight: model.serviceAttachIsInFlight(target))
    }

    private func workEvidenceLabel(
        _ evidence: CanonicalAttentionAttachmentEvidence,
        match: AttachMatch?
    ) -> String {
        if match != nil { return "Exact host relationship available" }
        if evidence.integrityValid == false || !evidence.structuralIntegrityValid
            || !evidence.semanticProjectionValid {
            return "Canonical Work evidence unavailable"
        }
        return "Work Host is not connected or no exact relationship was advertised"
    }
}

private extension CanonicalSessionWorkspaceRailState {
    var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .needsConfirmation: return "Needs confirmation"
        case .failed: return "Failed"
        case .working: return "Working"
        case .readyForReview: return "Ready for review"
        case .idle: return "Idle"
        case .completed: return "Completed"
        case .archived: return "Archived"
        case .unknown: return "State unknown"
        }
    }

    var symbol: String {
        switch self {
        case .needsInput: return "text.bubble.fill"
        case .needsConfirmation: return "checkmark.shield.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .working: return "bolt.horizontal.circle.fill"
        case .readyForReview: return "checkmark.circle.fill"
        case .idle: return "pause.circle"
        case .completed: return "checkmark.seal"
        case .archived: return "archivebox"
        case .unknown: return "questionmark.diamond"
        }
    }

    var tint: Color {
        switch self {
        case .failed: return Design.danger
        case .needsConfirmation, .needsInput: return Design.warning
        case .working: return Design.accent
        case .readyForReview, .completed: return Design.success
        case .idle, .archived, .unknown: return .secondary
        }
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
                Text("New chat")
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
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityRemoveTraits(selected ? [] : .isSelected)
    }
}

// MARK: - Rows

// `LiveSessionRow` lived here: a row describing a session a daemon was holding, with a lease,
// a worker and an attached-client count. Service-backed Work now supplies that durable state;
// a live run is an attachment in `runs`, and the canonical Sessions surface remains the source
// for Work that is not currently attached to this GUI.

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
