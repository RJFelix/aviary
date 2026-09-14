import SwiftUI
import AviaryCore

struct ReviewHunkCodeBlock: View {
    let hunk: RepositoryReviewDiffHunk
    @State private var expanded = false
    @State private var copied = false

    init(hunk: RepositoryReviewDiffHunk, initiallyExpanded: Bool = false) {
        self.hunk = hunk
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let lines = RepositoryReviewDiffDisplayLine.lines(in: hunk)
        let shown = expanded ? lines : Array(lines.prefix(10))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("+ Added").foregroundStyle(Design.success)
                Text("− Removed").foregroundStyle(Design.danger)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hunk.context, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Copied hunk" : "Copy complete retained hunk")
            }.font(.system(size: 9.5, weight: .medium)).padding(8)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(Design.mono(11.5))
                                .textSelection(.enabled)
                                .foregroundStyle(line.kind == .marker ? Color.secondary : Color.primary)
                                .padding(.horizontal, 9).padding(.vertical, 2)
                                .frame(minWidth: geometry.size.width, alignment: .leading)
                                .background(background(line.kind))
                        }
                    }.fixedSize(horizontal: true, vertical: true)
                }
            }.frame(height: min(CGFloat(shown.count) * 18, expanded ? 280 : 180))
            if lines.count > 10 {
                Divider()
                Button(expanded ? "Collapse hunk" : "Show \(lines.count - 10) more retained lines") {
                    expanded.toggle()
                }.buttonStyle(.plain).font(.caption).foregroundStyle(Design.accent)
                    .padding(8).frame(maxWidth: .infinity)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func background(_ kind: RepositoryReviewDiffDisplayLine.Kind) -> Color {
        switch kind {
        case .addition: Design.success.opacity(0.13)
        case .removal: Design.danger.opacity(0.10)
        case .context, .marker: .clear
        }
    }
}
