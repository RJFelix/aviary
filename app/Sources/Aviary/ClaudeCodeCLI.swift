import Foundation
import AviaryCore

/// `Aviary --claude-code "<prompt>"` — one driven Claude Code session, in a terminal.
///
/// Exists for the same reason `--agent` does: a session type you cannot run without the GUI is
/// a session type you cannot debug. It is also the honest way to answer the question the
/// research doc ends on — whether a Claude-Code-driven loop over Aviary's kernel feels like
/// Aviary or like a worse Claude Code — before any UI is built on the answer.
enum ClaudeCodeCLI {

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--claude-code") else { return }
        let prompt = args.count > flag + 1 ? args[flag + 1] : ""
        guard !prompt.isEmpty, !prompt.hasPrefix("--") else {
            AgentCLI.fail("usage: Aviary --claude-code \"<prompt>\" [--model sonnet|opus|haiku] "
                + "[--cwd path] [--effort low|medium|high] [--quiet]")
        }
        let model = AgentCLI.value(of: "--model", in: args) ?? "sonnet"
        let cwd = AgentCLI.value(of: "--cwd", in: args) ?? FileManager.default.currentDirectoryPath
        let effort = AgentCLI.value(of: "--effort", in: args)
        let quiet = args.contains("--quiet")

        let done = Atomic(false)
        Task {
            await run(prompt: prompt, model: model, cwd: cwd, effort: effort, quiet: quiet)
            done.set(true)
        }
        while !done.get() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        exit(0)
    }

    private static func run(
        prompt: String, model: String, cwd: String, effort: String?, quiet: Bool
    ) async {
        _ = await ProcessEnvironment.shared.loadFromLoginShell()
        let home = AgentHome.default

        let bridge = KernelBridge()
        let prepared: ClaudeCodeSession.Prepared
        do {
            prepared = try await ClaudeCodeSession.prepare(
                home: home, cwd: cwd, model: model, effort: effort,
                bridgeExecutable: CommandLine.arguments[0], firstPrompt: prompt, bridge: bridge)
        } catch {
            AgentCLI.fail(error.localizedDescription)
        }
        let run = prepared.run
        if !quiet {
            note("claude \(prepared.auth.summary)")
            note("runtime \(prepared.runtimeSummary)")
            if let skills = prepared.skillsNote { note(skills) }
            if let memory = prepared.memoryNote { note(memory) }
        }
        for warning in prepared.warnings { note("! " + warning) }

        await run.observe { event in
            switch event {
            case .started(let session):
                if !quiet { note("session \(session) · claude-code/\(model) · \(cwd)") }
            case .claudeSession(let id):
                if !quiet { note("claude session \(id)") }
            case .textDelta(let text):
                FileHandle.standardOutput.write(Data(text.utf8))
            case .thinkingDelta:
                break  // shown in the GUI, noise in a terminal
            case .toolStarted(let name):
                note("\n▸ \(name)")
            case .toolFinished(_, let isError):
                note(isError ? "✗" : "◂")
            case .rateLimit(let limit):
                if !quiet { note("· \(limit.summary)") }
            case .warning(let text):
                note("! \(text)")
            case .failed(let detail):
                note("\n— failed: \(detail)")
            case .turnFinished, .finished:
                break
            }
        }

        do {
            try await run.start(prompt: prompt)
            // One prompt, so tell Claude Code that immediately. Without it the process waits
            // on stdin forever and a `--claude-code` invocation never returns.
            await run.finishInput()
        } catch {
            note("could not start: \(error.localizedDescription)")
            await prepared.host.stop()
            return
        }

        // Claude Code exits when stdin closes and its turn is done; the process's own
        // termination is what ends the run, so wait on that rather than on a turn boundary.
        while !(await run.isFinished) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let usage = await run.totalUsage
        if !quiet {
            note("\ntotal \(Fmt.tokens(usage.totalTokens)) tokens"
                + (usage.reasoning.map { " · \(Fmt.tokens($0)) reasoning" } ?? ""))
            let unmodelled = await run.unmodelledFrames
            if !unmodelled.isEmpty {
                note("unmodelled frames: " + unmodelled.sorted { $0.key < $1.key }
                    .map { "\($0.key)×\($0.value)" }.joined(separator: " "))
            }
            note("transcript \(run.fileURL.path)")
        }
        await run.stop()
        await prepared.host.stop()
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
