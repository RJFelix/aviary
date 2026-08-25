import SwiftUI
import Observation
import AviaryCore

/// Top-level navigation destinations.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case cockpit, live, sessions, workshop, flock, models, usage, library, health

    /// What the sidebar offers.
    ///
    /// Flock is kept and not shown. It drew the harness's world — a forest of sub-agent
    /// sessions held by a supervisor — and that world is gone; the shape of the idea is worth
    /// keeping, but it needs to describe what the in-house engine actually does before it
    /// earns a place back. Hiding rather than deleting, because the argument for it was never
    /// wrong, only its subject.
    static var visible: [Section] { allCases.filter { $0 != .flock } }

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
    /// The harness build Aviary used to drive.
    ///
    /// Kept only so the Health screen can still say what it found on disk, and so an existing
    /// checkout is recognised. Nothing runs through it any more.
    var engine: EngineLocation? {
        didSet {
            guard engine != oldValue else { return }
            UserDefaults.standard.set(engine?.displayPath, forKey: "aviary.engine")
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
    /// The focused session remains the transcript shown in the center pane. The set is the
    /// List's native macOS multi-selection, used for batch actions in the sidebar.
    var selectedSessionID: String?
    var selectedSessionIDs: Set<String> = []
    var isTrashingSessions = false
    var transcript: Transcript?
    var transcriptSessionID: String?
    var isLoadingTranscript = false
    var kernelState: KernelState?
    /// Recorded provider payloads for the selected session, when a run of it was recorded.
    var selectedSessionWire: [WireRecord] = []
    /// Which recorded logs belong to which session.
    var wireIndex = WireLog.Index()

    // MARK: Live

    // The harness had a supervisor process holding sessions, a pool of kernels and a lease
    // per session, and this is where their state used to live. Aviary's own engine runs its
    // agents in-process and its interpreters in a runtime host it owns, so there is nothing
    // to inspect and nothing to reconcile — a run is live because it is in `runs`.
    var tree = AgentTree()
    var lastRefresh: Date?

    // MARK: Models & library

    var modelsConfig: ModelsConfig = .load(home: .default)
    var auth: AuthInfo = .load(home: .default)
    /// Runtime model catalog from the engine — includes built-in providers that never
    /// appear in models.json.
    var runtimeModels: [ModelSpec] = []
    var runtimeModelsError: String?
    /// The reachable model catalogue, assembled locally rather than asked of the engine.
    var modelCatalog = ModelCatalog()
    let modelPreferencesStore = ModelPreferencesStore()
    var modelPreferences = ModelPreferences()
    /// What a picker offers: reachable, enabled, in your order.
    var pickerModels: [ModelSpec] { modelCatalog.enabled }
    var providerTests: [String: ProviderTestResult] = [:]
    var testingProviders: Set<String> = []
    /// When this bundle was built, and how far the checkout has moved since.
    let buildStamp = BuildStamp.fromBundle()
    var commitsBehind: Int?
    var library = Library()
    /// MCP servers as configured, read from settings.json with the library.
    var mcpServers: [MCPConfiguration.Server] = []
    /// What probing them found, by server name. Empty until somebody asks.
    var mcpProbes: [String: MCPProbe] = [:]
    var isProbingMCP = false
    /// What the agent finds already bound in its Python namespace, and which skills reference
    /// each name. The catalogue is static; the index is read off the skills on disk.
    var builtinIndex = SkillBuiltinIndex()
    /// How often each name was actually reached for, read back out of the trajectories. Empty
    /// until the first scan finishes, which is why every reader treats zero as "not yet known"
    /// only in combination with `libraryUsageScanned`.
    var libraryUsage = LibraryUsage()
    var libraryUsageScanned = false
    private var libraryUsageTask: Task<Void, Never>?
    /// Whether Aviary's own runtime can start, checked rather than assumed.
    var runtimeProbes: [RuntimeProbe] = []

    // MARK: Analytics

    var analytics = UsageAnalytics()

    // MARK: Runs

    var runs: [LiveRun] = []

    /// Which engine a new run uses.
    ///
    /// Three, not two, and the third is a different kind of thing from the first two. Harness
    /// and in-house are both *Aviary's loop over a provider*; Claude Code is somebody else's
    /// loop over Aviary's kernel. Modelling that as a third choice in the same picker is
    /// honest — it is the decision you actually make when starting a run — as long as the
    /// picker says what the difference is.
    enum Engine: String, CaseIterable, Identifiable {
        case inHouse
        case claudeCode

        public var id: String { rawValue }

        var label: String {
            switch self {
            case .inHouse: return "In-house"
            case .claudeCode: return "Claude Code"
            }
        }
    }

    /// Remembered, because it is a preference rather than a per-run decision once you have
    /// picked a side.
    ///
    /// Stored under a new key rather than migrating the old boolean: somebody who had the
    /// in-house engine selected keeps it, because `Engine(rawValue:)` falls back through the
    /// old flag when the new key is absent.
    var engineChoice: Engine = {
        // `aviary.engineChoice`, not `aviary.engine` — that key is already taken by the
        // remembered engine *path*, and writing this over it would leave `bootstrap()` unable
        // to match the saved engine and silently falling back to the first one discovered.
        if let raw = UserDefaults.standard.string(forKey: "aviary.engineChoice"),
           let choice = Engine(rawValue: raw) {
            return choice
        }
        // In-house is the default now. The harness fork is on its way out — it is 457MB of
        // vendored Node whose remaining advantages over Aviary's own loop have been absorbed
        // one at a time, and a default that still pointed at it meant the workshop agent was
        // improving Aviary using somebody else's agent.
        return .inHouse
    }() {
        didSet { UserDefaults.standard.set(engineChoice.rawValue, forKey: "aviary.engineChoice") }
    }

    /// Kept as a derived value so the several places that only care "is this the harness or
    /// not" need no change. A Claude-Code run is not the harness either.
    /// Retained as a name several places still read. There is no other kind of engine now.
    var preferInHouseEngine: Bool { true }
    var focusedRunID: UUID?
    /// Which Claude model a driven run asks for. An alias rather than a full id, because that
    /// is what Claude Code's `--model` takes and what its own docs use.
    var claudeCodeModel: String = UserDefaults.standard.string(forKey: "aviary.claudeCodeModel")
        ?? "sonnet"
    {
        didSet { UserDefaults.standard.set(claudeCodeModel, forKey: "aviary.claudeCodeModel") }
    }
    /// Claude Code's login, read once at bootstrap. Nil until checked, and nil also means "no
    /// binary found" — which is a different fact from "not signed in", so `Auth.loggedIn`
    /// carries that one.
    var claudeCodeAuth: ClaudeCode.Auth?

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
    /// The Workshop's full-size request editor. The global capture panel remains the quick
    /// way to file an observation from any screen; this is the place to write and revise it.
    enum WorkshopEditorMode: Identifiable {
        case new
        case edit(String)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let id): return "edit-\(id)"
            }
        }
    }
    var workshopEditor: WorkshopEditorMode?
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

    /// Rebuilding and relaunching Aviary when the workshop has changed Aviary.
    let reloader = Reloader()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError = false
    }

    private var catalog: SessionCatalog?
    private var pollTask: Task<Void, Never>?
    private var watcher: SessionWatcher?

    var focusedRun: LiveRun? {
        guard let focusedRunID else { return runs.first }
        return runs.first { $0.id == focusedRunID } ?? runs.first
    }

    // MARK: Lifecycle

    /// True when this process is a throwaway window for looking at one screen.
    ///
    /// Not a display mode — a *startup* mode. The full `bootstrap` costs about seven and a half
    /// seconds before anything is on screen, and almost none of it is work a UI edit needs:
    /// capturing the login shell's environment (`zsh -ilc`), scanning every transcript on disk,
    /// discovering engines, probing the daemon, resolving every provider's key expression (one
    /// of which shells out), starting Python hosts to read their capabilities, and asking
    /// `claude auth status`. A preview skips all of it and opens in well under a second, which
    /// is the difference between a feedback loop and a wait.
    private(set) var isPreview = false

    /// Enough state to draw a screen, and nothing that costs a subprocess.
    func bootstrapPreview(section: Section) {
        isPreview = true
        self.section = section
        // File reads only. Every one of these is cheap and several screens look empty without
        // them, which would make the preview lie about layout.
        settings = .load(home: home)
        hideThinking = settings.hideThinkingBlock ?? false
        auth = .load(home: home)
        modelsConfig = .load(home: home, auth: auth)
        modelPreferences = modelPreferencesStore.load()
        repoRoot = EngineLocator.repoRoot()
        board = WorkshopBoard.load(repoRoot: repoRoot)
        // Built with no credentials resolved: the catalogue's *shape* is what a layout pass
        // needs, and resolving keys is the single most expensive thing bootstrap does.
        modelCatalog = ModelCatalogBuilder.build(
            config: modelsConfig, auth: auth, credentialed: [], preferences: modelPreferences)
        runtimeModels = modelCatalog.models
        // The catalogue is read lazily by the Sessions screen, so a preview of it shows the
        // real list without paying for a full rescan up front.
        catalog = SessionCatalog(home: home)
        // Printed because the whole justification for this mode is that it is fast, and a
        // number you can watch is how you notice when it stops being.
        let ms = Int(Date().timeIntervalSince(AviaryApp.launchedAt) * 1000)
        FileHandle.standardError.write(Data("preview ready in \(ms)ms\n".utf8))
    }

    func bootstrap() async {
        // Capture the login shell's environment before anything spawns a subprocess.
        // Without this the engine inherits launchd's environment and every
        // environment-variable credential silently resolves to its own name.
        loginShellEnvironmentLoaded = await ProcessEnvironment.shared.loadFromLoginShell()

        catalog = SessionCatalog(home: home)
        modelPreferences = modelPreferencesStore.load()
        engines = await EngineLocator.discover(
            customPath: UserDefaults.standard.string(forKey: "aviary.customEnginePath"))
        let remembered = UserDefaults.standard.string(forKey: "aviary.engine")
        engine = engines.first { $0.displayPath == remembered } ?? engines.first

        settings = .load(home: home)
        hideThinking = settings.hideThinkingBlock ?? false
        auth = .load(home: home)
        modelsConfig = .load(home: home, auth: auth)

        wireIndex = WireLog.buildIndex()

        // Read once here rather than per-run: it shells out to `claude auth status`, and the
        // engine picker needs it before a run exists to ask.
        claudeCodeAuth = await ClaudeCode.authStatus()

        repoRoot = EngineLocator.repoRoot()
        workshopSessionID = UserDefaults.standard.string(forKey: "aviary.workshop.session")
        board = WorkshopBoard.load(repoRoot: repoRoot)
        // Baselined *before* watching starts, so requests that were already done when this
        // window opened do not read as fresh completions and rebuild the app on launch.
        reloader.begin(repoRoot: repoRoot, board: board) { [weak self] in
            self?.refreshBoard()
        }
        reloader.requestRelaunch = { [weak self] in self?.reloadNow() }
        restoreAfterReload()

        await refreshAll()
        startPolling()
    }

    func refreshAll() async {
        async let a: Void = refreshCatalog()
        async let c: Void = refreshRuntimeModels()
        async let d: Void = refreshRuntimeProbes()
        _ = await (a, c, d)
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

    /// Mark the catalog rows that belong to a run this process is holding.
    ///
    /// One source now, so there is nothing to reconcile: a session is live when Aviary is
    /// running it. The harness needed two — an append-only daemon ledger and a writer-owned
    /// artifact — and their disagreements were a standing source of wrong rows.
    private func annotateLiveState() {
        let running = Set(runs.filter { !$0.hasExited }.compactMap(\.sessionID))
        let busy = Set(runs.filter { $0.isStreaming }.compactMap(\.sessionID))
        for i in sessions.indices {
            let isLive = running.contains(sessions[i].id)
            sessions[i].isLive = isLive
            sessions[i].isBusy = isLive && busy.contains(sessions[i].id)
            if !isLive { sessions[i].liveOperation = nil }
        }
    }

    /// Work out which models are reachable, without booting the engine.
    ///
    /// This used to open a short-lived RPC session, because built-in OAuth providers are absent
    /// from `models.json` and the harness was the only thing that knew about them. Aviary now
    /// has its own built-in catalogue, so the answer can be assembled locally — which removes a
    /// harness dependency from app startup and stops every launch paying for a Node boot.
    ///
    /// If an Anthropic subscription login is ever added, it needs a `BuiltInProviders` entry
    /// here too, or its models will be missing rather than merely unreachable.
    func refreshRuntimeModels() async {
        var credentialed = await ModelCatalogBuilder.credentialedProviders(
            config: modelsConfig, auth: auth)
        // Claude Code's credential lives in the `claude` binary's own keychain entry, which
        // Aviary cannot read and should not try to — so reachability is what `claude auth
        // status` says, resolved once at bootstrap.
        if claudeCodeAuth?.loggedIn == true { credentialed.insert("claude-code") }
        modelCatalog = ModelCatalogBuilder.build(
            config: modelsConfig, auth: auth, credentialed: credentialed,
            preferences: modelPreferences)
        runtimeModels = modelCatalog.models
        runtimeModelsError = modelCatalog.models.isEmpty
            ? (modelsConfig.exists
                ? "No provider has working credentials. Check the API keys in models.json."
                : "No models.json, and no built-in provider is logged in.")
            : nil
    }

    /// Re-apply preferences without re-resolving credentials.
    ///
    /// Reordering or disabling a model must not run a `!command` API-key expression again — on
    /// this machine one of them shells out through `zsh -ic`, and paying that on every drag
    /// would make the list feel broken.
    private func reapplyModelPreferences() {
        modelCatalog = ModelCatalogBuilder.build(
            config: modelsConfig, auth: auth,
            credentialed: Set(modelCatalog.reachable.map(\.id)),
            preferences: modelPreferences)
        runtimeModels = modelCatalog.models
    }

    func setModelEnabled(_ enabled: Bool, for model: ModelSpec) {
        modelPreferences.setEnabled(enabled, for: model)
        modelPreferencesStore.save(modelPreferences)
        reapplyModelPreferences()
    }

    /// Pin an explicit order for a list of models, as shown to the person doing the dragging.
    func setModelOrder(_ models: [ModelSpec]) {
        modelPreferences.pin(models)
        modelPreferencesStore.save(modelPreferences)
        reapplyModelPreferences()
    }

    /// Forget every ordering and re-enable everything.
    func resetModelPreferences() {
        modelPreferences = ModelPreferences()
        modelPreferencesStore.save(modelPreferences)
        reapplyModelPreferences()
    }

    /// Check both bundled hosts. Cheap — each starts, answers, and exits.
    func refreshRuntimeProbes() async {
        let root = EngineLocator.repoRoot()
        var found: [RuntimeProbe] = []
        for variant in ["python3", "python3-shared"] {
            found.append(await RuntimeProbe.probe(repoRoot: root, variant: variant))
        }
        runtimeProbes = found
    }

    func refreshLibrary() {
        let projectRoot = sessions.first.flatMap { $0.cwd.isEmpty ? nil : URL(fileURLWithPath: $0.cwd) }
        library = Library.discover(
            home: home, settings: settings,
            projectRoot: projectRoot, enginePackageRoot: nil)
        // Cheap, and only meaningful once a repo is known. Refreshed with the library rather
        // than polled: the answer only changes when somebody commits.
        if let root = EngineLocator.repoRoot() {
            commitsBehind = BuildStamp.commitsSinceBuild(repoRoot: root, stamp: buildStamp)
        }
        mcpServers = MCPConfiguration.load(home: home)
        let names = Builtins.all(.reference).map(\.name)
        builtinIndex = SkillBuiltinIndex.build(skills: library.skills, builtins: names)
        rescanLibraryUsage(skills: library.skills, builtins: names)
    }

    /// Start each configured MCP server, read what it offers, and stop it again.
    ///
    /// A deliberate button rather than part of the library refresh. Starting a server means
    /// spawning somebody else's program — commonly an `npx` invocation that will download a
    /// package the first time — and doing that on every window refresh would be rude to the
    /// machine and to whatever the server talks to.
    func probeMCPServers() async {
        guard !isProbingMCP else { return }
        isProbingMCP = true
        defer { isProbingMCP = false }
        for server in mcpServers where server.enabled {
            let client = MCPClient(
                name: server.name, executable: server.command, arguments: server.arguments,
                environment: server.environment)
            do {
                let tools = try await client.start(timeout: 30)
                mcpProbes[server.name] = MCPProbe(
                    era: await client.era?.label,
                    serverInfo: await client.serverInfo,
                    tools: tools.map(\.qualifiedName).sorted(),
                    error: nil, diagnostics: "")
            } catch {
                mcpProbes[server.name] = MCPProbe(
                    era: nil, serverInfo: nil, tools: [],
                    error: error.localizedDescription,
                    diagnostics: String((await client.diagnostics).suffix(600)))
            }
            await client.stop()
        }
    }

    /// Read every transcript and count what got called.
    ///
    /// Off the main actor and cancel-the-previous, because it walks the whole corpus — ~0.4s
    /// over 18 transcripts today — and a Library refresh should never be the thing that makes
    /// the window drop frames.
    private func rescanLibraryUsage(skills: [SkillEntry], builtins: [String]) {
        libraryUsageTask?.cancel()
        let home = self.home
        libraryUsageTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                LibraryUsage.scan(home: home, builtins: builtins, skills: skills)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.libraryUsage = scanned
                self?.libraryUsageScanned = true
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let busy = !self.runs.isEmpty
                try? await Task.sleep(nanoseconds: busy ? 3_000_000_000 : 12_000_000_000)
                guard !Task.isCancelled else { return }
                self.annotateLiveState()
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
        selectedSessionIDs = [session.id]
        selectedSessionID = session.id
        Task { await loadTranscript(for: session) }
    }

    /// Adopt the native List selection without conflating every selected row with the one
    /// whose transcript is open. If a single row was newly added, make that row the focus;
    /// otherwise keep the current transcript as long as it remains selected.
    func setSelectedSessions(_ ids: Set<String>) {
        let known = Set(sessions.map(\.id))
        let selection = ids.intersection(known)
        let added = selection.subtracting(selectedSessionIDs)
        selectedSessionIDs = selection

        let focus: String? = {
            if added.count == 1 { return added.first }
            if let current = selectedSessionID, selection.contains(current) { return current }
            return sessions.first(where: { selection.contains($0.id) })?.id
        }()
        guard focus != selectedSessionID else { return }
        selectedSessionID = focus
        selectedItemForSessionSelectionChanged()
    }

    /// Clear the detail state when the List no longer has a focused session.
    private func selectedItemForSessionSelectionChanged() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id })
        else {
            transcript = nil
            transcriptSessionID = nil
            kernelState = nil
            selectedSessionWire = []
            return
        }
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

    var selectedSessions: [SessionSummary] {
        sessions.filter { selectedSessionIDs.contains($0.id) }
    }

    /// Batch deletion deliberately shares the single-item Trash path. It moves each transcript
    /// and its artifacts to macOS Trash, never unlinks history, and refuses a mixed selection
    /// containing a live session instead of quietly deleting only some of it.
    func trashSelectedSessions() async {
        guard let catalog, !isTrashingSessions else { return }
        let targets = selectedSessions
        guard !targets.isEmpty else { return }
        guard !targets.contains(where: \.isLive) else {
            show("Stop or deselect live sessions before moving the selection to the Trash.", isError: true)
            return
        }

        isTrashingSessions = true
        defer { isTrashingSessions = false }
        let result = await catalog.trash(sessions: targets)
        let removed = result.trashedIDs
        guard !removed.isEmpty else {
            toast = Toast(
                message: result.failures.values.joined(separator: "\n"), isError: true)
            return
        }

        sessions.removeAll { removed.contains($0.id) }
        selectedSessionIDs.subtract(removed)
        if let focused = selectedSessionID, removed.contains(focused) {
            selectedSessionID = sessions.first(where: { selectedSessionIDs.contains($0.id) })?.id
            selectedItemForSessionSelectionChanged()
        }
        let count = removed.count
        let message = count == 1
            ? "Moved 1 session to the Trash"
            : "Moved \(count) sessions to the Trash"
        toast = Toast(
            message: result.failures.isEmpty
                ? message
                : message + "; \(result.failures.count) could not be moved",
            isError: !result.failures.isEmpty)
    }

    // MARK: Provider testing

    /// Send one throwaway completion and record what came back. Nothing else.
    ///
    /// A test completion is a diagnostic: it must not become a selection. Only
    /// `testingProviders` and `providerTests` may be touched here, and `ProviderTester` writes
    /// no file — there is a test pinning that, because this looked violated once. Sending a
    /// test to the LiteLLM gateway appeared to move the workshop agent onto LiteLLM's first
    /// model; in fact both sides independently defaulted to the same model (the test button
    /// takes `provider.models.first`, and the workshop agent named no model at all, which
    /// `AgentCLI.resolve` reads as the first model of the first provider in models.json). The
    /// coincidence is gone — see `startWorkshopRun` — and this stays diagnostic-only.
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
        // On the in-house engine recording is native, so it needs no extension to be present.
        continueSession(
            session,
            recordPayloads: preferInHouseEngine || EngineLocator.wireLogExtension() != nil)
    }

    func reloadModelsConfig() {
        auth = .load(home: home)
        modelsConfig = .load(home: home, auth: auth)
    }

    // MARK: Daemon actions

