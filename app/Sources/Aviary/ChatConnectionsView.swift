import AviaryCore
import SwiftUI

/// Advanced recovery and attachment controls for conversations that do not belong in the
/// primary Chats rail. Retained startup requests are reconciled with their original identity.
struct ChatConnectionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent connections")
                        .font(.title2.weight(.semibold))
                    Text("View or reconnect conversations already known to this Mac. Reconnecting may continue a saved first-message startup, using its original identity rather than sending a new request.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let error = model.localWorkServiceError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Agent service needs attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(Design.warning)
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                Button("Retry connection") {
                                    Task {
                                        await model.retryLocalWorkService()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Open Diagnostics") {
                                    dismiss()
                                    model.section = .health
                                }
                                .buttonStyle(.bordered)
                            }
                            .controlSize(.small)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Design.warning.opacity(0.08)))
                    }

                    if !model.detachedRuns.isEmpty {
                        connectionSection(
                            title: "Detached from this window",
                            explanation: "These conversations kept running or remained available after their views were closed. Reattaching only restores the view."
                        ) {
                            ForEach(model.detachedRuns) { run in
                                detachedRow(run)
                            }
                        }
                    }

                    if !model.localServiceCatalogWorks.isEmpty {
                        connectionSection(
                            title: "Available on this Mac",
                            explanation: "View or attach existing conversations. An unfinished saved startup may continue when its connection is restored."
                        ) {
                            ForEach(model.localServiceCatalogWorks, id: \.work) { descriptor in
                                availableRows(descriptor)
                            }
                        }
                    }

                    if model.detachedRuns.isEmpty && model.localServiceCatalogWorks.isEmpty {
                        EmptyStateView(
                            symbol: "rectangle.connected.to.line.below",
                            title: "No additional connections",
                            message: "Every available conversation is already represented in Chats, or the local agent service has not published any yet.")
                            .frame(minHeight: 230)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 400, idealHeight: 600)
    }

    private func connectionSection<Content: View>(
        title: String,
        explanation: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.secondary.opacity(0.055)))
    }

    private func detachedRow(_ run: LiveRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text("\(run.projectName) · \(run.presentationState)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reattach") {
                    model.reattachRun(run, destination: .cockpit)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Restore this conversation view without restarting work")
            }
            if let key = run.serviceAttachmentKey {
                technicalIDs([
                    ("Work", key.workSession.work.workID),
                    ("Session", key.workSession.session.sessionID),
                    ("Session attachment", key.workSession.sessionAttachment.attachmentID),
                    ("Client attachment", key.clientAttachment.attachmentID),
                ])
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func availableRows(_ descriptor: WorkServiceWorkDescriptor) -> some View {
        ForEach(model.serviceAttachTargets(for: descriptor), id: \.self) { target in
            let hasOwnAttachment = descriptor.attachments.contains {
                $0.client == model.localWorkServiceClient
                    && $0.session == target.session
                    && $0.sessionJournal == target.sessionJournal
                    && $0.sessionAttachment == target.sessionAttachment
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.workspaceLabel(for: descriptor))
                            .font(.system(size: 13, weight: .semibold))
                        Text("Existing conversation · \(executionLabel(descriptor.execution))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.serviceAttachIsInFlight(target) {
                        ProgressView().controlSize(.small)
                    }
                    Button(hasOwnAttachment ? "View" : "Attach") {
                        model.attachServiceWork(
                            descriptor,
                            targetSessionAttachment: target.sessionAttachment,
                            destination: .cockpit)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.serviceAttachIsInFlight(target))
                    .help(hasOwnAttachment
                        ? "Open this exact conversation without starting it"
                        : "Attach this window to the exact conversation without starting it")
                }
                technicalIDs([
                    ("Host", descriptor.work.workHostID),
                    ("Work", descriptor.work.workID),
                    ("Session", target.session.sessionID),
                    ("Session attachment", target.sessionAttachment.attachmentID),
                ])
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        ForEach(model.serviceSessionCreationAuthorizers(for: descriptor), id: \.attachment) { authorizer in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Create another conversation")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Creates an empty conversation on this existing agent process. It does not send a message or start work.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Create empty conversation") {
                        model.createServiceSession(
                            descriptor, authorizingAttachment: authorizer.attachment)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                technicalIDs([
                    ("Work", descriptor.work.workID),
                    ("Authorizing attachment", authorizer.attachment.attachmentID),
                    ("Current session", authorizer.session?.sessionID ?? "none"),
                ])
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func technicalIDs(_ values: [(String, String)]) -> some View {
        DisclosureGroup("Technical IDs") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(values.indices, id: \.self) { index in
                    let value = values[index]
                    LabeledContent(value.0) {
                        Text(value.1)
                            .font(Design.mono(9.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private func executionLabel(_ state: WorkServiceExecutionState) -> String {
        switch state {
        case .idle: return "ready"
        case .running: return "working"
        case .held: return "paused"
        case .canceling: return "canceling"
        case .ending: return "ending"
        case .recoveryRequired: return "recovery needed"
        case .unknown: return "status unknown"
        }
    }
}
