import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum WorkHostDaemonRuntimeState: String, Codable, Hashable, Sendable {
    case prepared
    case starting
    case running
    case stopping
    case stopped
    case failed
}

public enum WorkHostDaemonRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case invalidServiceIdentity
    case invalidState(WorkHostDaemonRuntimeState)
    case startupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServiceIdentity:
            return "The backing Work service does not match this daemon instance."
        case .invalidState(let state):
            return "The Work Host daemon cannot start from \(state.rawValue)."
        case .startupFailed(let detail):
            return "The Work Host daemon could not start: \(detail)"
        }
    }
}

/// Owns the local service listener and its discovery record, but not the lifecycle of Work.
///
/// Closing a client connection never reaches this actor. Stopping the transport drains or aborts
/// connections according to the caller's explicit policy and likewise never issues End to a Work.
/// A higher-level daemon coordinator must separately refuse ordinary shutdown while live Work is
/// present; this type intentionally cannot infer that policy from a socket count.
public actor WorkHostDaemonRuntime {
    public nonisolated let hostInstance: WorkHostInstanceRef
    public nonisolated let layout: WorkHostDaemonEndpointLayout
    public nonisolated let endpoint: WorkServiceTransportEndpoint

    private let service: any WorkServiceClient
    private let processID: Int32
    private var stateStorage: WorkHostDaemonRuntimeState = .prepared
    private var descriptorStorage: WorkHostDaemonDescriptor?
    private var publisher: WorkHostDaemonEndpointPublisher?
    private var server: WorkServiceUnixSocketServer?

    public init(
        home: AgentHome,
        hostInstance: WorkHostInstanceRef,
        service: any WorkServiceClient,
        socketRoot: URL? = nil,
        processID: Int32 = getpid()
    ) throws {
        let layout = socketRoot.map {
            WorkHostDaemonEndpointLayout(
                home: home, workHost: hostInstance.host, socketRoot: $0)
        } ?? WorkHostDaemonEndpointLayout(home: home, workHost: hostInstance.host)
        self.hostInstance = hostInstance
        self.layout = layout
        self.endpoint = try layout.endpoint(for: hostInstance)
        self.service = service
        self.processID = processID
    }

    public var state: WorkHostDaemonRuntimeState { stateStorage }
    public var descriptor: WorkHostDaemonDescriptor? { descriptorStorage }
    public var connectedClientCount: Int {
        get async { await server?.connectedClientCount ?? 0 }
    }

    /// Verify the backing service identity before creating the listener, then publish discovery
    /// only after the listener is accepting. A publication failure closes the socket and leaves
    /// no success-shaped descriptor behind.
    @discardableResult
    public func start() async throws -> WorkHostDaemonDescriptor {
        if stateStorage == .running, let descriptorStorage { return descriptorStorage }
        guard stateStorage == .prepared else {
            throw WorkHostDaemonRuntimeError.invalidState(stateStorage)
        }
        // Claim startup before the first suspension. A concurrent stop (for example a
        // coordinator force-stop while the service handshake is still opening) must be able to
        // absorb this generation and prevent it from publishing a listener after shutdown.
        stateStorage = .starting
        // Keep local ownership of partially-created resources until the final state transition.
        // The actor can be stopped reentrantly at every await below; if a later validation or
        // publication step fails, these locals are the only reliable way to clean up a listener
        // that has not yet been installed in `self.server`/`self.publisher`.
        var candidateServer: WorkServiceUnixSocketServer?
        var candidatePublisher: WorkHostDaemonEndpointPublisher?
        do {
            let observed = try await service.handshake(WorkServiceHandshakeRequest(
                client: ClientRef("aviaryd-self-check"), build: "aviaryd"))
            guard stateStorage == .starting else {
                throw WorkHostDaemonRuntimeError.invalidState(stateStorage)
            }
            guard observed.accepted,
                  observed.negotiatedVersion == WorkServiceProtocol.currentVersion,
                  observed.host == hostInstance.host,
                  observed.hostInstance == hostInstance,
                  observed.controlJournal == JournalRef.workHost(hostInstance.host),
                  observed.controlCursor.journal == observed.controlJournal else {
                stateStorage = .failed
                throw WorkHostDaemonRuntimeError.invalidServiceIdentity
            }

            let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
            candidateServer = server
            try await server.start()
            guard stateStorage == .starting else {
                // A concurrent stop may have won while the listener actor hop was suspended.
                // Close this local listener before returning the generation-fenced failure.
                await server.stop()
                throw WorkHostDaemonRuntimeError.invalidState(stateStorage)
            }
            let descriptor = WorkHostDaemonDescriptor(
                hostInstance: hostInstance,
                endpoint: endpoint,
                processID: processID,
                publishedAt: Date())
            let publisher = try WorkHostDaemonEndpointPublisher(
                layout: layout, descriptor: descriptor)
            candidatePublisher = publisher
            do {
                try publisher.publish()
            } catch {
                await server.stop()
                candidateServer = nil
                candidatePublisher = nil
                throw error
            }
            self.server = server
            self.publisher = publisher
            candidateServer = nil
            candidatePublisher = nil
            descriptorStorage = descriptor
            stateStorage = .running
            return descriptor
        } catch let error as WorkHostDaemonRuntimeError {
            if let candidatePublisher { try? candidatePublisher.removeIfOwned() }
            if let candidateServer { await candidateServer.stop() }
            if stateStorage != .stopped { stateStorage = .failed }
            throw error
        } catch {
            if let candidatePublisher { try? candidatePublisher.removeIfOwned() }
            if let candidateServer { await candidateServer.stop() }
            if stateStorage != .stopped { stateStorage = .failed }
            throw WorkHostDaemonRuntimeError.startupFailed(Self.bounded(error.localizedDescription))
        }
    }

    /// Stop only the service transport. Work shutdown, handoff, or refusal belongs to the daemon
    /// coordinator that has canonical registry knowledge and must be decided before this call.
    public func stop(drainTimeout: TimeInterval = 2) async {
        // Cleanup is also required from `.failed`.  A startup failure can occur after a listener
        // has been created but before the runtime reaches `.running` (for example while endpoint
        // publication is being validated).  Treating failed as a terminal no-op would strand the
        // listener and any discovery record, leaving a later generation to see an occupied
        // endpoint.  The same absorbing cleanup is safe for prepared/starting/stopping states;
        // start() owns the state fence and will close any local listener that it created but did
        // not yet publish into `server`.
        guard stateStorage != .stopped else {
            return
        }
        stateStorage = .stopping
        await server?.stop(drainTimeout: drainTimeout)
        if let publisher {
            try? publisher.removeIfOwned()
        }
        server = nil
        publisher = nil
        descriptorStorage = nil
        stateStorage = .stopped
    }

    private static func bounded(_ value: String, maximumBytes: Int = 500) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        return String(decoding: value.utf8.prefix(maximumBytes), as: UTF8.self)
    }
}