// MARK: Runs

    /// Start an in-house run: Aviary's own loop, its own provider client, its own runtime
    /// host. No harness process and no Node.
    /// Runs Aviary is holding, for an agent asking who else is here.
    ///
    /// Exited runs are excluded: a message to something that has stopped would be accepted and
    /// never read, which is worse than being refused.
    func peerRuns(excluding sessionID: String) -> [LiveRun] {
        runs.filter { !$0.hasExited && $0.sessionID != sessionID }
    }

    /// Deliver a message from one run into another.
    ///
    /// Matched on session id first, then on an exact title, because a title is what a person
    /// sees and an id is what a transcript records. An ambiguous title is refused rather than
    /// guessed — delivering to the wrong agent is silent and unrecoverable.
    func deliverPeerMessage(
        to reference: String, text: String, from sessionID: String
    ) async -> (session: String, error: String?) {
        let candidates = peerRuns(excluding: sessionID)
        guard !candidates.isEmpty else {
            return ("", "No other run is open.")
        }
        let byID = candidates.filter { $0.sessionID == reference }
        let byTitle = candidates.filter { $0.title == reference }
        let matches = byID.isEmpty ? byTitle : byID
        guard let target = matches.first else {
            let names = candidates.map { $0.sessionID ?? $0.title }.joined(separator: ", ")
            return ("", "No run matches '\(reference)'. Open runs: \(names).")
        }
        guard matches.count == 1 else {
            return ("", "'\(reference)' matches \(matches.count) runs. Use a session id.")
        }
        if target.isClaudeCode {
            return ("", "\(target.title) is driven by Claude Code, which owns its turn "
                + "boundary and will not accept an injected message.")
        }
        let from = runs.first { $0.sessionID == sessionID }?.title ?? "another agent"
        await target.receive(text: text, from: from)
        return (target.sessionID ?? target.title, nil)
    }

    /// Resolve a picked model the same way a launch does, then hand it to the run.
    ///
    /// One resolver, deliberately: a switch that reached a client a launch would not have is
    /// exactly the seam the Codex 404 lived in.
    func switchModel(run: LiveRun, provider: String, model: String) async {
        guard let resolved = AgentCLI.resolve("\(provider)/\(model)", in: modelsConfig) else {
            toast = Toast(
                message: "No configured provider serves \(provider)/\(model).", isError: true)
            return
        }
        await run.setModel(resolved: resolved)
    }

        func startInHouseRun(
        cwd: String, providerID: String?, modelID: String?, prompt: String,
        recordPayloads: Bool = false, resume: String? = nil, title: String? = nil
    ) {
        guard let (providerSpec, model) = AgentCLI.resolve(
            [providerID, modelID].compactMap { $0 }.joined(separator: "/"),
            in: modelsConfig) ?? AgentCLI.resolve(modelID, in: modelsConfig)
        else {
            toast = Toast(message: "No configured provider serves that model.", isError: true)
            return
        }
        let run = LiveRun(
            inHouse: InHouseDriver(
                home: home, cwd: cwd, model: model, providerSpec: providerSpec,
                recordPayloads: recordPayloads, resume: resume,
                peerDelegate: PeerBridge(model: self)),
            cwd: cwd, modelLabel: model.qualifiedID)
        if let title { run.title = title }
        runs.append(run)
        focusedRunID = run.id
        section = .live
        run.startInHouse(prompt: prompt)
    }

    /// Start a Claude-Code-driven run: Claude Code's loop, Aviary's kernel as its only tool.
    ///
    /// No provider or model resolution, because there is no provider here — Claude Code holds
    /// the credential and picks the route. The model is a Claude Code alias (`sonnet`, `opus`,
    /// `haiku`), which is why it is a plain string rather than a `ModelSpec`.
    func startClaudeCodeRun(
        cwd: String, model: String, effort: String?, prompt: String, title: String? = nil
    ) {
        // Remembered for the next run, and for the places that start one without a sheet —
        // the workshop launcher and `continueSession`.
        claudeCodeModel = model
        let run = LiveRun(
            claudeCode: ClaudeCodeDriver(home: home, cwd: cwd, model: model, effort: effort),
            cwd: cwd, modelLabel: "claude-code/\(model)")
        if let title { run.title = title }
        runs.append(run)
        focusedRunID = run.id
        section = .live
        run.startClaudeCode(prompt: prompt)
    }

    /// Continue an existing session on whichever engine is selected.
    ///
    /// One entry point for all three "Continue" affordances, so the engine picker governs
    /// resume too. They each used to build a harness `RunConfiguration` directly, which is why
    /// resume was harness-only regardless of what the picker said.
    func continueSession(_ s: SessionSummary, recordPayloads: Bool = false) {
        let cwd = s.cwd.isEmpty ? defaultCwd : s.cwd
        if engineChoice == .claudeCode {
            // Claude Code holds its own history and will not accept a prepared one, so
            // "continue" here means a new driven session in the same directory rather than a
            // resumed conversation. Said out loud rather than silently doing something else.
            toast = Toast(
                message: "Claude Code keeps its own history, so this starts a fresh driven "
                    + "session in the same directory.",
                isError: false)
            startClaudeCodeRun(
                cwd: cwd, model: claudeCodeModel, effort: nil, prompt: "", title: s.title)
            return
        }
        startInHouseRun(
            cwd: cwd, providerID: s.provider, modelID: s.model, prompt: "",
            recordPayloads: recordPayloads, resume: s.id, title: s.title)
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
/// Hands an agent the app's view of what else is running.
///
/// A separate type rather than a conformance on `AppModel`, because `PeerDelegate` is
/// `Sendable` and reached from the runtime's callback thread, while `AppModel` is main-actor.
/// The hop is explicit here instead of being scattered through the delegate methods.
struct PeerBridge: Agent.PeerDelegate {
    let model: AppModel

    func peers(excluding sessionID: String) async -> [Agent.Peer] {
        await MainActor.run {
            model.peerRuns(excluding: sessionID).map { run in
                Agent.Peer(
                    session: run.sessionID ?? "",
                    title: run.title,
                    model: run.modelLabel ?? "unknown",
                    working: run.isStreaming,
                    engine: run.isClaudeCode ? "claude-code" : "in-house")
            }
            .filter { !$0.session.isEmpty }
        }
    }

    func deliver(
        to peer: String, text: String, from sessionID: String
    ) async -> (session: String, error: String?) {
        await model.deliverPeerMessage(to: peer, text: text, from: sessionID)
    }
}

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

    /// One type with two backends rather than two types, because every view that renders a
    /// run — the transcript, the token panel, the sidebar row — should not have to know which
    /// engine produced it. That is the same reason the file format is shared.
    private(set) var inHouse: InHouseDriver?
    var isInHouse: Bool { inHouse != nil }

    /// Set when Claude Code is driving this run instead of Aviary.
    private(set) var claudeCode: ClaudeCodeDriver?
    var isClaudeCode: Bool { claudeCode != nil }

    init(inHouse driver: InHouseDriver, cwd: String, modelLabel: String) {
        self.engine = EngineLocation(
            kind: .fork, path: "aviary", version: "in-house",
            note: "Aviary's own agent loop")
        self.config = RunConfiguration(cwd: cwd)
        self.inHouse = driver
        self.modelLabel = modelLabel
        self.title = "New run"
    }

    init(claudeCode driver: ClaudeCodeDriver, cwd: String, modelLabel: String) {
        self.engine = EngineLocation(
            kind: .fork, path: "claude", version: "driven",
            note: "Claude Code, with Aviary's kernel as its tool")
        self.config = RunConfiguration(cwd: cwd)
        self.claudeCode = driver
        self.modelLabel = modelLabel
        self.title = "New run"
    }

    /// Publish a value only when it actually differs.
    ///
    /// `@Observable` notifies on *assignment*, not on change. The mirror below copies the
    /// driver's state every 250ms, so seven unconditional assignments meant every view reading
    /// a run — the transcript, the token panel, the options menu — was invalidated four times
    /// a second for as long as the run existed, whether or not anything had happened.
    ///
    /// That is what tore down an open NSMenu: AppKit answers a rebuilt menu by dismissing the
    /// submenu and dropping the highlight on its parent row. Shielding the menu with
    /// `EquatableView` was not enough, because the invalidation is upstream of it.
    private func publish<T: Equatable>(_ value: T, to keyPath: ReferenceWritableKeyPath<LiveRun, T>) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func startClaudeCode(prompt: String) {
        guard let claudeCode else { return }
        if !prompt.isEmpty { title = String(prompt.prefix(60)) }
        claudeCode.start(prompt: prompt)
        // Mirrored onto this run exactly as the in-house driver is, so every view that reads
        // `items`, `isStreaming` and `usage` keeps working without knowing which engine — the
        // same reason all three write one transcript format.
        mirror = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.publish(claudeCode.items, to: \.items)
                self.publish(claudeCode.isStreaming, to: \.isStreaming)
                self.publish(claudeCode.hasExited, to: \.hasExited)
                self.publish(claudeCode.usage, to: \.usage)
                self.publish(claudeCode.sessionID, to: \.sessionID)
                self.publish(claudeCode.sessionFile?.path, to: \.sessionFile)
                self.publish(claudeCode.errorBanner, to: \.errorBanner)
                if claudeCode.hasExited { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func startInHouse(prompt: String) {
        guard let inHouse else { return }
        if !prompt.isEmpty { title = String(prompt.prefix(60)) }
        inHouse.start(prompt: prompt)
        // Mirror the driver's observable state onto this run, so views that already read
        // `items`, `isStreaming` and `usage` keep working untouched.
        mirror = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.publish(inHouse.items, to: \.items)
                self.publish(inHouse.isStreaming, to: \.isStreaming)
                self.publish(inHouse.hasExited, to: \.hasExited)
                self.publish(inHouse.usage, to: \.usage)
                self.publish(inHouse.sessionID, to: \.sessionID)
                self.publish(inHouse.sessionFile?.path, to: \.sessionFile)
                self.publish(inHouse.errorBanner, to: \.errorBanner)
                if let label = inHouse.modelLabel { self.publish(label, to: \.modelLabel) }
                // Only stop mirroring once the run is genuinely finished. Idle-between-prompts
                // is not finished — the interpreter and the conversation are still alive.
                if inHouse.hasExited { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private var mirror: Task<Void, Never>?

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

    func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let claudeCode {
            guard claudeCode.acceptsFollowUps else {
                builder.appendNote("The run is still starting — try again in a moment.")
                sync()
                return
            }
            // No steering. Claude Code owns the turn boundary and will not take an injection
            // mid-turn, so a message sent now would either be lost or arrive as a second
            // conversation. Refusing plainly beats a queue that quietly reorders the session.
            guard !claudeCode.isStreaming else {
                builder.appendNote(
                    "Claude Code is mid-turn, and it does not accept steering — the turn "
                        + "boundary is its own. Wait for it to finish.")
                sync()
                return
            }
            if title == "New run" { title = String(text.prefix(60)) }
            claudeCode.send(text)
            return
        }
        if let inHouse {
            guard inHouse.acceptsFollowUps else {
                builder.appendNote("The run is still starting — try again in a moment.")
                sync()
                return
            }
            if inHouse.isStreaming {
                // Steer rather than refuse: the composer should stay usable while the agent
                // works, and the message lands at the next turn boundary where the
                // conversation is well-formed.
                inHouse.steer(text)
                queuedSteering = inHouse.pendingSteering
                return
            }
            inHouse.send(text)
            return
        }
        builder.appendNote("This run has no engine behind it.")
        sync()
    }

    /// Queue a message for after the current turn.
    ///
    /// The harness had a server-side queue for this. Aviary's own engine steers instead —
    /// the message lands at the next turn boundary, which is the same guarantee without a
    /// second place for a message to sit unacknowledged.
    func queueFollowUp(_ text: String) async {
        await send(text)
    }

    func abort() {
        claudeCode?.stop()
        inHouse?.stop()
    }

    /// Compaction is automatic on Aviary's own engine — the agent summarises the middle of
    /// the conversation when it passes a share of the context window, and records a marker.
    /// There is nothing to trigger by hand, and a button that pretended otherwise would be
    /// worse than its absence.
    func compact() async {
        builder.appendNote(
            "This engine compacts on its own when the conversation approaches the model's "
                + "context window.")
        sync()
    }

    /// Take a message from another run.
    ///
    /// Delivered as steering, which is what makes it land at a turn boundary rather than
    /// between a tool call and its result — the shape a provider rejects. Attributed in the
    /// text itself, because the receiving agent has no other way to know who is talking: it
    /// arrives in the conversation looking exactly like something a person typed.
    func receive(text: String, from sender: String) async {
        let attributed = "[message from \(sender)]\n\n" + text
        if let inHouse {
            if inHouse.isStreaming {
                inHouse.steer(attributed)
                queuedSteering = inHouse.pendingSteering
            } else {
                inHouse.send(attributed)
            }
            return
        }
        builder.appendNote("A message arrived but this run has no engine to take it.")
        sync()
    }

    /// Change the model this run answers with.
    ///
    /// Three engines, three genuinely different answers rather than three paths to one
    /// mechanism. The harness owns its session and is told over RPC. An in-house run is ours,
    /// so the agent swaps its provider and keeps the conversation and the interpreter — the
    /// expensive things. A driven run cannot: the model is an argument to the `claude` process
    /// and Claude Code owns the loop, so a new session is the only way, and saying that
    /// plainly beats a generic failure nobody can act on.
    func setModel(resolved: (provider: ProviderSpec, model: ModelSpec)) async {
        let label = resolved.model.qualifiedID
        if let inHouse {
            if let failure = await inHouse.switchModel(
                to: resolved.model, providerSpec: resolved.provider)
            {
                builder.appendNote("Could not switch model: \(failure)")
                sync()
                return
            }
            modelLabel = label
            return
        }
        if isClaudeCode {
            builder.appendNote(
                "Claude Code owns the loop for this run and takes its model at launch, so it "
                    + "cannot be changed mid-session. Start a new run to use \(label).")
            sync()
            return
        }
        builder.appendNote("This run has no engine to switch.")
        sync()
    }

    func setThinking(_ level: String) async {
        // Recorded on the run so the menu reflects the choice; the in-house agent reads its
        // effort from the model spec at each call, so this takes effect on the next turn.
        thinkingLevel = level
    }

    func rename(_ name: String) async {
        title = name
    }

    func stop() async {
        mirror?.cancel()
        if let claudeCode {
            claudeCode.stop()
            hasExited = true
            return
        }
        if let inHouse {
            inHouse.stop()
            hasExited = true
            return
        }
        inHouse?.stop()
        hasExited = true
    }
}
