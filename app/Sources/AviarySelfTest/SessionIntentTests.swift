import Foundation
@testable import AviaryCore

private func intentIdentity() -> SessionWorkIdentity {
    SessionWorkIdentity(
        sessionID: "intent-session",
        work: WorkRef(workHostID: "intent-host", workID: "intent-work"),
        runID: "intent-run")
}

private enum CommandJournalTestError: Error, Sendable {
    case delivery
}

private actor RecordingSessionCommandJournal: SessionCommandJournal {
    private(set) var intents: [SessionCommandIntent] = []
    private(set) var deliveries: [(SessionCommandIntent, Date)] = []
    private var failNextDelivery = false

    func commitIntent(_ intent: SessionCommandIntent) async throws {
        intents.append(intent)
    }

    func markDelivered(_ intent: SessionCommandIntent, at timestamp: Date) async throws {
        if failNextDelivery {
            failNextDelivery = false
            throw CommandJournalTestError.delivery
        }
        deliveries.append((intent, timestamp))
    }

    func failDeliveryOnce() {
        failNextDelivery = true
    }
}

private actor HeldDeliverySessionCommandJournal: SessionCommandJournal {
    private(set) var deliveryStarted = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func commitIntent(_ intent: SessionCommandIntent) async throws {}

    func markDelivered(_ intent: SessionCommandIntent, at timestamp: Date) async throws {
        deliveryStarted = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func releaseDelivery() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

func test_sessionCommandControllerJournalSeamPreservesIdentityAndDeliveryBoundaries() async throws {
    let identity = intentIdentity()
    let journal = RecordingSessionCommandJournal()
    let controller = SessionCommandController(identity: identity, journal: journal)
    let admittedAt = Date(timeIntervalSince1970: 123)
    let deliveredAt = Date(timeIntervalSince1970: 456)

    let result = await controller.admitAndCommit(
        .start(prompt: "hello"), actorID: "gui", commandID: "start", timestamp: admittedAt)
    guard case .accepted(let admitted) = result else {
        XCTFail("the supplied command journal should admit and commit start")
        return
    }
    let intents = await journal.intents
    XCTAssertEqual(intents.count, 1)
    XCTAssertEqual(intents.first?.identity, identity)
    XCTAssertEqual(intents.first?.commandID, admitted.commandID)
    XCTAssertEqual(intents.first?.sequence, admitted.sequence)
    XCTAssertEqual(intents.first?.timestamp, admittedAt)
    XCTAssertTrue((await journal.deliveries).isEmpty, "admission must not claim delivery")

    XCTAssertEqual(await controller.awaitDispatch(commandID: admitted.commandID)?.commandID, "start")
    // Start's dispatch permit covers setup; its actual input delivery is acknowledged later.
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: admitted.commandID))
    XCTAssertTrue(await controller.recordDelivered(commandID: admitted.commandID, timestamp: deliveredAt))
    XCTAssertTrue(
        await controller.recordDelivered(commandID: admitted.commandID, timestamp: deliveredAt),
        "delivery receipt retries are idempotent")
    let deliveries = await journal.deliveries
    XCTAssertEqual(deliveries.count, 1)
    XCTAssertEqual(deliveries.first?.0.identity, identity)
    XCTAssertEqual(deliveries.first?.0.commandID, admitted.commandID)
    XCTAssertEqual(deliveries.first?.1, deliveredAt)
}

func test_sessionCommandControllerInstallsLaunchJournalOnlyBeforeAdmission() async throws {
    let first = RecordingSessionCommandJournal()
    let replacement = RecordingSessionCommandJournal()
    let controller = SessionCommandController(identity: intentIdentity(), journal: first)

    XCTAssertTrue(await controller.installJournalBeforeAdmission(replacement))
    let result = await controller.admitAndCommit(
        .start(prompt: "hello"), actorID: "gui", commandID: "start")
    guard case .accepted = result else {
        XCTFail("the replacement journal should admit Start")
        return
    }
    XCTAssertTrue((await first.intents).isEmpty)
    XCTAssertEqual((await replacement.intents).map(\.commandID), ["start"])
    XCTAssertFalse(
        await controller.installJournalBeforeAdmission(first),
        "journal authority cannot change after admission begins")
}

