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

/// Reproduce the kernel artifact left when a daemon disappears without running listener cleanup:
/// a socket inode remains at the published path, but no descriptor is listening on it.
private func bootstrapLeaveStaleSocket(at url: URL) throws {
    let bytes = Data(url.path.utf8)
    guard !bytes.isEmpty, bytes.count <= 103 else {
        throw NSError(domain: "AviarySelfTest", code: 2)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    var nulTerminated = bytes
    nulTerminated.append(0)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        nulTerminated.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
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

func testWorkServiceClientIdentityUsesPrivateChildOfConventionalHome() throws {
    let root = try bootstrapScratchDirectory("identity-conventional-home")
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(chmod(root.path, mode_t(0o755)), 0)
    let home = AgentHome(root: root)
    let formerRootLevelFile = root.appending(
        path: "work-service-client-id", directoryHint: .notDirectory)

    let first = try WorkServiceClientIdentityStore(
        url: home.workServiceClientIdentityFile).loadOrCreate()
    XCTAssertFalse(FileManager.default.fileExists(atPath: formerRootLevelFile.path),
                   "opening the private store must not create or migrate a root-level identity")

    var rootInformation = stat()
    XCTAssertEqual(lstat(root.path, &rootInformation), 0)
    XCTAssertEqual(rootInformation.st_mode & mode_t(0o777), mode_t(0o755),
                   "identity creation must not chmod the existing AgentHome")
    var directoryInformation = stat()
    XCTAssertEqual(lstat(home.workServiceClientIdentityDirectory.path, &directoryInformation), 0)
    XCTAssertEqual(directoryInformation.st_mode & S_IFMT, mode_t(S_IFDIR))
    XCTAssertEqual(directoryInformation.st_mode & mode_t(0o777), mode_t(0o700))
    var fileInformation = stat()
    XCTAssertEqual(lstat(home.workServiceClientIdentityFile.path, &fileInformation), 0)
    XCTAssertEqual(fileInformation.st_mode & S_IFMT, mode_t(S_IFREG))
    XCTAssertEqual(fileInformation.st_mode & mode_t(0o777), mode_t(0o600))

    let reopened = try WorkServiceClientIdentityStore(
        url: home.workServiceClientIdentityFile).loadOrCreate()
    XCTAssertEqual(reopened, first)
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

func testLocalWorkServiceBootstrapRefusesV4DiscoveryWithoutLaunchingReplacement() async throws {
    let host = WorkHostRef("bootstrap-v4-host")
    let client = ClientRef("bootstrap-v4-client")
    let instance = WorkHostInstanceRef(
        host: host, instanceID: "bootstrap-v4-instance", startIdentity: "bootstrap-v4-start")
    let endpoint = WorkServiceTransportEndpoint(path: "/tmp/aviary-v4-published.sock")
    let launches = BootstrapLaunchCounter()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: BootstrapFixedLocator(location: WorkServiceHostLocation(
            host: host, expectedInstance: instance, protocolVersion: 4,
            transport: .unixSocket(endpoint))),
        client: client,
        launcher: { await launches.invoked() })

    do {
        _ = try await bootstrap.connect()
        XCTFail("a known v4 publication must be refused without launching over it")
    } catch LocalWorkServiceBootstrapError.connectionFailed(.incompatibleProtocol) {
        XCTAssertEqual(await bootstrap.session.state, .incompatible(host))
    }
    XCTAssertEqual(await launches.count, 0)
    await bootstrap.disconnect()
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

func testLocalWorkServiceBootstrapReplacesStaleDiscoveredEndpoint() async throws {
    let host = WorkHostRef("bootstrap-stale-host")
    let client = ClientRef("bootstrap-stale-client")
    let socketRoot = try bootstrapSocketRoot("stale-endpoint")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let staleEndpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "dead.sock", directoryHint: .notDirectory).path)
    try bootstrapLeaveStaleSocket(at: URL(fileURLWithPath: staleEndpoint.path))
    let freshEndpoint = WorkServiceTransportEndpoint(
        path: socketRoot.appending(path: "replacement.sock", directoryHint: .notDirectory).path)
    let service = InMemoryWorkService(
        host: host, instanceID: "bootstrap-stale-replacement-instance",
        startIdentity: "bootstrap-stale-replacement-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: Set(WorkServiceCapability.allCases)]))
    let instance = await service.hostInstance
    let stale = WorkServiceHostLocation(
        host: host,
        expectedInstance: WorkHostInstanceRef(
            host: host, instanceID: "bootstrap-dead-instance",
            startIdentity: "bootstrap-dead-start"),
        protocolVersion: WorkServiceProtocol.currentVersion,
        transport: .unixSocket(staleEndpoint))
    let fresh = WorkServiceHostLocation(
        host: host, expectedInstance: instance,
        protocolVersion: WorkServiceProtocol.currentVersion,
        transport: .unixSocket(freshEndpoint))
    let locator = BootstrapSequenceLocator([stale, fresh])
    let server = WorkServiceUnixSocketServer(endpoint: freshEndpoint, service: service)
    let launches = BootstrapLaunchCounter()
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: locator, client: client, timeout: 2, pollInterval: 0.005,
        launcher: {
            await launches.invoked()
            try await server.start()
        })

    let session = try await bootstrap.connect()
    XCTAssertEqual(await launches.count, 1)
    XCTAssertEqual(await session.state, .connected(instance))
    await bootstrap.disconnect()
    await server.stop()
}

func testLocalWorkServiceBootstrapPreservesSafeLauncherFailure() async throws {
    let bootstrap = try LocalWorkServiceBootstrap(
        locator: BootstrapFixedLocator(location: nil),
        client: ClientRef("bootstrap-launch-error-client"),
        launcher: { throw LocalAviaryDaemonLauncherError.executableNotFound })
    do {
        _ = try await bootstrap.connect()
        XCTFail("a missing approved daemon executable must remain distinguishable")
    } catch LocalWorkServiceBootstrapError.launcherFailed(let error) {
        XCTAssertEqual(error, .executableNotFound)
        XCTAssertEqual(
            error.errorDescription,
            "The Aviary Work Host executable was not found in an approved location.")
    } catch {
        XCTFail("unexpected launcher failure classification")
    }
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
    ("phase3 local Work service client identity uses a private conventional-home child", {
        try testWorkServiceClientIdentityUsesPrivateChildOfConventionalHome()
    }),
    ("phase3 local Work service client identity rejects malformed/private records", {
        try await testWorkServiceClientIdentityRejectsMalformedAndPrivateBoundaryViolations()
    }),
    ("phase3 local Work service bootstrap accepts an existing daemon without launching", {
        try await testLocalWorkServiceBootstrapAcceptsExistingDaemonWithoutLaunching()
    }),
    ("phase5 local Work service bootstrap refuses v4 without replacement", {
        try await testLocalWorkServiceBootstrapRefusesV4DiscoveryWithoutLaunchingReplacement()
    }),
    ("phase3 local Work service bootstrap coalesces a racing daemon launch", {
        try await testLocalWorkServiceBootstrapCoalescesLaunchAndAcceptsRacingDaemon()
    }),
    ("phase3 local Work service bootstrap replaces a stale discovered endpoint", {
        try await testLocalWorkServiceBootstrapReplacesStaleDiscoveredEndpoint()
    }),
    ("phase3 local Work service bootstrap preserves safe launcher failures", {
        try await testLocalWorkServiceBootstrapPreservesSafeLauncherFailure()
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
