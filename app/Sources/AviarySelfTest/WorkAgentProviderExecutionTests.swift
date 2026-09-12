import Foundation

@testable import AviaryCore

/// This file deliberately exercises the production child boundary rather than replaying the
/// reducer by hand. The provider is local and deterministic; the only real process involved is
/// the bundled Python runtime which AgentChildExecutionResource owns and tears down.
private enum WorkAgentProviderExecutionMode: Sendable {
    case succeeds
    case fails
    case cancels
}

private struct WorkAgentProviderExecutionFixture {
    let home: AgentHome
    let model: ModelSpec
    let binding: WorkRunBinding
    let bundle: RunJournalBundle
    let coordinator: WorkAgentChildCoordinator
}

private final class WorkAgentProviderExecutionResourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resource: AgentChildExecutionResource?

    func set(_ resource: AgentChildExecutionResource) {
        lock.lock()
        self.resource = resource
        lock.unlock()
    }

    func get() -> AgentChildExecutionResource? {
        lock.lock()
        defer { lock.unlock() }
        return resource
    }
}

private struct WorkAgentProviderExecutionFailure: Error {}

/// Pause after constructing the Work-owned ledger but before the child can call begin(). This
/// lets a test install a one-shot writer failure at the exact admission boundary.
private actor WorkAgentProviderAccountingConstructionGate {
    private var constructed = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdAfterConstruction() async {
        constructed = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilConstructed() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !constructed && ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return constructed
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// A bounded, local provider that exposes the exact stream lifecycle needed by the proof. It
/// reads the Work journal from `stream` itself, so `sawDurableAdmissionBeforeStream` proves the
/// ledger append happened before the provider was even invoked.
private final class WorkAgentProviderExecutionProbe: ChatProvider, @unchecked Sendable {
    let id = "fake"

    private let journalURL: URL
    private let journal: JournalRef
    private let mode: WorkAgentProviderExecutionMode
    private let lock = NSLock()
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var eventIndex = 0
    private var terminalWaiter: CheckedContinuation<Void, Never>?
    private var terminalReleased = false
    private var streamCallCount = 0
    private var sawDurableAdmissionBeforeStream = false

    init(
        journalURL: URL, journal: JournalRef, mode: WorkAgentProviderExecutionMode
    ) {
        self.journalURL = journalURL
        self.journal = journal
        self.mode = mode
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let data = (try? Data(contentsOf: journalURL)) ?? Data()
        let events = TimelineJournalReader.read(
            data, journal: journal,
            actor: TimelineActor(actorID: "provider-execution-probe", kind: "self-test"),
            hostRecordedAt: Date()).records.map(\.event)
        let admitted = events.contains {
            $0.type == TimelineEventType.agentHandleProviderStarted
        }
        lock.lock()
        streamCallCount += 1
        sawDurableAdmissionBeforeStream = admitted
        lock.unlock()

        // Pull-based delivery ensures the Agent consumed each cumulative observation before
        // the next iterator call throws. Finishing a push buffer with an error may discard it.
        return AsyncThrowingStream(unfolding: { try await self.nextEvent() })
    }

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return releaseWaiter != nil
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return streamCallCount
    }

    var reportsConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalWaiter != nil
    }

    func releaseTerminal() {
        lock.lock()
        terminalReleased = true
        let waiter = terminalWaiter
        terminalWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    var sawAdmission: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawDurableAdmissionBeforeStream
    }

    func release() {
        lock.lock()
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    private func nextEvent() async throws -> ChatEvent? {
        await withCheckedContinuation { waiter in
            lock.lock()
            if released { lock.unlock(); waiter.resume() }
            else { releaseWaiter = waiter; lock.unlock() }
        }
        let index = takeEventIndex()
        if index < 2 {
            return .usage(ProviderUsage.RawReport(
                inputTokens: index == 0 ? 1 : 7, outputTokens: index == 0 ? 1 : 5,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                reportedTotalTokens: index == 0 ? 2 : 12, inputAccounting: .cacheExclusive))
        }
        switch mode {
        case .succeeds:
            if index == 2 { return .textDelta("deterministic child result") }
            if index == 3 { return .done(stopReason: "stop") }
            return nil
        case .fails: throw WorkAgentProviderExecutionFailure()
        case .cancels:
            await withCheckedContinuation { waiter in
                lock.lock()
                if terminalReleased { lock.unlock(); waiter.resume() }
                else { terminalWaiter = waiter; lock.unlock() }
            }
            throw CancellationError()
        }
    }

    private func takeEventIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = eventIndex
        eventIndex += 1
        return index
    }
}

