import Foundation

/// Everything a driven session needs, assembled once.
///
/// Exists because there are two callers — the GUI driver and `--claude-code` — and they were
/// assembling this independently. That is the arrangement where a terminal run and a windowed
/// run quietly stop being the same thing: while building, the CLI is the only one that gets
/// exercised, so a divergence lands in the GUI and is discovered by a person using it. One
/// function means the CLI genuinely tests what the GUI does.
public enum ClaudeCodeSession {

    /// What was assembled, and what is worth saying about it.
    public struct Prepared: Sendable {
        public var run: ClaudeCodeRun
        public var kernel: ClaudeCodeKernel
        public var host: RuntimeHost
        public var auth: ClaudeCode.Auth
        /// A line about how many skills were described, or nil when there are none to gate.
        public var skillsNote: String?
        public var memoryNote: String?
        public var runtimeSummary: String
        /// Things true before the first token — a login that bills metered credit, say.
        public var warnings: [String]
    }

    public enum SetupError: LocalizedError {
        case noCheckout
        case noBinary
        case notSignedIn
        case runtimeFailed(String)
        case sessionFileFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noCheckout:
                return "No Aviary checkout was found, so there is no runtime host to be the tool."
            case .noBinary:
                return "No `claude` binary was found. Install Claude Code, then try again."
            case .notSignedIn:
                return "Claude Code is not signed in. Run `claude /login` in a terminal."
            case .runtimeFailed(let detail):
                return "Could not start the runtime host: \(detail)"
            case .sessionFileFailed(let detail):
                return "Could not open a session file: \(detail)"
            }
        }
    }

    /// Build a driven session, ready to be started.
    ///
    /// The order matters in one place: the kernel needs the run's session file and the run
    /// needs the bridge, so the run is constructed before the kernel that serves it. Nothing is
    /// sent — the caller starts it, because a GUI wants to attach an observer first.
    public static func prepare(
        home: AgentHome, cwd: String, model: String, effort: String?,
        bridgeExecutable: String, firstPrompt: String, bridge: KernelBridge
    ) async throws -> Prepared {
        guard let repoRoot = EngineLocator.repoRoot() else { throw SetupError.noCheckout }
        guard let auth = await ClaudeCode.authStatus() else { throw SetupError.noBinary }
        guard auth.loggedIn else { throw SetupError.notSignedIn }

        var warnings: [String] = []
        if !auth.isSubscription {
            // Worth saying before the run rather than after: an API-key login works perfectly
            // and removes the only reason to drive Claude Code instead of calling the model.
            warnings.append("This login is not a subscription one, so this run bills metered "
                + "API credit rather than the plan.")
        }

        // The kernel — the same host script and the same session semantics as an in-house run,
        // because it is the same kernel.
        let script = repoRoot.appending(path: "runtime-hosts/python3/host.py")
        let host = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", script.path])
        let runtimeSummary: String
        let hostSession: String
        do {
            runtimeSummary = try await host.start().summary
            hostSession = try await host.createSession(cwd: cwd)
        } catch {
            throw SetupError.runtimeFailed(error.localizedDescription)
        }

        // Skills and memory, gated exactly as an in-house run gates them. This is the part that
        // decides whether a driven session is recognisably an Aviary session: the loop is
        // Claude Code's, but what the model knows about this machine is Aviary's.
        let settings = HarnessSettings.load(home: home)
        let library = Library.discover(
            home: home, settings: settings,
            projectRoot: URL(fileURLWithPath: cwd), enginePackageRoot: nil)
        let gate = SkillGate()
        let selection = gate.select(skills: library.skills, prompt: firstPrompt, cwd: cwd)
        let skillsNote = library.skills.isEmpty ? nil
            : "\(selection.included.count) of \(library.skills.count) skills described"
                + " · \(Fmt.bytes(selection.savedCharacters)) saved"

        let memory = MemoryStore(repoRoot: repoRoot, home: home, cwd: cwd)
        let memoryGate = MemoryGate()
        let recalled = memoryGate.select(memory.load(sessionID: nil), prompt: firstPrompt)
        let memoryNote = recalled.totalAvailable == 0 ? nil
            : "\(recalled.included.count) memories recalled"

        let run: ClaudeCodeRun
        do {
            run = try ClaudeCodeRun(
                settings: .init(
                    home: home, cwd: cwd, model: model,
                    systemPrompt: ClaudeCodePrompt.build(
                        cwd: cwd, skills: gate.render(selection),
                        memory: memoryGate.render(recalled)),
                    effort: effort, bridgeExecutable: bridgeExecutable),
                bridge: bridge)
        } catch {
            throw SetupError.sessionFileFailed(error.localizedDescription)
        }

        let kernel = ClaudeCodeKernel(
            host: host, hostSession: hostSession, memory: memory,
            sessionFile: run.fileURL, sessionID: run.sessionID)
        await kernel.setCwdHint(cwd)
        await kernel.noteFirstPrompt(firstPrompt)
        await bridge.offer([await kernel.tool()])
        // `remember`, `recall` and `conversation` come from inside the interpreter, so they
        // arrive as host callbacks rather than as tool calls.
        await host.onCallback { session, kind, payload in
            guard session == hostSession else {
                return .object(["error": .string("Unknown kernel session.")])
            }
            return await kernel.serveCallback(kind: kind, payload: payload)
        }

        return Prepared(
            run: run, kernel: kernel, host: host, auth: auth,
            skillsNote: skillsNote, memoryNote: memoryNote,
            runtimeSummary: runtimeSummary, warnings: warnings)
    }
}
