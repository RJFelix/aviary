import Foundation

@testable import AviaryCore

private actor ShutdownStartGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ShutdownScanGate {
    private var scanCount = 0
    private(set) var shutdownScanEntered = false
    private var released = false

    func scan() async -> [JournalBackedWorkRecoveryEntry] {
        scanCount += 1
        guard scanCount > 1 else { return [] }
        shutdownScanEntered = true
        while !released {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return []
    }

    func release() { released = true }
}

private actor ShutdownCompleteExecution: WorkAgentChildExecution {
    let childID: String

    init(childID: String) { self.childID = childID }

    func execute() async -> AgentChildExecutionResult {
        AgentChildExecutionResult(
            childID: childID, state: .succeeded, answer: "shutdown child complete",
            cleanup: AgentChildExecutionCleanup(
                runtimeSessionDestroyed: true, runtimeStopped: true, transcriptClosed: true))
    }

    func cancel() async -> AgentChildCancellationOutcome { .accepted }
}

private actor ShutdownIncompleteExecution: WorkAgentChildExecution {
    let childID: String

    init(childID: String) { self.childID = childID }

    func execute() async -> AgentChildExecutionResult {
        AgentChildExecutionResult(
            childID: childID, state: .failed, detail: "cleanup remains unconfirmed",
            cleanup: AgentChildExecutionCleanup(
                runtimeSessionDestroyed: false, runtimeStopped: false, transcriptClosed: true))
    }

    func cancel() async -> AgentChildCancellationOutcome { .accepted }
}

private struct ShutdownForeignCanceller: WorkServiceAgentHandleCancelling {
    func cancel(
        work: WorkRef, handle: HandleRef, command: CommandRef
    ) async throws -> WorkAgentChildCoordinator.CancellationResult {
        .unavailable
    }
}

private struct ShutdownChildRoute {
    let home: AgentHome
    let binding: WorkRunBinding
    let bundle: RunJournalBundle
}

private func shutdownChildRoute(
    coordinator: WorkAgentChildCoordinator, suffix: String
) async throws -> ShutdownChildRoute {
    let home = scratchHome()
    let host = try home.requirePersistedWorkHost()
    let binding = WorkRunBinding(
        workBinding: WorkBinding(
            session: SessionRef("shutdown-session-\(suffix)"),
            work: WorkRef(workHostID: host.workHostID, workID: "shutdown-work-\(suffix)"),
            workHost: host,
            sessionAttachment: SessionAttachmentRef("shutdown-attachment-\(suffix)")),
        run: RunRef("shutdown-run-\(suffix)"))
    try await coordinator.register(
        work: binding.workBinding.work, home: home,
        actor: TimelineActor(actorID: "shutdown-owner-\(suffix)", kind: "work-host"))
    let bundle = try await coordinator.openRun(work: binding.workBinding.work) {
        try await RunJournalBundle.openForExecution(
            home: home,
            identity: SessionWorkIdentity(
                sessionID: binding.workBinding.session.sessionID,
                work: binding.workBinding.work,
                runID: binding.run.runID),
            actorID: "shutdown-parent-\(suffix)",
            makeAttachmentID: { binding.workBinding.sessionAttachment.attachmentID })
    }
    return ShutdownChildRoute(home: home, binding: binding, bundle: bundle)
}

private func shutdownResolver(
    coordinator: WorkAgentChildCoordinator,
    recovery: @escaping @Sendable () async throws -> [JournalBackedWorkRecoveryEntry] = { [] }
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
            childCoordinator: coordinator)
    }
}

private func shutdownSocketRoot(_ suffix: String) throws -> URL {
    let root = URL(
        fileURLWithPath: "/tmp/acs-\(UUID().uuidString.lowercased())",
        isDirectory: true)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return root
}

private func shutdownDaemon(
    coordinator: WorkAgentChildCoordinator,
    home: AgentHome,
    socketRoot: URL,
    recovery: @escaping @Sendable () async throws -> [JournalBackedWorkRecoveryEntry] = { [] }
) throws -> WorkHostDaemonCoordinator {
    try WorkHostDaemonCoordinator(
        home: home, socketRoot: socketRoot,
        resolver: shutdownResolver(coordinator: coordinator, recovery: recovery))
}

