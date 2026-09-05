import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import AviaryCore

private final class RecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: Bool
    private let entry: JournalBackedWorkRecoveryEntry

    init(entry: JournalBackedWorkRecoveryEntry) {
        self.blocked = true
        self.entry = entry
    }

    func setBlocked(_ value: Bool) {
        lock.lock()
        blocked = value
        lock.unlock()
    }

    func scan() -> [JournalBackedWorkRecoveryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return blocked ? [entry] : []
    }
}

/// A deliberately wedged service call used to prove that shutdown admission is bounded. All
/// methods except the handshake are unreachable in this focused fixture; fatalError keeps the
/// stub explicit if the test accidentally exercises a different operation.
private actor HangingWorkService: WorkServiceClient {
    private(set) var handshakeEntered = false
    private var released = false

    func release() { released = true }

    func handshake(_ request: WorkServiceHandshakeRequest) async throws
        -> WorkServiceHandshakeResponse {
        handshakeEntered = true
        while !released {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw WorkServiceProtocolError.sourceIncomplete
    }

    func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        fatalError("unused hanging-service operation")
    }

    func describeWork(_ request: WorkServiceDescribeRequest) async throws
        -> WorkServiceWorkDescriptor {
        fatalError("unused hanging-service operation")
    }

    func createWork(_ request: WorkServiceCreateWorkRequest) async throws
        -> WorkServiceCreateWorkResponse {
        fatalError("unused hanging-service operation")
    }

    func createSession(_ request: WorkServiceCreateSessionRequest) async throws
        -> WorkServiceCreateSessionResponse {
        fatalError("unused hanging-service operation")
    }

    func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws
        -> WorkServiceCommandReceipt {
        fatalError("unused hanging-service operation")
    }

    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        fatalError("unused hanging-service operation")
    }

    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        fatalError("unused hanging-service operation")
    }

    func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws
        -> WorkServiceUpdateCapabilitiesResponse {
        fatalError("unused hanging-service operation")
    }

    func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws
        -> WorkServiceAcknowledgeReadResponse {
        fatalError("unused hanging-service operation")
    }

    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        fatalError("unused hanging-service operation")
    }

    func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws
        -> WorkServiceEventPage {
        fatalError("unused hanging-service operation")
    }

    func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws
        -> WorkServiceArtifactDescriptor {
        fatalError("unused hanging-service operation")
    }

    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        fatalError("unused hanging-service operation")
    }

    func command(_ request: WorkServiceCommandRequest) async throws
        -> WorkServiceCommandReceipt {
        fatalError("unused hanging-service operation")
    }
}

/// Holds one mutating request after it has crossed the admission fence. The gate test uses this
/// to prove that closeAndDrain waits for an already-admitted mutation instead of racing a final
/// recovery read or reopening admission while the mutation is still in flight.
private actor HangingMutationWorkService: WorkServiceClient {
    private(set) var createEntered = false
    private var released = false

    func release() { released = true }

    func handshake(_ request: WorkServiceHandshakeRequest) async throws
        -> WorkServiceHandshakeResponse {
        throw WorkServiceProtocolError.sourceIncomplete
    }

    func createWork(_ request: WorkServiceCreateWorkRequest) async throws
        -> WorkServiceCreateWorkResponse {
        createEntered = true
        while !released {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw WorkServiceProtocolError.sourceIncomplete
    }

    func createSession(_ request: WorkServiceCreateSessionRequest) async throws
        -> WorkServiceCreateSessionResponse {
        fatalError("unused hanging-mutation operation")
    }

    func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        fatalError("unused hanging-mutation operation")
    }

    func describeWork(_ request: WorkServiceDescribeRequest) async throws
        -> WorkServiceWorkDescriptor {
        fatalError("unused hanging-mutation operation")
    }

    func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws
        -> WorkServiceCommandReceipt {
        fatalError("unused hanging-mutation operation")
    }

    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        fatalError("unused hanging-mutation operation")
    }

    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        fatalError("unused hanging-mutation operation")
    }

    func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws
        -> WorkServiceUpdateCapabilitiesResponse {
        fatalError("unused hanging-mutation operation")
    }

    func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws
        -> WorkServiceAcknowledgeReadResponse {
        fatalError("unused hanging-mutation operation")
    }

    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        fatalError("unused hanging-mutation operation")
    }

    func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws
        -> WorkServiceEventPage {
        fatalError("unused hanging-mutation operation")
    }

    func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws
        -> WorkServiceArtifactDescriptor {
        fatalError("unused hanging-mutation operation")
    }

    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        fatalError("unused hanging-mutation operation")
    }

    func command(_ request: WorkServiceCommandRequest) async throws
        -> WorkServiceCommandReceipt {
        fatalError("unused hanging-mutation operation")
    }
}

private actor GateResult {
    private(set) var value: Bool?

    func set(_ value: Bool) {
        self.value = value
    }
}

