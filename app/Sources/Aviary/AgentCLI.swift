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
        if args.contains("--codex-login") {
            runCodexLogin(paste: args.contains("--paste"))
        }
        if args.contains("--mcp-bridge") {
            runMCPBridge()
        }
        guard let flag = args.firstIndex(of: "--agent") else { return }
        let prompt = args.count > flag + 1 ? args[flag + 1] : ""
        guard !prompt.isEmpty, !prompt.hasPrefix("--") else {
            fail("usage: Aviary --agent \"<prompt>\" [--model provider/id] [--cwd path] "
                + "[--host python3|python3-shared] [--record] [--quiet] "
                + "[--budget <tokens>] [--minutes <n>] [--resume <session-id>]")
        }
        let model = value(of: "--model", in: args)
        let cwd = value(of: "--cwd", in: args) ?? FileManager.default.currentDirectoryPath
        let variant = value(of: "--host", in: args) ?? "python3"
        let quiet = args.contains("--quiet")
        let record = args.contains("--record")
        let tokenBudget = value(of: "--budget", in: args).flatMap { Int($0) }
        let minutes = value(of: "--minutes", in: args).flatMap { Double($0) }
        let resume = value(of: "--resume", in: args)

        // Its own run loop: this process has no NSApplication, and the async work below needs
        // the main queue drained or nothing progresses. The same reason `--snapshot` pumps it.
        let done = Atomic(false)
        Task {
            await run(prompt: prompt, modelRef: model, cwd: cwd, variant: variant,
                      quiet: quiet, record: record, tokenBudget: tokenBudget,
                      minutes: minutes, resume: resume)
            await AviaryTelemetry.shutdown(maximumDuration: 2)
            done.set(true)
        }
        while !done.get() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(0)
    }

    /// `Aviary --mcp-bridge` — be the MCP server a driven Claude Code talks to.
    ///
    /// Not documented in the usage line above, because nobody runs this by hand: Claude Code
    /// spawns it, with the bridge endpoint in its environment. Reached before any window is
    /// created, which matters — this mode must never bring up an NSApplication, or every tool
    /// call would flash a second copy of Aviary onto the Dock.
    private static func runMCPBridge() -> Never {
        guard let bridge = MCPBridge.fromEnvironment() else {
            FileHandle.standardError.write(Data(
                ("Aviary --mcp-bridge expects AVIARY_BRIDGE_PORT and AVIARY_BRIDGE_TOKEN in "
                    + "its environment. Claude Code sets them from --mcp-config; there is "
                    + "nothing to do when they are missing.\n").utf8))
            exit(2)
        }
        bridge.serve()
    }

    /// `Aviary --codex-login` — sign in to ChatGPT for the Codex provider.
    private static func runCodexLogin(paste: Bool) -> Never {
        let done = Atomic(false)
        var failure: String?
        Task {
            _ = await ProcessEnvironment.shared.loadFromLoginShell()
            let store = CodexAuth.Store(home: .default)
            let login = CodexLogin()
            do {
                let started = try await login.begin()
                note("Opening your browser to sign in to ChatGPT.")
                note("If it does not open, visit:\n\n\(started.url.absoluteString)\n")
                _ = await Shell.run("/usr/bin/open", [started.url.absoluteString], timeout: 15)

                // The paste option *races* the browser callback rather than replacing it —
                // which is what the reference does, and getting it wrong cost a real login: a
                // paste prompt that returned immediately tore down the listener while the
                // browser was still on the consent screen, so the redirect hit a closed port.
                //
                // Whichever arrives first wins, and the listener stays up either way.
                note("Waiting for the browser to come back on port \(CodexAuth.callbackPort).")
                if paste {
                    note("Or paste the code / full redirect URL here and press return.")
                }
                let code: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await login.waitForCode() }
                    if paste {
                        group.addTask {
                            // readLine blocks a thread, so it runs off the cooperative pool.
                            let typed: String = await withCheckedContinuation { cont in
                                Thread.detachNewThread { cont.resume(returning: readLine() ?? "") }
                            }
                            let parsed = CodexAuth.parseAuthorizationInput(typed)
                            guard let parsedCode = parsed.code, !parsedCode.isEmpty else {
                                // Not a failure of the whole login: the callback may still be
                                // coming, so this branch simply never wins the race.
                                try await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                                throw CodexAuth.AuthError.callbackFailed("nothing pasted")
                            }
                            if let parsedState = parsed.state, parsedState != started.state {
                                throw CodexAuth.AuthError.stateMismatch
                            }
                            return parsedCode
                        }
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }

                let credentials = try await login.complete(
                    code: code, verifier: started.verifier, expectedState: nil, store: store)
                note("Signed in. Account \(credentials.accountId), token valid until "
                    + "\(Fmt.timestamp(credentials.expiresAt)).")
                note("Stored in \(store.url.path) — the same file the harness reads, so this "
                    + "login works in both.")
            } catch {
                failure = error.localizedDescription
            }
            await login.stop()
            await AviaryTelemetry.shutdown(maximumDuration: 2)
            done.set(true)
        }
        while !done.get() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if let failure { fail(failure) }
        exit(0)
    }

    private static func run(
        prompt: String, modelRef: String?, cwd: String, variant: String, quiet: Bool,
        record: Bool, tokenBudget: Int?, minutes: Double?, resume: String? = nil
    ) async {
        _ = await ProcessEnvironment.shared.loadFromLoginShell()
        let home = AgentHome.default

        guard let repoRoot = EngineLocator.repoRoot() else {
            await fail("Could not find the Aviary checkout, so there is no runtime host to run.")
        }

        // Expand before resolving or starting anything. The durable start command must carry
        // the exact prompt the agent will receive, not the slash-command spelling that invoked
        // it.
        let expander = PromptExpander(
            templates: Library.discover(
                home: home, settings: HarnessSettings.load(home: home),
                projectRoot: URL(fileURLWithPath: cwd), enginePackageRoot: nil).prompts)
        let expansion = expander.expand(prompt)
        if let missing = expansion.missing {
            await fail("No prompt template named /\(missing). "
                + "Available: " + expander.templates.map(\.name).sorted()
                    .prefix(12).joined(separator: ", "))
        }
        let prompt = expansion.prompt
        if let template = expansion.template, !quiet {
            note("template /\(template.name) → \(Fmt.bytes(prompt.count))")
        }

        // 1. A model, and the provider that serves it.
        let auth = AuthInfo.load(home: home)
        let config = ModelsConfig.load(home: home, auth: auth)
        guard let (providerSpec, model) = resolve(modelRef, in: config, auth: auth) else {
            let available = (config.providers + [BuiltInProviders.openAICodex()])
                .flatMap { p in p.models.map { "\(p.id)/\($0.id)" } }
            await fail("No such model. Configured: \(available.prefix(12).joined(separator: ", "))")
        }
        let identity = RunConfiguration(
            cwd: cwd, provider: providerSpec.id, model: model.id, resume: resume)
            .resolvedIdentity(home: home)
        let writer: SessionWriter
        do {
            writer = try resume.map {
                try SessionWriter(
                    home: home, resuming: $0, cwd: cwd, model: model, identity: identity)
            } ?? SessionWriter(home: home, cwd: cwd, model: model, identity: identity)
        } catch {
            await fail("Could not open the session journal: \(error.localizedDescription)")
        }

        // Every current in-house launch is backed by the canonical Session/Work pair. Aviary's
        // pre-native local transcripts are disposable development data; an exact cold resume
        // without that pair fails closed instead of silently replaying a different projection.
        let nativeBridge: NativeSessionCommandJournal
        do {
            nativeBridge = try await NativeSessionCommandJournal.openForLaunch(
                home: home, identity: identity, legacyProjection: writer,
                actorID: "cli", modelID: model.qualifiedID,
                modelContextMode: resume == nil ? .launchFresh : .exactColdResume)
        } catch {
            try? await writer.closeChecked()
            await fail("Could not open the canonical Session/Work journal: "
                + error.localizedDescription)
        }
        let nativeJournal = nativeBridge.nativeJournal
        let nativeResumeSeed = nativeBridge.resumeSeed
        let commandJournal: any SessionCommandJournal = nativeBridge

        let commandController = SessionCommandController(
            identity: identity, capabilities: Agent.inHouseCommandCapabilities,
            journal: commandJournal)
        var admittedStartCommandID: String?

        func beginNativeEffect(
            kind: ActionKind, intent: String, target: String? = nil,
            metadata: [String: JSONValue] = [:]
        ) async -> EffectPermit? {
            return try? await nativeJournal.beginAction(
                kind: kind, intent: intent, target: target, scope: "run", metadata: metadata)
        }

        func finishNativeEffect(
            _ permit: EffectPermit?, state: ActionExecutionState,
            retrySafety: ActionRetrySafety, failureKind: ActionFailureKind? = nil
        ) async -> Bool {
            guard let permit else { return false }
            do {
                _ = try await nativeJournal.finishAction(
                    permit, state: state, retrySafety: retrySafety, failureKind: failureKind)
                return true
            } catch {
                note("warning: canonical action outcome was not confirmed: "
                    + error.localizedDescription)
                return false
            }
        }

        /// End is admitted before cleanup so even a failed launch has a durable terminal
        /// command when the journal is healthy; if the journal is wedged, the controller's
        /// degraded End permit still releases local resources.
        func endAndCleanup(
            runner: AgentRunner? = nil, host: RuntimeHost? = nil,
            outcome: RunTerminalOutcome, detail: String? = nil
        ) async {
            var terminalOutcome = outcome
            var terminalDetail = detail
            if let admittedStartCommandID {
                _ = await commandController.recordNotDelivered(
                    commandID: admittedStartCommandID,
                    reason: detail ?? "the CLI run ended before Start delivery")
            }
            let ending = await commandController.admitAndCommit(
                .endRun, actorID: "cli",
                causalCursor: await nativeJournal.latestWorkCursor)
            let endCommand: AdmittedSessionCommand?
            if case .accepted(let admittedEnd) = ending,
               await commandController.awaitDispatch(commandID: admittedEnd.commandID) != nil
            {
                _ = await commandController.acknowledgeDelivered(
                    commandID: admittedEnd.commandID)
                endCommand = admittedEnd
            } else {
                endCommand = nil
            }
            if let host {
                do {
                    try await host.closeCallbackAdmissionAndWait()
                } catch {
                    let callbackFailure =
                        "a runtime callback did not settle cleanly before teardown: "
                        + error.localizedDescription
                    note("warning: " + callbackFailure)
                    terminalOutcome = .indeterminate
                    terminalDetail = callbackFailure
                }
            }
            await runner?.stopMCPServers()
            if let host {
                let stopPermit = await beginNativeEffect(
                    kind: .runtime, intent: "Stop the Python runtime host")
                await host.stop()
                if stopPermit != nil {
                    _ = await finishNativeEffect(
                        stopPermit, state: .succeeded, retrySafety: .idempotent)
                }
            }
            if case .healthy = await nativeJournal.status.health {
                do {
                    _ = try await nativeJournal.finishRun(
                        outcome: terminalOutcome, detail: terminalDetail)
                } catch {
                    note("warning: native Run outcome was not confirmed: "
                        + error.localizedDescription)
                }
            }
            do {
                try await nativeJournal.closeChecked()
            } catch {
                note("warning: canonical journal close was not confirmed: "
                    + error.localizedDescription)
            }
            do {
                try await writer.closeChecked()
            } catch {
                note("warning: session journal close was not confirmed: \(error.localizedDescription)")
            }
            if let endCommand {
                _ = await commandController.acknowledgeEnd(commandID: endCommand.commandID)
            }
        }

        // Commit and dispatch the start intent before provider construction or RuntimeHost.start.
        let startCursor = await nativeJournal.latestWorkCursor
        let startReceipt = await commandController.admitAndCommitReceipt(
            .start(prompt: prompt), actorID: "cli",
            commandID: SessionCommandController.cliStartCommandID(for: identity),
            causalCursor: startCursor)
        guard case .accepted(let startCommand) = startReceipt.admission else {
            await endAndCleanup(outcome: .failed, detail: "Start was not durably admitted")
            await fail("The CLI start command could not be durably admitted.")
        }
        admittedStartCommandID = startCommand.commandID
        if startReceipt.isAcceptedButUndelivered {
            let detail = startReceipt.delivery.detail ?? "canonical delivery was not confirmed"
            await endAndCleanup(outcome: .indeterminate, detail: detail)
            await fail("The CLI start command was accepted but not delivered: \(detail)")
        }
        guard await commandController.awaitDispatch(commandID: startCommand.commandID) != nil else {
            await endAndCleanup(outcome: .failed, detail: "Start lost its dispatch turn")
            await fail("The CLI start command lost its dispatch turn.")
        }
        _ = await commandController.acknowledgeDispatched(commandID: startCommand.commandID)

        // The same factory the GUI uses. Two switch statements over the same api enum is how
        // the GUI ended up sending Codex traffic to the completions client and getting a 404.
        let providerPermit = await beginNativeEffect(
            kind: .provider, intent: "Resolve credentials and construct the chat provider",
            target: model.qualifiedID)
        guard providerPermit != nil else {
            await endAndCleanup(
                outcome: .indeterminate,
                detail: "canonical provider action permit was unavailable")
            await fail("The canonical Work journal refused provider construction.")
        }
        let routed = await ChatProviderRouting.makeProvider(
            spec: providerSpec, model: model, home: home,
            resolveSecret: { await resolvedSecret($0) })
        guard case .success(let provider) = routed else {
            _ = await finishNativeEffect(
                providerPermit, state: .failed, retrySafety: .unknown,
                failureKind: .infrastructure)
            if case .failure(let why) = routed {
                await endAndCleanup(outcome: .failed, detail: why.localizedDescription)
                await fail(why.localizedDescription)
            }
            return
        }
        if providerSpec.api != "openai-codex-responses" {
            let key = await ApiKeyResolver.resolve(providerSpec.apiKeyExpression)
            // Non-blocking: a provider may legitimately need no key, and refusing to start on
            // a format guess is how a working setup gets called broken.
            if !key.ok { note("credentials: \(key.explanation)") }
        }
        guard await finishNativeEffect(
            providerPermit, state: .succeeded, retrySafety: .unknown)
        else {
            await endAndCleanup(
                outcome: .indeterminate,
                detail: "provider construction outcome was not recorded")
            await fail("The canonical Work journal could not record provider construction.")
        }

        // 2. The runtime host.
        let hostScript = repoRoot.appending(path: "runtime-hosts/\(variant)/host.py")
        guard FileManager.default.fileExists(atPath: hostScript.path) else {
            await endAndCleanup(outcome: .failed, detail: "runtime host script is missing")
            await fail("No runtime host at \(hostScript.path)")
        }
        let host = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", hostScript.path])
        let runtimePermit = await beginNativeEffect(
            kind: .runtime, intent: "Start the Python runtime host", target: hostScript.path)
        guard runtimePermit != nil else {
            await endAndCleanup(
                host: host, outcome: .indeterminate,
                detail: "canonical runtime action permit was unavailable")
            await fail("The canonical Work journal refused runtime startup.")
        }
        let capabilities: RuntimeHost.Capabilities
        do {
            capabilities = try await host.start()
        } catch {
            _ = await finishNativeEffect(
                runtimePermit,
                state: error is CancellationError ? .canceled : .failed,
                retrySafety: .unknown,
                failureKind: error is CancellationError ? .cancellation : .infrastructure)
            await endAndCleanup(
                host: host, outcome: .failed,
                detail: "runtime host failed to start: \(error.localizedDescription)")
            await fail("Could not start the runtime host: \(error.localizedDescription)")
        }
        guard await finishNativeEffect(
            runtimePermit, state: .succeeded, retrySafety: .unsafe)
        else {
            await endAndCleanup(
                host: host, outcome: .indeterminate,
                detail: "runtime startup outcome was not recorded")
            await fail("The canonical Work journal could not record runtime startup.")
        }
        if !quiet {
            note("runtime \(capabilities.summary) · session isolation "
                + (capabilities.has("perSessionGIL") ? "on" : "off"))
        }

        // 3. A runner, which owns session creation, sub-agents and the callback wiring.
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

        let assembly: SystemPromptAssembly
        do {
            assembly = try SystemPromptAssembly.build(
                cwd: cwd, skills: gate.render(selection), memory: memoryGate.render(recalled))
        } catch {
            await endAndCleanup(
                host: host, outcome: .failed,
                detail: "Could not assemble the system prompt: \(error.localizedDescription)")
            await fail("Could not assemble the system prompt: \(error.localizedDescription)")
        }

        let runner = AgentRunner(
            provider: provider, host: host,
            settings: .init(
                home: home, cwd: cwd, model: model,
                systemPrompt: assembly.flattenedText,
                systemPromptAssembly: assembly,
                memory: memory, recordPayloads: record,
                goal: (tokenBudget != nil || minutes != nil)
                    ? Goal(text: prompt, tokenBudget: tokenBudget,
                           timeBudget: minutes.map { $0 * 60 })
                    : nil,
                hookPaths: HookDiscovery.paths(repoRoot: repoRoot),
                resume: resume, identity: identity, writer: writer,
                nativeJournal: nativeJournal, nativeResumeSeed: nativeResumeSeed,
                repositoryReviewer: ObservedRepositoryReviewer()))

        await runner.observe { event in
            switch event {
            case .textDelta(let t):
                FileHandle.standardOutput.write(Data(t.utf8))
            case .thinkingDelta:
                break  // shown in the GUI, noise in a terminal
            case .imageAttached(let path, let width, let height):
                note("\n👁 \(path) (\(width)×\(height))")
            case .awaitingDispatched(let count):
                note("\n— holding for \(count) dispatched task(s)")
            case .modelChanged(let provider, let id):
                note("\n— now answering with \(provider)/\(id)")
            case .toolStarted(_, _, let arguments):
                let code = arguments["code"]?.stringValue ?? ""
                note("\n▸ python\n" + code.split(separator: "\n").map { "  \($0)" }
                    .joined(separator: "\n"))
            case .toolFinished(_, _, let output, let isError):
                let head = output.split(separator: "\n").prefix(12).map { "  \($0)" }
                    .joined(separator: "\n")
                note((isError ? "✗ " : "◂ ") + "\n\(head)"
                    + (output.split(separator: "\n").count > 12 ? "\n  …" : ""))
            case .turnFinished(_, let usage, _):
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
            case .goalExhausted(let note):
                note2(note)
            case .steered(let text):
                note("\n↻ \(text.prefix(70))")
            case .started(let session):
                if !quiet { note("session \(session) · \(model.qualifiedID) · \(cwd)") }
            case .inputCommitted:
                break
            }
        }

        do {
            let (_, agent) = try await runner.prepare()
            guard await commandController.acknowledgePreparation(commandID: startCommand.commandID)
            else {
                await endAndCleanup(
                    runner: runner, host: host, outcome: .failed,
                    detail: "Start preparation was not acknowledged")
                await fail("The CLI start command was not acknowledged.")
            }
            let outcome = await agent.send(prompt) { delivery in
                switch delivery {
                case .delivered:
                    _ = await commandController.recordDelivered(
                        commandID: startCommand.commandID)
                case .notDelivered(let reason):
                    _ = await commandController.recordNotDelivered(
                        commandID: startCommand.commandID, reason: reason)
                case .notAttempted, .queued, .indeterminate:
                    break
                }
            }
            let runOutcome: RunTerminalOutcome
            let runDetail: String?
            switch outcome {
            case .completed:
                _ = await commandController.acknowledgeTurnFinished(
                    commandID: startCommand.commandID)
                runOutcome = .completed
                runDetail = nil
            case .failed(let detail):
                note("agent failed: \(detail)")
                _ = await commandController.markFailed(commandID: startCommand.commandID)
                runOutcome = .failed
                runDetail = detail
            case .cancelled:
                note("agent cancelled; ending run")
                runOutcome = .canceled
                runDetail = "agent canceled"
            }
            let total = await agent.totalUsage
            if !quiet {
                note("total \(Fmt.tokens(total.totalTokens)) tokens"
                    + (total.cacheHitRate.map { String(format: " · %.0f%% cached", $0 * 100) } ?? ""))
                note("transcript \(writer.fileURL.path)")
            }
            await endAndCleanup(
                runner: runner, host: host, outcome: runOutcome, detail: runDetail)
        } catch {
            note("could not start: \(error.localizedDescription)")
            await endAndCleanup(
                runner: runner, host: host, outcome: .failed,
                detail: error.localizedDescription)
        }
    }

    // MARK: Helpers

    /// `provider/model`, or a bare model id matched across providers, or the first configured.
    static func resolve(
        _ reference: String?, in config: ModelsConfig, auth: AuthInfo? = nil
    ) -> (ProviderSpec, ModelSpec)? {
        // Built-ins last, so a models.json entry always wins — someone who has configured a
        // provider explicitly meant it.
        let providers = config.providers + [BuiltInProviders.openAICodex(auth: auth)]
        guard let reference, !reference.isEmpty else {
            for provider in providers {
                if let first = provider.models.first { return (provider, first) }
            }
            return nil
        }
        if reference.contains("/") {
            // Split on the *first* slash only: model ids contain slashes too, as with
            // `baseten/deepseek-v4-pro` behind the gateway.
            let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
            if let provider = providers.first(where: { $0.id == parts[0] }),
               let model = provider.models.first(where: { $0.id == parts[1] })
            {
                return (provider, model)
            }
        }
        for provider in providers {
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

    static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    private static func note2(_ s: String) { note("\n— " + s) }

    private static func note(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    static func fail(_ s: String) -> Never {
        FileHandle.standardError.write(Data(("aviary: " + s + "\n").utf8))
        exit(2)
    }

    static func fail(_ s: String) async -> Never {
        FileHandle.standardError.write(Data(("aviary: " + s + "\n").utf8))
        await AviaryTelemetry.shutdown(maximumDuration: 2)
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
