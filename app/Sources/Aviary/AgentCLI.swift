import Foundation
import AviaryCore

/// `Aviary --agent "<prompt>"` — the in-house agent, no harness, no Node.
///
/// A headless entry point rather than a GUI-only feature, for three reasons: it is the only way
/// to verify the whole stack without a window, it is what a test or a cron job would call, and
/// a coding agent that cannot be driven from a terminal is missing the place most of its work
/// starts.
///
/// Resolves a provider out of the same `models.json` the harness reads, so a route that already
/// works keeps working — including the LiteLLM gateway, which is deliberately the default path
/// so runs stay metered.
enum AgentCLI {

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--agent") else { return }
        let prompt = args.count > flag + 1 ? args[flag + 1] : ""
        guard !prompt.isEmpty, !prompt.hasPrefix("--") else {
            fail("usage: Aviary --agent \"<prompt>\" [--model provider/id] [--cwd path] "
                + "[--host python3|python3-shared] [--record] [--quiet]")
        }
        let model = value(of: "--model", in: args)
        let cwd = value(of: "--cwd", in: args) ?? FileManager.default.currentDirectoryPath
        let variant = value(of: "--host", in: args) ?? "python3"
        let quiet = args.contains("--quiet")
        let record = args.contains("--record")

        // Its own run loop: this process has no NSApplication, and the async work below needs
        // the main queue drained or nothing progresses. The same reason `--snapshot` pumps it.
        let done = Atomic(false)
        Task {
            await run(prompt: prompt, modelRef: model, cwd: cwd, variant: variant,
                      quiet: quiet, record: record)
            done.set(true)
        }
        while !done.get() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(0)
    }

    private static func run(
        prompt: String, modelRef: String?, cwd: String, variant: String, quiet: Bool,
        record: Bool
    ) async {
        _ = await ProcessEnvironment.shared.loadFromLoginShell()
        let home = AgentHome.default

        guard let repoRoot = EngineLocator.repoRoot() else {
            fail("Could not find the Aviary checkout, so there is no runtime host to run.")
        }

        // 1. A model, and the provider that serves it.
        let auth = AuthInfo.load(home: home)
        let config = ModelsConfig.load(home: home, auth: auth)
        guard let (providerSpec, model) = resolve(modelRef, in: config) else {
            let available = config.providers.flatMap { p in p.models.map { "\(p.id)/\($0.id)" } }
            fail("No such model. Configured: \(available.prefix(12).joined(separator: ", "))")
        }
        guard let baseURL = providerSpec.baseURL.flatMap(URL.init(string:)) else {
            fail("Provider \(providerSpec.id) has no baseUrl.")
        }
        let key = await ApiKeyResolver.resolve(providerSpec.apiKeyExpression)
        if !key.ok {
            // Non-blocking: a provider may legitimately need no key, and refusing to start on
            // a format guess is how a working setup gets called broken.
            note("credentials: \(key.explanation)")
        }
        let resolvedKey = await resolvedSecret(providerSpec.apiKeyExpression)

        // 2. The runtime host.
        let hostScript = repoRoot.appending(path: "runtime-hosts/\(variant)/host.py")
        guard FileManager.default.fileExists(atPath: hostScript.path) else {
            fail("No runtime host at \(hostScript.path)")
        }
        let host = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", hostScript.path])
        let capabilities: RuntimeHost.Capabilities
        do {
            capabilities = try await host.start()
        } catch {
            fail("Could not start the runtime host: \(error.localizedDescription)")
        }
        if !quiet {
            note("runtime \(capabilities.summary) · session isolation "
                + (capabilities.has("perSessionGIL") ? "on" : "off"))
        }

        // 3. A runner, which owns session creation, sub-agents and the callback wiring.
        let provider = OpenAICompletionsProvider(
            id: providerSpec.id, baseURL: baseURL, apiKey: resolvedKey,
            extraHeaders: providerSpec.headers)
        // Skills, gated. The harness sent all 68 on every request — 62.7% of input tokens on
        // a trivial run — so this is the one place worth doing differently rather than
        // faithfully.
        let settings = HarnessSettings.load(home: home)
        let library = Library.discover(
            home: home, settings: settings,
            projectRoot: URL(fileURLWithPath: cwd), enginePackageRoot: nil)
        let gate = SkillGate()
        let selection = gate.select(skills: library.skills, prompt: prompt, cwd: cwd)
        if !quiet, !library.skills.isEmpty {
            note("skills \(selection.included.count) of \(library.skills.count) described "
                + "(\(Fmt.bytes(selection.charactersUsed)) of "
                + "\(Fmt.bytes(selection.charactersIfAllIncluded)); "
                + "\(Fmt.bytes(selection.savedCharacters)) saved)")
        }

        // Memory, gated the same way skills are. Read before the run so it can go in the
        // prompt; written during it through the `remember` callback.
        let memory = MemoryStore(repoRoot: repoRoot, home: home, cwd: cwd)
        let memoryGate = MemoryGate()
        let recalled = memoryGate.select(memory.load(sessionID: nil), prompt: prompt)
        if !quiet, recalled.totalAvailable > 0 {
            note("memory \(recalled.included.count) recalled"
                + (recalled.listed.isEmpty ? "" : ", \(recalled.listed.count) listed"))
        }

        let runner = AgentRunner(
            provider: provider, host: host,
            settings: .init(
                home: home, cwd: cwd, model: model,
                systemPrompt: SystemPrompt.build(
                    cwd: cwd, model: model, skills: gate.render(selection),
                    memory: memoryGate.render(recalled)),
                memory: memory, recordPayloads: record))

        await runner.observe { event in
            switch event {
            case .textDelta(let t):
                FileHandle.standardOutput.write(Data(t.utf8))
            case .thinkingDelta:
                break  // shown in the GUI, noise in a terminal
            case .toolStarted(_, _, let arguments):
                let code = arguments["code"]?.stringValue ?? ""
                note("\n▸ python\n" + code.split(separator: "\n").map { "  \($0)" }
                    .joined(separator: "\n"))
            case .toolFinished(_, _, let output, let isError):
                let head = output.split(separator: "\n").prefix(12).map { "  \($0)" }
                    .joined(separator: "\n")
                note((isError ? "✗ " : "◂ ") + "\n\(head)"
                    + (output.split(separator: "\n").count > 12 ? "\n  …" : ""))
            case .turnFinished(let usage, _):
                if let usage, !quiet {
                    note("  · \(Fmt.tokens(usage.input)) in / \(Fmt.tokens(usage.output)) out"
                        + (usage.reasoning.map { " / \(Fmt.tokens($0)) reasoning" } ?? ""))
                }
            case .finished(let reason):
                note("\n— finished (\(reason))")
            case .failed(let detail):
                note("\n— failed: \(detail)")
            case .compacted(let before, _, _):
                note("\n— compacted at \(Fmt.tokens(before)) tokens")
            case .childStarted(_, let name, let prompt):
                note("\n⤷ \(name): \(prompt.prefix(80))")
            case .childFinished(_, let name, _, let isError):
                note((isError ? "⤶ \(name) failed" : "⤶ \(name) done"))
            case .started(let session):
                if !quiet { note("session \(session) · \(model.qualifiedID) · \(cwd)") }
            }
        }

        do {
            let (writer, agent) = try await runner.run(prompt: prompt)
            let total = await agent.totalUsage
            if !quiet {
                note("total \(Fmt.tokens(total.totalTokens)) tokens"
                    + (total.cacheHitRate.map { String(format: " · %.0f%% cached", $0 * 100) } ?? ""))
                note("transcript \(writer.fileURL.path)")
            }
            await writer.close()
        } catch {
            note("could not start: \(error.localizedDescription)")
        }
        await host.stop()
    }

    // MARK: Helpers

    /// `provider/model`, or a bare model id matched across providers, or the first configured.
    static func resolve(
        _ reference: String?, in config: ModelsConfig
    ) -> (ProviderSpec, ModelSpec)? {
        guard let reference, !reference.isEmpty else {
            for provider in config.providers {
                if let first = provider.models.first { return (provider, first) }
            }
            return nil
        }
        if reference.contains("/") {
            // Split on the *first* slash only: model ids contain slashes too, as with
            // `baseten/deepseek-v4-pro` behind the gateway.
            let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
            if let provider = config.providers.first(where: { $0.id == parts[0] }),
               let model = provider.models.first(where: { $0.id == parts[1] })
            {
                return (provider, model)
            }
        }
        for provider in config.providers {
            if let model = provider.models.first(where: { $0.id == reference }) {
                return (provider, model)
            }
        }
        return nil
    }

    /// The actual secret, resolved the same way the harness resolves it.
    static func resolvedSecret(_ expression: String?) async -> String? {
        guard let expression, !expression.isEmpty else { return nil }
        switch ApiKeyForm.classify(expression) {
        case .command(let cmd):
            let shell = ProcessEnvironment.shared.value("SHELL") ?? "/bin/zsh"
            guard case .success(let r) = await Shell.run(shell, ["-c", cmd], timeout: 20), r.ok
            else { return nil }
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        case .environmentVariable(let name):
            return ProcessEnvironment.shared.value(name)
        case .literal:
            return expression
        }
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    private static func note(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    private static func fail(_ s: String) -> Never {
        FileHandle.standardError.write(Data(("aviary: " + s + "\n").utf8))
        exit(2)
    }
}

/// A boolean two threads can agree on, for the run-loop pump.
final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ initial: Bool) { value = initial }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: Bool) { lock.lock(); value = new; lock.unlock() }
}

