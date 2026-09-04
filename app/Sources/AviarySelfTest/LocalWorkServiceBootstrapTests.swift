import Foundation
import Darwin
@testable import AviaryCore

private struct BootstrapFixedLocator: WorkServiceHostLocating {
    let location: WorkServiceHostLocation?
    func locate() async throws -> WorkServiceHostLocation? { location }
}

private actor BootstrapLocator: WorkServiceHostLocating {
    private var location: WorkServiceHostLocation?

    func publish(_ location: WorkServiceHostLocation) { self.location = location }
    func locate() async throws -> WorkServiceHostLocation? { location }
}

private actor BootstrapSequenceLocator: WorkServiceHostLocating {
    private var locations: [WorkServiceHostLocation?]

    init(_ locations: [WorkServiceHostLocation?]) { self.locations = locations }

    func locate() async throws -> WorkServiceHostLocation? {
        guard locations.count > 1 else { return locations.first ?? nil }
        return locations.removeFirst()
    }
}

private actor BootstrapLaunchCounter {
    private(set) var count = 0
    func invoked() { count += 1 }
}

private actor BootstrapCancellationGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForRelease() async {
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        let releases = releaseWaiters
        releaseWaiters.removeAll()
        releases.forEach { $0.resume() }
    }
}

private func bootstrapScratchDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "aviary-bootstrap-\(name)-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    chmod(url.path, mode_t(0o700))
    return url
}

private func bootstrapSocketRoot(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/aviary-bs-\(name)-\(UUID().uuidString.prefix(8))",
                  isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    chmod(url.path, mode_t(0o700))
    return url
}

func testWorkServiceClientIdentityIsStableAndAtomic() async throws {
    let root = try bootstrapScratchDirectory("identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkServiceClientIdentityStore(
        url: root.appending(path: "client-id", directoryHint: .notDirectory))
    let first = try store.loadOrCreate()
    let second = try store.loadOrCreate()
    XCTAssertEqual(first, second)
    XCTAssertTrue(first.clientID.hasPrefix("client-"))
    var information = stat()
    XCTAssertEqual(lstat(store.url.path, &information), 0)
    XCTAssertEqual(information.st_mode & S_IFMT, mode_t(S_IFREG))
    XCTAssertEqual(information.st_mode & mode_t(0o077), 0)
    let bytes = try Data(contentsOf: store.url)
    XCTAssertEqual(bytes.count, first.clientID.utf8.count + 1)
}

func testWorkServiceClientIdentityRejectsMalformedAndPrivateBoundaryViolations() async throws {
    let root = try bootstrapScratchDirectory("identity-errors")
    defer { try? FileManager.default.removeItem(at: root) }
    let malformed = root.appending(path: "client-id", directoryHint: .notDirectory)
    XCTAssertTrue(FileManager.default.createFile(
        atPath: malformed.path, contents: Data("client-foreign\n".utf8),
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]))
    let malformedStore = try WorkServiceClientIdentityStore(url: malformed)
    do {
        _ = try malformedStore.loadOrCreate()
        XCTFail("an existing malformed identity must not rotate")
    } catch WorkServiceClientIdentityError.invalidRecord {
        XCTAssertTrue(true)
    }

    let target = root.appending(path: "identity-target", directoryHint: .notDirectory)
    let link = root.appending(path: "identity-link", directoryHint: .notDirectory)
    XCTAssertTrue(FileManager.default.createFile(
        atPath: target.path,
        contents: Data("client-00000000-0000-4000-8000-000000000000\n".utf8),
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]))
    XCTAssertEqual(symlink(target.path, link.path), 0)
    do {
        _ = try WorkServiceClientIdentityStore(url: link).loadOrCreate()
        XCTFail("identity storage must not follow a symlink")
    } catch WorkServiceClientIdentityError.invalidRecord {
        XCTAssertTrue(true)
    }

    let publicRoot = root.appending(path: "public", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: publicRoot, withIntermediateDirectories: true)
    chmod(publicRoot.path, mode_t(0o755))
    do {
        _ = try WorkServiceClientIdentityStore(
            url: publicRoot.appending(path: "client-id", directoryHint: .notDirectory))
            .loadOrCreate()
        XCTFail("identity storage must reject a non-private directory")
    } catch WorkServiceClientIdentityError.accessDenied {
        XCTAssertTrue(true)
    }
}

