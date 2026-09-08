import AviaryCore
import CryptoKit
import Observation
import SwiftUI
import UserNotifications

/// UserNotifications requires a real application bundle on macOS. SwiftPM executables used by
/// snapshots and CLI diagnostics have no bundle proxy; asking for the current notification center
/// there raises an Objective-C exception that Swift cannot catch.
enum CanonicalNotificationPlatform {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            && Bundle.main.bundleIdentifier != nil
    }
}

/// Fixed, non-sensitive reason a service draft could not be restored. The distinction matters:
/// an unreadable record is known to remain on disk, while failure to construct the store proves
/// no such thing and must not claim that it does.
enum ServiceDraftRestorationFailure: Equatable, Sendable {
    case storeUnavailable
    case recordUnreadable
}

/// One in-memory, bounded transcript page for Cockpit. The catalog may retain more canonical
/// messages for other readers; the main actor never remaps that lifetime-sized history per frame.
struct CanonicalWorkspaceTranscriptPage: Equatable {
    static let maximumMessageCount = 512
    static let maximumUTF8Bytes = 256 * 1024

    let items: [TranscriptItem]
    let omittedMessageCount: Int
    let retainedUTF8Bytes: Int
    let sourceCursor: JournalCursor?

    init(summary: CanonicalSessionCatalogSummary) {
        var reverseRetained: [SessionMessageSnapshot] = []
        var retainedBytes = 0
        for message in summary.visibleMessages.reversed() {
            let bytes = message.text.utf8.count
            guard reverseRetained.count < Self.maximumMessageCount,
                  bytes <= Self.maximumUTF8Bytes - retainedBytes else { break }
            reverseRetained.append(message)
            retainedBytes += bytes
        }
        let retained = reverseRetained.reversed()
        self.retainedUTF8Bytes = retainedBytes
        self.omittedMessageCount = summary.visibleMessages.count - retained.count
        self.sourceCursor = summary.sessionSnapshotCursor
        self.items = retained.map { message in
            let role = message.role.lowercased()
            let kind: TranscriptItem.Kind = switch role {
            case "user": .user
            case "assistant", "model": .assistant
            // A canonical text snapshot is not a paired ToolCall/result; `.tool` would hide its
            // text and falsely display TranscriptView's running-tool treatment.
            case "tool", "action": .custom
            case "system": .stateChange
            default: .custom
            }
            var item = TranscriptItem(
                id: "canonical:\(summary.journal.stableKey):\(message.eventID)",
                kind: kind,
                timestamp: message.hostRecordedAt ?? .distantPast)
            item.text = message.text
            if !message.text.isEmpty { item.blocks = [.text(message.text)] }
            item.model = summary.sessionModelID
            item.customType = message.role
            return item
        }
    }
}

/// Top-level navigation destinations.
enum Section: String, CaseIterable, Identifiable, Hashable {
    case cockpit, live, sessions, workshop, flock, models, usage, library, health

    /// What the sidebar offers.
    ///
    /// Flock is a Work/Session projection. Legacy child rows remain available only as an
    /// explicit compatibility section when no canonical Session projection exists.
    static var visible: [Section] { [.cockpit, .sessions, .workshop, .flock, .models, .usage, .library, .health] }
    static var primary: [Section] { [.cockpit, .sessions, .workshop] }
    static var tools: [Section] { [.flock, .models, .usage, .library, .health] }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cockpit, .live: return "Chats"
        case .sessions: return "History"
        case .workshop: return "Workshop"
        case .flock: return "Flock"
        case .models: return "Models"
        case .usage: return "Usage"
        case .library: return "Library"
        case .health: return "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .cockpit: return "bubble.left.and.bubble.right"
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
        case .cockpit, .live: return "Your conversations and current work"
        case .sessions: return "Recorded and imported conversations"
        case .workshop: return "Ask Aviary to change"
        case .flock: return "Sub-agent trees"
        case .models: return "Providers and routes"
        case .usage: return "Tokens and cost"
        case .library: return "Skills, prompts, extensions"
        case .health: return "Runtime and processes"
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
    /// Local chat presentation precedes remote Session admission. It is never a claim that
    /// the agent received a prompt or that canonical Work exists.
    var pendingChats: [PendingChat] = []
    var selectedPendingChatID: UUID?
    var pendingChatStoreError: String?
    var newChatRequested = false
    private var pendingChatAttempts: Set<UUID> = []
    var pendingChatDetails: [UUID: String] = [:]
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
    /// Canonical catalog projections keyed by the displayed row id. Legacy rows use the filename
    /// stem, while native rows use their authority-qualified id; artifact, kernel, and live-run
    /// joins still use the separate local compatibility identity until native journals land.
    var canonicalCatalogProjections: [String: CanonicalSessionCatalogSummary] = [:]
    /// Projection ids reported more than once in one catalog refresh. Conflicting rows are
    /// withheld from display and lookup rather than selecting an arbitrary authority.
    var canonicalCatalogProjectionConflicts: [String] = []
    /// Work is inventoried independently of Session rows so a live or completed Work Host can
    /// remain observable before any GUI attaches, and so future GUIs do not need to manufacture
    /// Work state from their own in-memory runs.
    var canonicalWorkInventory: [LocalTimelineCatalog.WorkRow] = []
    /// Recovery is projected from the same catalog scan as notification candidates. No local GUI
    /// observation is supplied here, so in-process attachment presentation never becomes global
    /// host truth; a clicked failed-recovery route must reconcile against this exact snapshot.
    var canonicalWorkRecoveryProjection = CanonicalWorkRecoveryProjection(
        works: [], sourceComplete: false)
    /// Bounded reader projections are assembled once at the catalog boundary. Views consume
    /// these values rather than repeatedly joining every Work to every Session during rendering.
    var canonicalFlockInventory: [CanonicalFlockCatalogProjection] = []
    var canonicalAttentionInbox = CanonicalAttentionInboxProjection(summaries: [])
    /// The Cockpit rail is a canonical Session workspace projection, not a list of whatever
    /// `LiveRun` objects this GUI happens to retain. It remains bounded and authority-qualified;
    /// GUI attachment/control capability is joined only at the user-action boundary.
    var canonicalWorkspaceRail = CanonicalSessionWorkspaceRailProjection(
        inbox: CanonicalAttentionInboxProjection(summaries: []), summaries: [])
    var canonicalWorkspaceTranscripts: [String: CanonicalWorkspaceTranscriptPage] = [:]
    /// Native notification candidates are built from the same exact canonical summaries as the
    /// attention inbox, but keep an independent bound so a display page cannot hide a transition.
    var canonicalNotificationProjection = CanonicalNotificationProjection(summaries: [])
    var canonicalNotificationError: String?
    /// Authorization is observed, never requested, during bootstrap and polling. Preferences is
    /// the explicit user action that may request it.
    var canonicalNotificationAuthorization: UNAuthorizationStatus = .notDetermined
    var canonicalNotificationAuthorizationError: String?
    /// Canonical journal identity to the actual displayed Session row. Companion rows display
    /// their legacy transcript id, which must never be reconstructed from the canonical id.
    private var canonicalNotificationDisplayIDs: [String: String] = [:]
    private static let maximumPendingCanonicalNotificationRoutes = 32
    private var pendingCanonicalNotificationRoutes: [CanonicalNotificationRoute] = []
    private var pendingCanonicalNotificationRouteKeys: Set<String> = []
    private var canonicalNotificationCatalogScanComplete = false
    /// The exact route that caused the current Session focus. Unlike a Session id alone, this
    /// retains the failed action, outcome, and source cursors for the evidence card.
    var canonicalNotificationFocus: CanonicalNotificationRoute?
    /// Cached bounded lexical documents. Views never rebuild native/legacy search fields on each
    /// keystroke, and the index consumes only conflict-free display projections.
    var canonicalSessionSearchIndex = CanonicalSessionSearchIndex(entries: [])
    var nativeTimelineCatalogDiagnostics: [LocalTimelineCatalog.Diagnostic] = []
    /// Native Session journals that exist but cannot prove attachment/liveness truth. This is
    /// separate from canonical projections because invalid native rows are intentionally absent
    /// from that fact map while still needing to block destructive or duplicate-start actions.
    var nativeActionBlockedSessionIDs: Set<String> = []
    /// Explicit catalog provenance for which legacy rows have a native companion.
    var nativeCompanionLegacyIDs: Set<String> = []
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
    /// Session identities reserved by an in-flight Trash operation. Resume admission checks
    /// this set so no new writer can appear after the liveness check yields to the catalog actor.
    private var sessionsBeingTrashed: Set<String> = []
    var isArchivingSessions = false
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
    // per session, and this is where their state used to live. Aviary's own engine still has
    // an in-process driver, but the durable Work identity and command controller now belong to
    // the session seam; `runs` is only this GUI's current attachment, not proof that Work ends
    // when this collection changes.
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
    /// Work retained by this process after its chat view is detached. Service-backed rows are
    /// durable host attachments; process-owned rows remain only the Claude Code path.
    var detachedRuns: [LiveRun] = []

    /// The GUI's durable client identity and local Work Host connection.  The bootstrapper is
    /// only a client transport: it may launch a helper to make a local host reachable, but it
    /// never owns Work, Session, Run, or the helper process lifetime.
    private(set) var localWorkService: LocalWorkServiceBootstrap?
    private(set) var localWorkServiceClient: ClientRef?
    var localWorkServiceHandshake: WorkServiceHandshakeResponse?
    var localWorkspaceCatalog: WorkHostWorkspaceCatalog = .empty
    /// Work rows offered by the last complete authoritative catalog read that this client does
    /// not already attach to. The launcher uses this for an explicit Attach action; rows are
    /// never reconstructed from a partially read or quarantined page.
    private(set) var localServiceCatalogWorks: [WorkServiceWorkDescriptor] = []
    private var localWorkServiceObservationError: String?
    /// A successful handshake/catalog read cannot resolve an outstanding Create transaction.
    /// Clear this only when the retained Create outbox has actually been reconciled.
    var localWorkServiceCreateError: String?
    private var localWorkServiceCreatesReconciled = false
    var localWorkServiceError: String? {
        get {
            if localWorkServiceHandshake == nil, let connectivity = localWorkServiceObservationError {
                return connectivity
            }
            return localWorkServiceCreateError ?? localWorkServiceObservationError
        }
        set { localWorkServiceObservationError = newValue }
    }
    private var localWorkServiceBootstrapInFlight = false
    private var serviceRefreshInFlight = false
    /// Cursor for the bounded central service poll. Stable ordering plus rotation prevents
    /// Work rows after the first page of attached runs from being starved forever.
    private var servicePollOffset = 0
    private var serviceCreateInFlight = false
    /// Process-level service work that can publish or mutate a GUI attachment. Shutdown closes
    /// admission and drains this set before taking its final `workRuns` snapshot, so an adoption
    /// cannot materialize behind that snapshot and escape draft/command quiescence.
    private var serviceLifecycleOperationsInFlight = 0
    private var serviceLifecycleOperationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Create Session is independently serialized per Work. The exact request is retained on
    /// disk before transport, so this flag is only presentation/admission backpressure rather
    /// than the durability boundary.
    private var serviceSessionCreationsInFlight: Set<WorkRef> = []
    /// Presentation-only admission guard for an explicit Attach/Inspect gesture. Durable retry
    /// identity still lives in `pendingServiceAttaches`; this set only prevents duplicate clicks
    /// while one exact target is being reconciled.
    private var serviceAttachesInFlight: Set<WorkSessionKey> = []
    private enum CreateSessionReconciliationOutcome: Equatable {
        case clear
        case recovered
        case blocked
    }
    /// Exact Attach requests retained across an ambiguous response.  The request's causal
    /// control cursor and host instance are part of the logical attach epoch; a later retry uses
    /// this same envelope only while the descriptor has not already proven the attachment.
    private struct PendingServiceAttach {
        let request: WorkServiceAttachRequest
        let hostInstance: WorkHostInstanceRef
    }
    private var pendingServiceAttaches: [AttachTargetKey: PendingServiceAttach] = [:]
    /// Local presentation state only.  Closing a completed service row must not cause the next
    /// catalog poll to recreate it; a relaunch starts with an empty set and can inspect terminal
    /// Work again from the canonical Sessions/catalog surface.
    private var hiddenServiceAttachmentKeys: Set<ServiceAttachmentKey> = []

    var workRuns: [LiveRun] { runs + detachedRuns }

    /// One process-wide quiescence barrier for reload and ordinary application termination.
    ///
    /// A second shutdown request must join the first rather than observe `LiveRun.isEnding`,
    /// return early, and let the process disappear while the original cleanup is still waiting
    /// on Claude Code or its runtime child. Window close does not call this; it merely removes
    /// the GUI attachment and leaves Work alive in this process.
    private var workShutdownTask: Task<Bool, Never>?
    var reloadInProgress = false
    var acceptsNewWork = true

    @discardableResult
    func stopAllWork() async -> Bool {
        acceptsNewWork = false
        if let workShutdownTask {
            return await workShutdownTask.value
        }
        let task = Task { @MainActor in
            self.stopPolling()
            await self.waitForServiceLifecycleOperations()
            // No new service lifecycle operation can enter after `acceptsNewWork = false`, and
            // every prior one is now settled. This snapshot is therefore the complete set of
            // GUI-owned rows whose drafts and command barriers must cross shutdown.
            let processOwnedWork = self.workRuns.filter { !$0.isServiceBacked }
            let serviceBackedWork = self.workRuns.filter(\.isServiceBacked)
            // Freeze new GUI-originated command admission, then join commands already beyond
            // that boundary. Their host outcome and draft reconciliation must settle before
            // the final draft flush can truthfully precede disconnect.
            for run in serviceBackedWork { run.freezeServiceComposerAdmission() }
            for run in serviceBackedWork { await run.waitForServiceComposerCommands() }
            // A draft is GUI-owned state, unlike the canonical conversation, and therefore
            // has to cross the process boundary before this GUI drops its service sessions.
            // Every run serializes this flush behind any already-started background save.
            var draftsAreDurable = true
            for run in serviceBackedWork {
                if !(await run.flushDraftPersistence(freezeEdits: true)) {
                    draftsAreDurable = false
                }
            }
            guard draftsAreDurable else {
                // Do not turn a disk failure into silent data loss. Nothing has been stopped or
                // disconnected yet; restore editing and let AppDelegate cancel termination.
                for run in serviceBackedWork { run.resumeAfterAbortedShutdown() }
                self.acceptsNewWork = true
                self.startPolling()
                self.localWorkServiceError =
                    "Quit or reload was canceled because an unsent draft could not be saved. Copy or repair the marked draft, then try again."
                return false
            }
            // Claude Code and the old in-process path still have an explicit process-owned
            // teardown.  A Work-service run is different: disconnecting this GUI must not
            // synthesize End or make the Work Host depend on this process.
            for run in processOwnedWork { await run.stop() }
            for run in serviceBackedWork { await run.disconnect() }
            await self.disconnectLocalWorkService()
            return true
        }
        workShutdownTask = task
        let completed = await task.value
        workShutdownTask = nil
        return completed
    }

    private func beginServiceLifecycleOperation() -> Bool {
        guard acceptsNewWork else { return false }
        serviceLifecycleOperationsInFlight += 1
        return true
    }

    private func finishServiceLifecycleOperation() {
        precondition(serviceLifecycleOperationsInFlight > 0)
        serviceLifecycleOperationsInFlight -= 1
        guard serviceLifecycleOperationsInFlight == 0 else { return }
        let waiters = serviceLifecycleOperationWaiters
        serviceLifecycleOperationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForServiceLifecycleOperations() async {
        guard serviceLifecycleOperationsInFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            serviceLifecycleOperationWaiters.append(continuation)
        }
    }