private func workAgentProviderExecutionModel() -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string("child-provider-model"),
        "provider": .string("fake"),
    ]))
    model.contextWindow = 100_000
    model.costInput = 1
    model.costOutput = 2
    return model
}

private func workAgentProviderExecutionRuntimeFactory() -> (@Sendable () -> RuntimeHost)? {
    guard let root = EngineLocator.repoRoot(),
          FileManager.default.fileExists(
              atPath: root.appending(path: "runtime-hosts/python3/host.py").path)
    else { return nil }
    return { RuntimeHost.bundledPython(repoRoot: root, parentLifetimeLease: true)! }
}

private func makeWorkAgentProviderExecutionFixture(
    suffix: String, mode: WorkAgentProviderExecutionMode
) async throws -> (WorkAgentProviderExecutionFixture, WorkAgentProviderExecutionProbe) {
    let home = AgentHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aviary-child-provider-\(UUID().uuidString.lowercased())"))
    try FileManager.default.createDirectory(
        at: home.root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let host = try home.requirePersistedWorkHost()
    let work = WorkRef(workHostID: host.workHostID, workID: "child-provider-work-\(suffix)")
    let binding = WorkBinding(
        session: SessionRef("child-provider-session-\(suffix)"), work: work,
        workHost: host, sessionAttachment: SessionAttachmentRef("child-provider-attachment-\(suffix)"))
    let runBinding = WorkRunBinding(
        workBinding: binding, run: RunRef("child-provider-run-\(suffix)"))
    let model = workAgentProviderExecutionModel()
    let coordinator = try WorkAgentChildCoordinator()
    try await coordinator.register(
        work: work, home: home,
        actor: TimelineActor(actorID: "child-provider-register-\(suffix)", kind: "work-host"))
    let bundle = try await coordinator.openRun(work: work) {
        try await RunJournalBundle.openForExecution(
            home: home, identity: SessionWorkIdentity(
                sessionID: binding.session.sessionID, work: work, runID: runBinding.run.runID),
            actorID: "child-provider-parent-\(suffix)", modelID: model.qualifiedID,
            makeAttachmentID: { binding.sessionAttachment.attachmentID })
    }
    let probe = WorkAgentProviderExecutionProbe(
        journalURL: home.timelineV2WorkJournalURL(work), journal: binding.workJournal, mode: mode)
    return (
        WorkAgentProviderExecutionFixture(
            home: home, model: model, binding: runBinding,
            bundle: bundle, coordinator: coordinator),
        probe)
}

private func workAgentProviderExecutionFactory(
    fixture: WorkAgentProviderExecutionFixture,
    probe: WorkAgentProviderExecutionProbe,
    runtimeFactory: @escaping @Sendable () -> RuntimeHost,
    resourceBox: WorkAgentProviderExecutionResourceBox,
    constructionGate: WorkAgentProviderAccountingConstructionGate? = nil
) -> WorkAgentChildCoordinator.ExecutionFactory {
    { handle, deadline in
        let resource = AgentChildExecutionResource(
            configuration: AgentChildExecutionConfiguration(
                origin: fixture.binding, childID: handle.handleID, deadline: deadline,
                home: fixture.home, cwd: fixture.home.root.path, model: fixture.model,
                provider: probe,
                systemPrompt: "You are a deterministic child used by a self-test.",
                maxIterations: 2,
                makeProviderAccounting: {
                    let accounting = try await fixture.coordinator.providerAccounting(
                        work: fixture.binding.workBinding.work, handle: handle)
                    if let constructionGate { await constructionGate.holdAfterConstruction() }
                    return accounting
                },
                makeRuntimeHost: runtimeFactory),
            prompt: "perform the provider accounting proof")
        resourceBox.set(resource)
        return resource
    }
}

private func waitForWorkAgentProviderRecord(
    _ fixture: WorkAgentProviderExecutionFixture,
    handle: HandleRef,
    matching predicate: @escaping (BoundedWorkAgentHandleIndexRecord) -> Bool
) async throws -> BoundedWorkAgentHandleIndexRecord {
    for _ in 0..<600 {
        if let record = try? await fixture.coordinator.inspect(
            work: fixture.binding.workBinding.work, handle: handle), predicate(record) {
            return record
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "WorkAgentProviderExecutionTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for canonical child state"])
}

private func waitForWorkAgentProviderProbe(
    _ probe: WorkAgentProviderExecutionProbe
) async throws {
    for _ in 0..<600 {
        if probe.isWaiting { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "WorkAgentProviderExecutionTests", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for child provider stream"])
}

private func workAgentProviderEvents(
    _ fixture: WorkAgentProviderExecutionFixture
) throws -> [TimelineEvent] {
    TimelineJournalReader.read(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.binding.workBinding.work)),
        journal: fixture.binding.workBinding.workJournal,
        actor: TimelineActor(actorID: "child-provider-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
}

private func assertWorkAgentProviderAccounting(
    _ record: BoundedWorkAgentHandleIndexRecord,
    expectedOutcome: WorkAgentHandleTerminalOutcome,
    expectedUnresolved: Int
) {
    XCTAssertEqual(record.state, .terminal)
    XCTAssertEqual(record.terminalOutcome, expectedOutcome)
    XCTAssertEqual(record.providerAccounting.usage.started, 1)
    XCTAssertEqual(record.providerAccounting.usage.settled, 1)
    XCTAssertEqual(record.providerAccounting.usage.unresolvedTotal, expectedUnresolved)
    XCTAssertEqual(record.providerAccounting.usage.unresolvedBreakdown, expectedUnresolved)
    XCTAssertEqual(record.providerAccounting.usage.knownTokenFloor, 12)
    XCTAssertNil(record.providerAccounting.pending)
}

private func testWorkAgentProviderExecutionPersistsBeforeStreamAndAfterParentEnd() async throws {
    let runtimeFactory = try XCTUnwrap(workAgentProviderExecutionRuntimeFactory())
    let (fixture, probe) = try await makeWorkAgentProviderExecutionFixture(
        suffix: "success", mode: .succeeds)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let resourceBox = WorkAgentProviderExecutionResourceBox()
    let admission = try await fixture.coordinator.admit(
        origin: fixture.binding, prompt: "admit a durable child", label: "provider proof",
        deadline: nil,
        makeExecution: workAgentProviderExecutionFactory(
            fixture: fixture, probe: probe, runtimeFactory: runtimeFactory,
            resourceBox: resourceBox))
    _ = try await waitForWorkAgentProviderRecord(
        fixture, handle: admission.handle, matching: { $0.state == .running })
    try await waitForWorkAgentProviderProbe(probe)
    XCTAssertTrue(probe.sawAdmission)
    XCTAssertEqual(probe.calls, 1)

    let beforeEnd = try workAgentProviderEvents(fixture)
    XCTAssertEqual(beforeEnd.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted
            && $0.handle == admission.handle
    }.count, 1)
    XCTAssertEqual(beforeEnd.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled
            && $0.handle == admission.handle
    }.count, 0)

    // A parent Run may close while a Work-owned child remains outstanding. The child ledger is
    // a separate Work route and must finish against the same journal after this close.
    _ = try await fixture.bundle.finishRun(outcome: .completed)
    try await fixture.bundle.closeChecked()
    let afterEnd = try workAgentProviderEvents(fixture)
    XCTAssertTrue(afterEnd.contains { $0.type == TimelineEventType.runFinished })
    XCTAssertEqual(afterEnd.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled
            && $0.handle == admission.handle
    }.count, 0)

    probe.release()
    let terminal = try await waitForWorkAgentProviderRecord(
        fixture, handle: admission.handle, matching: { $0.state == .terminal })
    assertWorkAgentProviderAccounting(terminal, expectedOutcome: .succeeded, expectedUnresolved: 0)
    XCTAssertEqual(
        try await fixture.coordinator.read(
            work: fixture.binding.workBinding.work, handle: admission.handle).result,
        .available(Data("deterministic child result".utf8)))

    let events = try workAgentProviderEvents(fixture)
    let providerStarts = events.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted && $0.handle == admission.handle
    }
    let providerSettles = events.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == admission.handle
    }
    XCTAssertEqual(providerStarts.count, 1)
    XCTAssertEqual(providerSettles.count, 1)
    XCTAssertTrue(
        (try XCTUnwrap(providerStarts.first?.sequence))
            < (try XCTUnwrap(providerSettles.first?.sequence)))
    XCTAssertTrue(
        (try XCTUnwrap(events.first { $0.type == TimelineEventType.runFinished }?.sequence))
            < (try XCTUnwrap(providerSettles.first?.sequence)))

    let workSnapshot = WorkReducer.reduce(events)
    XCTAssertEqual(workSnapshot.providerUsage.started, 0,
                   "child provider usage is not parent-direct Work usage")
    XCTAssertEqual(workSnapshot.providerUsage.settled, 0)
    let resource = try XCTUnwrap(resourceBox.get())
    let sameResult = await resource.execute()
    XCTAssertEqual(sameResult.state, .succeeded)
    XCTAssertEqual(probe.calls, 1, "re-reading a settled child must not call the provider again")
}

