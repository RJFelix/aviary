import Foundation

@testable import AviaryCore

private func coordinatorBinding(
    home: AgentHome, suffix: String = UUID().uuidString.lowercased()
) throws -> WorkRunBinding {
    let host = try home.requirePersistedWorkHost()
    let work = WorkRef(workHostID: host.workHostID, workID: "coordinator-work-\(suffix)")
    return WorkRunBinding(
        workBinding: WorkBinding(
            session: SessionRef("coordinator-session-\(suffix)"), work: work,
            workHost: host, sessionAttachment: SessionAttachmentRef("coordinator-attachment-\(suffix)")),
        run: RunRef("coordinator-run-\(suffix)"))
}

private actor CoordinatorExecutionGate {
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?

    func install(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    var isInstalled: Bool { continuation != nil }

    func release(answer: String = "coordinator child answer") {
        continuation?.yield(.textDelta(answer))
        continuation?.yield(.done(stopReason: "stop"))
        continuation?.finish()
        continuation = nil
    }
}

private actor CoordinatorStartCommitGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    var wasEntered: Bool { entered }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct CoordinatorGatedProvider: ChatProvider, @unchecked Sendable {
    let id = "coordinator-gated"
    let gate: CoordinatorExecutionGate

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await gate.install(continuation) }
        }
    }
}

private final class CoordinatorLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func set(_ value: Value) { lock.withLock { stored = value } }
    func get() -> Value? { lock.withLock { stored } }
}

private final class CoordinatorInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private actor CoordinatorIncompleteCleanupExecution: WorkAgentChildExecution {
    let childID: String

    init(childID: String) { self.childID = childID }

    func execute() async -> AgentChildExecutionResult {
        AgentChildExecutionResult(
            childID: childID, state: .failed, detail: "cleanup remains in progress",
            cleanup: AgentChildExecutionCleanup(
                runtimeSessionDestroyed: false, runtimeStopped: false,
                transcriptClosed: true))
    }

    func cancel() async -> AgentChildCancellationOutcome { .accepted }
}

