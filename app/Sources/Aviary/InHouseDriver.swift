import AviaryCore
import SwiftUI

/// Drives an in-house run for the Live view.
///
/// The transcript comes from tailing the session file the run writes, not from a second
/// rendering path. That is the whole reason `SessionWriter` reuses the harness's format: one
/// parser, one renderer, and a live run that looks identical to the same run read back
/// tomorrow. The only thing layered on top is the text of the turn currently streaming, which
/// is not on disk yet because an entry is written when a turn completes.
@Observable
@MainActor
final class InHouseDriver {
    /// Everything the run has written, re-parsed as it grows.
    var items: [TranscriptItem] = []
    var isStreaming = false
    var hasExited = false
    var usage = Usage()
    var sessionID: String?
    var sessionFile: URL?
    var errorBanner: String?
    var commandNotice: RunCommandNotice?
    /// True only after the writer has acknowledged the prompt admitted by the start command.
    /// This is narrower than “the run was prepared”: startup proof needs to distinguish an
    /// accepted command from a message that actually crossed the durable seam.
    private(set) var initialPromptDelivered = false
    var runtimeSummary: String?
    var skillsNote: String?
    var memoryNote: String?
    /// Kept here rather than only on `LiveRun`, because after a switch the driver is the one
    /// that knows what actually took effect.
    var modelLabel: String?

    private let home: AgentHome
    private let cwd: String
    private var model: ModelSpec
    private var providerSpec: ProviderSpec
    private var host: RuntimeHost?
    private var runner: AgentRunner?
    private var writer: SessionWriter?
    private var watcher: SessionWatcher?
    private var task: Task<Void, Never>?
    private var eventPump: Task<Void, Never>?
    /// Kept so the run can take another prompt. The loop is per-prompt; the conversation,
    /// the runtime session and its Python state all persist across them — which is the whole
    /// reason a session is worth more than a request.
    private var agent: Agent?
    private(set) var acceptsFollowUps = false
    /// Schedules for this session, and the timer that fires them.
    private(set) var jobs: [ScheduledJob] = []
    private var scheduler: Task<Void, Never>?
    /// Ephemeral provider output. The file parser remains authoritative once a turn is written.
    private let liveOverlay = LiveTranscriptOverlay()
    private var liveTurnID: LiveTranscriptTurnID?
    private var liveMessageID: LiveTranscriptMessageID?
    private var liveRevision: UInt64 = 0
    private var reloadGeneration: UInt64 = 0
    /// Live identities use a controller-local id while the journal uses an entry id allocated
    /// by SessionWriter. Keep the explicit writer-confirmed mapping until the parser sees it.
    private var pendingOverlayCommits: [LiveTranscriptIdentity: String] = [:]

    /// Whether to record request payloads, so the run's "what was sent" breakdown works.
    private let recordPayloads: Bool
    private let reasoningEffort: String?
    private let noContextFiles: Bool
    /// An existing session to continue, or nil for a new one.
    private let resume: String?
    /// Who else is running. Supplied by the app, because only it knows.
    private let peerDelegate: Agent.PeerDelegate?
    let identity: SessionWorkIdentity
    let commandCapabilities: SessionCommandCapabilities
    private let commandController: SessionCommandController
    private let actorID: String
    private var activeTurnCommandID: String?
    private var initialPromptCommandID: String?
    /// A user-requested end can arrive while provider/runtime preparation is suspended. Every
    /// post-await boundary checks this before publishing newly-created live resources.
    private var terminationRequested = false
    /// Opened by the launch boundary before provider/runtime effects. Tests and legacy callers
    /// may omit it; `run` then opens the one exact writer before resolving the provider.
    private let suppliedWriter: SessionWriter?

    func commandState() async -> SessionCommandState {
        await commandController.state
    }

