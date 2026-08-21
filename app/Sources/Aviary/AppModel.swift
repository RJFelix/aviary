import SwiftUI
import Observation
import AviaryCore

/// Top-level navigation destinations.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case cockpit, live, sessions, workshop, flock, models, usage, library, health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cockpit: return "Cockpit"
        case .live: return "Live"
        case .sessions: return "Sessions"
        case .workshop: return "Workshop"
        case .flock: return "Flock"
        case .models: return "Models"
        case .usage: return "Usage"
        case .library: return "Library"
        case .health: return "Health"
        }
    }

    var symbol: String {
        switch self {
        case .cockpit: return "gauge.open.with.lines.needle.33percent"
        case .live: return "dot.radiowaves.left.and.right"
        case .sessions: return "bubble.left.and.text.bubble.right"
        case .workshop: return "hammer"
        case .flock: return "bird"
        case .models: return "cpu"
        case .usage: return "chart.bar.xaxis"
        case .library: return "books.vertical"
        case .health: return "stethoscope"
        }
    }

    var subtitle: String {
        switch self {
        case .cockpit: return "Everything at a glance"
        case .live: return "Start and steer a run"
        case .sessions: return "Read what happened"
        case .workshop: return "Ask Aviary to change"
        case .flock: return "Sub-agent trees"
        case .models: return "Providers and routes"
        case .usage: return "Tokens and cost"
        case .library: return "Skills, prompts, extensions"
        case .health: return "Daemon and processes"
        }
    }
}

/// The application store.
///
/// One observable object rather than several: nearly every view needs the session catalog,
/// the live-session list, and the daemon's state together, and the interesting bugs in a
/// tool like this come from those three disagreeing.
@Observable
@MainActor
final class AppModel {
    // MARK: Configuration

    var home: AgentHome = .default
    var engines: [EngineLocation] = []
    var engine: EngineLocation? {
        didSet {
            guard engine != oldValue else { return }
            let e = engine
            Task { await inspector?.setEngine(e) }
            UserDefaults.standard.set(e?.displayPath, forKey: "aviary.engine")
            Task { await refreshDaemon() }
        }
    }

    var settings: HarnessSettings = .load(home: .default)
    var loginShellEnvironmentLoaded = false

    // MARK: Catalog

    var sessions: [SessionSummary] = []
    var isScanning = false
    var scanProgress: (done: Int, total: Int) = (0, 0)
    var catalogError: String?

    // MARK: Selection & transcript

    var section: Section = .cockpit
    var selectedSessionID: String?
    var transcript: Transcript?
    var transcriptSessionID: String?
    var isLoadingTranscript = false
    var kernelState: KernelState?
    /// Recorded provider payloads for the selected session, when a run of it was recorded.
    var selectedSessionWire: [WireRecord] = []
    /// Which recorded logs belong to which session.
    var wireIndex = WireLog.Index()

    // MARK: Live

    var liveSessions: [LiveSession] = []
    var daemon = DaemonStatus()
    var workers: [WorkerDescriptor] = []
    var tree = AgentTree()
    var lastRefresh: Date?

    // MARK: Models & library

    var modelsConfig: ModelsConfig = .load(home: .default)
    var auth: AuthInfo = .load(home: .default)
    /// Runtime model catalog from the engine — includes built-in providers that never
    /// appear in models.json.
    var runtimeModels: [ModelSpec] = []
    var runtimeModelsError: String?
    var providerTests: [String: ProviderTestResult] = [:]
    var testingProviders: Set<String> = []
    var library = Library()

    // MARK: Analytics

    var analytics = UsageAnalytics()

    // MARK: Runs

    var runs: [LiveRun] = []
    var focusedRunID: UUID?

    // MARK: UI state

    var showCommandPalette = false
    var showInspector = true
    var sessionSearch = ""
    var transcriptSearch = ""
    var hideThinking = false
    var toast: Toast?

    // MARK: Workshop
    //
    // The self-improvement board. Requests you file against Aviary itself, and the
    // long-lived session that services them.