/// What the agent is told about itself.
///
/// Short on purpose. The measured cost of the harness's prompt was 68 skill descriptions at
/// 62.7% of input on a trivial run — paid on every request whether or not any skill was used.
/// Starting from nothing and adding only what earns its tokens is the whole point of owning
/// this.
enum SystemPrompt {
    static func build(
        cwd: String, model: ModelSpec, skills: String = "", memory: String = ""
    ) -> String {
        var lines = [
            "You are a coding agent working in \(cwd) on a macOS machine.",
            "",
            "You act by running Python in a persistent interpreter — that is your only tool, "
                + "and it is enough. State survives between calls, so build on what you have "
                + "already loaded instead of repeating work.",
            "",
            "`sh(command)` runs a shell command and returns {'stdout','stderr','status'}. Its "
                + "working directory and environment persist across calls, so `sh('cd sub')` "
                + "then `sh('pwd')` does what you would expect. `cwd()` reports where you are.",
            "",
            "Prefer the tools the repository already has — git, grep, and whatever its own "
                + "task runner exposes — over reimplementing them in Python.",
            "",
            "Say what you found, not what you are about to do. When you are finished, stop "
                + "calling tools and answer.",
        ]
        if !memory.isEmpty {
            lines.append("")
            lines.append(memory)
        }
        if !skills.isEmpty {
            lines.append("")
            lines.append(skills)
        }
        // Project instructions, if the working directory has any. Read at start rather than
        // discovered per turn, so the cost is visible and paid once.
        for name in ["AGENTS.md", "CLAUDE.md"] {
            let url = URL(fileURLWithPath: cwd).appending(path: name)
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                lines.append("")
                lines.append("## \(name) (from \(cwd))")
                lines.append("")
                lines.append(text.count > 12_000 ? String(text.prefix(12_000)) + "\n…(truncated)" : text)
            }
        }
        return lines.joined(separator: "\n")
    }
}
