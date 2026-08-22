import Foundation

/// Expands `/name` at the start of a prompt using the prompt templates on disk.
///
/// The harness's slash commands, in the form that matters: a prompt you have written once and
/// want to reuse. Deliberately only at the *start* of a prompt and only one — a prompt that
/// expands templates anywhere becomes a templating language, and a `/` in the middle of a
/// sentence is far more often a path than a command.
public struct PromptExpander: Sendable {
    public let templates: [PromptTemplate]

    public init(templates: [PromptTemplate]) {
        self.templates = templates
    }

    public struct Expansion: Sendable {
        public var prompt: String
        /// Which template was used, if any — so a caller can say so rather than silently
        /// sending something other than what was typed.
        public var template: PromptTemplate?
        public var missing: String?
    }

    public func expand(_ input: String) -> Expansion {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else {
            return Expansion(prompt: input, template: nil, missing: nil)
        }
        // Split the command from its argument on the first run of whitespace.
        let body = trimmed.dropFirst()
        let name: String
        let argument: String
        if let space = body.firstIndex(where: { $0.isWhitespace }) {
            name = String(body[body.startIndex..<space])
            argument = String(body[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = String(body)
            argument = ""
        }
        guard let template = templates.first(where: { $0.name == name }) else {
            // Not silently sent as-is: a mistyped command that reaches the model as a literal
            // slash reads as the model ignoring an instruction.
            return Expansion(prompt: input, template: nil, missing: name)
        }
        guard let text = try? String(contentsOf: template.url, encoding: .utf8) else {
            return Expansion(prompt: input, template: nil, missing: name)
        }
        return Expansion(
            prompt: Self.substitute(text, argument: argument),
            template: template, missing: nil)
    }

    /// `$ARGUMENTS` and `$1` are the conventions other tools use; both are supported, and an
    /// argument with nowhere to go is appended rather than dropped.
    static func substitute(_ text: String, argument: String) -> String {
        var out = text
        var placed = false
        for token in ["$ARGUMENTS", "{{args}}", "$1"] where out.contains(token) {
            out = out.replacingOccurrences(of: token, with: argument)
            placed = true
        }
        if !placed, !argument.isEmpty {
            out += "\n\n" + argument
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
