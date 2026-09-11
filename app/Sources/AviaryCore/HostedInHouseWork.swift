import Foundation

private enum HostedInHouseWorkLimits {
    /// Timeline identities are caller supplied. Keep malformed remote/client input from turning
    /// command keys, diagnostics, or subscription state into an unbounded allocation.
    static let maxIdentifierBytes = 256
    static let maxSubscriptions = 64
}

/// The lifecycle owned by one in-house Work execution.
///
/// This is intentionally a per-run execution object, not the eventual Work registry.  A future
/// Work Host coordinator can retain this object (or a replacement) after every GUI has detached,
/// while keeping client attachments and their cursors in its own service journal.
public enum HostedInHouseWorkLifecycle: String, Codable, Hashable, Sendable {
    case prepared
    case preparing
    case idle
    case running
    case canceling
    case ending
    case ended
    case failed
}

/// Connection state is an observation of this actor's RuntimeHost client, not a claim that a
/// detached endpoint is alive. The adoption descriptor is retained separately as reconnect
/// material and always carries an explicit ``isLivenessProof`` false value.
public enum HostedInHouseWorkRuntimeState: String, Codable, Hashable, Sendable {
    case notStarted = "not_started"
    case connected
    case detached
    case unavailable
    case stopped
}

public enum HostedInHouseWorkJournalHealth: String, Codable, Hashable, Sendable {
    case healthy
    case failed
    case closed
}

/// Recovery evidence for a RuntimeHost handshake.
///
/// An endpoint and identity are sufficient for a replacement client to attempt a verified
/// adoption; neither is evidence that the process is still running. Keeping that distinction in
/// the value itself prevents a future service API from accidentally projecting "alive" from a
/// persisted socket path.
public struct HostedInHouseWorkAdoptionEvidence: Codable, Hashable, Sendable {
    public let descriptor: RuntimeHost.AdoptionDescriptor
    public let observedAt: Date
    public let sourceEvent: EventRef
    public let sourceCursor: JournalCursor
    public let coverage: RecoveryCoverage

    /// Deliberately always false. Liveness must be established by a fresh identity-checked
    /// handshake, never by reading this durable record. It is stored and encoded explicitly so a
    /// registry or remote client cannot mistake an omitted field for a positive liveness claim.
    public let isLivenessProof: Bool

    private enum CodingKeys: String, CodingKey {
        case descriptor, observedAt, sourceEvent, sourceCursor, coverage, isLivenessProof
    }

    public init(
        descriptor: RuntimeHost.AdoptionDescriptor,
        observedAt: Date,
        sourceEvent: EventRef,
        sourceCursor: JournalCursor,
        coverage: RecoveryCoverage
    ) {
        self.descriptor = descriptor
        self.observedAt = observedAt
        self.sourceEvent = sourceEvent
        self.sourceCursor = sourceCursor
        self.coverage = coverage
        self.isLivenessProof = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.descriptor = try container.decode(RuntimeHost.AdoptionDescriptor.self, forKey: .descriptor)
        self.observedAt = try container.decode(Date.self, forKey: .observedAt)
        self.sourceEvent = try container.decode(EventRef.self, forKey: .sourceEvent)
        self.sourceCursor = try container.decode(JournalCursor.self, forKey: .sourceCursor)
        self.coverage = try container.decode(RecoveryCoverage.self, forKey: .coverage)
        // Never trust a persisted assertion that a descriptor proves liveness; its value is
        // intentionally ignored while the explicit field is normalized to false.
        self.isLivenessProof = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(descriptor, forKey: .descriptor)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(sourceEvent, forKey: .sourceEvent)
        try container.encode(sourceCursor, forKey: .sourceCursor)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(false, forKey: .isLivenessProof)
    }
}

/// A bounded durable notification. The journal remains the source of truth: a client that
/// misses this stream can use the supplied cursors to request an exact catch-up page.
public struct HostedInHouseWorkDurableEvent: Codable, Hashable, Sendable {
    public let source: String
    public let commits: [TimelineJournalCommit]
    public let sessionCursor: JournalCursor?
    public let workCursor: JournalCursor?
    /// The caller-scoped ID from the Hosted command envelope. The canonical controller ID below
    /// is what is persisted in the command journal; keeping both makes stream notifications
    /// unambiguous without forcing GUI code to reverse an encoding.
    public let commandID: String?
    public let client: ClientRef?
    public let canonicalCommandID: String?

    public init(
        source: String,
        commits: [TimelineJournalCommit] = [],
        sessionCursor: JournalCursor?,
        workCursor: JournalCursor?,
        commandID: String? = nil,
        client: ClientRef? = nil,
        canonicalCommandID: String? = nil
    ) {
        self.source = source
        self.commits = Array(commits.prefix(64))
        self.sessionCursor = sessionCursor
        self.workCursor = workCursor
        self.commandID = commandID
        self.client = client
        self.canonicalCommandID = canonicalCommandID
    }
}

public struct HostedInHouseWorkLifecycleEvent: Codable, Hashable, Sendable {
    public let from: HostedInHouseWorkLifecycle
    public let to: HostedInHouseWorkLifecycle
    public let reason: String?

    public init(
        from: HostedInHouseWorkLifecycle,
        to: HostedInHouseWorkLifecycle,
        reason: String? = nil
    ) {
        self.from = from
        self.to = to
        self.reason = reason.map { String($0.prefix(500)) }
    }
}

public struct HostedInHouseWorkRuntimeObservation: Codable, Hashable, Sendable {
    public let state: HostedInHouseWorkRuntimeState
    public let descriptor: RuntimeHost.AdoptionDescriptor?
    public let identity: RuntimeHost.HostIdentity?
    public let capabilitiesSummary: String?
    public let transportConnected: Bool
    /// True only for a RuntimeHost process launched by this actor. An adopted host intentionally
    /// reports false even when its handshake succeeds.
    public let ownedProcessKnownAlive: Bool

    public init(
        state: HostedInHouseWorkRuntimeState,
        descriptor: RuntimeHost.AdoptionDescriptor?,
        identity: RuntimeHost.HostIdentity?,
        capabilitiesSummary: String?,
        transportConnected: Bool,
        ownedProcessKnownAlive: Bool
    ) {
        self.state = state
        self.descriptor = descriptor
        self.identity = identity
        self.capabilitiesSummary = capabilitiesSummary
        self.transportConnected = transportConnected
        self.ownedProcessKnownAlive = ownedProcessKnownAlive
    }
}

/// Ephemeral presentation delivery. Durable journal commits are never represented only by these
/// events; every durable notification carries cursors and is replayable through the host read
/// surface.
public enum HostedInHouseWorkEphemeralEvent: Sendable {
    case lifecycle(HostedInHouseWorkLifecycleEvent)
    case runtime(HostedInHouseWorkRuntimeObservation)
    case agent(Agent.Event)
}

public enum HostedInHouseWorkEvent: Sendable {
    case durable(HostedInHouseWorkDurableEvent)
    case ephemeral(HostedInHouseWorkEphemeralEvent)
}

/// The immutable command envelope accepted by a hosted Work.
///
/// Every command carries the Work, Session attachment, client actor, command identity, and the
/// exact Work cursor observed by the caller. A stale cursor is a normal durable conflict, not a
/// reason to silently retry against the latest state.
public struct HostedInHouseWorkCommand: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let session: SessionRef
    public let sessionAttachment: SessionAttachmentRef
    public let client: ClientRef
    public let commandID: String
    public let causalCursor: JournalCursor
    public let command: SessionCommand

    public init(
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        client: ClientRef,
        commandID: String,
        causalCursor: JournalCursor,
        command: SessionCommand
    ) {
        self.work = work
        self.session = session
        self.sessionAttachment = sessionAttachment
        self.client = client
        self.commandID = commandID
        self.causalCursor = causalCursor
        self.command = command
    }

    fileprivate func validate(
        identity: SessionWorkIdentity, workJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef
    ) throws {
        let identifiers = [
            identity.sessionID,
            identity.work.workHostID,
            identity.work.workID,
            identity.runID,
            sessionAttachment.attachmentID,
            client.clientID,
            commandID,
            causalCursor.eventID ?? "",
        ]
        guard identifiers.allSatisfy({
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && $0.utf8.count <= HostedInHouseWorkLimits.maxIdentifierBytes
        }) else {
            throw HostedInHouseWorkError.invalidCommand(
                "command identity fields must be nonempty and at most "
                    + "\(HostedInHouseWorkLimits.maxIdentifierBytes) UTF-8 bytes")
        }
        guard work == identity.work,
              session == SessionRef(identity.sessionID),
              self.sessionAttachment == sessionAttachment,
              causalCursor.eventID != nil
        else {
            throw HostedInHouseWorkError.invalidCommand("command identity does not match hosted Work")
        }
        guard causalCursor.journal == workJournal, causalCursor.eventID != nil,
              causalCursor.sequence >= 0 else {
            throw HostedInHouseWorkError.invalidCommand(
                "command requires a canonical Work cursor with event identity")
        }
    }
}

