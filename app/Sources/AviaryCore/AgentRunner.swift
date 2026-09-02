import Foundation

/// Builds and runs agents, including the children they spawn.
///
/// Exists so `Agent` does not have to know how to make another `Agent`. A sub-agent needs a
/// runtime session, a transcript in the right place, a ledger record, a depth budget and a
/// provider — all of which are the caller's business, not the loop's. Keeping that here means
/// `Agent` stays a loop, and a caller can decide sub-agents are simply not allowed by not
/// installing this.
public actor AgentRunner {

    public struct Settings: Sendable {
        public var home: AgentHome
        public var cwd: String
        public var model: ModelSpec
        public var systemPrompt: String
        /// The producer-side decomposition of ``systemPrompt``. This remains optional so
        /// legacy callers and native resumes whose durable prefix predates source observations
        /// keep the opaque aggregate path.
        public var systemPromptAssembly: SystemPromptAssembly?
        /// The user-selected reasoning level for provider routes that support it.
        public var reasoningEffort: String?
        public var maxDepth: Int
        public var maxIterations: Int
        /// Children get a tighter ceiling than their parent. A delegated task is meant to be
        /// narrower, and an unbounded child is how a fan-out becomes a runaway.
        public var childMaxIterations: Int
        /// Where `remember` writes. Nil disables memory for the run, which is a legitimate
        /// configuration rather than a degraded one.
        public var memory: MemoryStore?
        /// Record request payloads for the root run. Off unless asked: it writes the whole
        /// system prompt and conversation to disk.
        public var recordPayloads = false
        /// A budget and finishing condition for the root run. Children get their own iteration
        /// ceiling instead — a shared token budget would let one child starve its siblings.
        public var goal: Goal?
        /// Hook files to load. Empty means the feature costs nothing.
        public var hookPaths: [String] = []
        /// An existing session id to continue. The run appends to that transcript and picks up
        /// its conversation; nil starts a new session.
        public var resume: String?
        /// Preallocated identity bundle. Nil keeps existing callers source-compatible; prepare()
        /// resolves it before creating a runtime session.
        public var identity: SessionWorkIdentity?
        /// The exact journal opened by the launch boundary. Supplying it is what makes the
        /// writer-before-runtime ordering enforceable: the runner must never silently open a
        /// second handle for the same Work.
        public var writer: SessionWriter?
        /// The exact native Session/Work producer opened by the launch boundary. The runner
        /// borrows it for the root Agent; the driver or CLI retains teardown ownership.
        public var nativeJournal: RunJournalBundle?
        /// Immutable history captured by the native launch boundary before Start admission.
        /// Supplying a native journal for a cold resume without this seed is an error; the
        /// runner must never reread a later tip containing the new prompt or fall back to legacy.
        public var nativeResumeSeed: NativeColdResumeResult?

        /// Who else is running, supplied by the app. Nil in a CLI run, where the two peer
        /// builtins are then not bound at all — which is right: there is nobody else there.
        public var peerDelegate: Agent.PeerDelegate?
        /// Puts a message back into this run's own conversation, for work that outlives the
        /// turn that started it.
        public var selfDelegate: Agent.SelfDelegate?

        public init(
            home: AgentHome, cwd: String, model: ModelSpec, systemPrompt: String,
            systemPromptAssembly: SystemPromptAssembly? = nil,
            maxDepth: Int = 3, maxIterations: Int = 40, childMaxIterations: Int = 20,
            memory: MemoryStore? = nil, recordPayloads: Bool = false, goal: Goal? = nil,
            hookPaths: [String] = [], resume: String? = nil,
            peerDelegate: Agent.PeerDelegate? = nil,
            selfDelegate: Agent.SelfDelegate? = nil,
            identity: SessionWorkIdentity? = nil,
            reasoningEffort: String? = nil,
            writer: SessionWriter? = nil,
            nativeJournal: RunJournalBundle? = nil,
            nativeResumeSeed: NativeColdResumeResult? = nil
        ) {
            self.peerDelegate = peerDelegate
            self.selfDelegate = selfDelegate
            self.home = home
            self.cwd = cwd
            self.model = model
            self.systemPrompt = systemPrompt
            self.systemPromptAssembly = systemPromptAssembly
            self.reasoningEffort = reasoningEffort
            self.maxDepth = maxDepth
            self.maxIterations = maxIterations
            self.childMaxIterations = childMaxIterations
            self.memory = memory
            self.recordPayloads = recordPayloads
            self.goal = goal
            self.hookPaths = hookPaths
            self.resume = resume
            self.identity = identity
            self.writer = writer
            self.nativeJournal = nativeJournal
            self.nativeResumeSeed = nativeResumeSeed
        }
    }

    private let provider: ChatProvider
    private let host: RuntimeHost
    private let settings: Settings
    private var observer: (@Sendable (Agent.Event) -> Void)?

    public init(provider: ChatProvider, host: RuntimeHost, settings: Settings) {
        self.provider = provider
        self.host = host
        self.settings = settings
    }

    public func observe(_ observer: (@Sendable (Agent.Event) -> Void)?) {
        self.observer = observer
    }

    /// Run a root agent to completion. Returns its transcript so a caller can render it.
    /// Build the run and send its first prompt.
    /// Children started in the background, by child id.
    ///
    /// Held on the runner rather than the agent because a child outlives the turn that started
    /// it — that is the whole point — and the agent's turn loop is not where a thing that
    /// outlives turns should live.
    private var background: [String: Agent.ChildStatus] = [:]
    private var backgroundTasks: [String: Task<Void, Never>] = [:]
    /// Cancellation is explicit runner state as well as a Task flag. Awaiting an actor method
    /// can resume on a different task context, so the flag alone is not a reliable record of
    /// why a child settled.
    private var cancellationRequested: Set<String> = []

    /// Live MCP servers, held so they can be stopped with the run that started them.
    private var mcpClients: [MCPClient] = []
    /// Once teardown starts, no callback may admit another background child while the actor is
    /// re-entered awaiting existing child tasks. This remains closed for the lifetime of the
    /// runner, which is also the lifetime of its host resources.
    private var backgroundAdmissionClosed = false

    private func beginNativeAction(
        kind: ActionKind, intent: String, target: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) async throws -> EffectPermit? {
        guard let journal = settings.nativeJournal else { return nil }
        return try await journal.beginAction(
            kind: kind, intent: intent, target: target, scope: "run", metadata: metadata)
    }

    private func requireNativePermit(_ permit: EffectPermit?, kind: ActionKind) throws {
        guard settings.nativeJournal == nil || permit != nil else {
            throw RunJournalBundleError.unavailable(
                "the canonical Work journal refused the \(kind.rawValue) effect")
        }
    }

    private func finishNativeAction(
        _ permit: EffectPermit?, state: ActionExecutionState,
        retrySafety: ActionRetrySafety, failureKind: ActionFailureKind? = nil
    ) async throws {
        guard let journal = settings.nativeJournal else { return }
        guard let permit else {
            throw RunJournalBundleError.unavailable(
                "the canonical Work journal did not issue an effect permit")
        }
        _ = try await journal.finishAction(
            permit, state: state, retrySafety: retrySafety, failureKind: failureKind)
    }

    struct MCPReport {
        var client: MCPClient?
        var tools: [MCPClient.Tool]
        var note: String
    }

    /// Start every configured MCP server and collect its tools.
    ///
    /// One failing server must not take the run with it: an MCP server is somebody else's
    /// program, frequently a `npx` invocation that will fail the first time it is run on a
    /// machine, and a run that refuses to start because a note-taking integration is broken is
    /// a worse outcome than a run without that integration. So each is reported into the
    /// transcript and the rest continue.
    private func startMCPServers() async throws -> [MCPReport] {
        let configured = MCPConfiguration.load(home: settings.home).filter(\.enabled)
        guard !configured.isEmpty else { return [] }
        var reports: [MCPReport] = []
        for server in configured {
            let client = MCPClient(
                name: server.name, executable: server.command, arguments: server.arguments,
                environment: server.environment)
            let permit = try await beginNativeAction(
                kind: .mcp, intent: "Start and discover an MCP server", target: server.name,
                metadata: ["executable": .string(server.command)])
            try requireNativePermit(permit, kind: .mcp)
            let tools: [MCPClient.Tool]
            do {
                tools = try await client.start()
            } catch let startupError {
                await client.stop()
                try await finishNativeAction(
                    permit, state: .failed, retrySafety: .unknown,
                    failureKind: .infrastructure)
                let diagnostics = await client.diagnostics
                reports.append(
                    MCPReport(
                    client: nil, tools: [],
                    note: "MCP · \(server.name) did not start: \(startupError.localizedDescription)"
                        + (diagnostics.isEmpty ? "" : "\n" + String(diagnostics.suffix(400)))))
                continue
            }
            do {
                try await finishNativeAction(
                    permit, state: .succeeded, retrySafety: .unsafe)
            } catch {
                await client.stop()
                throw error
            }
            mcpClients.append(client)
            let era = await client.era
            reports.append(
                MCPReport(
                client: client, tools: tools,
                note: "MCP · \(server.name): \(tools.count) tool(s) over "
                    + "\(era?.label ?? "an unknown protocol")"))
        }
        return reports
    }

    /// Stop the servers this run started.
    public func stopMCPServers() async {
        // Children are part of the run's effect lifetime too. Cancelling the unstructured Task
        // without awaiting it lets a provider/tool call continue while the host and its MCP
        // clients are being dismantled. End must not be published until every child has
        // observed cancellation and returned.
        await stopBackgroundChildren()
        let clients = mcpClients
        mcpClients.removeAll()
        for client in clients {
            // Shutdown is a cleanup effect: record it when the canonical journal is healthy,
            // but never leave the external process alive merely because that journal failed.
            let permit = try? await beginNativeAction(
                kind: .mcp, intent: "Stop an MCP server", target: client.name)
            await client.stop()
            if let permit {
                try? await finishNativeAction(
                    permit, state: .succeeded, retrySafety: .idempotent)
            }
        }
    }

    public func run(prompt: String) async throws -> (writer: SessionWriter, agent: Agent) {
        let prepared = try await prepare()
        await prepared.agent.send(prompt)
        return prepared
    }

    /// Build the run without sending anything.
    ///
    /// Resuming needs this: continuing a session opens a run whose conversation is already
    /// there and then waits for what you want to say next, which is not the same as sending an
    /// empty prompt — an empty user turn is a real turn, and some routes reject it.
    public func prepare() async throws -> (writer: SessionWriter, agent: Agent) {
        // Resolve once, before the runtime/provider boundary. Legacy headers supply the Work
        // identity when available; otherwise this home owns a durable host id and gets a
        // deterministic legacy Work id for the resumed session.
        let identity =
            settings.identity
            ?? settings.resume.flatMap {
                SessionWriter.recoverIdentity(home: settings.home, sessionID: $0)
            }
            ?? SessionWorkIdentity.allocate(
                workHostID: settings.home.workHostID,
                sessionID: settings.resume ?? SessionWriter.newSessionID())
        // A cold resume reuses the durable session/Work identity but must not claim the old
        // Python namespace. The same RuntimeHost may still hold the live namespace from the
        // previous run, and `session.create` correctly rejects reopening it. A fresh runtime
        // id per run makes the survival boundary explicit: only a deliberate live-host
        // reattach may reuse `identity.workID`.
        // Open or adopt the journal before creating a runtime session. A runtime namespace is
        // an external effect; if the durable antecedent cannot be established, no Python work
        // may become reachable.
        let writer: SessionWriter
        if let supplied = settings.writer {
            writer = supplied
        } else if let resume = settings.resume {
            writer = try SessionWriter(
                home: settings.home, resuming: resume, cwd: settings.cwd,
                model: settings.model, identity: identity)
        } else {
            writer = try SessionWriter(
                home: settings.home, cwd: settings.cwd, model: settings.model,
                identity: identity)
        }

        let runtimeSessionID =
            settings.resume == nil
            ? identity.workID
            : identity.workID + "-run-" + identity.runID

        // Every operation after the journal open is covered by one cleanup boundary. A failed
        // replay/runtime/agent assembly must not leave an invisible Python namespace behind.
        let writerForCleanup: SessionWriter? = writer
        var hostSessionForCleanup: String?
        do {
            // Choose replay before the runtime namespace is created. Native history was captured
            // at the locked pre-Start boundary and is authoritative; a missing seed or malformed
            // pinned instruction set is a hard recovery error, never an invitation to consult the
            // legacy presentation transcript.
            var replay = SessionReplay()
            var systemPrompt = settings.systemPromptAssembly?.flattenedText ?? settings.systemPrompt
            var systemPromptAssembly = settings.systemPromptAssembly
            if let assembly = systemPromptAssembly,
               Data(settings.systemPrompt.utf8) != Data(assembly.flattenedText.utf8) {
                throw RunJournalBundleError.invalidConfiguration(
                    "systemPrompt and systemPromptAssembly contain different bytes")
            }
            var expectedResumeTools: [ChatTool]?
            var nativeResumeNote: String?
            if settings.resume != nil {
                if settings.nativeJournal != nil {
                    guard let seed = settings.nativeResumeSeed else {
                        throw RunJournalBundleError.invalidConfiguration(
                            "native cold resume is missing its pre-Start replay seed")
                    }
                    guard seed.pinnedMessages.count == 1,
                          seed.pinnedMessages[0].role == .system,
                          seed.pinnedMessages[0].content.count == 1,
                          case .text(let retainedSystemPrompt) = seed.pinnedMessages[0].content[0]
                    else {
                        throw RunJournalBundleError.invalidConfiguration(
                            "native cold resume requires one retained text system instruction")
                    }
                    replay.messages = seed.messages
                    replay.lastModel = seed.modelID
                    systemPrompt = retainedSystemPrompt
                    // NativeColdResume owns source-body reconstruction and validation at the
                    // recovery boundary. A nil value is intentional for legacy native prefixes
                    // whose effective system prompt is only an opaque retained message.
                    systemPromptAssembly = seed.systemPromptAssembly
                    expectedResumeTools = seed.tools
                    nativeResumeNote =
                        "Native cold resume reconstructed the durable timeline and "
                        + "prior effective model context. The Python namespace and background "
                        + "Futures/Handles were not restored; memory/artifact/repository state and "
                        + "external effects remain unknown."
                } else {
                    guard settings.nativeResumeSeed == nil else {
                        throw RunJournalBundleError.invalidConfiguration(
                            "a native resume seed was supplied without its native journal authority")
                    }
                    replay =
                        SessionResume.replay(
                            fileURL: settings.home.sessionFile(id: settings.resume!))
                        ?? SessionReplay()
                }
            } else if settings.nativeResumeSeed != nil {
                throw RunJournalBundleError.invalidConfiguration(
                    "a fresh run cannot consume a native cold-resume seed")
            }

        guard case .healthy = await writer.writerHealth else {
            throw SessionWriter.WriterError.unavailable("The session journal is unavailable.")
        }
        let runtimePermit = try await beginNativeAction(
            kind: .runtime, intent: "Create the Work's Python namespace",
            target: runtimeSessionID, metadata: ["cwd": .string(settings.cwd)])
        try requireNativePermit(runtimePermit, kind: .runtime)
        let hostSession: String
        do {
            hostSession = try await host.createSession(id: runtimeSessionID, cwd: settings.cwd)
        } catch {
            try await finishNativeAction(
                runtimePermit, state: .failed, retrySafety: .unknown,
                failureKind: .infrastructure)
            throw error
        }
        do {
            try await finishNativeAction(
                runtimePermit, state: .succeeded, retrySafety: .unsafe)
        } catch {
            await host.destroySessionQuietly(hostSession)
            throw error
        }
        hostSessionForCleanup = hostSession
        let agent = Agent(
            provider: provider, host: host, writer: writer, hostSession: hostSession,
            config: .init(
                model: settings.model, cwd: settings.cwd, systemPrompt: systemPrompt,
                systemPromptAssembly: systemPromptAssembly,
                maxIterations: settings.maxIterations, maxTokens: settings.model.maxTokens,
                    reasoningEffort: settings.reasoningEffort,
                maxDepth: settings.maxDepth, depth: 0, goal: settings.goal,
                resumedHistory: replay.messages,
                expectedResumeTools: expectedResumeTools),
            nativeJournal: settings.nativeJournal,
            contextBodyStore: ContextBodyStore(home: settings.home))

        let obs = observer
        await agent.observe { event in obs?(event) }
        // Only the app knows what else is running, so it supplies this. A CLI run leaves it
        // nil and the two peer builtins simply are not bound — which is right: there is
        // nobody else there.
        await agent.setPeerDelegate(settings.peerDelegate)
        await agent.setSelfDelegate(settings.selfDelegate)
        await agent.setSpawnDelegate(Delegate(runner: self, parentSessionID: writer.sessionID))
        await agent.setMemory(settings.memory)
        await agent.setArtifacts(
            ArtifactStore(home: settings.home, sessionID: writer.sessionID))
        if !settings.hookPaths.isEmpty {
            let hookPermit = try await beginNativeAction(
                kind: .hook, intent: "Load runtime hooks", target: hostSession,
                metadata: ["count": .number(Double(settings.hookPaths.count))])
            try requireNativePermit(hookPermit, kind: .hook)
            let result: (
                loaded: [(path: String, events: [String])],
                failed: [(path: String, detail: String)]
            )
            do {
                result = try await host.loadHooks(settings.hookPaths)
            } catch let loadError {
                try await finishNativeAction(
                    hookPermit, state: .failed, retrySafety: .unknown,
                    failureKind: .infrastructure)
                throw loadError
            }
            try await finishNativeAction(
                hookPermit,
                state: result.failed.isEmpty ? .succeeded : .failed,
                retrySafety: .unsafe,
                failureKind: result.failed.isEmpty ? nil : .task)
            // A hook that failed to load is reported into the transcript rather than swallowed:
            // silently absent and deliberately doing nothing are indistinguishable, and the
            // difference matters when the hook was supposed to be blocking something.
            for failure in result.failed {
                try await writer.appendNote(
                    "A hook failed to load: \(failure.path)\n\(failure.detail)",
                    customType: "aviary.hook")
            }
            if !result.loaded.isEmpty {
                await agent.enableHooks(true)
            }
        }
        if settings.recordPayloads {
                await agent.recordPayloads(to: WireLog.path(forRun: identity.runID))
        }

        // MCP servers from settings.json. Started here rather than at app launch because a
        // server is a child process holding credentials, and the honest lifetime for that is
        // the run that asked for it.
        for report in try await startMCPServers() {
            try await writer.appendNote(report.note, customType: "aviary.mcp")
            if let client = report.client, !report.tools.isEmpty {
                await agent.addMCPTools(report.tools, from: client)
            }
        }

        // Route the runtime's callbacks to this agent. One host serves many sessions, so the
        // handler dispatches on the host-session id rather than assuming a single agent.
            register(hostSession: hostSession, agent: agent)
        await installCallbackHandler()

        // Recorded in the transcript, not just shown once in the UI: a resumed run whose
        // history was altered should still say so when the session is read back tomorrow.
        if settings.resume != nil {
            var note = replay.messages.isEmpty
                ? "Resumed, but no prior conversation could be replayed from this session."
                : "Resumed: picked up \(replay.turnCount) prior turn(s)."
            if let caveat = replay.caveat { note += " " + caveat + "." }
            if let nativeResumeNote { note += " " + nativeResumeNote }
            try await writer.appendNote(note, customType: "aviary.resume")
        }

        return (writer, agent)
        } catch {
            await writerForCleanup?.close()
            await stopMCPServers()
            if let hostSessionForCleanup {
                await host.destroySessionQuietly(hostSessionForCleanup)
            }
            throw error
        }
    }

    // MARK: Callback routing

    private var agentsByHostSession: [String: Agent] = [:]
    private var handlerInstalled = false

    private func register(hostSession: String, agent: Agent) {
        agentsByHostSession[hostSession] = agent
    }

    private func installCallbackHandler() async {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        await host.onCallback { [weak self] session, kind, payload in
            guard let self else {
                return .object(["error": .string("Aviary is no longer listening.")])
            }
            return await self.dispatch(session: session, kind: kind, payload: payload)
        }
    }

    private func dispatch(session: String, kind: String, payload: JSONValue) async -> JSONValue {
        guard let agent = agentsByHostSession[session] else {
            // Can happen if a runtime session outlives its agent. Answered rather than
            // ignored, so the agent code gets an error instead of a nine-minute timeout.
            return .object(["error": .string("No agent is attached to this runtime session.")])
        }
        return await agent.serveCallback(kind: kind, payload: payload)
    }

    // MARK: Children

    /// Runs one child and reports its answer back to the parent.
    ///
    /// A child is an ordinary agent: its own runtime session (so its Python state is its own),
    /// its own transcript under the parent's artifacts directory, and its own ledger record so
    /// Flock draws it. What it is *not* is a fresh context — the prompt it gets is the whole
    /// brief, which is why the parent is told to write a self-contained one.
    /// Start a child and return its id immediately.
    ///
    /// The parent keeps its turn. Worth being clear about what that buys and costs: two agents
    /// now write to the same runtime host concurrently, which is fine because the host gives
    /// each session its own interpreter and its own GIL, and both append to their own
    /// transcripts. What it does *not* buy is a notification — the parent finds out by asking
    /// `children()`, because there is no way to interrupt a turn that is already running
    /// without producing a conversation its provider rejects.
    fileprivate func startBackgroundChild(
        prompt: String, name: String?, modelID: String?, depth: Int, parentSessionID: String
    ) async -> Agent.SpawnStartResult {
        let label = name ?? "child"
        guard !backgroundAdmissionClosed else {
            return .refused(
                name: label, reason: "The run is stopping; background child admission is closed.")
        }

        let childID = SubAgentRecorder.newChildID()
        if let journal = settings.nativeJournal {
            do {
                // This is the admission boundary. In particular, do not create the Task until
                // the parent has durable evidence that this child is running.
                try await journal.recordChildLifecycle(
                    childID: childID, name: label, state: .running)
            } catch {
                return .refused(
                    name: label,
                    reason: "The canonical child lifecycle could not be recorded: "
                        + error.localizedDescription)
            }
        }
        background[childID] = Agent.ChildStatus(
            id: childID, name: label, state: "running", answer: nil)
        backgroundTasks[childID] = Task { [weak self] in
            guard let self else { return }
            let result = await self.runChild(
                prompt: prompt, name: name, modelID: modelID, depth: depth,
                parentSessionID: parentSessionID, childID: childID)
            let taskCanceled = Task.isCancelled
            let runnerCanceled = await self.wasCancellationRequested(childID)
            let lifecycle: ChildLifecycleState = (taskCanceled || runnerCanceled)
                ? .canceled
                : (result.isError ? .failed : .done)
            await self.finishBackground(
                childID: childID, name: result.name, answer: result.answer,
                lifecycle: lifecycle, sessionFile: result.sessionFile,
                prompt: prompt, depth: depth, parentSessionID: parentSessionID,
                createdAt: result.createdAt)
        }
        return .running(childID: childID, name: label)
    }

    private func finishBackground(
        childID: String, name: String, answer: String, lifecycle: ChildLifecycleState,
        sessionFile: URL?, prompt: String, depth: Int, parentSessionID: String,
        createdAt: Date
    ) async {
        var finalLifecycle = lifecycle
        var finalAnswer = answer
        if let journal = settings.nativeJournal {
            do {
                try await journal.recordChildLifecycle(
                    childID: childID, name: name, state: lifecycle)
            } catch {
                // A settled child is not a successful child until its terminal record is
                // durable. The bundle latches itself here; keep both projections non-successful.
                finalLifecycle = .failed
                finalAnswer = "The child \(childID) settled as \(lifecycle.rawValue), but its "
                    + "terminal lifecycle could not be recorded: "
                    + error.localizedDescription
            }
        }

        // Keep the legacy Flock ledger behind the canonical terminal boundary. This avoids a
        // completed legacy row when a native terminal append fails.
        if let sessionFile {
            let recorder = SubAgentRecorder(home: settings.home, parentSessionID: parentSessionID)
            try? recorder.record(
                childID: childID, name: name, sessionFile: sessionFile, prompt: prompt,
                spawnCode: "", depth: depth, maxDepth: settings.maxDepth,
                status: finalLifecycle == .done ? "completed" : finalLifecycle.rawValue,
                provider: settings.model.providerID, model: settings.model.id,
                createdAt: createdAt)
        }
        background[childID] = Agent.ChildStatus(
            id: childID, name: name,
            state: finalLifecycle == .done ? "done" : finalLifecycle.rawValue,
            answer: finalAnswer)
        backgroundTasks[childID] = nil
        cancellationRequested.remove(childID)
    }

    fileprivate func backgroundChildren() -> [Agent.ChildStatus] {
        background.values.sorted { $0.id < $1.id }
    }

    /// Stop anything still running, when the run that started it is going away.
    ///
    /// A background child whose parent has exited has nobody to report to, and a runtime host
    /// about to be torn down underneath it. Cancelled rather than left, because an orphan that
    /// keeps spending tokens is the failure mode this whole feature could most easily add.
    public func stopBackgroundChildren() async {
        backgroundAdmissionClosed = true
        // Drain rather than snapshot once. The actor is re-entrant while awaiting a child, so a
        // callback can otherwise enqueue a nested child after the first snapshot. Admission is
        // closed above, and each loop waits for the handles that already exist before checking
        // again. This method is called by the driver, never by a child task, so it cannot
        // self-await.
        while !backgroundTasks.isEmpty {
            let tasks = Array(backgroundTasks.values)
            for childID in backgroundTasks.keys {
                cancellationRequested.insert(childID)
            }
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
        }
        backgroundTasks.removeAll()
    }

    private func wasCancellationRequested(_ childID: String) -> Bool {
        cancellationRequested.contains(childID)
    }

    fileprivate func runChild(
        prompt: String, name: String?, modelID: String?, depth: Int, parentSessionID: String,
        childID preallocated: String? = nil
    ) async -> (
        answer: String, isError: Bool, childID: String, name: String, sessionFile: URL?,
        createdAt: Date
    ) {
        // Passed in by the background path, which has already told the parent this id.
        let childID = preallocated ?? SubAgentRecorder.newChildID()
        let label = name ?? childID
        let recorder = SubAgentRecorder(home: settings.home, parentSessionID: parentSessionID)
        let createdAt = Date()

        observer?(.childStarted(id: childID, name: label, prompt: prompt))

        let childDir = recorder.childDirectory(childID: childID)
        do {
            try FileManager.default.createDirectory(
                at: childDir, withIntermediateDirectories: true)
        } catch {
            return (
                "Could not create the child's directory: \(error.localizedDescription)",
                true, childID, label, childDir.appending(path: "failed.jsonl"), createdAt
            )
        }

        // A child writes into its own directory rather than the flat sessions dir, which is
        // what makes the tree recoverable from the filesystem alone.
        let childHome = AgentHome(root: childDir)
        let childIdentity = SessionWorkIdentity.allocate(
            workHostID: settings.identity?.workHostID ?? settings.home.workHostID,
            sessionID: SessionWriter.newSessionID())
        let model = settings.model

        // Reserve the child's durable antecedent before allocating a Python namespace. A child
        // is a real Work of its own; creating a host session first would leave an unjournaled
        // interpreter behind if SessionWriter setup failed.
        let writer: SessionWriter
        do {
            writer = try SessionWriter(
                home: childHome, cwd: settings.cwd, model: model, identity: childIdentity)
        } catch {
            return (
                "The sub-agent could not open its session journal: \(error.localizedDescription)",
                true, childID, label, childDir.appending(path: "failed.jsonl"), createdAt
            )
        }

        var hostSession: String?
        do {
            hostSession = try await host.createSession(
                id: childIdentity.workID, cwd: settings.cwd)
            try recorder.record(
                childID: childID, name: label, sessionFile: writer.fileURL, prompt: prompt,
                spawnCode: "spawn(\(prompt.debugDescription))", depth: depth,
                maxDepth: settings.maxDepth, status: "running",
                provider: model.providerID, model: model.id, createdAt: createdAt)

            let child = Agent(
                provider: provider, host: host, writer: writer, hostSession: hostSession!,
                config: .init(
                    model: model, cwd: settings.cwd,
                    systemPrompt: Self.childPrompt(
                        base: settings.systemPrompt, depth: depth,
                                                   maxDepth: settings.maxDepth),
                    maxIterations: settings.childMaxIterations, maxTokens: model.maxTokens,
                    maxDepth: settings.maxDepth, depth: depth))
            await child.setSpawnDelegate(Delegate(runner: self, parentSessionID: writer.sessionID))
            // Children remember too: a finding is no less true for having been discovered by
            // a delegate, and a child that cannot record one has to hand it back in prose.
            await child.setMemory(settings.memory)
            // Under the child's own home, not the parent's — a child's transcript already lives
            // there, and keeping its document beside it is what makes the tree recoverable from
            // the filesystem alone.
            await child.setArtifacts(
                ArtifactStore(home: childHome, sessionID: writer.sessionID))
            register(hostSession: hostSession!, agent: child)

            // A child's own events are not forwarded to the parent's observer: a fan-out of
            // eight would make the parent's stream unreadable. The child's transcript is on
            // disk and Flock renders it, which is the right place to watch one.
            await child.send(prompt)

            let answer = await child.lastAssistantText
            var teardownFailure: String?
            do {
                try await writer.closeChecked()
            } catch {
                teardownFailure = "The sub-agent journal could not be closed: "
                    + error.localizedDescription
            }
            do {
                try await host.destroySession(hostSession!)
            } catch {
                let detail = "The sub-agent runtime could not be destroyed: "
                    + error.localizedDescription
                teardownFailure = [teardownFailure, detail].compactMap { $0 }.joined(separator: " ")
            }
            let failed = answer.isEmpty || teardownFailure != nil
            let terminalAnswer: String
            if let teardownFailure {
                terminalAnswer = teardownFailure
            } else {
                terminalAnswer = failed ? "The sub-agent produced no answer." : answer
            }
            return (
                terminalAnswer,
                failed, childID, label, writer.fileURL, createdAt
            )
        } catch {
            try? await writer.closeChecked()
            if let hostSession {
                await host.destroySessionQuietly(hostSession)
            }
            return (
                "The sub-agent could not start: \(error.localizedDescription)",
                true, childID, label, writer.fileURL, createdAt
            )
        }
    }

    /// What a child is told, on top of the shared prompt.
    static func childPrompt(base: String, depth: Int, maxDepth: Int) -> String {
        base + """


            ## You are a sub-agent

            You were spawned to do one specific thing. You are at depth \(depth) of \(maxDepth).

            Your final message is the whole of what your parent receives — it does not see your \
            transcript, your tool output, or your reasoning. So end with the answer itself: what \
            you found, the paths, the numbers, the verdict. Not "I have completed the analysis".

            Work narrowly and stop. \(depth >= maxDepth
                ? "You cannot spawn further sub-agents; do this work yourself."
                : "Spawn a sub-agent only for genuinely separable work.")
            """
    }

    private struct Delegate: Agent.SpawnDelegate {
        let runner: AgentRunner
        let parentSessionID: String

        func startBackground(
            prompt: String, name: String?, model: String?, depth: Int
        ) async -> Agent.SpawnStartResult {
            await runner.startBackgroundChild(
                prompt: prompt, name: name, modelID: model, depth: depth,
                parentSessionID: parentSessionID)
        }

        func children() async -> [Agent.ChildStatus] {
            await runner.backgroundChildren()
        }
    }
}

extension RuntimeHost {
    /// Destroy a session, ignoring failure. Used on teardown paths where a session that is
    /// already gone is a success, not an error worth surfacing.
    func destroySessionQuietly(_ id: String) async {
        try? await destroySession(id)
    }
}
