import AviaryCore
import AppKit
import SwiftUI

/// Model prose, rendered with block structure.
///
/// `MarkdownParser` decides the blocks; this only draws them. Inline markdown is still parsed
/// by `AttributedString` in `inlineOnlyPreservingWhitespace` mode, per block — which is what
/// keeps hard line breaks inside a paragraph while letting a list be a list.
///
/// Search takes priority over formatting: while a query is active every block falls back to
/// highlighted plain text, because a match inside a run that markdown consumed is a match the
/// reader cannot see. Finding the text matters more than the styling of it.
struct MarkdownBody: View {
    var text: String
    var query: String = ""
    var onAskAgentToRun: ((SuggestedShellCommand) -> Void)?

    private var blocks: [MarkdownBlock] { MarkdownParser.blocks(from: text) }

    var body: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            HighlightedText(text: text, query: query)
                .font(.system(size: 13))
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block, onAskAgentToRun: onAskAgentToRun)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BlockView: View {
    var block: MarkdownBlock
    var onAskAgentToRun: ((SuggestedShellCommand) -> Void)?

    var body: some View {
        switch block {
        case let .heading(level, text):
            InlineText(text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .semibold : .medium))
                .foregroundStyle(.primary)
                // Headings separate sections, so they get air above but not below: the block
                // they introduce supplies that.
                .padding(.top, level <= 2 ? 6 : 2)

        case let .paragraph(text):
            InlineText(text)
                .font(.system(size: 13))

        case let .list(list):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                    ListItemRow(item: item, ordered: list.ordered)
                }
            }

        case let .quote(inner):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Design.accent.opacity(0.45))
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, b in
                        BlockView(block: b)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(language, source, isClosed):
            FencedCode(language: language, source: source,
                       onAskAgentToRun: isClosed ? onAskAgentToRun : nil)

        case .rule:
            Divider().padding(.vertical, 2)

        case let .table(table):
            MarkdownTableView(table: table)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 16
        case 3: return 14
        default: return 13
        }
    }
}

private struct ListItemRow: View {
    var item: MarkdownListItem
    var ordered: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            InlineText(item.text)
                .font(.system(size: 13))
        }
        // Indent by depth rather than nesting VStacks: the parser already flattened the
        // hierarchy, and a flat list keeps every item's text on one alignment guide.
        .padding(.leading, CGFloat(item.depth) * 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var marker: some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(checked ? Design.accent : .secondary)
                .frame(width: 16, alignment: .leading)
        } else if ordered {
            Text(item.marker)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                // Fixed width so the text of every item lines up even across 9 → 10.
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            // A dot at every depth, sized down when nested, rather than the usual
            // bullet/circle/square cycle — depth is already carried by the indent, and one
            // shape reads as one list.
            Circle()
                .fill(Color.secondary.opacity(item.depth == 0 ? 0.65 : 0.4))
                .frame(width: item.depth == 0 ? 4 : 3, height: item.depth == 0 ? 4 : 3)
                .frame(width: 14, alignment: .center)
                .offset(y: -1)
        }
    }
}

private struct FencedCode: View {
    var language: String?
    var source: String
    var onAskAgentToRun: ((SuggestedShellCommand) -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "code")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(source, forType: .string)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .accessibilityLabel("Copy code")
                .help("Copy this code block without its Markdown fence")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            ScrollView(.horizontal, showsIndicators: false) {
                // Highlighting only where it is actually right: `PythonHighlighter` is a
                // Python and shell lexer, and applying it to Rust or JSON invents syntax.
                Group {
                    if shouldHighlight {
                        Text(PythonHighlighter.highlight(source))
                    } else {
                        Text(source)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let onAskAgentToRun,
               let command = SuggestedShellCommand.make(language: language, source: source) {
                Divider()
                Button { onAskAgentToRun(command) } label: {
                    Label("Ask agent to run…", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Design.accent)
                .help("Review this command and prepare a message in this chat. Nothing runs until you send it.")
            }
        }
        .onChange(of: source) { _, _ in copied = false }
        .background(Design.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var shouldHighlight: Bool {
        guard let language else { return false }
        return ["python", "py", "ipython", "bash", "sh", "shell", "zsh", "console"]
            .contains(language)
    }
}

private struct MarkdownTableView: View {
    var table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                    Divider().opacity(0.5)
                    row(cells, isHeader: false, zebra: index.isMultiple(of: 2))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func row(_ cells: [String], isHeader: Bool, zebra: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                InlineText(cell)
                    .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(isHeader ? .primary : .secondary)
                    .multilineTextAlignment(alignment(index))
                    .frame(minWidth: 60, alignment: frameAlignment(index))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                if index < cells.count - 1 { Divider().opacity(0.4) }
            }
        }
        .background(isHeader ? Design.codeBackground : (zebra ? Color.clear
            : Color.primary.opacity(0.02)))
    }

    private func alignment(_ index: Int) -> TextAlignment {
        guard index < table.alignments.count else { return .leading }
        switch table.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ index: Int) -> Alignment {
        guard index < table.alignments.count else { return .leading }
        switch table.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// One run of inline markdown, with the plain string as the fallback.
private struct InlineText: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
