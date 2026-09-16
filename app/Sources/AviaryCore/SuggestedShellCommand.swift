import Foundation

/// An explicit shell fence that can be prepared as an unsent request to the current chat.
///
/// This value never executes or submits anything. It keeps the suggested bytes intact so the
/// GUI can show them in the composer and leave the eventual Send as a separate human action.
public struct SuggestedShellCommand: Equatable, Hashable, Sendable {
    public static let maximumSourceBytes = 16 * 1024

    public let language: String
    public let source: String
    public let draftText: String

    private static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "shell"]

    /// Recognize only explicitly labelled shell fences and prepare a byte-preserving draft.
    ///
    /// Unlabelled, `console`, and `terminal` blocks are deliberately excluded: those commonly
    /// contain prompt markers or output that should not be presented as an executable command.
    public static func make(language: String?, source: String) -> SuggestedShellCommand? {
        guard let language else { return nil }
        let normalizedLanguage = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard shellLanguages.contains(normalizedLanguage),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= maximumSourceBytes,
              source.unicodeScalars.allSatisfy(Self.isAllowedSourceScalar)
        else { return nil }

        let fence = String(
            repeating: "`",
            count: max(3, longestBacktickRun(in: source) + 1))
        let closingSeparator = source.hasSuffix("\n") ? "" : "\n"
        let draft = """
        Run the following shell command exactly as written in this chat's current project and report its output:

        \(fence)\(normalizedLanguage)
        \(source)\(closingSeparator)\(fence)
        """
        return SuggestedShellCommand(
            language: normalizedLanguage, source: source, draftText: draft)
    }

    private static func isAllowedSourceScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D:
            return true
        case 0x00...0x1F, 0x7F...0x9F:
            return false
        default:
            return true
        }
    }

    private static func longestBacktickRun(in source: String) -> Int {
        var longest = 0
        var current = 0
        for byte in source.utf8 {
            if byte == UInt8(ascii: "`") {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