private actor StartupGate {
    private(set) var entered = false
    private var released = false

    func waitUntilReleased() async {
        entered = true
        while !released {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func release() {
        released = true
    }
}

private actor RecoveryScanFailure {
    private var scans = 0

    func scan() throws -> [JournalBackedWorkRecoveryEntry] {
        scans += 1
        if scans >= 2 {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return []
    }
}

/// Returns a healthy startup scan, then holds the shutdown scan until a concurrent force-stop
/// has taken lifecycle ownership. The released scan deliberately reports a blocker so a stale
/// shutdown continuation would visibly resurrect `.running` on the old implementation.
private actor DelayedBlockingRecoveryScan {
    let blocker: JournalBackedWorkRecoveryEntry
    private var scans = 0
    private(set) var shutdownScanEntered = false
    private var released = false

    init(blocker: JournalBackedWorkRecoveryEntry) {
        self.blocker = blocker
    }

    func scan() async -> [JournalBackedWorkRecoveryEntry] {
        scans += 1
        guard scans > 1 else { return [] }
        shutdownScanEntered = true
        while !released {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return [blocker]
    }

    func release() { released = true }
}

private actor ReconstructabilityProbeRecorder {
    let result: Bool
    private(set) var calls = 0

    init(result: Bool) {
        self.result = result
    }

    func probe(_ template: WorkLaunchWorkTemplateRecord) -> Bool {
        calls += 1
        return result
    }
}

private struct DaemonProcessFixture {
    let root: URL
    let home: AgentHome
    let socketRoot: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "aviaryd-process-\(name)-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        // Darwin's sockaddr_un path is only 103 bytes. Keep this caller-supplied private root
        // short enough that the generation-specific socket remains representable even under a
        // long temporary-directory prefix.
        socketRoot = URL(fileURLWithPath: "/tmp/aviaryd-\(UUID().uuidString.lowercased())",
                          isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: socketRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    }
}

/// Terminate a child with a bounded graceful window, then force-stop if needed. On Darwin,
/// Foundation observes and reaps the child before `Process.isRunning` becomes false; this helper
/// never adds a second wait that could block behind an already-observed termination. Keeping it
/// synchronous also makes it safe to call from `defer`, including when an assertion or transport
/// call throws halfway through a process proof.
@discardableResult
private func terminateAndReap(_ process: Process, timeout: TimeInterval = 3) -> Bool {
    guard process.isRunning else {
        // On Darwin, `isRunning == false` means Foundation has already observed/reaped the
        // child. Calling waitUntilExit again can block even though the process is gone, so read
        // the status directly.
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
    process.terminate()
    let deadline = Date().addingTimeInterval(max(0, timeout))
    while process.isRunning && Date() < deadline { usleep(20_000) }
    guard process.isRunning else {
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
    // SIGKILL cannot be caught or refused. Observe Foundation's termination state for one final
    // bounded window, but never call waitUntilExit: on Darwin that call can deadlock after
    // isRunning has already become false.
    _ = kill(process.processIdentifier, SIGKILL)
    let killDeadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < killDeadline { usleep(20_000) }
    return false
}

private func daemonInMemoryResolver(
    recovery: @escaping @Sendable () -> [JournalBackedWorkRecoveryEntry] = { [] },
    executionMaterialAvailable: Bool = true
) -> WorkHostDaemonServiceResolver {
    WorkHostDaemonServiceResolver { _, host, instance, _ in
        let service = InMemoryWorkService(
            host: host,
            instanceID: instance.instanceID,
            startIdentity: instance.startIdentity,
            authorizer: WorkServiceCapabilityPolicy())
        return WorkHostDaemonServiceComposition(
            service: service,
            scanRecovery: recovery,
            executionMaterialAvailable: executionMaterialAvailable)
    }
}

func test_workHostDaemonCoordinatorUsesOneGenerationAndPublishesAfterHandshake() async throws {
    let fixture = try DaemonProcessFixture("coordinator")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }

    let coordinator = try WorkHostDaemonCoordinator(
        home: fixture.home,
        socketRoot: fixture.socketRoot,
        instanceID: "instance-test",
        startIdentity: "start-test",
        resolver: daemonInMemoryResolver())
    let before = await coordinator.snapshot()
    XCTAssertEqual(before.state, .prepared)
    XCTAssertEqual(before.hostInstance.instanceID, "instance-test")

    let descriptor = try await coordinator.start()
    let started = await coordinator.snapshot()
    XCTAssertEqual(started.state, .running)
    XCTAssertEqual(started.hostInstance, descriptor.hostInstance)
    XCTAssertFalse(descriptor.isLivenessProof)
    XCTAssertEqual(
        try WorkHostDaemonEndpointPublisher.discover(
            layout: WorkHostDaemonEndpointLayout(
                home: fixture.home, workHost: started.host,
                socketRoot: fixture.socketRoot)),
        descriptor)

    // A repeated start is a read of the same process generation, never a second listener or
    // second Work Host instance.
    XCTAssertEqual(try await coordinator.start(), descriptor)
    XCTAssertEqual((await coordinator.snapshot()).hostInstance, descriptor.hostInstance)
    try await coordinator.shutdown()
    XCTAssertEqual(await coordinator.state, .stopped)
    XCTAssertNil(
        try WorkHostDaemonEndpointPublisher.discover(
            layout: WorkHostDaemonEndpointLayout(
                home: fixture.home, workHost: started.host,
                socketRoot: fixture.socketRoot)))
}

func test_workHostDaemonCoordinatorRefusesShutdownForRecoveryRequiredWork() async throws {
    let fixture = try DaemonProcessFixture("shutdown-gate")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }
    let host = try fixture.home.requirePersistedWorkHost()
    let work = WorkRef(workHostID: host.workHostID, workID: "work-recovery")
    let gate = RecoveryGate(entry: JournalBackedWorkRecoveryEntry(
        work: work,
        journal: .work(work),
        disposition: .recoveryRequired,
        diagnostic: "active Run has no fresh liveness proof"))

    let coordinator = try WorkHostDaemonCoordinator(
        home: fixture.home,
        socketRoot: fixture.socketRoot,
        resolver: daemonInMemoryResolver(recovery: { gate.scan() }))
    _ = try await coordinator.start()
    do {
        try await coordinator.shutdown()
        XCTFail("ordinary shutdown must refuse recovery-required Work")
    } catch WorkHostDaemonCoordinatorError.shutdownRefused(let works) {
        XCTAssertEqual(works, [work])
    }
    XCTAssertEqual(await coordinator.state, .running)
    XCTAssertNotNil(await coordinator.descriptor)

    gate.setBlocked(false)
    try await coordinator.shutdown()
    XCTAssertEqual(await coordinator.state, .stopped)
}

func test_workHostDaemonAdmissionGateClosesAndReopensWithoutReplayingRequests() async throws {
    let fixture = try DaemonProcessFixture("admission")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }
    let host = try fixture.home.requirePersistedWorkHost()
    let service = InMemoryWorkService(
        host: host, instanceID: "instance-admission", startIdentity: "start-admission",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [ClientRef("gate-test"): [.observe]]))
    let gate = WorkHostDaemonAdmissionGate(service: service)
    _ = try await gate.handshake(WorkServiceHandshakeRequest(client: ClientRef("gate-test")))
    await gate.closeAndDrain()
    XCTAssertFalse(await gate.isAccepting)
    do {
        _ = try await gate.listWorks(WorkServiceListRequest(client: ClientRef("gate-test")))
        XCTFail("closed admission must not forward a request")
    } catch WorkHostDaemonAdmissionGate.Error.closed {
        // Expected: a request arriving after the barrier is rejected, not replayed later.
    }
    await gate.reopen()
    XCTAssertTrue(await gate.isAccepting)
    _ = try await gate.listWorks(WorkServiceListRequest(client: ClientRef("gate-test")))
}

func test_workHostDaemonAdmissionGateDrainsInFlightMutationBeforeReopening() async throws {
    let service = HangingMutationWorkService()
    let gate = WorkHostDaemonAdmissionGate(service: service)
    let request = WorkServiceCreateWorkRequest(
        client: ClientRef("mutation-test"), commandID: "create-mutation", causalControlCursor:
            JournalCursor(journal: .workHost(WorkHostRef("mutation-host")), sequence: 0))
    let mutation = Task { try await gate.createWork(request) }
    let enteredDeadline = Date().addingTimeInterval(2)
    while !(await service.createEntered) && Date() < enteredDeadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(await service.createEntered)

    let result = GateResult()
    let close = Task {
        let value = await gate.closeAndDrain(timeout: 1)
        await result.set(value)
        return value
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(await gate.isAccepting)
    // The drain cannot complete while the admitted mutator is held. This assertion is made
    // before release, so a future implementation which snapshots and proceeds concurrently is
    // observable rather than silently passing.
    XCTAssertNil(await result.value)
    await service.release()
    XCTAssertTrue(await close.value)
    do {
        _ = try await mutation.value
        XCTFail("held mutation should finish with the fixture's source-incomplete error")
    } catch {
        XCTAssertEqual(error as? WorkServiceProtocolError, .sourceIncomplete)
    }
    await gate.reopen()
    XCTAssertTrue(await gate.isAccepting)
}

func test_workHostDaemonAdmissionGateTimesOutOnHungRequest() async throws {
    let service = HangingWorkService()
    let gate = WorkHostDaemonAdmissionGate(service: service)
    let task = Task {
        try await gate.handshake(WorkServiceHandshakeRequest(client: ClientRef("hung-test")))
    }
    let enteredDeadline = Date().addingTimeInterval(2)
    while !(await service.handshakeEntered) && Date() < enteredDeadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(await service.handshakeEntered)
    XCTAssertFalse(await gate.closeAndDrain(timeout: 0.05))
    XCTAssertFalse(await gate.isAccepting)
    await service.release()
    _ = try? await task.value
    await gate.reopen()
    XCTAssertTrue(await gate.isAccepting)
}

func test_workHostDaemonForceStopAbsorbsDelayedStartup() async throws {
    let fixture = try DaemonProcessFixture("delayed-start")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }
    let startup = StartupGate()
    let resolver = WorkHostDaemonServiceResolver { _, host, instance, _ in
        await startup.waitUntilReleased()
        let service = InMemoryWorkService(
            host: host, instanceID: instance.instanceID, startIdentity: instance.startIdentity,
            authorizer: WorkServiceCapabilityPolicy())
        return WorkHostDaemonServiceComposition(service: service, scanRecovery: { [] })
    }
    let coordinator = try WorkHostDaemonCoordinator(
        home: fixture.home, socketRoot: fixture.socketRoot, resolver: resolver)
    let start = Task { try await coordinator.start() }
    let enteredDeadline = Date().addingTimeInterval(2)
    while !(await startup.entered) && Date() < enteredDeadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(await startup.entered)
    await coordinator.forceStop()
    await startup.release()
    do {
        _ = try await start.value
        XCTFail("a force-stopped startup must not publish a daemon")
    } catch WorkHostDaemonCoordinatorError.invalidState(.stopped) {
        // Expected: startup observed the absorbing stop fence.
    } catch {
        XCTFail("unexpected delayed-start failure: \(error)")
    }
    XCTAssertEqual(await coordinator.state, .stopped)
    XCTAssertNil(await coordinator.descriptor)
    let host = try fixture.home.requirePersistedWorkHost()
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(
        layout: WorkHostDaemonEndpointLayout(
            home: fixture.home, workHost: host, socketRoot: fixture.socketRoot)))
}

func test_workHostDaemonRuntimeStopAbsorbsDelayedHandshake() async throws {
    let fixture = try DaemonProcessFixture("delayed-handshake")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }
    let host = try fixture.home.requirePersistedWorkHost()
    let service = HangingWorkService()
    let runtime = try WorkHostDaemonRuntime(
        home: fixture.home,
        hostInstance: WorkHostInstanceRef(
            host: host, instanceID: "instance-delayed-handshake", startIdentity: "start-delayed-handshake"),
        service: service, socketRoot: fixture.socketRoot)
    let start = Task { try await runtime.start() }
    let enteredDeadline = Date().addingTimeInterval(2)
    while !(await service.handshakeEntered) && Date() < enteredDeadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(await service.handshakeEntered)
    await runtime.stop()
    await service.release()
    do {
        _ = try await start.value
        XCTFail("a stopped runtime must not publish after a delayed handshake")
    } catch WorkHostDaemonRuntimeError.invalidState(.stopped) {
        // Expected: the runtime startup fence absorbed the stop.
    } catch WorkHostDaemonRuntimeError.startupFailed(_) {
        // The delayed fixture releases by throwing sourceIncomplete; the important invariant is
        // that the runtime remains stopped and never publishes the listener.
    } catch {
        XCTFail("unexpected delayed-handshake failure: \(error)")
    }
    XCTAssertEqual(await runtime.state, .stopped)
    XCTAssertNil(await runtime.descriptor)
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(
        layout: WorkHostDaemonEndpointLayout(home: fixture.home, workHost: host,
                                              socketRoot: fixture.socketRoot)))
}

