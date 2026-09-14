import SwiftUI
import AviaryCore

/// A compact destination rail for a busy chat composer.
///
/// This view only changes the selected delivery destination. Submission, draft persistence,
/// and focus remain owned by the enclosing composer.
struct ChatDeliveryChoiceView: View {
    let choices: [ChatBusyDelivery]
    @Binding var selection: ChatBusyDelivery

    init(choices: [ChatBusyDelivery], selection: Binding<ChatBusyDelivery>) {
        self.choices = choices
        _selection = selection
    }

    var body: some View {
        if choices.isEmpty {
            draftOnlyRow
        } else if choices.count == 1, let choice = choices.first {
            choiceCard(choice, isSelected: true, isStatic: true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ForEach(choices) { choice in
                        choiceCard(choice, isSelected: selection == choice)
                    }
                }
                .frame(minWidth: 380)

                VStack(spacing: 8) {
                    ForEach(choices) { choice in
                        choiceCard(choice, isSelected: selection == choice)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func choiceCard(
        _ choice: ChatBusyDelivery,
        isSelected: Bool,
        isStatic: Bool = false
    ) -> some View {
        if isStatic {
            cardContent(choice, isSelected: true)
                .accessibilityIdentifier("chat-delivery-\(choice.rawValue)")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                .accessibilityValue("Selected")
                .accessibilityHint(choice.explanation)
        } else {
            Button {
                selection = choice
            } label: {
                cardContent(choice, isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-delivery-\(choice.rawValue)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityHint("Select \(choice.label). \(choice.explanation)")
        }
    }

    private func cardContent(_ choice: ChatBusyDelivery, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: choice.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Design.accent : .secondary)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(choice.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(timingCue(for: choice))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.accent)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Design.accentSoft : Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Design.accent : Color.secondary.opacity(0.22),
                    lineWidth: isSelected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var draftOnlyRow: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Draft only")
                    .font(.system(size: 12.5, weight: .semibold))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-delivery-draft-only")
        .accessibilityLabel("Draft only")
        .accessibilityValue("No delivery destination is available")
    }

    private func timingCue(for choice: ChatBusyDelivery) -> String {
        switch choice {
        case .followUp: "After this response"
        case .guideCurrentWork: "Before the next model request"
        }
    }
}
