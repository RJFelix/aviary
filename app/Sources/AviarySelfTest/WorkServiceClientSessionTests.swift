import Foundation
@testable import AviaryCore

private struct FixedWorkServiceHostLocator: WorkServiceHostLocating {
    let location: WorkServiceHostLocation?

    func locate() async throws -> WorkServiceHostLocation? { location }
}

private actor ClientSessionGate {
    private var isOpen = false
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isOpen = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ClientSessionConnectionFactoryCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func observedCount() -> Int { count }
}

private actor ClientSessionObservedConnection: WorkServiceClientConnection {
    let base: WorkServiceUnixSocketClient
    let createResponseGate: ClientSessionGate?
    let listError: WorkServiceTransportError?
    let childCancelResponseError: WorkServiceTransportError?
    let handshakeResponse: WorkServiceHandshakeResponse?
    let handshakeError: WorkServiceTransportError?
    private(set) var closeCount = 0
    private(set) var childCancelCallCount = 0

    init(
        base: WorkServiceUnixSocketClient,
        createResponseGate: ClientSessionGate? = nil,
        listError: WorkServiceTransportError? = nil,
        childCancelResponseError: WorkServiceTransportError? = nil,
        handshakeResponse: WorkServiceHandshakeResponse? = nil,
        handshakeError: WorkServiceTransportError? = nil
    ) {
        self.base = base
        self.createResponseGate = createResponseGate
        self.listError = listError
        self.childCancelResponseError = childCancelResponseError
        self.handshakeResponse = handshakeResponse
        self.handshakeError = handshakeError
    }

    func close() async {
        closeCount += 1
        await base.close()
    }

    func handshake(
        _ request: WorkServiceHandshakeRequest
    ) async throws -> WorkServiceHandshakeResponse {
        if let handshakeError { throw handshakeError }
        if let handshakeResponse { return handshakeResponse }
        return try await base.handshake(request)
    }

    func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        if let listError { throw listError }
        return try await base.listWorks(request)
    }

    func describeWork(
        _ request: WorkServiceDescribeRequest
    ) async throws -> WorkServiceWorkDescriptor {
        try await base.describeWork(request)
    }

    func createWork(
        _ request: WorkServiceCreateWorkRequest
    ) async throws -> WorkServiceCreateWorkResponse {
        let response = try await base.createWork(request)
        await createResponseGate?.wait()
        return response
    }

    func createSession(
        _ request: WorkServiceCreateSessionRequest
    ) async throws -> WorkServiceCreateSessionResponse {
        try await base.createSession(request)
    }

    func completeWork(
        _ request: WorkServiceCompleteWorkRequest
    ) async throws -> WorkServiceCommandReceipt {
        try await base.completeWork(request)
    }

    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        try await base.attach(request)
    }

    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        try await base.detach(request)
    }

    func updateCapabilities(
        _ request: WorkServiceUpdateCapabilitiesRequest
    ) async throws -> WorkServiceUpdateCapabilitiesResponse {
        try await base.updateCapabilities(request)
    }

    func acknowledgeRead(
        _ request: WorkServiceAcknowledgeReadRequest
    ) async throws -> WorkServiceAcknowledgeReadResponse {
        try await base.acknowledgeRead(request)
    }

    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        try await base.snapshot(request)
    }

    func eventsAfterCursor(
        _ request: WorkServiceEventsRequest
    ) async throws -> WorkServiceEventPage {
        try await base.eventsAfterCursor(request)
    }

    func historyBeforeCursor(
        _ request: WorkServiceHistoryRequest
    ) async throws -> WorkServiceHistoryPage {
        try await base.historyBeforeCursor(request)
    }

    func fetchArtifact(
        _ request: WorkServiceArtifactRequest
    ) async throws -> WorkServiceArtifactDescriptor {
        try await base.fetchArtifact(request)
    }

    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        try await base.fetchBody(request)
    }

    func cancelAgentHandle(_ request: WorkServiceAgentHandleCancelRequest) async throws
        -> WorkServiceAgentHandleCancelResponse {
        childCancelCallCount += 1
        let response = try await base.cancelAgentHandle(request)
        if childCancelCallCount == 1, let childCancelResponseError { throw childCancelResponseError }
        return response
    }

    func command(_ request: WorkServiceCommandRequest) async throws -> WorkServiceCommandReceipt {
        try await base.command(request)
    }
}