func test_workHostDaemonShutdownScanFailureKeepsEndpointUntilExplicitForceStop() async throws {
    let fixture = try DaemonProcessFixture("scan-failure")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }
    let failure = RecoveryScanFailure()
    let resolver = WorkHostDaemonServiceResolver { _, host, instance, _ in
        let service = InMemoryWorkService(
            host: host, instanceID: instance.instanceID, startIdentity: instance.startIdentity,
            authorizer: WorkServiceCapabilityPolicy())
        return WorkHostDaemonServiceComposition(
            service: service, scanRecovery: { try await failure.scan() })
    }
    let coordinator = try WorkHostDaemonCoordinator(
        home: fixture.home, socketRoot: fixture.socketRoot, resolver: resolver)
    let descriptor = try await coordinator.start()
    do {
        try await coordinator.shutdown()
        XCTFail("an unexpected recovery read failure must not claim shutdown")
    } catch WorkServiceProtocolError.sourceIncomplete {
        // The coordinator remains available so a future GUI can retry observation.
    }
    XCTAssertEqual(await coordinator.state, .running)
    XCTAssertEqual(await coordinator.descriptor, descriptor)
    XCTAssertNotNil(try WorkHostDaemonEndpointPublisher.discover(
        layout: WorkHostDaemonEndpointLayout(
            home: fixture.home, workHost: descriptor.hostInstance.host,
            socketRoot: fixture.socketRoot)))
    await coordinator.forceStop()
    XCTAssertEqual(await coordinator.state, .stopped)
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(
        layout: WorkHostDaemonEndpointLayout(
            home: fixture.home, workHost: descriptor.hostInstance.host,
            socketRoot: fixture.socketRoot)))
}