private func waitForShutdownObservation(
    _ coordinator: WorkAgentChildCoordinator,
    _ predicate: @escaping (WorkAgentChildCoordinator.OwnerObservation) -> Bool
) async throws {
    for _ in 0..<600 {
        if predicate(await coordinator.ownerObservation()) { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "WorkAgentChildShutdownTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for child ownership observation"])
}

func testWorkAgentChildShutdownRefusesBeforeStartedOwnerAndThawsAdmission() async throws {
    let startGate = ShutdownStartGate()
    let coordinator = try WorkAgentChildCoordinator(beforeStartCommit: {
        await startGate.pause()
    })
    let route = try await shutdownChildRoute(coordinator: coordinator, suffix: "starting")
    let socketRoot = try shutdownSocketRoot("starting")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let daemon = try shutdownDaemon(
        coordinator: coordinator, home: route.home, socketRoot: socketRoot)

    let admissionTask = Task {
        try await coordinator.admit(
            origin: route.binding, prompt: "child held before started", label: "Starting child",
            deadline: Date().addingTimeInterval(30),
            makeExecution: { handle, _ in ShutdownCompleteExecution(childID: handle.handleID) })
    }
    for _ in 0..<600 {
        if await startGate.entered { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let startEntered = await startGate.entered
    XCTAssertTrue(startEntered, "the child must be owned before start commit")
    let startingObservation = await coordinator.ownerObservation()
    XCTAssertTrue(
        startingObservation.startingCount == 1,
        "the coordinator must report the pre-start owner even with an empty recovery scan")

    _ = try await daemon.start()
    do {
        try await daemon.shutdown()
        XCTAssertTrue(false, "shutdown must refuse a child owned before started commit")
    } catch WorkHostDaemonCoordinatorError.shutdownRefused(let works) {
        XCTAssertTrue(works == [route.binding.workBinding.work], "the owning Work must be named")
    } catch {
        XCTAssertTrue(false, "unexpected shutdown error: \(error)")
    }
    let thawedObservation = await coordinator.ownerObservation()
    XCTAssertTrue(
        !thawedObservation.admissionsFrozen,
        "a refusal must thaw the coordinator admission lease")

    await startGate.release()
    let first = try await admissionTask.value
    try await waitForShutdownObservation(coordinator) { $0.totalOwnedEntryCount == 0 }
    let second = try await coordinator.admit(
        origin: route.binding, prompt: "admission after refusal", label: "After refusal",
        deadline: Date().addingTimeInterval(30),
        makeExecution: { handle, _ in ShutdownCompleteExecution(childID: handle.handleID) })
    XCTAssertTrue(first.handle != second.handle, "thawed admission must accept a fresh Handle")
    try await waitForShutdownObservation(coordinator) { $0.totalOwnedEntryCount == 0 }
    await daemon.forceStop()
}

func testWorkAgentChildShutdownAfterQuiescenceKeepsAdmissionsFrozen() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let route = try await shutdownChildRoute(coordinator: coordinator, suffix: "quiesced")
    let admission = try await coordinator.admit(
        origin: route.binding, prompt: "quiesced child", label: "Quiesced child",
        deadline: Date().addingTimeInterval(30),
        makeExecution: { handle, _ in ShutdownCompleteExecution(childID: handle.handleID) })
    XCTAssertTrue(!admission.handle.handleID.isEmpty, "the fixture must admit a child")
    try await waitForShutdownObservation(coordinator) { $0.totalOwnedEntryCount == 0 }

    let socketRoot = try shutdownSocketRoot("quiesced")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let daemon = try shutdownDaemon(
        coordinator: coordinator, home: route.home, socketRoot: socketRoot)
    _ = try await daemon.start()
    try await daemon.shutdown()
    let quiescedDaemonState = await daemon.state
    XCTAssertTrue(quiescedDaemonState == .stopped, "quiesced child ownership must allow shutdown")
    let sealedObservation = await coordinator.ownerObservation()
    XCTAssertTrue(
        sealedObservation.admissionsFrozen && sealedObservation.admissionsSealed,
        "successful shutdown must retain the coordinator freeze")

    do {
        _ = try await coordinator.admit(
            origin: route.binding, prompt: "must remain frozen", label: "Frozen",
            deadline: Date().addingTimeInterval(30),
            makeExecution: { handle, _ in ShutdownCompleteExecution(childID: handle.handleID) })
        XCTAssertTrue(false, "a successful daemon shutdown must keep child admission frozen")
    } catch WorkAgentChildCoordinator.Failure.admissionsFrozen {
    } catch {
        XCTAssertTrue(false, "unexpected post-shutdown admission error: \(error)")
    }
}

func testWorkAgentChildShutdownRefusesTerminalUnquiescedOwner() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let route = try await shutdownChildRoute(coordinator: coordinator, suffix: "indeterminate")
    let admission = try await coordinator.admit(
        origin: route.binding, prompt: "cleanup is indeterminate", label: "Indeterminate child",
        deadline: Date().addingTimeInterval(30),
        makeExecution: { handle, _ in ShutdownIncompleteExecution(childID: handle.handleID) })
    XCTAssertTrue(!admission.handle.handleID.isEmpty, "the fixture must admit a child")
    try await waitForShutdownObservation(coordinator) { $0.terminalUnquiescedCount == 1 }

    let socketRoot = try shutdownSocketRoot("indeterminate")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let daemon = try shutdownDaemon(
        coordinator: coordinator, home: route.home, socketRoot: socketRoot)
    _ = try await daemon.start()
    do {
        try await daemon.shutdown()
        XCTAssertTrue(false, "terminal cleanup without proof must refuse shutdown")
    } catch WorkHostDaemonCoordinatorError.shutdownRefused(let works) {
        XCTAssertTrue(works == [route.binding.workBinding.work], "the owning Work must be named")
    } catch {
        XCTAssertTrue(false, "unexpected shutdown error: \(error)")
    }
    let observation = await coordinator.ownerObservation()
    XCTAssertTrue(observation.terminalUnquiescedCount == 1, "the cleanup slot must remain owned")
    XCTAssertTrue(!observation.admissionsFrozen, "refusal must thaw a terminal cleanup lease")
    await daemon.forceStop()
}

