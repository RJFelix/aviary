import Foundation
import Dispatch

/// The result of composing a Work Host service for one process generation.
///
/// The coordinator owns this composition for the lifetime of the daemon.  In particular, the
/// service and its recovery reader are not closures over GUI state: a production resolver opens
/// the durable control journal and launch-manifest store afresh for every daemon process.
public struct WorkHostDaemonServiceComposition: Sendable {
    public let service: any WorkServiceClient
    public let scanRecovery: @Sendable () async throws -> [JournalBackedWorkRecoveryEntry]
    /// Whether the resolver can reconstruct execution material, not merely read metadata. A
    /// journal-backed service may still expose an idle projection when its provider/workspace
    /// resolver is absent; the daemon must not treat that projection as safe-to-stop.
    public let executionMaterialAvailable: Bool

    public init(
        service: any WorkServiceClient,
        scanRecovery: @escaping @Sendable () async throws -> [JournalBackedWorkRecoveryEntry],
        executionMaterialAvailable: Bool = true
    ) {
        self.service = service
        self.scanRecovery = scanRecovery
        self.executionMaterialAvailable = executionMaterialAvailable
    }
}

/// A process-local admission fence around the service exposed by the daemon transport.
///
/// A transport server can accept a socket while an ordinary shutdown is deciding whether it is
/// safe to leave. Merely taking a recovery snapshot and then stopping the listener therefore has
/// a race: a Start (or even Create) may be admitted between those two operations. The coordinator
/// gives the transport this gate and closes it before its final recovery read. New requests are
/// rejected after closure and already admitted requests drain before the canonical snapshot is
/// taken. The socket may still exist briefly while the runtime drains, but no request can cross
/// into the backing service during that interval.
public actor WorkHostDaemonAdmissionGate: WorkServiceClient {
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case closed

        public var errorDescription: String? {
            "The Work Host is quiescing and is not accepting service requests."
        }
    }

    private let service: any WorkServiceClient
    private var accepting = true
    private var inFlight = 0

    public init(service: any WorkServiceClient) {
        self.service = service
    }

    public var isAccepting: Bool { accepting }

    /// Close admission and wait for every request which crossed the fence to return.
    @discardableResult
    public func closeAndDrain(timeout: TimeInterval = 2) async -> Bool {
        accepting = false
        guard inFlight > 0 else { return true }
        let boundedTimeout: TimeInterval
        if timeout.isFinite {
            boundedTimeout = max(0, min(timeout, 30))
        } else {
            boundedTimeout = timeout.isNaN || timeout < 0 ? 0 : 30
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(boundedTimeout * 1_000_000_000)
        // Keep the wait bounded even if a backing service call wedges. The gate stays closed on
        // timeout; the coordinator can reopen it and continue serving rather than claiming the
        // final recovery read covered an unknown in-flight mutation.
        while inFlight > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = min(20_000_000, deadline - now)
            try? await Task.sleep(nanoseconds: remaining)
        }
        return true
    }

    /// Re-open after a shutdown refusal. No request is replayed; clients must retry with the
    /// cursor/receipt they already hold.
    public func reopen() {
        accepting = true
    }

    private func enter() throws {
        guard accepting else { throw Error.closed }
        inFlight += 1
    }

    private func leave() {
        inFlight = max(0, inFlight - 1)
    }

    public func handshake(_ request: WorkServiceHandshakeRequest) async throws
        -> WorkServiceHandshakeResponse {
        try enter(); defer { leave() }
        return try await service.handshake(request)
    }

    public func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        try enter(); defer { leave() }
        return try await service.listWorks(request)
    }

    public func describeWork(_ request: WorkServiceDescribeRequest) async throws
        -> WorkServiceWorkDescriptor {
        try enter(); defer { leave() }
        return try await service.describeWork(request)
    }

    public func createWork(_ request: WorkServiceCreateWorkRequest) async throws
        -> WorkServiceCreateWorkResponse {
        try enter(); defer { leave() }
        return try await service.createWork(request)
    }

    public func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws
        -> WorkServiceCommandReceipt {
        try enter(); defer { leave() }
        return try await service.completeWork(request)
    }

    public func attach(_ request: WorkServiceAttachRequest) async throws
        -> WorkServiceAttachResponse {
        try enter(); defer { leave() }
        return try await service.attach(request)
    }

    public func detach(_ request: WorkServiceDetachRequest) async throws
        -> WorkServiceDetachResponse {
        try enter(); defer { leave() }
        return try await service.detach(request)
    }

    public func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws
        -> WorkServiceUpdateCapabilitiesResponse {
        try enter(); defer { leave() }
        return try await service.updateCapabilities(request)
    }

    public func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws
        -> WorkServiceAcknowledgeReadResponse {
        try enter(); defer { leave() }
        return try await service.acknowledgeRead(request)
    }

    public func snapshot(_ request: WorkServiceSnapshotRequest) async throws
        -> WorkServiceSnapshot {
        try enter(); defer { leave() }
        return try await service.snapshot(request)
    }

    public func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws
        -> WorkServiceEventPage {
        try enter(); defer { leave() }
        return try await service.eventsAfterCursor(request)
    }

    public func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws
        -> WorkServiceArtifactDescriptor {
        try enter(); defer { leave() }
        return try await service.fetchArtifact(request)
    }

    public func fetchBody(_ request: WorkServiceBodyRequest) async throws
        -> WorkServiceBodyResponse {
        try enter(); defer { leave() }
        return try await service.fetchBody(request)
    }

    public func command(_ request: WorkServiceCommandRequest) async throws
        -> WorkServiceCommandReceipt {
        try enter(); defer { leave() }
        return try await service.command(request)
    }
}