private func runWorkAgentProviderTerminalScenario(
    suffix: String, mode: WorkAgentProviderExecutionMode,
    expectedOutcome: WorkAgentHandleTerminalOutcome
) async throws {
    let runtimeFactory = try XCTUnwrap(workAgentProviderExecutionRuntimeFactory())
    let (fixture, probe) = try await makeWorkAgentProviderExecutionFixture(
        suffix: suffix, mode: mode)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let resourceBox = WorkAgentProviderExecutionResourceBox()
    let admission = try await fixture.coordinator.admit(
        origin: fixture.binding, prompt: "record a terminal child crossing", label: suffix,
        deadline: nil,
        makeExecution: workAgentProviderExecutionFactory(
            fixture: fixture, probe: probe, runtimeFactory: runtimeFactory,
            resourceBox: resourceBox))
    _ = try await waitForWorkAgentProviderRecord(
        fixture, handle: admission.handle, matching: { $0.state == .running })
    try await waitForWorkAgentProviderProbe(probe)

    if case .cancels = mode {
        probe.release()
        for _ in 0..<600 {
            if probe.reportsConsumed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(probe.reportsConsumed)
        let resource = try XCTUnwrap(resourceBox.get())
        let cancelTask = Task { await resource.cancel() }
        for _ in 0..<600 {
            if await resource.cancellationIntentRecorded { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(await resource.cancellationIntentRecorded)
        probe.releaseTerminal()
        _ = await cancelTask.value
    } else {
        probe.release()
    }

    let terminal = try await waitForWorkAgentProviderRecord(
        fixture, handle: admission.handle, matching: { $0.state == .terminal })
    assertWorkAgentProviderAccounting(
        terminal, expectedOutcome: expectedOutcome, expectedUnresolved: 1)
    XCTAssertEqual(probe.calls, 1)
    let events = try workAgentProviderEvents(fixture)
    XCTAssertEqual(events.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted && $0.handle == admission.handle
    }.count, 1)
    XCTAssertEqual(events.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == admission.handle
    }.count, 1)
    XCTAssertEqual(WorkReducer.reduce(events).providerUsage.started, 0)
    _ = try await fixture.bundle.finishRun(outcome: .completed)
    try await fixture.bundle.closeChecked()
}

private func testWorkAgentProviderAfterWriteSettlementIsNotReplayed() async throws {
    let runtimeFactory = try XCTUnwrap(workAgentProviderExecutionRuntimeFactory())
    let (fixture, probe) = try await makeWorkAgentProviderExecutionFixture(
        suffix: "after-write", mode: .succeeds)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let resourceBox = WorkAgentProviderExecutionResourceBox()
    let admission = try await fixture.coordinator.admit(
        origin: fixture.binding, prompt: "retain an after-write settlement",
        label: "After-write provider proof", deadline: nil,
        makeExecution: workAgentProviderExecutionFactory(
            fixture: fixture, probe: probe, runtimeFactory: runtimeFactory,
            resourceBox: resourceBox))
    _ = try await waitForWorkAgentProviderRecord(
        fixture, handle: admission.handle, matching: { $0.state == .running })
    try await waitForWorkAgentProviderProbe(probe)

    // The writer reports failure after the complete settlement line is written. The ledger
    // must latch rather than invoking the provider a second time. Runtime cleanup may finish,
    // but the failed live writer cannot certify a new terminal Handle event.
    await fixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    probe.release()
    let resource = try XCTUnwrap(resourceBox.get())
    let result = await resource.execute()
    XCTAssertEqual(result.state, .failed)
    XCTAssertTrue(result.cleanup.isComplete)
    XCTAssertEqual(probe.calls, 1)
    let events = try workAgentProviderEvents(fixture)
    let snapshot = WorkReducer.reduce(events)
    XCTAssertTrue(snapshot.semanticProjectionValid)
    let accounting = try XCTUnwrap(snapshot.agentHandles[admission.handle.handleID]?.providerAccounting)
    XCTAssertEqual(accounting.usage.started, 1)
    XCTAssertEqual(accounting.usage.settled, 1)
    XCTAssertEqual(accounting.usage.knownTokenFloor, 12)
    XCTAssertEqual(accounting.usage.unresolvedTotal, 0)
    XCTAssertNil(accounting.pending)
    XCTAssertFalse(events.contains { $0.type == TimelineEventType.agentHandleTerminal })
    XCTAssertEqual(events.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted && $0.handle == admission.handle
    }.count, 1)
    XCTAssertEqual(events.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == admission.handle
    }.count, 1)
    XCTAssertEqual(WorkReducer.reduce(events).providerUsage.started, 0)
    let replay = await resource.execute()
    XCTAssertEqual(replay.state, .failed)
    XCTAssertEqual(probe.calls, 1, "an after-write uncertainty must not replay the provider")
    try? await fixture.bundle.closeChecked()
}

