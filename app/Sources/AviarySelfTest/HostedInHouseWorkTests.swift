import Foundation

@testable import AviaryCore

private struct HostedImmediateProvider: ChatProvider {
    let id = "hosted-in-house-immediate"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("ok"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private actor HostedProviderGate {
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    private var installWaiters: [CheckedContinuation<Void, Never>] = []

    func install(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        self.continuation = continuation
        let waiters = installWaiters
        installWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilInstalled() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            installWaiters.append(continuation)
        }
    }

    func release() {
        continuation?.yield(.done(stopReason: "stop"))
        continuation?.finish()
        continuation = nil
    }
}

private actor HostedAdmissionGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct HostedBlockingProvider: ChatProvider {
    let id = "hosted-in-house-blocking"
    let gate: HostedProviderGate

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await gate.install(continuation) }
        }
    }
}

private final class HostedEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var durableSources: [String] = []
    private var lifecycleTransitions: [(HostedInHouseWorkLifecycle, HostedInHouseWorkLifecycle)] = []
    private var runtimeStates: [HostedInHouseWorkRuntimeState] = []
    private var agentEventCount = 0

    func record(_ event: HostedInHouseWorkEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .durable(let durable):
            durableSources.append(durable.source)
        case .ephemeral(let ephemeral):
            switch ephemeral {
            case .lifecycle(let transition):
                lifecycleTransitions.append((transition.from, transition.to))
            case .runtime(let observation):
                runtimeStates.append(observation.state)
            case .agent:
                agentEventCount += 1
            }
        }
    }

    var sources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return durableSources
    }

    var transitions: [(HostedInHouseWorkLifecycle, HostedInHouseWorkLifecycle)] {
        lock.lock()
        defer { lock.unlock() }
        return lifecycleTransitions
    }

    var runtimes: [HostedInHouseWorkRuntimeState] {
        lock.lock()
        defer { lock.unlock() }
        return runtimeStates
    }

    var agents: Int {
        lock.lock()
        defer { lock.unlock() }
        return agentEventCount
    }
}

private func hostedConfiguration(
    home: AgentHome,
    identity: SessionWorkIdentity,
    host: RuntimeHost,
    startAdmissionGate: (@Sendable () async -> Void)? = nil
) -> HostedInHouseWorkConfiguration {
    HostedInHouseWorkConfiguration(
        home: home,
        cwd: "/tmp",
        model: fakeModel(),
        provider: HostedImmediateProvider(),
        runtimeHost: host,
        identity: identity,
        serviceActorID: "hosted-work-service",
        systemPrompt: "You are a test agent.",
        maxIterations: 2,
        startAdmissionGate: startAdmissionGate)
}

private func hostedCommand(
    _ snapshot: HostedInHouseWorkSnapshot,
    commandID: String,
    command: SessionCommand,
    causalCursor: JournalCursor? = nil,
    client: String = "gui-test"
) -> HostedInHouseWorkCommand {
    HostedInHouseWorkCommand(
        work: snapshot.identity.work,
        session: SessionRef(snapshot.identity.sessionID),
        sessionAttachment: snapshot.sessionAttachment,
        client: ClientRef(client),
        commandID: commandID,
        causalCursor: causalCursor ?? snapshot.latestWorkCursor!,
        command: command)
}

private func hostedWaitForLifecycle(
    _ work: HostedInHouseWork,
    _ expected: HostedInHouseWorkLifecycle,
    attempts: Int = 200
) async -> HostedInHouseWorkSnapshot {
    var snapshot = await work.snapshot()
    for _ in 0..<attempts {
        if snapshot.lifecycle == expected { return snapshot }
        try? await Task.sleep(nanoseconds: 5_000_000)
        snapshot = await work.snapshot()
    }
    return snapshot
}

