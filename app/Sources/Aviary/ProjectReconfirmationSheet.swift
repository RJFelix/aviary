import AppKit
import AviaryCore
import SwiftUI

enum ProjectReconfirmationResult {
    case confirmed
    case confirmedNeedsRefresh
    case confirmedNeedsChatSave
}

/// Host-local administrator UI, never a path-bearing Work-service command. Selecting a folder
/// prepares a revision-fenced confirmation; only the second explicit action updates the registry.
struct ProjectReconfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialDirectory: String
    let prepare: (URL) throws -> WorkHostWorkspaceReconfirmation
    let confirm: (WorkHostWorkspaceReconfirmation) async throws -> ProjectReconfirmationResult

    @State private var confirmation: WorkHostWorkspaceReconfirmation?
    @State private var selectedPath: String?
    @State private var error: String?
    @State private var saving = false
    @State private var completedMessage: String?
    @State private var completionNeedsAttention = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm project folder", systemImage: "folder.badge.questionmark")
                .font(.title2.weight(.semibold))
            Text("Choose the original project folder for this chat. Aviary will keep the conversation and its project association.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Confirmation applies to future launches of chats using this project. It does not send a message, restart an agent, or recover a previous Python interpreter.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let selectedPath {
                Text(selectedPath).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Selected project folder: \(selectedPath)")
            }
            if let error {
                Text(error).foregroundStyle(Design.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let completedMessage {
                Label(completedMessage, systemImage: completionNeedsAttention
                      ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(completionNeedsAttention ? Design.warning : Design.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if completedMessage == nil {
                    Button("Choose folder…", action: chooseFolder).disabled(saving)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button(saving ? "Confirming…" : "Confirm folder") {
                        guard let confirmation else { return }
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                let result = try await confirm(confirmation)
                                self.confirmation = nil
                                error = nil
                                switch result {
                                case .confirmed:
                                    completedMessage = "Project confirmed. No message was sent. Close this window to continue."
                                case .confirmedNeedsRefresh:
                                    completionNeedsAttention = true
                                    completedMessage = "Project confirmed. The agent service has not confirmed that this chat is ready. Close this window to check its current status. No message was sent."
                                case .confirmedNeedsChatSave:
                                    completionNeedsAttention = true
                                    completedMessage = "Project confirmed, but the saved request’s status could not be updated. Its text is kept. Close this window to see the saving error. No message was sent."
                                }
                            } catch {
                                self.confirmation = nil
                                self.error = message(for: error)
                            }
                        }
                    }.buttonStyle(.borderedProminent).disabled(confirmation == nil || saving)
                } else {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 530)
        .interactiveDismissDisabled(saving)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the original folder for this chat. Choosing it does not start the agent."
        panel.prompt = "Select folder"
        if !initialDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: initialDirectory) }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        confirmation = nil
        selectedPath = directory.path
        do {
            confirmation = try prepare(directory)
            error = nil
        } catch { self.error = message(for: error) }
    }

    private func message(for error: Error) -> String {
        if let error = error as? WorkHostWorkspaceRegistryError {
            return error.localizedDescription + " Choose the original folder again to prepare a new confirmation."
        }
        return "The project could not be confirmed. No request was sent. Check the connection and try again."
    }
}
