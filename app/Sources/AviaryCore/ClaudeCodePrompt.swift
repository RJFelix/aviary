import Foundation

/// What a driven Claude Code is told about itself.
///
/// A separate prompt from `SystemPrompt`, and the difference is not stylistic. That one is
/// written for a model whose loop Aviary controls; this one replaces Claude Code's own system
/// prompt entirely, and Claude Code arrives with strong priors about having a dozen file and
/// shell tools. Left unaddressed, it spends turns reaching for `Read` and `Bash` and narrating
/// their absence. So this says plainly that there is one tool, that it is a real interpreter,
/// and that the interpreter is how you do the things those tools would have done.
public enum ClaudeCodePrompt {
    public static func build(
        cwd: String, skills: String = "", memory: String = "",
        includeContextFiles: Bool = true
    ) -> String {
        var lines = [
            "You are a coding agent working in \(cwd) on a macOS machine.",
            "",
            "Your only tool is `python`, a persistent IPython-style interpreter hosted by "
                + "Aviary. You have no file-reading, file-editing, search or shell tools, and "
                + "you do not need them: the interpreter can read and write files, and "
                + "`sh(command)` runs any shell command you want. Reach for `python` where you "
                + "would normally reach for Read, Edit, Grep or Bash.",
            "",
            "State survives between calls — variables, imports, open handles — so build on "
                + "what you have already loaded instead of repeating work. `sh`'s working "
                + "directory and environment persist too, so `sh('cd sub')` then `sh('pwd')` "
                + "does what you would expect.",
            "",
            "Prefer the tools the repository already has — git, grep, its own task runner — "
                + "over reimplementing them in Python.",
            "",
            "Say what you found, not what you are about to do. When you are finished, stop "
                + "calling the tool and answer.",
        ]
        if !memory.isEmpty {
            lines.append("")
            lines.append(memory)
        }
        if !skills.isEmpty {
            lines.append("")
            lines.append(skills)
        }
        // The project's own instructions, read here rather than left to Claude Code's CLAUDE.md
        // discovery — which `--setting-sources ""` switches off, and deliberately: that
        // mechanism also pulls in the *developer's* global CLAUDE.md, plugins and connectors,
        // which is 80k+ tokens of somebody else's environment.
        for name in includeContextFiles ? ["AGENTS.md", "CLAUDE.md"] : [] {
            let url = URL(fileURLWithPath: cwd).appending(path: name)
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                lines.append("")
                lines.append("## \(name) (from \(cwd))")
                lines.append("")
                lines.append(text.count > 12_000
                    ? String(text.prefix(12_000)) + "\n…(truncated)" : text)
            }
        }
        return lines.joined(separator: "\n")
    }
}