private actor CoordinatorManualExecution: WorkAgentChildExecution {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func execute() async -> AgentChildExecutionResult {
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return AgentChildExecutionResult(
            childID: "manual", state: .succeeded, answer: "manual result",
            cleanup: AgentChildExecutionCleanup(
                runtimeSessionDestroyed: true, runtimeStopped: true,
                transcriptClosed: true))
    }

    func cancel() async -> AgentChildCancellationOutcome {
        release()
        return .accepted
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct CoordinatorFixture {
    let home: AgentHome
    let binding: WorkRunBinding
    let bundle: RunJournalBundle
}

private func coordinatorHostFactory() -> (@Sendable () -> RuntimeHost)? {
    guard let root = EngineLocator.repoRoot(),
          FileManager.default.fileExists(
            atPath: root.appending(path: "runtime-hosts/python3/host.py").path)
    else { return nil }
    return { RuntimeHost.bundledPython(repoRoot: root, parentLifetimeLease: true)! }
}

private func coordinatorFixture(
    coordinator: WorkAgentChildCoordinator,
    home: AgentHome,
    suffix: String
) async throws -> CoordinatorFixture {
    let binding = try coordinatorBinding(home: home, suffix: suffix)
    try await coordinator.register(
        work: binding.workBinding.work, home: home,
        actor: TimelineActor(actorID: "coordinator-owner-\(suffix)", kind: "work-host"))
    let bundle = try await coordinator.openRun(work: binding.workBinding.work) {
        try await RunJournalBundle.openForExecution(
            home: home,
            identity: SessionWorkIdentity(
                sessionID: binding.workBinding.session.sessionID,
                work: binding.workBinding.work,
                runID: binding.run.runID),
            actorID: "coordinator-parent-\(suffix)",
            makeAttachmentID: { binding.workBinding.sessionAttachment.attachmentID })
    }
    return CoordinatorFixture(home: home, binding: binding, bundle: bundle)
}

private func coordinatorExecutionFactory(
    fixture: CoordinatorFixture,
    gate: CoordinatorExecutionGate,
    makeHost: @escaping @Sendable () -> RuntimeHost,
    resourceBox: CoordinatorLockedBox<AgentChildExecutionResource>? = nil
) -> WorkAgentChildCoordinator.ExecutionFactory {
    { handle, deadline in
        let resource = AgentChildExecutionResource(
            configuration: AgentChildExecutionConfiguration(
                origin: fixture.binding, childID: handle.handleID, deadline: deadline,
                home: fixture.home, cwd: "/tmp", model: fakeModel(),
                provider: CoordinatorGatedProvider(gate: gate),
                systemPrompt: "You are a focused coordinator child.", maxIterations: 3,
                makeRuntimeHost: makeHost),
            prompt: "perform the coordinator integration test")
        resourceBox?.set(resource)
        return resource
    }
}

private func coordinatorWaitForRecord(
    _ coordinator: WorkAgentChildCoordinator,
    work: WorkRef,
    handle: HandleRef,
    matching predicate: (BoundedWorkAgentHandleIndexRecord) -> Bool
) async throws -> WorkAgentChildCoordinator.ReadResult {
    for _ in 0..<600 {
        if let read = try? await coordinator.read(work: work, handle: handle),
           predicate(read.record) { return read }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "WorkAgentChildCoordinatorTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for canonical child state"])
}

private func coordinatorWaitForGate(_ gate: CoordinatorExecutionGate) async throws {
    for _ in 0..<600 {
        if await gate.isInstalled { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "WorkAgentChildCoordinatorTests", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for child provider"])
}

func testWorkAgentChildCoordinatorRejectsExpiredAndOversizedAdmission() async throws {
    let home = scratchHome()
    let binding = try coordinatorBinding(home: home)
    let coordinator = try WorkAgentChildCoordinator()
    try await coordinator.register(
        work: binding.workBinding.work, home: home,
        actor: TimelineActor(actorID: "coordinator-test", kind: "self-test"))
    let factory: WorkAgentChildCoordinator.ExecutionFactory = { _, _ in
        fatalError("invalid admissions must not create an execution resource")
    }

    do {
        _ = try await coordinator.admit(
            origin: binding, prompt: "expired", label: "expired",
            deadline: Date(timeIntervalSince1970: 10), makeExecution: factory,
            now: Date(timeIntervalSince1970: 11))
        XCTAssertTrue(false, "expired admission should be rejected before queue reservation")
    } catch let error as WorkAgentChildCoordinator.Failure {
        XCTAssertEqual(error, .invalidRequest("deadline must be finite and in the future"))
    }

    do {
        _ = try await coordinator.admit(
            origin: binding,
            prompt: String(repeating: "x", count: 64 * 1024 + 1),
            label: "oversized", deadline: Date().addingTimeInterval(60),
            makeExecution: factory)
        XCTAssertTrue(false, "oversized admission should be rejected without truncation")
    } catch let error as WorkAgentChildCoordinator.Failure {
        XCTAssertEqual(error, .invalidRequest("prompt exceeds 64 KiB"))
    }
}

func testWorkAgentChildCoordinatorRequiresOriginHostBinding() async throws {
    let home = scratchHome()
    let binding = try coordinatorBinding(home: home)
    let coordinator = try WorkAgentChildCoordinator()
    let foreign = WorkHostRef("foreign-host")
    let foreignBinding = WorkRunBinding(
        workBinding: WorkBinding(
            session: binding.workBinding.session, work: binding.workBinding.work,
            workHost: foreign, sessionAttachment: binding.workBinding.sessionAttachment),
        run: binding.run)
    try await coordinator.register(
        work: binding.workBinding.work, home: home,
        actor: TimelineActor(actorID: "coordinator-test", kind: "self-test"))
    let factory: WorkAgentChildCoordinator.ExecutionFactory = { _, _ in
        fatalError("wrong-origin admission must not create an execution resource")
    }
    do {
        _ = try await coordinator.admit(
            origin: foreignBinding, prompt: "no", label: "wrong-origin",
            deadline: Date().addingTimeInterval(60), makeExecution: factory)
        XCTAssertTrue(false, "foreign Work Host origin must be refused")
    } catch let error as WorkAgentChildCoordinator.Failure {
        XCTAssertEqual(error, .wrongOrigin)
    }
}

func testWorkAgentChildCoordinatorReturnsHandleForUncertainAdmission() async throws {
    let home = scratchHome()
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "uncertain-admission")
    let invocations = CoordinatorInvocationCount()
    await fixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    let retainedHandle: HandleRef
    do {
        _ = try await coordinator.admit(
            origin: fixture.binding, prompt: "retain my uncertain identity",
            label: "Uncertain admission", deadline: Date().addingTimeInterval(0.6),
            makeExecution: { handle, _ in
                invocations.increment()
                return CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
            })
        XCTAssertTrue(false, "lost admission confirmation must return its generated Handle")
        return
    } catch WorkAgentChildCoordinator.Failure.admissionUncertain(let handle) {
        retainedHandle = handle
    }
    try? await fixture.bundle.closeChecked()
    let canonical = try await coordinator.read(
        work: fixture.binding.workBinding.work, handle: retainedHandle)
    XCTAssertEqual(canonical.record.handle, retainedHandle)
    XCTAssertEqual(canonical.record.state, .queued)
    XCTAssertEqual(canonical.request, .available(Data("retain my uncertain identity".utf8)))
    XCTAssertEqual(invocations.count, 0)
    let expired = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: retainedHandle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(expired.record.terminalOutcome, .expired)
    XCTAssertEqual(expired.record.cleanup?.state, .notStarted)
    XCTAssertNil(expired.record.startedEvent)
    XCTAssertEqual(invocations.count, 0)
}

func testWorkAgentChildCoordinatorReleasesProvenAbsentUncertainAdmission() async throws {
    let home = scratchHome()
    let limits = try WorkAgentChildAdmissionQueue.Limits(
        executing: 1, queued: 1, queuedPerWork: 1)
    let coordinator = try WorkAgentChildCoordinator(limits: limits)
    let fixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "absent-uncertain-admission")
    await fixture.bundle.injectWriterFailure(.beforeWrite, in: .work)
    let absentHandle: HandleRef
    do {
        _ = try await coordinator.admit(
            origin: fixture.binding, prompt: "never written",
            label: "Absent uncertain", deadline: Date().addingTimeInterval(0.4),
            makeExecution: { handle, _ in
                CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
            })
        XCTAssertTrue(false, "failed-before-write admission must remain explicitly uncertain")
        return
    } catch WorkAgentChildCoordinator.Failure.admissionUncertain(let handle) {
        absentHandle = handle
    }
    try? await fixture.bundle.closeChecked()
    try await Task.sleep(nanoseconds: 550_000_000)
    do {
        _ = try await coordinator.inspect(
            work: fixture.binding.workBinding.work, handle: absentHandle)
        XCTAssertTrue(false, "exact canonical absence must not invent an agent Handle")
    } catch let error as WorkAgentChildCoordinator.Failure {
        XCTAssertEqual(error, .bodyUnavailable)
    }

    let replacementInvocations = CoordinatorInvocationCount()
    let replacement = try await coordinator.admit(
        origin: fixture.binding, prompt: "capacity was released",
        label: "Replacement", deadline: Date().addingTimeInterval(20),
        makeExecution: { handle, _ in
            replacementInvocations.increment()
            return CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
        })
    let replacementTerminal = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: replacement.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(replacementTerminal.record.handle, replacement.handle)
    XCTAssertEqual(replacementInvocations.count, 1)
}

func testWorkAgentChildCoordinatorCompletesAfterParentEndAndReadsCold() async throws {
    guard let makeHost = coordinatorHostFactory() else { return }
    let home = scratchHome()
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "post-parent-end")
    let gate = CoordinatorExecutionGate()
    let admission = try await coordinator.admit(
        origin: fixture.binding, prompt: "private post-End request",
        label: "Post-End child", deadline: Date().addingTimeInterval(30),
        makeExecution: coordinatorExecutionFactory(
            fixture: fixture, gate: gate, makeHost: makeHost))
    _ = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .running })
    try await coordinatorWaitForGate(gate)

    _ = try await fixture.bundle.finishRun(outcome: .completed)
    try await fixture.bundle.closeChecked()
    await gate.release(answer: "private post-End result")

    let terminal = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(terminal.record.terminalOutcome, .succeeded)
    XCTAssertEqual(terminal.result, .available(Data("private post-End result".utf8)))
    let stableBytes = try Data(contentsOf: home.timelineV2WorkJournalURL(
        fixture.binding.workBinding.work))
    let second = try await coordinator.read(
        work: fixture.binding.workBinding.work, handle: admission.handle)
    XCTAssertEqual(second.record, terminal.record)
    XCTAssertEqual(second.result, terminal.result)
    XCTAssertEqual(
        try Data(contentsOf: home.timelineV2WorkJournalURL(fixture.binding.workBinding.work)),
        stableBytes)

    let fresh = try WorkAgentChildCoordinator()
    try await fresh.register(
        work: fixture.binding.workBinding.work, home: home,
        actor: TimelineActor(actorID: "fresh-coordinator", kind: "work-host"))
    let cold = try await fresh.read(
        work: fixture.binding.workBinding.work, handle: admission.handle)
    XCTAssertEqual(cold.record, terminal.record)
    XCTAssertEqual(cold.result, .available(Data("private post-End result".utf8)))
    XCTAssertFalse(String(decoding: stableBytes, as: UTF8.self).contains("private post-End"))

    let resultReference = try XCTUnwrap(terminal.record.resultBody)
    let digest = try XCTUnwrap(resultReference.digest)
    let resultURL = ContextBodyStore(home: home).root.appending(path: "sha256")
        .appending(path: String(digest.dropFirst("sha256:".count)))
    try FileManager.default.removeItem(at: resultURL)
    let missingBody = try await fresh.read(
        work: fixture.binding.workBinding.work, handle: admission.handle)
    XCTAssertEqual(missingBody.record, terminal.record,
                   "missing content must not hide the canonical terminal fact")
    XCTAssertEqual(missingBody.request, .available(Data("private post-End request".utf8)))
    XCTAssertEqual(missingBody.result, .unavailable)
    XCTAssertEqual(
        try Data(contentsOf: home.timelineV2WorkJournalURL(fixture.binding.workBinding.work)),
        stableBytes)
}

