import SwiftUI
import AviaryCore

/// Drives a Claude-Code-driven run for the Live view.
///
/// Deliberately the same shape as `InHouseDriver`, down to the property names, because the
/// transcript comes from the same place: the session file the run writes, re-parsed as it
/// grows. One parser, one renderer, and a driven run that reads identically to an in-house one
/// when it is opened again tomorrow. What differs is only what a driven run can be told — there
/// is no steering, because Claude Code owns the turn boundary and will not take an injection
/// mid-turn.
@Observable
@MainActor
final class ClaudeCodeDriver {
    var items: [TranscriptItem] = []
    var isStreaming = false
    var hasExited = false
    var usage = Usage()
    var sessionID: String?
    var sessionFile: URL?
    var errorBanner: String?
    var commandNotice: RunCommandNotice?
    var initialPromptDelivered = false
    var runtimeSummary: String?
    var skillsNote: String?
    var memoryNote: String?
    /// Claude Code's own session id. Shown because it is what `claude --resume` takes, and a
    /// person debugging a driven run will want to open it in Claude Code itself.
    var claudeSessionID: String?
    /// Which bucket the run is drawing on. The reason this session type exists, so it is
    /// stated rather than assumed.
    var rateLimit: ClaudeCode.Frame.RateLimit?
    var authSummary: String?
    /// Warnings that are true for the whole run: a leaked API key, a missing tool, a denial.
    var warnings: [String] = []

    private let home: AgentHome
    private let cwd: String
    private let model: String
    private let effort: String?
    private let noContextFiles: Bool
    private var host: RuntimeHost?
    private var run: ClaudeCodeRun?
    private var bridge: KernelBridge?
    private var watcher: SessionWatcher?
    private var task: Task<Void, Never>?
    private var eventPump: Task<Void, Never>?
    private let liveOverlay = LiveTranscriptOverlay()
    private var liveTurnID: LiveTranscriptTurnID?
    private var liveMessageID: LiveTranscriptMessageID?
    private var liveRevision: UInt64 = 0
    private var reloadGeneration: UInt64 = 0
    private var liveTurnFailed = false
    private var pendingOverlayCommits: [LiveTranscriptIdentity: String] = [:]
    private(set) var acceptsFollowUps = false
    let identity: SessionWorkIdentity
    /// Claude Code owns the turn boundary. Steering, queued follow-ups, and cancellation are
    /// therefore deliberately false until a driver with those semantics exists.
    let commandCapabilities: SessionCommandCapabilities
    private let commandController: SessionCommandController
    private let actorID: String
    private var activeTurnCommandID: String?
    private var terminationRequested = false
    /// Guards the natural-exit and explicit-stop paths from tearing the same resources down
    /// twice when the process termination callback races a user End command.
    private var teardownStarted = false
    private var endedTransitioned = false
    /// The exact journal reserved before bridge/runtime/process effects.
    private let suppliedWriter: SessionWriter?

    func commandState() async -> SessionCommandState {
        await commandController.state
    }

    init(
        home: AgentHome, cwd: String, model: String, effort: String? = nil,
        identity: SessionWorkIdentity? = nil, actorID: String = "gui",
        commandController: SessionCommandController? = nil,
        noContextFiles: Bool = false,
        writer: SessionWriter? = nil
    ) {
        self.home = home
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.noContextFiles = noContextFiles
        self.suppliedWriter = writer
        self.identity = identity
            ?? SessionWorkIdentity.allocate(workHostID: home.workHostID)
        self.commandCapabilities = commandController?.capabilities ?? SessionCommandCapabilities()
        self.commandController = commandController ?? SessionCommandController(
            identity: self.identity, capabilities: self.commandCapabilities)
        self.actorID = actorID
    }

    func start(prompt: String) {
        task = Task { await launch(prompt: prompt) }
    }