    /// The Aviary checkout. Everything the workshop writes lives under it, so that the
    /// board is reviewable with `git diff` rather than buried in Application Support.
    var repoRoot: URL?
    var board = WorkshopBoard()
    var selectedRequestID: String?
    /// The bottom-right capture panel, available on every screen.
    var capturePanelOpen = false
    var draftTitle = ""
    var draftBody = ""
    var draftKind: WorkshopKind = .change
    var draftIncludesShot = true
    var isSubmitting = false
    /// State captured the instant the panel was asked for, before it existed on screen.
    ///
    /// Held rather than re-read at submit time so the request describes what you were
    /// looking at when you reached for the button — not the compose panel occluding it.
    var pendingContext: WorkshopContext?
    var pendingShot: Data?
    var isCapturingShot = false
    /// The session dedicated to improving Aviary. Remembered across launches.
    var workshopSessionID: String? {
        didSet { UserDefaults.standard.set(workshopSessionID, forKey: "aviary.workshop.session") }
    }
    /// The attached run servicing the board, when Aviary started one.
    var workshopRunID: UUID?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError = false
    }

    private var catalog: SessionCatalog?
    private var inspector: DaemonInspector?
    private var pollTask: Task<Void, Never>?
    private var watcher: SessionWatcher?

    var focusedRun: LiveRun? {
        guard let focusedRunID else { return runs.first }
        return runs.first { $0.id == focusedRunID } ?? runs.first
    }

    // MARK: Lifecycle

    func bootstrap() async {
        // Capture the login shell's environment before anything spawns a subprocess.
        // Without this the engine inherits launchd's environment and every
        // environment-variable credential silently resolves to its own name.
        loginShellEnvironmentLoaded = await ProcessEnvironment.shared.loadFromLoginShell()

        catalog = SessionCatalog(home: home)
        engines = await EngineLocator.discover(
            customPath: UserDefaults.standard.string(forKey: "aviary.customEnginePath"))
        let remembered = UserDefaults.standard.string(forKey: "aviary.engine")
        engine = engines.first { $0.displayPath == remembered } ?? engines.first
        inspector = DaemonInspector(home: home, engine: engine)

        settings = .load(home: home)
        hideThinking = settings.hideThinkingBlock ?? false
        auth = .load(home: home)
        modelsConfig = .load(home: home, auth: auth)

        wireIndex = WireLog.buildIndex()

        repoRoot = EngineLocator.repoRoot()
        workshopSessionID = UserDefaults.standard.string(forKey: "aviary.workshop.session")
        refreshBoard()

        await refreshAll()
        startPolling()
    }

    func refreshAll() async {
        async let a: Void = refreshCatalog()
        async let b: Void = refreshDaemon()
        async let c: Void = refreshRuntimeModels()
        _ = await (a, b, c)
        refreshLibrary()
    }

    func refreshCatalog() async {
        guard let catalog else { return }
        isScanning = true
        let found = await catalog.scan { [weak self] done, total in
            Task { @MainActor in self?.scanProgress = (done, total) }
        }
        sessions = found
        tree = AgentTreeReader.read(home: home)
        analytics = UsageAnalytics.build(from: found)
        isScanning = false
        annotateLiveState()
        lastRefresh = Date()
    }

    func refreshDaemon() async {
        guard let inspector else { return }
        daemon = await inspector.status()
        liveSessions = await inspector.liveSessions()
        workers = await inspector.workers()
        annotateLiveState()
    }

    /// Fold daemon liveness into the catalog rows so a session's list entry knows it is
    /// running. Two sources, one row — this is where they get reconciled.
    private func annotateLiveState() {
        let byID = Dictionary(liveSessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        for i in sessions.indices {
            if let live = byID[sessions[i].id] {
                sessions[i].isLive = true
                sessions[i].isBusy = live.isWorking
                sessions[i].liveOperation = live.activity
            } else if sessions[i].isLive {
                sessions[i].isLive = false
                sessions[i].isBusy = false
                sessions[i].liveOperation = nil
            }
        }
    }

    func refreshRuntimeModels() async {
        guard let engine else { return }
        // A short-lived RPC session is the only way to ask the engine what models it can
        // actually reach: built-in OAuth providers are absent from models.json entirely.
        let session = RPCSession()
        do {
            let stream = try await session.start(
                engine: engine,
                config: RunConfiguration(
                    cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                    persistSession: false))
            // Drain in the background so the pipe never fills.
            Task.detached { for await _ in stream {} }
            runtimeModels = try await session.availableModels()
            runtimeModelsError = nil
            await session.stop()
        } catch {
            runtimeModelsError = error.localizedDescription
            await session.stop()
        }
    }

    func refreshLibrary() {
        let projectRoot = sessions.first.flatMap { $0.cwd.isEmpty ? nil : URL(fileURLWithPath: $0.cwd) }
        let enginePackageRoot: URL? = {
            guard let engine, let cli = engine.leadingArguments.first else { return nil }
            // …/packages/coding-agent/dist/bundle/cli.js → …/packages/coding-agent
            return URL(fileURLWithPath: cli)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }()
        library = Library.discover(
            home: home, settings: settings,
            projectRoot: projectRoot, enginePackageRoot: enginePackageRoot)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = self.liveSessions.contains(where: \.isWorking) || !self.runs.isEmpty
                try? await Task.sleep(nanoseconds: busy ? 3_000_000_000 : 12_000_000_000)
                guard !Task.isCancelled else { return }
                await self.refreshDaemon()
                self.tree = AgentTreeReader.read(home: self.home)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Transcript

    func select(session: SessionSummary) {
        selectedSessionID = session.id
        Task { await loadTranscript(for: session) }
    }

    func loadTranscript(for session: SessionSummary) async {
        isLoadingTranscript = true
        let url = session.fileURL
        let id = session.id
        let parsed = await Task.detached(priority: .userInitiated) {
            SessionParser.parse(fileURL: url)
        }.value
        // A slower load for a session the user has since navigated away from must not
        // clobber the one they are looking at now.
        guard selectedSessionID == id else { return }
        transcript = parsed
        transcriptSessionID = id
        kernelState = KernelState.read(home: home, sessionID: id)
        selectedSessionWire = WireLog.records(forSession: id, index: wireIndex)
        isLoadingTranscript = false

        // Follow the file while it is live.
        watcher?.stop()
        if session.isLive {
            let w = SessionWatcher(url: url)
            w.start { [weak self] in
                Task { @MainActor in
                    guard let self, self.selectedSessionID == id else { return }
                    await self.reloadTranscriptInPlace(url: url, id: id)
                }
            }
            watcher = w
        } else {
            watcher = nil
        }
    }

    private func reloadTranscriptInPlace(url: URL, id: String) async {
        let parsed = await Task.detached(priority: .utility) {
            SessionParser.parse(fileURL: url)
        }.value
        guard selectedSessionID == id else { return }
        transcript = parsed
    }

    func openTranscript(sessionID: String) {
        if let s = sessions.first(where: { $0.id == sessionID }) {
            section = .sessions
            select(session: s)
            return
        }
        // A sub-agent session lives under session-artifacts, not in the flat catalog.
        if let node = tree.allNodes.first(where: { $0.sessionID == sessionID }) {
            Task { await loadChildTranscript(node: node) }
        }
    }

    func loadChildTranscript(node: AgentNode) async {
        isLoadingTranscript = true
        selectedSessionID = node.sessionID
        let url = node.sessionFile
        let parsed = await Task.detached(priority: .userInitiated) {
            SessionParser.parse(fileURL: url)
        }.value
        guard selectedSessionID == node.sessionID else { return }
        transcript = parsed
        transcriptSessionID = node.sessionID
        kernelState = nil
        selectedSessionWire = WireLog.records(forSession: node.sessionID, index: wireIndex)
        isLoadingTranscript = false
    }

    // MARK: Sessions list

    var filteredSessions: [SessionSummary] {
        let q = sessionSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { s in
            s.title.lowercased().contains(q)
                || s.firstPrompt.lowercased().contains(q)
                || s.lastAssistantText.lowercased().contains(q)
                || s.projectName.lowercased().contains(q)
                || (s.model?.lowercased().contains(q) ?? false)
                || (s.provider?.lowercased().contains(q) ?? false)
                || s.id.lowercased().contains(q)
        }
    }

    var selectedSession: SessionSummary? {
        sessions.first { $0.id == selectedSessionID }
    }

    func trashSelectedSession() async {
        guard let catalog, let s = selectedSession else { return }
        do {
            try await catalog.trash(session: s)
            sessions.removeAll { $0.id == s.id }
            selectedSessionID = nil
            transcript = nil
            toast = Toast(message: "Moved “\(s.title.prefix(40))” to the Trash")
        } catch {
            toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    // MARK: Provider testing

    func testProvider(_ provider: ProviderSpec, model: ModelSpec?) async {
        testingProviders.insert(provider.id)
        let result = await ProviderTester.test(provider: provider, model: model)
        providerTests[provider.id] = result
        testingProviders.remove(provider.id)
    }

    /// Rescan recorded logs. Cheap: one line read per file.
    func refreshWireIndex() {
        wireIndex = WireLog.buildIndex()
        if let id = selectedSessionID {
            selectedSessionWire = WireLog.records(forSession: id, index: wireIndex)
        }
    }

    /// Start a run that resumes this session with payload recording on — the way to get a
    /// breakdown for a session that was not recorded the first time.
    func continueWithRecording(_ session: SessionSummary) {
        startRun(
            config: RunConfiguration(
                cwd: session.cwd.isEmpty ? defaultCwd : session.cwd,
                provider: session.provider,
                model: session.model,
                resume: session.id,
                recordPayloads: EngineLocator.wireLogExtension() != nil),
            firstPrompt: nil)
    }

    func reloadModelsConfig() {
        auth = .load(home: home)
        modelsConfig = .load(home: home, auth: auth)
    }

    // MARK: Daemon actions

    func shutdownDaemon(force: Bool) async {
        guard let inspector else { return }
        let result = await inspector.shutdown(force: force)
        toast = Toast(
            message: result?.best.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Shutdown command sent",
            isError: !(result?.ok ?? false))
        await refreshDaemon()
    }

    func repairDaemon() async {
        guard let inspector else { return }
        let result = await inspector.repair()
        toast = Toast(
            message: result?.best.trimmingCharacters(in: .whitespacesAndNewlines) ?? "doctor --fix ran",
            isError: !(result?.ok ?? false))
        await refreshDaemon()
    }

    // MARK: Runs

    func startRun(config: RunConfiguration, firstPrompt: String?) {
        guard let engine else {
            toast = Toast(message: "No engine configured", isError: true)
            return
        }
        let run = LiveRun(engine: engine, config: config)
        runs.append(run)
        focusedRunID = run.id
        section = .live
        Task { await run.start(firstPrompt: firstPrompt) }
    }

    func closeRun(_ run: LiveRun) {
        if run.config.recordPayloads {
            // The log is complete now; make it discoverable from the Sessions tab.
            wireIndex = WireLog.buildIndex()
            if let id = selectedSessionID {
                selectedSessionWire = WireLog.records(forSession: id, index: wireIndex)
            }
        }
        Task { await run.stop() }
        runs.removeAll { $0.id == run.id }
        if focusedRunID == run.id { focusedRunID = runs.last?.id }
    }

    /// A sensible default working directory: the most recent session's, else home.
    var defaultCwd: String {
        sessions.first(where: { !$0.cwd.isEmpty })?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var recentCwds: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in sessions where !s.cwd.isEmpty {
            if seen.insert(s.cwd).inserted { out.append(s.cwd) }
            if out.count >= 8 { break }
        }
        return out
    }

    func show(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
    }
}

// MARK: - A live run

/// One attached agent run: an engine subprocess, its event stream, and the transcript
/// built from it.
@Observable
@MainActor
final class LiveRun: Identifiable {
    let id = UUID()
    let engine: EngineLocation
    var config: RunConfiguration

    var items: [TranscriptItem] = []
    var isStreaming = false
    var isCompacting = false
    var hasExited = false
    var exitCode: Int32?
    var usage = Usage()
    var queuedSteering: [String] = []
    var queuedFollowUps: [String] = []
    var sessionID: String?
    var sessionFile: String?
    var modelLabel: String?
    var thinkingLevel: String?
    var contextTokens: Int?
    var contextWindow: Int?
    var startedAt = Date()
    var errorBanner: String?
    var stderrTail: [String] = []
    var launchCommand = ""
    var title: String = "New run"
    /// Recorded provider payloads, when the run was started with recording on.
    var wireRecords: [WireRecord] = []
    var wireLogURL: URL?

    private let builder = LiveTranscriptBuilder()
    private var session = RPCSession()
    private var pump: Task<Void, Never>?

    init(engine: EngineLocation, config: RunConfiguration) {
        self.engine = engine
        var config = config
        if config.recordPayloads {
            // The path has to be decided here, where the run's identity exists.
            let url = WireLog.path(forRun: id)
            config.wireLogPath = url.path
            self.wireLogURL = url
        }
        self.config = config
        self.modelLabel = [config.provider, config.model].compactMap { $0 }.joined(separator: "/")
        self.thinkingLevel = config.thinkingLevel
    }

    var projectName: String {
        URL(fileURLWithPath: config.cwd).lastPathComponent
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    var contextShare: Double? {
        guard let t = contextTokens else { return nil }
        return Fmt.contextShare(used: t, window: contextWindow)
    }

    func start(firstPrompt: String?) async {
        do {
            let stream = try await session.start(engine: engine, config: config)
            launchCommand = await session.launchCommand
            pump = Task { [weak self] in
                for await message in stream {
                    await self?.ingest(message)
                }
                await self?.markExited()
            }
            await refreshState()
            if let firstPrompt, !firstPrompt.isEmpty {
                title = String(firstPrompt.prefix(60))
                builder.appendLocalUserMessage(firstPrompt)
                sync()
                try await session.prompt(firstPrompt)
            }
        } catch {
            errorBanner = error.localizedDescription
            hasExited = true
        }
    }

    private func ingest(_ message: RPCMessage) {
        if case .stderr(let text) = message {
            stderrTail.append(text)
            if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
        }
        if case .exited(let code, _) = message {
            exitCode = code
            hasExited = true
        }
        if builder.apply(message) { sync() }

        // State-bearing events are worth a follow-up query: the engine's own view of the
        // session (model, context usage) is authoritative and cheap to ask for.
        if case .event(let type, _) = message, ["agent_end", "compaction_end"].contains(type) {
            Task { await refreshState() }
        }
        // The extension appends on every provider request, so a turn boundary is the right
        // moment to pick up new records.
        if case .event(let type, _) = message,
           ["message_end", "agent_end"].contains(type)
        {
            refreshWireLog()
        }
    }

    private func sync() {
        items = builder.items
        isStreaming = builder.isStreaming
        isCompacting = builder.isCompacting
        usage = builder.usage
        queuedSteering = builder.queued.steering
        queuedFollowUps = builder.queued.followUps
    }

    private func markExited() {
        hasExited = true
        isStreaming = false
        sync()
    }

    /// Re-read the recorded payloads. Cheap: a handful of records per run.
    func refreshWireLog() {
        guard let url = wireLogURL else { return }
        wireRecords = WireLog.read(url: url)
    }

    /// The most recent request payload, decomposed.
    var latestAnalysis: PayloadAnalysis? {
        guard let payload = wireRecords.last(where: { $0.kind == .request })?.payload else {
            return nil
        }
        return WireLog.analyse(payload: payload)
    }

    /// Input tokens the provider actually charged for the matching turn, so the breakdown
    /// can report real numbers instead of only estimates.
    var lastInputTokens: Int? {
        let inputs = items.compactMap { $0.usage?.input }.filter { $0 > 0 }
        return inputs.last
    }

    func refreshState() async {
        guard !hasExited else { return }
        if let state = try? await session.state() {
            sessionID = state["sessionId"]?.stringValue ?? sessionID
            sessionFile = state["sessionFile"]?.stringValue ?? sessionFile
            if let m = state["model"] {
                let p = m["provider"]?.stringValue
                let id = m["id"]?.stringValue
                modelLabel = [p, id].compactMap { $0 }.joined(separator: "/")
                contextWindow = m["contextWindow"]?.intValue ?? contextWindow
            }
            thinkingLevel = state["thinkingLevel"]?.stringValue ?? thinkingLevel
        }
        if let stats = try? await session.stats() {
            contextTokens = stats.path("contextUsage.tokens")?.intValue ?? contextTokens
            contextWindow = stats.path("contextUsage.contextWindow")?.intValue ?? contextWindow
        }
    }

    func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if title == "New run" { title = String(text.prefix(60)) }
        builder.appendLocalUserMessage(text)
        sync()
        do {
            // While the agent is running, a plain prompt is rejected — it has to be
            // explicitly queued. Steering is the useful default: it lands after the
            // current tool calls finish, before the next model call.
            if isStreaming {
                try await session.prompt(text, streamingBehavior: "steer")
            } else {
                try await session.prompt(text)
            }
        } catch {
            builder.appendNote("Could not send: \(error.localizedDescription)")
            sync()
        }
    }

    func queueFollowUp(_ text: String) async {
        do { try await session.followUp(text) } catch {
            builder.appendNote("Could not queue: \(error.localizedDescription)")
            sync()
        }
    }

    func abort() {
        Task { await session.abort() }
    }

    func compact() async {
        do { try await session.compact() } catch {
            builder.appendNote("Compaction failed: \(error.localizedDescription)")
            sync()
        }
    }

    func setModel(provider: String, model: String) async {
        do {
            try await session.setModel(provider: provider, model: model)
            modelLabel = "\(provider)/\(model)"
            await refreshState()
        } catch {
            builder.appendNote("Could not switch model: \(error.localizedDescription)")
            sync()
        }
    }

    func setThinking(_ level: String) async {
        do {
            try await session.setThinkingLevel(level)
            thinkingLevel = level
        } catch {
            builder.appendNote("Could not set thinking level: \(error.localizedDescription)")
            sync()
        }
    }

    func rename(_ name: String) async {
        try? await session.setSessionName(name)
        title = name
    }

    func stop() async {
        pump?.cancel()
        await session.stop()
        hasExited = true
    }
}