func testWorkAgentChildCoordinatorExpiresAcrossStartedCommitBoundary() async throws {
    let home = scratchHome()
    let startGate = CoordinatorStartCommitGate()
    let coordinator = try WorkAgentChildCoordinator(beforeStartCommit: {
        await startGate.pause()
    })
    let fixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "start-deadline-boundary")
    let invocations = CoordinatorInvocationCount()
    let admissionTask = Task {
        try await coordinator.admit(
            origin: fixture.binding, prompt: "cross the start deadline",
            label: "Start boundary", deadline: Date().addingTimeInterval(0.25),
            makeExecution: { handle, _ in
                invocations.increment()
                return CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
            })
    }
    for _ in 0..<600 {
        if await startGate.wasEntered { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(await startGate.wasEntered)
    try await Task.sleep(nanoseconds: 350_000_000)
    await startGate.release()
    let admission = try await admissionTask.value
    let terminal = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(terminal.record.terminalOutcome, .expired)
    XCTAssertEqual(terminal.record.cleanup?.state, .notStarted)
    XCTAssertNil(terminal.record.startedEvent)
    XCTAssertEqual(invocations.count, 0)
    _ = try await fixture.bundle.finishRun(outcome: .completed)
    try await fixture.bundle.closeChecked()
}

func testWorkAgentChildCoordinatorExpiresQueuedAndRunningChildren() async throws {
    guard let makeHost = coordinatorHostFactory() else { return }
    let home = scratchHome()
    let limits = try WorkAgentChildAdmissionQueue.Limits(
        executing: 1, queued: 8, queuedPerWork: 8)
    let coordinator = try WorkAgentChildCoordinator(limits: limits)
    let runningFixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "expiry-running-blocker")
    let queuedFixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "expiry-queued")
    let runningGate = CoordinatorExecutionGate()
    let blocker = try await coordinator.admit(
        origin: runningFixture.binding, prompt: "occupy the only slot",
        label: "Running blocker", deadline: Date().addingTimeInterval(20),
        makeExecution: coordinatorExecutionFactory(
            fixture: runningFixture, gate: runningGate, makeHost: makeHost))
    try await coordinatorWaitForGate(runningGate)
    _ = try await coordinatorWaitForRecord(
        coordinator, work: runningFixture.binding.workBinding.work, handle: blocker.handle,
        matching: { $0.state == .running })

    let queuedInvocations = CoordinatorInvocationCount()
    let queued = try await coordinator.admit(
        origin: queuedFixture.binding, prompt: "expire without execution",
        label: "Queued expiry", deadline: Date().addingTimeInterval(0.35),
        makeExecution: { _, _ in
            queuedInvocations.increment()
            return CoordinatorIncompleteCleanupExecution(childID: "must-not-run")
        })
    let queuedTerminal = try await coordinatorWaitForRecord(
        coordinator, work: queuedFixture.binding.workBinding.work, handle: queued.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(queuedTerminal.record.terminalOutcome, .expired)
    XCTAssertEqual(queuedTerminal.record.cleanup?.state, .notStarted)
    XCTAssertEqual(queuedInvocations.count, 0)

    await runningGate.release()
    _ = try await coordinatorWaitForRecord(
        coordinator, work: runningFixture.binding.workBinding.work, handle: blocker.handle,
        matching: { $0.state == .terminal })
    _ = try await runningFixture.bundle.finishRun(outcome: .completed)
    try await runningFixture.bundle.closeChecked()
    _ = try await queuedFixture.bundle.finishRun(outcome: .completed)
    try await queuedFixture.bundle.closeChecked()

    let runningExpiryCoordinator = try WorkAgentChildCoordinator(limits: limits)
    let runningExpiryFixture = try await coordinatorFixture(
        coordinator: runningExpiryCoordinator, home: home, suffix: "expiry-running")
    let expiryGate = CoordinatorExecutionGate()
    let resourceBox = CoordinatorLockedBox<AgentChildExecutionResource>()
    let expiring = try await runningExpiryCoordinator.admit(
        origin: runningExpiryFixture.binding, prompt: "expire while running",
        label: "Running expiry", deadline: Date().addingTimeInterval(0.45),
        makeExecution: coordinatorExecutionFactory(
            fixture: runningExpiryFixture, gate: expiryGate, makeHost: makeHost,
            resourceBox: resourceBox))
    try await coordinatorWaitForGate(expiryGate)
    let resource = try XCTUnwrap(resourceBox.get())
    for _ in 0..<600 {
        if await resource.cancellationIntentRecorded { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(await resource.cancellationIntentRecorded)
    await expiryGate.release(answer: "too late")
    let runningTerminal = try await coordinatorWaitForRecord(
        runningExpiryCoordinator, work: runningExpiryFixture.binding.workBinding.work,
        handle: expiring.handle, matching: { $0.state == .terminal })
    XCTAssertEqual(runningTerminal.record.terminalOutcome, .expired)
    XCTAssertEqual(runningTerminal.record.cleanup?.state, .quiesced)
    _ = try await runningExpiryFixture.bundle.finishRun(outcome: .completed)
    try await runningExpiryFixture.bundle.closeChecked()
}

func testWorkAgentChildCoordinatorCancellationUsesExactLatestCauseAcrossClients() async throws {
    guard let makeHost = coordinatorHostFactory() else { return }
    let home = scratchHome()
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "two-client-cancel")
    let gate = CoordinatorExecutionGate()
    let resourceBox = CoordinatorLockedBox<AgentChildExecutionResource>()
    let admission = try await coordinator.admit(
        origin: fixture.binding, prompt: "cancel from an attached client",
        label: "Cancellation child", deadline: Date().addingTimeInterval(20),
        makeExecution: coordinatorExecutionFactory(
            fixture: fixture, gate: gate, makeHost: makeHost, resourceBox: resourceBox))
    let running = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .running })
    try await coordinatorWaitForGate(gate)
    let currentCursor = try XCTUnwrap(await fixture.bundle.status.durablePrefix.workCursor)
    let stale = JournalCursor(
        journal: currentCursor.journal, eventID: currentCursor.eventID,
        sequence: currentCursor.sequence - 1)
    do {
        _ = try await coordinator.cancel(
            work: fixture.binding.workBinding.work, handle: admission.handle,
            command: CommandRef(
                commandID: "stale-cancel", client: ClientRef("client-stale"),
                sessionAttachment: fixture.binding.workBinding.sessionAttachment,
                causalCursor: stale))
        XCTAssertTrue(false, "a stale client cursor must not mutate the queue or child")
    } catch { XCTAssertTrue(true) }
    XCTAssertEqual(
        try await coordinator.read(
            work: fixture.binding.workBinding.work, handle: admission.handle).record.state,
        .running)
    let resource = try XCTUnwrap(resourceBox.get())
    XCTAssertFalse(await resource.cancellationIntentRecorded)

    let clientA = ClientRef("client-a")
    let accepted = Task {
        try await coordinator.cancel(
            work: fixture.binding.workBinding.work, handle: admission.handle,
            command: CommandRef(
                commandID: "fresh-cancel-a", client: clientA,
                sessionAttachment: fixture.binding.workBinding.sessionAttachment,
                causalCursor: currentCursor))
    }
    let canceled = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .cancelRequested })
    let afterCancelCursor = try XCTUnwrap(await fixture.bundle.status.durablePrefix.workCursor)
    let second = try await coordinator.cancel(
        work: fixture.binding.workBinding.work, handle: admission.handle,
        command: CommandRef(
            commandID: "fresh-cancel-b", client: ClientRef("client-b"),
            sessionAttachment: fixture.binding.workBinding.sessionAttachment,
            causalCursor: afterCancelCursor))
    XCTAssertEqual(second, .alreadyRequested)
    await gate.release(answer: "late answer")
    XCTAssertEqual(try await accepted.value, .accepted)
    let terminal = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(terminal.record.terminalOutcome, .canceled)

    let events = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(fixture.binding.workBinding.work)),
        journal: fixture.bundle.workJournal,
        actor: TimelineActor(actorID: "coordinator-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    let cancellationEvents = events.filter {
        $0.type == TimelineEventType.agentHandleCancelRequested && $0.handle == admission.handle
    }
    XCTAssertEqual(cancellationEvents.count, 1)
    let cancellation = try XCTUnwrap(cancellationEvents.first)
    XCTAssertEqual(cancellation.client, clientA)
    XCTAssertEqual(cancellation.command?.client, clientA)
    XCTAssertEqual(cancellation.command?.causalCursor, currentCursor)
    XCTAssertEqual(cancellation.causedByEventID, running.record.latestLifecycleEvent)
    XCTAssertEqual(canceled.record.latestLifecycleEvent,
                   EventRef(journal: cancellation.journal, eventID: cancellation.eventID))
    let terminalEvent = try XCTUnwrap(events.last {
        $0.type == TimelineEventType.agentHandleTerminal && $0.handle == admission.handle
    })
    XCTAssertEqual(
        terminalEvent.causedByEventID,
        EventRef(journal: cancellation.journal, eventID: cancellation.eventID))
    _ = try await fixture.bundle.finishRun(outcome: .completed)
    try await fixture.bundle.closeChecked()
}