private func clientSessionEndpoint() -> WorkServiceTransportEndpoint {
    WorkServiceTransportEndpoint(
        path: FileManager.default.temporaryDirectory.appendingPathComponent(
            "wsc-" + String(UUID().uuidString.lowercased().prefix(8)) + ".sock").path)
}

private func clientSessionService(
    host: WorkHostRef, client: ClientRef
) -> InMemoryWorkService {
    InMemoryWorkService(
        host: host, instanceID: "client-session-instance", startIdentity: "client-session-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
}

func testWorkServiceClientSessionRejectsV4DiscoveryAndBackingHandshake() async throws {
    let host = WorkHostRef("client-session-v4-host")
    let client = ClientRef("client-session-v4-gui")
    let endpoint = clientSessionEndpoint()
    let instance = WorkHostInstanceRef(
        host: host, instanceID: "client-session-v4-instance",
        startIdentity: "client-session-v4-start")

    let factoryCalls = ClientSessionConnectionFactoryCounter()
    let discoveredV4 = try WorkServiceClientSession(
        locator: FixedWorkServiceHostLocator(location: WorkServiceHostLocation(
            host: host, expectedInstance: instance, protocolVersion: 4,
            transport: .unixSocket(endpoint))),
        client: client,
        connectionFactory: { _, _ in
            _ = await factoryCalls.next()
            throw WorkServiceTransportError.endpointUnavailable
        })
    do {
        _ = try await discoveredV4.connect()
        XCTFail("a structurally valid v4 discovery record must not connect")
    } catch WorkServiceClientSessionError.incompatibleProtocol {
        XCTAssertEqual(await discoveredV4.state, .incompatible(host))
    }
    XCTAssertEqual(await factoryCalls.observedCount(), 0)

    let v4Rejection = WorkServiceHandshakeResponse(
        accepted: false, negotiatedVersion: nil, supportedRange: 4 ... 4,
        host: host, hostInstance: instance,
        controlJournal: .workHost(host),
        controlCursor: JournalCursor(journal: .workHost(host), sequence: 0),
        capabilities: [], diagnostic: "unsupported Work service protocol version")
    let rejectedConnection = ClientSessionObservedConnection(
        base: WorkServiceUnixSocketClient(
            endpoint: endpoint, client: client, expectedHost: host),
        handshakeResponse: v4Rejection)
    let currentDiscovery = try WorkServiceClientSession(
        locator: FixedWorkServiceHostLocator(location: WorkServiceHostLocation(
            host: host, expectedInstance: instance,
            protocolVersion: WorkServiceProtocol.currentVersion,
            transport: .unixSocket(endpoint))),
        client: client,
        connectionFactory: { _, _ in rejectedConnection })
    do {
        _ = try await currentDiscovery.connect()
        XCTFail("a current discovery hint cannot upgrade a v4 backing handshake")
    } catch WorkServiceClientSessionError.incompatibleProtocol {
        XCTAssertEqual(await currentDiscovery.state, .incompatible(host))
    }
    XCTAssertTrue(await rejectedConnection.closeCount > 0)

    let remoteRejection = ClientSessionObservedConnection(
        base: WorkServiceUnixSocketClient(
            endpoint: endpoint, client: client, expectedHost: host),
        handshakeError: .remote(code: .unsupportedVersion, detail: nil))
    let remoteSession = try WorkServiceClientSession(
        locator: FixedWorkServiceHostLocator(location: WorkServiceHostLocation(
            host: host, expectedInstance: instance,
            protocolVersion: WorkServiceProtocol.currentVersion,
            transport: .unixSocket(endpoint))),
        client: client,
        connectionFactory: { _, _ in remoteRejection })
    do {
        _ = try await remoteSession.connect()
        XCTFail("a v4 transport rejection must map to the typed protocol fence")
    } catch WorkServiceClientSessionError.incompatibleProtocol {
        XCTAssertEqual(await remoteSession.state, .incompatible(host))
    }
    XCTAssertTrue(await remoteRejection.closeCount > 0)
}

func testWorkServiceClientSessionCoalescesConnectAndDisconnectsOnlyClient() async throws {
    let host = WorkHostRef("client-session-host")
    let client = ClientRef("client-session-gui")
    let endpoint = clientSessionEndpoint()
    defer { try? FileManager.default.removeItem(atPath: endpoint.path) }
    let service = clientSessionService(host: host, client: client)
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    do {
        try await server.start()
        let instance = await service.hostInstance
        let location = WorkServiceHostLocation(
            host: host, expectedInstance: instance,
            protocolVersion: WorkServiceProtocol.currentVersion,
            transport: .unixSocket(endpoint))
        let session = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: location), client: client)

        async let first = session.connect()
        async let second = session.connect()
        let (firstHandshake, secondHandshake) = try await (first, second)
        XCTAssertEqual(firstHandshake.hostInstance, instance)
        XCTAssertEqual(secondHandshake.hostInstance, instance)
        XCTAssertEqual(await session.state, .connected(instance))
        XCTAssertTrue(try await session.listWorks(
            WorkServiceListRequest(client: client)).works.isEmpty)

        await session.disconnect()
        XCTAssertEqual(await session.state, .disconnected)

        // Closing one GUI-side connection is not a daemon or Work lifecycle operation. A new
        // client connection can immediately handshake against the same service instance.
        let reconnected = try await session.connect()
        XCTAssertEqual(reconnected.hostInstance, instance)
        XCTAssertEqual(await session.state, .connected(instance))
        await session.disconnect()
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func testWorkServiceClientSessionFencesHostGenerationAndReconnectsAfterEOF() async throws {
    let host = WorkHostRef("client-session-fence-host")
    let client = ClientRef("client-session-fence-gui")
    let endpoint = clientSessionEndpoint()
    defer { try? FileManager.default.removeItem(atPath: endpoint.path) }
    let service = clientSessionService(host: host, client: client)
    var server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    do {
        try await server.start()
        let actual = await service.hostInstance
        let stale = WorkHostInstanceRef(
            host: host, instanceID: "stale-instance", startIdentity: "stale-start")
        let staleSession = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: WorkServiceHostLocation(
                host: host, expectedInstance: stale,
                protocolVersion: WorkServiceProtocol.currentVersion,
                transport: .unixSocket(endpoint))),
            client: client)
        do {
            _ = try await staleSession.connect()
            XCTFail("a descriptor from another host generation must not connect")
        } catch WorkServiceClientSessionError.hostInstanceMismatch {
            XCTAssertEqual(await staleSession.state, .incompatible(host))
        }

        let location = WorkServiceHostLocation(
            host: host, expectedInstance: actual,
            protocolVersion: WorkServiceProtocol.currentVersion,
            transport: .unixSocket(endpoint))
        let session = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: location), client: client)
        _ = try await session.connect()
        await server.stop()
        do {
            _ = try await session.listWorks(WorkServiceListRequest(client: client))
            XCTFail("a closed service transport must not return a page")
        } catch {
            XCTAssertEqual(await session.state, .reconnecting(host))
        }

        // Reconnection is explicit and performs a fresh exact handshake. No mutation is replayed.
        server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
        try await server.start()
        XCTAssertEqual(try await session.connect().hostInstance, actual)
        XCTAssertEqual(await session.state, .connected(actual))
        await session.disconnect()
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func testWorkServiceClientSessionDisconnectFencesCancellationInsensitiveConnect() async throws {
    let host = WorkHostRef("client-session-connect-race-host")
    let client = ClientRef("client-session-connect-race-gui")
    let endpoint = clientSessionEndpoint()
    defer { try? FileManager.default.removeItem(atPath: endpoint.path) }
    let service = clientSessionService(host: host, client: client)
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    do {
        try await server.start()
        let instance = await service.hostInstance
        let gate = ClientSessionGate()
        let observed = ClientSessionObservedConnection(base: WorkServiceUnixSocketClient(
            endpoint: endpoint, client: client, expectedHost: host))
        let session = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: WorkServiceHostLocation(
                host: host, expectedInstance: instance,
                protocolVersion: WorkServiceProtocol.currentVersion,
                transport: .unixSocket(endpoint))),
            client: client,
            connectionFactory: { _, _ in
                // CheckedContinuation deliberately ignores task cancellation. A future remote
                // dialer can have the same behavior while DNS/TLS is inside a system API.
                await gate.wait()
                return observed
            })

        let connecting = Task { try await session.connect() }
        await gate.waitUntilEntered()
        await session.disconnect()
        XCTAssertEqual(await session.state, .disconnected)
        await gate.release()
        do {
            _ = try await connecting.value
            XCTFail("a late connection must not resurrect a disconnected client session")
        } catch {
            XCTAssertTrue(true)
        }
        XCTAssertTrue(await observed.closeCount >= 1)
        XCTAssertEqual(await session.state, .disconnected)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func testWorkServiceClientSessionDoesNotReplayMutationAfterDisconnect() async throws {
    let host = WorkHostRef("client-session-mutation-race-host")
    let client = ClientRef("client-session-mutation-race-gui")
    let endpoint = clientSessionEndpoint()
    defer { try? FileManager.default.removeItem(atPath: endpoint.path) }
    let service = clientSessionService(host: host, client: client)
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    do {
        try await server.start()
        let instance = await service.hostInstance
        let responseGate = ClientSessionGate()
        let session = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: WorkServiceHostLocation(
                host: host, expectedInstance: instance,
                protocolVersion: WorkServiceProtocol.currentVersion,
                transport: .unixSocket(endpoint))),
            client: client,
            connectionFactory: { location, client in
                guard case .unixSocket(let endpoint) = location.transport else {
                    throw WorkServiceClientSessionError.unavailable
                }
                return ClientSessionObservedConnection(
                    base: WorkServiceUnixSocketClient(
                        endpoint: endpoint, client: client, expectedHost: location.host),
                    createResponseGate: responseGate)
            })
        let handshake = try await session.connect()
        let request = WorkServiceCreateWorkRequest(
            client: client, commandID: "create-once",
            causalControlCursor: handshake.controlCursor)
        let creating = Task { try await session.createWork(request) }
        await responseGate.waitUntilEntered()
        await session.disconnect()
        await responseGate.release()
        do {
            _ = try await creating.value
            XCTFail("a response from the disconnected generation must be superseded")
        } catch WorkServiceClientSessionError.superseded {
            XCTAssertTrue(true)
        }

        // The host admitted the mutation exactly once. Reconnect only observes that durable
        // result; WorkServiceClientSession never retries or fabricates a second Create call.
        let reconnected = try await session.connect()
        let page = try await session.listWorks(WorkServiceListRequest(client: client))
        XCTAssertEqual(page.works.count, 1)
        XCTAssertEqual(reconnected.controlCursor.sequence, 3)
        await session.disconnect()
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func testWorkServiceClientSessionDropsPoisonedIdentityConnection() async throws {
    let host = WorkHostRef("client-session-identity-host")
    let client = ClientRef("client-session-identity-gui")
    let endpoint = clientSessionEndpoint()
    defer { try? FileManager.default.removeItem(atPath: endpoint.path) }
    let service = clientSessionService(host: host, client: client)
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    let factoryCounter = ClientSessionConnectionFactoryCounter()
    do {
        try await server.start()
        let instance = await service.hostInstance
        let location = WorkServiceHostLocation(
            host: host, expectedInstance: instance,
            protocolVersion: WorkServiceProtocol.currentVersion,
            transport: .unixSocket(endpoint))
        let session = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: location), client: client,
            connectionFactory: { location, client in
                guard case .unixSocket(let endpoint) = location.transport else {
                    throw WorkServiceClientSessionError.unavailable
                }
                let ordinal = await factoryCounter.next()
                let base = WorkServiceUnixSocketClient(
                    endpoint: endpoint, client: client, expectedHost: location.host)
                if ordinal == 1 {
                    return ClientSessionObservedConnection(
                        base: base,
                        listError: .remote(
                            code: .identityMismatch,
                            detail: "simulated backend identity change"))
                }
                return ClientSessionObservedConnection(base: base)
            })

        _ = try await session.connect()
        do {
            _ = try await session.listWorks(WorkServiceListRequest(client: client))
            XCTFail("an identity-mismatch response must poison the cached connection")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .identityMismatch)
        }
        XCTAssertEqual(await session.state, .reconnecting(host))
        XCTAssertNil(await session.negotiatedHandshake)

        // Reconnect obtains a fresh socket and handshake. The poisoned first connection is not
        // retained, so a later read succeeds without changing the Work or replaying a command.
        let reconnected = try await session.connect()
        XCTAssertEqual(reconnected.hostInstance, instance)
        XCTAssertTrue(try await session.listWorks(
            WorkServiceListRequest(client: client)).works.isEmpty)
        XCTAssertEqual(await session.state, .connected(instance))
        await session.disconnect()
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func testWorkServiceClientSessionReconnectsAfterConnectionRequestBudgetIsExhausted() async throws {
    let host = WorkHostRef("client-session-request-budget-host")
    let client = ClientRef("client-session-request-budget-gui")
    let endpoint = clientSessionEndpoint()
    defer { try? FileManager.default.removeItem(atPath: endpoint.path) }
    let service = clientSessionService(host: host, client: client)
    let server = WorkServiceUnixSocketServer(
        endpoint: endpoint, service: service, maxRequestIDs: 2)
    do {
        try await server.start()
        let instance = await service.hostInstance
        let location = WorkServiceHostLocation(
            host: host, expectedInstance: instance,
            protocolVersion: WorkServiceProtocol.currentVersion,
            transport: .unixSocket(endpoint))
        let session = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: location), client: client)

        let handshake = try await session.connect()
        let first = try await session.createWork(.init(
            client: client, commandID: "request-budget-first",
            causalControlCursor: handshake.controlCursor))
        do {
            _ = try await session.createWork(.init(
                client: client, commandID: "request-budget-rejected",
                causalControlCursor: first.controlCursor))
            XCTFail("the exhausted connection must reject a request before service admission")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .connectionExhausted)
        }
        XCTAssertEqual(await session.state, .reconnecting(host))
        XCTAssertNil(await session.negotiatedHandshake)

        // Reconnection is explicit and opens a fresh socket. The rejected Create is neither
        // admitted by the service nor replayed by the client session.
        XCTAssertEqual(try await session.connect().hostInstance, instance)
        let page = try await session.listWorks(WorkServiceListRequest(client: client))
        XCTAssertEqual(page.works.map(\.work), [first.work.work])
        XCTAssertEqual(await session.state, .connected(instance))
        await session.disconnect()
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