func test_hostedInHouseWorkOwnsRunBeyondObserverDetach() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "hosted-detach-session",
        work: WorkRef(workHostID: hostID, workID: "hosted-detach-work"),
        runID: "hosted-detach-run")
    let work = try await HostedInHouseWork.open(
        configuration: hostedConfiguration(home: home, identity: identity, host: host))
    let prepared = await work.snapshot()
    XCTAssertEqual(prepared.lifecycle, .prepared)
    XCTAssertEqual(prepared.runtimeState, .notStarted)
    XCTAssertEqual(prepared.journalHealth, .healthy)
    XCTAssertNotNil(prepared.latestWorkCursor)
    XCTAssertEqual(prepared.identity, identity)

    let collector = HostedEventCollector()
    let subscription = await work.subscribe(client: ClientRef("gui-one"))
    let eventTask = Task {
        for await event in subscription.events {
            collector.record(event)
        }
    }

    let start = hostedCommand(
        prepared, commandID: "start-hosted-detach",
        command: .start(prompt: ""))
    let started = try await work.submit(start)
    XCTAssertTrue(started.wasAdmitted)
    XCTAssertTrue(started.receipt.isQueued || started.receipt.isDelivered)
    XCTAssertTrue(started.lifecycle == .preparing || started.lifecycle == .idle)

    var live = await hostedWaitForLifecycle(work, .idle)
    let settledStart = try await work.submit(start)
    XCTAssertTrue(settledStart.receipt.isDelivered)
    XCTAssertEqual(live.lifecycle, .idle)
    XCTAssertEqual(live.runtimeState, .connected)
    XCTAssertTrue(live.runtimeTransportConnected)
    XCTAssertTrue(live.agentAvailable)
    XCTAssertNotNil(live.adoptionDescriptor)
    XCTAssertNotNil(live.adoptionEvidence)
    XCTAssertFalse(live.adoptionEvidence?.isLivenessProof ?? true)
    XCTAssertEqual(
        live.recoveryCoverage.planes[.timeline], .preserved)
    XCTAssertEqual(
        live.recoveryCoverage.planes[.effectiveContext], .preserved)
    XCTAssertEqual(
        live.recoveryCoverage.planes[.runtimeNamespace], .preserved)
    XCTAssertEqual(
        live.recoveryCoverage.planes[.backgroundWork], .preserved)
    XCTAssertEqual(
        live.recoveryCoverage.planes[.memoriesArtifactsRepository], .referenced)
    XCTAssertEqual(
        live.recoveryCoverage.planes[.externalEffects], .unknown)

    await work.unsubscribe(subscription.id)
    await eventTask.value
    let observerCount = await work.observerCount
    XCTAssertEqual(observerCount, 0)
    let terminalSubscription = await work.subscribe(client: ClientRef("gui-one-terminal"))
    let terminalEventTask = Task {
        for await event in terminalSubscription.events {
            collector.record(event)
        }
    }
    live = await work.snapshot()
    XCTAssertEqual(live.lifecycle, .idle)
    XCTAssertEqual(live.runtimeState, .connected)
    XCTAssertNotNil(live.adoptionDescriptor)

    await work.disconnectRuntime()
    var detached = await work.snapshot()
    XCTAssertEqual(detached.lifecycle, .idle)
    XCTAssertEqual(detached.runtimeState, .detached)
    XCTAssertFalse(detached.runtimeTransportConnected)
    XCTAssertNotNil(detached.adoptionDescriptor)
    XCTAssertNotNil(detached.adoptionEvidence)
    XCTAssertFalse(detached.adoptionEvidence?.isLivenessProof ?? true)
    XCTAssertEqual(
        detached.recoveryCoverage.planes[.runtimeNamespace], .referenced)
    XCTAssertEqual(
        detached.recoveryCoverage.planes[.backgroundWork], .unknown)

    _ = try await work.reconnectRuntime()
    detached = await work.snapshot()
    XCTAssertEqual(detached.lifecycle, .idle)
    XCTAssertEqual(detached.runtimeState, .connected)
    XCTAssertTrue(detached.runtimeTransportConnected)
    XCTAssertNotNil(detached.adoptionDescriptor)
    XCTAssertNotNil(detached.adoptionEvidence)
    XCTAssertEqual(
        detached.recoveryCoverage.planes[.backgroundWork], .preserved)

    let end = hostedCommand(
        detached, commandID: "end-hosted-detach",
        command: .endRun)
    let ended = try await work.submit(end)
    XCTAssertTrue(ended.wasAdmitted)
    XCTAssertTrue(ended.receipt.isDelivered)
    XCTAssertEqual(ended.lifecycle, .ended)
    await terminalEventTask.value

    let final = await work.snapshot()
    XCTAssertEqual(final.lifecycle, .ended)
    XCTAssertEqual(final.runtimeState, .stopped)
    XCTAssertEqual(final.journalHealth, .closed)
    XCTAssertFalse(final.agentAvailable)
    XCTAssertNotNil(final.adoptionDescriptor)
    XCTAssertFalse(final.adoptionEvidence?.isLivenessProof ?? true)
    XCTAssertTrue(collector.sources.contains("runtime.adoption_observed"))
    XCTAssertTrue(collector.sources.contains("command.admission"))
    XCTAssertTrue(collector.sources.contains("run.finished"))
    XCTAssertTrue(collector.transitions.contains { $0.1 == .ended })
    XCTAssertTrue(collector.runtimes.contains(.connected))
    XCTAssertTrue(collector.runtimes.contains(.detached))
    XCTAssertTrue(collector.runtimes.contains(.stopped))

    // Terminal runtime state is absorbing. Late service/client cleanup or a reconnect attempt
    // must not relabel the Work or touch the already-stopped RuntimeHost.
    await work.disconnectRuntime()
    let afterLateDisconnect = await work.snapshot()
    XCTAssertEqual(afterLateDisconnect.lifecycle, .ended)
    XCTAssertEqual(afterLateDisconnect.runtimeState, .stopped)
    XCTAssertFalse(afterLateDisconnect.runtimeTransportConnected)
    XCTAssertFalse(afterLateDisconnect.ownedRuntimeProcessKnownAlive)

    let afterLateReconnect = try await work.reconnectRuntime()
    XCTAssertEqual(afterLateReconnect.state, .stopped)
    XCTAssertFalse(afterLateReconnect.transportConnected)
    XCTAssertFalse(afterLateReconnect.ownedProcessKnownAlive)
    let afterLateRuntimeCalls = await work.snapshot()
    XCTAssertEqual(afterLateRuntimeCalls.lifecycle, .ended)
    XCTAssertEqual(afterLateRuntimeCalls.runtimeState, .stopped)
    XCTAssertFalse(afterLateRuntimeCalls.runtimeTransportConnected)
    XCTAssertFalse(afterLateRuntimeCalls.ownedRuntimeProcessKnownAlive)
}