func test_sessionCommandControllerJournalDeliveryFailureFailsClosedAfterCrossing() async throws {
    let journal = RecordingSessionCommandJournal()
    let controller = SessionCommandController(identity: intentIdentity(), journal: journal)
    _ = await controller.admitAndCommit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertEqual(await controller.awaitDispatch(commandID: "start")?.commandID, "start")
    await journal.failDeliveryOnce()

    XCTAssertFalse(await controller.acknowledgeDelivered(commandID: "start"))
    XCTAssertEqual(await controller.state, .failed)
    XCTAssertTrue(await controller.isJournalUnavailable)
    XCTAssertFalse(
        await controller.acknowledgeDispatched(commandID: "start"),
        "a failed delivery receipt still releases the crossed dispatch owner")

    // End remains the only local teardown permit after an ambiguous native delivery write.
    let ending = await controller.admitAndCommit(.endRun, actorID: "gui", commandID: "end")
    guard case .accepted(let end) = ending else {
        XCTFail("End should remain available for teardown")
        return
    }
    XCTAssertEqual(await controller.awaitDispatch(commandID: end.commandID)?.commandID, end.commandID)
    XCTAssertTrue(await controller.acknowledgeDelivered(commandID: end.commandID))
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: end.commandID))
    XCTAssertEqual(await controller.state, .ended)
}

func test_sessionCommandControllerDeliveryWaitersHonorTheFirstTerminalOutcome() async throws {
    let journal = HeldDeliverySessionCommandJournal()
    let controller = SessionCommandController(identity: intentIdentity(), journal: journal)
    let receipt = await controller.admitAndCommitReceipt(
        .start(prompt: "held"), actorID: "gui", commandID: "held-delivery")
    guard case .accepted(let admitted) = receipt.admission else {
        XCTFail("the held command should be admitted")
        return
    }

    let delivered = Task {
        await controller.recordDelivered(commandID: admitted.commandID)
    }
    for _ in 0..<100 where !(await journal.deliveryStarted) {
        await Task.yield()
    }
    XCTAssertTrue(await journal.deliveryStarted, "delivery journal call should be held")

    // This waiter races the in-flight delivery, but it must not inherit delivery's success.
    let notDelivered = Task {
        await controller.recordNotDelivered(
            commandID: admitted.commandID, reason: "a competing terminal report")
    }
    await journal.releaseDelivery()

    XCTAssertTrue(await delivered.value)
    XCTAssertFalse(await notDelivered.value)
    XCTAssertEqual(
        await controller.receipt(for: admitted.commandID)?.delivery,
        .delivered(referenceID: nil))
}

func test_sessionWriterCanBePassedThroughCommandJournalSeam() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let identity = intentIdentity()
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
    let controller = SessionCommandController(identity: identity, journal: writer)

    let result = await controller.admitAndCommit(
        .start(prompt: "legacy"), actorID: "gui", commandID: "start",
        timestamp: Date(timeIntervalSince1970: 123))
    guard case .accepted(let admitted) = result else {
        XCTFail("SessionWriter must remain a command journal")
        return
    }
    XCTAssertEqual(await controller.awaitDispatch(commandID: admitted.commandID)?.commandID, "start")
    XCTAssertTrue(await controller.acknowledgeDelivered(commandID: admitted.commandID))
    try await writer.closeChecked()

    let raw = try String(contentsOf: writer.fileURL, encoding: .utf8)
    XCTAssertTrue(raw.contains("\"customType\":\"aviary.command-intent.v1\""))
    XCTAssertTrue(raw.contains("\"commandID\":\"start\""))
}

