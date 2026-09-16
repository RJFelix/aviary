import Foundation

/// Bounded source text used when a person explicitly copies or forwards one transcript row.
/// This is deliberately separate from `TranscriptItem.plainText`, which also includes thinking
/// and tool output and therefore can cross the visible role boundary.
public enum TranscriptMessageTransfer {
    /// Returns the exact authored text for message-like rows, including Markdown and whitespace.
    /// Injected user context remains part of the source block here; the view may render it
    /// separately, but a verbatim transfer must not silently trim or rewrite it.
    public static func authoredText(for item: TranscriptItem) -> String? {
        switch item.kind {
        case .user, .assistant:
            let text = item.blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        case .agentMessage:
            guard !item.text.isEmpty else { return nil }
            return agentBody(from: item.text)
        default:
            return nil
        }
    }

    /// Removes only Aviary's generated agent-message envelope. The authored body is returned
    /// byte-for-byte, including leading/trailing whitespace after the envelope separator.
    public static func agentBody(from text: String) -> String {
        guard text.hasPrefix("[from "), let idRange = text.range(of: "Message id:") else {
            return text
        }
        let afterID = text[idRange.upperBound...]
        guard let blank = afterID.range(of: "\n\n") else { return text }
        return String(text[blank.upperBound...])
    }
}