/// An injected host-private composition boundary.
///
/// Core can enforce process-generation and endpoint identity without knowing how a particular
/// installation resolves provider credentials, workspace policy, or RuntimeHost adoption.  The
/// default resolver deliberately fails closed.  A real host supplies those resolvers; it must
/// never smuggle a prompt, credential, or in-memory actor through the transport contract.
public struct WorkHostDaemonServiceResolver: Sendable {
    public typealias Open = @Sendable (
        AgentHome,
        WorkHostRef,
        WorkHostInstanceRef,
        [String: String]
    ) async throws -> WorkHostDaemonServiceComposition

    private let openClosure: Open

    public init(_ open: @escaping Open) {
        self.openClosure = open
    }

    public func open(
        home: AgentHome,
        host: WorkHostRef,
        instance: WorkHostInstanceRef,
        environment: [String: String]
    ) async throws -> WorkHostDaemonServiceComposition {
        try await openClosure(home, host, instance, environment)
    }

    /// A durable service resolver for the Work Host's journal-backed composition.
    ///
    /// `draftResolver` and `hostedResolver` are intentionally required inputs rather than
    /// guessed from a GUI configuration.  The daemon can open and serve already-recorded
    /// history when the launch resolver is unavailable, while new Create/Start requests fail
    /// closed at the exact operation that needs missing host-private material.
    public static func durable(
        authorizer: any WorkServiceAuthorizer,
        draftResolver: @escaping DurableJournalBackedWorkLaunchManifestStore.DraftResolver,
        hostedResolver: DurableJournalBackedWorkLaunchManifestStore.HostedConfigurationResolver?
            = nil,
        promptAssemblyResolver:
            DurableJournalBackedWorkLaunchManifestStore.PromptAssemblyResolver? = nil,
        reconstructabilityProbe: DurableJournalBackedWorkLaunchManifestStore.ReconstructabilityProbe?
            = nil,
        workspaceCatalogProvider: @escaping WorkHostWorkspaceCatalogProvider = { .empty },
        actor: TimelineActor = TimelineActor(actorID: "aviaryd", kind: "work-host")
    ) -> WorkHostDaemonServiceResolver {
        WorkHostDaemonServiceResolver { home, host, instance, _ in
            let manifestStore = DurableJournalBackedWorkLaunchManifestStore(
                store: WorkLaunchManifestStore(home: home),
                bodyAuthority: .workHost(host),
                draftResolver: draftResolver,
                hostedResolver: hostedResolver,
                promptAssemblyResolver: promptAssemblyResolver,
                reconstructabilityProbe: reconstructabilityProbe)
            let service = try JournalBackedWorkService(
                home: home,
                workHost: host,
                instanceID: instance.instanceID,
                startIdentity: instance.startIdentity,
                actor: actor,
                authorizer: authorizer,
                manifestStore: manifestStore,
                workspaceCatalogProvider: workspaceCatalogProvider)
            return WorkHostDaemonServiceComposition(
                service: service,
                scanRecovery: { try await service.scanRecovery() },
                executionMaterialAvailable: hostedResolver != nil
                    && promptAssemblyResolver != nil)
        }
    }