func testWorkAgentChildCoordinatorAppliesCanonicallyProvenAmbiguousCancellation() async throws {
    guard let makeHost = coordinatorHostFactory() else { return }
    let home = scratchHome()
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "ambiguous-cancel")
    let gate = CoordinatorExecutionGate()
    let resourceBox = CoordinatorLockedBox<AgentChildExecutionResource>()
    let admission = try await coordinator.admit(
        origin: fixture.binding, prompt: "cancel after ambiguous durability",
        label: "Ambiguous cancellation", deadline: Date().addingTimeInterval(20),
        makeExecution: coordinatorExecutionFactory(
            fixture: fixture, gate: gate, makeHost: makeHost, resourceBox: resourceBox))
    _ = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .running })
    try await coordinatorWaitForGate(gate)
    let cursor = try XCTUnwrap(await fixture.bundle.status.durablePrefix.workCursor)
    await fixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    let first = try await coordinator.cancel(
        work: fixture.binding.workBinding.work, handle: admission.handle,
        command: CommandRef(
            commandID: "ambiguous-cancel", client: ClientRef("client-a"),
            sessionAttachment: fixture.binding.workBinding.sessionAttachment,
            causalCursor: cursor))
    XCTAssertEqual(first, .ambiguous)
    let resource = try XCTUnwrap(resourceBox.get())
    XCTAssertFalse(await resource.cancellationIntentRecorded)
    await gate.release(answer: "late success must not override canonical cancellation")
    let lateResult = await resource.execute()
    XCTAssertEqual(lateResult.state, .succeeded)
    try await Task.sleep(nanoseconds: 100_000_000)
    try? await fixture.bundle.closeChecked()

    let applied = try await coordinator.cancel(
        work: fixture.binding.workBinding.work, handle: admission.handle,
        command: CommandRef(
            commandID: "observe-cancel", client: ClientRef("client-b"),
            sessionAttachment: fixture.binding.workBinding.sessionAttachment,
            causalCursor: cursor))
    XCTAssertEqual(applied, .alreadyRequested)
    XCTAssertFalse(await resource.cancellationIntentRecorded,
                   "an already-finished resource is settled from retained evidence, not replayed")
    let terminal = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(terminal.record.cancellationCause, .client)
    XCTAssertEqual(terminal.record.terminalOutcome, .canceled)
}

