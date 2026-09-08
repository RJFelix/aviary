import AppKit
import AviaryCore
import SwiftUI

/// A saved local conversation while agent startup is blocked. This deliberately does not
/// fabricate a canonical transcript row, accepted command, or running agent.
struct PendingChatPane: View {
    @Environment(AppModel.self) private var model
    let chat: PendingChat
    @State private var editing = false
    @State private var prompt = ""
    @State private var cwd = ""
    @State private var provider = ""
    @State private var modelID = ""
    @State private var confirmingDiscard = false
    @State private var confirmingSeparateCopy = false
    @State private var confirmingStopTracking = false

    private var canEdit: Bool {
        (chat.phase == .saved || chat.phase == .blocked) && chat.createdAssociation == nil
            && !model.pendingChatIsPreparing(chat)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.title ?? (chat.prompt.isEmpty ? "New chat" : String(chat.prompt.prefix(80))))
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(URL(fileURLWithPath: chat.cwd).lastPathComponent + " · Saved on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy request") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chat.prompt, forType: .string)
                }.controlSize(.small)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("You", systemImage: "person.circle")
                            .font(.subheadline.weight(.semibold))
                        Text(chat.prompt.isEmpty ? "An empty conversation, ready for your first message." : chat.prompt)
                            .font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(18)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Design.accentSoft.opacity(0.5)))

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 9) {
                            if model.pendingChatIsPreparing(chat) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: chat.phase == .saved ? "tray" : "exclamationmark.circle")
                                    .foregroundStyle(chat.phase == .saved ? Design.accent : Design.danger)
                            }
                            Text(model.pendingChatStatus(chat)).font(.headline)
                        }
                        Text(model.pendingChatIsPreparing(chat)
                             ? "Your request is saved. Connecting to the agent on this Mac…"
                             : model.pendingChatExplanation(chat))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !model.pendingChatIsPreparing(chat) {
                            ViewThatFits(in: .horizontal) {
                                HStack { recoveryButtons }
                                VStack(alignment: .leading, spacing: 10) { recoveryButtons }
                            }
                        }
                    }.padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))

                    if editing {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Edit saved request").font(.headline)
                            TextEditor(text: $prompt).font(.system(size: 14)).frame(minHeight: 160)
                                .accessibilityLabel("Saved request")
                            TextField("Project folder", text: $cwd).textFieldStyle(.roundedBorder)
                            Picker("Provider", selection: $provider) {
                                ForEach(Array(Set(model.pickerModels.map(\.providerID))).sorted(), id: \.self) { value in
                                    Text(value).tag(value)
                                }
                            }
                            Picker("Model", selection: $modelID) {
                                ForEach(model.pickerModels.filter { $0.providerID == provider }) { value in
                                    Text(value.displayName).tag(value.id)
                                }
                            }
                            HStack {
                                Button("Save changes") {
                                    if model.editPendingChat(chat, prompt: prompt, cwd: cwd,
                                                             providerID: provider, modelID: modelID) {
                                        editing = false
                                    }
                                }.buttonStyle(.borderedProminent)
                                Button("Cancel") { editing = false }
                            }
                            Text("Saving edits does not send them. Retry when you are ready.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(18)
                    }
                }.padding(24).frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: chat.id) { _, _ in editing = false }
        .confirmationDialog("Discard this unsent chat?", isPresented: $confirmingDiscard) {
            Button("Discard chat", role: .destructive) { model.discardPendingChat(chat) }
        } message: {
            Text("This removes the saved request from this Mac. It does not stop or delete any agent work.")
        }
        .confirmationDialog("Save a separate copy?", isPresented: $confirmingSeparateCopy) {
            Button("Save unsent copy") { model.copyPendingChatAsUnsent(chat) }
        } message: {
            Text("The original request may still take effect. This saves a separate chat without starting it. Check or stop the original work before starting the copy to avoid duplicate effects.")
        }
        .confirmationDialog("Remove this startup card?", isPresented: $confirmingStopTracking) {
            Button("Remove startup card", role: .destructive) { model.stopTrackingPendingChat(chat) }
        } message: {
            Text("The original request may still run. This only removes its local startup card; it does not cancel work or erase the conversation. Copy the request first if you want to keep a separate copy.")
        }
    }

    @ViewBuilder private var recoveryButtons: some View {
        Button(chat.phase == .awaitingAcceptance || chat.createdAssociation != nil
               ? "Check delivery" : chat.phase == .saved ? "Start chat" : "Retry startup") { model.retryPendingChat(chat.id) }
            .buttonStyle(.borderedProminent).disabled(editing)
        if canEdit {
            Button("Edit request") {
                prompt = chat.prompt; cwd = chat.cwd
                provider = chat.providerID ?? ""; modelID = chat.modelID ?? ""
                editing = true
            }.buttonStyle(.bordered)
        }
        if chat.createdAssociation != nil {
            Button("Open conversation") { model.openPendingConversation(chat) }.buttonStyle(.bordered)
                .disabled(!model.canOpenPendingConversation(chat))
            Menu("Recovery options") {
                Button("Save as a separate unsent chat…") { confirmingSeparateCopy = true }
                Button("Remove startup card…", role: .destructive) { confirmingStopTracking = true }
            }.menuStyle(.borderlessButton).fixedSize()
        }
        Button("Connection details") { model.section = .health }.buttonStyle(.bordered)
        if canEdit {
            Button("Discard…", role: .destructive) { confirmingDiscard = true }.buttonStyle(.borderless)
        }
    }
}