func test_sessionWriterCommandIntentIsRawReadableButConversationHidden() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let identity = intentIdentity()
    let writer = try SessionWriter(
        home: home, cwd: "/tmp/project", model: nil, identity: identity)
    let intentID = try await writer.appendCommandIntent(
        commandID: "intent-1", command: .send(prompt: "private prompt"), identity: identity,
        actorID: "gui-a", controllerSequence: 7, previousState: .idle, state: .running,
        timestamp: Date(timeIntervalSince1970: 123))
    try await writer.closeChecked()

    let lines = try String(contentsOf: writer.fileURL, encoding: .utf8).split(separator: "\n")
    let raw = try XCTUnwrap(lines.compactMap { JSONValue.parse(Data($0.utf8)) }.first {
        $0["customType"]?.stringValue == "aviary.command-intent.v1"
    })
    XCTAssertEqual(raw["id"]?.stringValue, intentID)
    XCTAssertEqual(raw["commandID"]?.stringValue, "intent-1")
    XCTAssertEqual(raw["command"]?["kind"]?.stringValue, "send")
    XCTAssertEqual(raw["command"]?["value"]?.stringValue, "private prompt")
    XCTAssertEqual(raw["identity"]?["sessionID"]?.stringValue, identity.sessionID)
    XCTAssertEqual(raw["identity"]?["workHostID"]?.stringValue, identity.workHostID)
    XCTAssertEqual(raw["identity"]?["workID"]?.stringValue, identity.workID)
    XCTAssertEqual(raw["identity"]?["runID"]?.stringValue, identity.runID)
    XCTAssertEqual(raw["actorID"]?.stringValue, "gui-a")
    XCTAssertEqual(raw["controllerSequence"]?.intValue, 7)
    XCTAssertEqual(raw["previousState"]?.stringValue, "idle")
    XCTAssertEqual(raw["state"]?.stringValue, "running")
    XCTAssertEqual(raw["intentTimestamp"]?.stringValue, "1970-01-01T00:02:03.000Z")
    XCTAssertEqual(raw["hidden"]?.boolValue, true)

    let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
    XCTAssertFalse(transcript.items.contains { $0.id == intentID })
}

func test_sessionWriterLatchesBeforePartialAndPostWriteSyncFailures() async throws {
    for point in SessionWriter.FailurePoint.allCases {
        let home = scratchHome()
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil)
        await writer.injectFailure(point)
        do {
            _ = try await writer.appendUser("hello")
            XCTFail("failure at \(point) should throw")
        } catch { }
        let health = await writer.writerHealth
        guard case .failed = health else {
            XCTFail("failure at \(point) must latch writer health")
            continue
        }
        do {
            _ = try await writer.appendNote("must fail fast")
            XCTFail("latched writer should fail fast")
        } catch { }
        try? await writer.closeChecked()
        try? FileManager.default.removeItem(at: home.root)
    }
}

func test_sessionWriterResumeQuarantinesPartialTailBeforeNewRun() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let identity = intentIdentity()
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
    await writer.injectFailure(.partialWrite)
    do {
        _ = try await writer.appendUser("lost at the partial boundary")
        XCTFail("partial append should fail")
    } catch { }
    try? await writer.closeChecked()

    // Resume must preserve the malformed evidence as an unparsed line, but terminate it before
    // writing run_start. Otherwise run_start would be concatenated to the fragment and no new
    // branch could be recovered by the JSONL reader.
    let resumed = try SessionWriter(
        home: home, resuming: identity.sessionID, cwd: "/tmp", model: nil)
    _ = try await resumed.appendUser("survived resume")
    try await resumed.closeChecked()

    let data = try Data(contentsOf: resumed.fileURL)
    XCTAssertTrue(data.last == UInt8(ascii: "\n"))
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    XCTAssertTrue(lines.count >= 4, "header, malformed quarantined line, run_start, and user")
    XCTAssertTrue(lines.dropFirst().contains { JSONValue.parse(Data($0))?["type"]?.stringValue == "run_start" })
    let transcript = try XCTUnwrap(SessionParser.parse(fileURL: resumed.fileURL))
    XCTAssertTrue(transcript.unparsedLines >= 1, "the partial fragment remains visible as corruption")
    XCTAssertTrue(transcript.items.contains { $0.kind == .user && $0.plainText == "survived resume" })
}