    init(
        home: AgentHome, cwd: String, model: ModelSpec, providerSpec: ProviderSpec,
        recordPayloads: Bool = false, resume: String? = nil,
        peerDelegate: Agent.PeerDelegate? = nil,
        identity: SessionWorkIdentity? = nil,
        actorID: String = "gui",
        commandController: SessionCommandController? = nil,
        reasoningEffort: String? = nil,
        noContextFiles: Bool = false,
        writer: SessionWriter? = nil
    ) {
        self.peerDelegate = peerDelegate
        self.recordPayloads = recordPayloads
        self.reasoningEffort = reasoningEffort
        self.noContextFiles = noContextFiles
        self.suppliedWriter = writer
        self.resume = resume
        self.home = home
        self.cwd = cwd
        self.model = model
        self.providerSpec = providerSpec
        self.identity =
            identity
            ?? SessionWorkIdentity.allocate(
                workHostID: home.workHostID, sessionID: resume)
        self.commandCapabilities =
            commandController?.capabilities
            ?? Agent.inHouseCommandCapabilities
        self.commandController =
            commandController
            ?? SessionCommandController(
                identity: self.identity, capabilities: self.commandCapabilities)
        self.actorID = actorID
    }

    func start(prompt: String) {
        task = Task { await run(prompt: prompt) }
    }

