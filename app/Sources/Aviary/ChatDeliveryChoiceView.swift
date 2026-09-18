import AviaryCore
import SwiftUI

/// The busy composer action strip.
///
/// Delivery is the action now: each button submits its own capability-gated command. The
/// preference menu only chooses which action is primary and what Return invokes; it never adds a
/// route or bypasses the enclosing composer admission guard.
struct ChatDeliveryChoiceView: View {
    let choices: [ChatBusyDelivery]
    let canSubmit: Bool
    let statusText: String
    @Binding var preferenceRawValue: String
    let onSubmit: (ChatBusyDelivery) -> Void

    init(
        choices: [ChatBusyDelivery],
        canSubmit: Bool,
        statusText: String,
        preferenceRawValue: Binding<String>,
        onSubmit: @escaping (ChatBusyDelivery) -> Void
    ) {
        self.choices = choices
        self.canSubmit = canSubmit
        self.statusText = statusText
        _preferenceRawValue = preferenceRawValue
        self.onSubmit = onSubmit
    }

    private var preference: ChatBusyDeliveryPreference {
        ChatBusyDeliveryPreference.load(rawValue: preferenceRawValue)
    }

    private var resolvedPrimary: ChatBusyDelivery? {
        preference.resolved(in: choices)
    }

    var body: some View {
        if choices.isEmpty {
            draftOnlyRow
        } else {
            HStack(spacing: 6) {
                ForEach(choices) { choice in
                    actionButton(choice)
                }
                preferenceMenu
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-delivery-strip")
        }
    }

    @ViewBuilder
    private func actionButton(_ choice: ChatBusyDelivery) -> some View {
        let isPrimary = resolvedPrimary == choice
        if isPrimary {
            actionButtonContent(choice)
                .buttonStyle(.borderedProminent)
        } else {
            actionButtonContent(choice)
                .buttonStyle(.bordered)
        }
    }

    private func actionButtonContent(_ choice: ChatBusyDelivery) -> some View {
        let isPrimary = resolvedPrimary == choice
        return Button {
            guard canSubmit else { return }
            onSubmit(choice)
        } label: {
            Label(choice.compactLabel, systemImage: choice.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .frame(minWidth: 76, minHeight: 22)
        }
        .tint(isPrimary ? Design.accent : Color.secondary)
        .controlSize(.small)
        .disabled(!canSubmit)
        .accessibilityIdentifier("chat-delivery-\(choice.rawValue)")
        .accessibilityLabel(choice.compactLabel)
        .accessibilityValue(isPrimary ? "Primary action" : "Available action")
        .accessibilityHint(choice.explanation + ". " + statusText)
        .help(choice.explanation)
    }

    private var preferenceMenu: some View {
        Menu {
            Text("Return / primary action")
                .font(.caption)
            ForEach(ChatBusyDeliveryPreference.allCases) { candidate in
                Button {
                    preferenceRawValue = candidate.rawValue
                } label: {
                    if preference == candidate {
                        Label(candidate.label, systemImage: "checkmark")
                    } else {
                        Text(candidate.label)
                    }
                }
                .disabled(!choices.contains(candidate.delivery))
                .help(candidate.explanation)
            }
            if let resolvedPrimary, resolvedPrimary != preference.delivery {
                Divider()
                Text("Default unavailable here; Return uses \(resolvedPrimary.compactLabel).")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel("Busy composer default")
        .accessibilityValue(resolvedPrimary?.compactLabel ?? "No available action")
        .accessibilityHint(resolvedPrimary?.explanation ?? "No delivery route is available.")
        .help("Return / primary action: \(resolvedPrimary?.compactLabel ?? "unavailable")")
    }

    private var draftOnlyRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Draft only")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 4)
            Text("No delivery route")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.22)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-delivery-draft-only")
        .accessibilityLabel("Draft only")
        .accessibilityValue("No delivery destination is available")
    }
}