func test_hostedInHouseWorkRejectsStaleCommandWithoutRunningIt() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "hosted-stale-session",
        work: WorkRef(workHostID: hostID, workID: "hosted-stale-work"),
        runID: "hosted-stale-run")
    let work = try await HostedInHouseWork.open(
        configuration: hostedConfiguration(home: home, identity: identity, host: host))
    let before = await work.snapshot()
    let oldCursor = before.latestWorkCursor!

    let started = try await work.submit(hostedCommand(
        before,
        commandID: "start-hosted-stale",
        command: .start(prompt: "")))
    XCTAssertTrue(started.wasAdmitted)
    XCTAssertTrue(started.receipt.isQueued || started.receipt.isDelivered)
    _ = await hostedWaitForLifecycle(work, .idle)
    let current = await work.snapshot()
    XCTAssertNotEqual(current.latestWorkCursor, oldCursor)

    let staleEnd = try await work.submit(hostedCommand(
        current,
        commandID: "stale-hosted-end",
        command: .endRun,
        causalCursor: oldCursor))
    XCTAssertFalse(staleEnd.wasAdmitted)
    XCTAssertEqual(staleEnd.lifecycle, .idle)
    XCTAssertFalse(staleEnd.receipt.wasHandedOff)

    let stale = try await work.submit(hostedCommand(
        current,
        commandID: "stale-hosted-send",
        command: .send(prompt: "must not run"),
        causalCursor: oldCursor))
    XCTAssertFalse(stale.wasAdmitted)
    if case .rejected(_, let reason) = stale.receipt.admission {
        if case .causalConflict = reason {
            // The native bridge preserves a typed causal conflict for this command.
        } else {
            XCTFail("stale command rejected for unexpected reason: \(reason)")
        }
    } else {
        XCTFail("stale command was not rejected")
    }
    XCTAssertEqual(stale.lifecycle, .idle)
    XCTAssertFalse(stale.receipt.wasHandedOff)

    let afterConflict = await work.snapshot()
    XCTAssertNotEqual(afterConflict.latestWorkCursor, current.latestWorkCursor)
    let end = try await work.submit(hostedCommand(
        afterConflict,
        commandID: "end-hosted-stale",
        command: .endRun))
    XCTAssertTrue(end.wasAdmitted)
    XCTAssertTrue(end.receipt.isDelivered)
    XCTAssertEqual((await work.snapshot()).lifecycle, .ended)
}