public struct HostedInHouseWorkReceipt: Codable, Hashable, Sendable {
    public let command: HostedInHouseWorkCommand
    public let receipt: SessionCommandReceipt
    public let sessionCursor: JournalCursor?
    public let workCursor: JournalCursor?
    public let lifecycle: HostedInHouseWorkLifecycle

    public init(
        command: HostedInHouseWorkCommand,
        receipt: SessionCommandReceipt,
        sessionCursor: JournalCursor?,
        workCursor: JournalCursor?,
        lifecycle: HostedInHouseWorkLifecycle
    ) {
        self.command = command
        self.receipt = receipt
        self.sessionCursor = sessionCursor
        self.workCursor = workCursor
        self.lifecycle = lifecycle
    }

    public var wasAdmitted: Bool { receipt.wasAdmitted }
    public var wasHandedOff: Bool { receipt.wasHandedOff }
}

public enum HostedInHouseWorkError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidCommand(String)
    case commandDispatchUnavailable(String)
    case runtimeUnavailable(String)
    case notPrepared
    case alreadyEnded

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return "Invalid hosted Work configuration: \(detail)"
        case .invalidCommand(let detail): return "Invalid hosted Work command: \(detail)"
        case .commandDispatchUnavailable(let detail): return "Hosted Work command was not dispatched: \(detail)"
        case .runtimeUnavailable(let detail): return "Hosted Work runtime unavailable: \(detail)"
        case .notPrepared: return "Hosted Work has not accepted its Start command."
        case .alreadyEnded: return "Hosted Work has already ended."
        }
    }
}

public struct HostedInHouseWorkSubscription: Sendable {
    public let id: String
    public let client: ClientRef
    public let events: AsyncStream<HostedInHouseWorkEvent>
    /// False means the bounded service refused this ephemeral observation stream. No durable
    /// Work state is changed by a rejected subscription.
    public let accepted: Bool
    public let rejectionReason: String?

    fileprivate init(
        id: String,
        client: ClientRef,
        events: AsyncStream<HostedInHouseWorkEvent>,
        accepted: Bool = true,
        rejectionReason: String? = nil
    ) {
        self.id = id
        self.client = client
        self.events = events
        self.accepted = accepted
        self.rejectionReason = rejectionReason
    }
}

/// Configuration supplied by the Work service after it has resolved a provider and selected a
/// runtime host. No UI or AgentCLI dependency is allowed here: the service can construct this
/// value from a local or remote-first policy and inject an already-resolved provider.
public struct HostedInHouseWorkConfiguration: Sendable {
    public let home: AgentHome
    public let cwd: String
    public let model: ModelSpec
    public let provider: any ChatProvider
    public let runtimeHost: RuntimeHost
    /// The service-created Work binding and the new execution generation. Start is only legal
    /// against this existing pair; opening a Hosted actor never allocates Work or Session IDs.
    public let workRunBinding: WorkRunBinding
    public let serviceActorID: String
    public let actorKind: String
    public let systemPrompt: String
    public let systemPromptAssembly: SystemPromptAssembly?
    public let reasoningEffort: String?
    public let maxDepth: Int
    public let maxIterations: Int
    public let childMaxIterations: Int
    public let memory: MemoryStore?
    public let recordPayloads: Bool
    public let goal: Goal?
    public let hookPaths: [String]
    /// The compatibility transcript operation is independent from effective model context.
    public let projectionMode: WorkLaunchProjectionMode
    /// Whether AgentRunner should reconstruct the exact native context before dispatch.
    public let modelContextMode: WorkLaunchContextMode
    /// Existing in-house callback capabilities. The Work Host owns these delegates; Hosted Work
    /// must carry them into the AgentRunner just as the GUI driver does.
    public let peerDelegate: Agent.PeerDelegate?
    public let selfDelegate: Agent.SelfDelegate?
    /// Host-private pilot opt-in. The default Hosted path remains unchanged; when present the
    /// factory admits this Work's Run through the coordinator and AgentRunner receives its child
    /// delegate from the captured pilot configuration.
    internal var agentChildPilot: WorkAgentChildPilot?
    /// Optional coordination hook run after the actor has reserved Start preparation but before
    /// durable command admission. It lets a service test or scheduler hold this narrow window
    /// without making the reservation invisible to a concurrent End command.
    public let startAdmissionGate: (@Sendable () async -> Void)?
    /// The service registry can persist this typed evidence alongside its Work record. The native
    /// Session journal is still written first by this actor, so a missing registry write cannot
    /// make an unrecorded descriptor look durable.
    public let adoptionEvidenceSink:
        (@Sendable (HostedInHouseWorkAdoptionEvidence) async throws -> Void)?

    public init(
        home: AgentHome,
        cwd: String,
        model: ModelSpec,
        provider: any ChatProvider,
        runtimeHost: RuntimeHost,
        workRunBinding: WorkRunBinding,
        serviceActorID: String,
        actorKind: String = "work-host",
        systemPrompt: String,
        systemPromptAssembly: SystemPromptAssembly? = nil,
        reasoningEffort: String? = nil,
        maxDepth: Int = 3,
        maxIterations: Int = 40,
        childMaxIterations: Int = 20,
        memory: MemoryStore? = nil,
        recordPayloads: Bool = false,
        goal: Goal? = nil,
        hookPaths: [String] = [],
        projectionMode: WorkLaunchProjectionMode = .fresh,
        modelContextMode: WorkLaunchContextMode = .launchFresh,
        peerDelegate: Agent.PeerDelegate? = nil,
        selfDelegate: Agent.SelfDelegate? = nil,
        startAdmissionGate: (@Sendable () async -> Void)? = nil,
        adoptionEvidenceSink:
            (@Sendable (HostedInHouseWorkAdoptionEvidence) async throws -> Void)? = nil
    ) {
        self.home = home
        self.cwd = cwd
        self.model = model
        self.provider = provider
        self.runtimeHost = runtimeHost
        self.workRunBinding = workRunBinding
        self.serviceActorID = serviceActorID
        self.actorKind = actorKind
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
        self.projectionMode = projectionMode
        self.modelContextMode = modelContextMode
        self.peerDelegate = peerDelegate
        self.selfDelegate = selfDelegate
        self.agentChildPilot = nil
        self.startAdmissionGate = startAdmissionGate
        self.adoptionEvidenceSink = adoptionEvidenceSink
    }
}

public struct HostedInHouseWorkSnapshot: Codable, Hashable, Sendable {
    public let identity: SessionWorkIdentity
    public let sessionAttachment: SessionAttachmentRef
    public let lifecycle: HostedInHouseWorkLifecycle
    public let runtimeState: HostedInHouseWorkRuntimeState
    public let journalHealth: HostedInHouseWorkJournalHealth
    public let runtimeIdentity: RuntimeHost.HostIdentity?
    /// The last verified descriptor, retained as recovery material. It is not a liveness claim.
    public let adoptionDescriptor: RuntimeHost.AdoptionDescriptor?
    public let adoptionEvidence: HostedInHouseWorkAdoptionEvidence?
    public let agentAvailable: Bool
    /// Ephemeral stream observers only; durable GUI attachments belong to the Work Host service
    /// attachment journal and are intentionally not projected here.
    public let ephemeralObserverCount: Int
    public let runtimeTransportConnected: Bool
    public let ownedRuntimeProcessKnownAlive: Bool
    public let runtimeCapabilitiesSummary: String?
    public let latestSessionCursor: JournalCursor?
    public let latestWorkCursor: JournalCursor?
    public let recoveryCoverage: RecoveryCoverage
    public let lastFailure: String?