private func testWorkAgentProviderAdmissionBeforeWriteFailsClosed() async throws {
    let runtimeFactory = try XCTUnwrap(workAgentProviderExecutionRuntimeFactory())
    let (fixture, probe) = try await makeWorkAgentProviderExecutionFixture(
        suffix: "admission-before-write", mode: .succeeds)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let resourceBox = WorkAgentProviderExecutionResourceBox()
    let constructionGate = WorkAgentProviderAccountingConstructionGate()
    let admission = try await fixture.coordinator.admit(
        origin: fixture.binding, prompt: "fail provider admission before write",
        label: "before-write admission", deadline: nil,
        makeExecution: workAgentProviderExecutionFactory(
            fixture: fixture, probe: probe, runtimeFactory: runtimeFactory,
            resourceBox: resourceBox, constructionGate: constructionGate))
    _ = try await waitForWorkAgentProviderRecord(
        fixture, handle: admission.handle, matching: { $0.state == .running })
    guard await constructionGate.waitUntilConstructed() else {
        await constructionGate.release()
        throw NSError(
            domain: "WorkAgentProviderExecutionTests", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "ledger construction boundary was not reached"])
    }

    // The ledger exists, but no begin() call has happened yet. This is the only Work write
    // failure installed in the gate, so a provider call cannot consume it first.
    await fixture.bundle.injectWriterFailure(.beforeWrite, in: .work)
    await constructionGate.release()
    let resource = try XCTUnwrap(resourceBox.get())
    let first = await resource.execute()
    XCTAssertEqual(first.state, .failed)
    XCTAssertTrue(first.cleanup.isComplete)
    XCTAssertEqual(probe.calls, 0, "a failed admission must not dispatch the provider")

    let events = try workAgentProviderEvents(fixture)
    XCTAssertEqual(events.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted && $0.handle == admission.handle
    }.count, 0)
    XCTAssertEqual(events.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == admission.handle
    }.count, 0)
    if case .failed = (await fixture.bundle.status).health {
        XCTAssertTrue(true)
    } else {
        XCTFail("a before-write admission failure must leave the Work writer unavailable")
    }

    let replay = await resource.execute()
    XCTAssertEqual(replay, first)
    XCTAssertEqual(probe.calls, 0, "replaying a failed admission must not dispatch twice")
}

