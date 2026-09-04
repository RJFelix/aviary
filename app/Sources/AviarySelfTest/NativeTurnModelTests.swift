import Foundation
@testable import AviaryCore

private func nativeTurnModelEvents(
    home: AgentHome, journal: JournalRef, url: URL
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: url), journal: journal,
        actor: TimelineActor(actorID: "turn-model-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        throw RunJournalBundleError.invalidJournal(
            journal: journal, reason: "turn/model fixture journal has an invalid tail")
    }
    return read.records.map(\.event)
}

func test_nativeAgentRecordsTurnPrefixesAndEffectiveModelSwitch() async throws {
    guard let firstServer = try FakeProviderServer(script: [
        ["text": "first answer", "input_tokens": 10, "output_tokens": 2],
    ]) else { print("      skipped: no provider fixture"); return }
    defer { firstServer.stop() }
    guard let secondServer = try FakeProviderServer(script: [
        ["text": "second answer", "input_tokens": 12, "output_tokens": 2],
    ]) else { print("      skipped: no provider fixture"); return }
    defer { secondServer.stop() }
    guard let host = try makeHost(.reference) else { return }

    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "turn-model-session",
        work: WorkRef(workHostID: hostID, workID: "turn-model-work"),
        runID: "turn-model-run")
    let initialModel = fakeModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "turn-model-client",
        modelID: initialModel.qualifiedID,
        makeAttachmentID: { "turn-model-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: initialModel, identity: identity)

    _ = try await host.start()
    let hostSession = try await host.createSession(id: identity.workID, cwd: "/tmp")
    let agent = Agent(
        provider: OpenAICompletionsProvider(
            id: "first", baseURL: firstServer.baseURL, apiKey: "test-key"),
        host: host, writer: writer, hostSession: hostSession,
        config: .init(model: initialModel, cwd: "/tmp", systemPrompt: "brief"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))

    _ = try await bundle.commitInput(
        text: "first", deliveryMode: .delivered,
        command: CommandRef(
            commandID: "turn-model-first", client: ClientRef("turn-model-client"),
            causalCursor: await bundle.latestWorkCursor))
    XCTAssertEqual(await agent.send("first"), .completed)

    var secondModel = fakeModel()
    secondModel.providerID = "second"
    secondModel.id = "second-model"
    secondModel.maxTokens = 2048
    XCTAssertTrue(await agent.switchModel(
        to: secondModel,
        provider: OpenAICompletionsProvider(
            id: "second", baseURL: secondServer.baseURL, apiKey: "test-key")))

    _ = try await bundle.commitInput(
        text: "second", deliveryMode: .delivered,
        command: CommandRef(
            commandID: "turn-model-second", client: ClientRef("turn-model-client"),
            causalCursor: await bundle.latestWorkCursor))
    XCTAssertEqual(await agent.send("second"), .completed)

    try await host.destroySession(hostSession)
    await host.stop()
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try nativeTurnModelEvents(
        home: home, journal: bundle.workJournal,
        url: home.timelineV2WorkJournalURL(identity.work))
    let starts = events.filter { $0.type == TimelineEventType.turnStarted }
    let finishes = events.filter { $0.type == TimelineEventType.turnFinished }
    XCTAssertEqual(starts.count, 2)
    XCTAssertEqual(finishes.count, 2)
    XCTAssertEqual(Set(starts.compactMap(\.turn)), Set(finishes.compactMap(\.turn)))
    XCTAssertNil(WorkReducer.reduce(events).activeTurn)
    XCTAssertEqual(WorkReducer.reduce(events).modelID, secondModel.qualifiedID)
    XCTAssertEqual(
        events.filter { $0.type == TimelineEventType.modelChanged }.count, 1)

    for turn in starts.compactMap(\.turn) {
        let startIndex = try XCTUnwrap(events.firstIndex {
            $0.type == TimelineEventType.turnStarted && $0.turn == turn
        })
        let finishIndex = try XCTUnwrap(events.firstIndex {
            $0.type == TimelineEventType.turnFinished && $0.turn == turn
        })
        XCTAssertTrue(startIndex < finishIndex)
        XCTAssertTrue(events[(startIndex + 1)..<finishIndex].contains {
            $0.type == TimelineEventType.actionIntent
                && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
        })
    }

    XCTAssertEqual(try firstServer.recordedRequests().count, 1)
    XCTAssertEqual(try secondServer.recordedRequests().count, 1)
}

let casesNativeTurnModel: [Case] = [
    ("phase1 native turn/model: live prefixes survive cold reduction", {
        try await test_nativeAgentRecordsTurnPrefixesAndEffectiveModelSwitch()
    }),
]