    public init(
        identity: SessionWorkIdentity,
        sessionAttachment: SessionAttachmentRef,
        lifecycle: HostedInHouseWorkLifecycle,
        runtimeState: HostedInHouseWorkRuntimeState,
        journalHealth: HostedInHouseWorkJournalHealth,
        runtimeIdentity: RuntimeHost.HostIdentity?,
        adoptionDescriptor: RuntimeHost.AdoptionDescriptor?,
        adoptionEvidence: HostedInHouseWorkAdoptionEvidence?,
        agentAvailable: Bool,
        ephemeralObserverCount: Int,
        runtimeTransportConnected: Bool,
        ownedRuntimeProcessKnownAlive: Bool,
        runtimeCapabilitiesSummary: String?,
        latestSessionCursor: JournalCursor?,
        latestWorkCursor: JournalCursor?,
        recoveryCoverage: RecoveryCoverage,
        lastFailure: String?
    ) {
        self.identity = identity
        self.sessionAttachment = sessionAttachment
        self.lifecycle = lifecycle
        self.runtimeState = runtimeState
        self.journalHealth = journalHealth
        self.runtimeIdentity = runtimeIdentity
        self.adoptionDescriptor = adoptionDescriptor
        self.adoptionEvidence = adoptionEvidence
        self.agentAvailable = agentAvailable
        self.ephemeralObserverCount = max(0, ephemeralObserverCount)
        self.runtimeTransportConnected = runtimeTransportConnected
        self.ownedRuntimeProcessKnownAlive = ownedRuntimeProcessKnownAlive
        self.runtimeCapabilitiesSummary = runtimeCapabilitiesSummary
        self.latestSessionCursor = latestSessionCursor
        self.latestWorkCursor = latestWorkCursor
        self.recoveryCoverage = recoveryCoverage
        self.lastFailure = lastFailure
    }
}