func testWorkAgentChildCoordinatorSettlesCanonicallyCanceledQueuedChild() async throws {
    let home = scratchHome()
    let limits = try WorkAgentChildAdmissionQueue.Limits(
        executing: 1, queued: 8, queuedPerWork: 8)
    let coordinator = try WorkAgentChildCoordinator(limits: limits)
    let blockerFixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "queued-cancel-blocker")
    let queuedFixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "queued-cancel-target")
    let blocker = try await coordinator.admit(
        origin: blockerFixture.binding, prompt: "retain execution capacity",
        label: "Capacity blocker", deadline: Date().addingTimeInterval(20),
        makeExecution: { handle, _ in
            CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
        })
    _ = try await coordinatorWaitForRecord(
        coordinator, work: blockerFixture.binding.workBinding.work, handle: blocker.handle,
        matching: { $0.state == .terminal && $0.blocksWorkCompletion })

    let invocations = CoordinatorInvocationCount()
    let queued = try await coordinator.admit(
        origin: queuedFixture.binding, prompt: "cancel while queued",
        label: "Queued cancel", deadline: Date().addingTimeInterval(20),
        makeExecution: { handle, _ in
            invocations.increment()
            return CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
        })
    _ = try await coordinatorWaitForRecord(
        coordinator, work: queuedFixture.binding.workBinding.work, handle: queued.handle,
        matching: { $0.state == .queued })
    let cursor = try XCTUnwrap(await queuedFixture.bundle.status.durablePrefix.workCursor)
    await queuedFixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    let first = try await coordinator.cancel(
        work: queuedFixture.binding.workBinding.work, handle: queued.handle,
        command: CommandRef(
            commandID: "ambiguous-queued-cancel", client: ClientRef("client-a"),
            sessionAttachment: queuedFixture.binding.workBinding.sessionAttachment,
            causalCursor: cursor))
    XCTAssertEqual(first, .ambiguous)
    try? await queuedFixture.bundle.closeChecked()

    let retry = try await coordinator.cancel(
        work: queuedFixture.binding.workBinding.work, handle: queued.handle,
        command: CommandRef(
            commandID: "observe-queued-cancel", client: ClientRef("client-b"),
            sessionAttachment: queuedFixture.binding.workBinding.sessionAttachment,
            causalCursor: cursor))
    XCTAssertEqual(retry, .alreadyRequested)
    let terminal = try await coordinatorWaitForRecord(
        coordinator, work: queuedFixture.binding.workBinding.work, handle: queued.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(terminal.record.terminalOutcome, .canceled)
    XCTAssertEqual(terminal.record.cleanup?.state, .notStarted)
    XCTAssertNil(terminal.record.startedEvent)
    XCTAssertEqual(invocations.count, 0)
}

