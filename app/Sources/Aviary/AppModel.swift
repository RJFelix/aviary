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
    /// The reachable model catalogue, assembled locally rather than asked of the engine.
    var modelCatalog = ModelCatalog()
    let modelPreferencesStore = ModelPreferencesStore()
    var modelPreferences = ModelPreferences()
    /// What a picker offers: reachable, enabled, in your order.
    var pickerModels: [ModelSpec] { modelCatalog.enabled }
    var providerTests: [String: ProviderTestResult] = [:]
    var testingProviders: Set<String> = []
    var library = Library()
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
        case harness
        case inHouse
        case claudeCode

        public var id: String { rawValue }

        var label: String {
            switch self {
            case .harness: return "Harness"
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
        return UserDefaults.standard.bool(forKey: "aviary.inHouseEngine") ? .inHouse : .harness
    }() {
        didSet { UserDefaults.standard.set(engineChoice.rawValue, forKey: "aviary.engineChoice") }
    }

    /// Kept as a derived value so the several places that only care "is this the harness or
    /// not" need no change. A Claude-Code run is not the harness either.
    var preferInHouseEngine: Bool { engineChoice != .harness }
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
        modelPreferences = modelPreferencesStore.load()
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
        async let b: Void = refreshDaemon()
        async let c: Void = refreshRuntimeModels()
        async let d: Void = refreshRuntimeProbes()
        _ = await (a, b, c, d)
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

    /// Start an in-house run: Aviary's own loop, its own provider client, its own runtime
    /// host. No harness process and no Node.
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
                recordPayloads: recordPayloads, resume: resume),
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
        if engineChoice == .inHouse {
            startInHouseRun(
                cwd: cwd, providerID: s.provider, modelID: s.model, prompt: "",
                recordPayloads: recordPayloads, resume: s.id, title: s.title)
            return
        }
        startRun(
            config: RunConfiguration(
                cwd: cwd, provider: s.provider, model: s.model, resume: s.id,
                recordPayloads: recordPayloads),
            firstPrompt: nil)
    }

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

    /// Set when this run is Aviary's own rather than the harness's.
    ///
    /// One type with two backends rather than two types, because every view that renders a run
    /// — the transcript, the token panel, the sidebar row — should not have to know which
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

    func startClaudeCode(prompt: String) {
        guard let claudeCode else { return }
        if !prompt.isEmpty { title = String(prompt.prefix(60)) }
        claudeCode.start(prompt: prompt)
        // Mirrored onto this run exactly as the in-house driver is, so every view that reads
        // `items`, `isStreaming` and `usage` keeps working without knowing which engine — the
        // same reason all three write one transcript format.
        mirror = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.items = claudeCode.items
                self.isStreaming = claudeCode.isStreaming
                self.hasExited = claudeCode.hasExited
                self.usage = claudeCode.usage
                self.sessionID = claudeCode.sessionID
                self.sessionFile = claudeCode.sessionFile?.path
                self.errorBanner = claudeCode.errorBanner
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
                self.items = inHouse.items
                self.isStreaming = inHouse.isStreaming
                self.hasExited = inHouse.hasExited
                self.usage = inHouse.usage
                self.sessionID = inHouse.sessionID
                self.sessionFile = inHouse.sessionFile?.path
                self.errorBanner = inHouse.errorBanner
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
        if let claudeCode { claudeCode.stop(); return }
        if let inHouse { inHouse.stop(); return }
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
        pump?.cancel()
        await session.stop()
        hasExited = true
    }
}