    /// The executable's safe default.  It opens the durable service composition but has no
    /// authority to invent provider or runtime configuration, so Create/Start remain unavailable
    /// until the app supplies a host-private resolver.
    public static var unavailable: WorkHostDaemonServiceResolver {
        durable(
            authorizer: WorkServiceCapabilityPolicy(),
            draftResolver: { _ in throw WorkServiceProtocolError.sourceIncomplete })
    }
}

public enum WorkHostDaemonCoordinatorState: String, Codable, Hashable, Sendable {
    case prepared
    case starting
    case running
    case stopping
    case stopped
    case failed
}

public enum WorkHostDaemonCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case invalidState(WorkHostDaemonCoordinatorState)
    case startupFailed(String)
    case shutdownRefused([WorkRef])
    case shutdownTimedOut
    case noService

    public var errorDescription: String? {
        switch self {
        case .invalidState(let state):
            return "The Work Host daemon cannot perform that operation from \(state.rawValue)."
        case .startupFailed(let detail):
            return "The Work Host daemon could not start: \(detail)"
        case .shutdownRefused(let works):
            let names = works.map { $0.workID }.joined(separator: ", ")
            return "Shutdown refused while canonical Work requires service recovery: \(names)."
        case .shutdownTimedOut:
            return "Shutdown refused because admitted service requests did not drain in time."
        case .noService:
            return "The Work Host daemon has no composed service."
        }
    }
}

public struct WorkHostDaemonCoordinatorSnapshot: Codable, Hashable, Sendable {
    public let state: WorkHostDaemonCoordinatorState
    public let host: WorkHostRef
    public let hostInstance: WorkHostInstanceRef
    public let loginShellEnvironmentLoaded: Bool
    public let descriptor: WorkHostDaemonDescriptor?
    public let recovery: [JournalBackedWorkRecoveryEntry]

    public init(
        state: WorkHostDaemonCoordinatorState,
        host: WorkHostRef,
        hostInstance: WorkHostInstanceRef,
        loginShellEnvironmentLoaded: Bool,
        descriptor: WorkHostDaemonDescriptor?,
        recovery: [JournalBackedWorkRecoveryEntry]
    ) {
        self.state = state
        self.host = host
        self.hostInstance = hostInstance
        self.loginShellEnvironmentLoaded = loginShellEnvironmentLoaded
        self.descriptor = descriptor
        self.recovery = recovery
    }
}

