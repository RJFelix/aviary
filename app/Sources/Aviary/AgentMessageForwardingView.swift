import SwiftUI

/// Chooses an already attached agent chat and stages a transcript message in its composer.
/// This view never sends a provider request: the destination must be explicitly selected and
/// must still have an empty, unresolved-free draft when the tap reaches the MainActor.
struct AgentMessageForwardingView: View {
    let text: String
    let sourceProject: String
    var sourceRunID: UUID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var failureMessage: String?

    private var candidates: [LiveRun] {
        model.runs
            .filter { $0.id != sourceRunID }
            .sorted { lhs, rhs in
                let lhsSameProject = sameProject(lhs)
                let rhsSameProject = sameProject(rhs)
                if lhsSameProject != rhsSameProject { return lhsSameProject }
                let lhsRecent = latestRecordedMessage(in: lhs)
                let rhsRecent = latestRecordedMessage(in: rhs)
                if lhsRecent != rhsRecent { return lhsRecent > rhsRecent }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private func latestRecordedMessage(in run: LiveRun) -> Date {
        run.items.map(\.timestamp).max()
            ?? (run.hasCanonicalStartTime ? run.startedAt : .distantPast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send to agent")
                    .font(.system(size: 16, weight: .semibold))
                Text("Choose an attached chat to prepare this message as a draft. Nothing is sent, "
                    + "and an existing draft will never be replaced.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.07)))

            if candidates.isEmpty {
                EmptyStateView(
                    symbol: "bubble.left.and.bubble.right",
                    title: "No attached agent chats",
                    message: "Start or attach another chat before forwarding a message. Aviary "
                        + "does not discover external or detached agents here.")
            } else {
                Text("ATTACHED AGENT CHATS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(candidates, id: \.id) { run in
                            destinationRow(run)
                        }
                    }
                }
            }

            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500, idealWidth: 580, minHeight: 420, idealHeight: 520)
    }

    private func destinationRow(_ run: LiveRun) -> some View {
        let reason = unavailableReason(for: run)
        let sameProject = sameProject(run)
        return Button {
            prepareDraft(for: run.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: run.isStreaming ? "bolt.fill" : "bubble.left.fill")
                    .foregroundStyle(run.isStreaming ? Design.success : Design.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title == "New run" ? run.projectName : run.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(run.projectName) · \(run.presentationState)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sameProject ? "same project" : "other project")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(sameProject ? Design.accent : Color.secondary.opacity(0.7))
                    Text(reason ?? "empty draft")
                        .font(.system(size: 9))
                        .foregroundStyle(reason == nil ? Design.success : Design.warning)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(reason == nil ? Design.accent : Color.secondary.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(reason == nil ? 0.07 : 0.035)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .accessibilityLabel("\(run.title), \(run.projectName)")
        .accessibilityValue(reason ?? "Ready to prepare an empty draft")
        .accessibilityHint(reason == nil
            ? "Stages the message in this chat's composer without sending"
            : "Unavailable because this chat cannot safely accept a draft")
    }

    private func sameProject(_ run: LiveRun) -> Bool {
        guard !sourceProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !run.config.cwd.isEmpty
        else { return false }
        guard URL(fileURLWithPath: sourceProject).standardizedFileURL.path
                == URL(fileURLWithPath: run.config.cwd).standardizedFileURL.path
        else { return false }

        // A path alone is not a project identity when two Work Hosts expose the same local
        // spelling. Only process-owned runs can be grouped without a host authority; service
        // runs must share the source attachment's exact Work Host.
        guard let sourceRunID,
              let sourceRun = model.runs.first(where: { $0.id == sourceRunID })
        else { return run.serviceAttachmentKey == nil }
        let sourceHost = sourceRun.serviceAttachmentKey?.workSession.work.workHostID
        let targetHost = run.serviceAttachmentKey?.workSession.work.workHostID
        return sourceHost == targetHost && (sourceHost != nil || targetHost == nil)
    }

    private func unavailableReason(for run: LiveRun) -> String? {
        AgentMessageDraftTransfer.unavailableReason(for: run)
    }

    private func prepareDraft(for id: UUID) {
        failureMessage = nil
        // Resolve the exact selected destination again at the click boundary.
        guard let target = model.runs.first(where: { $0.id == id }) else {
            failureMessage = "That attached chat is no longer available."
            return
        }
        guard AgentMessageDraftTransfer.prepare(text, for: target) else {
            failureMessage = "That chat cannot accept this draft. Its existing text was not replaced."
            return
        }
        model.focusRun(target)
        model.requestedChatSelectionID = target.id
        model.section = .cockpit
        dismiss()
    }
}

/// Main-actor UI transaction: no suspension between checking and staging, no command dispatch.
@MainActor enum AgentMessageDraftTransfer {
    static func unavailableReason(for run: LiveRun) -> String? {
        if run.hasExited { return "ended" }
        if run.isEnding { return "ending" }
        if run.errorBanner != nil { return "needs attention" }
        if run.serviceCommandAttemptActive { return "operation in progress" }
        if run.draftHandoff != nil { return "delivery unresolved" }
        if !run.draft.isEmpty {
            return "draft already present"
        }
        return nil
    }

    static func prepare(_ text: String, for target: LiveRun) -> Bool {
        guard !text.isEmpty, unavailableReason(for: target) == nil else { return false }
        target.setDraft(text)
        return target.draft == text
    }
}