func test_workHostDaemonForceStopOwnsSuspendedShutdown() async throws {
    let fixture = try DaemonProcessFixture("force-stop-shutdown")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }
    let host = try fixture.home.requirePersistedWorkHost()
    let work = WorkRef(workHostID: host.workHostID, workID: "force-stop-blocker")
    let scan = DelayedBlockingRecoveryScan(blocker: JournalBackedWorkRecoveryEntry(
        work: work,
        journal: .work(work),
        disposition: .recoveryRequired,
        diagnostic: "delayed blocker must not resurrect a force-stopped daemon"))
    let resolver = WorkHostDaemonServiceResolver { _, resolvedHost, instance, _ in
        let service = InMemoryWorkService(
            host: resolvedHost,
            instanceID: instance.instanceID,
            startIdentity: instance.startIdentity,
            authorizer: WorkServiceCapabilityPolicy())
        return WorkHostDaemonServiceComposition(
            service: service,
            scanRecovery: { await scan.scan() })
    }
    let coordinator = try WorkHostDaemonCoordinator(
        home: fixture.home, socketRoot: fixture.socketRoot, resolver: resolver)
    _ = try await coordinator.start()

    let shutdown = Task { try await coordinator.shutdown() }
    let enteredDeadline = Date().addingTimeInterval(2)
    while !(await scan.shutdownScanEntered) && Date() < enteredDeadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(await scan.shutdownScanEntered)
    await coordinator.forceStop()
    await scan.release()
    do {
        try await shutdown.value
    } catch {
        XCTFail("superseded shutdown must be absorbed by force-stop: \(error)")
    }
    XCTAssertEqual(await coordinator.state, .stopped)
    XCTAssertNil(await coordinator.descriptor)
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(
        layout: WorkHostDaemonEndpointLayout(
            home: fixture.home, workHost: host, socketRoot: fixture.socketRoot)))
}

func test_workHostDaemonDurableResolverUsesRunFreeReconstructabilityProbe() async throws {
    for expected in [true, false] {
        let fixture = try DaemonProcessFixture("probe-\(expected)")
        let client = ClientRef("probe-client")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: fixture.socketRoot)
        }
        let probe = ReconstructabilityProbeRecorder(result: expected)
        let resolver = WorkHostDaemonServiceResolver.durable(
            authorizer: WorkServiceCapabilityPolicy(
                grantsByClient: [client: Set(WorkServiceCapability.allCases)]),
            draftResolver: { request in
                WorkLaunchManifestDraft(
                    workspace: WorkLaunchWorkspace(
                        locator: fixture.root.path, policy: .temporary),
                    runtime: WorkLaunchRuntime(
                        providerID: request.configuration.providerID ?? "probe-provider",
                        modelID: request.configuration.modelID ?? "probe-model",
                        runtimeVariant: "probe"),
                    configuration: request.configuration,
                    requestedCapabilities: request.requestedCapabilities,
                    provenance: WorkLaunchManifestProvenance(source: "daemon-probe-test"))
            },
            hostedResolver: { _, _, _ in nil },
            promptAssemblyResolver: { _, _, _ in
                let source = try PromptSource(
                    sourceID: "daemon-probe-prompt", kind: .generated,
                    label: "daemon probe prompt", fullBody: "probe",
                    deliveredBody: "probe", renderedBody: "probe")
                return try SystemPromptAssembly(text: "probe", sources: [source])
            },
            reconstructabilityProbe: { template in await probe.probe(template) })
        let host = try fixture.home.requirePersistedWorkHost()
        let composition = try await resolver.open(
            home: fixture.home, host: host,
            instance: WorkHostInstanceRef(
                host: host, instanceID: "probe-instance-\(expected)",
                startIdentity: "probe-start-\(expected)"), environment: [:])
        let cursor = try await composition.service.handshake(
            WorkServiceHandshakeRequest(client: client)).controlCursor
        _ = try await composition.service.createWork(WorkServiceCreateWorkRequest(
            client: client, commandID: "probe-create-\(expected)",
            causalControlCursor: cursor,
            configuration: WorkServiceWorkConfiguration(
                providerID: "probe-provider", modelID: "probe-model"),
            requestedCapabilities: [.observe, .control, .start]))
        let recovery = try await composition.scanRecovery()
        XCTAssertEqual(recovery.first?.disposition,
                       expected ? .idleReconstructable : .recoveryRequired)
        XCTAssertTrue(await probe.calls > 0)
    }
}

func test_workHostDaemonRefusesShutdownWhenIdleProjectionCannotBeReconstructed() async throws {
    let fixture = try DaemonProcessFixture("unresolved-idle")
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }
    let host = try fixture.home.requirePersistedWorkHost()
    let work = WorkRef(workHostID: host.workHostID, workID: "work-unresolved-idle")
    let entry = JournalBackedWorkRecoveryEntry(
        work: work, journal: .work(work), disposition: .idleReconstructable,
        diagnostic: "manifest metadata exists but provider resolver is absent")
    let coordinator = try WorkHostDaemonCoordinator(
        home: fixture.home,
        socketRoot: fixture.socketRoot,
        resolver: daemonInMemoryResolver(
            recovery: { [entry] }, executionMaterialAvailable: false))
    _ = try await coordinator.start()
    let snapshot = await coordinator.snapshot()
    XCTAssertEqual(snapshot.recovery.first?.disposition, .recoveryRequired)
    do {
        try await coordinator.shutdown()
        XCTFail("idle metadata without execution material is not a stop proof")
    } catch WorkHostDaemonCoordinatorError.shutdownRefused(let works) {
        XCTAssertEqual(works, [work])
    }
    XCTAssertEqual(await coordinator.state, .running)
    await coordinator.forceStop()
}