func testLocalWorkServiceBootstrapAcceptsExistingDaemonWithoutLaunching() async throws {
    let host = WorkHostRef("bootstrap-existing-host")
    let client = ClientRef("bootstrap-existing-client")
    let socketRoot = try bootstrapSocketRoot("existing")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let endpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "service.sock", directoryHint: .notDirectory).path)
    let service = InMemoryWorkService(
        host: host, instanceID: "bootstrap-existing-instance", startIdentity: "bootstrap-existing-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    try await server.start()
    defer { Task { await server.stop() } }
    let instance = await service.hostInstance
    let location = WorkServiceHostLocation(
        host: host, expectedInstance: instance,
        protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))
    let launches = BootstrapLaunchCounter()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: BootstrapFixedLocator(location: location), client: client,
        launcher: { await launches.invoked() })
    let session = try await bootstrap.connect()
    XCTAssertEqual(await session.state, .connected(instance))
    XCTAssertEqual(await launches.count, 0)
    await bootstrap.disconnect()
    XCTAssertEqual(await session.state, .disconnected)
}

func testLocalWorkServiceBootstrapCoalescesLaunchAndAcceptsRacingDaemon() async throws {
    let host = WorkHostRef("bootstrap-race-host")
    let client = ClientRef("bootstrap-race-client")
    let socketRoot = try bootstrapSocketRoot("race")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let endpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "service.sock", directoryHint: .notDirectory).path)
    let service = InMemoryWorkService(
        host: host, instanceID: "bootstrap-race-instance", startIdentity: "bootstrap-race-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    let instance = await service.hostInstance
    let location = WorkServiceHostLocation(
        host: host, expectedInstance: instance,
        protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))
    let locator = BootstrapLocator()
    let launches = BootstrapLaunchCounter()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: locator, client: client, timeout: 2, pollInterval: 0.005,
        launcher: {
            await launches.invoked()
            try await server.start()
            await locator.publish(location)
        })

    async let first = bootstrap.connect()
    async let second = bootstrap.connect()
    let (firstSession, secondSession) = try await (first, second)
    XCTAssertTrue(firstSession === secondSession)
    XCTAssertEqual(await launches.count, 1)
    XCTAssertEqual(await firstSession.state, .connected(instance))
    await bootstrap.disconnect()
    await server.stop()
}

func testLocalWorkServiceBootstrapRediscoveriesAfterStaleGeneration() async throws {
    let host = WorkHostRef("bootstrap-rediscovery-host")
    let client = ClientRef("bootstrap-rediscovery-client")
    let socketRoot = try bootstrapSocketRoot("rediscovery")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let endpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "service.sock", directoryHint: .notDirectory).path)
    let service = InMemoryWorkService(
        host: host, instanceID: "bootstrap-rediscovery-instance", startIdentity: "bootstrap-rediscovery-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    try await server.start()
    defer { Task { await server.stop() } }
    let current = await service.hostInstance
    let stale = WorkHostInstanceRef(
        host: host, instanceID: "stale-rediscovery-instance", startIdentity: "stale-rediscovery-start")
    let freshLocation = WorkServiceHostLocation(
        host: host, expectedInstance: current,
        protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))
    let staleLocation = WorkServiceHostLocation(
        host: host, expectedInstance: stale,
        protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))
    let launches = BootstrapLaunchCounter()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: BootstrapSequenceLocator([staleLocation, freshLocation]), client: client,
        timeout: 1, pollInterval: 0.005,
        launcher: { await launches.invoked() })
    let session = try await bootstrap.connect()
    XCTAssertEqual(await session.state, .connected(current))
    XCTAssertEqual(await launches.count, 0)
    await bootstrap.disconnect()
}

func testLocalWorkServiceBootstrapReportsLaunchTimeoutAndDoesNotOwnDaemon() async throws {
    let locator = BootstrapLocator()
    let client = ClientRef("bootstrap-timeout-client")
    let launches = BootstrapLaunchCounter()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: locator, client: client, timeout: 0.02, pollInterval: 0.005,
        launcher: { await launches.invoked() })
    do {
        _ = try await bootstrap.connect()
        XCTFail("a launcher which never publishes a discoverable daemon must time out")
    } catch LocalWorkServiceBootstrapError.timedOut {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(await launches.count, 1)
    await bootstrap.disconnect()
}