/// A service-owned in-house run. The actor is deliberately independent of SwiftUI/MainActor:
/// its only presentation crossing is a bounded event stream, while canonical state remains in
/// the paired native journals. Retaining this actor after every GUI unsubscribes is safe; neither
/// a stream cancellation nor a RuntimeHost transport disconnect calls End or closes the Work.
public actor HostedInHouseWork: WorkServiceTerminalCommitter {
    public nonisolated let identity: SessionWorkIdentity
    public nonisolated let sessionAttachment: SessionAttachmentRef

    private let configuration: HostedInHouseWorkConfiguration
    private let bridge: NativeSessionCommandJournal
    private let controller: SessionCommandController
    private let runtimeHost: RuntimeHost

    private var runner: AgentRunner?
    private var agent: Agent?
    private var lifecycle: HostedInHouseWorkLifecycle = .prepared
    private var runtimeState: HostedInHouseWorkRuntimeState = .notStarted
    private var runtimeIdentity: RuntimeHost.HostIdentity?
    private var runtimeDescriptor: RuntimeHost.AdoptionDescriptor?
    private var runtimeCapabilitiesSummary: String?
    private var runtimeTransportConnected = false
    private var ownedRuntimeProcessKnownAlive = false
    private var intentionallyDetached = false
    private var adoptionEvidence: HostedInHouseWorkAdoptionEvidence?
    private var lastFailure: String?
    /// The command controller predates the multi-client Work seam and indexes by one String.
    /// Keep its durable identity collision-free by encoding client and caller command ID together;
    /// the Hosted command still exposes the caller's unqualified ID to that client.
    private var commandByID: [String: HostedInHouseWorkCommand] = [:]
    private var preparationInProgress = false
    private var preparationTask: Task<Void, Never>?
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var endRequested = false
    private var activeAgentCommandID: String?
    private var activeSendTask: Task<Void, Never>?
    /// Work completion/destruction is a separate transaction after this per-Run actor has ended
    /// and released its original writer locks. Attempting is not durable: a failed attempt rolls
    /// back unless canonical read-only reconciliation proves the exact transaction committed.
    private enum TerminalMutationState {
        case idle
        case attempting(WorkServiceTerminalCommitRequest)
        case committed(WorkServiceTerminalCommitRequest, WorkServiceTerminalCommitProof)
    }
    private var terminalMutationState: TerminalMutationState = .idle
    private var terminalMutationGateHeld = false
    private var terminalMutationGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscriptions: [String: AsyncStream<HostedInHouseWorkEvent>.Continuation] = [:]
    private var subscriptionClients: [String: ClientRef] = [:]

    init(
        configuration: HostedInHouseWorkConfiguration,
        bridge: NativeSessionCommandJournal,
        controller: SessionCommandController
    ) {
        self.configuration = configuration
        self.identity = SessionWorkIdentity(
            sessionID: configuration.workRunBinding.workBinding.session.sessionID,
            work: configuration.workRunBinding.workBinding.work,
            runID: configuration.workRunBinding.run.runID)
        self.sessionAttachment = bridge.nativeJournal.sessionAttachment
        self.bridge = bridge
        self.controller = controller
        self.runtimeHost = configuration.runtimeHost
    }

    /// Open native authority before the actor is returned. A fresh execution cannot silently
    /// reopen old bytes; a resume must have the native pair and the current Session presentation
    /// file required by the existing AgentRunner writer seam. This is the only launch path for
    /// this actor.
    /// Open through the Core composition factory. Hosted remains the public lifecycle surface;
    /// the factory is the only implementation path that admits its journals and runtime.
    public static func open(
        configuration: HostedInHouseWorkConfiguration
    ) async throws -> HostedInHouseWork {
        try await InHouseWorkFactory.open(
            configuration: InHouseWorkFactory.Configuration(hostedConfiguration: configuration))
    }

    /// Subscribe one GUI/service client to bounded notifications. Ending this stream has no
    /// durable effect and does not alter any other subscriber or the running Work.
    public func subscribe(client: ClientRef) -> HostedInHouseWorkSubscription {
        let id = "hosted-subscription-\(UUID().uuidString.lowercased())"
        let (events, continuation) = AsyncStream<HostedInHouseWorkEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        let trimmedClientID = client.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty,
              client.clientID.utf8.count <= HostedInHouseWorkLimits.maxIdentifierBytes else {
            continuation.finish()
            return HostedInHouseWorkSubscription(
                id: id,
                client: client,
                events: events,
                accepted: false,
                rejectionReason: "client identity must be nonempty and at most "
                    + "\(HostedInHouseWorkLimits.maxIdentifierBytes) UTF-8 bytes")
        }
        guard subscriptions.count < HostedInHouseWorkLimits.maxSubscriptions else {
            continuation.finish()
            return HostedInHouseWorkSubscription(
                id: id,
                client: client,
                events: events,
                accepted: false,
                rejectionReason: "ephemeral observer limit reached")
        }
        subscriptions[id] = continuation
        subscriptionClients[id] = client
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscription(id) }
        }
        return HostedInHouseWorkSubscription(id: id, client: client, events: events)
    }

    public func unsubscribe(_ subscriptionID: String) {
        removeSubscription(subscriptionID)
    }

    /// Drop only this actor's RuntimeHost transport. The host process is not stopped, no Run
    /// event is appended, and the saved descriptor remains available for a later verified
    /// reconnect. A Work Host service may use this at its own client/process boundary.
    public func disconnectRuntime() async {
        guard !runtimeShutdownIsAbsorbing else {
            forceStoppedRuntime()
            return
        }
        intentionallyDetached = true
        await runtimeHost.disconnect()
        guard !runtimeShutdownIsAbsorbing else {
            forceStoppedRuntime()
            return
        }
        runtimeTransportConnected = false
        ownedRuntimeProcessKnownAlive = false
        updateRuntimeState(.detached)
    }

    /// Reconnect using the RuntimeHost's retained identity fence. A successful handshake creates
    /// a new explicit adoption observation; the descriptor itself still is not liveness proof.
    @discardableResult
    public func reconnectRuntime() async throws -> HostedInHouseWorkRuntimeObservation {
        guard !runtimeShutdownIsAbsorbing else {
            forceStoppedRuntime()
            return runtimeObservation()
        }
        // This is now an adoption attempt, not an intentional detach. If the handshake fails,
        // subsequent snapshots must remain `.unavailable` rather than relabeling the failure as a
        // still-intentional disconnect.
        intentionallyDetached = false
        do {
            let capabilities = try await runtimeHost.reconnect()
            guard !runtimeShutdownIsAbsorbing else {
                forceStoppedRuntime()
                return runtimeObservation()
            }
            let descriptor = await runtimeHost.adoptionDescriptor
            guard !runtimeShutdownIsAbsorbing else {
                forceStoppedRuntime()
                return runtimeObservation()
            }
            runtimeDescriptor = descriptor ?? runtimeDescriptor
            let hostIdentity = await runtimeHost.hostIdentity
            guard !runtimeShutdownIsAbsorbing else {
                forceStoppedRuntime()
                return runtimeObservation()
            }
            runtimeIdentity = capabilities.identity ?? hostIdentity
            runtimeCapabilitiesSummary = capabilities.summary
            runtimeTransportConnected = await runtimeHost.isConnected
            guard !runtimeShutdownIsAbsorbing else {
                forceStoppedRuntime()
                return runtimeObservation()
            }
            ownedRuntimeProcessKnownAlive = await runtimeHost.hostProcessIsRunning
            guard !runtimeShutdownIsAbsorbing else {
                forceStoppedRuntime()
                return runtimeObservation()
            }
            updateRuntimeState(.connected)
            try await persistAdoptionEvidence()
            guard !runtimeShutdownIsAbsorbing else {
                forceStoppedRuntime()
                return runtimeObservation()
            }
            return runtimeObservation()
        } catch {
            guard !runtimeShutdownIsAbsorbing else {
                forceStoppedRuntime()
                return runtimeObservation()
            }
            updateRuntimeState(.unavailable)
            throw error
        }
    }

    /// Submit one exact command. Accepted command IDs are idempotent only when the entire command
    /// envelope matches; reusing a command ID for another client/cursor/operation is rejected.
    public func submit(
        _ command: HostedInHouseWorkCommand
    ) async throws -> HostedInHouseWorkReceipt {
        try command.validate(
            identity: identity,
            workJournal: bridge.nativeJournal.workJournal,
            sessionAttachment: sessionAttachment)
        let key = controllerCommandID(for: command)
        if let previous = commandByID[key] {
            guard previous == command else {
                throw HostedInHouseWorkError.invalidCommand(
                    "client-qualified command ID was already used with a different envelope")
            }
            // A command may have been accepted while its writer was still committing. Ask the
            // controller to reconcile the exact identity before returning the hosted projection;
            // returning the controller's provisional admission alone would make a retry look
            // settled even though its durable receipt is still unknown.
            _ = await controller.admitAndCommitReceipt(
                command.command,
                actorID: command.client.clientID,
                commandID: key,
                causalCursor: command.causalCursor)
            return await receipt(for: command)
        }
        commandByID[key] = command

        do {
            switch command.command {
            case .start(let prompt):
                return try await executeStart(prompt: prompt, command: command)
            case .send(let prompt):
                return try await executeSend(prompt: prompt, command: command)
            case .steer(let text):
                return try await executeSteer(text: text, command: command)
            case .queueFollowUp(let text):
                return try await executeQueue(text: text, command: command)
            case .cancel(let scope):
                return try await executeCancel(scope: scope, command: command)
            case .endRun:
                return try await executeEnd(command: command)
            }
        } catch {
            // A pre-admission validation failure (for example, Send before Start) must not
            // poison this caller's local retry key. Once the controller has a receipt, however,
            // retain the key so an accepted-but-ambiguous command remains strictly idempotent.
            if await controller.receipt(for: key) == nil {
                commandByID.removeValue(forKey: key)
            }
            throw error
        }
    }

    public func snapshot() async -> HostedInHouseWorkSnapshot {
        await refreshRuntimeObservation()
        let status = await bridge.nativeJournal.status
        let health: HostedInHouseWorkJournalHealth
        switch status.health {
        case .healthy: health = .healthy
        case .failed: health = .failed
        case .closed: health = .closed
        }
        let workCursor = status.durablePrefix.workCursor
        return HostedInHouseWorkSnapshot(
            identity: identity,
            sessionAttachment: sessionAttachment,
            lifecycle: lifecycle,
            runtimeState: runtimeState,
            journalHealth: health,
            runtimeIdentity: runtimeIdentity,
            adoptionDescriptor: runtimeDescriptor,
            adoptionEvidence: adoptionEvidence,
            agentAvailable: agent != nil,
            ephemeralObserverCount: subscriptions.count,
            runtimeTransportConnected: runtimeTransportConnected,
            ownedRuntimeProcessKnownAlive: ownedRuntimeProcessKnownAlive,
            runtimeCapabilitiesSummary: runtimeCapabilitiesSummary,
            latestSessionCursor: status.durablePrefix.sessionCursor,
            latestWorkCursor: workCursor,
            recoveryCoverage: recoveryCoverage(),
            lastFailure: lastFailure)
    }

    /// Return one live canonical Work/Session observation from the native bundle. The bundle's
    /// writer actors hold their advisory locks for the full observation, so callers never fall
    /// back to an unlocked source read while this Hosted actor owns the active Run.
    public func canonicalObservation(
        limits: BoundedTimelineReducerProjectionLimits = .default,
        maximumResidentRecords: Int = 1_000_000
    ) async throws -> RunJournalBundleCanonicalObservation {
        try await bridge.nativeJournal.canonicalObservation(
            limits: limits, maximumResidentRecords: maximumResidentRecords)
    }

    public var observerCount: Int { subscriptions.count }

    // MARK: Work terminalization

    /// Commit an explicit Work completion or destruction after End has quiesced the run. End
    /// closes the per-Run writers so this actor never monopolizes the Work merely because a GUI
    /// remains attached; this method reacquires both canonical journals for one bounded terminal
    /// transaction and closes them again before returning.
    public func commit(
        _ request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof {
        await acquireTerminalMutationGate()
        defer { releaseTerminalMutationGate() }
        try validateTerminalMutationState()
        try validateTerminalMutationIdentity(request)
        switch terminalMutationState {
        case .committed(let previous, let proof):
            guard previous == request else { throw terminalMutationConflict() }
            return proof
        case .attempting(let previous):
            guard previous == request else { throw terminalMutationConflict() }
            if let proof = try readTerminalProof(for: request) {
                terminalMutationState = .committed(request, proof)
                return proof
            }
            terminalMutationState = .idle
        case .idle:
            break
        }

        terminalMutationState = .attempting(request)
        do {
            let proof = try await withTerminalMutationBundle { committer in
                try await committer.commit(request)
            }
            terminalMutationState = .committed(request, proof)
            return proof
        } catch {
            // A writer close can fail after both terminal events are durable. Resolve that
            // ambiguity through the canonical read-only path before deciding this attempt failed.
            if let proof = try? readTerminalProof(for: request) {
                terminalMutationState = .committed(request, proof)
                return proof
            }
            terminalMutationState = .idle
            throw error
        }
    }

    /// Reconcile a possibly committed terminal request from canonical storage. This deliberately
    /// works after the short-lived terminal writer has closed; a lost service response cannot
    /// force another terminal append or turn a durable success into an unknown result.
    public func committedProof(
        for request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof? {
        await acquireTerminalMutationGate()
        defer { releaseTerminalMutationGate() }
        try validateTerminalMutationIdentity(request)
        switch terminalMutationState {
        case .committed(let previous, let proof):
            guard previous == request else { throw terminalMutationConflict() }
            return proof
        case .attempting(let previous):
            guard previous == request else { throw terminalMutationConflict() }
        case .idle:
            break
        }
        guard let proof = try readTerminalProof(for: request) else { return nil }
        terminalMutationState = .committed(request, proof)
        return proof
    }

    private func readTerminalProof(
        for request: WorkServiceTerminalCommitRequest
    ) throws -> WorkServiceTerminalCommitProof? {
        guard let record = try RunJournalBundle.readTerminalCommit(
            home: configuration.home,
            identity: identity,
            sessionAttachment: sessionAttachment,
            command: request.command,
            detail: request.detail,
            actorID: configuration.serviceActorID + ":terminal-reader") else { return nil }
        return try WorkServiceTerminalCommitProof.makeProof(record: record, request: request)
    }

    /// Verify a terminal proof against the exact canonical bytes owned by this Hosted Work. A
    /// proof is transport data and may be forged or stale even when its DTO fields look coherent;
    /// registry release therefore calls this read-only seam before converting the live slot to
    /// historical state.
    public func verifyCanonicalTerminalProof(
        _ proof: WorkServiceTerminalCommitProof
    ) async -> Bool {
        guard proof.work == identity.work,
              proof.session == SessionRef(identity.sessionID),
              proof.sessionAttachment == sessionAttachment,
              let client = proof.command.client else { return false }
        let detail = proof.terminalEvent.payload["detail"]?.stringValue
        let request = WorkServiceTerminalCommitRequest(
            operation: proof.operation,
            work: proof.work,
            journal: proof.journal,
            client: client,
            session: proof.session,
            sessionJournal: proof.sessionJournal,
            sessionAttachment: proof.sessionAttachment,
            causalWorkCursor: proof.causalWorkCursor,
            detail: detail,
            command: proof.command)
        guard let canonical = try? await committedProof(for: request) else { return false }
        return canonical == proof
    }

    // MARK: Command execution

    private func admitAndDispatch(
        _ command: HostedInHouseWorkCommand
    ) async throws -> (admitted: AdmittedSessionCommand, receipt: SessionCommandReceipt)? {
        let controllerID = controllerCommandID(for: command)
        let receipt = await controller.admitAndCommitReceipt(
            command.command,
            actorID: command.client.clientID,
            commandID: controllerID,
            causalCursor: command.causalCursor)
        await emitDurable(
            source: "command.admission", commandID: command.commandID, client: command.client)
        guard case .accepted = receipt.admission else { return nil }
        guard let dispatched = await controller.awaitDispatch(commandID: controllerID) else {
            throw HostedInHouseWorkError.commandDispatchUnavailable(
                "\(command.commandID) has no dispatch permit")
        }
        guard await controller.acknowledgeDispatched(commandID: controllerID) else {
            throw HostedInHouseWorkError.commandDispatchUnavailable(
                "\(command.commandID) dispatch acknowledgement was refused")
        }
        return (dispatched, receipt)
    }

    private func executeStart(
        prompt: String,
        command: HostedInHouseWorkCommand
    ) async throws -> HostedInHouseWorkReceipt {
        guard lifecycle == .prepared else {
            throw HostedInHouseWorkError.invalidCommand(
                "Start is legal only while hosted Work is prepared")
        }
        let controllerID = controllerCommandID(for: command)
        // Reserve the preparation barrier before the first suspension. End must observe this
        // reservation and wait for it, even if admission is held by a client/service boundary.
        transition(to: .preparing, reason: "Start admission in progress")
        preparationInProgress = true
        do {
            if let startAdmissionGate = configuration.startAdmissionGate {
                await startAdmissionGate()
            }
            guard (try await admitAndDispatch(command)) != nil else {
                releaseStartReservation(reason: "Start was rejected by Work")
                return await receipt(for: command)
            }
            guard !endRequested, lifecycle == .preparing else {
                if lifecycle != .ended {
                    _ = await controller.recordNotDelivered(
                        commandID: controllerID,
                        reason: "Start was overtaken by an explicit End command")
                    await emitDurable(
                        source: "command.not_delivered", commandID: command.commandID,
                        client: command.client)
                }
                releaseStartReservation(reason: "Start was overtaken by an explicit End command")
                return await receipt(for: command)
            }
            preparationTask = Task { [weak self] in
                guard let self else { return }
                await self.prepareStart(prompt: prompt, command: command, controllerID: controllerID)
            }
            return await receipt(for: command)
        } catch {
            releaseStartReservation(reason: "Start admission failed")
            throw error
        }
    }

    /// Complete Start outside the command request. Admission and dispatch are the service-call
    /// boundary; RuntimeHost startup and AgentRunner preparation can be slow and must not block a
    /// single ordered client connection from delivering End or cancellation.
    private func prepareStart(
        prompt: String,
        command: HostedInHouseWorkCommand,
        controllerID: String
    ) async {
        defer {
            completePreparationBarrier()
        }

        // End can be admitted while the service is still dispatching Start. The reservation
        // remains visible until this task exits; importantly, this guard prevents a late task from
        // starting the runtime after End has already won the lifecycle race.
        guard !endRequested, lifecycle == .preparing else {
            if lifecycle != .ended {
                _ = await controller.recordNotDelivered(
                    commandID: controllerID,
                    reason: "Start was overtaken by an explicit End command")
                await emitDurable(
                    source: "command.not_delivered", commandID: command.commandID,
                    client: command.client)
            }
            return
        }

        do {
            let capabilities: RuntimeHost.Capabilities
            do {
                capabilities = try await runtimeHost.start()
            } catch {
                throw HostedInHouseWorkError.runtimeUnavailable(Self.bounded(error.localizedDescription))
            }
            intentionallyDetached = false
            runtimeDescriptor = await runtimeHost.adoptionDescriptor
            guard runtimeDescriptor != nil else {
                throw HostedInHouseWorkError.runtimeUnavailable(
                    "RuntimeHost did not expose a verified adoption descriptor")
            }
            let hostIdentity = await runtimeHost.hostIdentity
            runtimeIdentity = capabilities.identity ?? hostIdentity
            runtimeCapabilitiesSummary = capabilities.summary
            runtimeTransportConnected = await runtimeHost.isConnected
            ownedRuntimeProcessKnownAlive = await runtimeHost.hostProcessIsRunning
            updateRuntimeState(.connected)
            try await persistAdoptionEvidence()

            guard !endRequested else {
                throw HostedInHouseWorkError.runtimeUnavailable(
                    "Start was overtaken by an explicit End command")
            }

            let runner = AgentRunner(
                provider: configuration.provider,
                host: runtimeHost,
                settings: .init(
                    home: configuration.home,
                    cwd: configuration.cwd,
                    model: configuration.model,
                    systemPrompt: configuration.systemPrompt,
                    systemPromptAssembly: configuration.systemPromptAssembly,
                    maxDepth: configuration.maxDepth,
                    maxIterations: configuration.maxIterations,
                    childMaxIterations: configuration.childMaxIterations,
                    memory: configuration.memory,
                    recordPayloads: configuration.recordPayloads,
                    goal: configuration.goal,
                    hookPaths: configuration.hookPaths,
                    // The legacy AgentRunner switch is an adapter detail. The public launch
                    // contract carries the truthful typed context mode, while the projection
                    // mode remains independent (a historical projection may still launch fresh).
                    resume: configuration.modelContextMode == .exactColdResume
                        ? identity.sessionID : nil,
                    peerDelegate: configuration.peerDelegate,
                    selfDelegate: configuration.selfDelegate,
                    childDelegate: configuration.agentChildPilot?.makeDelegate(
                        configuration: configuration),
                    identity: identity,
                    reasoningEffort: configuration.reasoningEffort,
                    writer: bridge.legacyProjection,
                    nativeJournal: bridge.nativeJournal,
                    nativeResumeSeed: bridge.resumeSeed,
                    repositoryReviewer: ObservedRepositoryReviewer()))
            self.runner = runner
            await runner.observe { [weak self] event in
                guard let self else { return }
                Task { await self.receiveAgentEvent(event) }
            }
            let (_, preparedAgent) = try await runner.prepare()
            guard !endRequested else {
                throw HostedInHouseWorkError.runtimeUnavailable(
                    "Start was overtaken by an explicit End command")
            }
            self.agent = preparedAgent
            guard await controller.acknowledgePreparation(commandID: controllerID) else {
                throw HostedInHouseWorkError.commandDispatchUnavailable(
                    "Start preparation acknowledgement was refused")
            }

            guard !endRequested else {
                throw HostedInHouseWorkError.runtimeUnavailable(
                    "Start was overtaken by an explicit End command")
            }
            try await persistRecoveryCoverage(
                effectiveContext: .preserved,
                backgroundWork: .preserved,
                caveat: "AgentRunner is live in this Work Host process.")
            guard !endRequested else {
                throw HostedInHouseWorkError.runtimeUnavailable(
                    "Start was overtaken by an explicit End command")
            }
            if prompt.isEmpty {
                guard await controller.recordDelivered(commandID: controllerID) else {
                    throw HostedInHouseWorkError.commandDispatchUnavailable(
                        "empty Start delivery could not be recorded")
                }
                await emitDurable(
                    source: "command.delivered", commandID: command.commandID, client: command.client)
                _ = await controller.acknowledgeTurnFinished(commandID: controllerID)
                transition(to: .idle, reason: "Start prepared an idle run")
            } else {
                transition(to: .running, reason: "Start crossed into Agent")
                activeAgentCommandID = controllerID
                launchAgentSend(prompt: prompt, command: command, agent: preparedAgent)
            }
        } catch {
            await failStart(command: command, error: error)
        }
    }

    private func executeSend(
        prompt: String,
        command: HostedInHouseWorkCommand
    ) async throws -> HostedInHouseWorkReceipt {
        guard lifecycle != .ended else { throw HostedInHouseWorkError.alreadyEnded }
        guard let agent else { throw HostedInHouseWorkError.notPrepared }
        guard (try await admitAndDispatch(command)) != nil else {
            return await receipt(for: command)
        }
        guard !endRequested, lifecycle != .ending, lifecycle != .ended else {
            _ = await controller.recordNotDelivered(
                commandID: controllerCommandID(for: command),
                reason: "the run ended before the prompt reached the agent")
            await emitDurable(
                source: "command.not_delivered", commandID: command.commandID, client: command.client)
            return await receipt(for: command)
        }
        transition(to: .running, reason: "Send was accepted")
        activeAgentCommandID = controllerCommandID(for: command)
        launchAgentSend(prompt: prompt, command: command, agent: agent)
        return await receipt(for: command)
    }

    private func executeSteer(
        text: String,
        command: HostedInHouseWorkCommand
    ) async throws -> HostedInHouseWorkReceipt {
        guard let agent else { throw HostedInHouseWorkError.notPrepared }
        guard (try await admitAndDispatch(command)) != nil else {
            return await receipt(for: command)
        }
        let accepted = await agent.steer(text) { [weak self] delivery in
            guard let self else { return }
            await self.recordDelivery(delivery, for: command)
        }
        if !accepted {
            _ = await controller.recordNotDelivered(
                commandID: controllerCommandID(for: command), reason: "Agent did not accept steering input")
            await emitDurable(
                source: "command.not_delivered", commandID: command.commandID, client: command.client)
        }
        return await receipt(for: command)
    }

    private func executeQueue(
        text: String,
        command: HostedInHouseWorkCommand
    ) async throws -> HostedInHouseWorkReceipt {
        guard let agent else { throw HostedInHouseWorkError.notPrepared }
        guard (try await admitAndDispatch(command)) != nil else {
            return await receipt(for: command)
        }
        let accepted = await agent.queueFollowUp(text) { [weak self] delivery in
            guard let self else { return }
            await self.recordDelivery(delivery, for: command)
        }
        if !accepted {
            _ = await controller.recordNotDelivered(
                commandID: controllerCommandID(for: command), reason: "Agent did not accept queued follow-up")
            await emitDurable(
                source: "command.not_delivered", commandID: command.commandID, client: command.client)
        }
        return await receipt(for: command)
    }

    private func executeCancel(
        scope: SessionCancellationScope,
        command: HostedInHouseWorkCommand
    ) async throws -> HostedInHouseWorkReceipt {
        guard let agent else { throw HostedInHouseWorkError.notPrepared }
        guard (try await admitAndDispatch(command)) != nil else {
            return await receipt(for: command)
        }
        transition(to: .canceling, reason: "Cancellation was accepted")
        guard await agent.requestCancellation(scope) else {
            _ = await controller.recordNotDelivered(
                commandID: controllerCommandID(for: command), reason: "Agent rejected cancellation scope")
            transition(to: .failed, reason: "Cancellation scope was not supported")
            return await receipt(for: command)
        }
        guard await controller.recordDelivered(commandID: controllerCommandID(for: command)) else {
            transition(to: .failed, reason: "Cancellation delivery could not be recorded")
            return await receipt(for: command)
        }
        await emitDurable(
            source: "command.delivered", commandID: command.commandID, client: command.client)
        launchCancellationCompletion(command: command, agent: agent)
        return await receipt(for: command)
    }

    private func executeEnd(
        command: HostedInHouseWorkCommand
    ) async throws -> HostedInHouseWorkReceipt {
        guard (try await admitAndDispatch(command)) != nil else {
            return await receipt(for: command)
        }
        endRequested = true
        transition(to: .ending, reason: "Explicit End was accepted")
        await waitForPreparationIfNeeded()

        if let agent {
            await agent.cancel()
            await agent.waitUntilQuiescent()
        }
        if let runner { await runner.stopMCPServers() }

        await runtimeHost.closeCallbackAdmission()
        do {
            try await runtimeHost.waitUntilCallbacksQuiescent()
        } catch {
            appendFailure(
                "Runtime callback drain failed: " + Self.bounded(error.localizedDescription))
        }
        await runtimeHost.stop()
        runtimeTransportConnected = false
        ownedRuntimeProcessKnownAlive = false
        runtimeState = .stopped
        emit(.ephemeral(.runtime(runtimeObservation())))
        // End owns teardown even when no new model turn can be admitted. Do not leave an agent or
        // runner reachable through a stale actor reference after the durable run is terminal.
        self.agent = nil
        self.runner = nil
        self.activeAgentCommandID = nil
        self.activeSendTask = nil

        guard await controller.recordDelivered(commandID: controllerCommandID(for: command)) else {
            lastFailure = "End delivery could not be recorded"
            transition(to: .failed, reason: lastFailure)
            return await receipt(for: command)
        }
        await emitDurable(
            source: "command.delivered", commandID: command.commandID, client: command.client)

        let outcome: RunTerminalOutcome = lastFailure == nil ? .completed : .failed
        var canonicalRunFinished = false
        do {
            let commits = try await bridge.nativeJournal.finishRun(
                outcome: outcome, detail: lastFailure)
            canonicalRunFinished = true
            await emitDurable(
                source: "run.finished", commits: commits,
                commandID: command.commandID, client: command.client)
            _ = await controller.acknowledgeEnd(commandID: controllerCommandID(for: command))
            // `run.finished` is the canonical End fact. Disposable projection teardown below may
            // report a failure, but it cannot rewrite an already durable native outcome.
            transition(to: .ended, reason: "Canonical run.finished committed")
        } catch {
            lastFailure = Self.bounded(error.localizedDescription)
            transition(to: .failed, reason: lastFailure)
        }

        // Close canonical and presentation writers independently. A native close failure remains
        // visible in journal health/lastFailure, while a projection close failure never demotes a
        // canonical End or prevents read-only terminal proof reconciliation.
        if canonicalRunFinished {
            do {
                try await bridge.nativeJournal.closeChecked()
            } catch {
                appendFailure(
                    "native journal close failed: " + Self.bounded(error.localizedDescription))
            }
            do {
                try await bridge.legacyProjection.closeChecked()
            } catch {
                appendFailure(
                    "Session projection close failed: " + Self.bounded(error.localizedDescription))
            }
        }
        if lifecycle == .ended {
            finishSubscriptions()
        }
        return await receipt(for: command)
    }

    // MARK: Agent/runtime crossings

    private func recordDelivery(
        _ delivery: SessionCommandDelivery,
        for command: HostedInHouseWorkCommand
    ) async {
        let commandID = controllerCommandID(for: command)
        switch delivery {
        case .delivered:
            _ = await controller.recordDelivered(commandID: commandID)
            await emitDurable(
                source: "command.delivered", commandID: command.commandID, client: command.client)
        case .notDelivered(let reason):
            _ = await controller.recordNotDelivered(commandID: commandID, reason: reason)
            await emitDurable(
                source: "command.not_delivered", commandID: command.commandID, client: command.client)
        case .indeterminate(let reason):
            lastFailure = Self.bounded(reason)
            guard lifecycle != .ended else { return }
            transition(to: .failed, reason: lastFailure)
            await emitDurable(
                source: "command.delivery_indeterminate", commandID: command.commandID,
                client: command.client)
        case .notAttempted, .queued:
            break
        }
    }

    private func settle(_ outcome: Agent.SendOutcome, command: HostedInHouseWorkCommand) async {
        let commandID = controllerCommandID(for: command)
        switch outcome {
        case .completed:
            _ = await controller.acknowledgeTurnFinished(commandID: commandID)
            guard lifecycle != .ending, lifecycle != .ended, lifecycle != .failed else { return }
            transition(to: .idle, reason: "Agent turn finished")
        case .cancelled:
            guard lifecycle != .ending, lifecycle != .ended, lifecycle != .failed else { return }
            if lifecycle != .canceling {
                transition(to: .idle, reason: "Agent turn canceled")
            }
        case .failed(let detail):
            guard lifecycle != .ended else { return }
            lastFailure = Self.bounded(detail)
            _ = await controller.markFailed(commandID: commandID)
            if lifecycle != .ending, lifecycle != .failed {
                transition(to: .failed, reason: lastFailure)
            }
        }
    }

    private func receiveAgentEvent(_ event: Agent.Event) async {
        guard lifecycle != .ended else { return }
        emit(.ephemeral(.agent(event)))
        if case .failed(let detail) = event {
            lastFailure = Self.bounded(detail)
        }
        // Agent events may include native turn/action commits that the runner owns. Emit a cursor
        // observation so clients can request the exact durable tail without treating this stream
        // as the journal itself.
        switch event {
        case .inputCommitted, .turnFinished, .compacted, .modelChanged, .childFinished,
             .finished, .failed:
            await emitDurable(source: "agent.cursor_observed")
        default:
            break
        }
    }

    private func failStart(command: HostedInHouseWorkCommand, error: Error) async {
        let commandID = controllerCommandID(for: command)
        let detail = Self.bounded(error.localizedDescription)
        lastFailure = detail
        _ = await controller.recordNotDelivered(
            commandID: commandID, reason: "Start setup failed: \(detail)")
        if let runner { await runner.stopMCPServers() }
        await runtimeHost.stop()
        runtimeTransportConnected = false
        ownedRuntimeProcessKnownAlive = false
        runtimeState = .stopped
        emit(.ephemeral(.runtime(runtimeObservation())))
        self.agent = nil
        self.runner = nil
        self.activeAgentCommandID = nil
        self.activeSendTask = nil
        if lifecycle != .ending, lifecycle != .ended { transition(to: .failed, reason: detail) }
        await emitDurable(
            source: "start.failed", commandID: command.commandID, client: command.client)
    }

    private func waitForPreparationIfNeeded() async {
        guard preparationInProgress else { return }
        await withCheckedContinuation { continuation in
            preparationWaiters.append(continuation)
        }
    }

    private func completePreparationBarrier() {
        preparationInProgress = false
        preparationTask = nil
        let waiters = preparationWaiters
        preparationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func releaseStartReservation(reason: String) {
        completePreparationBarrier()
        // A stale/rejected Start can return the actor to its prepared state. Once End has been
        // accepted, however, the terminal path owns the lifecycle and the reservation must not
        // resurrect it.
        guard !endRequested, lifecycle == .preparing else { return }
        transition(to: .prepared, reason: reason)
    }

    private func launchAgentSend(
        prompt: String,
        command: HostedInHouseWorkCommand,
        agent: Agent
    ) {
        let task = Task { [weak self] in
            let outcome = await agent.send(prompt) { [weak self] delivery in
                guard let self else { return }
                await self.recordDelivery(delivery, for: command)
            }
            guard let self else { return }
            await self.finishAgentSend(outcome, command: command)
        }
        activeSendTask = task
    }

    private func finishAgentSend(
        _ outcome: Agent.SendOutcome,
        command: HostedInHouseWorkCommand
    ) async {
        await settle(outcome, command: command)
        activeAgentCommandID = nil
        activeSendTask = nil
    }

    private func launchCancellationCompletion(
        command: HostedInHouseWorkCommand,
        agent: Agent
    ) {
        Task { [weak self] in
            await agent.waitUntilQuiescent()
            guard let self else { return }
            await self.finishCancellation(command: command)
        }
    }

    private func finishCancellation(command: HostedInHouseWorkCommand) async {
        _ = await controller.acknowledgeCancellation(
            commandID: controllerCommandID(for: command))
        guard lifecycle != .ending, lifecycle != .ended else { return }
        if lifecycle == .canceling {
            transition(to: .idle, reason: "Agent cancellation completed")
        }
    }

    // MARK: Durable recovery/evidence

    private func persistAdoptionEvidence() async throws {
        guard let descriptor = runtimeDescriptor else {
            throw HostedInHouseWorkError.runtimeUnavailable(
                "cannot record adoption evidence without a verified descriptor")
        }
        let coverage = RecoveryCoverage(
            operation: .reattachLiveHost,
            planes: [
                .timeline: .preserved,
                .effectiveContext: .unknown,
                .runtimeNamespace: .preserved,
                .backgroundWork: .unknown,
                .memoriesArtifactsRepository: .referenced,
                .externalEffects: .unknown,
            ],
            evidenceCursor: await bridge.nativeJournal.latestWorkCursor,
            caveats: [Self.adoptionCaveat(descriptor)])
        let commit = try await bridge.nativeJournal.recordRecoveryCoverage(coverage)
        let evidence = HostedInHouseWorkAdoptionEvidence(
            descriptor: descriptor,
            observedAt: Date(),
            sourceEvent: commit.eventRef,
            sourceCursor: commit.cursor,
            coverage: coverage)
        adoptionEvidence = evidence
        try await configuration.adoptionEvidenceSink?(evidence)
        await emitDurable(source: "runtime.adoption_observed", commits: [commit])
    }

    private func persistRecoveryCoverage(
        effectiveContext: RecoveryCoverageStatus,
        backgroundWork: RecoveryCoverageStatus,
        caveat: String
    ) async throws {
        let coverage = RecoveryCoverage(
            operation: .reattachLiveHost,
            planes: [
                .timeline: .preserved,
                .effectiveContext: effectiveContext,
                .runtimeNamespace: runtimeState == .connected ? .preserved : .unknown,
                .backgroundWork: backgroundWork,
                .memoriesArtifactsRepository: .referenced,
                .externalEffects: .unknown,
            ],
            evidenceCursor: await bridge.nativeJournal.latestWorkCursor,
            caveats: [caveat, "Runtime adoption material is not proof of liveness."])
        let commit = try await bridge.nativeJournal.recordRecoveryCoverage(coverage)
        await emitDurable(source: "recovery.coverage", commits: [commit])
    }

    private func recoveryCoverage() -> RecoveryCoverage {
        let runtime: RecoveryCoverageStatus
        switch runtimeState {
        case .connected: runtime = .preserved
        case .detached: runtime = .referenced
        case .unavailable: runtime = .unknown
        case .notStarted: runtime = .notApplicable
        case .stopped: runtime = .lost
        }
        let effective: RecoveryCoverageStatus
        switch lifecycle {
        case .prepared: effective = .notApplicable
        case .preparing: effective = .unknown
        case .ended: effective = .lost
        default: effective = agent == nil ? .unknown : .preserved
        }
        let background: RecoveryCoverageStatus
        switch lifecycle {
        case .prepared: background = .notApplicable
        case .ended: background = .lost
        default:
            // A disconnected or unexpectedly unavailable transport leaves an adoption address,
            // but it does not prove that Python Futures/Handles or the Swift runner are making
            // progress. Only the currently connected, in-process observation earns preserved.
            background = runner == nil ? .unknown : (runtime == .preserved ? .preserved : .unknown)
        }
        let timeline: RecoveryCoverageStatus = {
            switch lifecycle {
            case .ended: return .preserved
            default: return .preserved
            }
        }()
        return RecoveryCoverage(
            operation: .reattachLiveHost,
            planes: [
                .timeline: timeline,
                .effectiveContext: effective,
                .runtimeNamespace: runtime,
                .backgroundWork: background,
                .memoriesArtifactsRepository: .referenced,
                .externalEffects: .unknown,
            ],
            evidence: adoptionEvidence?.sourceEvent,
            evidenceCursor: adoptionEvidence?.sourceCursor,
            caveats: [
                "A RuntimeHost adoption descriptor is reconnect material, not proof of liveness.",
                lifecycle == .ended
                    ? "Explicit End closed this run and its runtime host."
                    : "External effects are outside this actor's complete verification boundary.",
            ])
    }

    // MARK: Event delivery and observations

    private func emit(_ event: HostedInHouseWorkEvent) {
        for continuation in subscriptions.values {
            _ = continuation.yield(event)
        }
    }

    private func emitDurable(
        source: String,
        commits: [TimelineJournalCommit] = [],
        commandID: String? = nil,
        client: ClientRef? = nil
    ) async {
        let event = HostedInHouseWorkDurableEvent(
            source: source,
            commits: commits,
            sessionCursor: await bridge.nativeJournal.latestSessionCursor,
            workCursor: await bridge.nativeJournal.latestWorkCursor,
            commandID: commandID,
            client: client,
            canonicalCommandID: commandID.flatMap { id in
                guard let client else { return nil }
                return qualifiedCommandID(clientID: client.clientID, commandID: id)
            })
        emit(.durable(event))
    }

    private func runtimeObservation() -> HostedInHouseWorkRuntimeObservation {
        HostedInHouseWorkRuntimeObservation(
            state: runtimeState,
            descriptor: runtimeDescriptor,
            identity: runtimeIdentity,
            capabilitiesSummary: runtimeCapabilitiesSummary,
            transportConnected: runtimeTransportConnected,
            ownedProcessKnownAlive: ownedRuntimeProcessKnownAlive)
    }

    private func updateRuntimeState(_ state: HostedInHouseWorkRuntimeState) {
        guard !runtimeShutdownIsAbsorbing else {
            forceStoppedRuntime()
            return
        }
        runtimeState = state
        emit(.ephemeral(.runtime(runtimeObservation())))
    }

    private func forceStoppedRuntime() {
        let changed = runtimeState != .stopped
            || runtimeTransportConnected
            || ownedRuntimeProcessKnownAlive
        runtimeState = .stopped
        runtimeTransportConnected = false
        ownedRuntimeProcessKnownAlive = false
        if changed {
            emit(.ephemeral(.runtime(runtimeObservation())))
        }
    }

    private func appendFailure(_ detail: String) {
        let bounded = Self.bounded(detail)
        if let lastFailure, !lastFailure.isEmpty {
            self.lastFailure = Self.bounded(lastFailure + "; " + bounded)
        } else {
            lastFailure = bounded
        }
    }

    private var runtimeShutdownIsAbsorbing: Bool {
        // Once End is durably accepted, runtime teardown is irreversible even if a later journal
        // close/finalization step fails; canonical lifecycle remains ended and the failure is
        // exposed separately through journal health/lastFailure.
        endRequested || lifecycle == .ending || lifecycle == .ended
    }

    private func transition(
        to state: HostedInHouseWorkLifecycle, reason: String? = nil
    ) {
        guard lifecycle != .ended || state == .ended else { return }
        guard lifecycle != state else { return }
        let previous = lifecycle
        lifecycle = state
        emit(.ephemeral(.lifecycle(
            HostedInHouseWorkLifecycleEvent(from: previous, to: state, reason: reason))))
    }

    private func refreshRuntimeObservation() async {
        guard !runtimeShutdownIsAbsorbing else {
            // A terminal Work is an absorbing runtime state. In particular, a late GUI snapshot
            // must not reconnect or query a RuntimeHost that End has already stopped.
            forceStoppedRuntime()
            return
        }
        let previousState = runtimeState
        let previousTransport = runtimeTransportConnected
        let previousOwnedProcess = ownedRuntimeProcessKnownAlive
        let connected = await runtimeHost.isConnected
        guard !runtimeShutdownIsAbsorbing else {
            forceStoppedRuntime()
            return
        }
        runtimeTransportConnected = connected
        let ownedProcessKnownAlive = await runtimeHost.hostProcessIsRunning
        guard !runtimeShutdownIsAbsorbing else {
            forceStoppedRuntime()
            return
        }
        ownedRuntimeProcessKnownAlive = ownedProcessKnownAlive
        if connected {
            runtimeState = .connected
        } else if intentionallyDetached {
            runtimeState = .detached
        } else if runtimeDescriptor != nil, !runtimeShutdownIsAbsorbing {
            // An unexpected transport loss is not evidence that the process is dead. The service
            // can attempt adoption and verify the identity again.
            runtimeState = .unavailable
        }
        if previousState != runtimeState
            || previousTransport != runtimeTransportConnected
            || previousOwnedProcess != ownedRuntimeProcessKnownAlive
        {
            emit(.ephemeral(.runtime(runtimeObservation())))
        }
    }

    private func validateTerminalMutationState() throws {
        guard endRequested,
              lifecycle == .ended,
              runtimeState == .stopped,
              !runtimeTransportConnected,
              !ownedRuntimeProcessKnownAlive,
              agent == nil,
              runner == nil,
              !preparationInProgress else {
            throw WorkServiceProtocolError.invalidRequest(
                "Work completion or destruction requires an explicitly ended, quiescent Run")
        }
    }

    private func validateTerminalMutationIdentity(
        _ request: WorkServiceTerminalCommitRequest
    ) throws {
        let session = SessionRef(identity.sessionID)
        let authority = TimelineAuthorityRef(identity.workHostID)
        guard request.work == identity.work,
              request.journal == JournalRef.work(identity.work),
              request.session == session,
              request.sessionJournal == JournalRef.session(session, authority: authority),
              request.sessionAttachment == sessionAttachment,
              request.command.client == request.client,
              request.command.sessionAttachment == sessionAttachment,
              request.command.causalCursor == request.causalWorkCursor else {
            throw WorkServiceProtocolError.invalidRequest(
                "terminal request does not name this ended Session/Work execution")
        }
    }

    private func terminalMutationConflict() -> WorkServiceProtocolError {
        .invalidRequest("Work terminal command conflicts with the committed terminal request")
    }

    private func withTerminalMutationBundle<T>(
        _ body: (RunJournalBundleWorkServiceTerminalCommitter) async throws -> T
    ) async throws -> T {
        let terminalBundle = try await RunJournalBundle.openForTerminalMutation(
            home: configuration.home,
            identity: identity,
            sessionAttachment: sessionAttachment,
            actorID: configuration.serviceActorID)
        let committer = RunJournalBundleWorkServiceTerminalCommitter(
            bundle: terminalBundle,
            destroyResourcesAreQuiesced: { [weak self] in
                guard let self else { return false }
                return await self.terminalResourcesAreQuiesced()
            })
        do {
            let result = try await body(committer)
            try await terminalBundle.closeChecked()
            return result
        } catch {
            try? await terminalBundle.closeChecked()
            throw error
        }
    }

    private func terminalResourcesAreQuiesced() -> Bool {
        endRequested
            && lifecycle == .ended
            && runtimeState == .stopped
            && !runtimeTransportConnected
            && !ownedRuntimeProcessKnownAlive
            && agent == nil
            && runner == nil
            && !preparationInProgress
    }

    private func acquireTerminalMutationGate() async {
        if !terminalMutationGateHeld {
            terminalMutationGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            terminalMutationGateWaiters.append(continuation)
        }
    }

    private func releaseTerminalMutationGate() {
        if terminalMutationGateWaiters.isEmpty {
            terminalMutationGateHeld = false
            return
        }
        terminalMutationGateWaiters.removeFirst().resume()
    }

    private func receipt(for command: HostedInHouseWorkCommand) async -> HostedInHouseWorkReceipt {
        let commandReceipt = await controller.receipt(for: controllerCommandID(for: command))
            ?? SessionCommandReceipt(
                admission: .rejected(
                    commandID: controllerCommandID(for: command),
                    reason: .journalUnavailable))
        return HostedInHouseWorkReceipt(
            command: command,
            receipt: commandReceipt,
            sessionCursor: await bridge.nativeJournal.latestSessionCursor,
            workCursor: await bridge.nativeJournal.latestWorkCursor,
            lifecycle: lifecycle)
    }

    private func removeSubscription(_ id: String) {
        subscriptions.removeValue(forKey: id)?.finish()
        subscriptionClients.removeValue(forKey: id)
    }

    private func finishSubscriptions() {
        for continuation in subscriptions.values {
            continuation.finish()
        }
        subscriptions.removeAll()
        subscriptionClients.removeAll()
    }

    /// SessionCommandController currently accepts a single String identity. Its owning Work may
    /// receive the same caller-selected command ID from several GUI clients, so the controller
    /// identity must include the client without relying on a delimiter that caller data could
    /// collide with. Base64 is only an unambiguous transport encoding; it is not a secret or an
    /// authorization token.
    private func controllerCommandID(for command: HostedInHouseWorkCommand) -> String {
        qualifiedCommandID(clientID: command.client.clientID, commandID: command.commandID)
    }

    private func qualifiedCommandID(clientID: String, commandID: String) -> String {
        WorkServiceCommandLedgerIdentity.commandID(
            client: ClientRef(clientID), commandID: commandID)
    }

    private static func adoptionCaveat(_ descriptor: RuntimeHost.AdoptionDescriptor) -> String {
        let host = boundedUTF8(descriptor.identity.hostID, limit: 120)
        let instance = boundedUTF8(descriptor.identity.instanceID, limit: 120)
        return "runtime_adoption_descriptor=v1;protocol=\(descriptor.protocolVersion);"
            + "endpoint_present=true;host_id=\(host);instance_id=\(instance);"
            + "liveness_proof=false"
    }

    private static func bounded(_ detail: String, limit: Int = 1_000) -> String {
        boundedUTF8(detail, limit: limit).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedUTF8(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var result = String()
        var used = 0
        for scalar in value.unicodeScalars {
            let bytes = String(scalar).utf8.count
            guard used + bytes <= limit else { break }
            result.unicodeScalars.append(scalar)
            used += bytes
        }
        return result
    }
}
