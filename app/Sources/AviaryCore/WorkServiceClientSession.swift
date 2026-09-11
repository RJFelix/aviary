import Foundation

/// A connection that can be discarded without issuing any Work lifecycle command.
/// `close` means "this client went away", never End, Complete, or Destroy.
public protocol WorkServiceClientConnection: WorkServiceClient {
    func close() async
}

extension WorkServiceUnixSocketClient: WorkServiceClientConnection {}

public enum WorkServiceClientSessionState: Equatable, Sendable {
    case disconnected
    case discovering
    case connecting(WorkHostRef)
    case connected(WorkHostInstanceRef)
    case reconnecting(WorkHostRef?)
    case unavailable(WorkHostRef?)
    case incompatible(WorkHostRef?)
}

public enum WorkServiceClientSessionError: Error, Equatable, Sendable {
    case invalidClient
    case unavailable
    case incompatibleProtocol
    case hostInstanceMismatch
    case notConnected
    case superseded
}

/// The GUI-side owner of one Work-service connection.
///
/// Calls are never replayed automatically. A transport loss can make a mutation indeterminate,
/// so callers reconnect and reconcile the durable command identity before deciding what to do.
/// Connection generations also fence a late response from an older socket after reconnect.
public actor WorkServiceClientSession: WorkServiceClient {
    public typealias ConnectionFactory = @Sendable (
        WorkServiceHostLocation, ClientRef
    ) async throws -> any WorkServiceClientConnection

    private struct Established: Sendable {
        let generation: UInt64
        let location: WorkServiceHostLocation
        let connection: any WorkServiceClientConnection
        let handshake: WorkServiceHandshakeResponse
    }

    private struct PendingConnection: Sendable {
        let generation: UInt64
        let task: Task<Established, Error>
    }

    public let client: ClientRef
    private let locator: any WorkServiceHostLocating
    private let build: String?
    private let connectionFactory: ConnectionFactory
    private var stateStorage: WorkServiceClientSessionState = .disconnected
    private var generation: UInt64 = 0
    private var pendingConnection: PendingConnection?
    private var connection: (any WorkServiceClientConnection)?
    private var handshakeStorage: WorkServiceHandshakeResponse?

    public init(
        locator: any WorkServiceHostLocating,
        client: ClientRef,
        build: String? = nil,
        connectionFactory: @escaping ConnectionFactory = { @Sendable location, client in
            try await WorkServiceClientSession.unixConnection(location, client)
        }
    ) throws {
        guard Self.validIdentity(client.clientID) else {
            throw WorkServiceClientSessionError.invalidClient
        }
        self.locator = locator
        self.client = client
        self.build = build
        self.connectionFactory = connectionFactory
    }

    public var state: WorkServiceClientSessionState { stateStorage }
    public var negotiatedHandshake: WorkServiceHandshakeResponse? { handshakeStorage }

    @discardableResult
    public func connect() async throws -> WorkServiceHandshakeResponse {
        if let handshakeStorage { return handshakeStorage }
        if let pendingConnection { return try await finish(pendingConnection) }

        generation = generation == UInt64.max ? 1 : generation + 1
        let attemptGeneration = generation
        stateStorage = .discovering
        let locator = self.locator
        let client = self.client
        let build = self.build
        let factory = self.connectionFactory
        let task = Task<Established, Error> { [weak self] in
            guard let location = try await locator.locate() else {
                throw WorkServiceClientSessionError.unavailable
            }
            await self?.markConnecting(
                host: location.host, generation: attemptGeneration)
            guard location.protocolVersion >= WorkServiceProtocol.minimumSupportedVersion,
                  location.protocolVersion <= WorkServiceProtocol.maximumSupportedVersion else {
                throw WorkServiceClientSessionError.incompatibleProtocol
            }
            let connection = try await factory(location, client)
            do {
                let handshake = try await connection.handshake(
                    WorkServiceHandshakeRequest(client: client, build: build))
                guard handshake.accepted,
                      handshake.negotiatedVersion == location.protocolVersion,
                      handshake.host == location.host,
                      handshake.hostInstance == location.expectedInstance else {
                    await connection.close()
                    throw WorkServiceClientSessionError.hostInstanceMismatch
                }
                return Established(
                    generation: attemptGeneration, location: location,
                    connection: connection, handshake: handshake)
            } catch {
                await connection.close()
                throw error
            }
        }
        let pending = PendingConnection(generation: attemptGeneration, task: task)
        pendingConnection = pending
        return try await finish(pending)
    }

    /// Fetch the current control-journal cursor on the existing socket.  `connect()` deliberately
    /// returns its cached handshake, which is correct for ordinary reads but would make a second
    /// control mutation use a stale causal cursor forever.  This operation never replays a
    /// mutation and fences the response to the same connection generation and host instance.
    @discardableResult
    public func refreshHandshake() async throws -> WorkServiceHandshakeResponse {
        guard let connection, let cached = handshakeStorage else {
            return try await connect()
        }
        let operationGeneration = generation
        do {
            let response = try await connection.handshake(
                WorkServiceHandshakeRequest(client: client, build: build))
            guard generation == operationGeneration, self.connection != nil else {
                throw WorkServiceClientSessionError.superseded
            }
            guard response.accepted,
                  let negotiatedVersion = response.negotiatedVersion,
                  negotiatedVersion >= response.supportedRange.lowerBound,
                  negotiatedVersion <= response.supportedRange.upperBound,
                  response.host == cached.host,
                  response.hostInstance == cached.hostInstance else {
                self.connection = nil
                handshakeStorage = nil
                stateStorage = .incompatible(cached.host)
                await connection.close()
                throw WorkServiceClientSessionError.hostInstanceMismatch
            }
            handshakeStorage = response
            stateStorage = .connected(response.hostInstance)
            return response
        } catch {
            if generation == operationGeneration,
               Self.losesConnection(error) {
                let host = handshakeStorage?.host
                self.connection = nil
                handshakeStorage = nil
                stateStorage = .reconnecting(host)
                await connection.close()
            }
            throw error
        }
    }

    /// Close only this client connection. Work remains owned by the Work Host.
    public func disconnect() async {
        generation = generation == UInt64.max ? 1 : generation + 1
        pendingConnection?.task.cancel()
        pendingConnection = nil
        let old = connection
        connection = nil
        handshakeStorage = nil
        stateStorage = .disconnected
        await old?.close()
    }

    public func handshake(
        _ request: WorkServiceHandshakeRequest
    ) async throws -> WorkServiceHandshakeResponse {
        try requireClient(request.client)
        return try await connect()
    }

    public func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        try requireClient(request.client)
        return try await perform { try await $0.listWorks(request) }
    }

    public func describeWork(
        _ request: WorkServiceDescribeRequest
    ) async throws -> WorkServiceWorkDescriptor {
        try requireClient(request.client)
        return try await perform { try await $0.describeWork(request) }
    }

    public func createWork(
        _ request: WorkServiceCreateWorkRequest
    ) async throws -> WorkServiceCreateWorkResponse {
        try requireClient(request.client)
        return try await perform { try await $0.createWork(request) }
    }

    public func createSession(
        _ request: WorkServiceCreateSessionRequest
    ) async throws -> WorkServiceCreateSessionResponse {
        try requireClient(request.client)
        return try await perform { try await $0.createSession(request) }
    }

    public func completeWork(
        _ request: WorkServiceCompleteWorkRequest
    ) async throws -> WorkServiceCommandReceipt {
        guard request.command.client == client else {
            throw WorkServiceClientSessionError.invalidClient
        }
        return try await perform { try await $0.completeWork(request) }
    }

    public func attach(
        _ request: WorkServiceAttachRequest
    ) async throws -> WorkServiceAttachResponse {
        try requireClient(request.client)
        return try await perform { try await $0.attach(request) }
    }

    public func detach(
        _ request: WorkServiceDetachRequest
    ) async throws -> WorkServiceDetachResponse {
        try requireClient(request.client)
        return try await perform { try await $0.detach(request) }
    }

    public func updateCapabilities(
        _ request: WorkServiceUpdateCapabilitiesRequest
    ) async throws -> WorkServiceUpdateCapabilitiesResponse {
        try requireClient(request.client)
        return try await perform { try await $0.updateCapabilities(request) }
    }

    public func acknowledgeRead(
        _ request: WorkServiceAcknowledgeReadRequest
    ) async throws -> WorkServiceAcknowledgeReadResponse {
        try requireClient(request.client)
        return try await perform { try await $0.acknowledgeRead(request) }
    }

    public func snapshot(
        _ request: WorkServiceSnapshotRequest
    ) async throws -> WorkServiceSnapshot {
        try requireClient(request.client)
        return try await perform { try await $0.snapshot(request) }
    }

    public func eventsAfterCursor(
        _ request: WorkServiceEventsRequest
    ) async throws -> WorkServiceEventPage {
        try requireClient(request.client)
        return try await perform { try await $0.eventsAfterCursor(request) }
    }

    public func historyBeforeCursor(
        _ request: WorkServiceHistoryRequest
    ) async throws -> WorkServiceHistoryPage {
        try requireClient(request.client)
        return try await perform { try await $0.historyBeforeCursor(request) }
    }

    public func fetchArtifact(
        _ request: WorkServiceArtifactRequest
    ) async throws -> WorkServiceArtifactDescriptor {
        try requireClient(request.client)
        return try await perform { try await $0.fetchArtifact(request) }
    }

    public func fetchBody(
        _ request: WorkServiceBodyRequest
    ) async throws -> WorkServiceBodyResponse {
        try requireClient(request.client)
        return try await perform { try await $0.fetchBody(request) }
    }

    public func cancelAgentHandle(
        _ request: WorkServiceAgentHandleCancelRequest
    ) async throws -> WorkServiceAgentHandleCancelResponse {
        guard request.command.client == client else {
            throw WorkServiceClientSessionError.invalidClient
        }
        return try await perform { try await $0.cancelAgentHandle(request) }
    }

    public func command(
        _ request: WorkServiceCommandRequest
    ) async throws -> WorkServiceCommandReceipt {
        guard request.command.client == client else {
            throw WorkServiceClientSessionError.invalidClient
        }
        return try await perform { try await $0.command(request) }
    }

    private func finish(_ pending: PendingConnection) async throws
        -> WorkServiceHandshakeResponse
    {
        do {
            let established = try await pending.task.value
            if generation == pending.generation,
               pendingConnection == nil,
               let handshakeStorage {
                return handshakeStorage
            }
            guard generation == pending.generation,
                  pendingConnection?.generation == pending.generation else {
                await established.connection.close()
                throw WorkServiceClientSessionError.superseded
            }
            pendingConnection = nil
            connection = established.connection
            handshakeStorage = established.handshake
            stateStorage = .connected(established.handshake.hostInstance)
            return established.handshake
        } catch {
            if generation == pending.generation,
               pendingConnection?.generation == pending.generation {
                pendingConnection = nil
                connection = nil
                handshakeStorage = nil
                stateStorage = stateAfterConnectionFailure(error)
            }
            throw error
        }
    }

    private func perform<T: Sendable>(
        _ operation: @Sendable (any WorkServiceClientConnection) async throws -> T
    ) async throws -> T {
        guard let connection, handshakeStorage != nil else {
            throw WorkServiceClientSessionError.notConnected
        }
        let operationGeneration = generation
        do {
            let value = try await operation(connection)
            guard generation == operationGeneration,
                  self.connection != nil else {
                throw WorkServiceClientSessionError.superseded
            }
            return value
        } catch {
            if generation == operationGeneration, Self.losesConnection(error) {
                let host = handshakeStorage?.host
                self.connection = nil
                handshakeStorage = nil
                stateStorage = .reconnecting(host)
                await connection.close()
            }
            throw error
        }
    }

    private func requireClient(_ candidate: ClientRef) throws {
        guard candidate == client else { throw WorkServiceClientSessionError.invalidClient }
    }

    private func markConnecting(host: WorkHostRef, generation candidate: UInt64) {
        guard generation == candidate else { return }
        stateStorage = .connecting(host)
    }

    private func stateAfterConnectionFailure(_ error: Error) -> WorkServiceClientSessionState {
        let discoveredHost: WorkHostRef? = switch stateStorage {
        case .connecting(let host): host
        case .reconnecting(let host), .unavailable(let host), .incompatible(let host): host
        case .disconnected, .discovering, .connected: nil
        }
        switch error {
        case WorkServiceClientSessionError.incompatibleProtocol,
             WorkServiceClientSessionError.hostInstanceMismatch:
            return .incompatible(discoveredHost)
        default:
            return .unavailable(discoveredHost)
        }
    }

    private static func losesConnection(_ error: Error) -> Bool {
        guard let transport = error as? WorkServiceTransportError else { return false }
        switch transport {
        case .notConnected, .disconnected, .invalidFrame, .invalidResponse,
             .duplicateResponseID, .writeFailed:
            return true
        case .remote(let code, _):
            // An identity mismatch is a poisoned connection, not an ordinary rejected
            // operation.  The peer may have been replaced behind the endpoint (or a
            // connection's principal may have changed), so retaining the cached socket and
            // handshake would make every subsequent request fail against an untrusted host.
            return code == .identityMismatch || code == .transportClosed
                || code == .serverStopping || code == .serviceUnavailable
                || code == .connectionExhausted
        case .invalidEndpoint, .endpointUnavailable, .endpointOccupied, .alreadyConnected,
             .frameTooLarge,
             .tooManyPendingRequests, .timedOut, .canceled:
            return false
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    public static func unixConnection(
        _ location: WorkServiceHostLocation,
        _ client: ClientRef
    ) async throws -> any WorkServiceClientConnection {
        switch location.transport {
        case .unixSocket(let endpoint):
            return WorkServiceUnixSocketClient(
                endpoint: endpoint, client: client, expectedHost: location.host)
        }
    }
}
