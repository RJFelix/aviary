import Foundation
@testable import AviaryCore

private enum ChildLifecycleProviderError: Error {
    case failed
}

private final class ChildLifecycleProvider: ChatProvider, @unchecked Sendable {
    enum Mode {
        case completed
        case failed
        case delayed
    }

    let id = "child-lifecycle-provider"
    let mode: Mode
    private let lock = NSLock()
    private var calls = 0

    init(mode: Mode) {
        self.mode = mode
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.withLock { calls += 1 }
        return AsyncThrowingStream { continuation in
            switch self.mode {
            case .completed:
                continuation.yield(.textDelta("child answer"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            case .failed:
                continuation.finish(throwing: ChildLifecycleProviderError.failed)
            case .delayed:
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continuation.yield(.textDelta("late answer"))
                    continuation.yield(.done(stopReason: "stop"))
                    continuation.finish()
                }
            }
        }
    }
}

private func childLifecycleEvents(
    home: AgentHome, bundle: RunJournalBundle, identity: SessionWorkIdentity
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "child-lifecycle-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    return read.records.map(\.event)
}

private func waitForChildToSettle(_ agent: Agent) async -> Agent.ChildStatus? {
    for _ in 0..<100 {
        let payload = await agent.serveCallback(kind: "children", payload: .object([:]))
        if let child = payload.arrayValue?.first,
           let state = child["state"]?.stringValue, state != "running"
        {
            return Agent.ChildStatus(
                id: child["id"]?.stringValue ?? "",
                name: child["name"]?.stringValue ?? "",
                state: state, answer: child["answer"]?.stringValue)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return nil
}

private func prepareChildLifecycleRun(
    provider: ChatProvider, name: String
) async throws -> (
    home: AgentHome, identity: SessionWorkIdentity, bundle: RunJournalBundle,
    writer: SessionWriter, host: RuntimeHost, runner: AgentRunner, agent: Agent
) {
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "\(name)-session",
        work: WorkRef(workHostID: hostID, workID: "\(name)-work"),
        runID: "\(name)-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "child-lifecycle-test",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "\(name)-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    guard let host = try makeHost(.reference) else {
        try await bundle.closeChecked()
        try await writer.closeChecked()
        throw RunJournalBundleError.unavailable("reference runtime host unavailable")
    }
    _ = try await host.start()
    let runner = AgentRunner(
        provider: provider, host: host,
        settings: .init(
            home: home, cwd: "/tmp", model: fakeModel(), systemPrompt: "child test",
            identity: identity, writer: writer, nativeJournal: bundle))
    let prepared = try await runner.prepare()
    return (home, identity, bundle, writer, host, runner, prepared.agent)
}

private func finishChildLifecycleRun(
    _ fixture: (
        home: AgentHome, identity: SessionWorkIdentity, bundle: RunJournalBundle,
        writer: SessionWriter, host: RuntimeHost, runner: AgentRunner, agent: Agent
    ),
    outcome: RunTerminalOutcome = .completed
) async {
    await fixture.runner.stopMCPServers()
    try? await fixture.host.destroySession(fixture.identity.workID)
    await fixture.host.stop()
    do { _ = try await fixture.bundle.finishRun(outcome: outcome) } catch {}
    try? await fixture.bundle.closeChecked()
    try? await fixture.writer.closeChecked()
    try? FileManager.default.removeItem(at: fixture.home.root)
}

func test_nativeChildStartRefusalIsNotProjectedAsRunning() async throws {
    let fixture = try await prepareChildLifecycleRun(
        provider: ChildLifecycleProvider(mode: .completed), name: "child-refusal")

    // Teardown closes admission before the callback arrives.
    await fixture.runner.stopBackgroundChildren()
    let reply = await fixture.agent.serveCallback(kind: "spawn", payload: .object([
        "prompt": .string("late child"), "name": .string("late"),
    ]))
    XCTAssertEqual(reply["state"]?.stringValue, "refused")
    XCTAssertNil(reply["id"], "refusal must not manufacture a running child id")
    XCTAssertTrue(
        reply["error"]?.stringValue?.contains("admission is closed") == true)
    let children = await fixture.agent.serveCallback(
        kind: "children", payload: .object([:]))
    XCTAssertTrue(children.arrayValue?.isEmpty == true)

    let events = try childLifecycleEvents(
        home: fixture.home, bundle: fixture.bundle, identity: fixture.identity)
    XCTAssertTrue(events.filter { $0.type == TimelineEventType.childLifecycle }.isEmpty)
    XCTAssertEqual(
        events.filter {
            $0.type == TimelineEventType.actionOutcome
                && $0.payload["kind"]?.stringValue == ActionKind.child.rawValue
        }.first?.payload["state"]?.stringValue,
        ActionExecutionState.canceled.rawValue)
    await finishChildLifecycleRun(fixture)
}

func test_nativeChildRunnerRecordsCompletionWithParentRunProvenance() async throws {
    let fixture = try await prepareChildLifecycleRun(
        provider: ChildLifecycleProvider(mode: .completed), name: "child-complete")
    let reply = await fixture.agent.serveCallback(kind: "spawn", payload: .object([
        "prompt": .string("complete this child"), "name": .string("completer"),
    ]))
    guard let childID = reply["id"]?.stringValue else {
        XCTFail("runner should admit a child")
        await finishChildLifecycleRun(fixture, outcome: .failed)
        return
    }
    XCTAssertEqual(reply["state"]?.stringValue, "running")
    let child = try XCTUnwrap(await waitForChildToSettle(fixture.agent))
    XCTAssertEqual(child.id, childID)
    XCTAssertEqual(child.state, "done")

    let events = try childLifecycleEvents(
        home: fixture.home, bundle: fixture.bundle, identity: fixture.identity)
    let lifecycle = events.filter { $0.type == TimelineEventType.childLifecycle }
    XCTAssertEqual(lifecycle.map { $0.payload["state"]?.stringValue }, ["running", "done"])
    XCTAssertTrue(lifecycle.allSatisfy { $0.payload["child_id"]?.stringValue == childID })
    XCTAssertTrue(lifecycle.allSatisfy { $0.payload["name"]?.stringValue == "completer" })
    XCTAssertTrue(lifecycle.allSatisfy { $0.session?.sessionID == fixture.identity.sessionID })
    XCTAssertTrue(lifecycle.allSatisfy { $0.run == RunRef(fixture.identity.runID) })
    XCTAssertEqual(
        lifecycle.last?.payload["parent_session_id"]?.stringValue,
        fixture.identity.sessionID)
    XCTAssertEqual(
        lifecycle.last?.payload["parent_run_id"]?.stringValue,
        fixture.identity.runID)
    await finishChildLifecycleRun(fixture)
}

func test_nativeChildRunnerRecordsFailureAndCancellationDistinctly() async throws {
    let failed = try await prepareChildLifecycleRun(
        provider: ChildLifecycleProvider(mode: .failed), name: "child-failed")
    _ = await failed.agent.serveCallback(kind: "spawn", payload: .object([
        "prompt": .string("fail this child"), "name": .string("failure"),
    ]))
    let failedChild = try XCTUnwrap(await waitForChildToSettle(failed.agent))
    XCTAssertEqual(failedChild.state, "failed")
    let failedEvents = try childLifecycleEvents(
        home: failed.home, bundle: failed.bundle, identity: failed.identity)
    XCTAssertEqual(
        failedEvents.filter { $0.type == TimelineEventType.childLifecycle }
            .compactMap { $0.payload["state"]?.stringValue },
        ["running", "failed"])
    await finishChildLifecycleRun(failed)

    let canceledProvider = ChildLifecycleProvider(mode: .delayed)
    let canceled = try await prepareChildLifecycleRun(
        provider: canceledProvider, name: "child-canceled")
    _ = await canceled.agent.serveCallback(kind: "spawn", payload: .object([
        "prompt": .string("cancel this child"), "name": .string("cancellation"),
    ]))
    for _ in 0..<100 where canceledProvider.callCount == 0 {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    await canceled.runner.stopBackgroundChildren()
    let canceledChild = try XCTUnwrap(await waitForChildToSettle(canceled.agent))
    XCTAssertEqual(canceledChild.state, "canceled")
    let canceledEvents = try childLifecycleEvents(
        home: canceled.home, bundle: canceled.bundle, identity: canceled.identity)
    XCTAssertEqual(
        canceledEvents.filter { $0.type == TimelineEventType.childLifecycle }
            .compactMap { $0.payload["state"]?.stringValue },
        ["running", "canceled"])
    await finishChildLifecycleRun(canceled)
}

func test_nativeChildTerminalAppendFailureCannotPresentSuccess() async throws {
    let provider = ChildLifecycleProvider(mode: .delayed)
    let fixture = try await prepareChildLifecycleRun(
        provider: provider, name: "child-terminal-failure")
    _ = await fixture.agent.serveCallback(kind: "spawn", payload: .object([
        "prompt": .string("terminal receipt must fail"), "name": .string("unrecordable"),
    ]))
    for _ in 0..<100 where provider.callCount == 0 {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    await fixture.bundle.injectWriterFailure(.beforeWrite, in: .work)
    await fixture.runner.stopBackgroundChildren()
    if case .failed = (await fixture.bundle.status).health {
        // Expected: an ambiguous native terminal append latches the bundle.
    } else {
        XCTFail("terminal lifecycle failure must latch the native bundle")
    }
    let tree = AgentTreeReader.read(home: fixture.home)
    XCTAssertTrue(
        tree.allNodes.first { $0.name == "unrecordable" }?.status == "failed",
        "legacy child projection must not report completed after native failure")
    await finishChildLifecycleRun(fixture, outcome: .failed)
}

let casesChildLifecycle: [Case] = [
    ("phase1 child lifecycle: closed admission refuses without a running child", {
        try await test_nativeChildStartRefusalIsNotProjectedAsRunning()
    }),
    ("phase1 child lifecycle: completion records running and done provenance", {
        try await test_nativeChildRunnerRecordsCompletionWithParentRunProvenance()
    }),
    ("phase1 child lifecycle: failure and cancellation have distinct terminal records", {
        try await test_nativeChildRunnerRecordsFailureAndCancellationDistinctly()
    }),
    ("phase1 child lifecycle: terminal append failure cannot present success", {
        try await test_nativeChildTerminalAppendFailureCannotPresentSuccess()
    }),
]
