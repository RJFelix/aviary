import Foundation
@testable import AviaryCore

func test_nativeQueuedSteerCancellationProducesNotDeliveredOutcome() async throws {
    guard let host = try makeHost(.reference) else { return }
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "queued-cancel-session",
        work: WorkRef(workHostID: hostID, workID: "queued-cancel-work"),
        runID: "queued-cancel-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "queued-client",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "queued-cancel-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    let bridge = try NativeSessionCommandJournal(
        identity: identity, nativeJournal: bundle, legacyProjection: writer)
    let controller = SessionCommandController(
        identity: identity, capabilities: Agent.inHouseCommandCapabilities,
        journal: bridge)

    let startReceipt = await controller.admitAndCommitReceipt(
        .start(prompt: "hold"), actorID: "queued-client", commandID: "queued-start",
        causalCursor: await bundle.latestWorkCursor)
    guard case .accepted(let start) = startReceipt.admission else {
        XCTFail("Start should be admitted")
        return
    }
    XCTAssertNotNil(await controller.awaitDispatch(commandID: start.commandID))
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: start.commandID))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: start.commandID))

    let provider = CooperativeCancellationProvider()
    let agent = Agent(
        provider: provider, host: host, writer: writer,
        hostSession: identity.workID,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "brief"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    let sendTask = Task {
        await agent.send("hold") { delivery in
            switch delivery {
            case .delivered:
                _ = await controller.recordDelivered(commandID: start.commandID)
            case .notDelivered(let reason):
                _ = await controller.recordNotDelivered(
                    commandID: start.commandID, reason: reason)
            case .notAttempted, .queued, .indeterminate:
                break
            }
        }
    }
    for _ in 0..<200 where !provider.hasStarted {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(provider.hasStarted)

    let steerReceipt = await controller.admitAndCommitReceipt(
        .steer(text: "late steering"), actorID: "queued-client",
        commandID: "queued-steer", causalCursor: await bundle.latestWorkCursor)
    guard case .accepted(let steer) = steerReceipt.admission else {
        XCTFail("Steer should be admitted while the provider is active")
        sendTask.cancel()
        _ = await sendTask.value
        return
    }
    XCTAssertNotNil(await controller.awaitDispatch(commandID: steer.commandID))
    let accepted = await agent.steer("late steering") { delivery in
        switch delivery {
        case .delivered:
            _ = await controller.recordDelivered(commandID: steer.commandID)
        case .notDelivered(let reason):
            _ = await controller.recordNotDelivered(
                commandID: steer.commandID, reason: reason)
        case .notAttempted, .queued, .indeterminate:
            break
        }
    }
    XCTAssertTrue(accepted)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: steer.commandID))

    await agent.cancel()
    sendTask.cancel()
    XCTAssertEqual(await sendTask.value, .cancelled)
    _ = try await bundle.finishRun(outcome: .canceled)
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "queued-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let work = WorkReducer.reduce(read.records.map(\.event))
    XCTAssertEqual(work.commands[start.commandID]?.state, .delivered)
    XCTAssertEqual(work.commands[steer.commandID]?.state, .notDelivered)
    XCTAssertNil(work.activeRun)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
}

let casesCommandDeliveryOutcome: [Case] = [
    ("phase1 command outcome: queued steer cancellation is terminally not delivered", {
        try await test_nativeQueuedSteerCancellationProducesNotDeliveredOutcome()
    }),
]