    private func run(prompt: String) async {
        do {
            // Reserve the durable antecedent before provider resolution, runtime startup, or
            // any later MCP/child effect. The controller is injected with this exact writer by
            // the app launch boundary; the fallback keeps old test callers source-compatible.
            if let suppliedWriter {
                self.writer = suppliedWriter
            } else if let resume {
                self.writer = try SessionWriter(
                    home: home, resuming: resume, cwd: cwd, model: model, identity: identity)
            } else {
                self.writer = try SessionWriter(
                    home: home, cwd: cwd, model: model, identity: identity)
            }
        } catch {
            errorBanner = "Could not open the session journal: \(error.localizedDescription)"
            hasExited = true
            return
        }
        let start = await commandController.admitAndCommit(
            .start(prompt: prompt), actorID: actorID)
        guard case .accepted(let admittedStart) = start else {
            reject(start, operation: "start")
            await finishFailedLaunch()
            return
        }
        initialPromptDelivered = false
        initialPromptCommandID = prompt.isEmpty ? nil : admittedStart.commandID
        commandNotice = nil
        guard await commandController.awaitDispatch(commandID: admittedStart.commandID) != nil
        else {
            errorBanner = "The start command lost its dispatch turn."
            hasExited = true
            await finishFailedLaunch()
            return
        }
        _ = await commandController.acknowledgeDispatched(
            commandID: admittedStart.commandID)
        guard let repoRoot = EngineLocator.repoRoot() else {
            errorBanner = "No Aviary checkout, so there is no runtime host."
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch()
            return
        }
        // The same factory `--agent` uses. Two switch statements over the same api enum is
        // what let the GUI send Codex traffic to the completions client and 404.
        let routed = await ChatProviderRouting.makeProvider(
            spec: providerSpec, model: model, home: home)
        guard !terminationRequested else {
            await finishFailedLaunch()
            return
        }
        guard case .success(let provider) = routed else {
            if case .failure(let why) = routed { errorBanner = why.localizedDescription }
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch()
            return
        }

        // Started after the provider is settled, so a run that cannot reach a model does not
        // boot a Python interpreter first and leave it to be torn down again.
        let script = repoRoot.appending(path: "runtime-hosts/python3/host.py")
        let host = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", script.path])
        self.host = host
        do {
            runtimeSummary = try await host.start().summary
            if terminationRequested {
                await host.stop()
                await finishFailedLaunch()
                return
            }
        } catch {
            // `RuntimeHost.start` may fail after launching its child but before the ready
            // handshake. The driver still owns that partially started process.
            await host.stop()
            if terminationRequested {
                await finishFailedLaunch()
                return
            }
            errorBanner = "Could not start the runtime host: \(error.localizedDescription)"
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch()
            return
        }

        // Skills, gated. Reported so the saving is visible rather than assumed.
        let settings = HarnessSettings.load(home: home)
        let library = Library.discover(
            home: home, settings: settings,
            projectRoot: URL(fileURLWithPath: cwd), enginePackageRoot: nil)
        let gate = SkillGate()
        let selection = gate.select(skills: library.skills, prompt: prompt, cwd: cwd)
        if !library.skills.isEmpty {
            skillsNote =
                "\(selection.included.count) of \(library.skills.count) skills described"
                + " · \(Fmt.bytes(selection.savedCharacters)) saved"
        }

        let memory = MemoryStore(repoRoot: repoRoot, home: home, cwd: cwd)
        let memoryGate = MemoryGate()
        let recalled = memoryGate.select(memory.load(sessionID: nil), prompt: prompt)
        if recalled.totalAvailable > 0 {
            memoryNote =
                "\(recalled.included.count) memories recalled"
                + (recalled.listed.isEmpty ? "" : ", \(recalled.listed.count) listed")
        }

        guard let writer = self.writer else {
            errorBanner = "The session journal was not opened."
            await host.stop()
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch()
            return
        }

        let runner = AgentRunner(
            provider: provider, host: host,
            settings: .init(
                home: home, cwd: cwd, model: model,
                systemPrompt: SystemPrompt.build(
                    cwd: cwd, model: model, skills: gate.render(selection),
                    memory: memoryGate.render(recalled),
                    includeContextFiles: !noContextFiles),
                memory: memory, recordPayloads: recordPayloads,
                hookPaths: HookDiscovery.paths(repoRoot: repoRoot), resume: resume,
                peerDelegate: peerDelegate,
                selfDelegate: peerDelegate as? Agent.SelfDelegate,
                identity: identity, reasoningEffort: reasoningEffort, writer: writer))
        self.runner = runner

        let (events, eventContinuation) = AsyncStream<Agent.Event>.makeStream(
            bufferingPolicy: .unbounded)
        eventPump = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(event)
        }
        }
        await runner.observe { event in eventContinuation.yield(event) }

        do {
            // Prepare first, then publish the live agent before sending the first prompt.
            // `runner.run(prompt:)` does not return until the whole first turn finishes; using
            // it here made first-turn steering, peer messages, and self notifications hit a
            // nil agent and disappear.
            let (writer, agent) = try await runner.prepare()
            if terminationRequested {
                await finishFailedLaunch()
                return
            }
            self.writer = writer
            self.agent = agent
            sessionID = writer.sessionID
            sessionFile = writer.fileURL
            follow()
            acceptsFollowUps = true
            guard
                await commandController.acknowledgePreparation(
                    commandID: admittedStart.commandID)
            else {
                if terminationRequested {
                    await finishFailedLaunch()
                    return
                }
                errorBanner = "The start command was not acknowledged."
                _ = await commandController.markFailed(commandID: admittedStart.commandID)
                await finishFailedLaunch()
                return
            }
            jobs = ScheduleStore(home: home, sessionID: writer.sessionID).load()
            if !jobs.isEmpty { startScheduler() }
            if !prompt.isEmpty {
                isStreaming = true
                beginLiveTurn()
                activeTurnCommandID = admittedStart.commandID
                guard !terminationRequested, !Task.isCancelled else {
                    await agent.cancel()
                    return
                }
                let outcome = await agent.send(prompt)
                await settle(outcome, commandID: admittedStart.commandID)
                activeTurnCommandID = nil
            } else {
                _ = await commandController.acknowledgeTurnFinished(
                    commandID: admittedStart.commandID)
            }
            usage = await agent.totalUsage
        } catch {
            // AgentRunner owns the created session, but the driver owns the host lifetime.
            // Preparation can fail after the host has started (for example, SessionWriter
            // setup), so stop it even when the run was concurrently asked to terminate.
            await runner.stopMCPServers()
            await host.stop()
            if terminationRequested {
                await finishFailedLaunch()
                return
            }
            errorBanner = error.localizedDescription
            _ = await commandController.markFailed(commandID: admittedStart.commandID)
            await finishFailedLaunch()
        }
        isStreaming = false
        // Not exited: the conversation, the interpreter and its variables are all still here,
        // so the run stays open for a follow-up rather than being torn down after one prompt.
        reload()
    }

    private func ingest(_ event: Agent.Event) async {
        switch event {
        case .started(let session):
            sessionID = session
            sessionFile = home.sessionFile(id: session)
            follow()
        case .inputCommitted:
            // The ordered event pump preserves this event's position relative to the initial
            // send. Keep the command id until observation so a fast send cannot clear its
            // active command before startup delivery is reported.
            if initialPromptCommandID != nil {
                initialPromptDelivered = true
                initialPromptCommandID = nil
            }
            reload()
        case .steered(let text):
            // One event acknowledges one queued input. Removing by value collapsed two
            // intentionally repeated prompts into one visible delivery.
            if let index = pendingSteering.firstIndex(of: text) {
                pendingSteering.remove(at: index)
            } else if let index = pendingFollowUps.firstIndex(of: text) {
                pendingFollowUps.remove(at: index)
            }
            reload()
        case .textDelta(let t):
            if liveTurnID == nil { beginLiveTurn() }
            guard let turnID = liveTurnID, let messageID = liveMessageID else { break }
            liveRevision &+= 1
            _ = liveOverlay.apply(
                turnID: turnID.rawValue, messageID: messageID.rawValue,
                content: .text(t), lifecycle: .streaming, revision: liveRevision)
            publishLiveOverlay()
        case .thinkingDelta(let t):
            if liveTurnID == nil { beginLiveTurn() }
            guard let turnID = liveTurnID, let messageID = liveMessageID else { break }
            liveRevision &+= 1
            _ = liveOverlay.apply(
                turnID: turnID.rawValue, messageID: messageID.rawValue,
                content: .thinking(t), lifecycle: .streaming, revision: liveRevision)
            publishLiveOverlay()
        case .turnFinished(let messageID, _, _):
            // Do not remove the live row merely because the writer returned. The parser may
            // still be behind; retaining a completed overlay closes that blank/flicker window.
            completeLiveMessage(durableID: messageID)
            reload()
        case .modelChanged(let provider, let id):
            modelLabel = "\(provider)/\(id)"
            reload()
        case .awaitingDispatched(let count):
            skillsNote = "waiting on \(count) dispatched task(s)"
            reload()
        case .goalExhausted, .toolStarted, .toolFinished, .compacted, .childStarted,
             .childFinished, .imageAttached:
            reload()
        case .finished:
            if errorBanner == nil, let turnID = liveTurnID, let messageID = liveMessageID {
                _ = liveOverlay.apply(
                    turnID: turnID.rawValue, messageID: messageID.rawValue,
                    lifecycle: .cancelled, revision: liveRevision &+ 1)
                publishLiveOverlay()
            }
            reload()
        case .failed(let detail):
            errorBanner = detail
            isStreaming = false
            if let turnID = liveTurnID, let messageID = liveMessageID {
                liveRevision &+= 1
                _ = liveOverlay.apply(
                    turnID: turnID.rawValue, messageID: messageID.rawValue,
                    lifecycle: .failed, revision: liveRevision)
                publishLiveOverlay()
            }
            reload()
        }
    }

    /// Settle the exact command that invoked `Agent.send`. Presentation events are delivered
    /// on another task and can lag behind this return, so they must never mutate lifecycle.
    private func settle(_ outcome: Agent.SendOutcome, commandID: String) async {
        switch outcome {
        case .completed:
            _ = await commandController.acknowledgeTurnFinished(commandID: commandID)
        case .cancelled:
            // End-run owns the controller by the time driver-requested cancellation returns.
            // If cancellation came from elsewhere, leave the explicit state untouched rather
            // than guessing that a model stream or action was cancelled.
            break
        case .failed(let detail):
            if errorBanner == nil { errorBanner = detail }
            _ = await commandController.markFailed(commandID: commandID)
        }
    }

    private func reject(_ admission: SessionCommandAdmission, operation: String) {
        guard case .rejected(_, let reason) = admission else { return }
        commandNotice = .warning(
            "Could not " + operation + ": " + String(describing: reason) + ".")
    }

    /// Setup can fail before a runtime session exists. Still drive the same terminal lifecycle
    /// as a normal End and close the launch-boundary writer, so a rejected start cannot leave a
    /// zombie LiveRun in the UI.
    private func finishFailedLaunch() async {
        terminationRequested = true
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
        scheduler?.cancel()
        eventPump?.cancel()
        watcher?.stop()
        await agent?.cancel()
        await agent?.waitUntilQuiescent()
        await runner?.stopMCPServers()
        await host?.stop()
        do {
            try await writer?.closeChecked()
        } catch {
            errorBanner = "The session journal close was not confirmed: \(error.localizedDescription)"
        }
        // End is the durable terminal projection of teardown, not permission to start it.
        // Publish it only after the agent, children/MCP, host, and writer are gone.
        if let endCommand {
            _ = await commandController.acknowledgeEnd(commandID: endCommand.commandID)
        }
        hasExited = true
        isStreaming = false
    }

    /// Watch the file so entries appear as they are appended, including from sub-agents.
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
                    // A terminal outcome is durable but intentionally not a conversation row.
                    // Once the parser observes it, the cold projection is authoritative and
                    // the terminal partial overlay must disappear rather than live forever.
                    _ = self.liveOverlay.remove(identity: LiveTranscriptIdentity(
                        turnID: turnID, messageID: messageID))
                    self.liveTurnID = nil
                    self.liveMessageID = nil
                    self.liveRevision = 0
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
        publishLiveOverlay()
    }

    private func publishLiveOverlay() {
        items = liveOverlay.snapshot.items
    }

    /// Change course without waiting for the current turn to finish.
    ///
    /// Queued on the agent, which injects it at the next turn boundary — the composer stays
    /// usable while the agent works, which is the whole point of steering.
    func steer(_ text: String, sourceID: String? = nil) async -> SessionCommandReceipt {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let admission = await commandController.admitAndCommit(
            .steer(text: text), actorID: sourceID ?? actorID)
        guard case .accepted(let admitted) = admission else {
            reject(admission, operation: "steer")
            return SessionCommandReceipt(admission: admission)
        }
        commandNotice = nil
        guard await commandController.awaitDispatch(commandID: admitted.commandID) != nil else {
            errorBanner = "The steer command lost its dispatch turn."
            return SessionCommandReceipt(
                admission: admission,
                delivery: .indeterminate(reason: "dispatch ownership was unavailable"))
        }
        guard let agent else {
            commandNotice = .warning("Could not steer: the run is still starting.")
            _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
            return SessionCommandReceipt(
                admission: admission,
                delivery: .notDelivered(reason: "the run is still starting"))
        }
        commandNotice = nil
        // Publish the optimistic pending row before yielding to the Agent actor. The Agent can
        // reach the next turn boundary immediately after accepting this request and emit
        // `.steered`; that event must always find the row to acknowledge.
        pendingSteering.append(text)
        let didSteer = await agent.steer(text)
        _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
        guard didSteer else {
            if let index = pendingSteering.firstIndex(of: text) {
                pendingSteering.remove(at: index)
            }
            commandNotice = .warning("Could not steer: the active send already finished.")
            return SessionCommandReceipt(
                admission: admission,
                delivery: .notDelivered(reason: "the active send already finished"))
        }
        return SessionCommandReceipt(admission: admission, delivery: .queued)
    }

    /// Shown in the composer so a queued message is visible until it is taken up.
    private(set) var pendingSteering: [String] = []

    /// Queue a distinct later turn, rather than changing the active turn's next model call.
    func queueFollowUp(
        _ text: String, sourceID: String? = nil
    ) async -> SessionCommandReceipt {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let admission = await commandController.admitAndCommit(
            .queueFollowUp(text: text), actorID: sourceID ?? actorID)
        guard case .accepted(let admitted) = admission else {
            reject(admission, operation: "queue follow-up")
            return SessionCommandReceipt(admission: admission)
        }
        commandNotice = nil
        guard await commandController.awaitDispatch(commandID: admitted.commandID) != nil else {
            errorBanner = "The queue follow-up command lost its dispatch turn."
            return SessionCommandReceipt(
                admission: admission,
                delivery: .indeterminate(reason: "dispatch ownership was unavailable"))
        }
        guard let agent else {
            commandNotice = .warning("Could not queue follow-up: the run is still starting.")
            _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
            return SessionCommandReceipt(
                admission: admission,
                delivery: .notDelivered(reason: "the run is still starting"))
        }
        commandNotice = nil
        // As with steering, put the row in the UI before crossing the actor boundary so a
        // fast completion cannot emit an acknowledgement before the row exists.
        pendingFollowUps.append(text)
        let didQueue = await agent.queueFollowUp(text)
        _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
        guard didQueue else {
            if let index = pendingFollowUps.firstIndex(of: text) {
                pendingFollowUps.remove(at: index)
            }
            commandNotice = .warning(
                "Could not queue follow-up: the active send already finished.")
            return SessionCommandReceipt(
                admission: admission,
                delivery: .notDelivered(reason: "the active send already finished"))
        }
        let queued = await agent.queued
        pendingSteering = queued.steering
        // Keep the optimistic row if the Agent accepted the request but has not reflected the
        // queue snapshot yet; the next event/reload will reconcile it. For the usual path the
        // snapshot includes the same value and preserves duplicate prompts by position.
        pendingFollowUps = queued.followUps
        return SessionCommandReceipt(admission: admission, delivery: .queued)
    }

    private(set) var pendingFollowUps: [String] = []

    /// Request cancellation at the agent loop's next safe boundary.
    ///
    /// The in-house engine cannot interrupt an in-flight provider stream or Python action. The
    /// controller therefore advertises only `.agentLoop`, and this method waits for quiescence
    /// before acknowledging the request. End-run remains a separate, broader teardown command.
    func cancel(
        scope: SessionCancellationScope, sourceID: String? = nil
    ) async -> SessionCommandReceipt {
        let admission = await commandController.admitAndCommit(
            .cancel(scope: scope), actorID: sourceID ?? actorID)
        guard case .accepted(let admitted) = admission else {
            reject(admission, operation: "cancel")
            return SessionCommandReceipt(admission: admission)
        }
        commandNotice = nil
        guard await commandController.awaitDispatch(commandID: admitted.commandID) != nil else {
            errorBanner = "The cancellation command lost its dispatch turn."
            return SessionCommandReceipt(
                admission: admission,
                delivery: .indeterminate(reason: "dispatch ownership was unavailable"))
        }
        guard let agent else {
            let reason = "the run is not attached to an agent"
            commandNotice = .warning("Could not cancel: \(reason).")
            _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
            _ = await commandController.markFailed(commandID: admitted.commandID)
            return SessionCommandReceipt(
                admission: admission, delivery: .notDelivered(reason: reason))
        }
        guard await agent.requestCancellation(scope) else {
            // This should be unreachable because admission is capability-scoped, but retaining
            // a defensive failure keeps a future engine change from claiming cancellation.
            let reason = "the agent does not implement this cancellation scope"
            commandNotice = .warning("Could not cancel: \(reason).")
            _ = await commandController.acknowledgeCancellation(commandID: admitted.commandID)
            _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
            return SessionCommandReceipt(
                admission: admission, delivery: .notDelivered(reason: reason))
        }
        await agent.waitUntilQuiescent()
        let acknowledged = await commandController.acknowledgeCancellation(
            commandID: admitted.commandID)
        _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
        guard acknowledged else {
            commandNotice = .warning(
                "Cancellation reached the agent, but its acknowledgement was stale.")
            return SessionCommandReceipt(
                admission: admission,
                delivery: .indeterminate(reason: "the cancellation acknowledgement was stale"))
        }
        activeTurnCommandID = nil
        isStreaming = false
        commandNotice = .success(
            "Cancellation acknowledged at the agent loop's safe boundary.")
        return SessionCommandReceipt(admission: admission, delivery: .delivered(referenceID: nil))
    }

    /// Add a scheduled job to this session, and start ticking if this is the first one.
    func addJob(prompt: String, everyMinutes: Double, onlyWhenIdle: Bool) {
        guard let sessionID else { return }
        let store = ScheduleStore(home: home, sessionID: sessionID)
        _ = try? store.add(
            ScheduledJob(
            prompt: prompt, everySeconds: everyMinutes * 60, onlyWhenIdle: onlyWhenIdle))
        jobs = store.load()
        startScheduler()
    }

    func removeJob(id: String) {
        guard let sessionID else { return }
        let store = ScheduleStore(home: home, sessionID: sessionID)
        try? store.remove(id: id)
        jobs = store.load()
    }

    /// Fires due jobs. Checks every fifteen seconds rather than sleeping until the next due
    /// time, because jobs can be added and removed while it waits and a recomputed sleep is
    /// more code than a cheap poll.
    private func startScheduler() {
        guard scheduler == nil else { return }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, let sessionID = self.sessionID, !self.hasExited else { return }
                let store = ScheduleStore(home: self.home, sessionID: sessionID)
                let due = store.load().filter { job in
                    job.isDue() && !(job.onlyWhenIdle && self.isStreaming)
                }
                for job in due {
                    // Skipped rather than queued when busy: a heartbeat that piles up while a
                    // long turn runs would deliver a burst the moment it finishes.
                    guard !self.isStreaming else { continue }
                    self.jobs = store.load()
                    let receipt = await self.send(
                        job.prompt, sourceID: "scheduler:" + job.id)
                    if receipt.isDelivered {
                        try? store.markRun(id: job.id)
                    }
                    break
                }
            }
        }
    }

    /// Another prompt in the same session — same conversation, same interpreter, same
    /// variables.
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
        guard let agent else {
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
        let delivery: SessionCommandDelivery = await withCheckedContinuation { continuation in
            task = Task { [weak self] in
                let outcome = await agent.send(prompt) { delivery in
                    continuation.resume(returning: delivery)
                }
                guard let self else { return }
                await self.settle(outcome, commandID: admitted.commandID)
                self.activeTurnCommandID = nil
                self.usage = await agent.totalUsage
                self.isStreaming = false
                self.reload()
        }
    }
        _ = await commandController.acknowledgeDispatched(commandID: admitted.commandID)
        return SessionCommandReceipt(admission: admission, delivery: delivery)
    }

    /// Change the model this run answers with, keeping the conversation and the interpreter.
    ///
    /// Routed through the same factory a launch uses, so a switch cannot reach a client a
    /// launch would not have — that seam is exactly where the Codex 404 lived, and one factory
    /// is the reason it cannot come back.
    func switchModel(to spec: ModelSpec, providerSpec newSpec: ProviderSpec) async -> String? {
        guard let agent else { return "This run has not started yet." }
        guard let writer else { return "The session journal is unavailable." }
        let routed = await ModelSwitchCoordinator.prepare(
            writer: writer, model: spec, provider: newSpec,
            makeProvider: { model, provider in
                switch await ChatProviderRouting.makeProvider(
                    spec: provider, model: model, home: self.home)
                {
                case .success(let client): return .success(client)
                case .failure(let why):
                    return .failure(ModelSwitchCoordinator.Failure(why.localizedDescription))
                }
            })
        guard case .success(let provider) = routed else {
            if case .failure(let why) = routed { return why.message }
            return "Could not build a client for \(spec.qualifiedID)."
        }
        guard await agent.switchModel(to: spec, provider: provider) else {
            return "The model switch could not be committed to the session journal."
        }
        model = spec
        providerSpec = newSpec
        return nil
    }

    func stop() async {
        let admission = await commandController.admitAndCommit(.endRun, actorID: actorID)
        guard case .accepted(let admitted) = admission else {
            reject(admission, operation: "end run")
            return
        }
        terminationRequested = true
        guard await commandController.awaitDispatch(commandID: admitted.commandID) != nil
        else { return }
        scheduler?.cancel()
        let activeTask = task
        // Cancellation is a request to the Agent, while Task cancellation only helps at
        // cooperative suspension points. Await both the driver task and the Agent's explicit
        // quiescence boundary before closing anything the provider or tools may still touch.
        await agent?.cancel()
        activeTask?.cancel()
        await activeTask?.value
        await agent?.waitUntilQuiescent()
        eventPump?.cancel()
        watcher?.stop()
        if let turnID = liveTurnID, let messageID = liveMessageID {
            liveRevision &+= 1
            _ = liveOverlay.apply(
                turnID: turnID.rawValue, messageID: messageID.rawValue,
                lifecycle: .cancelled, revision: liveRevision)
            publishLiveOverlay()
        }
        let host = self.host
        let runner = self.runner
        do {
            try await self.writer?.closeChecked()
        } catch {
            self.errorBanner = "The session journal close was not confirmed: \(error.localizedDescription)"
        }
        await runner?.stopMCPServers()
        await host?.stop()
        _ = await commandController.acknowledgeEnd(commandID: admitted.commandID)
        hasExited = true
        isStreaming = false
    }
}
