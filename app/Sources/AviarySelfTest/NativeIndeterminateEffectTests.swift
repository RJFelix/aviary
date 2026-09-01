import Foundation
@testable import AviaryCore

func test_nativePythonTransportLossAfterObservableEffectIsIndeterminate() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let marker = home.root.appending(path: "python-effect.txt")
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "indeterminate-python-session",
        work: WorkRef(workHostID: hostID, workID: "indeterminate-python-work"),
        runID: "indeterminate-python-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "effect-client",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "indeterminate-python-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)

    _ = try await host.start()
    let hostSession = try await host.createSession(id: identity.workID, cwd: "/tmp")
    let agent = Agent(
        provider: OpenAICompletionsProvider(
            id: "unused", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
        host: host, writer: writer, hostSession: hostSession,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "brief"),
        nativeJournal: bundle)

    let code = """
        with open(r'\(marker.path)', 'w') as stream:
            stream.write('effect happened')
            stream.flush()
        import os
        os._exit(9)
        """
    let result = await agent.executeForTesting(
        id: "kill-host", name: "python", arguments: .object(["code": .string(code)]))
    XCTAssertTrue(result.1)
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "effect happened")

    await host.stop()
    _ = try await bundle.finishRun(outcome: .indeterminate)
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "effect-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let events = read.records.map(\.event)
    let pythonAction = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionIntent
            && $0.payload["kind"]?.stringValue == ActionKind.python.rawValue
    }?.action)
    let outcome = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionOutcome && $0.action == pythonAction
    })
    XCTAssertEqual(
        outcome.payload["state"]?.stringValue,
        ActionExecutionState.indeterminateEffect.rawValue)
    XCTAssertEqual(
        outcome.payload["failure_kind"]?.stringValue,
        ActionFailureKind.indeterminateEffect.rawValue)
    XCTAssertEqual(
        outcome.payload["retry_safety"]?.stringValue,
        ActionRetrySafety.unsafe.rawValue)
}

func test_nativeHookTransportFailureDoesNotSucceedOrStartPython() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "hook-transport-session",
        work: WorkRef(workHostID: hostID, workID: "hook-transport-work"),
        runID: "hook-transport-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "hook-client",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "hook-transport-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    let agent = Agent(
        provider: OpenAICompletionsProvider(
            id: "unused", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
        host: host, writer: writer, hostSession: identity.workID,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "brief"),
        nativeJournal: bundle)
    await agent.enableHooks(true)

    let result = await agent.executeForTesting(
        id: "hook-down", name: "python",
        arguments: .object(["code": .string("raise RuntimeError('must not run')")]))
    XCTAssertTrue(result.1)
    XCTAssertTrue(result.0.contains("Python was not started"))

    _ = try await bundle.finishRun(outcome: .failed)
    try await bundle.closeChecked()
    try await writer.closeChecked()
    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "hook-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let events = read.records.map(\.event)
    let intents = events.filter { $0.type == TimelineEventType.actionIntent }
    XCTAssertEqual(intents.count, 1)
    XCTAssertEqual(intents.first?.payload["kind"]?.stringValue, ActionKind.hook.rawValue)
    let outcome = try XCTUnwrap(events.first { $0.type == TimelineEventType.actionOutcome })
    XCTAssertEqual(
        outcome.payload["state"]?.stringValue,
        ActionExecutionState.indeterminateEffect.rawValue)
    XCTAssertNotEqual(outcome.payload["state"]?.stringValue, ActionExecutionState.succeeded.rawValue)
}

let casesNativeIndeterminateEffects: [Case] = [
    ("phase1 native effects: Python transport loss preserves indeterminate effect", {
        try await test_nativePythonTransportLossAfterObservableEffectIsIndeterminate()
    }),
    ("phase1 native effects: hook transport failure blocks Python", {
        try await test_nativeHookTransportFailureDoesNotSucceedOrStartPython()
    }),
]