func testWorkAgentChildCoordinatorAggregatesAwaitObservers() async throws {
    let home = scratchHome()
    let limits = try WorkAgentChildAdmissionQueue.Limits(
        executing: 1, queued: 8, queuedPerWork: 8)
    let coordinator = try WorkAgentChildCoordinator(limits: limits)
    let fixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "await-observers")
    let manual = CoordinatorManualExecution()
    let blocker = try await coordinator.admit(
        origin: fixture.binding, prompt: "block promotion",
        label: "Observer blocker", deadline: Date().addingTimeInterval(20),
        makeExecution: { _, _ in manual })
    _ = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: blocker.handle,
        matching: { $0.state == .running })

    let olderInvocations = CoordinatorInvocationCount()
    let older = try await coordinator.admit(
        origin: fixture.binding, prompt: "older non-awaited",
        label: "Older", deadline: Date().addingTimeInterval(20),
        makeExecution: { handle, _ in
            olderInvocations.increment()
            return CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
        })
    let targetInvocations = CoordinatorInvocationCount()
    let target = try await coordinator.admit(
        origin: fixture.binding, prompt: "newer multiply-awaited",
        label: "Target", deadline: Date().addingTimeInterval(20),
        makeExecution: { handle, _ in
            targetInvocations.increment()
            return CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
        })
    let prefix = "run:\(fixture.binding.run.runID)/delegate:coordinator-test/future:"
    XCTAssertEqual(try await coordinator.awaitInterest(
        work: fixture.binding.workBinding.work, handle: target.handle,
        observerID: prefix + "a", awaited: true), .accepted)
    XCTAssertEqual(try await coordinator.awaitInterest(
        work: fixture.binding.workBinding.work, handle: target.handle,
        observerID: prefix + "b", awaited: true), .accepted)
    XCTAssertEqual(try await coordinator.awaitInterest(
        work: fixture.binding.workBinding.work, handle: target.handle,
        observerID: prefix + "a", awaited: false), .accepted)
    for index in 0..<63 {
        XCTAssertEqual(try await coordinator.awaitInterest(
            work: fixture.binding.workBinding.work, handle: target.handle,
            observerID: prefix + "extra-\(index)", awaited: true), .accepted)
    }
    do {
        _ = try await coordinator.awaitInterest(
            work: fixture.binding.workBinding.work, handle: target.handle,
            observerID: prefix + "over-cap", awaited: true)
        XCTAssertTrue(false, "a Handle must retain at most 64 active await observers")
    } catch let error as WorkAgentChildCoordinator.Failure {
        XCTAssertEqual(error, .capacity)
    }

    await manual.release()
    _ = try await coordinatorWaitForRecord(
        coordinator, work: fixture.binding.workBinding.work, handle: target.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(targetInvocations.count, 1,
                   "remaining observers must preserve awaited promotion")
    XCTAssertEqual(olderInvocations.count, 0)
    XCTAssertEqual(
        try await coordinator.inspect(
            work: fixture.binding.workBinding.work, handle: older.handle).state,
        .queued)
}

