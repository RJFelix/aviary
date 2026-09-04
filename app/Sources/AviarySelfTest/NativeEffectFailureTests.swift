import Foundation
@testable import AviaryCore

private final class ImmediateNativeProvider: ChatProvider, @unchecked Sendable {
    let id = "immediate-native"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("done"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private final class OutcomeJournalFailingProvider: ChatProvider, @unchecked Sendable {
    let id = "outcome-journal-failing"
    private let bundle: RunJournalBundle
    private let lock = NSLock()
    private var count = 0

    init(bundle: RunJournalBundle) { self.bundle = bundle }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        count += 1
        lock.unlock()
        return AsyncThrowingStream { [bundle] continuation in
            Task {
                // The provider effect has crossed only after Agent durably wrote intent/start.
                // Fail the next Work append so its terminal outcome becomes indeterminate.
                await bundle.injectWriterFailure(.beforeWrite, in: .work)
                continuation.yield(.textDelta("must not become a committed answer"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

private func effectFailureFixture(
    name: String
) async throws -> (AgentHome, SessionWorkIdentity, RunJournalBundle, SessionWriter, RuntimeHost, String) {
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "\(name)-session",
        work: WorkRef(workHostID: hostID, workID: "\(name)-work"),
        runID: "\(name)-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "effect-test",
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
    let hostSession = try await host.createSession(id: identity.workID, cwd: "/tmp")
    return (home, identity, bundle, writer, host, hostSession)
}

private func effectFailureWorkEvents(
    home: AgentHome, identity: SessionWorkIdentity, bundle: RunJournalBundle
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "effect-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertNil(read.quarantinedSuffix)
    XCTAssertNil(read.truncatedTail)
    return read.records.map(\.event)
}

func test_nativeRunnerPreparationRecordsRuntimeNamespaceAction() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "runner-native-session",
        work: WorkRef(workHostID: hostID, workID: "runner-native-work"),
        runID: "runner-native-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "runner-test",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "runner-native-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    guard let host = try makeHost(.reference) else {
        try await bundle.closeChecked()
        try await writer.closeChecked()
        return
    }
    _ = try await host.start()
    let runner = AgentRunner(
        provider: ImmediateNativeProvider(), host: host,
        settings: .init(
            home: home, cwd: "/tmp", model: fakeModel(), systemPrompt: "brief",
            identity: identity, writer: writer, nativeJournal: bundle))

    _ = try await runner.prepare()
    await runner.stopMCPServers()
    await host.stop()
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try effectFailureWorkEvents(home: home, identity: identity, bundle: bundle)
    let runtimeIntents = events.filter {
        $0.type == TimelineEventType.actionIntent
            && $0.payload["kind"]?.stringValue == ActionKind.runtime.rawValue
    }
    XCTAssertEqual(runtimeIntents.count, 1)
    XCTAssertEqual(
        events.filter { $0.type == TimelineEventType.actionOutcome }.count, 1)
    XCTAssertTrue(WorkReducer.reduce(events).actions.values.allSatisfy { $0.state.isTerminal })
}

func test_nativeRunnerRecordsAllFailedHookLoadAsFailedAction() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hookDirectory = home.root.appending(path: "broken-hooks", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
    let brokenHook = hookDirectory.appending(path: "broken.py")
    try "import a_module_that_does_not_exist\n".write(
        to: brokenHook, atomically: true, encoding: .utf8)

    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "failed-hook-session",
        work: WorkRef(workHostID: hostID, workID: "failed-hook-work"),
        runID: "failed-hook-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "failed-hook-test",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "failed-hook-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    guard let host = try makeHost(.reference) else {
        try await bundle.closeChecked()
        try await writer.closeChecked()
        return
    }
    _ = try await host.start()
    let runner = AgentRunner(
        provider: ImmediateNativeProvider(), host: host,
        settings: .init(
            home: home, cwd: "/tmp", model: fakeModel(), systemPrompt: "brief",
            hookPaths: [brokenHook.path], identity: identity, writer: writer,
            nativeJournal: bundle))

    _ = try await runner.prepare()
    await runner.stopMCPServers()
    await host.stop()
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try effectFailureWorkEvents(home: home, identity: identity, bundle: bundle)
    let hookOutcome = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionOutcome
            && $0.payload["kind"]?.stringValue == ActionKind.hook.rawValue
    })
    XCTAssertEqual(
        hookOutcome.payload["state"]?.stringValue,
        ActionExecutionState.failed.rawValue)
    XCTAssertEqual(
        hookOutcome.payload["failure_kind"]?.stringValue,
        ActionFailureKind.task.rawValue)
}

func test_nativeProviderDoesNotRunWhenIntentCannotBeCommitted() async throws {
    guard let server = try FakeProviderServer(script: [["text": "must not be requested"]])
    else { return }
    defer { server.stop() }
    let (home, identity, bundle, writer, host, hostSession) = try await effectFailureFixture(
        name: "permit-denied")
    defer { try? FileManager.default.removeItem(at: home.root) }
    _ = try await bundle.commitInput(
        text: "do not call", deliveryMode: .delivered,
        command: CommandRef(
            commandID: "permit-denied-input", client: ClientRef("test"),
            causalCursor: await bundle.latestWorkCursor))
    let agent = Agent(
        provider: OpenAICompletionsProvider(
            id: "fake", baseURL: server.baseURL, apiKey: "test-key"),
        host: host, writer: writer, hostSession: hostSession,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "brief"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    await bundle.injectWriterFailure(.beforeWrite, in: .work)

    guard case .failed = await agent.send("do not call") else {
        XCTFail("the Agent must fail when the provider action cannot obtain a permit")
        return
    }
    XCTAssertTrue(try server.recordedRequests().isEmpty)
    try await writer.closeChecked()
    try await host.destroySession(hostSession)
    await host.stop()
    do {
        try await bundle.closeChecked()
        XCTFail("a latched Work writer must report partial close health")
    } catch RunJournalBundleError.closeFailed {
        // Expected: the durable prefix remains readable below.
    }
    let events = try effectFailureWorkEvents(home: home, identity: identity, bundle: bundle)
    XCTAssertTrue(events.filter { $0.type == TimelineEventType.actionStarted }.isEmpty)
}

func test_nativeOutcomeFailureStopsAfterOneEffectAndRequiresRecovery() async throws {
    let (home, identity, bundle, writer, host, hostSession) = try await effectFailureFixture(
        name: "outcome-failure")
    defer { try? FileManager.default.removeItem(at: home.root) }
    _ = try await bundle.commitInput(
        text: "one call", deliveryMode: .delivered,
        command: CommandRef(
            commandID: "outcome-failure-input", client: ClientRef("test"),
            causalCursor: await bundle.latestWorkCursor))
    let provider = OutcomeJournalFailingProvider(bundle: bundle)
    let agent = Agent(
        provider: provider, host: host, writer: writer, hostSession: hostSession,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "brief"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))

    guard case .failed = await agent.send("one call") else {
        XCTFail("an unrecordable provider outcome must fail the run")
        return
    }
    XCTAssertEqual(provider.callCount, 1)
    try await writer.closeChecked()
    try await host.destroySession(hostSession)
    await host.stop()
    do {
        try await bundle.closeChecked()
        XCTFail("an ambiguous outcome must report partial close health")
    } catch RunJournalBundleError.closeFailed {
        // Expected: recovery reads the synchronized prefix, not a claimed terminal outcome.
    }

    let events = try effectFailureWorkEvents(home: home, identity: identity, bundle: bundle)
    let work = WorkReducer.reduce(events)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionStarted }.count, 1)
    XCTAssertTrue(events.filter { $0.type == TimelineEventType.actionOutcome }.isEmpty)
    XCTAssertEqual(work.activeActionIDs.count, 1)
    XCTAssertEqual(work.actions.values.first?.state, .running)

    let resumedIdentity = SessionWorkIdentity(
        sessionID: identity.sessionID, work: identity.work, runID: "recovery-attempt")
    do {
        _ = try await RunJournalBundle.openForExecution(
            home: home, identity: resumedIdentity, actorID: "recovery-test")
        XCTFail("an unfinished effect must require explicit recovery")
    } catch RunJournalBundleError.unfinishedActions(let actionIDs) {
        XCTAssertEqual(actionIDs.count, 1)
    }
}

let casesNativeEffectFailure: [Case] = [
    ("phase1 native effects: runner preparation journals runtime namespace creation", {
        try await test_nativeRunnerPreparationRecordsRuntimeNamespaceAction()
    }),
    ("phase1 native effects: all-failed hook load is a failed action", {
        try await test_nativeRunnerRecordsAllFailedHookLoadAsFailedAction()
    }),
    ("phase1 native effects: provider is denied when intent cannot commit", {
        try await test_nativeProviderDoesNotRunWhenIntentCannotBeCommitted()
    }),
    ("phase1 native effects: outcome ambiguity stops later effects and requires recovery", {
        try await test_nativeOutcomeFailureStopsAfterOneEffectAndRequiresRecovery()
    }),
]
