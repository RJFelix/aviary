import Foundation
@testable import AviaryCore

let casesSuggestedShellCommand: [Case] = [
    ("suggested shell command accepts only normalized explicit shell languages", {
        for input in ["sh", "SH", " Bash ", "zSh", "shell"] {
            let suggestion = try XCTUnwrap(SuggestedShellCommand.make(
                language: input, source: "printf 'ready\\n'"))
            XCTAssertEqual(suggestion.language, input.trimmingCharacters(
                in: .whitespacesAndNewlines).lowercased())
        }
    }),
    ("suggested shell command excludes ambiguous and unknown fences", {
        for language: String? in [nil, "", "console", "terminal", "python", "bash session"] {
            XCTAssertNil(SuggestedShellCommand.make(language: language, source: "echo ready"))
        }
    }),
    ("suggested shell command rejects empty and oversized source", {
        XCTAssertNil(SuggestedShellCommand.make(language: "sh", source: ""))
        XCTAssertNil(SuggestedShellCommand.make(language: "sh", source: " \t\r\n"))
        XCTAssertNotNil(SuggestedShellCommand.make(
            language: "sh",
            source: String(repeating: "x", count: SuggestedShellCommand.maximumSourceBytes)))
        XCTAssertNil(SuggestedShellCommand.make(
            language: "sh",
            source: String(repeating: "x", count: SuggestedShellCommand.maximumSourceBytes + 1)))
    }),
    ("suggested shell command rejects controls but permits shell line whitespace", {
        XCTAssertNil(SuggestedShellCommand.make(language: "bash", source: "echo\u{0}hidden"))
        XCTAssertNil(SuggestedShellCommand.make(language: "bash", source: "echo\u{7}bell"))
        let source = "printf 'one'\t# tab\r\nprintf 'two'\n"
        XCTAssertEqual(
            SuggestedShellCommand.make(language: "bash", source: source)?.source,
            source)
    }),
    ("suggested shell command preserves unicode multiline source exactly", {
        let source = """
        printf '%s\\n' 'café ☕️'
        # Keep this placeholder exactly: $PROJECT_ROOT
        ./serve --name "βeta"
        """
        let suggestion = try XCTUnwrap(SuggestedShellCommand.make(
            language: "ZSH", source: source))
        XCTAssertEqual(suggestion.source, source)
        XCTAssertTrue(suggestion.draftText.contains(source))
        XCTAssertTrue(suggestion.draftText.hasPrefix(
            "Run the following shell command exactly as written in this chat's current project and report its output:"))
    }),
    ("suggested shell command uses a fence longer than every source backtick run", {
        let source = "echo ```\nprintf '``````'\n# $PLACEHOLDER stays literal"
        let suggestion = try XCTUnwrap(SuggestedShellCommand.make(
            language: "shell", source: source))
        let lines = suggestion.draftText.components(separatedBy: "\n")
        let opening = try XCTUnwrap(lines.first(where: { $0.hasSuffix("shell") && $0.hasPrefix("```") }))
        let fence = String(opening.dropLast("shell".count))
        XCTAssertEqual(fence.count, 7)
        XCTAssertTrue(suggestion.draftText.hasSuffix(fence))
        XCTAssertEqual(suggestion.source, source)
    }),
    ("suggested shell command does not strip prompt-like placeholders or comments", {
        let source = "$ npm run dev\n# replace $PORT only if asked\nprintf '%s\\n' \"$PORT\""
        let suggestion = try XCTUnwrap(SuggestedShellCommand.make(
            language: "sh", source: source))
        XCTAssertEqual(suggestion.source, source)
        XCTAssertTrue(suggestion.draftText.contains("\n" + source + "\n"))
    }),
]