private func testWorkAgentProviderAdmissionAfterWriteRetainsPendingUnknownUsage() async throws {
    let runtimeFactory = try XCTUnwrap(workAgentProviderExecutionRuntimeFactory())
    let (fixture, probe) = try await makeWorkAgentProviderExecutionFixture(
        suffix: "admission-after-write", mode: .succeeds)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let resourceBox = WorkAgentProviderExecutionResourceBox()
    let constructionGate = WorkAgentProviderAccountingConstructionGate()
    let admission = try await fixture.coordinator.admit(
        origin: fixture.binding, prompt: "fail provider admission after write",
        label: "after-write admission", deadline: nil,
        makeExecution: workAgentProviderExecutionFactory(
            fixture: fixture, probe: probe, runtimeFactory: runtimeFactory,
            resourceBox: resourceBox, constructionGate: constructionGate))
    _ = try await waitForWorkAgentProviderRecord(
        fixture, handle: admission.handle, matching: { $0.state == .running })
    guard await constructionGate.waitUntilConstructed() else {
        await constructionGate.release()
        throw NSError(
            domain: "WorkAgentProviderExecutionTests", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "ledger construction boundary was not reached"])
    }

    await fixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    await constructionGate.release()
    let resource = try XCTUnwrap(resourceBox.get())
    let first = await resource.execute()
    XCTAssertEqual(first.state, .failed)
    XCTAssertTrue(first.cleanup.isComplete)
    XCTAssertEqual(probe.calls, 0, "an uncertain admission must not dispatch the provider")

    let events = try workAgentProviderEvents(fixture)
    let starts = events.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted && $0.handle == admission.handle
    }
    let settles = events.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == admission.handle
    }
    XCTAssertEqual(starts.count, 1, "the complete after-write line must remain canonical evidence")
    XCTAssertEqual(settles.count, 0)
    let snapshot = WorkReducer.reduce(events)
    let record = try XCTUnwrap(snapshot.agentHandles[admission.handle.handleID])
    XCTAssertEqual(record.providerAccounting.usage.started, 1)
    XCTAssertEqual(record.providerAccounting.usage.settled, 0)
    XCTAssertEqual(record.providerAccounting.usage.knownTokenFloor, 0)
    XCTAssertEqual(record.providerAccounting.usage.unresolvedTotal, 1)
    XCTAssertNotNil(record.providerAccounting.pending,
                    "an uncertain admission remains pending with unknown usage")
    if case .failed = (await fixture.bundle.status).health {
        XCTAssertTrue(true)
    } else {
        XCTFail("an after-write admission failure must leave the Work writer unavailable")
    }

    let replay = await resource.execute()
    XCTAssertEqual(replay, first)
    XCTAssertEqual(probe.calls, 0, "an uncertain admission must not be replayed")
}

let casesWorkAgentProviderExecution: [Case] = [
    ("phase5 child provider: durable admission before stream and settlement after parent End", {
        try await testWorkAgentProviderExecutionPersistsBeforeStreamAndAfterParentEnd()
    }),
    ("phase5 child provider: failed crossing retains latest report once", {
        try await runWorkAgentProviderTerminalScenario(
            suffix: "failure", mode: .fails, expectedOutcome: .failed)
    }),
    ("phase5 child provider: canceled crossing retains latest report once", {
        try await runWorkAgentProviderTerminalScenario(
            suffix: "cancellation", mode: .cancels, expectedOutcome: .canceled)
    }),
    ("phase5 child provider: after-write settlement is durable and not replayed", {
        try await testWorkAgentProviderAfterWriteSettlementIsNotReplayed()
    }),
    ("phase5 child provider: before-write admission dispatches no provider", {
        try await testWorkAgentProviderAdmissionBeforeWriteFailsClosed()
    }),
    ("phase5 child provider: after-write admission remains pending and unknown", {
        try await testWorkAgentProviderAdmissionAfterWriteRetainsPendingUnknownUsage()
    }),
]
