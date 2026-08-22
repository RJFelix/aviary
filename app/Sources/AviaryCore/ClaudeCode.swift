import Foundation

/// The `claude` CLI, as something Aviary can drive.
///
/// This is not a provider and does not pretend to be one. Claude Code will not accept a
/// prepared conversation — `--input-format stream-json` silently discards any `assistant` line
/// you feed it — so it cannot serve as a stateless completion endpoint for Aviary's own loop.
/// What it can do is run its own loop with exactly one tool, and that tool can be Aviary's
/// kernel. So Claude Code drives, and the kernel is what it reaches with. See
/// `plans/claude-code-as-transport.md` for the measurements this is built on.
public enum ClaudeCode {

    // MARK: Locating the binary

    /// Where a real install lives, in the order worth trying.
    private static let installCandidates = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.claude/local/claude",
        "~/.local/bin/claude",
    ]

    /// Find the `claude` binary, preferring a real install over whatever is on `PATH`.
    ///
    /// `PATH` is checked last and filtered, because a terminal multiplexer or IDE integration
    /// commonly puts a **shim** on it that lives under `/var/folders/…/T/` — one was on this
    /// machine's `PATH` while this was written. A shim is scoped to the session that made it,
    /// so resolving to one gives Aviary a path that works today and is gone tomorrow.
    public static func locate() async -> String? {
        let fm = FileManager.default
        for candidate in installCandidates {
            let path = (candidate as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        if let found = await Shell.which("claude"), !isEphemeral(found),
           fm.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    /// Whether a path is a per-session shim rather than an install.
    static func isEphemeral(_ path: String) -> Bool {
        let temporary = ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"]
        return temporary.contains { path.hasPrefix($0) }
    }

    // MARK: Authentication

    /// What `claude auth status` reports.
    public struct Auth: Sendable, Equatable {
        public var loggedIn = false
        public var method: String?
        public var apiProvider: String?
        public var email: String?
        public var organization: String?
        /// `pro`, `max`, `team`, `enterprise`, or nil for an API-key login.
        public var subscription: String?

        /// Whether a run would draw on the plan rather than on metered API credit.
        ///
        /// The distinction is the entire reason this session type exists, and it is not
        /// something to infer from the presence of a login: an `ANTHROPIC_API_KEY` in the
        /// environment outranks subscription OAuth silently, so a session can look perfectly
        /// healthy while spending API money.
        public var isSubscription: Bool {
            loggedIn && method == "claude.ai" && subscription != nil
        }

        public var summary: String {
            guard loggedIn else { return "Not signed in" }
            let plan = subscription?.capitalized ?? apiProvider ?? "unknown"
            if let organization { return "\(plan) · \(organization)" }
            return plan
        }
    }

    /// Read the current login. Returns nil when the binary could not be run at all, which is a
    /// different fact from "not signed in" and worth keeping different.
    public static func authStatus(binary: String? = nil) async -> Auth? {
        guard let exe = await { if let binary { return binary } else { return await locate() } }()
        else { return nil }
        guard case .success(let result) = await Shell.run(
            exe, ["auth", "status"], environment: scrubbedEnvironment(), timeout: 20)
        else { return nil }
        // Answers JSON on stdout even when not signed in, so a parse failure means something
        // else went wrong.
        guard let json = JSONValue.parse(Data(result.stdout.utf8)) else { return nil }
        return Auth(
            loggedIn: json["loggedIn"]?.boolValue ?? false,
            method: json["authMethod"]?.stringValue,
            apiProvider: json["apiProvider"]?.stringValue,
            email: json["email"]?.stringValue,
            organization: json["orgName"]?.stringValue,
            subscription: json["subscriptionType"]?.stringValue)
    }

    // MARK: The environment a driven run gets

    /// Variables that must not reach a driven `claude`, and why each one matters.
    ///
    /// The first group redirects authentication. Claude Code's precedence puts every one of
    /// these *above* subscription OAuth, so leaving one set means the run quietly bills API
    /// credit while every visible sign says it worked. `apiKeySource` in the `system/init`
    /// frame is the check that this scrub took effect.
    ///
    /// The second group is a parent Claude Code session's own state. Aviary is developed from
    /// inside Claude Code, so these are routinely present in its environment — and handing a
    /// child the parent's session id and messaging socket makes it a participant in a
    /// conversation it knows nothing about.
    public static let strippedVariables = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_CUSTOM_HEADERS",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "AWS_BEARER_TOKEN_BEDROCK",
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID",
        "CLAUDE_EFFORT", "CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION",
    ]

    /// The process environment with the above removed.
    ///
    /// `CLAUDE_CODE_OAUTH_TOKEN` is deliberately *not* stripped: it is the documented way to
    /// authenticate a headless subscription session, so somebody who set one meant it.
    public static func scrubbedEnvironment(
        base: [String: String]? = nil, adding extras: [String: String] = [:]
    ) -> [String: String] {
        var env = base ?? ProcessEnvironment.shared.snapshot
        for name in strippedVariables { env.removeValue(forKey: name) }
        for (k, v) in extras { env[k] = v }
        if (env["PATH"] ?? "").isEmpty {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        }
        return env
    }

    // MARK: Building the invocation

    /// How to launch one driven session.
    public struct Invocation: Sendable {
        /// `sonnet`, `opus`, `haiku`, or a full model id.
        public var model: String
        public var cwd: String
        public var systemPrompt: String
        /// MCP servers to attach, as the `mcpServers` object `--mcp-config` takes.
        public var mcpServers: JSONValue
        /// Tool names to permit without asking. Anything not listed still produces a visible
        /// `tool_use` block, but lands in `permission_denials` instead of running.
        public var allowedTools: [String]
        /// Reasoning effort, when the model supports it.
        public var effort: String?
        /// A session id to continue, from a previous `system/init` frame.
        public var resume: String?

        public init(
            model: String, cwd: String, systemPrompt: String,
            mcpServers: JSONValue = .object([:]), allowedTools: [String] = [],
            effort: String? = nil, resume: String? = nil
        ) {
            self.model = model
            self.cwd = cwd
            self.systemPrompt = systemPrompt
            self.mcpServers = mcpServers
            self.allowedTools = allowedTools
            self.effort = effort
            self.resume = resume
        }

        /// The argument list.
        ///
        /// Three of these flags are load-bearing and none of them is obvious:
        ///
        /// - `--tools ""` empties the built-in tool set. The model does not then hallucinate
        ///   tool calls; it answers as a plain completion, or reaches for the one tool we did
        ///   attach.
        /// - `--setting-sources ""`, `--strict-mcp-config` and `--disable-slash-commands`
        ///   together are what make the input overhead **286 tokens** instead of 80–106k. The
        ///   difference is the developer's own environment — CLAUDE.md, plugins, skills, and
        ///   every claude.ai MCP connector — being read in as context.
        /// - `--bare` is *not* used, despite being the documented mode for scripted runs. Bare
        ///   mode never reads OAuth credentials or the keychain, so the flag designed for
        ///   programmatic use is exactly the flag that removes the subscription this session
        ///   type exists to use. The docs say bare may become the `-p` default, which makes
        ///   this a standing durability risk rather than a settled one.
        public var arguments: [String] {
            var args = [
                "-p",
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--model", model,
                "--tools", "",
                "--system-prompt", systemPrompt,
                "--strict-mcp-config",
                "--setting-sources", "",
                "--disable-slash-commands",
                "--permission-mode", "dontAsk",
            ]
            if case .object(let servers) = mcpServers, !servers.isEmpty {
                args += ["--mcp-config", JSONValue.object(["mcpServers": mcpServers]).compactJSON]
            }
            // Written as one comma-joined value rather than repeated words: `--allowedTools`
            // is variadic, so a space-separated list swallows whatever follows it.
            if !allowedTools.isEmpty {
                args += ["--allowedTools", allowedTools.joined(separator: ",")]
            }
            if let effort { args += ["--effort", effort] }
            if let resume { args += ["--resume", resume] }
            return args
        }
    }
}