func testWorkAgentChildCoordinatorRetainsIndeterminateCleanupAndExecutionSlot() async throws {
    let home = scratchHome()
    let limits = try WorkAgentChildAdmissionQueue.Limits(
        executing: 1, queued: 8, queuedPerWork: 8)
    let coordinator = try WorkAgentChildCoordinator(limits: limits)
    let stuckFixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "indeterminate-cleanup")
    let waitingFixture = try await coordinatorFixture(
        coordinator: coordinator, home: home, suffix: "after-indeterminate")
    let stuck = try await coordinator.admit(
        origin: stuckFixture.binding, prompt: "truthful incomplete cleanup",
        label: "Incomplete cleanup", deadline: Date().addingTimeInterval(20),
        makeExecution: { handle, _ in
            CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
        })
    let terminal = try await coordinatorWaitForRecord(
        coordinator, work: stuckFixture.binding.workBinding.work, handle: stuck.handle,
        matching: { $0.state == .terminal })
    XCTAssertEqual(terminal.record.terminalOutcome, .indeterminate)
    XCTAssertEqual(terminal.record.cleanup?.state, .indeterminate)
    XCTAssertTrue(terminal.record.blocksWorkCompletion)
    XCTAssertEqual(terminal.result, .available(Data("cleanup remains in progress".utf8)))

    let waitingInvocations = CoordinatorInvocationCount()
    let waiting = try await coordinator.admit(
        origin: waitingFixture.binding, prompt: "must remain queued",
        label: "Blocked by unquiesced child", deadline: Date().addingTimeInterval(20),
        makeExecution: { handle, _ in
            waitingInvocations.increment()
            return CoordinatorIncompleteCleanupExecution(childID: handle.handleID)
        })
    let queued = try await coordinatorWaitForRecord(
        coordinator, work: waitingFixture.binding.workBinding.work, handle: waiting.handle,
        matching: { $0.state == .queued })
    XCTAssertEqual(queued.record.state, .queued)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(waitingInvocations.count, 0,
                   "an indeterminate terminal must retain its possibly-executing slot")
    let coldCancel = try await coordinator.cancel(
        work: stuckFixture.binding.workBinding.work, handle: stuck.handle,
        command: CommandRef(
            commandID: "terminal-cancel", client: ClientRef("client"),
            sessionAttachment: stuckFixture.binding.workBinding.sessionAttachment,
            causalCursor: try XCTUnwrap(await stuckFixture.bundle.status.durablePrefix.workCursor)))
    XCTAssertEqual(coldCancel, .alreadyTerminal(.indeterminate))
}