func testWorkServiceClientSessionDoesNotReplayChildCancellation() async throws {
    let host = WorkHostRef("child-cancel-session-host")
    let client = ClientRef("child-cancel-session-gui")
    let endpoint = clientSessionEndpoint()
    defer { try? FileManager.default.removeItem(atPath: endpoint.path) }
    let service = clientSessionService(host: host, client: client)
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    let observed = ClientSessionObservedConnection(
        base: WorkServiceUnixSocketClient(endpoint: endpoint, client: client, expectedHost: host),
        childCancelResponseError: .remote(code: .transportClosed, detail: "fixture lost confirmation"))
    do {
        try await server.start()
        let instance = await service.hostInstance
        let session = try WorkServiceClientSession(
            locator: FixedWorkServiceHostLocator(location: .init(
                host: host, expectedInstance: instance,
                protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))),
            client: client, connectionFactory: { _, _ in observed })
        let handshake = try await session.connect()
        let created = try await session.createWork(.init(
            client: client, commandID: "child-cancel-session-create",
            causalControlCursor: handshake.controlCursor,
            requestedCapabilities: [.observe, .control, .cancel]))
        let request = WorkServiceAgentHandleCancelRequest(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, handle: HandleRef("unknown-child"),
            commandID: "one-child-cancel", client: client,
            sessionAttachment: created.sessionAttachment, causalWorkCursor: created.workCursor)
        do {
            _ = try await session.cancelAgentHandle(request)
            XCTAssertTrue(false, "lost response must remain a connection error")
        } catch WorkServiceTransportError.remote(let code, _) {
            XCTAssertEqual(code, .transportClosed)
        }
        XCTAssertEqual(await observed.childCancelCallCount, 1)
        XCTAssertEqual(await session.state, .reconnecting(host))
        _ = try await session.connect()
        _ = try await session.listWorks(.init(client: client))
        XCTAssertEqual(await observed.childCancelCallCount, 1, "reconnect must not replay cancellation")

        let foreign = WorkServiceAgentHandleCancelRequest(
            work: request.work, journal: request.journal, attachment: request.attachment,
            handle: request.handle, commandID: "foreign", client: ClientRef("foreign-gui"),
            sessionAttachment: created.sessionAttachment, causalWorkCursor: request.causalWorkCursor)
        do {
            _ = try await session.cancelAgentHandle(foreign)
            XCTAssertTrue(false, "foreign client must be rejected before transport")
        } catch WorkServiceClientSessionError.invalidClient { XCTAssertTrue(true) }
        XCTAssertEqual(await observed.childCancelCallCount, 1)
        let explicit = try await session.cancelAgentHandle(request)
        XCTAssertEqual(explicit.disposition, .rejected)
        XCTAssertEqual(await observed.childCancelCallCount, 2)
        await session.disconnect()
    } catch {
        await observed.close()
        await server.stop()
        throw error
    }
    await server.stop()
}