func testWorkAgentChildShutdownForceStopDoesNotThawSuspendedLease() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let route = try await shutdownChildRoute(coordinator: coordinator, suffix: "force-stop")
    let scan = ShutdownScanGate()
    let socketRoot = try shutdownSocketRoot("force-stop")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let daemon = try shutdownDaemon(
        coordinator: coordinator, home: route.home, socketRoot: socketRoot,
        recovery: { await scan.scan() })
    _ = try await daemon.start()

    let shutdown = Task { try await daemon.shutdown() }
    for _ in 0..<600 {
        if await scan.shutdownScanEntered { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let scanEntered = await scan.shutdownScanEntered
    XCTAssertTrue(scanEntered, "the final recovery scan must be suspended")
    let suspendedObservation = await coordinator.ownerObservation()
    XCTAssertTrue(
        suspendedObservation.admissionsFrozen,
        "shutdown must hold the child lease while the final scan is suspended")

    await daemon.forceStop()
    await scan.release()
    do {
        try await shutdown.value
    } catch {
        XCTAssertTrue(false, "force-stop must absorb the suspended shutdown: \(error)")
    }
    let forceStoppedState = await daemon.state
    XCTAssertTrue(forceStoppedState == .stopped, "force-stop must own the daemon lifecycle")
    let forceStoppedObservation = await coordinator.ownerObservation()
    XCTAssertTrue(
        forceStoppedObservation.admissionsFrozen && forceStoppedObservation.admissionsSealed,
        "force-stop must not thaw a stale shutdown lease")
    do {
        _ = try await coordinator.admit(
            origin: route.binding, prompt: "stale lease must hold", label: "Still frozen",
            deadline: Date().addingTimeInterval(30),
            makeExecution: { handle, _ in ShutdownCompleteExecution(childID: handle.handleID) })
        XCTAssertTrue(false, "stale force-stopped shutdown lease must remain frozen")
    } catch WorkAgentChildCoordinator.Failure.admissionsFrozen {
    } catch {
        XCTAssertTrue(false, "unexpected stale-lease admission error: \(error)")
    }
}

func testWorkAgentChildShutdownPublicCompositionAutoDerivesJBSOwner() async throws {
    let home = scratchHome()
    let host = try home.requirePersistedWorkHost()
    let coordinator = try WorkAgentChildCoordinator()
    let service = try JournalBackedWorkService(
        home: home, workHost: host, authorizer: WorkServiceCapabilityPolicy())
    try await service.installAgentHandleCanceller(coordinator)
    let composition = WorkHostDaemonServiceComposition(
        service: service, scanRecovery: { [] })

    let lease = try await composition.freezeChildAdmission()
    XCTAssertTrue(lease != nil, "public composition must derive the installed JBS coordinator")
    let frozen = await coordinator.ownerObservation()
    XCTAssertTrue(frozen.admissionsFrozen, "auto-derived JBS lease must freeze child admission")
    if let lease { await lease.reopen() }
    let reopened = await coordinator.ownerObservation()
    XCTAssertTrue(!reopened.admissionsFrozen, "a refused auto-derived lease must reopen admission")
}

func testWorkAgentChildShutdownPublicCompositionWithoutPilotLeavesJBSUnfrozen() async throws {
    let home = scratchHome()
    let host = try home.requirePersistedWorkHost()
    let service = try JournalBackedWorkService(
        home: home, workHost: host, authorizer: WorkServiceCapabilityPolicy())
    let composition = WorkHostDaemonServiceComposition(
        service: service, scanRecovery: { [] })
    let lease = try await composition.freezeChildAdmission()
    XCTAssertTrue(lease == nil, "a JBS service without the pilot must not invent child ownership")
}

func testWorkAgentChildShutdownCustomCancellerFailsClosed() async throws {
    let home = scratchHome()
    let host = try home.requirePersistedWorkHost()
    let service = try JournalBackedWorkService(
        home: home, workHost: host, authorizer: WorkServiceCapabilityPolicy())
    try await service.installAgentHandleCanceller(ShutdownForeignCanceller())
    let composition = WorkHostDaemonServiceComposition(
        service: service, scanRecovery: { [] })
    do {
        _ = try await composition.freezeChildAdmission()
        XCTAssertTrue(false, "a custom canceller without the coordinator must fail closed")
    } catch WorkServiceProtocolError.sourceIncomplete {
    } catch {
        XCTAssertTrue(false, "unexpected custom-canceller error: \(error)")
    }
}

func testWorkAgentChildShutdownSynchronousSealDefeatsQueuedThaw() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let lease = try await coordinator.makeShutdownLease()
    var tokens: [WorkAgentChildCoordinator.AdmissionFreezeToken] = []
    for _ in 1..<WorkAgentChildCoordinator.maximumAdmissionFreezeTokens {
        tokens.append(try await coordinator.freezeAdmissions())
    }
    do {
        _ = try await coordinator.freezeAdmissions()
        XCTFail("freeze token storage must stay bounded")
    } catch WorkAgentChildCoordinator.Failure.capacity {}
    lease.seal()
    let staleThaw = Task { await lease.reopen() }
    await staleThaw.value
    for token in tokens { XCTAssertFalse(await coordinator.thawAdmissions(token)) }
    let observation = await coordinator.ownerObservation()
    XCTAssertTrue(
        observation.admissionsSealed && observation.admissionsFrozen,
        "a thaw queued after synchronous seal must not reopen child admission")
}