func testLocalWorkServiceBootstrapBoundsCancellationInsensitiveLauncher() async throws {
    let locator = BootstrapLocator()
    let gate = BootstrapCancellationGate()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: locator, client: ClientRef("bootstrap-launch-bound-client"),
        timeout: 0.02, pollInterval: 0.005,
        launcher: {
            await gate.enter()
            await gate.waitForRelease()
        })
    let started = Date()
    do {
        _ = try await bootstrap.connect()
        XCTFail("the public timeout must include a nonreturning launcher")
    } catch LocalWorkServiceBootstrapError.timedOut {
        XCTAssertTrue(true)
    }
    XCTAssertTrue(Date().timeIntervalSince(started) < 0.5)
    XCTAssertEqual(await bootstrap.session.state, .unavailable(nil))
    await gate.release()
    await bootstrap.disconnect()
}

func testLocalWorkServiceBootstrapDisconnectFencesCancellationInsensitiveLauncher() async throws {
    let locator = BootstrapLocator()
    let gate = BootstrapCancellationGate()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: locator, client: ClientRef("bootstrap-cancel-client"), timeout: 1,
        launcher: {
            await gate.enter()
            await gate.waitForRelease()
        })
    let connecting = Task { try await bootstrap.connect() }
    await gate.waitUntilEntered()
    await bootstrap.disconnect()
    await gate.release()
    do {
        _ = try await connecting.value
        XCTFail("a cancellation-insensitive launcher must not reconnect after disconnect")
    } catch LocalWorkServiceBootstrapError.canceled {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(await bootstrap.session.state, .disconnected)
}

func testLocalWorkServiceBootstrapDisconnectSupersedesCompletedSharedAttempt() async throws {
    let host = WorkHostRef("bootstrap-completion-race-host")
    let client = ClientRef("bootstrap-completion-race-client")
    let socketRoot = try bootstrapSocketRoot("completion-race")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let endpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "service.sock", directoryHint: .notDirectory).path)
    let service = InMemoryWorkService(
        host: host, instanceID: "bootstrap-completion-race-instance",
        startIdentity: "bootstrap-completion-race-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    try await server.start()
    defer { Task { await server.stop() } }
    let instance = await service.hostInstance
    let location = WorkServiceHostLocation(
        host: host, expectedInstance: instance,
        protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))
    let gate = BootstrapCancellationGate()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: BootstrapFixedLocator(location: location), client: client,
        attemptCompletionGate: {
            await gate.enter()
            await gate.waitForRelease()
        })

    let connecting = Task { try await bootstrap.connect() }
    await gate.waitUntilEntered()
    XCTAssertEqual(await bootstrap.session.state, .connected(instance))
    await bootstrap.disconnect()
    await gate.release()
    do {
        _ = try await connecting.value
        XCTFail("disconnect must supersede a connected attempt before it can publish success")
    } catch LocalWorkServiceBootstrapError.canceled {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(await bootstrap.session.state, .disconnected)
}

func testLocalWorkServiceBootstrapCancelsOneWaiterWithoutCancelingSharedAttempt() async throws {
    let host = WorkHostRef("bootstrap-waiter-cancel-host")
    let client = ClientRef("bootstrap-waiter-cancel-client")
    let socketRoot = try bootstrapSocketRoot("waiter-cancel")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let endpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "service.sock", directoryHint: .notDirectory).path)
    let service = InMemoryWorkService(
        host: host, instanceID: "bootstrap-waiter-cancel-instance",
        startIdentity: "bootstrap-waiter-cancel-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    let instance = await service.hostInstance
    let location = WorkServiceHostLocation(
        host: host, expectedInstance: instance,
        protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))
    let locator = BootstrapLocator()
    let gate = BootstrapCancellationGate()
    let launches = BootstrapLaunchCounter()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: locator, client: client, timeout: 2, pollInterval: 0.005,
        launcher: {
            await launches.invoked()
            await gate.enter()
            await gate.waitForRelease()
            try await server.start()
            await locator.publish(location)
        })

    let canceled = Task { try await bootstrap.connect() }
    await gate.waitUntilEntered()
    let survivor = Task { try await bootstrap.connect() }
    await Task.yield()
    canceled.cancel()
    await gate.release()
    do {
        _ = try await canceled.value
        XCTFail("canceling one waiter must not return the shared connection")
    } catch LocalWorkServiceBootstrapError.canceled {
        XCTAssertTrue(true)
    }
    let connected = try await survivor.value
    XCTAssertEqual(await connected.state, .connected(instance))
    XCTAssertEqual(await launches.count, 1)
    await bootstrap.disconnect()
    await server.stop()
}