/// Launch the production resolver path with a pre-existing registry. This catches accidentally
/// shipping the old unavailable-service stub, resolving runtime assets only from a source-tree
/// cwd, or silently promoting the daemon process cwd into the host catalog. Provider execution is
/// covered by the deterministic subprocess fixture below; this proof deliberately exercises normal
/// mode with no explicit --workspace registration request.
func test_aviarydNormalModeServesDurableCatalogWithoutCwdPromotion() async throws {
    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
    let executable = testExecutable.deletingLastPathComponent().appending(path: "aviaryd")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw NSError(
            domain: "AviarySelfTest.WorkHostDaemonProcess",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey:
                "aviaryd product is not beside AviarySelfTest; build --product aviaryd first"])
    }
    let fixture = try DaemonProcessFixture("normal-mode")
    let workspace = fixture.root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let registry = try WorkHostWorkspaceRegistry(home: fixture.home)
    let registeredWorkspace = try registry.registerLocalDirectory(
        workspace, label: "Persisted workspace", isDefault: true)
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = [
        "--agent-home", fixture.home.root.path,
        "--socket-root", fixture.socketRoot.path,
        "--instance-id", "instance-normal-mode",
        "--start-identity", "start-normal-mode",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        terminateAndReap(process)
    }

    let host = try fixture.home.requirePersistedWorkHost()
    let layout = WorkHostDaemonEndpointLayout(
        home: fixture.home, workHost: host, socketRoot: fixture.socketRoot)
    var descriptor: WorkHostDaemonDescriptor?
    let readyDeadline = Date().addingTimeInterval(15)
    while Date() < readyDeadline && process.isRunning {
        descriptor = try? WorkHostDaemonEndpointPublisher.discover(layout: layout)
        if descriptor != nil { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    let published = try XCTUnwrap(descriptor)
    XCTAssertEqual(published.hostInstance.instanceID, "instance-normal-mode")

    let client = WorkServiceUnixSocketClient(
        endpoint: published.endpoint, client: ClientRef("normal-mode-client"), expectedHost: host)
    let handshake = try await client.connect(build: "normal-mode-process-test")
    XCTAssertEqual(handshake.hostInstance, published.hostInstance)
    XCTAssertEqual(handshake.workspaceCatalog.entries.map(\.workspaceID), [registeredWorkspace.workspaceID])
    XCTAssertEqual(handshake.workspaceCatalog.defaultWorkspace?.workspaceID, registeredWorkspace.workspaceID)
    let page = try await client.listWorks(WorkServiceListRequest(
        client: ClientRef("normal-mode-client")))
    XCTAssertTrue(page.works.isEmpty)
    await client.close()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(process.isRunning)

    let exitedGracefully = terminateAndReap(process, timeout: 8)
    XCTAssertTrue(exitedGracefully, "normal daemon should honor explicit SIGTERM")
    XCTAssertFalse(process.isRunning)
    // Foundation may report the child stopped before its final async cleanup has become visible
    // to this process. Wait only for the bounded endpoint-removal proof; do not turn discovery
    // into an unbounded sleep or treat a stale descriptor as harmless.
    var endpointRemoved = false
    let cleanupDeadline = Date().addingTimeInterval(2)
    while Date() < cleanupDeadline {
        if try WorkHostDaemonEndpointPublisher.discover(layout: layout) == nil {
            endpointRemoved = true
            break
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertTrue(endpointRemoved)
    let afterRestart = try WorkHostWorkspaceRegistry(home: fixture.home).catalog()
    XCTAssertEqual(afterRestart.entries.map(\.workspaceID), [registeredWorkspace.workspaceID])
    XCTAssertEqual(afterRestart.defaultWorkspace?.workspaceID, registeredWorkspace.workspaceID)
}

/// Launch the actual `aviaryd` executable, rather than an actor or an in-process transport. The
/// product is a required prerequisite; an absent binary is a test failure, never a skip.
///
/// The blocking provider is selected only by the explicit daemon test mode. Create and Start
/// still travel through the durable manifest store and JournalBackedWorkService, and the two
/// clients use the Unix transport on opposite sides of a real process/client disconnect.
func test_aviarydSubprocessSurvivesClientExitAndSecondClientAttaches() async throws {
    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
    let executable = testExecutable.deletingLastPathComponent().appending(path: "aviaryd")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw NSError(
            domain: "AviarySelfTest.WorkHostDaemonProcess",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "aviaryd product is not beside AviarySelfTest; build --product aviaryd first"])
    }
    let fixture = try DaemonProcessFixture("subprocess")
    let releaseFile = fixture.root.appending(path: "release", directoryHint: .notDirectory)
    let workspace = fixture.root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }

    // `RuntimeHost.bundledPython` is intentionally resolved from the checkout passed to the
    // executable. This keeps the subprocess proof independent of the test process's actor state.
    let sourcePath = URL(fileURLWithPath: #filePath, isDirectory: false)
    let repositoryRoot = sourcePath.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard FileManager.default.fileExists(
        atPath: repositoryRoot.appending(path: "runtime-hosts/python3/host.py").path) else {
        throw NSError(
            domain: "AviarySelfTest.WorkHostDaemonProcess",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey:
                "could not locate the repository runtime host for the subprocess test"])
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = [
        "--agent-home", fixture.home.root.path,
        "--socket-root", fixture.socketRoot.path,
        "--instance-id", "instance-subprocess",
        "--start-identity", "start-subprocess",
        "--test-blocking",
        "--test-parent-lease",
        "--runtime-repo", repositoryRoot.path,
        "--release-file", releaseFile.path,
        "--workspace", workspace.path,
    ]
    // Keep this write end open for the subprocess lifetime. If this test runner is killed, the
    // kernel closes it and aviaryd's test-only parent lease force-stops the orphaned transport.
    let parentLease = Pipe()
    process.standardInput = parentLease
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? parentLease.fileHandleForWriting.close()
        // A failed test may intentionally leave live/recovery Work, so the daemon is correct to
        // refuse SIGTERM. The test cleanup must still be bounded and cannot turn that useful
        // failure into a hung test process.
        terminateAndReap(process)
    }

    let host = try fixture.home.requirePersistedWorkHost()
    let layout = WorkHostDaemonEndpointLayout(
        home: fixture.home, workHost: host, socketRoot: fixture.socketRoot)
    var descriptor: WorkHostDaemonDescriptor?
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline && process.isRunning {
        descriptor = try? WorkHostDaemonEndpointPublisher.discover(layout: layout)
        if descriptor != nil { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    let published = try XCTUnwrap(descriptor)
    XCTAssertEqual(published.hostInstance.instanceID, "instance-subprocess")
    XCTAssertFalse(published.isLivenessProof)

    let clientA = WorkServiceUnixSocketClient(
        endpoint: published.endpoint, client: ClientRef("daemon-client-a"), expectedHost: host)
    let handshakeA: WorkServiceHandshakeResponse
    do {
        handshakeA = try await clientA.connect(build: "process-test")
    } catch {
        throw UnwrapFailure(description: "daemon handshake response was invalid: \(error)")
    }
    let capabilities = Set(WorkServiceCapability.allCases)
    let workspaceID = try XCTUnwrap(handshakeA.workspaceCatalog.defaultWorkspace?.workspaceID)
    let create: WorkServiceCreateWorkResponse
    do {
        create = try await clientA.createWork(WorkServiceCreateWorkRequest(
            client: ClientRef("daemon-client-a"), commandID: "create-a",
            causalControlCursor: handshakeA.controlCursor,
            configuration: WorkServiceWorkConfiguration(
                providerID: "aviaryd-test-provider", modelID: "aviaryd-test-model",
                workspaceID: workspaceID),
            requestedCapabilities: capabilities))
    } catch {
        throw UnwrapFailure(description: "daemon Create response was invalid: \(error)")
    }
    XCTAssertEqual(create.work.execution, .idle)

    let start: WorkServiceCommandReceipt
    do {
        start = try await clientA.command(WorkServiceCommandRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: create.attachment.attachment,
            commandID: "start-a", client: ClientRef("daemon-client-a"),
            sessionAttachment: create.attachment.sessionAttachment,
            causalWorkCursor: create.workCursor, kind: .start, value: "block until release"))
    } catch {
        throw UnwrapFailure(description: "daemon Start response was invalid: \(error)")
    }
    XCTAssertEqual(start.state, .accepted)

    // A lost-response retry is a public service duplicate, not a second provider admission. The
    // same cursor/body/qualified command identity must reconcile to the original receipt while
    // the first Run is still preparing.
    let duplicateStart: WorkServiceCommandReceipt
    do {
        duplicateStart = try await clientA.command(WorkServiceCommandRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: create.attachment.attachment,
            commandID: "start-a", client: ClientRef("daemon-client-a"),
            sessionAttachment: create.attachment.sessionAttachment,
            causalWorkCursor: create.workCursor, kind: .start, value: "block until release"))
    } catch {
        throw UnwrapFailure(description: "daemon duplicate Start response was invalid: \(error)")
    }
    XCTAssertEqual(duplicateStart.state, .duplicate)
    XCTAssertEqual(duplicateStart.causalWorkCursor, start.causalWorkCursor)
    XCTAssertEqual(duplicateStart.resultingWorkCursor, start.resultingWorkCursor)
    XCTAssertEqual(duplicateStart.hostSequence, start.hostSequence)

    let launchStore = WorkLaunchManifestStore(home: fixture.home)
    let launchBinding = WorkBinding(
        session: create.session, work: create.work.work, workHost: host,
        sessionAttachment: create.sessionAttachment)
    let firstAssembly = try XCTUnwrap(
        launchStore.readCurrentSelection(for: launchBinding)?.record.manifest.promptAssembly)

    // Wait until the durable Work projection exposes the newly admitted Run. This verifies that
    // Start crossed the service boundary before the first client intentionally exits.
    var runningDescriptor = create.work
    let runningDeadline = Date().addingTimeInterval(20)
    while Date() < runningDeadline {
        do {
            runningDescriptor = try await clientA.describeWork(WorkServiceDescribeRequest(
                work: create.work.work, journal: create.work.journal,
                client: ClientRef("daemon-client-a")))
        } catch {
            throw UnwrapFailure(description: "daemon running descriptor was invalid: \(error)")
        }
        if runningDescriptor.currentRun != nil { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let run1 = try XCTUnwrap(runningDescriptor.currentRun)

    // A GUI/client EOF is not a lifecycle command. The daemon and its blocking provider remain
    // alive while client B establishes an independent attachment.
    await clientA.close()
    XCTAssertTrue(process.isRunning)
    let clientB = WorkServiceUnixSocketClient(
        endpoint: published.endpoint, client: ClientRef("daemon-client-b"), expectedHost: host)
    let handshakeB: WorkServiceHandshakeResponse
    do {
        handshakeB = try await clientB.connect(build: "process-test")
    } catch {
        throw UnwrapFailure(description: "second daemon handshake was invalid: \(error)")
    }
    let attached: WorkServiceAttachResponse
    do {
        attached = try await clientB.attach(WorkServiceAttachRequest(
            work: create.work.work, journal: create.work.journal,
            client: ClientRef("daemon-client-b"), session: create.session,
            sessionJournal: create.sessionJournal, sessionAttachment: create.sessionAttachment,
            commandID: "attach-b", causalControlCursor: handshakeB.controlCursor,
            requestedCapabilities: capabilities))
    } catch {
        throw UnwrapFailure(description: "second daemon attachment was invalid: \(error)")
    }
    let attachmentB = try XCTUnwrap(attached.attachment)
    XCTAssertEqual(attached.state, .accepted)
    let sessionSnapshot: WorkServiceSnapshot
    do {
        sessionSnapshot = try await clientB.snapshot(WorkServiceSnapshotRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: attachmentB.attachment,
            client: ClientRef("daemon-client-b"),
            target: .session(session: create.session, journal: create.sessionJournal)))
    } catch {
        throw UnwrapFailure(description: "second daemon Session snapshot was invalid: \(error)")
    }
    XCTAssertTrue(sessionSnapshot.events.contains { $0.session == create.session })

    // Release the provider only after the second client has observed the same Session. Prove the
    // provider's actual output and the canonical Work turn completion through cursor reads before
    // terminalizing the still-open Run.
    XCTAssertTrue(FileManager.default.createFile(atPath: releaseFile.path, contents: Data()))
    var workCursor = try XCTUnwrap(runningDescriptor.hostObservation?.servedCursor)
    var sessionCursor = try XCTUnwrap(sessionSnapshot.servedCursor)
    var turnFinished: TimelineEvent?
    var assistantMessage: TimelineEvent?
    let completionDeadline = Date().addingTimeInterval(10)
    while Date() < completionDeadline && (turnFinished == nil || assistantMessage == nil) {
        let workPage = try await clientB.eventsAfterCursor(WorkServiceEventsRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
            target: .work(journal: create.work.journal), afterCursor: workCursor))
        if let served = workPage.servedCursor { workCursor = served }
        turnFinished = turnFinished ?? workPage.events.first {
            $0.type == TimelineEventType.turnFinished
        }
        let sessionPage = try await clientB.eventsAfterCursor(WorkServiceEventsRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
            target: .session(session: create.session, journal: create.sessionJournal),
            afterCursor: sessionCursor))
        if let served = sessionPage.servedCursor { sessionCursor = served }
        assistantMessage = assistantMessage ?? sessionPage.events.first {
            $0.type == TimelineEventType.messageCommitted
        }
        if turnFinished == nil || assistantMessage == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    XCTAssertNotNil(turnFinished)
    let committed = try XCTUnwrap(assistantMessage)
    guard case .object(let messagePayload) = committed.payload,
          let bodyValue = messagePayload["message_body_ref"] else {
        throw UnwrapFailure(description: "completed assistant message must retain a body reference")
    }
    let messageBodyReference = try JSONDecoder().decode(
        TimelineBodyReference.self, from: JSONEncoder().encode(bodyValue))
    let messageBody = try await clientB.fetchBody(WorkServiceBodyRequest(
        work: create.work.work, journal: create.work.journal,
        attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
        reference: messageBodyReference))
    XCTAssertEqual(messageBody.status, .retained)
    let messageBodyData = try XCTUnwrap(messageBody.data)
    XCTAssertTrue(
        String(data: messageBodyData, encoding: .utf8)?.contains(
            "daemon process survived client exit") == true)
    let endCursor = workCursor
    let end = try await clientB.command(WorkServiceCommandRequest(
        work: create.work.work, journal: create.work.journal,
        attachment: attachmentB.attachment, commandID: "end-b",
        client: ClientRef("daemon-client-b"), sessionAttachment: attachmentB.sessionAttachment,
        causalWorkCursor: endCursor, kind: .end))
    XCTAssertEqual(end.state, .accepted)
    var endedDescriptor = try await clientB.describeWork(WorkServiceDescribeRequest(
        work: create.work.work, journal: create.work.journal,
        client: ClientRef("daemon-client-b")))
    let endedDeadline = Date().addingTimeInterval(20)
    while Date() < endedDeadline {
        endedDescriptor = try await clientB.describeWork(WorkServiceDescribeRequest(
            work: create.work.work, journal: create.work.journal,
            client: ClientRef("daemon-client-b")))
        if endedDescriptor.currentRun == nil { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertNil(endedDescriptor.currentRun)
    let terminalWorkPage = try await clientB.eventsAfterCursor(WorkServiceEventsRequest(
        work: create.work.work, journal: create.work.journal,
        attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
        target: .work(journal: create.work.journal), afterCursor: endCursor))
    XCTAssertTrue(terminalWorkPage.events.contains { $0.type == TimelineEventType.runFinished })

    // End releases only the current actor. The Work remains reusable through the same daemon,
    // and a replacement Start gets one new Run while retaining the predecessor's exact prompt
    // assembly for native cold replay.
    // End's receipt cursor is the immutable command-acceptance point; the asynchronous
    // run.finished marker may already be present in this terminal page. Start must use the
    // canonical current tip, not the earlier acceptance cursor.
    let replacementCursor = try XCTUnwrap(terminalWorkPage.servedCursor ?? end.resultingWorkCursor)
    let replacement = try await clientB.command(WorkServiceCommandRequest(
        work: create.work.work, journal: create.work.journal,
        attachment: attachmentB.attachment, commandID: "start-c",
        client: ClientRef("daemon-client-b"), sessionAttachment: attachmentB.sessionAttachment,
        causalWorkCursor: replacementCursor, kind: .start, value: "replacement start"))
    XCTAssertEqual(replacement.state, .accepted)
    XCTAssertEqual(replacement.outcome, .started)
    var replacementDescriptor = try await clientB.describeWork(WorkServiceDescribeRequest(
        work: create.work.work, journal: create.work.journal,
        client: ClientRef("daemon-client-b")))
    let replacementDeadline = Date().addingTimeInterval(20)
    while Date() < replacementDeadline {
        replacementDescriptor = try await clientB.describeWork(WorkServiceDescribeRequest(
            work: create.work.work, journal: create.work.journal,
            client: ClientRef("daemon-client-b")))
        if replacementDescriptor.currentRun != nil { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    let run2 = try XCTUnwrap(replacementDescriptor.currentRun)
    XCTAssertNotEqual(run2, run1)
    let replacementSelection = try XCTUnwrap(
        launchStore.readCurrentSelection(for: launchBinding)?.record.manifest)
    XCTAssertEqual(replacementSelection.promptAssembly, firstAssembly)
    XCTAssertEqual(
        replacementSelection.initialInputBodyReference?.digest,
        "sha256:" + AviarySHA256.hash(data: Data("replacement start".utf8))
            .map { String(format: "%02x", $0) }.joined())

    // `currentRun` only proves that the opener crossed the Run marker. Continue reading the
    // canonical work/session journals until the asynchronous AgentRunner preparation and first
    // provider turn have both produced durable delivery/output evidence.
    var replacementWorkReadCursor = try XCTUnwrap(replacement.resultingWorkCursor)
    var replacementSessionReadCursor = sessionCursor
    var replacementDelivered = false
    var replacementTurnFinished: TimelineEvent?
    var replacementAssistant: TimelineEvent?
    let replacementOutputDeadline = Date().addingTimeInterval(20)
    while Date() < replacementOutputDeadline
            && (!replacementDelivered || replacementTurnFinished == nil || replacementAssistant == nil) {
        let workPage = try await clientB.eventsAfterCursor(WorkServiceEventsRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
            target: .work(journal: create.work.journal), afterCursor: replacementWorkReadCursor))
        if let served = workPage.servedCursor { replacementWorkReadCursor = served }
        replacementDelivered = replacementDelivered || workPage.events.contains {
            $0.type == TimelineEventType.commandDelivered
                && $0.run == run2
        }
        replacementTurnFinished = replacementTurnFinished ?? workPage.events.first {
            $0.type == TimelineEventType.turnFinished && $0.run == run2
        }
        let sessionPage = try await clientB.eventsAfterCursor(WorkServiceEventsRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
            target: .session(session: create.session, journal: create.sessionJournal),
            afterCursor: replacementSessionReadCursor))
        if let served = sessionPage.servedCursor { replacementSessionReadCursor = served }
        replacementAssistant = replacementAssistant ?? sessionPage.events.first {
            $0.type == TimelineEventType.messageCommitted && $0.run == run2
        }
        if !replacementDelivered || replacementTurnFinished == nil || replacementAssistant == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    XCTAssertTrue(replacementDelivered)
    XCTAssertNotNil(replacementTurnFinished)
    let replacementMessage = try XCTUnwrap(replacementAssistant)
    guard case .object(let replacementPayload) = replacementMessage.payload,
          let replacementBodyValue = replacementPayload["message_body_ref"] else {
        throw UnwrapFailure(description: "replacement assistant message must retain a body reference")
    }
    let replacementBodyReference = try JSONDecoder().decode(
        TimelineBodyReference.self, from: JSONEncoder().encode(replacementBodyValue))
    let replacementBody = try await clientB.fetchBody(WorkServiceBodyRequest(
        work: create.work.work, journal: create.work.journal,
        attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
        reference: replacementBodyReference))
    XCTAssertEqual(replacementBody.status, .retained)
    XCTAssertTrue(String(data: try XCTUnwrap(replacementBody.data), encoding: .utf8)?.contains(
        "daemon process survived client exit") == true)
    let replacementDuplicate = try await clientB.command(WorkServiceCommandRequest(
        work: create.work.work, journal: create.work.journal,
        attachment: attachmentB.attachment, commandID: "start-c", client: ClientRef("daemon-client-b"),
        sessionAttachment: attachmentB.sessionAttachment,
        causalWorkCursor: replacementCursor, kind: .start, value: "replacement start"))
    XCTAssertEqual(replacementDuplicate.state, .duplicate)
    XCTAssertEqual(replacementDuplicate.resultingWorkCursor, replacement.resultingWorkCursor)

    // Explicitly End Run 2 before asserting terminal cardinality. A second run.started without
    // its paired run.finished would only prove admission, not the reusable Work lifecycle.
    var replacementEnd: WorkServiceCommandReceipt?
    for attempt in 0..<8 {
        do {
            replacementEnd = try await clientB.command(WorkServiceCommandRequest(
                work: create.work.work, journal: create.work.journal,
                attachment: attachmentB.attachment, commandID: "end-c",
                client: ClientRef("daemon-client-b"),
                sessionAttachment: attachmentB.sessionAttachment,
                causalWorkCursor: replacementWorkReadCursor, kind: .end))
            break
        } catch WorkServiceProtocolError.staleCursor where attempt < 7 {
            let refreshed = try await clientB.eventsAfterCursor(WorkServiceEventsRequest(
                work: create.work.work, journal: create.work.journal,
                attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
                target: .work(journal: create.work.journal),
                afterCursor: replacementWorkReadCursor))
            if let served = refreshed.servedCursor { replacementWorkReadCursor = served }
        }
    }
    let endedReplacement = try XCTUnwrap(replacementEnd)
    XCTAssertEqual(endedReplacement.state, .accepted)
    var replacementFinished = false
    let replacementEndDeadline = Date().addingTimeInterval(10)
    while Date() < replacementEndDeadline && !replacementFinished {
        let page = try await clientB.eventsAfterCursor(WorkServiceEventsRequest(
            work: create.work.work, journal: create.work.journal,
            attachment: attachmentB.attachment, client: ClientRef("daemon-client-b"),
            target: .work(journal: create.work.journal),
            afterCursor: replacementWorkReadCursor))
        if let served = page.servedCursor { replacementWorkReadCursor = served }
        replacementFinished = page.events.contains {
            $0.type == TimelineEventType.runFinished && $0.run == run2
        }
        if !replacementFinished {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    XCTAssertTrue(replacementFinished)

    let allWorkEvents = TimelineJournalReader.read(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(create.work.work)),
        journal: create.work.journal,
        actor: TimelineActor(actorID: "daemon-process-test-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertEqual(allWorkEvents.filter { $0.type == TimelineEventType.runStarted }.count, 2)
    XCTAssertEqual(allWorkEvents.filter { $0.type == TimelineEventType.runFinished }.count, 2)
    await clientB.close()

    // No client was connected for the signal path. Only this explicit supervisor request may
    // terminate the daemon; all earlier client EOFs left it serving.
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(process.isRunning)
    let exitedGracefully = terminateAndReap(process, timeout: 8)
    XCTAssertTrue(exitedGracefully, "daemon should honor SIGTERM after Work is ended")
    XCTAssertFalse(process.isRunning)
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(layout: layout))
}

/// The subprocess test harness owns aviaryd through an inherited pipe as well as ordinary
/// SIGTERM cleanup. Closing the parent end models the kernel behavior when AviarySelfTest is
/// abruptly killed: the daemon must remove its endpoint and exit instead of becoming a PID-1
/// orphan that keeps serving old test state.
func test_aviarydSubprocessParentLeasePreventsOrphans() async throws {
    let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
    let executable = testExecutable.deletingLastPathComponent().appending(path: "aviaryd")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw NSError(
            domain: "AviarySelfTest.WorkHostDaemonProcess",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey:
                "aviaryd product is not beside AviarySelfTest; build --product aviaryd first"])
    }
    let fixture = try DaemonProcessFixture("parent-lease")
    let releaseFile = fixture.root.appending(path: "release", directoryHint: .notDirectory)
    let workspace = fixture.root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: fixture.socketRoot)
    }

    let sourcePath = URL(fileURLWithPath: #filePath, isDirectory: false)
    let repositoryRoot = sourcePath.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let parentLease = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = [
        "--agent-home", fixture.home.root.path,
        "--socket-root", fixture.socketRoot.path,
        "--instance-id", "instance-parent-lease",
        "--start-identity", "start-parent-lease",
        "--test-blocking",
        "--test-parent-lease",
        "--runtime-repo", repositoryRoot.path,
        "--release-file", releaseFile.path,
        "--workspace", workspace.path,
    ]
    process.standardInput = parentLease
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? parentLease.fileHandleForWriting.close()
        // The normal assertion path below proves lease EOF termination. If an earlier assertion
        // throws, use the same bounded graceful-then-kill policy rather than an unconditional reap
        // that could hang behind a broken lease watcher.
        _ = terminateAndReap(process)
    }

    let host = try fixture.home.requirePersistedWorkHost()
    let layout = WorkHostDaemonEndpointLayout(
        home: fixture.home, workHost: host, socketRoot: fixture.socketRoot)
    var descriptor: WorkHostDaemonDescriptor?
    let readyDeadline = Date().addingTimeInterval(15)
    while Date() < readyDeadline && process.isRunning {
        descriptor = try? WorkHostDaemonEndpointPublisher.discover(layout: layout)
        if descriptor != nil { break }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertNotNil(descriptor)
    XCTAssertTrue(process.isRunning)

    try parentLease.fileHandleForWriting.close()
    let exitedGracefully = terminateAndReap(process, timeout: 8)
    XCTAssertTrue(exitedGracefully, "parent lease EOF should force-stop the daemon")
    XCTAssertFalse(process.isRunning)
    XCTAssertNil(try WorkHostDaemonEndpointPublisher.discover(layout: layout))
}

let casesWorkHostDaemonProcess: [Case] = [
    ("phase3 Work Host daemon: one generation publishes after handshake", {
        try await test_workHostDaemonCoordinatorUsesOneGenerationAndPublishesAfterHandshake()
    }),
    ("phase3 Work Host daemon: ordinary shutdown refuses recovery-required Work", {
        try await test_workHostDaemonCoordinatorRefusesShutdownForRecoveryRequiredWork()
    }),
    ("phase3 Work Host daemon: admission gate closes and reopens without replay", {
        try await test_workHostDaemonAdmissionGateClosesAndReopensWithoutReplayingRequests()
    }),
    ("phase3 Work Host daemon: admission gate drains an in-flight mutation", {
        try await test_workHostDaemonAdmissionGateDrainsInFlightMutationBeforeReopening()
    }),
    ("phase3 Work Host daemon: admission gate times out on hung request", {
        try await test_workHostDaemonAdmissionGateTimesOutOnHungRequest()
    }),
    ("phase3 Work Host daemon: force stop absorbs delayed startup", {
        try await test_workHostDaemonForceStopAbsorbsDelayedStartup()
    }),
    ("phase3 Work Host daemon: runtime stop absorbs delayed handshake", {
        try await test_workHostDaemonRuntimeStopAbsorbsDelayedHandshake()
    }),
    ("phase3 Work Host daemon: shutdown scan failure retains endpoint", {
        try await test_workHostDaemonShutdownScanFailureKeepsEndpointUntilExplicitForceStop()
    }),
    ("phase3 Work Host daemon: force stop absorbs suspended shutdown", {
        try await test_workHostDaemonForceStopOwnsSuspendedShutdown()
    }),
    ("phase3 Work Host daemon: durable resolver uses reconstructability probe", {
        try await test_workHostDaemonDurableResolverUsesRunFreeReconstructabilityProbe()
    }),
    ("phase3 Work Host daemon: unresolved idle projection blocks shutdown", {
        try await test_workHostDaemonRefusesShutdownWhenIdleProjectionCannotBeReconstructed()
    }),
    ("phase3 Work Host daemon: normal subprocess preserves durable catalog without cwd promotion", {
        try await test_aviarydNormalModeServesDurableCatalogWithoutCwdPromotion()
    }),
    ("phase3 Work Host daemon: real subprocess survives client exit and second client attaches", {
        try await test_aviarydSubprocessSurvivesClientExitAndSecondClientAttaches()
    }),
    ("phase3 Work Host daemon: subprocess parent lease prevents orphans", {
        try await test_aviarydSubprocessParentLeasePreventsOrphans()
    }),
]