let casesWorkAgentChildCoordinator: [Case] = [
    ("phase5 child coordinator: bounded admission validation", {
        try await testWorkAgentChildCoordinatorRejectsExpiredAndOversizedAdmission()
    }),
    ("phase5 child coordinator: origin host binding", {
        try await testWorkAgentChildCoordinatorRequiresOriginHostBinding()
    }),
    ("phase5 child coordinator: uncertain admission retains Handle identity", {
        try await testWorkAgentChildCoordinatorReturnsHandleForUncertainAdmission()
    }),
    ("phase5 child coordinator: proven absent admission releases capacity", {
        try await testWorkAgentChildCoordinatorReleasesProvenAbsentUncertainAdmission()
    }),
    ("phase5 child coordinator: post-End completion and cold retained reads", {
        try await testWorkAgentChildCoordinatorCompletesAfterParentEndAndReadsCold()
    }),
    ("phase5 child coordinator: queued and running deadlines", {
        try await testWorkAgentChildCoordinatorExpiresQueuedAndRunningChildren()
    }),
    ("phase5 child coordinator: deadline crossing before started commit", {
        try await testWorkAgentChildCoordinatorExpiresAcrossStartedCommitBoundary()
    }),
    ("phase5 child coordinator: exact two-client cancellation causality", {
        try await testWorkAgentChildCoordinatorCancellationUsesExactLatestCauseAcrossClients()
    }),
    ("phase5 child coordinator: proven ambiguous cancellation reaches resource", {
        try await testWorkAgentChildCoordinatorAppliesCanonicallyProvenAmbiguousCancellation()
    }),
    ("phase5 child coordinator: proven queued cancellation reaches terminal", {
        try await testWorkAgentChildCoordinatorSettlesCanonicallyCanceledQueuedChild()
    }),
    ("phase5 child coordinator: await interest aggregates bounded observers", {
        try await testWorkAgentChildCoordinatorAggregatesAwaitObservers()
    }),
    ("phase5 child coordinator: indeterminate cleanup retains execution capacity", {
        try await testWorkAgentChildCoordinatorRetainsIndeterminateCleanupAndExecutionSlot()
    }),
]
