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
            await AviaryTelemetry.shutdown(maximumDuration: 2)
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
        let identity = RunConfiguration(
            cwd: cwd, provider: "claude-code", model: model, thinkingLevel: effort)
            .resolvedIdentity(home: home)
        let writer: SessionWriter
        do {
            writer = try SessionWriter(
                home: home, cwd: cwd, model: ClaudeCodeRun.modelSpec(for: model), identity: identity)
        } catch {
            await AgentCLI.fail("Could not open the session journal: \(error.localizedDescription)")
        }
        let commandController = SessionCommandController(
            identity: identity, writer: writer)
        let startAdmission = await commandController.admitAndCommit(
            .start(prompt: prompt), actorID: "cli", commandID: "cli-start")
        guard case .accepted(let startCommand) = startAdmission else {
            await finishFailedLaunch(commandController: commandController, writer: writer)
            await AgentCLI.fail("The Claude Code start command could not be durably admitted.")
        }
        guard await commandController.awaitDispatch(commandID: startCommand.commandID) != nil else {
            await finishFailedLaunch(commandController: commandController, writer: writer)
            await AgentCLI.fail("The Claude Code start command lost its dispatch turn.")
        }
        _ = await commandController.acknowledgeDispatched(commandID: startCommand.commandID)
        let prepared: ClaudeCodeSession.Prepared
        do {
            prepared = try await ClaudeCodeSession.prepare(
                home: home, cwd: cwd, model: model, effort: effort,
                bridgeExecutable: CommandLine.arguments[0], firstPrompt: prompt, bridge: bridge,
                identity: identity, writer: writer)
        } catch {
            await finishFailedLaunch(commandController: commandController, writer: writer)
            await AgentCLI.fail(error.localizedDescription)
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
            case .inputCommitted:
                break
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
            case .messageCommitted, .turnFinished, .finished:
                break
            }
        }

        var endCommand: AdmittedSessionCommand?
        do {
            guard await commandController.acknowledgePreparation(commandID: startCommand.commandID)
            else {
                throw NSError(
                    domain: "Aviary.ClaudeCodeCLI", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The start command was not acknowledged."])
            }
            try await run.start(prompt: prompt)
            // The initial user message has crossed Claude's stdin boundary at this point. Make
            // End the durable next owner before closing stdin, so the controller truthfully stays
            // in `.ending` while Claude finishes its final turn.
            let endAdmission = await commandController.admitAndCommit(.endRun, actorID: "cli")
            guard case .accepted(let admitted) = endAdmission,
                  let dispatch = await commandController.awaitDispatch(commandID: admitted.commandID)
            else {
                throw NSError(
                    domain: "Aviary.ClaudeCodeCLI", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The End command was not dispatchable."])
            }
            endCommand = dispatch
            _ = await commandController.acknowledgeDispatched(commandID: dispatch.commandID)
            // One prompt, so tell Claude Code that immediately. Without it the process waits
            // on stdin forever and a `--claude-code` invocation never returns.
            await run.finishInput()
        } catch {
            note("could not start: \(error.localizedDescription)")
            await finishFailedLaunch(
                commandController: commandController, writer: writer,
                run: run, host: prepared.host, cancelActiveTurn: true)
            return
        }

        // Claude Code exits when stdin closes and its turn is done; the process's own
        // termination is what ends the run, so wait on that rather than on a turn boundary.
        while !(await run.isFinished) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let usage = await run.totalUsage
        if !quiet {
            note("\ntotal \(Fmt.tokens(usage)) tokens"
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
        if let endCommand {
            _ = await commandController.acknowledgeEnd(commandID: endCommand.commandID)
        }
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func finishFailedLaunch(
        commandController: SessionCommandController, writer: SessionWriter,
        run: ClaudeCodeRun? = nil, host: RuntimeHost? = nil,
        cancelActiveTurn: Bool = false
    ) async {
        let ending = await commandController.admitAndCommit(.endRun, actorID: "cli")
        let endCommand: AdmittedSessionCommand?
        if case .accepted(let admitted) = ending {
            endCommand = await commandController.awaitDispatch(commandID: admitted.commandID)
        } else {
            endCommand = nil
        }
        if let endCommand {
            _ = await commandController.acknowledgeDispatched(commandID: endCommand.commandID)
        }
        await run?.stop(cancelActiveTurn: cancelActiveTurn)
        await host?.stop()
        try? await writer.closeChecked()
        if let endCommand {
            _ = await commandController.acknowledgeEnd(commandID: endCommand.commandID)
        }
    }
}
