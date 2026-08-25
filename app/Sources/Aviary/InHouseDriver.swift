import SwiftUI
import AviaryCore

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
    /// The assistant text of the turn in flight, before it becomes an entry.
    var streamingText = ""
    var streamingThinking = ""
    var isStreaming = false
    var hasExited = false
    var usage = Usage()
    var sessionID: String?
    var sessionFile: URL?
    var errorBanner: String?
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
    /// Kept so the run can take another prompt. The loop is per-prompt; the conversation,
    /// the runtime session and its Python state all persist across them — which is the whole
    /// reason a session is worth more than a request.
    private var agent: Agent?
    private(set) var acceptsFollowUps = false
    /// Schedules for this session, and the timer that fires them.
    private(set) var jobs: [ScheduledJob] = []
    private var scheduler: Task<Void, Never>?

    /// Whether to record request payloads, so the run's "what was sent" breakdown works.
    private let recordPayloads: Bool
    /// An existing session to continue, or nil for a new one.
    private let resume: String?
    /// Who else is running. Supplied by the app, because only it knows.
    private let peerDelegate: Agent.PeerDelegate?

    init(
        home: AgentHome, cwd: String, model: ModelSpec, providerSpec: ProviderSpec,
        recordPayloads: Bool = false, resume: String? = nil,
        peerDelegate: Agent.PeerDelegate? = nil
    ) {
        self.peerDelegate = peerDelegate
        self.recordPayloads = recordPayloads
        self.resume = resume
        self.home = home
        self.cwd = cwd
        self.model = model
        self.providerSpec = providerSpec
    }

    func start(prompt: String) {
        task = Task { await run(prompt: prompt) }
    }

    private func run(prompt: String) async {
        guard let repoRoot = EngineLocator.repoRoot() else {
            errorBanner = "No Aviary checkout, so there is no runtime host."
            hasExited = true
            return
        }
        // The same factory `--agent` uses. Two switch statements over the same api enum is
        // what let the GUI send Codex traffic to the completions client and 404.
        let routed = await ChatProviderRouting.makeProvider(
            spec: providerSpec, model: model, home: home)
        guard case .success(let provider) = routed else {
            if case .failure(let why) = routed { errorBanner = why.localizedDescription }
            hasExited = true
            return
        }

        // Started after the provider is settled, so a run that cannot reach a model does not
        // boot a Python interpreter first and leave it to be torn down again.
        let script = repoRoot.appending(path: "runtime-hosts/python3/host.py")
        let host = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", script.path])
        self.host = host
        do {
            runtimeSummary = try await host.start().summary
        } catch {
            errorBanner = "Could not start the runtime host: \(error.localizedDescription)"
            hasExited = true
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
            skillsNote = "\(selection.included.count) of \(library.skills.count) skills described"
                + " · \(Fmt.bytes(selection.savedCharacters)) saved"
        }

        let memory = MemoryStore(repoRoot: repoRoot, home: home, cwd: cwd)
        let memoryGate = MemoryGate()
        let recalled = memoryGate.select(memory.load(sessionID: nil), prompt: prompt)
        if recalled.totalAvailable > 0 {
            memoryNote = "\(recalled.included.count) memories recalled"
                + (recalled.listed.isEmpty ? "" : ", \(recalled.listed.count) listed")
        }

        let runner = AgentRunner(
            provider: provider, host: host,
            settings: .init(
                home: home, cwd: cwd, model: model,
                systemPrompt: SystemPrompt.build(
                    cwd: cwd, model: model, skills: gate.render(selection),
                    memory: memoryGate.render(recalled)),
                memory: memory, recordPayloads: recordPayloads,
                hookPaths: HookDiscovery.paths(repoRoot: repoRoot), resume: resume,
                peerDelegate: peerDelegate))
        self.runner = runner

        await runner.observe { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }

        isStreaming = true
        do {
            // An empty prompt means "open the run and wait" — the resume case.
            let (writer, agent) = prompt.isEmpty
                ? try await runner.prepare()
                : try await runner.run(prompt: prompt)
            self.writer = writer
            self.agent = agent
            acceptsFollowUps = true
            if let sessionID { jobs = ScheduleStore(home: home, sessionID: sessionID).load() }
            usage = await agent.totalUsage
        } catch {
            errorBanner = error.localizedDescription
            hasExited = true
        }
        isStreaming = false
        // Not exited: the conversation, the interpreter and its variables are all still here,
        // so the run stays open for a follow-up rather than being torn down after one prompt.
        reload()
    }

    private func ingest(_ event: Agent.Event) {
        switch event {
        case .started(let session):
            sessionID = session
            sessionFile = home.sessionFile(id: session)
            follow()
        case .steered(let text):
            pendingSteering.removeAll { $0 == text }
            reload()
        case .textDelta(let t):
            streamingText += t
        case .thinkingDelta(let t):
            streamingThinking += t
        case .turnFinished:
            // The turn is on disk now, so the file is the source of truth for it and the
            // streaming buffer would only duplicate it.
            streamingText = ""
            streamingThinking = ""
            reload()
        case .modelChanged(let provider, let id):
            modelLabel = "\(provider)/\(id)"
            reload()
        case .goalExhausted, .toolStarted, .toolFinished, .compacted, .childStarted,
             .childFinished, .imageAttached:
            reload()
        case .finished:
            isStreaming = false
            reload()
        case .failed(let detail):
            errorBanner = detail
            isStreaming = false
            reload()
        }
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
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                SessionParser.parse(fileURL: sessionFile)
            }.value
            await MainActor.run {
                if let parsed {
                    self.items = parsed.items
                    if parsed.usage.totalTokens > 0 { self.usage = parsed.usage }
                }
            }
        }
    }

    /// Change course without waiting for the current turn to finish.
    ///
    /// Queued on the agent, which injects it at the next turn boundary — the composer stays
    /// usable while the agent works, which is the whole point of steering.
    func steer(_ text: String) {
        guard let agent else { return }
        Task { await agent.steer(text) }
        pendingSteering.append(text)
    }

    /// Shown in the composer so a queued message is visible until it is taken up.
    private(set) var pendingSteering: [String] = []

    /// Add a scheduled job to this session, and start ticking if this is the first one.
    func addJob(prompt: String, everyMinutes: Double, onlyWhenIdle: Bool) {
        guard let sessionID else { return }
        let store = ScheduleStore(home: home, sessionID: sessionID)
        try? store.add(ScheduledJob(
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
                    try? store.markRun(id: job.id)
                    self.jobs = store.load()
                    self.send(job.prompt)
                    break
                }
            }
        }
    }

    /// Another prompt in the same session — same conversation, same interpreter, same
    /// variables.
    func send(_ prompt: String) {
        guard let agent, !isStreaming else { return }
        task = Task {
            isStreaming = true
            await agent.send(prompt)
            usage = await agent.totalUsage
            isStreaming = false
            reload()
        }
    }

    /// Change the model this run answers with, keeping the conversation and the interpreter.
    ///
    /// Routed through the same factory a launch uses, so a switch cannot reach a client a
    /// launch would not have — that seam is exactly where the Codex 404 lived, and one factory
    /// is the reason it cannot come back.
    func switchModel(to spec: ModelSpec, providerSpec newSpec: ProviderSpec) async -> String? {
        guard let agent else { return "This run has not started yet." }
        let routed = await ChatProviderRouting.makeProvider(
            spec: newSpec, model: spec, home: home)
        guard case .success(let provider) = routed else {
            if case .failure(let why) = routed { return why.localizedDescription }
            return "Could not build a client for \(spec.qualifiedID)."
        }
        model = spec
        providerSpec = newSpec
        await agent.switchModel(to: spec, provider: provider)
        return nil
    }

    func stop() {
        scheduler?.cancel()
        task?.cancel()
        watcher?.stop()
        let host = self.host
        let runner = self.runner
        Task {
            await self.writer?.close()
            await runner?.stopMCPServers()
            await host?.stop()
        }
        hasExited = true
        isStreaming = false
    }
}