let casesWorkServiceClientSession: [Case] = [
    ("phase5 Work service client fences v4 discovery and backing handshakes", {
        try await testWorkServiceClientSessionRejectsV4DiscoveryAndBackingHandshake()
    }),
    ("phase5 child cancellation client: explicit retry only after lost response", {
        try await testWorkServiceClientSessionDoesNotReplayChildCancellation()
    }),
    ("phase3 Work service client coalesces connect and disconnects only itself", {
        try await testWorkServiceClientSessionCoalescesConnectAndDisconnectsOnlyClient()
    }),
    ("phase3 Work service client fences generations and reconnects after EOF", {
        try await testWorkServiceClientSessionFencesHostGenerationAndReconnectsAfterEOF()
    }),
    ("phase3 Work service client fences a late cancellation-insensitive connect", {
        try await testWorkServiceClientSessionDisconnectFencesCancellationInsensitiveConnect()
    }),
    ("phase3 Work service client never replays a superseded mutation", {
        try await testWorkServiceClientSessionDoesNotReplayMutationAfterDisconnect()
    }),
    ("phase3 Work service client drops an identity-mismatch connection", {
        try await testWorkServiceClientSessionDropsPoisonedIdentityConnection()
    }),
    ("phase3 Work service client reconnects after its request-ID budget is exhausted", {
        try await testWorkServiceClientSessionReconnectsAfterConnectionRequestBudgetIsExhausted()
    }),
]
