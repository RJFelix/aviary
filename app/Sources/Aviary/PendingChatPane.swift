import AppKit
import AviaryCore
import SwiftUI

/// Visual cues describe saved intent, not an inferred command receipt.
struct PendingChatVisualState {
    let symbol: String
    let tint: Color
    let deliveryLabel: String
    let statusOverride: String?

    init(phase: PendingChatPhase, isPreparing: Bool, conversationCreated: Bool) {
        statusOverride = conversationCreated && !isPreparing
            ? "Conversation created · delivery unconfirmed" : nil
        if isPreparing {
            symbol = "arrow.triangle.2.circlepath"
            tint = Design.accent
            deliveryLabel = conversationCreated || phase == .awaitingAcceptance
                ? "Checking delivery" : "Preparing startup"
        } else if conversationCreated || phase == .awaitingAcceptance {
            symbol = "questionmark.circle.fill"
            tint = Design.warning
            deliveryLabel = "Delivery unconfirmed"
        } else if phase == .preparing {
            symbol = "pause.circle.fill"
            tint = Design.warning
            deliveryLabel = "Startup interrupted"
        } else if phase == .blocked {
            symbol = "exclamationmark.circle.fill"
            tint = Design.warning
            deliveryLabel = "Not sent"
        } else {
            symbol = "tray.fill"
            tint = Design.accent
            deliveryLabel = "Ready to send"
        }
    }
}

/// The two locations matter: saving a request and delivering it are separate facts.
struct SavedRequestProgress: View {
    let state: PendingChatVisualState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                location("This Mac", detail: "Request saved", symbol: "checkmark.circle.fill", tint: Design.success)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                location("Agent", detail: state.deliveryLabel, symbol: state.symbol, tint: state.tint)
            }
            VStack(alignment: .leading, spacing: 12) {
                location("This Mac", detail: "Request saved", symbol: "checkmark.circle.fill", tint: Design.success)
                location("Agent", detail: state.deliveryLabel, symbol: state.symbol, tint: state.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func location(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint).frame(width: 38, height: 38)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(detail).font(.system(size: 13, weight: .semibold)).fixedSize()
            }
        }
    }
}

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
    @State private var showingProjectReconfirmation = false

    private var canEdit: Bool {
        (chat.phase == .saved || chat.phase == .blocked) && chat.createdAssociation == nil
            && !model.pendingChatIsPreparing(chat)
    }

    private var visualState: PendingChatVisualState {
        .init(phase: chat.phase, isPreparing: model.pendingChatIsPreparing(chat),
              conversationCreated: chat.createdAssociation != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.title ?? (chat.prompt.isEmpty ? "New chat" : String(chat.prompt.prefix(80))))
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Label(URL(fileURLWithPath: chat.cwd).lastPathComponent, systemImage: "folder")
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
                    if !model.pendingChatIsPreparing(chat) {
                        SavedRequestProgress(state: visualState)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("You", systemImage: "person.circle")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Design.user)
                        Text(chat.prompt.isEmpty ? "An empty conversation, ready for your first message." : chat.prompt)
                            .font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(20)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Design.user.opacity(0.06)))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Design.user.opacity(0.6))
                                .frame(width: 3).padding(.vertical, 16)
                        }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 9) {
                            if model.pendingChatIsPreparing(chat) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: visualState.symbol)
                                    .foregroundStyle(visualState.tint)
                            }
                            Text(model.pendingChatIsPreparing(chat) ? "Starting…"
                                : visualState.statusOverride ?? model.pendingChatStatus(chat)).font(.headline)
                        }
                        if !model.pendingChatIsPreparing(chat) {
                        Text(model.pendingChatExplanation(chat))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.pendingChatIsPreparing(chat) {
                            ViewThatFits(in: .horizontal) {
                                HStack { recoveryButtons }
                                VStack(alignment: .leading, spacing: 10) { recoveryButtons }
                            }
                        }
                    }.padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(visualState.tint.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(visualState.tint.opacity(0.25), lineWidth: 1))

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
                }.padding(24).frame(maxWidth: 800)
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: chat.id) { _, _ in editing = false }
        .sheet(isPresented: $showingProjectReconfirmation) {
            ProjectReconfirmationSheet(initialDirectory: chat.cwd,
                prepare: { try model.preparePendingProjectReconfirmation(chatID: chat.id, directory: $0) },
                confirm: { try await model.confirmPendingProjectReconfirmation($0, chatID: chat.id) })
        }
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
            if chat.failureKind == .workspaceConfirmationRequired || chat.failureKind == .workspaceUnavailable {
                Button("Confirm project folder…") { showingProjectReconfirmation = true }
                    .buttonStyle(.bordered).disabled(editing)
            }
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