/// Process owner for one Work Host generation.
///
/// A GUI is a client of this actor, never its owner.  Client EOF, a closed GUI window, and a
/// disconnected socket do not call `shutdown` or End.  Only an explicit ordinary shutdown gets
/// to the canonical recovery gate, and that gate is checked again immediately before transport
/// teardown.
public actor WorkHostDaemonCoordinator {
    public nonisolated let home: AgentHome
    public nonisolated let host: WorkHostRef
    public nonisolated let hostInstance: WorkHostInstanceRef
    public nonisolated let socketRoot: URL?

    private let resolver: WorkHostDaemonServiceResolver
    private var stateStorage: WorkHostDaemonCoordinatorState = .prepared
    private var environmentLoaded = false
    private var composition: WorkHostDaemonServiceComposition?
    private var admissionGate: WorkHostDaemonAdmissionGate?
    private var runtime: WorkHostDaemonRuntime?
    private var recoveryStorage: [JournalBackedWorkRecoveryEntry] = []
    private var descriptorStorage: WorkHostDaemonDescriptor?
    /// Invalidates a suspended lifecycle mutation when a later force-stop takes ownership.
    /// Actor isolation does not prevent reentrancy across `await`, so state alone cannot
    /// distinguish the original shutdown from the force-stop's own `.stopping` transition.
    private var lifecycleEpoch: UInt64 = 0

    public init(
        home: AgentHome = .default,
        socketRoot: URL? = nil,
        instanceID: String? = nil,
        startIdentity: String? = nil,
        resolver: WorkHostDaemonServiceResolver = .unavailable
    ) throws {
        let host = try home.requirePersistedWorkHost()
        let instance = WorkHostInstanceRef(
            host: host,
            instanceID: instanceID ?? "instance-" + AviarySecureRandom.uuidString(),
            startIdentity: startIdentity ?? "start-" + AviarySecureRandom.uuidString())
        self.home = home
        self.host = host
        self.hostInstance = instance
        self.socketRoot = socketRoot
        self.resolver = resolver
    }

    public var state: WorkHostDaemonCoordinatorState { stateStorage }
    public var descriptor: WorkHostDaemonDescriptor? { descriptorStorage }
    public var recovery: [JournalBackedWorkRecoveryEntry] { recoveryStorage }
    public var loginShellEnvironmentLoaded: Bool { environmentLoaded }

    public func snapshot() -> WorkHostDaemonCoordinatorSnapshot {
        WorkHostDaemonCoordinatorSnapshot(
            state: stateStorage,
            host: host,
            hostInstance: hostInstance,
            loginShellEnvironmentLoaded: environmentLoaded,
            descriptor: descriptorStorage,
            recovery: recoveryStorage)
    }

    /// Compose the durable service, read recovery as observation-only, then let the runtime
    /// perform its exact handshake fence before publishing the endpoint descriptor.
    @discardableResult
    public func start() async throws -> WorkHostDaemonDescriptor {
        guard stateStorage == .prepared else {
            if stateStorage == .running, let descriptorStorage { return descriptorStorage }
            throw WorkHostDaemonCoordinatorError.invalidState(stateStorage)
        }
        stateStorage = .starting
        do {
            // ProcessEnvironment documents the login-shell snapshot as a process-wide value.
            // A daemon coordinator may be created more than once in one process (the self-test
            // suite does this deliberately), so do not launch another interactive shell after a
            // successful snapshot.  Reattempt only when the previous load genuinely failed.
            if ProcessEnvironment.shared.isLoginShellEnvironment {
                environmentLoaded = true
            } else {
                environmentLoaded = await ProcessEnvironment.shared.loadFromLoginShell()
            }
            try ensureStartupIsStillOwned()
            let environment = ProcessEnvironment.shared.snapshot
            let composition = try await resolver.open(
                home: home, host: host, instance: hostInstance, environment: environment)
            try ensureStartupIsStillOwned()
            let recovery = normalizedRecovery(
                try await composition.scanRecovery(), composition: composition)
            try ensureStartupIsStillOwned()
            self.composition = composition
            recoveryStorage = recovery

            let admissionGate = WorkHostDaemonAdmissionGate(service: composition.service)
            let runtime = try WorkHostDaemonRuntime(
                home: home,
                hostInstance: hostInstance,
                service: admissionGate,
                socketRoot: socketRoot)
            // Retain both owners before the first await. If listener publication or the exact
            // service handshake fails, the catch path can close the partially started runtime
            // rather than relying on actor deallocation to release its socket.
            self.admissionGate = admissionGate
            self.runtime = runtime
            let descriptor = try await runtime.start()
            try ensureStartupIsStillOwned()
            descriptorStorage = descriptor
            stateStorage = .running
            return descriptor
        } catch let error as WorkHostDaemonCoordinatorError {
            if let runtime { await runtime.stop() }
            runtime = nil
            admissionGate = nil
            descriptorStorage = nil
            if stateStorage == .starting { stateStorage = .failed }
            throw error
        } catch {
            if let runtime { await runtime.stop() }
            runtime = nil
            admissionGate = nil
            descriptorStorage = nil
            if stateStorage == .starting { stateStorage = .failed }
            throw WorkHostDaemonCoordinatorError.startupFailed(Self.bounded(error.localizedDescription))
        }
    }

    private func ensureStartupIsStillOwned() throws {
        guard stateStorage == .starting else {
            throw WorkHostDaemonCoordinatorError.invalidState(stateStorage)
        }
    }

    /// Refresh recovery from the service without changing liveness or claiming a host instance.
    /// This is useful before a shutdown gate and for diagnostics after another GUI attaches.
    public func refreshRecovery() async throws -> [JournalBackedWorkRecoveryEntry] {
        guard let composition else { throw WorkHostDaemonCoordinatorError.noService }
        let recovery = normalizedRecovery(
            try await composition.scanRecovery(), composition: composition)
        recoveryStorage = recovery
        return recovery
    }

    /// Ordinary shutdown is deliberately refusal-based.  An active durable Run, or a durable
    /// record which requires recovery, keeps the service process available for a future GUI.
    /// The caller may separately terminate the process forcibly; that path leaves canonical
    /// recovery evidence and never pretends that Work was ended.
    public func shutdown(drainTimeout: TimeInterval = 2) async throws {
        guard stateStorage == .running else {
            if stateStorage == .stopped { return }
            throw WorkHostDaemonCoordinatorError.invalidState(stateStorage)
        }
        // Claim the stopping transition before the first suspension. This prevents a second
        // shutdown (or a supervisor force-stop) from racing the same gate and transport while the
        // first call drains accepted requests.
        stateStorage = .stopping
        lifecycleEpoch &+= 1
        let shutdownEpoch = lifecycleEpoch
        let gate = admissionGate
        let ownedRuntime = runtime
        // Close the service-facing admission boundary before the final canonical read. This is
        // the ordering that makes shutdown safe against a concurrent Start/Create: no new
        // request can enter after closeAndDrain returns, and already accepted work has completed.
        let drained = await gate?.closeAndDrain(timeout: drainTimeout) ?? true
        guard drained else {
            guard ownsShutdown(shutdownEpoch) else { return }
            await gate?.reopen()
            guard ownsShutdown(shutdownEpoch) else { return }
            stateStorage = .running
            throw WorkHostDaemonCoordinatorError.shutdownTimedOut
        }
        guard ownsShutdown(shutdownEpoch) else { return }
        let recovery: [JournalBackedWorkRecoveryEntry]
        do {
            guard let composition else { throw WorkHostDaemonCoordinatorError.noService }
            recovery = normalizedRecovery(
                try await composition.scanRecovery(), composition: composition)
        } catch {
            guard ownsShutdown(shutdownEpoch) else { return }
            await gate?.reopen()
            guard ownsShutdown(shutdownEpoch) else { return }
            stateStorage = .running
            throw error
        }
        guard ownsShutdown(shutdownEpoch) else { return }
        recoveryStorage = recovery
        let blockers = recovery.filter { entry in
            switch entry.disposition {
            case .liveUnproven, .recoveryRequired, .corrupt:
                return true
            case .idleReconstructable, .historical:
                return false
            case .unavailable:
                // An unavailable source is not evidence that Work is quiescent. Keep the
                // process available so a future GUI can repair/read the canonical record.
                return true
            }
        }.map(\.work)
        guard blockers.isEmpty else {
            guard ownsShutdown(shutdownEpoch) else { return }
            await gate?.reopen()
            guard ownsShutdown(shutdownEpoch) else { return }
            stateStorage = .running
            throw WorkHostDaemonCoordinatorError.shutdownRefused(blockers)
        }
        await ownedRuntime?.stop(drainTimeout: drainTimeout)
        guard ownsShutdown(shutdownEpoch) else { return }
        runtime = nil
        descriptorStorage = nil
        admissionGate = nil
        stateStorage = .stopped
    }

    private func ownsShutdown(_ epoch: UInt64) -> Bool {
        stateStorage == .stopping && lifecycleEpoch == epoch
    }

    private func normalizedRecovery(
        _ entries: [JournalBackedWorkRecoveryEntry],
        composition: WorkHostDaemonServiceComposition
    ) -> [JournalBackedWorkRecoveryEntry] {
        guard !composition.executionMaterialAvailable else { return entries }
        return entries.map { entry in
            guard entry.disposition == .idleReconstructable else { return entry }
            return JournalBackedWorkRecoveryEntry(
                work: entry.work, journal: entry.journal,
                disposition: .recoveryRequired, workCursor: entry.workCursor,
                sessionCursor: entry.sessionCursor, sourcePresence: entry.sourcePresence,
                failure: entry.failure, hostInstance: entry.hostInstance,
                diagnostic: "execution resolver unavailable; idle metadata is not a stop proof")
        }
    }

    /// Explicit forced transport stop.  This does not mutate Work, End a Run, or clear recovery
    /// records; it exists for a supervisor that is itself intentionally killing the process.
    public func forceStop(drainTimeout: TimeInterval = 0) async {
        // A failed startup may still own a partially-created runtime (and therefore a listener or
        // discovery record).  Force-stop is the supervisor's last cleanup boundary, so it must
        // absorb `.failed` as well as the in-flight states.  Prepared has no owned resources.
        guard stateStorage == .running || stateStorage == .starting || stateStorage == .stopping
            || stateStorage == .failed else {
            return
        }
        lifecycleEpoch &+= 1
        stateStorage = .stopping
        await runtime?.stop(drainTimeout: drainTimeout)
        runtime = nil
        descriptorStorage = nil
        admissionGate = nil
        stateStorage = .stopped
    }

    private static func bounded(_ value: String, maximumBytes: Int = 500) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        return String(decoding: value.utf8.prefix(maximumBytes), as: UTF8.self)
    }
}