let casesWorkAgentChildShutdown: [Case] = [
    ("phase5 child shutdown: pre-start owner refuses and thaws", {
        try await testWorkAgentChildShutdownRefusesBeforeStartedOwnerAndThawsAdmission()
    }),
    ("phase5 child shutdown: quiesced owner shuts down and stays frozen", {
        try await testWorkAgentChildShutdownAfterQuiescenceKeepsAdmissionsFrozen()
    }),
    ("phase5 child shutdown: terminal cleanup indeterminate refuses", {
        try await testWorkAgentChildShutdownRefusesTerminalUnquiescedOwner()
    }),
    ("phase5 child shutdown: force-stop preserves suspended lease", {
        try await testWorkAgentChildShutdownForceStopDoesNotThawSuspendedLease()
    }),
    ("phase5 child shutdown: public JBS composition derives the pilot", {
        try await testWorkAgentChildShutdownPublicCompositionAutoDerivesJBSOwner()
    }),
    ("phase5 child shutdown: JBS without pilot leaves admission unfrozen", {
        try await testWorkAgentChildShutdownPublicCompositionWithoutPilotLeavesJBSUnfrozen()
    }),
    ("phase5 child shutdown: custom canceller fails closed", {
        try await testWorkAgentChildShutdownCustomCancellerFailsClosed()
    }),
    ("phase5 child shutdown: synchronous seal defeats queued thaw", {
        try await testWorkAgentChildShutdownSynchronousSealDefeatsQueuedThaw()
    }),
]
