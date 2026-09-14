import SwiftUI
import AviaryCore

/// One bounded summary above the conversation; all source text is available in Details.
struct ChatStatusPanel: View {
    let presentation: ChatStatusPresentation
    var onConfirmProject: (() -> Void)?
    var onCheckProject: (() -> Void)?
    var onReviewDelivery: (() -> Void)?
    @State private var showsDetails = false

    var body: some View {
        if let primary = presentation.primary {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: primary.symbol).foregroundStyle(tint(primary.tone))
                        .font(.system(size: 14, weight: .semibold)).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(primary.title).font(.system(size: 12, weight: .semibold))
                        Text(primary.message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(3).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Button { showsDetails = true } label: {
                        Label(presentation.items.count == 1 ? "Details" : "Details · \(presentation.items.count) notices",
                              systemImage: "list.bullet.rectangle")
                    }.buttonStyle(.link)
                        .accessibilityIdentifier("chat-status-details")
                    if presentation.attentionCount > 1 {
                        Text("\(presentation.attentionCount) need attention")
                            .foregroundStyle(Design.warning)
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 10.5, weight: .medium))
                recoveryActions
            }
            .padding(.horizontal, Design.gutter).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint(primary.tone).opacity(0.055))
            .overlay(alignment: .leading) { Rectangle().fill(tint(primary.tone)).frame(width: 3) }
            .sheet(isPresented: $showsDetails) { details }
        }
    }

    @ViewBuilder private var recoveryActions: some View {
        if onConfirmProject != nil || onCheckProject != nil || onReviewDelivery != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }.buttonStyle(.bordered).controlSize(.small)
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if let onConfirmProject { Button("Confirm project folder…", action: onConfirmProject) }
        if let onCheckProject { Button("Check project again", action: onCheckProject) }
        if let onReviewDelivery { Button("Review delivery", action: onReviewDelivery) }
    }

    var details: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Chat status", systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                Button("Done") { showsDetails = false }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(presentation.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(item.title, systemImage: item.symbol)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint(item.tone))
                            Text(item.message).font(.system(size: 12)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(16)
            }
        }.frame(minWidth: 320, idealWidth: 560, minHeight: 280, idealHeight: 440)
    }

    private func tint(_ tone: ChatStatusPresentation.Tone) -> Color {
        switch tone {
        case .uncertain, .warning: Design.warning
        case .danger: Design.danger
        case .information: Design.accent
        case .success: Design.success
        }
    }
}