func test_sessionCommandControllerCommitsIntentAndFailsClosedOnAmbiguity() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let identity = intentIdentity()
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
    let controller = SessionCommandController(identity: identity, writer: writer)

    let committed = await controller.admitAndCommit(
        .start(prompt: "hello"), actorID: "gui", commandID: "start")
    guard case .accepted(let start) = committed else {
        XCTFail("healthy writer should commit start")
        return
    }
    XCTAssertEqual(await controller.state, .preparing)
    XCTAssertEqual(await controller.awaitDispatch(commandID: start.commandID)?.commandID, "start")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "start"))

    await writer.injectFailure(.afterWriteBeforeSync)
    let failed = await controller.admitAndCommit(
        .send(prompt: "next"), actorID: "gui", commandID: "send")
    XCTAssertEqual(
        failed,
        .rejected(commandID: "send", reason: .journalUnavailable))
    XCTAssertEqual(await controller.state, .failed)
    XCTAssertTrue(await controller.isJournalUnavailable)
    XCTAssertEqual(
        await controller.admit(.send(prompt: "later"), actorID: "gui", commandID: "later"),
        .rejected(commandID: "later", reason: .journalUnavailable))

    // End is the only degraded permit allowed after a wedged journal. It bypasses the failed
    // command's dispatch owner so teardown can still release the runtime/process.
    let ending = await controller.admitAndCommit(.endRun, actorID: "gui", commandID: "end")
    guard case .accepted = ending else {
        XCTFail("End should obtain the degraded teardown permit")
        return
    }
    XCTAssertEqual(await controller.awaitDispatch(commandID: "end")?.commandID, "end")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "end"))
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: "end"))
    XCTAssertEqual(await controller.state, .ended)
    try? await writer.closeChecked()
}

func test_sessionCommandControllerEndIntentFailuresRemainTeardownPermits() async throws {
    for point in SessionWriter.FailurePoint.allCases {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let identity = intentIdentity()
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
        let controller = SessionCommandController(identity: identity, writer: writer)
        await writer.injectFailure(point)

        let ending = await controller.admitAndCommit(.endRun, actorID: "gui", commandID: "end")
        guard case .accepted(let end) = ending else {
            XCTFail("End admission must remain accepted at \(point.rawValue)")
            continue
        }
        XCTAssertEqual(await controller.state, .ending)
        XCTAssertTrue(await controller.isJournalUnavailable)
        XCTAssertEqual(
            await controller.awaitDispatch(commandID: end.commandID)?.commandID, end.commandID)
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: end.commandID))
        XCTAssertTrue(await controller.acknowledgeEnd(commandID: end.commandID))
        XCTAssertEqual(await controller.state, .ended)
        try? await writer.closeChecked()
    }
}

func test_sessionCommandControllerFailsQueuedWaitersWhenIntentCommitLatchesJournal() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let identity = intentIdentity()
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
    let controller = SessionCommandController(identity: identity, writer: writer)

    _ = await controller.admitAndCommit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertEqual(await controller.awaitDispatch(commandID: "start")?.commandID, "start")
    // Keep the first command's dispatch owner outstanding. The later committed command must
    // genuinely wait behind this owner; merely admitting an uncommitted command is not a queue.
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "start"))
    let queued = await controller.admitAndCommit(
        .send(prompt: "queued"), actorID: "gui", commandID: "queued")
    guard case .accepted(let queuedCommand) = queued else {
        XCTFail("send should be admitted and committed while start owns dispatch")
        return
    }
    let waiter = Task { await controller.awaitDispatch(commandID: queuedCommand.commandID) }
    try await Task.sleep(nanoseconds: 1_000_000)
    await writer.injectFailure(.beforeWrite)
    let ending = await controller.admitAndCommit(.endRun, actorID: "gui", commandID: "end-failing")
    guard case .accepted(let end) = ending else {
        XCTFail("End should still obtain a degraded permit after the later intent fails")
        return
    }
    XCTAssertNil(await waiter.value)
    XCTAssertEqual(await controller.awaitDispatch(commandID: end.commandID)?.commandID, end.commandID)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: end.commandID))
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: end.commandID))
    XCTAssertEqual(await controller.state, .ended)
    try? await writer.closeChecked()
}