    /// A reload may fail after the ordinary shutdown path has already disconnected this GUI.
    /// Reopen every local admission gate and restart the single polling owner, then reconnect
    /// immediately instead of leaving an apparently-live app with frozen service projections.
    func resumeAfterFailedRelaunch() async {
        acceptsNewWork = true
        for run in workRuns { run.resumeAfterAbortedShutdown() }
        startPolling()
        if localWorkService == nil {
            await bootstrapLocalWorkService()
        } else {
            await refreshServiceWork()
        }
    }

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
            let choice = Engine(rawValue: raw)
        {
            return choice
        }
        // In-house is the default now. The harness fork is on its way out — it is 457MB of
        // vendored Node whose remaining advantages over Aviary's own loop have been absorbed
        // one at a time, and a default that still pointed at it meant the workshop agent was
        // improving Aviary using somebody else's agent.
        return .inHouse
    }()
    {
        didSet { UserDefaults.standard.set(engineChoice.rawValue, forKey: "aviary.engineChoice") }
    }

    /// Kept as a derived value so the several places that only care "is this the harness or
    /// not" need no change. A Claude-Code run is not the harness either.
    /// Retained as a name several places still read. There is no other kind of engine now.
    var preferInHouseEngine: Bool { true }
    var focusedRunID: UUID?
    /// Which Claude model a driven run asks for. An alias rather than a full id, because that
    /// is what Claude Code's `--model` takes and what its own docs use.
    var claudeCodeModel: String =
        UserDefaults.standard.string(forKey: "aviary.claudeCodeModel")
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
    /// Catalog reads are actor-isolated, but applying a result is MainActor work. Coalesce a
    /// timer tick with a manual refresh so an older scan cannot overwrite a newer projection.
    private var catalogRefreshInFlight = false
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
    /// capturing the login shell's environment, scanning every transcript on disk,
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
        restorePendingChats()
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
        await bootstrapLocalWorkService()
        startPolling()
    }

    /// Establish the local client connection used by Aviary-owned in-house runs.  The durable
    /// ClientRef is read before constructing any controller and is shared across GUI relaunches;
    /// it is never regenerated merely because a window or process disappeared.
    func bootstrapLocalWorkService() async {
        guard !isPreview, localWorkService == nil, !localWorkServiceBootstrapInFlight,
              beginServiceLifecycleOperation() else {
            return
        }
        localWorkServiceBootstrapInFlight = true
        defer {
            localWorkServiceBootstrapInFlight = false
            finishServiceLifecycleOperation()
        }
        do {
            let workHost = try home.requirePersistedWorkHost()
            let identityStore = try WorkServiceClientIdentityStore(url: home.workServiceClientIdentityFile)
            let client = try identityStore.loadOrCreate()
            let locator = LocalWorkServiceHostLocator(home: home, workHost: workHost)
            let launcher = try LocalAviaryDaemonLauncher(agentHome: home).asLauncher()
            let bootstrap = try LocalWorkServiceBootstrap(
                locator: locator, client: client, launcher: launcher)
            localWorkService = bootstrap
            localWorkServiceClient = client
            let initialSession = try await bootstrap.connect()
            localWorkServiceHandshake = await initialSession.negotiatedHandshake
            localWorkspaceCatalog = localWorkServiceHandshake?.workspaceCatalog ?? .empty
            localWorkServiceError = nil
            // A fresh probe is not enough for mutation admission: it may be a different daemon
            // instance from the cached shared socket. Reconcile only after the shared session has
            // been refreshed and fenced to the same host instance.
            let (session, freshHandshake) = try await reconnectLocalWorkService()
            localWorkServiceHandshake = freshHandshake
            localWorkspaceCatalog = freshHandshake.workspaceCatalog
            let createsReconciled = await reconcilePendingCreateIntents(session: session, client: client)
            let sessionsReconciled = createsReconciled
                ? await reconcilePendingCreateSessionIntents(session: session, client: client) != .blocked
                : false
            let reconciliationWarning = localWorkServiceObservationError
            // A blocked creation must not hide unrelated attachments or implicitly replay Start.
            await restoreServiceWork(
                session: session, client: client, handshake: freshHandshake,
                resumeInitialStart: createsReconciled && sessionsReconciled)
            if !sessionsReconciled, localWorkServiceObservationError == nil {
                localWorkServiceObservationError = reconciliationWarning
            }
        } catch {
            // The GUI remains usable for Claude Code and historical sessions if the local
            // helper is unavailable.  Keep this error bounded and do not expose launcher paths.
            await localWorkService?.disconnect()
            localWorkService = nil
            localWorkServiceHandshake = nil
            localWorkspaceCatalog = .empty
            localWorkServiceError = Self.serviceErrorMessage(error)
        }
    }

    /// Explicit recovery, unlike background catalog polling, reconciles the original Create
    /// identity before reconstructing its conversation. A live socket alone is not success.
    func retryLocalWorkService() async {
        if localWorkService == nil {
            await bootstrapLocalWorkService()
            return
        }
        guard let client = localWorkServiceClient,
              beginServiceLifecycleOperation() else { return }
        defer { finishServiceLifecycleOperation() }
        do {
            let (session, handshake) = try await reconnectLocalWorkService()
            localWorkServiceHandshake = handshake
            localWorkspaceCatalog = handshake.workspaceCatalog
            let createsReconciled = await reconcilePendingCreateIntents(session: session, client: client)
            let sessionsReconciled = createsReconciled
                ? await reconcilePendingCreateSessionIntents(session: session, client: client) != .blocked
                : false
            let reconciliationWarning = localWorkServiceObservationError
            await restoreServiceWork(
                session: session, client: client, handshake: handshake,
                resumeInitialStart: createsReconciled && sessionsReconciled)
            if !sessionsReconciled, localWorkServiceObservationError == nil {
                localWorkServiceObservationError = reconciliationWarning
            }
        } catch {
            localWorkServiceError = Self.serviceErrorMessage(error)
        }
    }

    /// Read the host catalog and recreate every attachment belonging to this durable client.
    /// This never issues another Attach. Initial Start recovery is a separate, explicit mode;
    /// blocked creation reconciliation permits only observation of existing attachments.
    private func restoreServiceWork(
        session: WorkServiceClientSession, client: ClientRef,
        handshake suppliedHandshake: WorkServiceHandshakeResponse? = nil,
        resumeInitialStart: Bool = true
    ) async {
        defer { settlePendingChats() }
        let handshake: WorkServiceHandshakeResponse?
        if let suppliedHandshake {
            handshake = suppliedHandshake
        } else {
            handshake = await session.negotiatedHandshake
        }
        guard let handshake else {
            localServiceCatalogWorks = []
            localWorkServiceError = "The Work Host did not provide a handshake for reconstruction."
            return
        }
        let catalog = await WorkServiceCatalog().refresh([
            WorkServiceCatalogHost(host: handshake.host, session: session)
        ])
        let rowLocalQuarantineOnly = catalog.hosts.count == 1
            && catalog.hosts[0].sourceCompleteness != .complete
            && !catalog.hosts[0].quarantined.isEmpty
            && catalog.hosts[0].diagnostics.isEmpty
        guard catalog.hosts.count == 1,
              let host = catalog.hosts.first,
              connectionIsUsable(host.connectionState),
              host.omissions.isEmpty,
              host.negotiatedInstance == handshake.hostInstance,
              host.sourceCompleteness == .complete || rowLocalQuarantineOnly else {
            localServiceCatalogWorks = []
            localWorkServiceError = "The Work Host catalog is incomplete; attached Work was withheld until a complete read."
            return
        }
        // A malformed/duplicate descriptor is quarantined as a row by WorkServiceCatalog. It
        // must not poison unrelated healthy Works from the same complete page, but any page or
        // source omission still withholds reconstruction because the missing row could be this
        // GUI's attachment. Keep the quarantine visible without consuming the bad row.
        if !host.quarantined.isEmpty {
            localWorkServiceError =
                "Some Work rows were quarantined by the host catalog; healthy rows remain available for inspection."
        } else {
            localWorkServiceError = nil
        }
        localServiceCatalogWorks = catalog.works.filter { descriptor in
            let ownAttachments = descriptor.attachments.filter { $0.client == client }
            let hasOwnAttachment = !ownAttachments.isEmpty
            let representedKeys = Set(workRuns.compactMap { $0.serviceAttachmentKey })
            let hasUnrepresentedOwnAttachment = ownAttachments.contains { attachment in
                guard let key = ServiceAttachmentKey(work: descriptor.work, attachment: attachment)
                else { return false }
                return !representedKeys.contains(key)
            }
            let hasUnattachedSemanticTarget = descriptor.attachmentQualifiedSessionTargets.contains {
                target in
                !ownAttachments.contains {
                    $0.session == target.session
                        && $0.sessionJournal == target.sessionJournal
                        && $0.sessionAttachment == target.sessionAttachment
                }
            }
            let canCreateSession = ownAttachments.contains {
                $0.authorization.allows(.createSession)
                    && ServiceAttachmentKey(work: descriptor.work, attachment: $0) != nil
            }
            // Reusable Work with this client's attachment is reconstructed into LiveRun below.
            // Terminal Work stays in the explicit catalog even when it retains that attachment,
            // so a relaunch can reopen it for inspection instead of silently losing history.
            return !hasOwnAttachment || descriptor.recordedDisposition != .reusable
                || hasUnrepresentedOwnAttachment || hasUnattachedSemanticTarget
                || canCreateSession
        }
        for descriptor in catalog.works {
            // Terminal Work remains available from Sessions/catalog and through the explicit
            // Attach action below, but relaunch should not flood Live with completed history.
            guard descriptor.recordedDisposition == .reusable else { continue }
            let attachments = descriptor.attachments.filter { $0.client == client }
            for attachment in attachments {
                guard let key = ServiceAttachmentKey(work: descriptor.work, attachment: attachment),
                      !hiddenServiceAttachmentKeys.contains(key) else { continue }
                await adoptServiceAttachment(
                    descriptor: descriptor, attachment: attachment,
                    session: session, client: client, focus: false,
                    resumeInitialStart: resumeInitialStart)
            }
        }
        // A Start seed may outlive both its GUI and its Run. Terminal Work is not auto-opened
        // into Live, but its exact command evidence can still settle the local marker so a later
        // relaunch never retries an already-ended Start or leaves a stale bootstrap obligation.
        for descriptor in catalog.works {
            guard descriptor.recordedDisposition != .reusable else { continue }
            for attachment in descriptor.attachments where attachment.client == client {
                guard let key = ServiceAttachmentKey(work: descriptor.work, attachment: attachment),
                      !hiddenServiceAttachmentKeys.contains(key) else { continue }
                await reconcileTerminalStartIntent(
                    descriptor: descriptor, attachment: attachment,
                    session: session, client: client)
            }
        }
    }

    private func connectionIsUsable(_ state: WorkServiceClientSessionState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private func reconcileTerminalStartIntent(
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        session: WorkServiceClientSession,
        client: ClientRef
    ) async {
        do {
            guard let key = ServiceAttachmentKey(work: descriptor.work, attachment: attachment)
            else { throw ServiceBackedStartIntentError.corrupt }
            let store = try ServiceBackedStartIntentStore(
                home: home, key: key)
            guard let intent = try store.load() else { return }
            guard attachment.session == intent.session,
                  attachment.sessionJournal == intent.sessionJournal,
                  attachment.sessionAttachment == intent.sessionAttachment else {
                localWorkServiceError =
                    "A terminal Work has a retained Start from a different Session attachment; explicit review is required."
                return
            }
            let intentStore = try WorkServiceAttachedWorkIntentStore(
                home: home, key: key)
            let controller = try WorkServiceAttachedWorkController(
                session: session, seed: .existing(work: descriptor, attachment: attachment),
                intentStore: intentStore)
            let projection: WorkServiceAttachedWorkProjection
            do {
                projection = try await controller.refresh()
            } catch {
                projection = await controller.projection()
            }
            guard Self.hasCanonicalStartEvidence(intent, projection: projection) else { return }
            try store.clear(intent)
        } catch {
            // A malformed marker or incomplete terminal read remains visible as a local
            // recovery diagnostic. It is never silently converted into a fresh Start.
            localWorkServiceError =
                "A terminal Work's retained Start could not be reconciled safely."
        }
    }

    private struct ServiceDraftRestoration: Sendable {
        let store: ServiceBackedDraftStore?
        let snapshot: ServiceBackedDraftSnapshot?
        let failure: ServiceDraftRestorationFailure?
    }

    /// Draft files contain raw user text, so even their small bounded reads stay off the main
    /// actor. Failure is deliberately reduced to a fixed state here: paths and decoder details
    /// can expose private attachment metadata and do not belong in the GUI.
    private nonisolated static func readServiceDraft(
        home: AgentHome, key: ServiceAttachmentKey
    ) -> ServiceDraftRestoration {
        let store: ServiceBackedDraftStore
        do {
            store = try ServiceBackedDraftStore(home: home, key: key)
        } catch {
            return ServiceDraftRestoration(
                store: nil, snapshot: nil, failure: .storeUnavailable)
        }
        do {
            return ServiceDraftRestoration(
                store: store, snapshot: try store.load(), failure: nil)
        } catch {
            // Retain a successfully constructed store so a later explicit edit can replace a
            // damaged record atomically and recover persistence without relaunching again.
            return ServiceDraftRestoration(
                store: store, snapshot: nil, failure: .recordUnreadable)
        }
    }

    private static func restoreServiceDraft(
        home: AgentHome, key: ServiceAttachmentKey
    ) async -> ServiceDraftRestoration {
        await Task.detached(priority: .utility) {
            Self.readServiceDraft(home: home, key: key)
        }.value
    }

    /// Reconcile a crash-time handoff before constructing the composer. Accepted evidence clears
    /// only byte-identical submitted text; definitive rejection preserves it. Any source or
    /// persistence failure keeps the marker and blocks a second automatic submission.
    private static func reconcileServiceDraft(
        _ restoration: ServiceDraftRestoration,
        key: ServiceAttachmentKey,
        projection: WorkServiceAttachedWorkProjection
    ) async -> ServiceDraftRestoration {
        guard let store = restoration.store,
              let startingSnapshot = restoration.snapshot,
              let handoff = startingSnapshot.handoff else {
            return restoration
        }
        let disposition = ServiceBackedDraftHandoffDisposition.classify(
            handoff, key: key, projection: projection)
        guard disposition != .unresolved else { return restoration }
        return await Task.detached(priority: .utility) {
            do {
                let snapshot = try store.resolveHandoff(
                    commandID: handoff.commandID,
                    accepted: disposition == .accepted,
                    currentText: startingSnapshot.text,
                    expectedGeneration: startingSnapshot.generation)
                return ServiceDraftRestoration(
                    store: store, snapshot: snapshot, failure: nil)
            } catch ServiceBackedDraftError.conflict {
                // Another GUI using the same durable client attachment won the CAS. Adopt its
                // latest private draft state without issuing or resolving any Work command;
                // the LiveRun actor will carry that generation into every later mutation.
                do {
                    return ServiceDraftRestoration(
                        store: store, snapshot: try store.load(), failure: nil)
                } catch {
                    return ServiceDraftRestoration(
                        store: store, snapshot: restoration.snapshot,
                        failure: .recordUnreadable)
                }
            } catch {
                return ServiceDraftRestoration(
                    store: store, snapshot: restoration.snapshot,
                    failure: .recordUnreadable)
            }
        }.value
    }

    @discardableResult
    private func adoptServiceAttachment(
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        session: WorkServiceClientSession,
        client: ClientRef,
        focus: Bool,
        destination: Section = .live,
        resumeInitialStart: Bool = true
    ) async -> String? {
        guard attachment.session != nil,
              attachment.sessionJournal != nil,
              attachment.sessionAttachment != nil else {
            let message = "A Work attachment without a Session identity was withheld."
            localWorkServiceError = message
            return message
        }
        guard let key = ServiceAttachmentKey(work: descriptor.work, attachment: attachment) else {
            let message = "A Work attachment without a complete identity was withheld."
            localWorkServiceError = message
            return message
        }
        let sameSessionAttachments = descriptor.attachments.filter {
            $0.client == key.client
                && $0.session == key.workSession.session
                && $0.sessionJournal == key.workSession.sessionJournal
                && $0.sessionAttachment == key.workSession.sessionAttachment
        }
        guard sameSessionAttachments.count == 1,
              sameSessionAttachments.first.map({
                  ServiceAttachmentKey(work: descriptor.work, attachment: $0) == key
              }) == true else {
            let message =
                "This Work has conflicting records for one client Session attachment."
            localWorkServiceError = message
            return message
        }
        hiddenServiceAttachmentKeys.remove(key)
        if let existing = workRuns.first(where: { $0.serviceAttachmentKey == key }) {
            if focus {
                if detachedRuns.contains(where: { $0.id == existing.id }) {
                    reattachRun(existing, destination: destination)
                } else {
                    focusedRunID = existing.id
                    section = destination
                }
            }
            return nil
        }
        do {
            var restoredDraft = await Self.restoreServiceDraft(home: home, key: key)
            let intentStore = try WorkServiceAttachedWorkIntentStore(
                home: home, key: key)
            let startIntentStore = try ServiceBackedStartIntentStore(
                home: home, key: key)
            let initialStart = try startIntentStore.load()
            let controller = try WorkServiceAttachedWorkController(
                session: session,
                seed: .existing(work: descriptor, attachment: attachment),
                intentStore: intentStore)
            let projection: WorkServiceAttachedWorkProjection
            do {
                projection = try await controller.refresh()
            } catch {
                // Keep the row visible with the controller's bounded evidence.  A read failure
                // is a recovery/unavailable state, never a reason to drop completed history.
                projection = await controller.projection()
            }
            restoredDraft = await Self.reconcileServiceDraft(
                restoredDraft, key: key, projection: projection)
            var unresolvedInitialStart = initialStart
            if let initialStart, Self.hasCanonicalStartEvidence(
                initialStart, projection: projection) {
                // A prior Start may have crossed the host boundary after the GUI lost its
                // response. The exact canonical command envelope resolves the bootstrap marker;
                // never issue a second Start merely because the local cleanup was interrupted.
                do {
                    try startIntentStore.clear(initialStart)
                    unresolvedInitialStart = nil
                } catch {
                    localWorkServiceError =
                        "The initial Start is already reflected by canonical Work, but its local intent could not be cleared."
                    unresolvedInitialStart = nil
                }
            }
            let bridge = ServiceBackedRunBridge(
                controller: controller,
                projection: projection,
                history: await controller.conversationHistory(),
                serviceAttachmentKey: key,
                workspaceLabel: workspaceLabel(for: descriptor),
                modelLabel: [descriptor.configuration.providerID,
                             descriptor.configuration.modelID]
                    .compactMap { $0 }.joined(separator: "/"),
                thinkingLevel: descriptor.configuration.thinkingLevel)
            let run = LiveRun(
                service: bridge, initialStart: unresolvedInitialStart,
                initialStartStore: startIntentStore,
                draftStore: restoredDraft.store,
                restoredDraft: restoredDraft.snapshot,
                draftRestorationFailure: restoredDraft.failure)
            run.initialStartRequiresExplicitRetry = !resumeInitialStart
            // A central restore and an explicit Attach/Create may have started from the same
            // catalog generation. Recheck after every suspension; only one exact attachment
            // becomes a GUI row/controller, and an explicit focusing caller reuses that winner.
            if let existing = workRuns.first(where: { $0.serviceAttachmentKey == key }) {
                if focus {
                    if detachedRuns.contains(where: { $0.id == existing.id }) {
                        reattachRun(existing, destination: destination)
                    } else {
                        focusedRunID = existing.id
                        section = destination
                    }
                }
                return nil
            }
            // Shutdown may have closed admission while the read/controller work above was in
            // flight. Canonical Work remains on its host and will be restored next launch; do
            // not create an in-memory row behind shutdown's final snapshot.
            guard acceptsNewWork else { return nil }
            runs.append(run)
            if focus {
                focusedRunID = run.id
                section = destination
            }
            run.observeService()
            // A Create may have been durably accepted just before the previous GUI disappeared.
            // Re-drive that exact first prompt only after the attachment has been reconstructed;
            // refreshService may retry an incomplete first read only in recovery-enabled mode.
            if resumeInitialStart, let unresolvedInitialStart,
               bridge.projection.isCanonical,
               bridge.hasMatchingStartAttachment(for: unresolvedInitialStart),
               await controller.pendingCommand() == nil {
                await run.startService(
                    prompt: unresolvedInitialStart.prompt, commandID: unresolvedInitialStart.commandID)
            } else if unresolvedInitialStart != nil {
                run.commandNotice = .warning(
                    bridge.projection.isCanonical
                        ? "The saved first message is awaiting startup reconciliation. Check delivery before retrying."
                        : "The saved first message is waiting for a complete Work and Session read. It has not been resubmitted.")
            }
            return nil
        } catch {
            let message = "A Work attachment could not be reconstructed safely."
            localWorkServiceError = message
            return message
        }
    }

    func workspaceLabel(for descriptor: WorkServiceWorkDescriptor) -> String {
        guard let workspaceID = descriptor.configuration.workspaceID,
              let workspace = localWorkspaceCatalog.entries.first(where: {
                  $0.workspaceID == workspaceID
              }) else {
            return "Work \(descriptor.work.workID)"
        }
        return workspace.label ?? "Workspace \(workspaceID.rawValue.prefix(12))"
    }

    static func serviceErrorMessage(_ error: Error) -> String {
        if let error = error as? WorkServiceTransportError {
            switch error {
            case .remote(let code, _):
                // Do not echo arbitrary remote diagnostic text (it can contain source data).
                switch code {
                case .launchUnavailable:
                    return "The agent service answered, but it cannot prepare this chat's model, project, or runtime configuration. Check Models, the project settings, and Diagnostics, then retry the saved request."
                case .internalError:
                    return "The agent service answered with an internal error while preparing the chat. This is not a connection failure. The saved request is retained for an exact retry."
                case .sourceIncomplete:
                    return "The agent service cannot verify its saved Work state. The request is retained; no replacement Work will be created."
                case .capabilityDenied:
                    return "The agent service has not granted permission to prepare this chat. Your saved request is retained."
                default:
                    return "The agent service rejected the operation (\(code.rawValue)). Your saved request is retained; check Diagnostics before retrying."
                }
            case .invalidFrame, .invalidResponse:
                return "The agent service returned a response Aviary could not validate. The original request is retained for reconciliation; it will not be replaced with another copy."
            default:
                return "Confirmation from the agent service was interrupted. Your saved request is retained for reconciliation, not sent again as a new request."
            }
        }
        if let error = error as? WorkServiceClientIdentityError {
            switch error {
            case .invalidURL, .accessDenied:
                return "Aviary could not open its private connection identity. Check access to Aviary's local data folder; your saved chats are kept."
            case .invalidRecord:
                return "Aviary's saved connection identity is unreadable. It has not been replaced, because that could disconnect existing conversations."
            case .ioFailure:
                return "Aviary could not save its connection identity. Check local disk access, then retry."
            }
        }
        if error is AgentHomeError {
            return "Aviary could not load the agent service's saved identity. Its existing data has been kept; check access to Aviary's local data folder."
        }
        if let error = error as? LocalAviaryDaemonLauncherError {
            return error.errorDescription ?? "The local agent service could not start. Retry connection or open Diagnostics."
        }
        if let error = error as? LocalWorkServiceBootstrapError {
            return error.errorDescription ?? "The local Work Host is unavailable."
        }
        if error is WorkServiceClientSessionError {
            return "The local Work Host connection is unavailable."
        }
        return "Aviary could not connect to the local agent service. Retry connection; if this continues, open Diagnostics."
    }

    /// Reconcile Create intents retained before a GUI crash or lost response. Replaying the exact
    /// request is the protocol's idempotent lookup; inventing a new command or rewriting its
    /// causal cursor could mint a second Work. An unresolved intent blocks new Create admission
    /// but does not affect inspection of already-listed Work.
    private func reconcilePendingCreateIntents(
        session: WorkServiceClientSession, client: ClientRef
    ) async -> Bool {
        localWorkServiceCreatesReconciled = false
        do {
            let store = try ServiceBackedCreateIntentStore(home: home, client: client)
            let pending = try store.loadPending()
            for retained in pending {
                let request = retained.request
                do {
                    let response = try await session.createWork(request)
                    guard response.receipt.state == .accepted
                        || response.receipt.state == .duplicate else {
                        // A structured rejection is definitive non-admission, so clear it rather
                        // than replaying a known-dead intent forever. Transport errors below are
                        // different: their effect may be indeterminate and must remain retained.
                        do {
                            guard rejectPendingChatAttempt(request.commandID) else { throw PendingChatError.conflict }
                            try store.clear(request)
                        } catch {
                            localWorkServiceCreateError =
                                "A rejected Work creation intent could not be cleared safely; new Work is withheld."
                            return false
                        }
                        localWorkServiceError =
                            response.receipt.rejection == .staleCursor
                                ? "A retained Work creation intent was stale and was cleared; retry Create to use the current Work Host cursor."
                                : "A retained Work creation intent was rejected and cleared; retry Create when ready."
                        continue
                    }
                    if let initialStart = retained.initialStart {
                        try associatePendingChat(request: request, response: response)
                        try Self.retainStartIntent(
                            initialStart, response: response, home: home, client: client)
                    }
                    try store.clear(request)
                } catch {
                    if Self.isProvenStaleCreateFailure(error) {
                        do {
                            guard rejectPendingChatAttempt(request.commandID) else { throw PendingChatError.conflict }
                            try store.clear(request)
                        } catch {
                            localWorkServiceCreateError =
                                "A stale Work creation intent could not be cleared safely; new Work is withheld."
                            return false
                        }
                        localWorkServiceError =
                            "A retained Work creation intent was stale and was cleared; retry Create to use the current Work Host cursor."
                        continue
                    }
                    localWorkServiceCreateError = Self.serviceErrorMessage(error)
                        + " New chats are paused until this saved Create attempt is reconciled."
                    return false
                }
            }
            localWorkServiceCreateError = nil
            localWorkServiceCreatesReconciled = true
            return true
        } catch {
            localWorkServiceCreateError =
                "A retained Work creation intent could not be read safely; new Work is withheld."
            return false
        }
    }

    /// Reconcile every host-minted Session request before admitting another one. Unlike a
    /// normal command, the identities in the result do not exist until the Work Host commits;
    /// only replaying the exact retained request can distinguish a lost response from no effect.
    private func reconcilePendingCreateSessionIntents(
        session: WorkServiceClientSession, client: ClientRef,
        mode: ServiceBackedGUIOrchestration.ReconciliationMode = .passivePolling
    ) async -> CreateSessionReconciliationOutcome {
        do {
            guard let handshake = await session.negotiatedHandshake else {
                localWorkServiceError =
                    "A retained Session creation could not be reconciled without a Work Host handshake."
                return .blocked
            }
            let store = try ServiceBackedCreateSessionIntentStore(
                home: home, client: client, host: handshake.host)
            var blockedMessage: String?
            var clearedMessage: String?
            var recoveredPresentationMessage: String?
            let pending = try store.load()
            var observations: [ServiceBackedGUIOrchestration.CreateSessionObservation] = []
            var recoveredResponses:
                [(ServiceBackedGUIOrchestration.RecoveredCreateSession,
                    WorkServiceCreateSessionResponse)] = []
            for request in pending {
                do {
                    let response = try await session.createSession(request)
                    guard Self.validCreateSessionResponse(
                        response, request: request, expectedHost: handshake.hostInstance) else {
                        blockedMessage = blockedMessage
                            ?? "The Work Host returned an invalid result for a retained Session creation; the exact intent remains pending."
                        observations.append(.init(request: request, outcome: .blocked))
                        continue
                    }
                    if response.state == .accepted || response.state == .duplicate {
                        guard let responseAttachment = response.attachment,
                              let responseKey = ServiceAttachmentKey(
                                  work: response.work.work, attachment: responseAttachment),
                              let recovery = ServiceBackedGUIOrchestration.RecoveredCreateSession(
                                  request: request, attachmentKey: responseKey) else {
                            blockedMessage = blockedMessage
                                ?? "The Work Host returned a Session identity that did not match the retained request; the exact intent remains pending."
                            observations.append(.init(request: request, outcome: .blocked))
                            continue
                        }
                        observations.append(
                            .init(request: request, outcome: .recovered(recovery)))
                        recoveredResponses.append((recovery, response))
                        continue
                    }
                    // A typed rejection proves the host did not mint the requested Session.
                    observations.append(.init(request: request, outcome: .rejected))
                    clearedMessage = response.rejection == .staleCursor
                        ? "A retained Session creation was stale and was cleared; retry against the current Work cursor."
                        : "A retained Session creation was rejected and cleared."
                } catch {
                    if Self.isDefinitiveCreateSessionFailure(error) {
                        observations.append(.init(request: request, outcome: .rejected))
                        clearedMessage =
                            "A retained Session creation was definitively rejected and cleared; retry against the current Work Host state."
                        continue
                    }
                    blockedMessage = blockedMessage
                        ?? "A retained Session creation has an indeterminate result; its exact request remains pending until the Work Host can reconcile it."
                    observations.append(.init(request: request, outcome: .blocked))
                }
            }

            // The pure decision owns the safety classification. AppModel only applies its
            // durable clears and presents the exact response facts it observed above.
            let decision = ServiceBackedGUIOrchestration.reconcileCreateSession(
                pending: pending, observations: observations, mode: mode)
            var clearedRequests: Set<WorkServiceCreateSessionRequest> = []
            var applicationBlocked = false
            for request in decision.cleared {
                do {
                    try store.clear(request)
                    clearedRequests.insert(request)
                } catch {
                    applicationBlocked = true
                    blockedMessage = blockedMessage
                        ?? "A retained Session creation could not be cleared safely; its exact intent remains pending."
                }
            }
            for recovery in decision.recoveries where clearedRequests.contains(recovery.request) {
                guard let response = recoveredResponses.first(where: {
                    $0.0 == recovery
                })?.1 else {
                    applicationBlocked = true
                    blockedMessage = blockedMessage
                        ?? "A recovered Session response could not be matched to its exact intent; the intent remains pending."
                    continue
                }
                if let message = await presentRecoveredCreateSession(
                    response, request: recovery.request, session: session, client: client,
                    focus: decision.shouldFocusRecovery) {
                    recoveredPresentationMessage = recoveredPresentationMessage ?? message
                }
            }
            let hasBlockedWork = !decision.retained.isEmpty
                || clearedRequests.count != decision.cleared.count
                || decision.recoveries.contains {
                    !clearedRequests.contains($0.request)
                }
            if applicationBlocked || hasBlockedWork {
                localWorkServiceError = blockedMessage
                    ?? "A retained Session creation remains pending and blocks a new mutation."
                return .blocked
            }
            if !decision.recoveries.isEmpty {
                localWorkServiceError = if let recoveredPresentationMessage {
                    recoveredPresentationMessage
                } else if clearedMessage != nil {
                    "Recovered an exact prior Session creation; another retained request was rejected and cleared. Choose New Session again only if you want another conversation."
                } else {
                    "Recovered the exact prior Session creation. Choose New Session again only if you want another conversation."
                }
                return .recovered
            }
            if let clearedMessage { localWorkServiceError = clearedMessage }
            return .clear
        } catch {
            localWorkServiceError =
                "Retained Session creation state could not be read safely; new Session creation is withheld."
            return .blocked
        }
    }

    @discardableResult
    private func presentRecoveredCreateSession(
        _ response: WorkServiceCreateSessionResponse,
        request: WorkServiceCreateSessionRequest,
        session: WorkServiceClientSession,
        client: ClientRef,
        focus: Bool = true
    ) async -> String? {
        if let index = localServiceCatalogWorks.firstIndex(where: {
            $0.work == response.work.work
        }) {
            localServiceCatalogWorks[index] = response.work
        } else {
            localServiceCatalogWorks.append(response.work)
        }
        guard let attachment = Self.currentCreateSessionAttachment(
            response, request: request) else {
            let message =
                "Recovered the exact prior Session creation, but this client is no longer attached to it. The Session remains available for inspection in the Work catalog."
            localWorkServiceError = message
            return message
        }
        return await adoptServiceAttachment(
            descriptor: response.work, attachment: attachment,
            session: session, client: client, focus: focus)
    }

    private static func isProvenStaleCreateFailure(_ error: Error) -> Bool {
        guard let transport = error as? WorkServiceTransportError else { return false }
        guard case .remote(let code, _) = transport else { return false }
        return code == .staleCursor
    }

    private static func hasCanonicalStartEvidence(
        _ initialStart: ServiceBackedStartIntent,
        projection: WorkServiceAttachedWorkProjection
    ) -> Bool {
        initialStart.hasCanonicalEvidence(in: projection)
    }

    private static func isProvenStaleAttachFailure(_ error: Error) -> Bool {
        if case WorkServiceProtocolError.staleCursor = error { return true }
        guard let transport = error as? WorkServiceTransportError,
              case .remote(let code, _) = transport else { return false }
        return code == .staleCursor
    }

    private static func isDefinitiveCreateSessionFailure(_ error: Error) -> Bool {
        if let protocolError = error as? WorkServiceProtocolError {
            switch protocolError {
            case .staleCursor, .attachmentNotFound, .capabilityDenied, .invalidRequest,
                 .workNotFound, .journalMismatch:
                return true
            case .unsupportedVersion, .hostUnavailable, .artifactNotFound,
                 .eventPageCannotProgress, .sourceIncomplete:
                return false
            }
        }
        guard let transport = error as? WorkServiceTransportError,
              case .remote(let code, _) = transport else { return false }
        switch code {
        case .staleCursor, .attachmentNotFound, .capabilityDenied, .invalidRequest,
             .workNotFound, .journalMismatch:
            return true
        default:
            return false
        }
    }

    private static func currentCreateSessionAttachment(
        _ response: WorkServiceCreateSessionResponse,
        request: WorkServiceCreateSessionRequest,
        requiringObserve: Bool = true
    ) -> WorkServiceClientAttachment? {
        guard let recorded = response.attachment else { return nil }
        let current = response.work.attachments.filter {
            $0.attachment == recorded.attachment
                && $0.client == request.client
                && $0.session == recorded.session
                && $0.sessionJournal == recorded.sessionJournal
                && $0.sessionAttachment == recorded.sessionAttachment
                && (!requiringObserve || $0.authorization.allows(.observe))
        }
        return current.count == 1 ? current[0] : nil
    }

    private static func validCreateSessionResponse(
        _ response: WorkServiceCreateSessionResponse,
        request: WorkServiceCreateSessionRequest,
        expectedHost: WorkHostInstanceRef
    ) -> Bool {
        guard response.work.work == request.work,
              response.work.journal == request.journal,
              response.commandID == request.commandID,
              response.host == expectedHost,
              response.causalControlCursor == request.causalControlCursor,
              response.causalWorkCursor == request.causalWorkCursor,
              response.receipt.operation == .createSession,
              response.receipt.work == request.work,
              response.receipt.commandID == request.commandID,
              response.receipt.state == response.state,
              response.receipt.host == response.host,
              response.receipt.causalControlCursor == request.causalControlCursor,
              response.receipt.resultingControlCursor == response.controlCursor,
              response.receipt.authorization == response.authorization,
              response.receipt.rejection == response.rejection,
              validServiceCursor(
                response.controlCursor,
                journal: .workHost(WorkHostRef(request.work.workHostID))),
              validServiceCursor(response.workCursor, journal: request.journal) else {
            return false
        }
        switch response.state {
        case .accepted, .duplicate:
            guard response.rejection == nil,
                  response.receipt.rejection == nil,
                  response.receipt.outcome == .sessionCreated,
                  let createdSession = response.session,
                  let sessionJournal = response.sessionJournal,
                  let sessionAttachment = response.sessionAttachment,
                  let clientAttachment = response.attachment,
                  let relationship = response.relationship,
                  let sessionCursor = response.sessionCursor,
                  sessionJournal.owner == .session(createdSession),
                  sessionJournal.authority.authorityID == request.work.workHostID,
                  validServiceCursor(sessionCursor, journal: sessionJournal),
                  relationship.session == createdSession,
                  relationship.sessionJournal == sessionJournal,
                  relationship.sessionAttachment == sessionAttachment,
                  relationship.causalWorkCursor == request.causalWorkCursor,
                  relationship.resultingWorkCursor == response.workCursor,
                  relationship.sessionCursor == sessionCursor,
                  relationship.capabilities == response.authorization.granted,
                  relationship.isAttached,
                  clientAttachment.attachment != request.attachment,
                  clientAttachment.client == request.client,
                  clientAttachment.session == createdSession,
                  clientAttachment.sessionJournal == sessionJournal,
                  clientAttachment.sessionAttachment == sessionAttachment,
                  response.work.sessionAttachments.filter({
                      $0.session == createdSession
                          && $0.sessionJournal == sessionJournal
                          && $0.sessionAttachment == sessionAttachment
                  }) == [relationship] else {
                return false
            }
            if response.state == .accepted {
                guard clientAttachment.authorization == response.authorization,
                      Self.currentCreateSessionAttachment(
                          response, request: request, requiringObserve: false)
                        == clientAttachment else { return false }
            } else {
                // Exact duplicate replay returns the original immutable publication facts but
                // the attachment's current capabilities while it remains attached. Once it has
                // been detached, the response carries the verified historical minted row only
                // for identity correlation: it must be absent from the descriptor and retain the
                // immutable publication authorization, so the GUI cannot adopt it as authority.
                let rowsWithMintedIdentity = response.work.attachments.filter {
                    $0.attachment == clientAttachment.attachment
                }
                if rowsWithMintedIdentity.isEmpty {
                    guard clientAttachment.authorization == response.authorization else {
                        return false
                    }
                } else {
                    guard rowsWithMintedIdentity == [clientAttachment],
                          Self.currentCreateSessionAttachment(
                              response, request: request, requiringObserve: false)
                            == clientAttachment else { return false }
                }
            }
            return true
        case .rejected:
            return response.rejection != nil
                && response.receipt.outcome == nil
                && response.session == nil
                && response.sessionJournal == nil
                && response.sessionAttachment == nil
                && response.attachment == nil
                && response.relationship == nil
                && response.sessionCursor == nil
        }
    }

    private static func validServiceCursor(
        _ cursor: JournalCursor, journal: JournalRef
    ) -> Bool {
        cursor.journal == journal
            && cursor.sequence >= 0
            && cursor.sequence < Int.max
            && (cursor.sequence == 0
                ? cursor.eventID == nil
                : cursor.eventID.map({
                    !$0.isEmpty
                        && $0.utf8.count <= WorkServiceBounds.maxIdentityCharacters
                        && !$0.unicodeScalars.contains(where: { $0.value == 0 })
                }) == true)
    }

    private static func retainStartIntent(
        _ seed: ServiceBackedCreateIntentStore.InitialStart,
        response: WorkServiceCreateWorkResponse,
        home: AgentHome,
        client: ClientRef
    ) throws {
        let intent = try ServiceBackedStartIntent(
            seed: seed, response: response, client: client)
        guard let key = ServiceAttachmentKey(
            work: response.work.work, attachment: response.attachment) else {
            throw ServiceBackedStartIntentError.invalid
        }
        let store = try ServiceBackedStartIntentStore(
            home: home, key: key)
        try store.retain(intent)
    }

    /// The shared client session intentionally caches its handshake, while a Work Host's control
    /// cursor advances after every Create/Attach. Probe a fresh auxiliary session for current
    /// catalog/cursor evidence without disconnecting the shared session used by controllers.
    private func freshLocalWorkServiceHandshake(
        client: ClientRef
    ) async throws -> WorkServiceHandshakeResponse {
        let workHost = try home.requirePersistedWorkHost()
        let locator = LocalWorkServiceHostLocator(home: home, workHost: workHost)
        let probe = try WorkServiceClientSession(locator: locator, client: client)
        do {
            let handshake = try await probe.connect()
            await probe.disconnect()
            return handshake
        } catch {
            await probe.disconnect()
            throw error
        }
    }

    /// Explicitly attach this GUI client to a Work discovered in the complete host catalog.
    /// The catalog row is re-read immediately before the mutation. Attach identity is scoped to
    /// the exact causal control cursor, Session tuple, and capability envelope, so a lost
    /// response can be retried exactly while a real Detach followed by Attach creates a new
    /// logical attachment epoch.
    func serviceAttachTargets(for descriptor: WorkServiceWorkDescriptor) -> [WorkSessionKey] {
        descriptor.attachmentQualifiedSessionTargets
    }

    func serviceAttachIsInFlight(_ target: WorkSessionKey) -> Bool {
        serviceAttachesInFlight.contains(target)
    }

    func attachServiceWork(
        _ descriptor: WorkServiceWorkDescriptor,
        targetSessionAttachment: SessionAttachmentRef,
        destination: Section = .live
    ) {
        guard acceptsNewWork,
              let client = localWorkServiceClient, localWorkService != nil else {
            localWorkServiceError = "The local Work Host is not connected."
            return
        }
        guard let target = descriptor.exactAttachmentQualifiedSessionTarget(
            targetSessionAttachment) else {
            localWorkServiceError =
                "This Work does not expose one exact Session relationship for Attach."
            return
        }
        guard serviceAttachesInFlight.insert(target).inserted else { return }
        localWorkServiceError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.serviceAttachesInFlight.remove(target) }
            await self.attachServiceWorkNow(
                descriptor, targetSessionAttachment: targetSessionAttachment, client: client,
                destination: destination)
        }
    }

    private func attachServiceWorkNow(
        _ requested: WorkServiceWorkDescriptor,
        targetSessionAttachment: SessionAttachmentRef,
        client: ClientRef,
        destination: Section
    ) async {
        guard localWorkService != nil, beginServiceLifecycleOperation() else { return }
        defer { finishServiceLifecycleOperation() }
        do {
            // Attach is a mutation too: fence the shared socket and fresh cursor to one exact
            // Work Host instance before reading or dispatching against the catalog. A locator
            // replacement must never let a fresh probe B authorize an Attach sent to live A.
            let (session, handshake) = try await reconnectLocalWorkService()
            guard handshake.host.workHostID == requested.work.workHostID,
                  handshake.workspaceCatalog.isComplete,
                  handshake.hostInstance.host == handshake.host else {
                throw LocalWorkServiceBootstrapError.connectionFailed(.notConnected)
            }
            let catalog = await WorkServiceCatalog().refresh([
                WorkServiceCatalogHost(host: handshake.host, session: session)
            ])
            let rowLocalQuarantineOnly = catalog.hosts.count == 1
                && catalog.hosts[0].sourceCompleteness != .complete
                && !catalog.hosts[0].quarantined.isEmpty
                && catalog.hosts[0].diagnostics.isEmpty
            guard let host = catalog.hosts.first,
                  connectionIsUsable(host.connectionState),
                  host.omissions.isEmpty,
                  host.negotiatedInstance == handshake.hostInstance,
                  host.sourceCompleteness == .complete || rowLocalQuarantineOnly,
                  let descriptor = catalog.works.first(where: {
                      $0.work == requested.work
                  }) else {
                localWorkServiceError =
                    "The Work Host catalog changed or is incomplete; Attach was withheld."
                return
            }
            // Resolve the target only from the host's semantic relationship projection; never
            // choose the first Session on a Work because ordering is not identity.
            guard let inspectDecision = ServiceBackedGUIOrchestration.inspect(
                descriptor: descriptor,
                client: client,
                targetSessionAttachment: targetSessionAttachment) else {
                localWorkServiceError =
                    "This Work does not expose one exact Session relationship for Attach."
                return
            }
            let target = inspectDecision.target.workSession
            let targetKey = inspectDecision.target
            if let existing = inspectDecision.existingAttachment {
                await adoptServiceAttachment(
                    descriptor: descriptor, attachment: existing,
                    session: session, client: client, focus: inspectDecision.shouldFocus,
                    destination: destination)
                return
            }
            let requestedCapabilities: Set<WorkServiceCapability> = [
                .observe, .control, .start, .send, .steer, .queue, .cancel, .end,
                .inspectArtifacts, .createSession,
            ]
            let pending = pendingServiceAttaches[targetKey]
            let request: WorkServiceAttachRequest
            if let pending,
               pending.hostInstance == handshake.hostInstance,
               pending.request.work == descriptor.work,
               pending.request.journal == descriptor.journal,
               pending.request.client == client,
               pending.request.session == target.session,
               pending.request.sessionJournal == target.sessionJournal,
               pending.request.sessionAttachment == target.sessionAttachment,
               pending.request.requestedCapabilities == requestedCapabilities,
               pending.request.causalControlCursor.journal == handshake.controlJournal {
                // This is the exact lost-response retry. Do not mint a new id from the newer
                // handshake cursor: doing so could create a second client attachment.
                request = pending.request
            } else {
                let commandMaterial = Self.attachCommandMaterial(
                    client: client, work: descriptor.work,
                    session: target.session, sessionJournal: target.sessionJournal,
                    sessionAttachment: target.sessionAttachment,
                    capabilities: requestedCapabilities,
                    controlJournal: handshake.controlJournal,
                    causalControlCursor: handshake.controlCursor)
                let digest = SHA256.hash(data: Data(commandMaterial.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                request = WorkServiceAttachRequest(
                    work: descriptor.work,
                    journal: descriptor.journal,
                    client: client,
                    session: target.session,
                    sessionJournal: target.sessionJournal,
                    sessionAttachment: target.sessionAttachment,
                    commandID: "attach-v2-\(digest.prefix(48))",
                    causalControlCursor: handshake.controlCursor,
                    requestedCapabilities: requestedCapabilities)
            }
            pendingServiceAttaches[targetKey] = PendingServiceAttach(
                request: request, hostInstance: handshake.hostInstance)
            let response: WorkServiceAttachResponse
            do {
                response = try await session.attach(request)
            } catch {
                if Self.isProvenStaleAttachFailure(error) {
                    // A typed stale_cursor response proves this exact Attach was not admitted.
                    // Do not preserve an exact request whose cursor can never become current;
                    // clear it and obtain fresh host/catalog evidence before exposing Attach
                    // again.
                    pendingServiceAttaches.removeValue(forKey: targetKey)
                    await refreshAfterStaleAttach(session)
                    return
                }
                // Transport uncertainty retains the exact request. A subsequent catalog read
                // can prove it committed; no fresh Attach is synthesized here.
                throw error
            }
            guard (response.state == .accepted || response.state == .duplicate),
                  let attachment = response.attachment else {
                pendingServiceAttaches.removeValue(forKey: targetKey)
                if response.rejection == .staleCursor {
                    await refreshAfterStaleAttach(session)
                    return
                }
                localWorkServiceError =
                    "The Work Host rejected Attach: "
                        + (response.diagnostic ?? "no attachment was admitted.")
                return
            }
            pendingServiceAttaches.removeValue(forKey: targetKey)
            await adoptServiceAttachment(
                descriptor: response.work, attachment: attachment,
                session: session, client: client, focus: inspectDecision.shouldFocus,
                destination: destination)
            if let index = localServiceCatalogWorks.firstIndex(where: { $0.work == descriptor.work }) {
                // Keep the Work row: its other Session relationships remain independently
                // attachable/inspectable after this client attaches one exact target.
                localServiceCatalogWorks[index] = response.work
            }
        } catch {
            localWorkServiceError = Self.serviceErrorMessage(error)
        }
    }

    private func refreshAfterStaleAttach(_ session: WorkServiceClientSession) async {
        do {
            let refreshed = try await session.refreshHandshake()
            localWorkServiceHandshake = refreshed
            localWorkspaceCatalog = refreshed.workspaceCatalog
            await refreshServiceWork()
            localWorkServiceError =
                "The Work Host rejected Attach because its cursor was stale. The pending intent was cleared and the catalog was refreshed."
        } catch {
            localWorkServiceError =
                "The Work Host rejected Attach because its cursor was stale. The pending intent was cleared; reconnect before trying again."
        }
    }

    /// Exact client attachments that may authorize a host-minted Session on this Work. Multiple
    /// entries remain separate: choosing one is part of the mutation identity and must never be
    /// inferred from array order.
    func serviceSessionCreationAuthorizers(
        for descriptor: WorkServiceWorkDescriptor
    ) -> [WorkServiceClientAttachment] {
        guard descriptor.omissions.isEmpty,
              descriptor.hostObservation?.sourceCompleteness == .complete,
              let client = localWorkServiceClient else { return [] }
        return descriptor.attachments.filter {
            $0.client == client
                && $0.authorization.allows(.createSession)
                && ServiceAttachmentKey(work: descriptor.work, attachment: $0) != nil
        }.sorted { $0.attachment.attachmentID < $1.attachment.attachmentID }
    }

    func createServiceSession(
        _ descriptor: WorkServiceWorkDescriptor,
        authorizingAttachment: ClientAttachmentRef
    ) {
        guard acceptsNewWork,
              let client = localWorkServiceClient, localWorkService != nil else {
            localWorkServiceError = "The local Work Host is not connected."
            return
        }
        Task { @MainActor [weak self] in
            await self?.createServiceSessionNow(
                descriptor, authorizingAttachment: authorizingAttachment, client: client)
        }
    }

    private func createServiceSessionNow(
        _ requested: WorkServiceWorkDescriptor,
        authorizingAttachment: ClientAttachmentRef,
        client: ClientRef
    ) async {
        guard beginServiceLifecycleOperation() else { return }
        defer { finishServiceLifecycleOperation() }
        guard !serviceSessionCreationsInFlight.contains(requested.work) else {
            localWorkServiceError =
                "A Session creation is already in progress for this Work."
            return
        }
        serviceSessionCreationsInFlight.insert(requested.work)
        defer { serviceSessionCreationsInFlight.remove(requested.work) }
        do {
            let (session, initialHandshake) = try await reconnectLocalWorkService()
            guard initialHandshake.host == WorkHostRef(requested.work.workHostID) else {
                return
            }
            let reconciliation = await reconcilePendingCreateSessionIntents(
                session: session, client: client, mode: .explicitCreate)
            guard reconciliation != .blocked else { return }
            guard reconciliation != .recovered else {
                // The click served as the exact retry for a prior lost response. Requiring a
                // second explicit click is what prevents one gesture from minting two Sessions.
                return
            }
            let handshake = try await session.refreshHandshake()
            guard handshake.host == initialHandshake.host,
                  handshake.hostInstance == initialHandshake.hostInstance else {
                await session.disconnect()
                throw LocalWorkServiceBootstrapError.connectionFailed(.notConnected)
            }
            // Re-read after reconciliation because a recovered result may have advanced both
            // Work and control cursors and added the very relationship this GUI was missing.
            let catalog = await WorkServiceCatalog().refresh([
                WorkServiceCatalogHost(host: handshake.host, session: session)
            ])
            guard let host = catalog.hosts.first,
                  catalog.hosts.count == 1,
                  connectionIsUsable(host.connectionState),
                  host.omissions.isEmpty,
                  host.diagnostics.isEmpty,
                  host.quarantined.isEmpty,
                  host.sourceCompleteness == .complete,
                  host.negotiatedInstance == handshake.hostInstance,
                  let descriptor = catalog.works.first(where: { $0.work == requested.work }),
                  descriptor.journal == requested.journal,
                  descriptor.omissions.isEmpty,
                  descriptor.hostObservation?.sourceCompleteness == .complete,
                  let causalWorkCursor = descriptor.hostObservation?.servedCursor,
                  Self.validServiceCursor(causalWorkCursor, journal: descriptor.journal) else {
                localWorkServiceError =
                    "The Work Host catalog is not complete enough to create a Session."
                return
            }
            let authorizers = serviceSessionCreationAuthorizers(for: descriptor).filter {
                $0.attachment == authorizingAttachment
            }
            guard authorizers.count == 1 else {
                localWorkServiceError =
                    "The selected client attachment no longer uniquely authorizes Session creation."
                return
            }
            let requestedCapabilities: Set<WorkServiceCapability> = [
                .observe, .control, .start, .send, .steer, .queue, .cancel, .end,
                .inspectArtifacts,
            ]
            let request = WorkServiceCreateSessionRequest(
                work: descriptor.work, journal: descriptor.journal,
                attachment: authorizingAttachment, client: client,
                commandID: "create-session-v1-" + UUID().uuidString.lowercased(),
                causalControlCursor: handshake.controlCursor,
                causalWorkCursor: causalWorkCursor,
                requestedCapabilities: requestedCapabilities)
            let store = try ServiceBackedCreateSessionIntentStore(
                home: home, client: client, host: handshake.host)
            try store.retain(request)
            let response: WorkServiceCreateSessionResponse
            do {
                response = try await session.createSession(request)
            } catch {
                if Self.isDefinitiveCreateSessionFailure(error) {
                    try store.clear(request)
                    localWorkServiceError =
                        "Session creation was definitively rejected before admission; its retained request was cleared."
                    return
                }
                localWorkServiceError =
                    "Session creation has an indeterminate result; its exact request was retained for reconciliation."
                return
            }
            guard Self.validCreateSessionResponse(
                response, request: request, expectedHost: handshake.hostInstance) else {
                localWorkServiceError =
                    "The Work Host returned an invalid Session creation result; its exact request remains retained."
                return
            }
            guard response.state == .accepted || response.state == .duplicate else {
                try store.clear(request)
                localWorkServiceError = response.rejection == .staleCursor
                    ? "Session creation was not admitted because its cursor was stale; refresh and try again."
                    : "The Work Host rejected Session creation: "
                        + (response.diagnostic ?? "no Session was minted.")
                return
            }
            do {
                try store.clear(request)
            } catch {
                // The exact retry is safe and will resolve as duplicate on launch. Continue to
                // display the canonical result while making the cleanup failure visible.
                localWorkServiceError =
                    "The Session was created, but its local reconciliation marker could not be cleared."
            }
            localServiceCatalogWorks = catalog.works.map {
                $0.work == response.work.work ? response.work : $0
            }
            await presentRecoveredCreateSession(
                response, request: request, session: session, client: client, focus: true)
        } catch {
            localWorkServiceError = Self.serviceErrorMessage(error)
        }
    }

    private static func attachCommandMaterial(
        client: ClientRef,
        work: WorkRef,
        session: SessionRef,
        sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef,
        capabilities: Set<WorkServiceCapability>,
        controlJournal: JournalRef,
        causalControlCursor: JournalCursor
    ) -> String {
        let capabilityMaterial = capabilities.map(\.rawValue).sorted().joined(separator: ",")
        let fields = [
            client.clientID, work.workHostID, work.workID,
            session.sessionID, sessionJournal.journalID,
            sessionJournal.authority.authorityID, sessionAttachment.attachmentID,
            capabilityMaterial, controlJournal.journalID,
            controlJournal.authority.authorityID, String(causalControlCursor.sequence),
            causalControlCursor.eventID ?? "",
        ]
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    /// Refresh all attached service projections and discover attachments created by another
    /// GUI.  The Work service list is intentionally authoritative for reconstruction; local
    /// `runs` is only this process's current view.
    func refreshServiceWork() async {
        guard !serviceRefreshInFlight,
              let bootstrap = localWorkService,
              let client = localWorkServiceClient,
              beginServiceLifecycleOperation() else { return }
        serviceRefreshInFlight = true
        defer {
            serviceRefreshInFlight = false
            finishServiceLifecycleOperation()
        }
        do {
            let session = try await bootstrap.connect()
            // Polling is the single central observation owner. A fresh auxiliary connection is
            // reserved for mutation admission (Create/Attach), not every timer tick; opening a
            // second socket per poll would turn a bounded poll into connection churn. The shared
            // session's handshake is already fenced by each successful response and is replaced
            // by an explicit reconnect when its transport becomes unusable.
            guard let handshake = await session.negotiatedHandshake else {
                throw LocalWorkServiceBootstrapError.connectionFailed(.notConnected)
            }
            localWorkServiceHandshake = handshake
            localWorkspaceCatalog = handshake.workspaceCatalog
            let sessionsReconciled = localWorkServiceCreatesReconciled
                ? await reconcilePendingCreateSessionIntents(session: session, client: client) != .blocked
                : false
            let resumeInitialStart = localWorkServiceCreatesReconciled && sessionsReconciled
            let reconciliationWarning = localWorkServiceObservationError
            // Detached service rows still own this GUI's durable attachment and must continue
            // receiving canonical updates. Presentation detachment is not an observation opt-out.
            let attachedServiceRuns = workRuns
                .filter { $0.isServiceBacked && !$0.hasExited }
                .sorted { lhs, rhs in lhs.id.uuidString < rhs.id.uuidString }
            let selectedServiceRuns: [LiveRun]
            if attachedServiceRuns.isEmpty {
                servicePollOffset = 0
                selectedServiceRuns = []
            } else {
                let offset = servicePollOffset % attachedServiceRuns.count
                let budget = min(32, attachedServiceRuns.count)
                selectedServiceRuns = (0..<budget).map { index in
                    attachedServiceRuns[(offset + index) % attachedServiceRuns.count]
                }
                servicePollOffset = (offset + budget) % attachedServiceRuns.count
            }
            for run in selectedServiceRuns {
                await run.refreshService(resumeInitialStart: resumeInitialStart)
            }
            await restoreServiceWork(
                session: session, client: client, handshake: handshake,
                resumeInitialStart: resumeInitialStart)
            if !sessionsReconciled, localWorkServiceObservationError == nil {
                localWorkServiceObservationError = reconciliationWarning
            }
        } catch {
            localWorkServiceError = Self.serviceErrorMessage(error)
        }
    }

    /// Closing Aviary removes only this GUI's transport attachment.  It never sends End,
    /// Complete, Destroy, or a process signal to service-backed Work.
    func disconnectLocalWorkService() async {
        localWorkServiceCreatesReconciled = false
        for run in workRuns where run.isServiceBacked { await run.disconnect() }
        await localWorkService?.disconnect()
        localWorkServiceHandshake = nil
        localWorkspaceCatalog = .empty
        localServiceCatalogWorks = []
    }

    private func reconnectLocalWorkService() async throws
        -> (session: WorkServiceClientSession, handshake: WorkServiceHandshakeResponse)
    {
        guard let bootstrap = localWorkService else {
            throw LocalWorkServiceBootstrapError.discoveryFailed
        }
        let session = try await bootstrap.connect()
        guard let client = localWorkServiceClient else {
            throw LocalWorkServiceBootstrapError.discoveryFailed
        }
        let sharedHandshake: WorkServiceHandshakeResponse
        do {
            sharedHandshake = try await session.refreshHandshake()
        } catch {
            await session.disconnect()
            localWorkServiceHandshake = nil
            localWorkspaceCatalog = .empty
            throw error
        }
        let probeHandshake: WorkServiceHandshakeResponse
        do {
            probeHandshake = try await freshLocalWorkServiceHandshake(client: client)
        } catch {
            throw error
        }
        guard sharedHandshake.host == probeHandshake.host,
              sharedHandshake.hostInstance == probeHandshake.hostInstance else {
            // The locator may have moved from daemon A to daemon B while the shared socket was
            // still alive. Never dispatch a mutation using B's cursor on A's connection; poison
            // the cached session so the next attempt discovers the new instance.
            await session.disconnect()
            localWorkServiceHandshake = nil
            localWorkspaceCatalog = .empty
            throw LocalWorkServiceBootstrapError.connectionFailed(.notConnected)
        }
        localWorkServiceHandshake = probeHandshake
        localWorkspaceCatalog = probeHandshake.workspaceCatalog
        return (session, probeHandshake)
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
        guard !catalogRefreshInFlight else { return }
        catalogRefreshInFlight = true
        defer { catalogRefreshInFlight = false }
        isScanning = true
        canonicalNotificationCatalogScanComplete = false
        let result = await catalog.scanCatalog { [weak self] done, total in
            Task { @MainActor in self?.scanProgress = (done, total) }
        }
        let projectionIndex = SessionCatalogProjectionIndex(entries: result.entries)
        canonicalCatalogProjections = projectionIndex.canonicalByID
        canonicalCatalogProjectionConflicts = projectionIndex.duplicateIDs
        canonicalSessionSearchIndex = CanonicalSessionSearchIndex(entries: projectionIndex.displayEntries)
        var duplicateNotificationDisplayKeys: Set<String> = []
        canonicalNotificationDisplayIDs = projectionIndex.displayEntries.reduce(into: [:]) { result, entry in
            guard let canonical = entry.canonical, let display = entry.displaySummary else { return }
            let key = CanonicalAttentionIdentity.sessionRow(journal: canonical.journal)
            // A duplicate identity is not a safe deep-link target. Leave the key absent rather
            // than choosing whichever display row happened to be visited last.
            if !duplicateNotificationDisplayKeys.contains(key), result[key] == nil {
                result[key] = display.id
            } else {
                result.removeValue(forKey: key)
                duplicateNotificationDisplayKeys.insert(key)
            }
        }
        canonicalWorkInventory = result.workInventory
        let nativeSummaries = result.entries.compactMap { entry -> CanonicalSessionCatalogSummary? in
            switch entry {
            case .canonical(let summary): return summary
            case .companion(let companion): return companion.canonical
            case .legacy: return nil
            }
        }
        canonicalFlockInventory = CanonicalFlockCatalogProjection.project(
            sessions: nativeSummaries, works: result.workInventory)
        canonicalAttentionInbox = CanonicalAttentionInboxProjection(summaries: nativeSummaries)
        canonicalWorkspaceRail = canonicalAttentionInbox.workspaceRail(
            summaries: nativeSummaries,
            sourceComplete: result.canonicalNotificationSourceComplete)
        let priorTranscriptPages = canonicalWorkspaceTranscripts
        var transcriptPages: [String: CanonicalWorkspaceTranscriptPage] = [:]
        var duplicateTranscriptIDs: Set<String> = []
        for summary in nativeSummaries {
            let key = CanonicalAttentionIdentity.sessionRow(journal: summary.journal)
            if transcriptPages[key] == nil, !duplicateTranscriptIDs.contains(key) {
                // An exact append-only cursor identifies the same visible Session projection.
                // Reuse its already-mapped page on unchanged polls; a new cursor rebuilds once.
                if let cursor = summary.sessionSnapshotCursor,
                   let prior = priorTranscriptPages[key],
                   prior.sourceCursor == cursor {
                    transcriptPages[key] = prior
                } else {
                    transcriptPages[key] = CanonicalWorkspaceTranscriptPage(summary: summary)
                }
            } else {
                transcriptPages.removeValue(forKey: key)
                duplicateTranscriptIDs.insert(key)
            }
        }
        canonicalWorkspaceTranscripts = transcriptPages
        let notifications = CanonicalNotificationProjection(
            summaries: nativeSummaries,
            sourceComplete: result.canonicalNotificationSourceComplete)
        canonicalWorkRecoveryProjection = CanonicalWorkRecoveryProjection(
            works: result.workInventory, sessions: nativeSummaries,
            sourceComplete: result.canonicalNotificationSourceComplete)
        canonicalNotificationProjection = notifications
        // Scan completeness is about global discovery. Row-local conflicts remain omitted from
        // the projection, but healthy rows can still resolve cold routes during this pass.
        canonicalNotificationCatalogScanComplete = result.canonicalNotificationSourceComplete
        await refreshCanonicalNotificationAuthorization()
        if !notifications.isComplete {
            canonicalNotificationError =
                "Canonical notification state is incomplete; notifications are withheld until the next exact scan."
        } else if canonicalNotificationDeliveryEnabled {
            canonicalNotificationError = nil
            let plan = notificationDelivery.plan(notifications)
            persistNotificationCheckpoint()
            for candidate in plan.candidates {
                deliverCanonicalNotification(candidate)
            }
        } else {
            // Unauthorized observations still advance the baseline. Enabling notifications later
            // must report only a fresh transition, not every old attention row.
            notificationDelivery.baseline(notifications)
            persistNotificationCheckpoint()
            canonicalNotificationError = nil
        }
        nativeTimelineCatalogDiagnostics = result.diagnostics
        nativeActionBlockedSessionIDs = result.nativeActionBlockedSessionIDs
        nativeCompanionLegacyIDs = result.nativeCompanionLegacyIDs
        var catalogIssues: [String] = []
        if !projectionIndex.duplicateIDs.isEmpty {
            catalogIssues.append(
                "Duplicate canonical catalog ids: "
                    + projectionIndex.duplicateIDs.joined(separator: ", "))
        }
        if !canonicalSessionSearchIndex.duplicateCanonicalIdentities.isEmpty {
            catalogIssues.append(
                "Canonical Session search withheld "
                    + "\(canonicalSessionSearchIndex.duplicateCanonicalIdentities.count) conflicting journal identity claim(s)")
        }
        if !result.diagnostics.isEmpty {
            let kinds = Array(Set(result.diagnostics.map(\.kind))).sorted()
            catalogIssues.append(
                "Native Timeline catalog: \(result.diagnostics.count) issue(s)"
                    + (kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))"))
        }
        catalogError = catalogIssues.isEmpty ? nil : catalogIssues.joined(separator: "; ")
        // The index owns first-seen identity deduplication. Feeding all adapted entries directly
        // to the list would give SwiftUI duplicate tags and make selection nondeterministic.
        let found = projectionIndex.displaySummaries
        sessions = found
        // A route is exact evidence only for the catalog snapshot that admitted it. Polling can
        // resolve an indeterminate action or advance either journal while the inspector remains
        // open, so revalidate the focus on every scan instead of waiting for another click.
        if let focus = canonicalNotificationFocus,
           let staleReason = canonicalNotificationStaleReason(focus)
        {
            canonicalNotificationFocus = nil
            canonicalNotificationError = staleReason
            if !canonicalNotificationCatalogScanComplete {
                enqueuePendingCanonicalNotificationRoute(focus)
            }
        }
        drainPendingCanonicalNotificationRoutes(
            scanComplete: result.canonicalNotificationSourceComplete)
        tree = AgentTreeReader.read(home: home)
        // Native canonical-only rows are not legacy transcript accounting inputs. Keep them in
        // the list, but do not turn their observe-only zero counters into analytics evidence.
        analytics = UsageAnalytics.build(from: found.filter { !$0.isCanonicalOnly })
        isScanning = false
        annotateLiveState()
        lastRefresh = Date()
    }

    private let notificationCheckpointKey = "aviary.canonical-notification-checkpoint.v2"
    private var notificationDelivery = CanonicalNotificationDelivery(
        checkpoint: UserDefaults.standard.data(forKey: "aviary.canonical-notification-checkpoint.v2"))

    private func persistNotificationCheckpoint() {
        guard let data = notificationDelivery.checkpointData else { return }
        UserDefaults.standard.set(data, forKey: notificationCheckpointKey)
    }

    var canonicalNotificationDeliveryEnabled: Bool {
        canonicalNotificationAuthorization == .authorized
            || canonicalNotificationAuthorization == .provisional
    }

    var canonicalNotificationNeedsSystemSettings: Bool {
        canonicalNotificationAuthorization == .denied
    }

    var canonicalNotificationStatusText: String {
        switch canonicalNotificationAuthorization {
        case .authorized: return "Enabled"
        case .provisional: return "Enabled quietly"
        case .denied: return "Disabled in System Settings"
        case .notDetermined: return "Not enabled"
        @unknown default: return "Status unavailable"
        }
    }

    var canonicalNotificationFocusForSelectedSession: CanonicalNotificationRoute? {
        guard let focus = canonicalNotificationFocus,
              let rowID = canonicalNotificationDisplayIDs[focus.sessionIdentityKey],
              rowID == selectedSessionID
        else { return nil }
        return focus
    }

    /// Read authorization without prompting. This is intentionally called before the delivery
    /// gate so a denied/not-yet-enabled user never sees an add-request error in the poll loop.
    func refreshCanonicalNotificationAuthorization() async {
        guard CanonicalNotificationPlatform.isAvailable else {
            canonicalNotificationAuthorization = .notDetermined
            canonicalNotificationAuthorizationError = nil
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        canonicalNotificationAuthorization = settings.authorizationStatus
        canonicalNotificationAuthorizationError = nil
    }

    /// The only code path allowed to ask macOS for notification permission. It is reachable from
    /// Preferences, never from launch/bootstrap or the polling loop.
    func requestCanonicalNotificationAuthorization() async {
        guard CanonicalNotificationPlatform.isAvailable else {
            canonicalNotificationAuthorizationError =
                "Notifications are available only from the Aviary app bundle."
            return
        }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await refreshCanonicalNotificationAuthorization()
        } catch {
            canonicalNotificationAuthorizationError =
                "Could not update notification permission: " + error.localizedDescription
        }
    }

    /// Deliver only candidates admitted by the core transition gate. The userInfo is the typed
    /// Session/action identity used by the click handler; no legacy transcript path is involved.
    private func deliverCanonicalNotification(_ candidate: CanonicalNotificationCandidate) {
        guard CanonicalNotificationPlatform.isAvailable else {
            notificationDelivery.rollback(candidate)
            canonicalNotificationError =
                "Notification delivery is unavailable outside the Aviary app bundle."
            return
        }
        guard let routeUserInfo = candidate.routeUserInfo else {
            // A route that cannot fit the bounded OS payload is not retryable. Commit its
            // transition and surface one truthful status instead of retrying on every poll.
            notificationDelivery.commit(candidate)
            persistNotificationCheckpoint()
            canonicalNotificationError =
                "Notification withheld because its canonical route exceeded the size limit."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.body
        content.sound = .default
        content.userInfo = routeUserInfo
        let request = UNNotificationRequest(
            identifier: candidate.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.notificationDelivery.rollback(candidate)
                    self?.canonicalNotificationError = "Could not deliver notification: \(error.localizedDescription)"
                } else {
                    self?.notificationDelivery.commit(candidate)
                    self?.persistNotificationCheckpoint()
                }
            }
        }
    }

    /// Route an already-decoded, identity-validated notification. Cold clicks are bounded until
    /// the next complete catalog scan can resolve their canonical Session/display join.
    func openCanonicalNotification(_ route: CanonicalNotificationRoute) {
        guard route.isValid else {
            canonicalNotificationFocus = nil
            canonicalNotificationError = "Dropped an invalid canonical notification route."
            return
        }
        canonicalNotificationFocus = nil
        let rowID = canonicalNotificationDisplayIDs[route.sessionIdentityKey]
        guard let rowID, let session = sessions.first(where: { $0.id == rowID }) else {
            if canonicalNotificationCatalogScanComplete {
                canonicalNotificationError =
                    "Dropped an unresolved cold notification route after a complete catalog scan."
                return
            }
            enqueuePendingCanonicalNotificationRoute(route)
            return
        }
        section = .sessions
        selectedSessionIDs = [session.id]
        selectedSessionID = session.id
        if let staleReason = canonicalNotificationStaleReason(route) {
            canonicalNotificationError = staleReason
            if !canonicalNotificationCatalogScanComplete {
                enqueuePendingCanonicalNotificationRoute(route)
            }
        } else {
            canonicalNotificationFocus = route
            canonicalNotificationError = nil
        }
        selectedItemForSessionSelectionChanged()
    }

    private func enqueuePendingCanonicalNotificationRoute(_ route: CanonicalNotificationRoute) {
        let key = route.deduplicationKey
        guard pendingCanonicalNotificationRouteKeys.insert(key).inserted else { return }
        pendingCanonicalNotificationRoutes.append(route)
        if pendingCanonicalNotificationRoutes.count > Self.maximumPendingCanonicalNotificationRoutes,
           let dropped = pendingCanonicalNotificationRoutes.first
        {
            pendingCanonicalNotificationRoutes.removeFirst()
            pendingCanonicalNotificationRouteKeys.remove(dropped.deduplicationKey)
            canonicalNotificationError =
                "Dropped the oldest cold notification route because the queue is full."
        }
    }

    private func drainPendingCanonicalNotificationRoutes(scanComplete: Bool) {
        guard !pendingCanonicalNotificationRoutes.isEmpty else { return }
        let pending = pendingCanonicalNotificationRoutes
        pendingCanonicalNotificationRoutes.removeAll()
        pendingCanonicalNotificationRouteKeys.removeAll()
        var unresolved = 0
        for route in pending {
            guard let rowID = canonicalNotificationDisplayIDs[route.sessionIdentityKey],
                  let session = sessions.first(where: { $0.id == rowID })
            else {
                if !scanComplete {
                    enqueuePendingCanonicalNotificationRoute(route)
                    continue
                }
                unresolved += 1
                continue
            }
            section = .sessions
            selectedSessionIDs = [session.id]
            selectedSessionID = session.id
            canonicalNotificationFocus = nil
            if !scanComplete {
                // The Session join is useful immediately, but an incomplete catalog cannot
                // establish whether the old route is current or stale. Keep the route for the
                // next complete scan instead of consuming it as a false stale click.
                canonicalNotificationError =
                    "Notification evidence is pending a complete catalog scan."
                enqueuePendingCanonicalNotificationRoute(route)
                selectedItemForSessionSelectionChanged()
                continue
            }
            if let staleReason = canonicalNotificationStaleReason(route) {
                canonicalNotificationError = staleReason
            } else {
                canonicalNotificationFocus = route
                canonicalNotificationError = nil
            }
            selectedItemForSessionSelectionChanged()
        }
        if unresolved > 0 {
            canonicalNotificationError =
                "Dropped " + String(unresolved)
                    + " unresolved cold notification route(s) after a complete catalog scan."
        }
    }

    /// Return nil only when the route is still an exact current canonical candidate. Session
    /// selection remains useful for stale clicks, but the evidence card must never present an
    /// old action/cursor as if it were current.
    private func canonicalNotificationStaleReason(
        _ route: CanonicalNotificationRoute
    ) -> String? {
        guard canonicalNotificationCatalogScanComplete else {
            return "Notification evidence is pending a complete catalog scan."
        }
        guard canonicalNotificationProjection.isComplete else {
            return "Notification evidence is incomplete; Aviary selected the Session only."
        }
        guard canonicalNotificationProjection.candidate(matching: route) != nil else {
            return "Notification is stale; Aviary selected the Session without old evidence."
        }
        if route.kind == .failedRecovery {
            guard canonicalWorkRecoveryProjection.isComplete else {
                return "Recovery evidence is incomplete; Aviary selected the Session only."
            }
            guard let reconciliation = canonicalWorkRecoveryProjection.reconcile(
                notificationRoute: route), reconciliation.exact else {
                return "Recovery evidence is stale; Aviary selected the Session only."
            }
        }
        return nil
    }

    /// Mark the catalog rows that belong to a run this process is holding.
    ///
    /// One source now, so there is nothing to reconcile: a session is live when Aviary is
    /// running it. The harness needed two — an append-only daemon ledger and a writer-owned
    /// artifact — and their disagreements were a standing source of wrong rows.
    private func annotateLiveState() {
        let running = Set(workRuns.filter { !$0.hasExited }.compactMap(\.sessionID))
        let busy = Set(workRuns.filter { $0.isStreaming }.compactMap(\.sessionID))
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
        runtimeModelsError =
            modelCatalog.models.isEmpty
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
        let projectRoot = sessions.first.flatMap {
            $0.cwd.isEmpty ? nil : URL(fileURLWithPath: $0.cwd)
        }
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
        guard acceptsNewWork else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let liveRuns = self.workRuns.filter { !$0.hasExited }
                let attachedServiceWork = self.runs.contains {
                    $0.isServiceBacked && !$0.hasExited
                }
                let interval: UInt64
                if attachedServiceWork {
                    interval = 1_500_000_000
                } else if !liveRuns.isEmpty {
                    interval = 3_000_000_000
                } else {
                    interval = 12_000_000_000
                }
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                self.annotateLiveState()
                self.tree = AgentTreeReader.read(home: self.home)
                await self.refreshServiceWork()
                // The canonical journals are the notification producer's source of truth. A
                // live run can finish or enter review between catalog refreshes, so polling
                // must consume the projection as well as repainting the in-memory tree.
                await self.refreshCatalog()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Transcript

    func select(session: SessionSummary) {
        canonicalNotificationFocus = nil
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
        if let notificationFocus = canonicalNotificationFocus,
           canonicalNotificationDisplayIDs[notificationFocus.sessionIdentityKey] != focus
        {
            canonicalNotificationFocus = nil
        }
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
        guard !session.isCanonicalOnly else {
            transcript = nil
            transcriptSessionID = nil
            kernelState = nil
            selectedSessionWire = []
            isLoadingTranscript = false
            return
        }
        isLoadingTranscript = true
        guard let url = session.fileURL else {
            transcript = nil
            transcriptSessionID = nil
            kernelState = nil
            selectedSessionWire = []
            isLoadingTranscript = false
            return
        }
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
        return sessions.filter { canonicalSessionSearchIndex.document(actionTargetID: $0.id)?.matches(q) == true }
    }

    /// The list's title/search projection comes from the canonical boundary when available. The
    /// legacy summary remains the compatibility fallback, and local identity is never replaced
    /// by the canonical authority-qualified journal id.
    func catalogTitle(for session: SessionSummary) -> String {
        if let document = canonicalSessionSearchIndex.document(actionTargetID: session.id) {
            return document.displayTitle
        }
        if let projected = canonicalCatalogProjections[session.id]?.title,
           !projected.isEmpty {
            return projected
        }
        return session.title
    }

    func sessionSearchDocument(for session: SessionSummary) -> CanonicalSessionSearchDocument? {
        canonicalSessionSearchIndex.document(actionTargetID: session.id)
    }

    /// Running Work is not the same thing as an active conversation. Preserve in-process
    /// liveness for legacy rows and require exact attached Work before native state drives the
    /// palette's live indicator.
    func sessionLiveness(for session: SessionSummary) -> Bool? {
        guard let document = sessionSearchDocument(for: session) else { return nil }
        return CanonicalSessionLivenessProjection.project(
            inProcess: session.isLive, source: document.source,
            summary: canonicalCatalogProjections[session.id])
    }

    var selectedSession: SessionSummary? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selectedSessions: [SessionSummary] {
        sessions.filter { selectedSessionIDs.contains($0.id) }
    }

    /// Fail-closed liveness at an action boundary. In-process identity closes the refresh race;
    /// canonical attachments cover Work owned by another GUI/process and treat an unprojectable
    /// attached Work as uncertain rather than terminal.
    func hasLiveWork(forSession sessionID: String) -> Bool {
        let inProcess = workRuns.contains {
            !$0.hasExited
                && ($0.config.identity?.sessionID == sessionID || $0.sessionID == sessionID)
        }
        if inProcess { return true }
        if nativeActionBlockedSessionIDs.contains(sessionID) { return true }
        guard let canonical = canonicalCatalogProjections[sessionID],
              canonical.sessionStructuralIntegrityValid,
              canonical.sessionSemanticProjectionValid
        else { return false }
        return canonical.hasOngoingOrUncertainAttachedWork
    }

    /// Revalidate the native locator at the user action boundary. Rendering uses the cached
    /// projection above; Continue/Trash must account for appends by another process since then.
    private func nativeActionIsBlocked(forSession sessionID: String) -> Bool {
        hasLiveWork(forSession: sessionID)
            || LocalTimelineCatalog.blocksLegacyAction(home: home, sessionID: sessionID)
    }

    /// Batch deletion deliberately shares the single-item Trash path. It moves each transcript
    /// and its artifacts to macOS Trash, never unlinks history, and refuses a mixed selection
    /// containing a live session instead of quietly deleting only some of it.
    func trashSelectedSessions() async {
        guard let catalog, !isTrashingSessions else { return }
        let targets = selectedSessions
        guard !targets.isEmpty else { return }
        guard !targets.contains(where: {
            $0.isCanonicalOnly || $0.isLive || nativeActionIsBlocked(forSession: $0.id)
        }) else {
            show(
                "Native canonical rows are observe-only here; stop or deselect live sessions "
                    + "before moving legacy transcripts to the Trash.",
                isError: true)
            return
        }

        isTrashingSessions = true
        let targetIDs = Set(targets.map(\.id))
        sessionsBeingTrashed.formUnion(targetIDs)
        defer {
            sessionsBeingTrashed.subtract(targetIDs)
            isTrashingSessions = false
        }
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
        var message = count == 1
            ? "Moved 1 session transcript to the Trash"
            : "Moved \(count) session transcripts to the Trash"
        if !result.partialFailures.isEmpty {
            message += "; \(result.partialFailures.count) had companion data that could not move"
        }
        if !result.failures.isEmpty {
            message += "; \(result.failures.count) transcripts could not be moved"
        }
        let details = result.partialFailures.values.sorted()
            + result.failures.values.sorted()
        if !details.isEmpty { message += ": " + details.joined(separator: "\n") }
        toast = Toast(
            message: message,
            isError: !result.failures.isEmpty || !result.partialFailures.isEmpty)
    }

    /// Reversibly organize durable conversation history without ending Work or moving files.
    func setSessionsArchived(_ targets: [SessionSummary], archived: Bool) async {
        guard let catalog, !isArchivingSessions, !targets.isEmpty else { return }
        guard !targets.contains(where: \.isCanonicalOnly) else {
            show("Native canonical rows cannot be archived through the legacy catalog yet.",
                 isError: true)
            return
        }
        isArchivingSessions = true
        defer { isArchivingSessions = false }
        do {
            let ids = Set(targets.map(\.id))
            try await catalog.setArchived(archived, sessionIDs: ids)
            for index in sessions.indices where ids.contains(sessions[index].id) {
                sessions[index].isArchived = archived
            }
            show(
                archived
                    ? "Archived \(ids.count == 1 ? "1 session" : "\(ids.count) sessions")"
                    : "Restored \(ids.count == 1 ? "1 session" : "\(ids.count) sessions")")
        } catch {
            show("Could not update the archive: \(error.localizedDescription)", isError: true)
        }
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

    /// Start a run that cold-resumes this session with payload recording on — history and the
    /// durable identity are recovered, while the prior in-memory Python namespace is not
    /// claimed to survive this new runtime host.
    func continueWithRecording(_ session: SessionSummary) {
        guard !session.isCanonicalOnly else {
            toast = Toast(message: "Native canonical sessions have no legacy payload recording path.",
                          isError: true)
            return
        }
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

    /// Start an in-house run through the durable local Work service.  This method is a GUI
    /// admission boundary only: it registers the selected local directory as a host-admin
    /// operation, then sends its opaque workspace identity through Create/Start.  No Session,
    /// Run, RuntimeHost, or Python object is created in this process.
    func peerRuns(excluding sessionID: String) -> [LiveRun] {
        workRuns.filter { !$0.hasExited && $0.sessionID != sessionID }
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
            return (
                "",
                "\(target.title) is driven by Claude Code, which owns its turn "
                    + "boundary and will not accept an injected message."
            )
        }
        let displaySender = workRuns.first { $0.sessionID == sessionID }?.title ?? "another agent"
        guard
            await target.receive(
                text: text, displaySender: displaySender, sourceID: "peer:" + sessionID)
        else {
            return (target.sessionID ?? target.title, "The target did not accept the message.")
        }
        return (target.sessionID ?? target.title, nil)
    }

    /// Main-actor hop for a background Future/Handle reporting to its originating run.
    /// Return only the Sendable receipt across the boundary; a `LiveRun` never leaves its actor.
    func deliverSelfMessage(
        sessionID: String, text: String, from sourceSessionID: String
    ) async -> Bool {
        guard let run = workRuns.first(where: { $0.sessionID == sessionID }) else { return false }
        return await run.receive(
            text: text,
            displaySender: "your background task (session " + sourceSessionID + ")",
            sourceID: "self:" + sourceSessionID)
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
        thinkingLevel: String? = nil, noContextFiles: Bool = false,
        recordPayloads: Bool = false, resume: String? = nil, title: String? = nil,
        onCreated: (@MainActor (LiveRun) -> Void)? = nil
    ) {
        guard acceptsNewWork else {
            show(
                "Aviary is ending its current Work and cannot start another run yet.", isError: true
            )
            return
        }
        if let resume, sessionsBeingTrashed.contains(resume) {
            show("That conversation is currently moving to the Trash and cannot be resumed.",
                 isError: true)
            return
        }
        if let resume {
            if focusExistingWork(forSession: resume) {
                if let run = workRuns.first(where: {
                    $0.config.identity?.sessionID == resume || $0.sessionID == resume
                }) {
                    onCreated?(run)
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshServiceWork()
                if self.focusExistingWork(forSession: resume) {
                    if let run = self.workRuns.first(where: {
                        $0.config.identity?.sessionID == resume || $0.sessionID == resume
                    }) {
                        onCreated?(run)
                    }
                    self.show("Reattached the durable Work for this conversation.")
                } else {
                    self.show(
                        "This session has no attached Work in the current host catalog; a new "
                            + "in-house run was not created.", isError: true)
                }
            }
            return
        }
        Task { @MainActor [weak self] in
            await self?.startServiceInHouseRun(
                cwd: cwd, providerID: providerID, modelID: modelID, prompt: prompt,
                thinkingLevel: thinkingLevel, noContextFiles: noContextFiles,
                recordPayloads: recordPayloads, title: title, onCreated: onCreated)
        }
    }

    // MARK: Chat exists before its executor does

    func restorePendingChats() {
        guard !isPreview else { return }
        do {
            let inventory = try PendingChatStore(home: home).load()
            pendingChats = inventory.rows.sorted { $0.createdAt > $1.createdAt }
            pendingChatStoreError = inventory.unavailable.isEmpty ? nil
                : "Some saved chats could not be read. Their files have been kept; open Diagnostics for help."
            // Restoring saved cards must not override the returning conversation or a
            // notification destination. Cards remain available in the Chats rail.
        } catch {
            pendingChatStoreError = "Saved chats could not be loaded. No saved files were removed."
        }
    }

    /// Success means only that the exact request is saved locally, never that it was sent.
    @discardableResult
    func createPendingChat(
        cwd: String, providerID: String?, modelID: String?, prompt: String,
        thinkingLevel: String? = nil, noContextFiles: Bool = false,
        recordPayloads: Bool = false, title: String? = nil,
        attemptStartup: Bool = true
    ) -> Bool {
        guard acceptsNewWork else { return false }
        do {
            let chat = try PendingChatStore(home: home).create(
                prompt: prompt, cwd: cwd, providerID: providerID, modelID: modelID,
                thinkingLevel: thinkingLevel, title: title ?? String(prompt.prefix(80)),
                noContextFiles: noContextFiles, recordPayloads: recordPayloads)
            pendingChats.insert(chat, at: 0)
            selectedPendingChatID = chat.id
            pendingChatStoreError = nil
            section = .cockpit
            if attemptStartup { retryPendingChat(chat.id) }
            return true
        } catch PendingChatError.capacity {
            pendingChatStoreError = "Saved chats are full. Discard an unsent chat from the Chats list, then try again. Your text is still in the editor."
            return false
        } catch {
            pendingChatStoreError = "Your chat could not be saved. Your text is still in the editor. Check available disk space or copy it before leaving."
            return false
        }
    }

    func pendingChatIsPreparing(_ chat: PendingChat) -> Bool { pendingChatAttempts.contains(chat.id) }

    func pendingChatStatus(_ chat: PendingChat) -> String {
        if pendingChatAttempts.contains(chat.id) { return "Connecting…" }
        if chat.createdAssociation != nil { return "Saved · opening conversation" }
        if chat.phase == .awaitingAcceptance { return "Saved · checking delivery" }
        if chat.phase == .preparing { return "Saved · startup interrupted" }
        return chat.phase == .saved ? "Saved · not sent" : "Not sent · needs attention"
    }

    func pendingChatExplanation(_ chat: PendingChat) -> String {
        if let detail = pendingChatDetails[chat.id] { return detail }
        if chat.phase == .saved {
            return "This request is saved on this Mac and has not been sent. Start the chat when you are ready."
        }
        if chat.createdAssociation != nil {
            return "The agent service created this conversation. Reconnect to open it; your request will not be sent twice."
        }
        if chat.phase == .awaitingAcceptance {
            if let issue = localWorkServiceCreateError {
                return issue + " Check delivery retries the original saved identity, not a new copy."
            }
            return "Aviary lost confirmation of delivery. Your request is saved. Check delivery to reconcile the original attempt without sending another copy."
        }
        if chat.phase == .preparing {
            return "Startup was interrupted. Your request is saved. Retry checks any retained delivery attempt before proceeding."
        }
        switch chat.failureKind {
        case .providerUnavailable: return "The selected model is not available. Choose a configured model, then retry."
        case .workspaceUnavailable: return "The project folder is unavailable. Check the folder, then retry."
        case .invalidRequest: return "The request needs an adjustment before it can be sent. Your original text is saved."
        default: return "The local agent service is not ready. Your request is saved on this Mac and has not been sent. Retry connection to continue."
        }
    }

    private func replacePendingChat(_ value: PendingChat) {
        if let index = pendingChats.firstIndex(where: { $0.id == value.id }) {
            pendingChats[index] = value
        }
    }

    @discardableResult
    private func updatePendingChat(
        _ id: UUID, phase: PendingChatPhase, failure: PendingChatFailureKind? = nil,
        association: ServiceAttachmentKey? = nil, newAttempt: Bool = false
    ) -> Bool {
        guard let chat = pendingChats.first(where: { $0.id == id }) else { return false }
        do {
            let changed = try chat.changing(
                phase: phase, failureKind: failure,
                attemptCommandID: newAttempt ? UUID() : nil, createdAssociation: association)
            let saved = try PendingChatStore(home: home).update(changed, expectedGeneration: chat.generation)
            replacePendingChat(saved)
            return true
        } catch {
            pendingChatDetails[id] = "Saving this chat's status failed. No new request was sent. Reopen Aviary to reload the saved version; your visible prompt is kept."
            return false
        }
    }

    private func blockPendingChat(_ id: UUID?, message: String, kind: PendingChatFailureKind = .unknown) {
        guard let id else { show(message, isError: true); return }
        pendingChatDetails[id] = message
        guard let chat = pendingChats.first(where: { $0.id == id }),
              chat.phase != .awaitingAcceptance, chat.createdAssociation == nil else { return }
        _ = updatePendingChat(id, phase: .blocked, failure: kind)
    }

    private func rejectPendingChatAttempt(_ commandID: String) -> Bool {
        guard let chat = pendingChats.first(where: {
            $0.attemptCommandID.uuidString.lowercased() == commandID && $0.createdAssociation == nil
        }) else { return true }
        guard updatePendingChat(chat.id, phase: .blocked, failure: .invalidRequest) else { return false }
        return updatePendingChat(chat.id, phase: .blocked, failure: .invalidRequest, newAttempt: true)
    }

    func editPendingChat(_ chat: PendingChat, prompt: String, cwd: String,
                         providerID: String, modelID: String) -> Bool {
        guard !pendingChatAttempts.contains(chat.id), chat.createdAssociation == nil,
              chat.phase != .awaitingAcceptance else { return false }
        do {
            let edited = try chat.edited(prompt: prompt, cwd: cwd,
                providerID: providerID, modelID: modelID, thinkingLevel: chat.thinkingLevel,
                title: chat.title, noContextFiles: false, recordPayloads: chat.recordPayloads)
            replacePendingChat(try PendingChatStore(home: home).update(edited, expectedGeneration: chat.generation))
            pendingChatDetails.removeValue(forKey: chat.id)
            return true
        } catch {
            pendingChatDetails[chat.id] = "Your edits could not be saved. They are still in the editor; copy them before leaving."
            return false
        }
    }

    /// Returns true only after the exact host association is durable locally, before Create
    /// intent cleanup. This closes the response/GUI-publication crash window.
    private func associatePendingChat(request: WorkServiceCreateWorkRequest,
                                      response: WorkServiceCreateWorkResponse) throws {
        guard let chat = pendingChats.first(where: {
            $0.attemptCommandID.uuidString.lowercased() == request.commandID
        }) else { return }
        guard let key = ServiceAttachmentKey(work: response.work.work, attachment: response.attachment),
              updatePendingChat(chat.id, phase: .awaitingAcceptance, association: key) else {
            throw PendingChatError.conflict
        }
    }

    private func settlePendingChats() {
        for chat in pendingChats {
            guard let key = chat.createdAssociation,
                  let run = workRuns.first(where: { $0.serviceAttachmentKey == key }) else { continue }
            guard run.hasCanonicalDelivery(for: chat) else {
                if let error = run.errorBanner {
                    pendingChatDetails[chat.id] = "The conversation is saved, but the agent could not start. " + error
                }
                continue
            }
            do {
                try PendingChatStore(home: home).delete(id: chat.id, expectedGeneration: chat.generation)
                pendingChats.removeAll { $0.id == chat.id }
                pendingChatDetails.removeValue(forKey: chat.id)
                if selectedPendingChatID == chat.id {
                    selectedPendingChatID = nil
                    focusedRunID = run.id
                }
            } catch {
                pendingChatDetails[chat.id] = "Your conversation is ready, but its saved startup card could not be cleared. Reconnecting will open the same conversation, not send again."
            }
        }
    }

    func openPendingConversation(_ chat: PendingChat) {
        guard let key = chat.createdAssociation,
              let run = workRuns.first(where: { $0.serviceAttachmentKey == key }) else { return }
        selectedPendingChatID = nil
        focusedRunID = run.id
        section = .cockpit
    }

    func canOpenPendingConversation(_ chat: PendingChat) -> Bool {
        guard let key = chat.createdAssociation else { return false }
        return workRuns.contains { $0.serviceAttachmentKey == key }
    }

    /// A reviewed escape from indeterminate startup. Copying only saves a new local request;
    /// the person must separately choose Start, because the original may still take effect.
    func copyPendingChatAsUnsent(_ chat: PendingChat) {
        guard chat.createdAssociation != nil, !pendingChatIsPreparing(chat) else { return }
        _ = createPendingChat(cwd: chat.cwd, providerID: chat.providerID, modelID: chat.modelID,
            prompt: chat.prompt, thinkingLevel: chat.thinkingLevel,
            noContextFiles: chat.noContextFiles, recordPayloads: chat.recordPayloads,
            title: chat.title, attemptStartup: false)
    }

    /// Explicit presentation-only dismissal, never cancellation, End, or an intent replay.
    func stopTrackingPendingChat(_ chat: PendingChat) {
        guard chat.createdAssociation != nil, !pendingChatIsPreparing(chat) else { return }
        do {
            try PendingChatStore(home: home).delete(id: chat.id, expectedGeneration: chat.generation)
            pendingChats.removeAll { $0.id == chat.id }
            pendingChatDetails.removeValue(forKey: chat.id)
            if selectedPendingChatID == chat.id { selectedPendingChatID = nil }
            show("Startup card removed. The original work was not stopped.")
        } catch {
            pendingChatDetails[chat.id] = "The startup card could not be removed. It has been kept."
        }
    }

    /// Only definitely unsent local cards may be discarded. An independent retained Create
    /// obligation must be reconciled first, even if its card was marked blocked before a crash.
    func discardPendingChat(_ chat: PendingChat) {
        guard !pendingChatIsPreparing(chat), chat.createdAssociation == nil,
              chat.phase == .saved || chat.phase == .blocked else { return }
        do {
            let identity = try WorkServiceClientIdentityStore(url: home.workServiceClientIdentityFile).loadOrCreate()
            let retained = try ServiceBackedCreateIntentStore(home: home, client: identity).loadPending()
            guard !retained.contains(where: {
                $0.initialStart?.commandID == chat.startCommandID
                    || $0.request.commandID == chat.attemptCommandID.uuidString.lowercased()
            }) else {
                pendingChatDetails[chat.id] = "Delivery still needs checking. Check delivery before discarding this request; it may already belong to the agent service."
                return
            }
            try PendingChatStore(home: home).delete(id: chat.id, expectedGeneration: chat.generation)
            pendingChats.removeAll { $0.id == chat.id }
            pendingChatDetails.removeValue(forKey: chat.id)
            if selectedPendingChatID == chat.id { selectedPendingChatID = nil }
        } catch {
            pendingChatDetails[chat.id] = "The saved request could not be safely discarded. It has been kept."
        }
    }

    func retryPendingChat(_ id: UUID) {
        guard acceptsNewWork, !pendingChatAttempts.contains(id),
              let original = pendingChats.first(where: { $0.id == id }) else { return }
        pendingChatAttempts.insert(id)
        pendingChatDetails.removeValue(forKey: id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingChatAttempts.remove(id) }
            if original.phase == .awaitingAcceptance || original.createdAssociation != nil {
                if self.localWorkService == nil { await self.bootstrapLocalWorkService() }
                do {
                    let (session, handshake) = try await self.reconnectLocalWorkService()
                    guard let client = self.localWorkServiceClient,
                          await self.reconcilePendingCreateIntents(session: session, client: client) else { return }
                    await self.restoreServiceWork(session: session, client: client, handshake: handshake)
                    self.settlePendingChats()
                } catch {
                    self.pendingChatDetails[id] = "Still unable to confirm delivery. Your saved request is kept; no second attempt was sent. " + Self.serviceErrorMessage(error)
                }
                return
            }
            guard self.updatePendingChat(id, phase: .preparing),
                  let chat = self.pendingChats.first(where: { $0.id == id }) else { return }
            await self.startServiceInHouseRun(
                cwd: chat.cwd, providerID: chat.providerID, modelID: chat.modelID,
                prompt: chat.prompt, thinkingLevel: chat.thinkingLevel,
                noContextFiles: chat.noContextFiles, recordPayloads: chat.recordPayloads,
                title: chat.title, onCreated: nil, pendingChatID: id)
        }
    }

    private func startServiceInHouseRun(
        cwd: String, providerID: String?, modelID: String?, prompt: String,
        thinkingLevel: String?, noContextFiles: Bool, recordPayloads: Bool, title: String?,
        onCreated: (@MainActor (LiveRun) -> Void)?, pendingChatID: UUID? = nil
    ) async {
        guard prompt.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
            blockPendingChat(pendingChatID, message: "Your prompt is saved, but this connection accepts at most \(WorkServiceBounds.maxCommandValueCharacters) bytes per message. Shorten the request before retrying.", kind: .invalidRequest)
            return
        }
        guard !noContextFiles else {
            blockPendingChat(pendingChatID, message:
                "This agent requires project instructions. Choose Edit request and save it to include those instructions before retrying.", kind: .invalidRequest)
            return
        }
        guard
            let (providerSpec, model) = AgentCLI.resolve(
                [providerID, modelID].compactMap { $0 }.joined(separator: "/"),
                in: modelsConfig) ?? AgentCLI.resolve(modelID, in: modelsConfig)
        else {
            blockPendingChat(pendingChatID, message: "The selected model is not configured. Choose a model in Models, then retry this saved chat.", kind: .providerUnavailable)
            return
        }
        if localWorkService == nil { await bootstrapLocalWorkService() }
        if let pendingChatID,
           !pendingChats.contains(where: { $0.id == pendingChatID && $0.createdAssociation == nil }) {
            settlePendingChats()
            return
        }
        guard localWorkService != nil,
              let client = localWorkServiceClient else {
            blockPendingChat(pendingChatID, message: localWorkServiceError ?? "The local agent service is unavailable. Your request has not been sent.", kind: .hostUnavailable)
            return
        }
        guard beginServiceLifecycleOperation() else { return }
        defer { finishServiceLifecycleOperation() }
        do {
            // This is the one path-bearing operation in the GUI service flow.  The returned
            // descriptor is reduced immediately to its opaque host-minted workspace ID.
            let registry = try WorkHostWorkspaceRegistry(home: home)
            let workspace = try registry.registerLocalDirectory(
                URL(fileURLWithPath: cwd, isDirectory: true),
                label: URL(fileURLWithPath: cwd).lastPathComponent,
                isDefault: true)
            let (session, handshake) = try await reconnectLocalWorkService()
            guard !serviceCreateInFlight else {
                blockPendingChat(pendingChatID, message: "Another conversation is being prepared. Your request is saved; retry in a moment.")
                return
            }
            serviceCreateInFlight = true
            defer { serviceCreateInFlight = false }
            guard await reconcilePendingCreateIntents(session: session, client: client) else {
                blockPendingChat(pendingChatID, message:
                    localWorkServiceError
                        ?? "A prior Work creation is still awaiting reconciliation.",
                    kind: .hostUnavailable)
                return
            }
            if let pendingChatID,
               !pendingChats.contains(where: { $0.id == pendingChatID && $0.createdAssociation == nil }) {
                await restoreServiceWork(session: session, client: client, handshake: handshake)
                return
            }
            guard handshake.workspaceCatalog.isComplete,
                  let advertised = handshake.workspaceCatalog.entries.first(where: {
                      $0.workspaceID == workspace.workspaceID
                  }), advertised.isAvailable,
                  advertised.capabilities.contains(.resolve) else {
                throw LocalWorkServiceBootstrapError.connectionFailed(.notConnected)
            }
            let requested: Set<WorkServiceCapability> = [
                .observe, .control, .start, .send, .steer, .queue, .cancel, .end,
                .inspectArtifacts, .createSession,
            ]
            let configuration = WorkServiceWorkConfiguration(
                providerID: providerSpec.id, modelID: model.id,
                thinkingLevel: thinkingLevel, workspaceID: advertised.workspaceID,
                includeContextFiles: true, recordPayloads: recordPayloads)
            let createRequest = WorkServiceCreateWorkRequest(
                client: client,
                commandID: pendingChatID.flatMap { id in pendingChats.first { $0.id == id }?.attemptCommandID.uuidString.lowercased() } ?? UUID().uuidString.lowercased(),
                causalControlCursor: handshake.controlCursor,
                configuration: configuration,
                requestedCapabilities: requested)
            let createIntentStore = try ServiceBackedCreateIntentStore(home: home, client: client)
            // Persist the exact initial prompt and Start command identity in the same durable
            // transaction record before Create crosses the host boundary. Until Start resolves,
            // a relaunch must not present this newly-created idle Work as an ordinary composer.
            let initialStart = try ServiceBackedCreateIntentStore.InitialStart(
                commandID: pendingChatID.flatMap { id in pendingChats.first { $0.id == id }?.startCommandID } ?? "start-v2-" + UUID().uuidString.lowercased(), prompt: prompt)
            localWorkServiceCreatesReconciled = false
            try createIntentStore.retain(createRequest, initialStart: initialStart)
            if let pendingChatID, !updatePendingChat(pendingChatID, phase: .awaitingAcceptance) { return }
            let response = try await session.createWork(createRequest)
            guard response.receipt.state == .accepted
                || response.receipt.state == .duplicate else {
                // Every structured rejection is definitive non-admission. In particular,
                // staleCursor proves this exact request never crossed the host's mutation
                // boundary; retaining it as an indeterminate mutation would freeze every later
                // Create forever. Clear the exact intent before allowing the user to retry.
                do {
                    guard rejectPendingChatAttempt(createRequest.commandID) else { throw PendingChatError.conflict }
                    try createIntentStore.clear(createRequest)
                    localWorkServiceCreatesReconciled = true
                } catch {
                    localWorkServiceCreateError =
                        "Create was rejected, but its durable intent could not be cleared; new Work is withheld until it is reconciled."
                    return
                }
                let detail = response.receipt.diagnostic ?? "no durable Work was admitted."
                blockPendingChat(pendingChatID, message:
                    response.receipt.rejection == .staleCursor
                        ? "The Work Host rejected Create because its control cursor was stale. No Work was created; retry when ready."
                        : "The Work Host rejected Create: \(detail)",
                    kind: .invalidRequest)
                return
            }
            do {
                try associatePendingChat(request: createRequest, response: response)
                try Self.retainStartIntent(
                    initialStart, response: response, home: home, client: client)
                try createIntentStore.clear(createRequest)
                localWorkServiceCreatesReconciled = true
            } catch {
                // Keeping the intent is safe: the next bootstrap replays the exact idempotent
                // request and promotes the Start seed again. Surface the durability issue without
                // discarding the attached Work or losing its initial prompt.
                localWorkServiceCreateError =
                    "Work was created, but its GUI Start intent could not be durably resolved; the exact request will be reconciled on relaunch."
            }
            guard let serviceAttachmentKey = ServiceAttachmentKey(
                work: response.work.work, attachment: response.attachment) else {
                throw ServiceBackedStartIntentError.invalid
            }
            var restoredDraft = await Self.restoreServiceDraft(
                home: home, key: serviceAttachmentKey)
            let startIntentStore = try ServiceBackedStartIntentStore(
                home: home, key: serviceAttachmentKey)
            guard let retainedStart = try startIntentStore.load() else {
                throw ServiceBackedStartIntentError.corrupt
            }
            let intentStore = try WorkServiceAttachedWorkIntentStore(
                home: home, key: serviceAttachmentKey)
            let controller = try WorkServiceAttachedWorkController(
                session: session, seed: .created(response), intentStore: intentStore)
            let projection: WorkServiceAttachedWorkProjection
            do {
                projection = try await controller.refresh()
            } catch {
                projection = await controller.projection()
            }
            restoredDraft = await Self.reconcileServiceDraft(
                restoredDraft, key: serviceAttachmentKey, projection: projection)
            var unresolvedRetainedStart: ServiceBackedStartIntent? = retainedStart
            if Self.hasCanonicalStartEvidence(retainedStart, projection: projection) {
                do {
                    try startIntentStore.clear(retainedStart)
                    unresolvedRetainedStart = nil
                } catch {
                    localWorkServiceError =
                        "The initial Start is already reflected by canonical Work, but its local intent could not be cleared."
                    unresolvedRetainedStart = nil
                }
            }
            let bridge = ServiceBackedRunBridge(
                controller: controller, projection: projection,
                history: await controller.conversationHistory(),
                serviceAttachmentKey: serviceAttachmentKey,
                workspaceLabel: workspace.label ?? advertised.workspaceID.rawValue,
                modelLabel: model.qualifiedID, thinkingLevel: thinkingLevel)
            let run = LiveRun(
                service: bridge, cwd: cwd, title: title,
                initialStart: unresolvedRetainedStart, initialStartStore: startIntentStore,
                draftStore: restoredDraft.store,
                restoredDraft: restoredDraft.snapshot,
                draftRestorationFailure: restoredDraft.failure)
            run.config = RunConfiguration(
                cwd: cwd, provider: providerSpec.id, model: model.id,
                thinkingLevel: thinkingLevel, noContextFiles: noContextFiles,
                recordPayloads: recordPayloads)
            // Create and its Start seed are already durable. If application shutdown closed GUI
            // admission during the host round-trip, leave the idle Work for next-launch catalog
            // reconstruction instead of publishing a row after shutdown's drain.
            guard acceptsNewWork else { return }
            runs.append(run)
            if pendingChatID == nil {
                focusedRunID = run.id
                section = .cockpit
            }
            settlePendingChats()
            onCreated?(run)
            if let unresolvedRetainedStart,
               bridge.hasMatchingStartAttachment(for: unresolvedRetainedStart) {
                await run.startService(
                    prompt: unresolvedRetainedStart.prompt,
                    commandID: unresolvedRetainedStart.commandID)
            } else if unresolvedRetainedStart != nil {
                run.commandNotice = .warning(
                    bridge.projection.isCanonical
                        ? "The saved first message is awaiting startup reconciliation. Check delivery before retrying."
                        : "The saved first message is waiting for a complete Work and Session read. It has not been resubmitted.")
            }
        } catch let error as WorkHostWorkspaceRegistryError {
            blockPendingChat(pendingChatID,
                message: (error.errorDescription ?? "The project folder is unavailable.")
                    + " Choose Edit request to check the project folder. Your request has not been sent.",
                kind: .workspaceUnavailable)
        } catch {
            let message = Self.serviceErrorMessage(error)
            if let pendingChatID,
               pendingChats.contains(where: { $0.id == pendingChatID && $0.phase == .awaitingAcceptance }) {
                localWorkServiceCreateError = message
            }
            blockPendingChat(pendingChatID, message: message, kind: .hostUnavailable)
        }
    }

    /// Start a Claude-Code-driven run: Claude Code's loop, Aviary's kernel as its only tool.
    ///
    /// No provider or model resolution, because there is no provider here — Claude Code holds
    /// the credential and picks the route. The model is a Claude Code alias (`sonnet`, `opus`,
    /// `haiku`), which is why it is a plain string rather than a `ModelSpec`.
    @discardableResult
    func startClaudeCodeRun(
        cwd: String, model: String, effort: String?, prompt: String,
        noContextFiles: Bool = false, title: String? = nil
    ) -> Bool {
        guard acceptsNewWork else {
            show(
                "Aviary is ending its current Work and cannot start another run yet.", isError: true
            )
            return false
        }
        // Remembered for the next run, and for the places that start one without a sheet —
        // the workshop launcher and `continueSession`.
        claudeCodeModel = model
        var config = RunConfiguration(
            cwd: cwd, provider: "claude-code", model: model, thinkingLevel: effort,
            noContextFiles: noContextFiles)
        let identity = config.resolvedIdentity(home: home)
        config.identity = identity
        let writer: SessionWriter
        do {
            writer = try SessionWriter(
                home: home, cwd: cwd, model: ClaudeCodeRun.modelSpec(for: model), identity: identity)
        } catch {
            toast = Toast(
                message: "Could not open the session journal: \(error.localizedDescription)",
                isError: true)
            return false
        }
        let commandController = SessionCommandController(identity: identity, writer: writer)
        let run = LiveRun(
            claudeCode: ClaudeCodeDriver(
                home: home, cwd: cwd, model: model, effort: effort, identity: identity,
                commandController: commandController, noContextFiles: noContextFiles,
                writer: writer),
            cwd: cwd, modelLabel: "claude-code/\(model)", config: config)
        if let title { run.title = title }
        runs.append(run)
        focusedRunID = run.id
        section = .live
        run.startClaudeCode(prompt: prompt)
        return true
    }

    /// Continue an existing session on whichever engine is selected.
    ///
    /// One entry point for all three "Continue" affordances, so the engine picker governs
    /// resume too. They each used to build a harness `RunConfiguration` directly, which is why
    /// resume was harness-only regardless of what the picker said.
    func continueSession(_ s: SessionSummary, recordPayloads: Bool = false) {
        guard !s.isCanonicalOnly else {
            toast = Toast(message: "This native session has no legacy transcript resume path yet.",
                          isError: true)
            return
        }
        if focusExistingWork(forSession: s.id) { return }
        if nativeActionIsBlocked(forSession: s.id) {
            toast = Toast(
                message: "This session has active or uncertain Work on a Work Host. Attach to "
                    + "that Work or wait for a proven terminal state before continuing.",
                isError: true)
            return
        }
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
        // Re-read native Work identity at admission, including the window before this driver
        // publishes its session event. The native bundle's writer lock remains the final guard
        // against a cross-process race after this bounded observation.
        toast = Toast(
            message: "Conversation history and Work identity will resume in a new Python "
                + "runtime. The prior interpreter namespace is not restored.",
            isError: false)
        startInHouseRun(
            cwd: cwd, providerID: s.provider, modelID: s.model, prompt: "",
            recordPayloads: recordPayloads, resume: s.id, title: s.title)
    }

    @discardableResult
    private func focusExistingWork(forSession sessionID: String) -> Bool {
        guard let existing = workRuns.first(where: {
            !$0.hasExited
                && ($0.config.identity?.sessionID == sessionID || $0.sessionID == sessionID)
        }) else { return false }
        if detachedRuns.contains(where: { $0.id == existing.id }) {
            reattachRun(existing)
        } else {
            focusedRunID = existing.id
            section = .live
        }
        show("That conversation already has live Work; reattached its existing run.")
        return true
    }

    func closeRun(_ run: LiveRun) {
        // Closing is a view operation. An active run is detached and retained; only End run
        // carries termination intent.
        guard run.hasExited else {
            detachRun(run)
            return
        }
        if run.isServiceBacked, !run.draft.isEmpty,
           run.draftPersistenceState != .saved
        {
            // Do not drop the only strong UI owner while its newest draft is still in flight.
            // A failed write gets one explicit retry; if it remains unavailable, keep the pane
            // open with its existing warning so the user can copy or discard the text.
            Task { @MainActor in
                if await run.flushDraftPersistence() {
                    self.closeRun(run)
                } else {
                    self.show(
                        "This completed Work was kept open because its unsent draft is not saved.",
                        isError: true)
                }
            }
            return
        }
        if let serviceKey = run.serviceAttachmentKey {
            hiddenServiceAttachmentKeys.insert(serviceKey)
        }
        if run.config.recordPayloads {
            // The log is complete now; make it discoverable from the Sessions tab.
            wireIndex = WireLog.buildIndex()
            if let id = selectedSessionID {
                selectedSessionWire = WireLog.records(forSession: id, index: wireIndex)
            }
        }
        runs.removeAll { $0.id == run.id }
        detachedRuns.removeAll { $0.id == run.id }
        if focusedRunID == run.id { focusedRunID = runs.last?.id }
    }

    /// Remove only this GUI attachment. The Work remains controllable by its in-process host.
    func detachRun(_ run: LiveRun) {
        guard runs.contains(where: { $0.id == run.id }) else { return }
        runs.removeAll { $0.id == run.id }
        if !detachedRuns.contains(where: { $0.id == run.id }) { detachedRuns.append(run) }
        if focusedRunID == run.id { focusedRunID = runs.last?.id }
        show("Detached the view; the run is still \(run.isStreaming ? "working" : "available").")
    }

    func reattachRun(_ run: LiveRun, destination: Section = .live) {
        guard detachedRuns.contains(where: { $0.id == run.id }) else { return }
        detachedRuns.removeAll { $0.id == run.id }
        if !runs.contains(where: { $0.id == run.id }) { runs.append(run) }
        focusedRunID = run.id
        section = destination
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

/// A command acknowledgement is not an error banner. Keeping the semantic level with the
/// message prevents a successful safe-boundary cancellation from being rendered as a warning
/// merely because failures and acknowledgements share the same compact slot in the run UI.
struct RunCommandNotice: Equatable {
    enum Level: Equatable { case warning, success }

    var level: Level
    var message: String
    /// Present only for a service-backed success. Warnings deliberately carry no service
    /// identity so a later refresh can never erase a local error or draft-storage failure.
    var serviceAcknowledgement: ServiceBackedCommandNotice?

    static func warning(_ message: String) -> Self {
        .init(level: .warning, message: message, serviceAcknowledgement: nil)
    }

    static func success(
        _ message: String,
        serviceAcknowledgement: ServiceBackedCommandNotice? = nil
    ) -> Self {
        .init(
            level: .success, message: message,
            serviceAcknowledgement: serviceAcknowledgement)
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
struct PeerBridge: Agent.PeerDelegate, Agent.SelfDelegate {
    let model: AppModel

    /// A background task reporting back to the run that started it.
    ///
    /// Routed through the run rather than the agent because the interesting case is work that
    /// outlives its turn: by the time a test suite finishes, the loop that started it may have
    /// stopped, and only the run can start it again.
    func deliverToSelf(sessionID: String, text: String, from sourceSessionID: String) async -> Bool
    {
        await model.deliverSelfMessage(
            sessionID: sessionID, text: text, from: sourceSessionID)
    }

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

private enum LiveRunDraftSaveResult: Sendable {
    case saved
    case canceled
    case failed
}

/// Serializes draft writes for one attachment. A canceled debounce can be overtaken, while an
/// already-started file transaction finishes before the next value is written; older text can
/// therefore never land after newer text.
private actor LiveRunDraftPersistence {
    private let store: ServiceBackedDraftStore
    private var snapshot: ServiceBackedDraftSnapshot?

    init(store: ServiceBackedDraftStore, snapshot: ServiceBackedDraftSnapshot?) {
        self.store = store
        self.snapshot = snapshot
    }

    func replace(_ text: String, debounceNanoseconds: UInt64?) async -> LiveRunDraftSaveResult {
        if let debounceNanoseconds {
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return .canceled
            }
        }
        guard !Task.isCancelled else { return .canceled }
        do {
            snapshot = try store.replace(
                text, expectedGeneration: snapshot?.generation)
            return .saved
        } catch {
            return .failed
        }
    }

    func beginHandoff(
        text: String, kind: WorkServiceCommandKind, commandID: String
    ) throws -> ServiceBackedDraftSnapshot {
        let next = try store.beginHandoff(
            text: text, kind: kind, commandID: commandID,
            expectedGeneration: snapshot?.generation)
        snapshot = next
        return next
    }

    func resolveHandoff(
        commandID: String, accepted: Bool, currentText: String
    ) throws -> ServiceBackedDraftSnapshot? {
        guard let generation = snapshot?.generation else {
            throw ServiceBackedDraftError.conflict
        }
        let next = try store.resolveHandoff(
            commandID: commandID, accepted: accepted, currentText: currentText,
            expectedGeneration: generation)
        snapshot = next
        return next
    }
}

enum LiveRunDraftPersistenceState: Equatable {
    case memoryOnly
    case saving
    case saved
    case loadFailed
    case unavailable
    case writeFailed
}

/// The semantic delivery choice the person made before the composer schedules asynchronous
/// work. A later Run-state change may reject the command, but must never reinterpret Steer as
/// Send (or the reverse).
enum LiveRunComposerDelivery: Sendable {
    case sendNow
    case steerNext
    case queueFollowUp
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
    var isEnding = false
    var commandState: SessionCommandState = .prepared
    var exitCode: Int32?
    var usage = Usage()
    var queuedSteering: [String] = []
    var queuedFollowUps: [String] = []
    /// Unsent composer text belongs to the GUI's exact Work/Session/client attachment, not to
    /// one ephemeral SwiftUI view. Service-backed runs persist it privately across GUI process
    /// relaunch; process-owned engines retain the same navigation-safe in-memory behavior.
    private(set) var draft = ""
    /// A durable marker means this exact text may already have crossed into Work. It disables
    /// further submission until canonical evidence or an explicit user decision resolves it.
    private(set) var draftHandoff: ServiceBackedDraftHandoff?
    private(set) var draftPersistenceState: LiveRunDraftPersistenceState = .memoryOnly
    var draftPersistenceNotice: String? {
        if draftHandoff != nil {
            return "This draft has an unresolved Work Host handoff. Aviary will not resend it until exact canonical evidence resolves the command."
        }
        switch draftPersistenceState {
        case .loadFailed:
            return "A saved draft for this attachment could not be read. It remains on disk; edit the composer to replace it."
        case .unavailable:
            return "Private draft storage is unavailable. Current composer text exists only in this GUI."
        case .writeFailed:
            return "This draft could not be saved privately and currently exists only in this GUI."
        case .memoryOnly, .saving, .saved:
            return nil
        }
    }
    var sessionID: String?
    var sessionFile: String?
    /// True only after the first admitted prompt crossed the driver's durable delivery seam.
    /// A session id alone proves allocation, not that the requested work reached the Work.
    var initialPromptDelivered = false
    var modelLabel: String?
    var thinkingLevel: String?
    var contextTokens: Int?
    var contextWindow: Int?
    var startedAt = Date()
    var errorBanner: String?
    var commandNotice: RunCommandNotice?
    var stderrTail: [String] = []
    var launchCommand = ""
    var title: String = "New run"
    /// Recorded provider payloads, when the run was started with recording on.
    var wireRecords: [WireRecord] = []
    var wireLogURL: URL?

    /// One type with two backends rather than two types, because every view that renders a
    /// run — the transcript, the token panel, the sidebar row — should not have to know which
    /// engine produced it. That is the same reason the file format is shared.
    private(set) var inHouse: InHouseDriver?
    var isInHouse: Bool { inHouse != nil }

    /// Capabilities are owned by the Work driver, not inferred by a GUI. This keeps every
    /// attached view truthful when a remote or driven Work has different command semantics.
    var commandCapabilities: SessionCommandCapabilities {
        if let visualFixtureCommandCapabilities { return visualFixtureCommandCapabilities }
        if let serviceBridge { return serviceBridge.commandCapabilities }
        if let inHouse { return inHouse.commandCapabilities }
        if let claudeCode { return claudeCode.commandCapabilities }
        return SessionCommandCapabilities()
    }

    var acceptsInput: Bool {
        guard errorBanner == nil, !hasExited, !isEnding else { return false }
        if let serviceBridge {
            return initialStart == nil && draftHandoff == nil && serviceBridge.canSubmitText
        }
        switch commandState {
        case .idle: return true
        case .running:
            return commandCapabilities.supportsSteering
                || commandCapabilities.supportsQueuedFollowUps
        case .prepared, .preparing, .committing, .canceling, .failed, .ending, .ended:
            return false
        }
    }

    var serviceControlsAvailable: Bool {
        guard let serviceBridge else { return true }
        return serviceBridge.canEnd
    }

    var serviceRetryAvailable: Bool {
        (serviceBridge?.canRetryPendingCommand ?? false)
            && serviceCommandBarrier.operationsInFlight == 0
            && !serviceCommandBarrier.admissionFrozen
    }

    var draftHandoffRecoveryAvailable: Bool {
        isServiceBacked && serviceCommandBarrier.canResolveUnresolvedDraft(
            hasUnresolvedDraft: draftHandoff != nil, isEnding: isEnding)
    }

    /// Set when Claude Code is driving this run instead of Aviary.
    private(set) var claudeCode: ClaudeCodeDriver?
    var isClaudeCode: Bool { claudeCode != nil }

    /// A service-backed run is an attachment to Work owned by a Work Host.  The bridge is
    /// intentionally separate from both process-owned drivers so a GUI disconnect cannot
    /// accidentally call a local stop path.
    private(set) var serviceBridge: ServiceBackedRunBridge? = nil
    var isServiceBacked: Bool { serviceBridge != nil }
    /// Stable identity for a service-backed run. The process-local UUID above is presentation
    /// state only; relaunch/reconstruction dedupes by this exact attachment relationship.
    private(set) var serviceAttachmentKey: ServiceAttachmentKey?
    var serviceProjection: WorkServiceAttachedWorkProjection? { serviceBridge?.projection }
    /// The current descriptor is presentation metadata only. Body bytes are not fetched until
    /// the Review changes affordance explicitly opens the review sheet and the person requests
    /// a load there. It is mirrored from the bridge so an open review sheet observes canonical
    /// A-to-B selection changes instead of retaining the value read at presentation time.
    private(set) var serviceReviewDescriptor: WorkServiceArtifactDescriptor? = nil
    var canLoadServiceRepositoryReview: Bool {
        guard let descriptor = serviceReviewDescriptor,
              descriptor.available,
              descriptor.bodyReference != nil else { return false }
        return serviceProjection?.capabilities.contains(.inspectArtifacts) == true
    }

    func loadServiceRepositoryReview(
        expectedDescriptor: WorkServiceArtifactDescriptor
    ) async
        -> Result<ObservedRepositoryReview, RepositoryReviewLoadError> {
        guard let serviceBridge else { return .failure(.unavailable) }
        return await serviceBridge.loadLatestRepositoryReview(expectedDescriptor: expectedDescriptor)
    }

    var serviceActivities: [WorkActionSnapshot] { serviceBridge?.activities ?? [] }
    /// Mirrored from the non-observable service bridge so an open action sheet tracks canonical
    /// lifecycle changes instead of freezing the value that happened to be selected.
    private(set) var serviceActionPresentations: [WorkActionPresentation] = []
    /// Exact entity counts omitted from the bounded GUI projection. This is mirrored into the
    /// observable run because both Cockpit and Live must disclose omissions without an inspector.
    private(set) var serviceProjectionOmissions: [WorkServiceOmission] = []
    /// Canonical inputs owned by Work whose runtime-delivery boundary is still unresolved.
    /// This is intentionally separate from the GUI-owned composer draft and the controller's
    /// single transport mutation so none of those states can clear another by accident.
    private(set) var servicePendingInputs: [CanonicalInputDeliveryRow] = []
    /// Canonical delivery outcomes that need human attention even when no Session message was
    /// committed for them (for example, an unknown-effect crossing after a partial append).
    private(set) var serviceInputDeliveryAttention: [CanonicalInputDeliveryRow] = []
    private(set) var serviceInputDeliveryOmissions: [WorkServiceOmission] = []
    /// One GUI's bounded presentation window. These flags never imply a Work mutation or a
    /// shared read acknowledgement; every attached GUI may browse a different range.
    private(set) var serviceHistoryHasEarlier = false
    private(set) var serviceHistoryHasNewer = false
    private(set) var serviceHistoryIsLoading = false
    private(set) var serviceHistoryError: String?
    /// The last provider-bound context and the runtime's durable working state are intentionally
    /// separate. A context manifest is never evidence that a Python namespace is live.
    private(set) var recordedModelContext: RecordedModelContextProjection?
    private(set) var canonicalWorkingState: CanonicalWorkingStateProjection?
    /// Snapshot-only injection used to render the real RunPane with deterministic capabilities.
    /// Production runs always leave this nil and derive capabilities from their driver/host.
    private var visualFixtureCommandCapabilities: SessionCommandCapabilities?
    private var visualFixtureElapsedLabel: String?
    private var visualFixtureStartedLabel: String?
    var currentServiceActions: [WorkActionPresentation] {
        serviceActionPresentations.filter { !$0.state.isTerminal }
    }
    var serviceProjectionOmissionSummary: String? {
        guard !serviceProjectionOmissions.isEmpty else { return nil }
        let parts = serviceProjectionOmissions.map { omission -> String in
            if omission.category == "activity_metadata" {
                let verb = omission.count == 1 ? "has" : "have"
                return "\(omission.count) action\(omission.count == 1 ? "" : "s") \(verb) truncated metadata"
            }
            let label: String = switch omission.category {
            case "messages": "message"
            case "active_activities": "current action"
            case "activities": "resolved action"
            default: omission.category.replacingOccurrences(of: "_", with: " ") + " item"
            }
            return "\(omission.count) \(label)\(omission.count == 1 ? "" : "s") omitted from this bounded view"
        }
        return parts.joined(separator: "; ")
            + ". Full canonical records remain addressable "
            + "through the Work Host."
    }
    var serviceInputDeliveryOmissionSummary: String? {
        let deliveryOmissions = serviceInputDeliveryOmissions.filter {
            $0.category.hasPrefix("canonical_input_delivery.")
        }
        guard !deliveryOmissions.isEmpty else { return nil }
        var descriptions: [String] = []
        if deliveryOmissions.contains(where: {
            $0.category == "canonical_input_delivery.work_source"
                || $0.category == "canonical_input_delivery.session_source"
        }) {
            descriptions.append("the current Work/Session read is incomplete")
        }
        if let omitted = deliveryOmissions.first(where: {
            $0.category == "canonical_input_delivery.rows"
        }), omitted.count > 0 {
            descriptions.append(
                "\(omitted.count) delivery row\(omitted.count == 1 ? "" : "s") omitted")
        }
        if let omitted = deliveryOmissions.first(where: {
            $0.category == "canonical_input_delivery.unresolved_commands"
        }), omitted.count > 0 {
            descriptions.append(
                "\(omitted.count) unresolved input\(omitted.count == 1 ? "" : "s") omitted")
        }
        if let omitted = deliveryOmissions.first(where: {
            $0.category == "canonical_input_delivery.attention"
        }), omitted.count > 0 {
            descriptions.append(
                "\(omitted.count) input outcome\(omitted.count == 1 ? "" : "s") needing review omitted")
        }
        if let omitted = deliveryOmissions.first(where: {
            $0.category == "canonical_input_delivery.unattributed_inputs"
        }), omitted.count > 0 {
            descriptions.append(
                "\(omitted.count) host-owned input\(omitted.count == 1 ? " has" : "s have") no provable Session relationship")
        }
        guard !descriptions.isEmpty else { return nil }
        return descriptions.joined(separator: "; ")
            + ". Do not infer delivery or retry safety from this bounded view."
    }
    var serviceExecutionLabel: String? { serviceBridge?.executionLabel }
    var serviceWorkspaceLabel: String? { serviceBridge?.workspaceLabel }
    var hasCanonicalStartTime: Bool {
        !isServiceBacked
    }

    var elapsedLabel: String {
        if let visualFixtureElapsedLabel { return visualFixtureElapsedLabel }
        return hasCanonicalStartTime ? Fmt.duration(elapsed) : "time unknown"
    }

    var startedLabel: String {
        if let visualFixtureStartedLabel { return visualFixtureStartedLabel }
        return isServiceBacked ? "unknown" : Fmt.timestamp(startedAt)
    }

    init(
        inHouse driver: InHouseDriver, cwd: String, modelLabel: String,
        config: RunConfiguration? = nil
    ) {
        self.engine = EngineLocation(
            kind: .fork, path: "aviary", version: "in-house",
            note: "Aviary's own agent loop")
        var runConfig = config ?? RunConfiguration(cwd: cwd, identity: driver.identity)
        if runConfig.recordPayloads {
            let url = WireLog.path(forRun: runConfig.identity?.runID ?? id.uuidString)
            runConfig.wireLogPath = url.path
            self.wireLogURL = url
        }
        self.config = runConfig
        self.inHouse = driver
        self.modelLabel = modelLabel
        self.thinkingLevel = runConfig.thinkingLevel
        self.title = "New run"
    }

    init(
        claudeCode driver: ClaudeCodeDriver, cwd: String, modelLabel: String,
        config: RunConfiguration? = nil
    ) {
        self.engine = EngineLocation(
            kind: .fork, path: "claude", version: "driven",
            note: "Claude Code, with Aviary's kernel as its tool")
        let runConfig = config ?? RunConfiguration(cwd: cwd, identity: driver.identity)
        self.config = runConfig
        self.claudeCode = driver
        self.modelLabel = modelLabel
        self.thinkingLevel = runConfig.thinkingLevel
        self.title = "New run"
    }

    /// Rehydrate a GUI row from a durable Work-service attachment.  `cwd` is deliberately
    /// optional and is used only for the co-located launcher; remote reconstruction passes an
    /// empty value and displays the opaque workspace label instead.
    init(
        service bridge: ServiceBackedRunBridge,
        cwd: String = "",
        title: String? = nil,
        initialStart: ServiceBackedStartIntent? = nil,
        initialStartStore: ServiceBackedStartIntentStore? = nil,
        draftStore: ServiceBackedDraftStore? = nil,
        restoredDraft: ServiceBackedDraftSnapshot? = nil,
        draftRestorationFailure: ServiceDraftRestorationFailure? = nil
    ) {
        self.engine = EngineLocation(
            kind: .fork, path: "aviaryd", version: "work-service",
            note: "Durable Work Host service")
        self.config = RunConfiguration(
            cwd: cwd,
            provider: bridge.projection.descriptor.configuration.providerID,
            model: bridge.projection.descriptor.configuration.modelID,
            thinkingLevel: bridge.thinkingLevel)
        self.serviceBridge = bridge
        self.serviceAttachmentKey = bridge.serviceAttachmentKey
        self.serviceReviewDescriptor = bridge.latestRepositoryReviewDescriptor
        self.serviceActionPresentations = bridge.actionPresentations
        self.serviceProjectionOmissions = bridge.projection.projectionOmissions
        self.servicePendingInputs = bridge.pendingInputs
        self.serviceInputDeliveryAttention = bridge.inputDeliveryAttention
        self.serviceInputDeliveryOmissions = bridge.inputDeliveryProjection.omissions
        self.serviceHistoryHasEarlier = bridge.history.hasEarlier
        self.serviceHistoryHasNewer = bridge.history.hasNewer
        self.serviceHistoryIsLoading = bridge.history.status == .loading
        self.serviceHistoryError = bridge.historyError
        self.recordedModelContext = bridge.recordedModelContext
        self.canonicalWorkingState = bridge.canonicalWorkingState
        self.modelLabel = bridge.modelLabel
        self.thinkingLevel = bridge.thinkingLevel
        self.sessionID = bridge.sessionID
        self.items = bridge.transcriptItems
        self.initialPromptDelivered = bridge.hasCanonicalInputDelivery
        // WorkSnapshot currently carries no canonical run.started timestamp.  Keep the local
        // initialization value private; the service UI uses `startedLabel`/`elapsedLabel` and
        // never presents it as host history.
        self.title = title
            ?? bridge.transcriptItems.first(where: { $0.kind == .user && !$0.text.isEmpty })
                .map { String($0.text.prefix(80)) }
            ?? bridge.workspaceLabel
        self.commandState = bridge.commandState
        self.isStreaming = bridge.isStreaming
        self.hasExited = bridge.isTerminal
        self.isEnding = bridge.isEnding
        self.errorBanner = bridge.errorBanner
        self.initialStart = initialStart
        self.initialStartStore = initialStartStore
        self.draft = restoredDraft?.text ?? ""
        self.draftHandoff = restoredDraft?.handoff
        if let draftStore {
            self.draftPersistence = LiveRunDraftPersistence(
                store: draftStore, snapshot: restoredDraft)
            self.draftPersistenceState = draftRestorationFailure == .recordUnreadable
                ? .loadFailed : .saved
        } else if draftRestorationFailure == .storeUnavailable {
            self.draftPersistenceState = .unavailable
        }
    }

    /// Update the in-memory composer immediately and queue one bounded private save. Repeated
    /// keystrokes cancel only the debounce; an I/O operation already underway remains ordered
    /// before the newer value by `LiveRunDraftPersistence`.
    func setDraft(_ text: String) {
        guard !draftPersistenceFrozen else { return }
        guard draft != text else { return }
        draft = text
        guard let draftPersistence else { return }
        draftRequiresPersistence = true
        draftContentRevision &+= 1
        // While the submission marker is being made durable, retain edits in memory but do not
        // race a plain replacement ahead of that transaction. The handoff path flushes this
        // newer revision immediately before crossing the service boundary.
        if draftHandoffPreparationInProgress {
            draftPersistenceState = .saving
            return
        }
        let revision = draftContentRevision
        draftPersistenceTask?.cancel()
        draftPersistenceState = .saving
        draftPersistenceTask = Task { [weak self, draftPersistence] in
            let result = await draftPersistence.replace(
                text,
                // Once a command is handed off, the old draft must disappear durably without
                // a crash window. Manual deletion benefits from the same immediate behavior.
                debounceNanoseconds:
                    text.isEmpty
                        || (self?.serviceCommandBarrier.operationsInFlight ?? 0) > 0
                        ? nil : 175_000_000)
            guard let self, self.draftContentRevision == revision else { return }
            switch result {
            case .saved:
                self.draftPersistenceState = .saved
                self.draftRequiresPersistence = false
                self.draftPersistenceTask = nil
            case .failed:
                self.draftPersistenceState = .writeFailed
                self.draftPersistenceTask = nil
            case .canceled:
                break
            }
        }
    }

    /// Flush the exact latest draft before a GUI process disconnects from the Work Host. This
    /// never sends a Work command and never changes canonical conversation state.
    @discardableResult
    func flushDraftPersistence(freezeEdits: Bool = false) async -> Bool {
        if freezeEdits { draftPersistenceFrozen = true }
        guard let draftPersistence else {
            // A corrupt/unavailable store with no in-memory text has no newest draft to lose.
            // Keep its diagnostic for the next attach, but do not make an empty composer an
            // unquittable application. Nonempty memory-only service text still blocks exit.
            return draft.isEmpty
        }
        // A failed load may represent recoverable bytes. Normal quit must not reinterpret an
        // empty in-memory editor as user intent to delete them. The first edit makes replacement
        // explicit and enters the ordinary save path.
        if draftPersistenceState == .loadFailed, !draftRequiresPersistence {
            return draft.isEmpty
        }
        while true {
            // Flush callers may overlap (delivery, close, quit). Only a content edit advances
            // this revision, so concurrent idempotent writes cannot invalidate each other.
            let revision = draftContentRevision
            let text = draft
            draftPersistenceTask?.cancel()
            draftPersistenceTask = nil
            draftPersistenceState = .saving
            let result = await draftPersistence.replace(text, debounceNanoseconds: nil)
            // An ordinary close or post-handoff flush does not freeze the editor. If a new
            // edit arrived across the actor hop, loop and make that latest value durable too.
            guard draftContentRevision == revision else { continue }
            switch result {
            case .saved:
                draftPersistenceState = .saved
                draftRequiresPersistence = false
                return true
            case .failed, .canceled:
                draftPersistenceState = .writeFailed
                return false
            }
        }
    }

    /// Resolve the composer only after the host accepted delivery. If the editor is unchanged,
    /// clear it; if the user already typed the next message, keep that text. Either way, await an
    /// immediate durable write so a crash cannot resurrect the submitted draft.
    func reconcileDraftAfterHandOff(_ submittedText: String) async {
        if draft == submittedText { setDraft("") }
        _ = await flushDraftPersistence()
    }

    /// Make the submission identity durable before invoking the controller. If the user edits
    /// while this file transaction is in flight, persist that next draft behind the marker
    /// before the service call begins. A failed marker/write proves no service call happened.
    private func beginDraftHandoff(
        text: String, kind: WorkServiceCommandKind, commandID: String
    ) async -> Bool {
        guard draft == text, draftHandoff == nil, let draftPersistence else {
            commandNotice = .warning(
                draftHandoff == nil
                    ? "The current draft is not durably ready to send."
                    : "A prior draft handoff still needs explicit reconciliation.")
            return false
        }
        let submittedRevision = draftContentRevision
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        draftHandoffPreparationInProgress = true
        draftPersistenceState = .saving
        do {
            let snapshot = try await draftPersistence.beginHandoff(
                text: text, kind: kind, commandID: commandID)
            draftHandoff = snapshot.handoff
            draftHandoffPreparationInProgress = false
            draftPersistenceState = .saved
            draftRequiresPersistence = draftContentRevision != submittedRevision
            var newerDraftSaved = true
            if draftRequiresPersistence {
                newerDraftSaved = await flushDraftPersistence()
            }
            if !newerDraftSaved {
                // The service has not been called. Clear the marker as a proven rejection while
                // preserving both the on-disk submitted text and the newer in-memory edit.
                do {
                    let resolved = try await draftPersistence.resolveHandoff(
                        commandID: commandID, accepted: false, currentText: draft)
                    draftHandoff = resolved?.handoff
                    draftPersistenceState = .saved
                    draftRequiresPersistence = false
                    commandNotice = .warning(
                        "Nothing was sent; the newer text was returned to the composer.")
                } catch {
                    // Keep the in-memory marker if the store could not prove its removal.
                    draftPersistenceState = .writeFailed
                    commandNotice = .warning(
                        "The newer draft could not be saved, so nothing was sent.")
                }
                return false
            }
            return true
        } catch {
            draftHandoffPreparationInProgress = false
            draftPersistenceState = .writeFailed
            commandNotice = .warning(
                "The draft handoff could not be saved privately, so nothing was sent.")
            return false
        }
    }

    /// Apply one exact command outcome to the durable marker. Core persistence decides whether
    /// accepted delivery may clear the text by comparing its submitted digest; newer edits are
    /// retained and immediately made durable after the marker is removed.
    @discardableResult
    private func resolveDraftHandoff(commandID: String, accepted: Bool) async -> Bool {
        guard draftHandoff?.commandID == commandID,
              let draftPersistence else { return draftHandoff == nil }
        let resolutionRevision = draftContentRevision
        let currentText = draft
        draftPersistenceTask?.cancel()
        draftPersistenceTask = nil
        draftPersistenceState = .saving
        do {
            let snapshot = try await draftPersistence.resolveHandoff(
                commandID: commandID, accepted: accepted, currentText: currentText)
            draftHandoff = snapshot?.handoff
            if draftContentRevision == resolutionRevision {
                let resolvedText = snapshot?.text ?? ""
                if draft != resolvedText {
                    draft = resolvedText
                    draftContentRevision &+= 1
                }
            }
            let storedText = snapshot?.text ?? ""
            draftRequiresPersistence = draft != storedText
            draftPersistenceState = .saved
            if draftRequiresPersistence {
                return await flushDraftPersistence()
            }
            return true
        } catch {
            draftPersistenceState = .writeFailed
            commandNotice = .warning(
                "The Work command outcome is known, but its local draft marker could not be resolved.")
            return false
        }
    }

    private func commandWasDefinitivelyRejected(
        commandID: String, error: Error
    ) async -> Bool {
        if error is ServiceBackedRunBridgeError { return true }
        guard let pending = await serviceBridge?.controller.pendingCommand(),
              pending.commandID == commandID else { return false }
        return pending.state == .stale
    }

    /// Polling is read-only, but an exact canonical command can settle the local handoff marker.
    /// Unknown/indeterminate evidence leaves it intact and therefore keeps submission disabled.
    private func reconcileDraftHandoffFromProjection() async {
        // The request/retry that owns this marker resolves it. A timer refresh may observe the
        // same canonical event while that operation is suspended, but must not race a second
        // local CAS and turn successful resolution into a spurious write failure.
        guard serviceCommandBarrier.operationsInFlight == 0,
              !draftHandoffPreparationInProgress else { return }
        guard let handoff = draftHandoff, let serviceAttachmentKey,
              let projection = serviceBridge?.projection else { return }
        switch ServiceBackedDraftHandoffDisposition.classify(
            handoff, key: serviceAttachmentKey, projection: projection) {
        case .accepted:
            guard beginServiceCommandOperation(allowingUnresolvedDraft: true) else { return }
            defer { finishServiceCommandOperation() }
            _ = await resolveDraftHandoff(commandID: handoff.commandID, accepted: true)
        case .rejected:
            guard beginServiceCommandOperation(allowingUnresolvedDraft: true) else { return }
            defer { finishServiceCommandOperation() }
            _ = await resolveDraftHandoff(commandID: handoff.commandID, accepted: false)
        case .unresolved:
            break
        }
    }

    /// Explicitly return an unresolved submitted value to the composer. This is the only escape
    /// hatch when a crash happened after the marker write but before any canonical command was
    /// observed; Aviary never performs this potentially duplicating choice automatically.
    func returnUnresolvedDraftToComposer() async -> Bool {
        guard let handoff = draftHandoff else { return true }
        guard beginServiceCommandOperation(allowingUnresolvedDraft: true) else { return false }
        defer { finishServiceCommandOperation() }
        let resolved = await resolveDraftHandoff(
            commandID: handoff.commandID, accepted: false)
        if resolved {
            commandNotice = .warning(
                "The unresolved handoff was returned to the composer. Review Work before sending it again.")
        }
        return resolved
    }

    func freezeServiceComposerAdmission() {
        serviceCommandBarrier.freeze()
    }

    func waitForServiceComposerCommands() async {
        guard serviceCommandBarrier.operationsInFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            serviceComposerCommandWaiters.append(continuation)
        }
    }

    func resumeAfterAbortedShutdown() {
        draftPersistenceFrozen = false
        serviceCommandBarrier.resume()
    }

    private func beginServiceCommandOperation(
        allowingUnresolvedDraft: Bool = false
    ) -> Bool {
        serviceCommandBarrier.begin(
            hasUnresolvedDraft: draftHandoff != nil,
            allowingUnresolvedDraft: allowingUnresolvedDraft)
    }

    private func finishServiceCommandOperation() {
        precondition(serviceCommandBarrier.operationsInFlight > 0)
        guard serviceCommandBarrier.finish() else { return }
        let waiters = serviceComposerCommandWaiters
        serviceComposerCommandWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
    private func publish<T: Equatable>(_ value: T, to keyPath: ReferenceWritableKeyPath<LiveRun, T>)
    {
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
                self.publish(
                    claudeCode.initialPromptDelivered, to: \.initialPromptDelivered)
                self.publish(claudeCode.errorBanner, to: \.errorBanner)
                self.publish(claudeCode.commandNotice, to: \.commandNotice)
                self.publish(await claudeCode.commandState(), to: \.commandState)
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
                self.publish(
                    inHouse.initialPromptDelivered, to: \.initialPromptDelivered)
                self.publish(inHouse.errorBanner, to: \.errorBanner)
                self.publish(inHouse.commandNotice, to: \.commandNotice)
                self.publish(await inHouse.commandState(), to: \.commandState)
                self.publish(inHouse.pendingSteering, to: \.queuedSteering)
                self.publish(inHouse.pendingFollowUps, to: \.queuedFollowUps)
                if let label = inHouse.modelLabel { self.publish(label, to: \.modelLabel) }
                self.refreshWireLog()
                // Only stop mirroring once the run is genuinely finished. Idle-between-prompts
                // is not finished — the interpreter and the conversation are still alive.
                if inHouse.hasExited { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Admit the first prompt through the Work service.  This is deliberately asynchronous and
    /// does not create a local writer or runtime; the Work Host performs that preparation after
    /// durable Create/Start admission.
    @discardableResult
    func startService(
        prompt: String, commandID: String? = nil,
        operationAlreadyAdmitted: Bool = false
    ) async -> LiveRunCommandResult {
        guard let serviceBridge else { return .rejected("not a Work-service run") }
        let ownsOperation: Bool
        if operationAlreadyAdmitted {
            ownsOperation = false
        } else {
            guard beginServiceCommandOperation() else {
                commandNotice = .warning(
                    serviceCommandBarrier.operationsInFlight > 0
                        ? "Another Work command is already in progress."
                        : "This GUI cannot start Work while it is disconnecting or reconciling a draft.")
                return .rejected("Start admission unavailable")
            }
            ownsOperation = true
        }
        defer {
            if ownsOperation { finishServiceCommandOperation() }
        }
        guard let start = ServiceBackedGUIOrchestration.startCommand(
            prompt: prompt, commandID: commandID, retained: initialStart) else {
            if let commandID, draftHandoff?.commandID == commandID {
                _ = await resolveDraftHandoff(commandID: commandID, accepted: false)
            }
            commandNotice = .warning(
                "A prior Start is still unresolved; these newer prompt bytes were not sent.")
            return .rejected("Start command identity does not match prompt")
        }
        let effectivePrompt = start.prompt
        let effectiveCommandID = start.commandID
        if !effectivePrompt.isEmpty, title == "New run" {
            title = String(effectivePrompt.prefix(60))
        }
        do {
            let receipt = try await serviceBridge.start(effectivePrompt, commandID: effectiveCommandID)
            var draftMarkerResolved = true
            if let effectiveCommandID,
               draftHandoff?.commandID == effectiveCommandID {
                draftMarkerResolved = await resolveDraftHandoff(
                    commandID: effectiveCommandID, accepted: true)
            }
            var retainedMarkerWarning: String?
            if let initialStart {
                if serviceBridge.hasCanonicalStartEvidence(for: initialStart) {
                    do {
                        guard let initialStartStore else {
                            throw ServiceBackedStartIntentError.corrupt
                        }
                        try initialStartStore.clear(initialStart)
                        self.initialStart = nil
                    } catch {
                        retainedMarkerWarning =
                            "Canonical Start evidence is present, but its local recovery marker could not be cleared."
                    }
                } else {
                    // A receipt is not the canonical command event. Keep the independent
                    // Create-to-Start bootstrap marker until a complete Work read proves the
                    // exact client-qualified command, including across GUI termination here.
                    retainedMarkerWarning =
                        "Start was accepted; its local recovery marker remains until the exact canonical command is observed."
                }
            }
            syncServiceState()
            if draftMarkerResolved {
                if let retainedMarkerWarning {
                    commandNotice = .warning(retainedMarkerWarning)
                } else {
                    setServiceSuccessNotice(
                        "Agent service accepted your message; updating this chat…",
                        kind: .start, receipt: receipt)
                }
            }
            return .service(receipt)
        } catch {
            if let effectiveCommandID,
               draftHandoff?.commandID == effectiveCommandID,
               await commandWasDefinitivelyRejected(
                   commandID: effectiveCommandID, error: error) {
                _ = await resolveDraftHandoff(
                    commandID: effectiveCommandID, accepted: false)
            }
            if let initialStart {
                let pending = await serviceBridge.controller.pendingCommand()
                let definitiveRejection = error is ServiceBackedRunBridgeError
                    || pending?.state == .stale
                if definitiveRejection {
                    // A structured rejection or stale cursor proves this exact Start never
                    // crossed the host boundary. Clear the GUI bootstrap obligation; the
                    // controller still exposes a stale command as an explicit repair, never as
                    // an automatic replay. Transport/source uncertainty keeps the marker.
                    if let initialStartStore {
                        do {
                            try initialStartStore.clear(initialStart)
                            self.initialStart = nil
                        } catch {
                            commandNotice = .warning(
                                "Start was rejected, but its local recovery marker could not be cleared.")
                        }
                    } else {
                        commandNotice = .warning(
                            "Start was rejected, but its local recovery marker has no durable store.")
                    }
                }
            }
            syncServiceState()
            commandNotice = .warning(serviceBridge.errorBanner ?? "Start was not accepted.")
            return .rejected(serviceBridge.errorBanner ?? "Work service unavailable")
        }
    }

    private func syncServiceState() {
        guard let serviceBridge else { return }
        publish(serviceBridge.transcriptItems, to: \.items)
        publish(serviceBridge.isStreaming, to: \.isStreaming)
        publish(serviceBridge.isTerminal, to: \.hasExited)
        publish(serviceBridge.isEnding, to: \.isEnding)
        publish(serviceBridge.commandState, to: \.commandState)
        publish(serviceBridge.errorBanner, to: \.errorBanner)
        publish(serviceBridge.modelLabel, to: \.modelLabel)
        publish(serviceBridge.thinkingLevel, to: \.thinkingLevel)
        publish(serviceBridge.actionPresentations, to: \.serviceActionPresentations)
        publish(serviceBridge.projection.projectionOmissions, to: \.serviceProjectionOmissions)
        publish(serviceBridge.pendingInputs, to: \.servicePendingInputs)
        publish(serviceBridge.inputDeliveryAttention, to: \.serviceInputDeliveryAttention)
        publish(
            serviceBridge.inputDeliveryProjection.omissions,
            to: \.serviceInputDeliveryOmissions)
        publish(serviceBridge.history.hasEarlier, to: \.serviceHistoryHasEarlier)
        publish(serviceBridge.history.hasNewer, to: \.serviceHistoryHasNewer)
        publish(serviceBridge.history.status == .loading, to: \.serviceHistoryIsLoading)
        publish(serviceBridge.historyError, to: \.serviceHistoryError)
        publish(serviceBridge.recordedModelContext, to: \.recordedModelContext)
        publish(serviceBridge.canonicalWorkingState, to: \.canonicalWorkingState)
        publish(serviceBridge.latestRepositoryReviewDescriptor, to: \.serviceReviewDescriptor)
        // This is canonical Session evidence (input.accepted/message history), not a Start
        // receipt. It remains true even when the visible transcript has bounded omissions.
        publish(serviceBridge.hasCanonicalInputDelivery, to: \.initialPromptDelivered)
    }

    private func serviceAcknowledgement(
        kind: WorkServiceCommandKind,
        receipt: WorkServiceCommandReceipt
    ) -> ServiceBackedCommandNotice? {
        guard let serviceBridge else { return nil }
        let key = serviceBridge.serviceAttachmentKey
        return ServiceBackedCommandNotice(
            work: receipt.work, commandID: receipt.commandID, kind: kind,
            client: key.client, attachment: key.clientAttachment,
            sessionAttachment: key.workSession.sessionAttachment)
    }

    private func setServiceSuccessNotice(
        _ message: String,
        kind: WorkServiceCommandKind,
        receipt: WorkServiceCommandReceipt
    ) {
        commandNotice = .success(
            message,
            serviceAcknowledgement: serviceAcknowledgement(kind: kind, receipt: receipt))
        // Normally the receipt marks the projection as requiring refresh, but a synchronous
        // duplicate/reconstruction can already have canonical evidence. Reconcile immediately
        // as well as from the polling path without weakening the incomplete-read guard.
        reconcileServiceCommandNotice()
    }

    /// Retire only an acknowledgement whose exact canonical command has caught up. The policy
    /// is intentionally called after all refresh/recovery work so warnings produced by those
    /// paths, including local draft failures, remain visible.
    private func reconcileServiceCommandNotice() {
        guard let notice = commandNotice,
              notice.level == .success,
              let acknowledgement = notice.serviceAcknowledgement,
              let projection = serviceBridge?.projection else { return }
        if ServiceBackedCommandNoticePolicy.shouldClear(acknowledgement, from: projection) {
            commandNotice = nil
        }
    }

    /// Load one older page for this GUI only. Failure preserves the authenticated rows already
    /// on screen and exposes a retry affordance; it never retries a command or acknowledges a
    /// shared read cursor.
    func loadEarlierServiceHistory() async {
        guard let serviceBridge, !serviceHistoryIsLoading else { return }
        publish(true, to: \.serviceHistoryIsLoading)
        defer {
            syncServiceState()
            publish(false, to: \.serviceHistoryIsLoading)
        }
        do {
            _ = try await serviceBridge.loadEarlierHistory()
        } catch {
            // The bridge stores bounded, non-sensitive presentation copy for the retry banner.
        }
    }

    /// Explicitly leave historical browsing and return to the newest already-authenticated
    /// Session projection. No network request or Work lifecycle action is involved.
    func jumpServiceHistoryToLatest() async {
        guard let serviceBridge else { return }
        _ = await serviceBridge.jumpHistoryToLatest()
        syncServiceState()
    }

    /// Begin observing an already-existing attachment without issuing Start or Attach.
    func observeService() {
        guard serviceBridge != nil else { return }
        syncServiceState()
    }

    func refreshService(resumeInitialStart: Bool = true) async {
        guard let serviceBridge else { return }
        _ = await serviceBridge.refresh()
        syncServiceState()
        await reconcileDraftHandoffFromProjection()
        var startResolvedByEvidence = false
        if let initialStart,
           serviceBridge.hasCanonicalStartEvidence(for: initialStart) {
            startResolvedByEvidence = true
            do {
                guard let initialStartStore else {
                    throw ServiceBackedStartIntentError.corrupt
                }
                try initialStartStore.clear(initialStart)
                self.initialStart = nil
            } catch {
                // Keep the in-memory marker as a guard until the durable file can be removed.
                commandNotice = .warning(
                    "Canonical Start evidence is present, but the local recovery marker remains.")
            }
        }
        // If the GUI had to wait through a transiently incomplete first read, retry the
        // persisted Start only after the pair is canonical. A command that already crossed the
        // boundary remains in the controller's durable pending record and is never auto-replayed.
        if resumeInitialStart, !initialStartRequiresExplicitRetry, !startResolvedByEvidence, let initialStart,
           serviceCommandBarrier.operationsInFlight == 0,
           serviceBridge.projection.isCanonical,
           serviceBridge.hasMatchingStartAttachment(for: initialStart),
           serviceBridge.commandState == .idle,
           await serviceBridge.controller.pendingCommand() == nil {
            _ = await startService(
                prompt: initialStart.prompt, commandID: initialStart.commandID)
        }
        reconcileServiceCommandNotice()
    }

    /// User-directed repair of a command whose durable outcome was not yet safely known.
    func retryServiceCommand() async -> LiveRunCommandResult {
        guard let serviceBridge else { return .rejected("not a Work-service run") }
        guard beginServiceCommandOperation(allowingUnresolvedDraft: true) else {
            commandNotice = .warning(
                serviceCommandBarrier.operationsInFlight > 0
                    ? "Another Work command reconciliation is already in progress."
                    : "Aviary is disconnecting this GUI; the pending command was not retried.")
            return .rejected("command reconciliation unavailable")
        }
        defer { finishServiceCommandOperation() }
        let pending = await serviceBridge.controller.pendingCommand()
        do {
            let receipt = try await serviceBridge.retryPendingCommand()
            let markerResolved: Bool
            if let pending, draftHandoff?.commandID == pending.commandID {
                markerResolved = await resolveDraftHandoff(
                    commandID: pending.commandID, accepted: true)
            } else {
                markerResolved = true
            }
            if markerResolved {
                setServiceSuccessNotice(
                    "Agent service accepted your message; updating this chat…",
                    kind: pending?.kind ?? .start, receipt: receipt)
            }
            syncServiceState()
            return .service(receipt)
        } catch {
            if let pending, draftHandoff?.commandID == pending.commandID,
               await commandWasDefinitivelyRejected(
                   commandID: pending.commandID, error: error) {
                _ = await resolveDraftHandoff(
                    commandID: pending.commandID, accepted: false)
            }
            syncServiceState()
            let detail = serviceBridge.errorBanner ?? error.localizedDescription
            commandNotice = .warning(detail)
            return .rejected(detail)
        }
    }

    /// Remove a stale command intent after the current canonical state has been reviewed.
    func abandonStaleServiceCommand() async -> Bool {
        guard let serviceBridge else { return false }
        guard beginServiceCommandOperation(allowingUnresolvedDraft: true) else { return false }
        defer { finishServiceCommandOperation() }
        let pending = await serviceBridge.controller.pendingCommand()
        do {
            try await serviceBridge.abandonStaleCommand()
            if let pending, draftHandoff?.commandID == pending.commandID {
                guard await resolveDraftHandoff(
                    commandID: pending.commandID, accepted: false) else {
                    syncServiceState()
                    return false
                }
            }
            syncServiceState()
            return true
        } catch {
            syncServiceState()
            commandNotice = .warning(serviceBridge.errorBanner ?? error.localizedDescription)
            return false
        }
    }

    private var mirror: Task<Void, Never>?
    private var initialStart: ServiceBackedStartIntent?
    /// Observation-only reconstruction must not become an automatic Start on the next poll.
    var initialStartRequiresExplicitRetry = false
    var savedInitialPrompt: String? { initialStart?.prompt }
    func hasCanonicalDelivery(for chat: PendingChat) -> Bool {
        guard let serviceBridge else { return false }
        return chat.hasCanonicalDelivery(in: serviceBridge.projection)
    }
    private var initialStartStore: ServiceBackedStartIntentStore?
    private var draftPersistence: LiveRunDraftPersistence?
    private var draftPersistenceTask: Task<Void, Never>?
    private var draftContentRevision: UInt64 = 0
    private var draftRequiresPersistence = false
    private var draftPersistenceFrozen = false
    private var draftHandoffPreparationInProgress = false
    private var serviceCommandBarrier = ServiceBackedGUIOrchestration.CommandBarrier()
    private var serviceComposerCommandWaiters: [CheckedContinuation<Void, Never>] = []
    /// End, Quit, and Reload all join this same teardown. `isEnding` is presentation state,
    /// not proof that cleanup finished.
    private var stopTask: Task<Void, Never>?

    init(engine: EngineLocation, config: RunConfiguration) {
        self.engine = engine
        var config = config
        if config.recordPayloads {
            // The path has to be decided here, where the run's identity exists.
            let url = WireLog.path(forRun: config.identity?.runID ?? id.uuidString)
            config.wireLogPath = url.path
            self.wireLogURL = url
        }
        self.config = config
        self.modelLabel = [config.provider, config.model].compactMap { $0 }.joined(separator: "/")
        self.thinkingLevel = config.thinkingLevel
    }

    /// Build deterministic presentation state for the offscreen screenshot harness while using
    /// the actual production RunPane and TranscriptRow implementations. This never constructs a
    /// service attachment and must not be treated as persistence or transport certification.
    static func productionRunPaneVisualFixture(
        items: [TranscriptItem],
        pendingInputs: [CanonicalInputDeliveryRow],
        deliveryAttention: [CanonicalInputDeliveryRow],
        actions: [WorkActionPresentation],
        recordedModelContext: RecordedModelContextProjection? = nil,
        canonicalWorkingState: CanonicalWorkingStateProjection? = nil,
        draft: String
    ) -> LiveRun {
        let run = LiveRun(
            engine: EngineLocation(
                kind: .fork, path: "aviaryd-fixture", version: "presentation",
                note: "Production RunPane visual fixture"),
            config: RunConfiguration(
                cwd: "/remote/workspaces/aviary",
                provider: "anthropic", model: "claude-sonnet-4-5",
                thinkingLevel: "high"))
        run.title = "Canonical input delivery"
        run.items = items
        run.commandState = .running
        run.isStreaming = true
        run.modelLabel = "claude-sonnet-4-5"
        run.contextTokens = 31_240
        run.contextWindow = 200_000
        var usage = Usage()
        usage.input = 3_842
        usage.output = 286
        usage.cacheRead = 2_910
        usage.totalTokens = 7_038
        run.usage = usage
        run.servicePendingInputs = pendingInputs
        run.serviceInputDeliveryAttention = deliveryAttention
        run.serviceActionPresentations = actions
        run.recordedModelContext = recordedModelContext
        run.canonicalWorkingState = canonicalWorkingState
        run.visualFixtureCommandCapabilities = SessionCommandCapabilities(
            supportsSteering: true, supportsQueuedFollowUps: true,
            cancellationScopes: [.agentLoop])
        run.visualFixtureElapsedLabel = "time unknown"
        run.visualFixtureStartedLabel = "unknown"
        run.launchCommand = "aviaryd · workspace workspace-aviary"
        run.draft = draft
        return run
    }

    var projectName: String {
        if let serviceWorkspaceLabel, !serviceWorkspaceLabel.isEmpty {
            return serviceWorkspaceLabel
        }
        return URL(fileURLWithPath: config.cwd).lastPathComponent
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    var presentationState: String {
        switch commandState {
        case .prepared, .preparing, .committing: return "preparing"
        case .running: return "working"
        case .idle: return "idle"
        case .canceling: return "canceling"
        case .failed: return "failed"
        case .ending: return "ending"
        case .ended: return "completed"
        }
    }

    var contextShare: Double? {
        guard let t = contextTokens else { return nil }
        return Fmt.contextShare(used: t, window: contextWindow)
    }

    /// Re-read the recorded payloads. Cheap: a handful of records per run.
    func refreshWireLog() {
        guard let url = wireLogURL else { return }
        let next = WireLog.read(url: url)
        guard
            next.count != wireRecords.count
                || next.last?.seq != wireRecords.last?.seq
                || next.last?.status != wireRecords.last?.status
        else { return }
        wireRecords = next
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

    func send(_ text: String) async -> LiveRunCommandResult {
        await send(text, fromComposer: false, requiredDelivery: nil)
    }

    /// Submit the exact composer action captured at the click/key-command boundary. Work may
    /// advance while the durable draft handoff is written; that can yield a typed rejection, but
    /// this method never changes the requested command kind to accommodate the newer state.
    func submitComposer(
        _ text: String, delivery: LiveRunComposerDelivery
    ) async -> LiveRunCommandResult {
        switch delivery {
        case .queueFollowUp:
            return await queueFollowUp(text, fromComposer: true, requireActiveRun: true)
        case .sendNow, .steerNext:
            return await send(text, fromComposer: true, requiredDelivery: delivery)
        }
    }

    private func send(
        _ text: String, fromComposer: Bool,
        requiredDelivery: LiveRunComposerDelivery?
    ) async -> LiveRunCommandResult {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            commandNotice = .warning("Could not send: empty input.")
            return .rejected("empty input")
        }
        if let serviceBridge {
            guard beginServiceCommandOperation() else {
                if draftHandoff != nil {
                    commandNotice = .warning(
                        "A prior draft handoff still needs explicit reconciliation.")
                    return .rejected("draft handoff unresolved")
                }
                commandNotice = .warning(
                    serviceCommandBarrier.operationsInFlight > 0
                        ? "Another composer command is already crossing into Work."
                        : "Aviary is disconnecting this GUI; this message was not sent.")
                return .rejected("composer command unavailable")
            }
            defer { finishServiceCommandOperation() }
            guard serviceBridge.hasExactRunOwner, serviceBridge.projection.isCanonical else {
                commandNotice = .warning("This Work's active Session owner is unavailable.")
                return .rejected("exact Session owner unavailable")
            }
            if serviceBridge.requiresStartForNextInput {
                guard requiredDelivery != .steerNext else {
                    commandNotice = .warning(
                        "The Work settled before this steering message crossed. The draft was preserved.")
                    return .rejected("steering state changed")
                }
                let commandID = fromComposer ? UUID().uuidString.lowercased() : nil
                if let commandID {
                    guard await beginDraftHandoff(
                        text: text, kind: .start, commandID: commandID) else {
                        return .rejected("draft handoff unavailable")
                    }
                }
                let result = await startService(
                    prompt: text, commandID: commandID, operationAlreadyAdmitted: true)
                return result
            }
            let kind: WorkServiceCommandKind
            if requiredDelivery == .sendNow {
                guard !serviceBridge.isStreaming else {
                    commandNotice = .warning(
                        "The Work started running before this Send crossed. The draft was preserved.")
                    return .rejected("send state changed")
                }
                kind = .send
            } else if requiredDelivery == .steerNext {
                guard serviceBridge.isStreaming else {
                    commandNotice = .warning(
                        "The Work settled before this steering message crossed. The draft was preserved.")
                    return .rejected("steering state changed")
                }
                guard serviceBridge.commandCapabilities.supportsSteering else {
                    commandNotice = .warning(
                        "This Work does not advertise steering. The draft was preserved.")
                    return .rejected("steering unavailable")
                }
                kind = .steer
            } else {
                if serviceBridge.isStreaming {
                    guard serviceBridge.commandCapabilities.supportsSteering else {
                        if serviceBridge.commandCapabilities.supportsQueuedFollowUps {
                            commandNotice = .warning(
                                "This Work is busy; use Queue follow-up for the next turn.")
                        } else {
                            commandNotice = .warning(
                                "This Work is busy and does not advertise steering.")
                        }
                        return .rejected("steering unavailable")
                    }
                    kind = .steer
                } else {
                    kind = .send
                }
            }
            let commandID = fromComposer ? UUID().uuidString.lowercased() : nil
            if let commandID {
                guard await beginDraftHandoff(
                    text: text, kind: kind, commandID: commandID) else {
                    return .rejected("draft handoff unavailable")
                }
            }
            do {
                let receipt: WorkServiceCommandReceipt
                if kind == .steer {
                    receipt = try await serviceBridge.steer(text, commandID: commandID)
                } else {
                    receipt = try await serviceBridge.send(text, commandID: commandID)
                }
                let markerResolved = if let commandID {
                    await resolveDraftHandoff(commandID: commandID, accepted: true)
                } else {
                    true
                }
                if receipt.state == .accepted || receipt.state == .duplicate {
                    if title == "New run" { title = String(text.prefix(60)) }
                    if markerResolved {
                        setServiceSuccessNotice(
                            "Agent service accepted your message; updating this chat…",
                            kind: kind, receipt: receipt)
                    }
                }
                syncServiceState()
                return .service(receipt)
            } catch {
                if let commandID, await commandWasDefinitivelyRejected(
                    commandID: commandID, error: error) {
                    _ = await resolveDraftHandoff(
                        commandID: commandID, accepted: false)
                }
                syncServiceState()
                commandNotice = .warning(serviceBridge.errorBanner ?? "The Work Host did not accept that command.")
                return .rejected(serviceBridge.errorBanner ?? "Work service unavailable")
            }
        }
        if let claudeCode {
            // No steering. Claude Code owns the turn boundary and will not take an injection
            // mid-turn, so a message sent now would either be lost or arrive as a second
            // conversation. Refusing plainly beats a queue that quietly reorders the session.
            guard requiredDelivery != .steerNext, !claudeCode.isStreaming else {
                commandNotice = .warning(
                    "Claude Code is mid-turn, and it does not accept steering — the turn "
                        + "boundary is its own. Wait for it to finish.")
                return .rejected("steering unavailable")
            }
            let receipt = await claudeCode.send(text)
            if receipt.wasHandedOff, title == "New run" { title = String(text.prefix(60)) }
            return .session(receipt)
        }
        if let inHouse {
            if requiredDelivery == .sendNow {
                guard !inHouse.isStreaming else {
                    commandNotice = .warning(
                        "The run started working before this Send crossed. The draft was preserved.")
                    return .rejected("send state changed")
                }
                let receipt = await inHouse.send(text)
                if receipt.wasHandedOff, title == "New run" { title = String(text.prefix(60)) }
                return .session(receipt)
            }
            if requiredDelivery == .steerNext {
                guard inHouse.isStreaming else {
                    commandNotice = .warning(
                        "The run settled before this steering message crossed. The draft was preserved.")
                    return .rejected("steering state changed")
                }
                let receipt = await inHouse.steer(text)
                queuedSteering = inHouse.pendingSteering
                return .session(receipt)
            }
            if inHouse.isStreaming {
                // Steer rather than refuse: the composer should stay usable while the agent
                // works, and the message lands at the next turn boundary where the
                // conversation is well-formed.
                let receipt = await inHouse.steer(text)
                queuedSteering = inHouse.pendingSteering
                return .session(receipt)
            }
            let receipt = await inHouse.send(text)
            if receipt.wasHandedOff, title == "New run" { title = String(text.prefix(60)) }
            return .session(receipt)
        }
        commandNotice = .warning("This run has no engine behind it.")
        return .rejected("no engine")
    }

    /// Queue a message for after the current turn.
    ///
    /// The harness had a server-side queue for this. Aviary's own engine steers instead —
    /// the message lands at the next turn boundary, which is the same guarantee without a
    /// second place for a message to sit unacknowledged.
    func queueFollowUp(
        _ text: String, fromComposer: Bool = false,
        requireActiveRun: Bool = false
    ) async -> LiveRunCommandResult {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            commandNotice = .warning("Could not queue: empty input.")
            return .rejected("empty input")
        }
        if let serviceBridge {
            guard beginServiceCommandOperation() else {
                if draftHandoff != nil {
                    commandNotice = .warning(
                        "A prior draft handoff still needs explicit reconciliation.")
                    return .rejected("draft handoff unresolved")
                }
                commandNotice = .warning(
                    serviceCommandBarrier.operationsInFlight > 0
                        ? "Another composer command is already crossing into Work."
                        : "Aviary is disconnecting this GUI; this follow-up was not queued.")
                return .rejected("composer command unavailable")
            }
            defer { finishServiceCommandOperation() }
            guard !requireActiveRun || serviceBridge.isStreaming else {
                commandNotice = .warning(
                    "The Work settled before this follow-up crossed. The draft was preserved.")
                return .rejected("queue state changed")
            }
            guard serviceBridge.commandCapabilities.supportsQueuedFollowUps else {
                commandNotice = .warning("This Work does not advertise queued follow-ups.")
                return .rejected("queued follow-ups unavailable")
            }
            let commandID = fromComposer ? UUID().uuidString.lowercased() : nil
            if let commandID {
                guard await beginDraftHandoff(
                    text: text, kind: .queue, commandID: commandID) else {
                    return .rejected("draft handoff unavailable")
                }
            }
            do {
                let receipt = try await serviceBridge.queue(text, commandID: commandID)
                let markerResolved = if let commandID {
                    await resolveDraftHandoff(commandID: commandID, accepted: true)
                } else {
                    true
                }
                if markerResolved {
                    setServiceSuccessNotice(
                        "Agent service accepted your message; updating this chat…",
                        kind: .queue, receipt: receipt)
                }
                syncServiceState()
                return .service(receipt)
            } catch {
                if let commandID, await commandWasDefinitivelyRejected(
                    commandID: commandID, error: error) {
                    _ = await resolveDraftHandoff(
                        commandID: commandID, accepted: false)
                }
                syncServiceState()
                commandNotice = .warning(serviceBridge.errorBanner ?? "The Work Host did not accept that follow-up.")
                return .rejected(serviceBridge.errorBanner ?? "Work service unavailable")
            }
        }
        guard let inHouse else {
            commandNotice = .warning("Claude Code does not support queued follow-ups.")
            return .rejected("queued follow-ups unavailable")
        }
        guard !requireActiveRun || inHouse.isStreaming else {
            commandNotice = .warning(
                "The run settled before this follow-up crossed. The draft was preserved.")
            return .rejected("queue state changed")
        }
        let receipt = await inHouse.queueFollowUp(text)
        queuedFollowUps = inHouse.pendingFollowUps
        return .session(receipt)
    }

    /// Request only a scope the attached Work explicitly advertises.
    func cancel(_ scope: SessionCancellationScope) async -> LiveRunCommandResult {
        guard commandCapabilities.supports(scope) else {
            commandNotice = .warning(
                "This engine does not support \(scope.rawValue) cancellation.")
            return .rejected("unsupported cancellation scope")
        }
        if let inHouse { return .session(await inHouse.cancel(scope: scope)) }
        if let claudeCode { return .session(await claudeCode.cancel(scope: scope)) }
        if let serviceBridge {
            do {
                let receipt = try await serviceBridge.cancel(scope: scope)
                setServiceSuccessNotice(
                    "Agent service accepted the stop request; updating this chat…",
                    kind: .cancel, receipt: receipt)
                syncServiceState()
                return .service(receipt)
            } catch {
                syncServiceState()
                commandNotice = .warning(serviceBridge.errorBanner ?? "The Work Host did not accept cancellation.")
                return .rejected(serviceBridge.errorBanner ?? "Work service unavailable")
            }
        }
        commandNotice = .warning("This run has no engine behind it.")
        return .rejected("no engine")
    }

    /// Compaction is automatic on Aviary's own engine — the agent summarises the middle of
    /// the conversation when it passes a share of the context window, and records a marker.
    /// There is nothing to trigger by hand, and a button that pretended otherwise would be
    /// worse than its absence.
    func compact() async {
        appendLocalNote(
            "This engine compacts on its own when the conversation approaches the model's "
                + "context window.")
    }

    /// Take a message from another run.
    ///
    /// Delivered as steering, which is what makes it land at a turn boundary rather than
    /// between a tool call and its result — the shape a provider rejects. Attributed in the
    /// text itself, because the receiving agent has no other way to know who is talking: it
    /// arrives in the conversation looking exactly like something a person typed.
    func receive(
        text: String, displaySender: String, sourceID: String? = nil
    ) async -> Bool {
        let attributed = "[message from \(displaySender)]\n\n" + text
        if let serviceBridge {
            guard serviceBridge.hasExactRunOwner, serviceBridge.projection.isCanonical else {
                return false
            }
            do {
                let receipt: WorkServiceCommandReceipt
                if serviceBridge.isStreaming {
                    guard serviceBridge.commandCapabilities.supportsSteering else { return false }
                    receipt = try await serviceBridge.steer(attributed)
                } else {
                    receipt = try await serviceBridge.send(attributed)
                }
                syncServiceState()
                return receipt.state == .accepted || receipt.state == .duplicate
            } catch {
                syncServiceState()
                return false
            }
        }
        if let inHouse {
            if inHouse.isStreaming {
                let admission = await inHouse.steer(
                    attributed, sourceID: sourceID ?? displaySender)
                queuedSteering = inHouse.pendingSteering
                return admission.wasHandedOff
            } else {
                return
                    (await inHouse.send(
                        attributed, sourceID: sourceID ?? displaySender)).wasHandedOff
            }
        }
        commandNotice = .warning("A message arrived but this run has no engine to take it.")
        return false
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
                appendLocalNote("Could not switch model: \(failure)")
                return
            }
            modelLabel = label
            return
        }
        if isClaudeCode {
            appendLocalNote(
                "Claude Code owns the loop for this run and takes its model at launch, so it "
                    + "cannot be changed mid-session. Start a new run to use \(label).")
            return
        }
        appendLocalNote("This run has no engine to switch.")
    }

    func setThinking(_ level: String) async {
        // Recorded on the run so the menu reflects the choice; the in-house agent reads its
        // effort from the model spec at each call, so this takes effect on the next turn.
        thinkingLevel = level
    }

    func rename(_ name: String) async {
        title = name
    }

    /// Publish a local diagnostic without calling the POSIX sync() symbol. These notes are
    /// ephemeral UI feedback; engine-backed durable events continue to arrive through the
    /// driver's session file.
    private func appendLocalNote(_ text: String) {
        var item = TranscriptItem(
            id: "local-note-\(UUID().uuidString)", kind: .note, timestamp: Date())
        item.text = text
        items.append(item)
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard !hasExited else { return }
        isEnding = true
        let stopTask = Task { @MainActor in await performStop() }
        self.stopTask = stopTask
        await stopTask.value
        self.stopTask = nil
        isEnding = false
    }

    /// Explicit End for a service-backed Work.  Calling `stop()` remains reserved for the
    /// process-owned Claude/in-house paths; application termination uses `disconnect()` below.
    func end() async {
        if let serviceBridge {
            guard !hasExited, serviceBridge.hasExactRunOwner,
                  serviceBridge.projection.isCanonical else {
                commandNotice = .warning("This Work's active Session owner is unavailable.")
                return
            }
            isEnding = true
            do {
                let receipt = try await serviceBridge.end()
                setServiceSuccessNotice(
                    "Agent service accepted the end request; updating this chat…",
                    kind: .end, receipt: receipt)
            } catch {
                commandNotice = .warning(serviceBridge.errorBanner ?? "The Work Host did not accept End.")
            }
            syncServiceState()
            return
        }
        await stop()
    }

    /// Detach this GUI from the service connection without sending an End command.
    func disconnect() async {
        guard serviceBridge != nil else { return }
        mirror?.cancel()
        mirror = nil
    }

    private func performStop() async {
        if let claudeCode {
            await claudeCode.stop()
            mirror?.cancel()
            hasExited = claudeCode.hasExited
            commandState = await claudeCode.commandState()
            errorBanner = claudeCode.errorBanner
            return
        }
        if let inHouse {
            await inHouse.stop()
            mirror?.cancel()
            hasExited = inHouse.hasExited
            commandState = await inHouse.commandState()
            errorBanner = inHouse.errorBanner
            return
        }
        if serviceBridge != nil {
            // Defensive only: callers should use `end()` for a service-backed run.  Never send
            // a lifecycle command from this generic cleanup path.
            await disconnect()
            return
        }
        hasExited = true
        commandState = .ended
    }
}