    private func launch(prompt: String) async {
        let start = await commandController.admitAndCommit(
            .start(prompt: prompt), actorID: actorID)
        guard case .accepted(let admittedStart) = start else {
            reject(start, operation: "start")
            await finishFailedLaunch()
            await closeSuppliedWriter()
            return
        }
        commandNotice = nil
        guard await commandController.awaitDispatch(commandID: admittedStart.commandID) != nil
        else {
            fail("The start command lost its dispatch turn.")
            await finishFailedLaunch()
            await closeSuppliedWriter()
            return
        }
        _ = await commandController.acknowledgeDispatched(
            commandID: admittedStart.commandID)
        // The path to this very binary, which Claude Code re-launches as the MCP courier.
        // `Bundle.main.executablePath` rather than `CommandLine.arguments[0]`: inside an app
        // bundle the latter can be relative, and Claude Code resolves an MCP server command in
        // its own working directory, not ours.
        guard let selfPath = Bundle.main.executablePath ?? CommandLine.arguments.first else {
            fail("Could not determine Aviary's own path, which the MCP bridge needs.")
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch()
            await closeSuppliedWriter()
            return
        }

        let bridge = KernelBridge()
        self.bridge = bridge
        let prepared: ClaudeCodeSession.Prepared
        do {
            // The same assembly `--claude-code` uses, deliberately: two copies of this is how a
            // windowed run and a terminal run quietly stop being the same thing.
            prepared = try await ClaudeCodeSession.prepare(
                home: home, cwd: cwd, model: model, effort: effort,
                bridgeExecutable: selfPath, firstPrompt: prompt, bridge: bridge,
                identity: identity, noContextFiles: noContextFiles, writer: suppliedWriter)
        } catch {
            if terminationRequested {
                await finishFailedLaunch()
                await closeSuppliedWriter()
                return
            }
            fail(error.localizedDescription)
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch()
            await closeSuppliedWriter()
            return
        }

        if terminationRequested {
            await finishFailedLaunch(run: prepared.run, host: prepared.host)
            return
        }

        host = prepared.host
        run = prepared.run
        authSummary = prepared.auth.summary
        runtimeSummary = prepared.runtimeSummary
        skillsNote = prepared.skillsNote
        memoryNote = prepared.memoryNote
        warnings.append(contentsOf: prepared.warnings)

        let (events, eventContinuation) = AsyncStream<ClaudeCodeRun.Event>.makeStream(
            bufferingPolicy: .unbounded)
        eventPump = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(event)
            }
        }
        await prepared.run.observe { event in eventContinuation.yield(event) }

        guard await commandController.acknowledgePreparation(
            commandID: admittedStart.commandID)
        else {
            if terminationRequested {
                await finishFailedLaunch(run: prepared.run, host: prepared.host)
                return
            }
            fail("The start command was not acknowledged.")
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch(run: prepared.run, host: prepared.host)
            return
        }
        if !prompt.isEmpty {
            isStreaming = true
            beginLiveTurn()
            activeTurnCommandID = admittedStart.commandID
        }
        do {
            try await prepared.run.start(prompt: prompt)
            acceptsFollowUps = true
            if prompt.isEmpty {
                _ = await commandController.acknowledgeTurnFinished(
                    commandID: admittedStart.commandID)
            }
        } catch {
            if terminationRequested {
                await finishFailedLaunch(run: prepared.run, host: prepared.host)
                return
            }
            fail(error.localizedDescription)
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            // A non-delivered initial prompt may have crossed stdin indeterminately. The run
            // actor deliberately does not call that a known failure; if teardown is now
            // required, classify it as an interrupted active turn instead.
            await finishFailedLaunch(
                run: prepared.run, host: prepared.host,
                cancelActiveTurn: activeTurnCommandID != nil || isStreaming)
        }
    }

    private func ingest(_ event: ClaudeCodeRun.Event) async {
        switch event {
        case .started(let session):
            sessionID = session
            sessionFile = home.sessionFile(id: session)
            follow()
        case .claudeSession(let id):
            claudeSessionID = id
        case .inputCommitted:
            initialPromptDelivered = true
        case .textDelta(let text):
            appendLive(.text(text))
        case .thinkingDelta(let text):
            appendLive(.thinking(text))
        case .toolStarted:
            reload()
        case .toolFinished:
            reload()
        case .messageCommitted(let messageID):
            completeLiveMessage(durableID: messageID)
            reload()
        case .turnFinished:
            if let commandID = activeTurnCommandID {
                await acknowledgeTurn(commandID)
            } else {
                isStreaming = false
            }
            reload()
        case .rateLimit(let limit):
            rateLimit = limit
        case .warning(let text):
            if !warnings.contains(text) { warnings.append(text) }
            reload()
        case .failed(let detail):
            errorBanner = detail
            isStreaming = false
            liveTurnFailed = true
            markLiveTerminal(.failed)
            if let commandID = activeTurnCommandID {
                _ = await commandController.markFailed(commandID: commandID)
            } else {
                _ = await commandController.markFailed()
            }
            reload()
        case .finished:
            isStreaming = false
            if let commandID = activeTurnCommandID, errorBanner == nil {
                errorBanner = "Claude Code exited before acknowledging the active turn."
                _ = await commandController.markFailed(commandID: commandID)
            }
            await finishNaturalExit()
        }
    }

    /// Another prompt in the same session — same Claude Code history, same interpreter.
    ///
    /// Claude Code takes this as a new user turn on the history it already holds, which is the
    /// one thing its stream-json input *does* accept.
    func send(_ prompt: String, sourceID: String? = nil) async -> SessionCommandReceipt {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let admission = await commandController.admitAndCommit(
            .send(prompt: prompt), actorID: sourceID ?? actorID)
        guard case .accepted(let admitted) = admission else {
            reject(admission, operation: "send")
            return SessionCommandReceipt(admission: admission)
        }
        commandNotice = nil
        guard await commandController.awaitDispatch(commandID: admitted.commandID) != nil else {
            errorBanner = "The send command lost its dispatch turn."
            return SessionCommandReceipt(
                admission: admission,
                delivery: .indeterminate(reason: "dispatch ownership was unavailable"))
        }
        guard let run else {
            commandNotice = .warning("Could not send: the run is still starting.")
            _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
            _ = await commandController.markFailed(commandID: admitted.commandID)
            return SessionCommandReceipt(
                admission: admission,
                delivery: .notDelivered(reason: "the run is still starting"))
        }
        commandNotice = nil
        beginLiveTurn()
        isStreaming = true
        activeTurnCommandID = admitted.commandID
        let delivery = await run.send(prompt)
        _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
        if delivery.isDelivered {
            return SessionCommandReceipt(admission: admission, delivery: delivery)
        }
        errorBanner = delivery.detail ?? "Claude Code input delivery was not confirmed."
        if case .indeterminate = delivery {
            markLiveTerminal(.cancelled)
        } else {
            markLiveTerminal(.failed)
        }
        _ = await commandController.markFailed(commandID: admitted.commandID)
        // The send was admitted and the driver is tearing down an active turn. Preserve an
        // indeterminate stdin crossing as indeterminate; the explicit cancellation marker
        // describes the subsequent run teardown, not a known delivery failure.
        await finishFailedLaunch(run: run, host: host, cancelActiveTurn: true)
        return SessionCommandReceipt(admission: admission, delivery: delivery)
    }

    /// Claude Code has no protocol boundary for either model-stream or current-action
    /// cancellation. Keep a common entry point for future clients, but let the controller
    /// reject every scope rather than presenting teardown as scoped cancellation.
    func cancel(
        scope: SessionCancellationScope, sourceID: String? = nil
    ) async -> SessionCommandReceipt {
        let admission = await commandController.admitAndCommit(
            .cancel(scope: scope), actorID: sourceID ?? actorID)
        guard case .accepted(let admitted) = admission else {
            reject(admission, operation: "cancel")
            return SessionCommandReceipt(admission: admission)
        }
        // Defensive only: this driver currently declares no cancellation capability. If a
        // future caller injects a mismatched controller, do not claim an effect here.
        let reason = "Claude Code does not support scoped cancellation"
        commandNotice = .warning(reason + ".")
        if await commandController.awaitDispatch(
            commandID: admitted.commandID
        ) != nil {
            _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
        }
        _ = await commandController.markFailed(commandID: admitted.commandID)
        return SessionCommandReceipt(
            admission: admission, delivery: .notDelivered(reason: reason))
    }

    func stop() async {
        guard !endedTransitioned, !teardownStarted else { return }
        let admission = await commandController.admitAndCommit(.endRun, actorID: actorID)
        guard case .accepted(let admitted) = admission else {
            reject(admission, operation: "end run")
            return
        }
        terminationRequested = true
        teardownStarted = true
        guard await commandController.awaitDispatch(commandID: admitted.commandID) != nil
        else { return }
        _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
        let launchTask = task
        let cancelActiveTurn = activeTurnCommandID != nil || isStreaming
        launchTask?.cancel()
        eventPump?.cancel()
        watcher?.stop()
        markLiveTerminal(.cancelled)
        // `launch` owns setup until it publishes `self.run` and `self.host`. Snapshotting those
        // references before it finishes can observe nil, acknowledge End, and let a late
        // RuntimeHost child outlive Quit or Reload. No launch path calls this method, so this
        // join cannot self-await; stop is exclusively a controller/UI operation.
        await launchTask?.value
        let run = self.run
        let host = self.host
        await run?.stop(cancelActiveTurn: cancelActiveTurn)
        await host?.stop()
        if await commandController.acknowledgeEnd(commandID: admitted.commandID) {
            endedTransitioned = true
        }
        isStreaming = false
        hasExited = endedTransitioned
    }

    private func fail(_ detail: String) {
        errorBanner = detail
        isStreaming = false
    }

    /// A supplied writer is reserved by the GUI before this driver starts. If setup fails
    /// before a `ClaudeCodeRun` can adopt it, the driver still owns the close boundary.
    private func closeSuppliedWriter() async {
        guard run == nil else { return }
        do {
            try await suppliedWriter?.closeChecked()
        } catch {
            errorBanner = "The session journal close was not confirmed: \(error.localizedDescription)"
        }
    }

    /// Setup failures still cross the command lifecycle's End boundary. The receipt may be
    /// degraded when the journal is already unhealthy, but the local terminal projection must
    /// never depend on a successful earlier preparation step.
    private func finishFailedLaunch(
        run: ClaudeCodeRun? = nil, host: RuntimeHost? = nil,
        cancelActiveTurn: Bool = false
    ) async {
        guard !endedTransitioned, !teardownStarted else { return }
        terminationRequested = true
        teardownStarted = true
        let ending = await commandController.admitAndCommit(.endRun, actorID: actorID)
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
        if run == nil { await closeSuppliedWriter() }
        if let endCommand {
            _ = await commandController.acknowledgeEnd(commandID: endCommand.commandID)
            endedTransitioned = true
        }
        hasExited = true
        isStreaming = false
    }

    /// Natural Claude process termination is an observed process outcome, not a user command.
    /// Reclaim the process/bridge and Python host first, then mark the controller failed and
    /// expose the row as exited. In particular, do not fabricate a GUI End intent after the
    /// process has already gone away; End remains an explicit durable user action.
    private func finishNaturalExit() async {
        guard !endedTransitioned, !teardownStarted else { return }
        teardownStarted = true
        terminationRequested = true
        watcher?.stop()
        let finishedRun = run
        let finishedHost = host
        await finishedRun?.stop()
        await finishedHost?.stop()
        run = nil
        host = nil
        _ = await commandController.markFailed()
        hasExited = true
        isStreaming = false
        reload()
    }

    private func acknowledgeTurn(_ commandID: String) async {
        if await commandController.acknowledgeTurnFinished(commandID: commandID) {
            activeTurnCommandID = nil
            isStreaming = false
        }
    }

    private func reject(_ admission: SessionCommandAdmission, operation: String) {
        guard case .rejected(_, let reason) = admission else { return }
        commandNotice = .warning(
            "Could not " + operation + ": " + String(describing: reason) + ".")
    }

    private func follow() {
        guard let sessionFile else { return }
        watcher?.stop()
        let w = SessionWatcher(url: sessionFile)
        w.start { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher = w
        reload()
    }

    private func reload() {
        guard let sessionFile else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        Task { [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) {
                SessionParser.parse(fileURL: sessionFile)
            }.value
            await MainActor.run {
                guard let self, self.reloadGeneration == generation, let parsed else { return }
                _ = self.liveOverlay.reconcile(committed: parsed.items)
                if parsed.outcome != nil,
                   let turnID = self.liveTurnID, let messageID = self.liveMessageID
                {
                    // Failure/cancellation is durable as `aviary.outcome`, not as a model row.
                    // Remove the terminal overlay only after that marker is cold-readable.
                    _ = self.liveOverlay.remove(identity: LiveTranscriptIdentity(
                        turnID: turnID, messageID: messageID))
                    self.liveTurnID = nil
                    self.liveMessageID = nil
                    self.liveRevision = 0
                    self.liveTurnFailed = false
                }
                var reconciled: [LiveTranscriptIdentity] = []
                for (identity, durableID) in self.pendingOverlayCommits {
                    guard let item = parsed.items.first(where: { $0.id == durableID }) else {
                        continue
                    }
                    _ = self.liveOverlay.commit(identity: identity, committedItem: item)
                    reconciled.append(identity)
                }
                for identity in reconciled {
                    self.pendingOverlayCommits.removeValue(forKey: identity)
                }
                self.items = self.liveOverlay.snapshot.items
                if parsed.usage.totalTokens > 0 { self.usage = parsed.usage }
            }
        }
    }

    private func beginLiveTurn() {
        liveTurnID = LiveTranscriptTurnID(UUID().uuidString)
        liveMessageID = LiveTranscriptMessageID(UUID().uuidString)
        liveRevision = 0
        liveTurnFailed = false
    }

    private func appendLive(_ content: LiveTranscriptContentDelta) {
        if liveTurnID == nil { beginLiveTurn() }
        guard let turnID = liveTurnID, let messageID = liveMessageID else { return }
        liveRevision &+= 1
        _ = liveOverlay.apply(
            turnID: turnID.rawValue, messageID: messageID.rawValue,
            content: content, lifecycle: .streaming, revision: liveRevision)
        publishLiveOverlay()
    }

    private func completeLiveMessage(durableID: String) {
        guard let turnID = liveTurnID, let messageID = liveMessageID else { return }
        let identity = LiveTranscriptIdentity(turnID: turnID, messageID: messageID)
        liveRevision &+= 1
        _ = liveOverlay.apply(
            turnID: turnID.rawValue, messageID: messageID.rawValue,
            lifecycle: .completed, revision: liveRevision)
        pendingOverlayCommits[identity] = durableID
        liveTurnID = nil
        liveMessageID = nil
        liveRevision = 0
        liveTurnFailed = false
        publishLiveOverlay()
    }

    private func markLiveTerminal(_ lifecycle: LiveTranscriptLifecycle) {
        guard let turnID = liveTurnID, let messageID = liveMessageID else { return }
        liveRevision &+= 1
        _ = liveOverlay.apply(
            turnID: turnID.rawValue, messageID: messageID.rawValue,
            lifecycle: lifecycle, revision: liveRevision)
        publishLiveOverlay()
    }

    private func publishLiveOverlay() {
        items = liveOverlay.snapshot.items
    }
}