func test_sessionCommandControllerEndBypassesHeldCommitAndStaysEnded() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let identity = intentIdentity()
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
    let controller = SessionCommandController(identity: identity, writer: writer)

    _ = await controller.admitAndCommit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertEqual(await controller.awaitDispatch(commandID: "start")?.commandID, "start")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "start"))

    let gate = SessionWriter.IntentCommitGate()
    await writer.installIntentCommitGate(gate)
    let heldSend = Task {
        await controller.admitAndCommit(.send(prompt: "held"), actorID: "gui", commandID: "held")
    }
    var sawCommitting = false
    for _ in 0..<100 {
        if await controller.state == .committing {
            sawCommitting = true
            break
        }
        await Task.yield()
    }
    XCTAssertTrue(sawCommitting, "send must be held after admission and before its writer append")

    // End must not await the held SessionWriter actor call. It receives a degraded, local-only
    // teardown permit and can release the runtime even though the prior intent is unresolved.
    let ending = await controller.admitAndCommit(.endRun, actorID: "gui", commandID: "end")
    guard case .accepted(let end) = ending else {
        XCTFail("End should obtain a degraded permit while a non-End commit is held")
        await gate.release()
        _ = await heldSend.value
        return
    }
    XCTAssertEqual(await controller.state, .ending)
    XCTAssertEqual(await controller.awaitDispatch(commandID: end.commandID)?.commandID, "end")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: end.commandID))
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: end.commandID))
    XCTAssertEqual(await controller.state, .ended)

    // Let the old commit finish. Its success must not resurrect the run or make its stale permit
    // dispatchable after End has completed.
    await gate.release()
    let heldResult = await heldSend.value
    guard case .accepted = heldResult else {
        XCTFail("the held write should complete successfully after release")
        return
    }
    XCTAssertEqual(await controller.state, .ended)
    XCTAssertNil(await controller.awaitDispatch(commandID: "held"))
    try? await writer.closeChecked()
}

func test_sessionCommandControllerLateEndCannotDispatchAfterNewerEndCompletes() async throws {
    let failurePoints: [SessionWriter.FailurePoint?] = [nil, .beforeWrite]
    for failurePoint in failurePoints {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let identity = intentIdentity()
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
        let controller = SessionCommandController(identity: identity, writer: writer)
        let gate = SessionWriter.IntentCommitGate()
        await writer.installIntentCommitGate(gate)

        let first = Task {
            await controller.admitAndCommit(.endRun, actorID: "gui", commandID: "end-1")
        }
        var sawCommitting = false
        for _ in 0..<100 {
            if await controller.state == .committing {
                sawCommitting = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(sawCommitting, "End-1 should be held before its writer append")

        // End-2 supersedes the in-flight End-1 locally and is allowed to complete teardown.
        let second = await controller.admitAndCommit(.endRun, actorID: "gui", commandID: "end-2")
        guard case .accepted(let end2) = second else {
            XCTFail("newer End should obtain a degraded permit")
            await gate.release()
            _ = await first.value
            continue
        }
        XCTAssertEqual(await controller.state, .ending)
        XCTAssertEqual(
            await controller.awaitDispatch(commandID: end2.commandID)?.commandID, end2.commandID)
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: end2.commandID))
        XCTAssertTrue(await controller.acknowledgeEnd(commandID: end2.commandID))
        XCTAssertEqual(await controller.state, .ended)

        if let failurePoint {
            await writer.injectFailure(failurePoint)
        }
        await gate.release()
        let firstResult = await first.value
        guard case .accepted = firstResult else {
            XCTFail("older End remains accepted even when its write is ambiguous")
            continue
        }
        XCTAssertEqual(await controller.state, .ended)
        XCTAssertNil(await controller.awaitDispatch(commandID: "end-1"))
        XCTAssertFalse(await controller.acknowledgeDispatched(commandID: "end-1"))
        XCTAssertFalse(await controller.acknowledgeEnd(commandID: "end-1"))
        try? await writer.closeChecked()
    }
}

