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
        public var maxDepth: Int
        public var maxIterations: Int
        /// Children get a tighter ceiling than their parent. A delegated task is meant to be
        /// narrower, and an unbounded child is how a fan-out becomes a runaway.
        public var childMaxIterations: Int
        /// Where `remember` writes. Nil disables memory for the run, which is a legitimate
        /// configuration rather than a degraded one.
        public var memory: MemoryStore?

        public init(
            home: AgentHome, cwd: String, model: ModelSpec, systemPrompt: String,
            maxDepth: Int = 3, maxIterations: Int = 40, childMaxIterations: Int = 20,
            memory: MemoryStore? = nil
        ) {
            self.home = home
            self.cwd = cwd
            self.model = model
            self.systemPrompt = systemPrompt
            self.maxDepth = maxDepth
            self.maxIterations = maxIterations
            self.childMaxIterations = childMaxIterations
            self.memory = memory
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
    public func run(prompt: String) async throws -> (writer: SessionWriter, agent: Agent) {
        let hostSession = try await host.createSession(cwd: settings.cwd)
        let writer = try SessionWriter(home: settings.home, cwd: settings.cwd, model: settings.model)
        let agent = Agent(
            provider: provider, host: host, writer: writer, hostSession: hostSession,
            config: .init(
                model: settings.model, cwd: settings.cwd, systemPrompt: settings.systemPrompt,
                maxIterations: settings.maxIterations, maxTokens: settings.model.maxTokens,
                maxDepth: settings.maxDepth, depth: 0))

        let obs = observer
        await agent.observe { event in obs?(event) }
        await agent.setSpawnDelegate(Delegate(runner: self, parentSessionID: writer.sessionID))
        await agent.setMemory(settings.memory)

        // Route the runtime's callbacks to this agent. One host serves many sessions, so the
        // handler dispatches on the host-session id rather than assuming a single agent.
        await register(hostSession: hostSession, agent: agent)
        await installCallbackHandler()

        await agent.send(prompt)
        return (writer, agent)
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
    fileprivate func runChild(
        prompt: String, name: String?, modelID: String?, depth: Int, parentSessionID: String
    ) async -> (answer: String, isError: Bool, childID: String, name: String) {
        let childID = SubAgentRecorder.newChildID()
        let label = name ?? childID
        let recorder = SubAgentRecorder(home: settings.home, parentSessionID: parentSessionID)
        let createdAt = Date()

        observer?(.childStarted(id: childID, name: label, prompt: prompt))

        let childDir = recorder.childDirectory(childID: childID)
        do {
            try FileManager.default.createDirectory(
                at: childDir, withIntermediateDirectories: true)
        } catch {
            return ("Could not create the child's directory: \(error.localizedDescription)",
                    true, childID, label)
        }

        // A child writes into its own directory rather than the flat sessions dir, which is
        // what makes the tree recoverable from the filesystem alone.
        let childHome = AgentHome(root: childDir)
        let model = settings.model

        do {
            let hostSession = try await host.createSession(cwd: settings.cwd)
            let writer = try SessionWriter(home: childHome, cwd: settings.cwd, model: model)
            try recorder.record(
                childID: childID, name: label, sessionFile: writer.fileURL, prompt: prompt,
                spawnCode: "spawn(\(prompt.debugDescription))", depth: depth,
                maxDepth: settings.maxDepth, status: "running",
                provider: model.providerID, model: model.id, createdAt: createdAt)

            let child = Agent(
                provider: provider, host: host, writer: writer, hostSession: hostSession,
                config: .init(
                    model: model, cwd: settings.cwd,
                    systemPrompt: Self.childPrompt(base: settings.systemPrompt, depth: depth,
                                                   maxDepth: settings.maxDepth),
                    maxIterations: settings.childMaxIterations, maxTokens: model.maxTokens,
                    maxDepth: settings.maxDepth, depth: depth))
            await child.setSpawnDelegate(Delegate(runner: self, parentSessionID: writer.sessionID))
            // Children remember too: a finding is no less true for having been discovered by
            // a delegate, and a child that cannot record one has to hand it back in prose.
            await child.setMemory(settings.memory)
            register(hostSession: hostSession, agent: child)

            // A child's own events are not forwarded to the parent's observer: a fan-out of
            // eight would make the parent's stream unreadable. The child's transcript is on
            // disk and Flock renders it, which is the right place to watch one.
            await child.send(prompt)

            let answer = await child.lastAssistantText
            let failed = answer.isEmpty
            try? recorder.record(
                childID: childID, name: label, sessionFile: writer.fileURL, prompt: prompt,
                spawnCode: "", depth: depth, maxDepth: settings.maxDepth,
                status: failed ? "failed" : "completed",
                provider: model.providerID, model: model.id, createdAt: createdAt)
            await writer.close()
            await host.destroySessionQuietly(hostSession)

            return (failed ? "The sub-agent produced no answer." : answer,
                    failed, childID, label)
        } catch {
            try? recorder.record(
                childID: childID, name: label,
                sessionFile: childDir.appending(path: "failed.jsonl"), prompt: prompt,
                spawnCode: "", depth: depth, maxDepth: settings.maxDepth, status: "failed",
                provider: model.providerID, model: model.id, createdAt: createdAt)
            return ("The sub-agent could not start: \(error.localizedDescription)",
                    true, childID, label)
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

        func spawn(
            prompt: String, name: String?, model: String?, depth: Int
        ) async -> (answer: String, isError: Bool, childID: String, name: String) {
            await runner.runChild(
                prompt: prompt, name: name, modelID: model, depth: depth,
                parentSessionID: parentSessionID)
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