func testLocalWorkServiceBootstrapCancelingOnlyWaiterAbandonsAttempt() async throws {
    let locator = BootstrapLocator()
    let gate = BootstrapCancellationGate()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: locator, client: ClientRef("bootstrap-only-waiter-client"), timeout: 1,
        launcher: {
            await gate.enter()
            await gate.waitForRelease()
        })
    let connecting = Task { try await bootstrap.connect() }
    await gate.waitUntilEntered()
    connecting.cancel()
    do {
        _ = try await connecting.value
        XCTFail("canceling the only waiter must abandon its shared attempt")
    } catch LocalWorkServiceBootstrapError.canceled {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(await bootstrap.session.state, .disconnected)
    await gate.release()
    try await Task.sleep(nanoseconds: 10_000_000)
    XCTAssertEqual(await bootstrap.session.state, .disconnected)
}

func testLocalWorkServiceBootstrapCancellationSupersedesResolvedSuccess() async throws {
    let host = WorkHostRef("bootstrap-resolved-cancel-host")
    let client = ClientRef("bootstrap-resolved-cancel-client")
    let socketRoot = try bootstrapSocketRoot("resolved-cancel")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let endpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "service.sock", directoryHint: .notDirectory).path)
    let service = InMemoryWorkService(
        host: host, instanceID: "bootstrap-resolved-cancel-instance",
        startIdentity: "bootstrap-resolved-cancel-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
    let server = WorkServiceUnixSocketServer(endpoint: endpoint, service: service)
    try await server.start()
    defer { Task { await server.stop() } }
    let instance = await service.hostInstance
    let location = WorkServiceHostLocation(
        host: host, expectedInstance: instance,
        protocolVersion: WorkServiceProtocol.currentVersion, transport: .unixSocket(endpoint))
    let gate = BootstrapCancellationGate()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: BootstrapFixedLocator(location: location), client: client,
        attemptCompletionGate: nil,
        waiterResultGate: {
            await gate.enter()
            await gate.waitForRelease()
        })

    let connecting = Task { try await bootstrap.connect() }
    await gate.waitUntilEntered()
    XCTAssertEqual(await bootstrap.session.state, .connected(instance))
    connecting.cancel()
    await gate.release()
    do {
        _ = try await connecting.value
        XCTFail("waiter cancellation must supersede an already-resolved shared success")
    } catch LocalWorkServiceBootstrapError.canceled {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(await bootstrap.session.state, .disconnected)
}

let casesLocalWorkServiceBootstrap: [Case] = [
    ("phase3 local Work service client identity is stable and atomic", {
        try await testWorkServiceClientIdentityIsStableAndAtomic()
    }),
    ("phase3 local Work service client identity rejects malformed/private records", {
        try await testWorkServiceClientIdentityRejectsMalformedAndPrivateBoundaryViolations()
    }),
    ("phase3 local Work service bootstrap accepts an existing daemon without launching", {
        try await testLocalWorkServiceBootstrapAcceptsExistingDaemonWithoutLaunching()
    }),
    ("phase3 local Work service bootstrap coalesces a racing daemon launch", {
        try await testLocalWorkServiceBootstrapCoalescesLaunchAndAcceptsRacingDaemon()
    }),
    ("phase3 local Work service bootstrap rediscoveries after stale generation", {
        try await testLocalWorkServiceBootstrapRediscoveriesAfterStaleGeneration()
    }),
    ("phase3 local Work service bootstrap reports timeout explicitly", {
        try await testLocalWorkServiceBootstrapReportsLaunchTimeoutAndDoesNotOwnDaemon()
    }),
    ("phase3 local Work service bootstrap bounds a nonreturning launcher", {
        try await testLocalWorkServiceBootstrapBoundsCancellationInsensitiveLauncher()
    }),
    ("phase3 local Work service bootstrap fences a late launcher after disconnect", {
        try await testLocalWorkServiceBootstrapDisconnectFencesCancellationInsensitiveLauncher()
    }),
    ("phase3 local Work service bootstrap disconnect supersedes completed attempt", {
        try await testLocalWorkServiceBootstrapDisconnectSupersedesCompletedSharedAttempt()
    }),
    ("phase3 local Work service bootstrap caller cancellation preserves shared attempt", {
        try await testLocalWorkServiceBootstrapCancelsOneWaiterWithoutCancelingSharedAttempt()
    }),
    ("phase3 local Work service bootstrap lone cancellation abandons attempt", {
        try await testLocalWorkServiceBootstrapCancelingOnlyWaiterAbandonsAttempt()
    }),
    ("phase3 local Work service bootstrap cancellation supersedes resolved success", {
        try await testLocalWorkServiceBootstrapCancellationSupersedesResolvedSuccess()
    }),
]