func test_sessionCommandControllerLifecycleAckSurvivesHeldSteerAndQueueCommit() async throws {
    for (label, command) in [
        ("steer", SessionCommand.steer(text: "adjust")),
        ("queue", SessionCommand.queueFollowUp(text: "after")),
    ] {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let identity = intentIdentity()
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
        let controller = SessionCommandController(
            identity: identity,
            capabilities: SessionCommandCapabilities(
                supportsSteering: true, supportsQueuedFollowUps: true),
            writer: writer)

        _ = await controller.admitAndCommit(.start(prompt: "run"), actorID: "gui", commandID: "start")
        XCTAssertEqual(await controller.awaitDispatch(commandID: "start")?.commandID, "start")
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "start"))
        XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))
        XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "start"))
        _ = await controller.admitAndCommit(.send(prompt: "turn"), actorID: "gui", commandID: "turn")
        XCTAssertEqual(await controller.awaitDispatch(commandID: "turn")?.commandID, "turn")
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "turn"))

        let gate = SessionWriter.IntentCommitGate()
        await writer.installIntentCommitGate(gate)
        let held = Task {
            await controller.admitAndCommit(command, actorID: "gui", commandID: label)
        }
        var sawCommitting = false
        for _ in 0..<100 {
            if await controller.state == .committing {
                sawCommitting = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(sawCommitting, "\(label) commit should be held")

        // The provider reports the original turn finished while the later command's intent is
        // still being committed. That lifecycle fact must survive the temporary commit state.
        XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "turn"))
        XCTAssertEqual(await controller.state, .idle)

        // The lifecycle acknowledgement also means End must not wait for the held intent merely
        // because the transient commit state has become idle. It takes the degraded permit now.
        let ending = await controller.admitAndCommit(
            .endRun, actorID: "gui", commandID: "end-\(label)")
        guard case .accepted(let end) = ending else {
            XCTFail("End should bypass the held \(label) commit")
            await gate.release()
            _ = await held.value
            continue
        }
        XCTAssertEqual(await controller.state, .ending)
        XCTAssertEqual(
            await controller.awaitDispatch(commandID: end.commandID)?.commandID, end.commandID)
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: end.commandID))
        XCTAssertTrue(await controller.acknowledgeEnd(commandID: end.commandID))
        XCTAssertEqual(await controller.state, .ended)
        await gate.release()
        let result = await held.value
        guard case .accepted(let admitted) = result else {
            XCTFail("\(label) intent should commit after release")
            continue
        }
        XCTAssertEqual(await controller.state, .ended)
        XCTAssertNil(await controller.awaitDispatch(commandID: admitted.commandID))
        try? await writer.closeChecked()
    }
}

func test_sessionCommandControllerHeldSteerFailureAfterTurnFinishMarksFailed() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let identity = intentIdentity()
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: nil, identity: identity)
    let controller = SessionCommandController(
        identity: identity,
        capabilities: SessionCommandCapabilities(supportsSteering: true),
        writer: writer)

    _ = await controller.admitAndCommit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertEqual(await controller.awaitDispatch(commandID: "start")?.commandID, "start")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "start"))
    _ = await controller.admitAndCommit(.send(prompt: "turn"), actorID: "gui", commandID: "turn")
    XCTAssertEqual(await controller.awaitDispatch(commandID: "turn")?.commandID, "turn")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "turn"))

    let gate = SessionWriter.IntentCommitGate()
    await writer.installIntentCommitGate(gate)
    let held = Task {
        await controller.admitAndCommit(.steer(text: "adjust"), actorID: "gui", commandID: "steer")
    }
    for _ in 0..<100 {
        if await controller.state == .committing { break }
        await Task.yield()
    }
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "turn"))
    XCTAssertEqual(await controller.state, .idle)
    await writer.injectFailure(.beforeWrite)
    await gate.release()

    let result = await held.value
    XCTAssertEqual(
        result,
        .rejected(commandID: "steer", reason: .journalUnavailable))
    XCTAssertEqual(await controller.state, .failed)
    XCTAssertTrue(await controller.isJournalUnavailable)
    try? await writer.closeChecked()
}