func test_hostedInHouseWorkQualifiesCommandIdentityPerClient() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "hosted-client-identity-session",
        work: WorkRef(workHostID: hostID, workID: "hosted-client-identity-work"),
        runID: "hosted-client-identity-run")
    let work = try await HostedInHouseWork.open(
        configuration: hostedConfiguration(home: home, identity: identity, host: host))
    let initial = await work.snapshot()

    let started = try await work.submit(hostedCommand(
        initial,
        commandID: "same-local-id",
        command: .start(prompt: ""),
        client: "gui-one"))
    XCTAssertTrue(started.wasAdmitted)
    XCTAssertTrue(started.receipt.isQueued || started.receipt.isDelivered)
    let firstControllerCommandID: String
    if case .accepted(let admitted) = started.receipt.admission {
        firstControllerCommandID = admitted.commandID
    } else {
        XCTFail("first client command was not accepted")
        return
    }

    _ = await hostedWaitForLifecycle(work, .idle)
    let afterStart = await work.snapshot()
    let secondClient = try await work.submit(hostedCommand(
        afterStart,
        commandID: "same-local-id",
        command: .send(prompt: "second client"),
        client: "gui-two"))
    XCTAssertTrue(secondClient.wasAdmitted)
    XCTAssertTrue(secondClient.receipt.isQueued || secondClient.receipt.isDelivered)
    _ = await hostedWaitForLifecycle(work, .idle)
    XCTAssertEqual(secondClient.command.commandID, "same-local-id")
    XCTAssertEqual(secondClient.command.client, ClientRef("gui-two"))
    if case .accepted(let admitted) = secondClient.receipt.admission {
        XCTAssertNotEqual(admitted.commandID, firstControllerCommandID)
    } else {
        XCTFail("second client command was not accepted")
    }

    let afterSecondClient = await work.snapshot()
    let end = try await work.submit(hostedCommand(
        afterSecondClient,
        commandID: "end-client-identity",
        command: .endRun,
        client: "gui-two"))
    XCTAssertTrue(end.wasAdmitted)
    XCTAssertTrue(end.receipt.isDelivered)
    XCTAssertEqual(end.lifecycle, .ended)
}

func test_hostedInHouseWorkStartReservationPreventsEndRuntimeLaunch() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "hosted-start-reservation-session",
        work: WorkRef(workHostID: hostID, workID: "hosted-start-reservation-work"),
        runID: "hosted-start-reservation-run")
    let admissionGate = HostedAdmissionGate()
    let work = try await HostedInHouseWork.open(configuration: hostedConfiguration(
        home: home,
        identity: identity,
        host: host,
        startAdmissionGate: { await admissionGate.pause() }))
    let initial = await work.snapshot()
    let startCommand = hostedCommand(
        initial,
        commandID: "start-before-end-admission",
        command: .start(prompt: ""))

    let startTask = Task { try await work.submit(startCommand) }
    await admissionGate.waitUntilEntered()
    let reserved = await work.snapshot()
    XCTAssertEqual(reserved.lifecycle, .preparing)

    // End uses the same pre-admission cursor and can win while Start is held at the service
    // boundary. The reservation makes End wait for Start's admission decision, not launch a
    // runtime in the meantime.
    let endCommand = hostedCommand(
        reserved,
        commandID: "end-wins-start-admission",
        command: .endRun,
        causalCursor: initial.latestWorkCursor!)
    let endTask = Task { try await work.submit(endCommand) }
    let ending = await hostedWaitForLifecycle(work, .ending)
    XCTAssertEqual(ending.lifecycle, .ending)

    await admissionGate.release()
    let start = try await startTask.value
    let end = try await endTask.value
    XCTAssertFalse(start.wasAdmitted)
    XCTAssertTrue(end.wasAdmitted)
    XCTAssertTrue(end.receipt.isDelivered)
    XCTAssertEqual(end.lifecycle, .ended)

    let final = await work.snapshot()
    XCTAssertEqual(final.lifecycle, .ended)
    XCTAssertEqual(final.runtimeState, .stopped)
    XCTAssertNil(final.adoptionDescriptor)
    XCTAssertFalse(final.agentAvailable)
}

func test_hostedInHouseWorkEndAbsorbsLateTurnResult() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "hosted-terminal-race-session",
        work: WorkRef(workHostID: hostID, workID: "hosted-terminal-race-work"),
        runID: "hosted-terminal-race-run")
    let gate = HostedProviderGate()
    let configuration = HostedInHouseWorkConfiguration(
        home: home,
        cwd: "/tmp",
        model: fakeModel(),
        provider: HostedBlockingProvider(gate: gate),
        runtimeHost: host,
        identity: identity,
        serviceActorID: "hosted-work-service",
        systemPrompt: "You are a test agent.",
        maxIterations: 2)
    let work = try await HostedInHouseWork.open(configuration: configuration)
    let initial = await work.snapshot()
    let start = try await work.submit(hostedCommand(
        initial,
        commandID: "start-hosted-terminal-race",
        command: .start(prompt: "")))
    XCTAssertTrue(start.wasAdmitted)
    _ = await hostedWaitForLifecycle(work, .idle)

    let sendCommand = hostedCommand(
        await work.snapshot(),
        commandID: "send-hosted-terminal-race",
        command: .send(prompt: "hold this turn"))
    let sendTask = Task { try await work.submit(sendCommand) }
    let send = try await sendTask.value
    XCTAssertTrue(send.wasAdmitted)
    XCTAssertTrue(send.receipt.isQueued || send.receipt.isDelivered)
    await gate.waitUntilInstalled()

    let endTask = Task {
        try await work.submit(hostedCommand(
            await work.snapshot(),
            commandID: "end-hosted-terminal-race",
            command: .endRun))
    }
    let ending = await hostedWaitForLifecycle(work, .ending)
    XCTAssertEqual(ending.lifecycle, .ending)
    let reconnectWhileEnding = try await work.reconnectRuntime()
    XCTAssertEqual(reconnectWhileEnding.state, .stopped)
    XCTAssertFalse(reconnectWhileEnding.transportConnected)
    await work.disconnectRuntime()
    let stillEnding = await work.snapshot()
    XCTAssertEqual(stillEnding.lifecycle, .ending)
    XCTAssertEqual(stillEnding.runtimeState, .stopped)
    await gate.release()
    let ended = try await endTask.value
    XCTAssertTrue(ended.wasAdmitted)
    XCTAssertTrue(ended.receipt.isDelivered)
    XCTAssertEqual(ended.lifecycle, .ended)
    let final = await work.snapshot()
    XCTAssertEqual(final.lifecycle, .ended)
    XCTAssertFalse(final.agentAvailable)
}

let casesHostedInHouseWork: [Case] = [
    (
        "hostedInHouseWorkOwnsRunBeyondObserverDetach",
        { try await test_hostedInHouseWorkOwnsRunBeyondObserverDetach() }),
    (
        "hostedInHouseWorkRejectsStaleCommandWithoutRunningIt",
        { try await test_hostedInHouseWorkRejectsStaleCommandWithoutRunningIt() }),
    (
        "hostedInHouseWorkQualifiesCommandIdentityPerClient",
        { try await test_hostedInHouseWorkQualifiesCommandIdentityPerClient() }),
    (
        "hostedInHouseWorkStartReservationPreventsEndRuntimeLaunch",
        { try await test_hostedInHouseWorkStartReservationPreventsEndRuntimeLaunch() }),
    (
        "hostedInHouseWorkEndAbsorbsLateTurnResult",
        { try await test_hostedInHouseWorkEndAbsorbsLateTurnResult() }),
]
