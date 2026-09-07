import Foundation
@testable import AviaryCore

private func phase4BModel() -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string("test-model"),
        "provider": .string("fake"),
    ]))
    model.contextWindow = 100_000
    return model
}

private func phase4BHome() -> AgentHome {
    AgentHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aviary-phase4b-agent-test-\(UUID().uuidString)"))
}

private func phase4BHost() throws -> RuntimeHost? {
    guard let root = EngineLocator.repoRoot() else {
        print("      skipped: no repo root found")
        return nil
    }
    let script = root.appending(path: "runtime-hosts/python3/host.py")
    guard FileManager.default.fileExists(atPath: script.path) else {
        print("      skipped: python3 host missing")
        return nil
    }
    return RuntimeHost(
        executable: "/usr/bin/env", arguments: ["python3", script.path],
        parentLifetimeLease: true)
}

private final class Phase4BImmediateProvider: ChatProvider, @unchecked Sendable {
    let id = "phase4b-immediate"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("done"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private final class Phase4BRepositoryReviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false

    func markEntered() {
        lock.lock()
        entered = true
        lock.unlock()
    }

    func hasEntered() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func isReleased() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }
}

private final class Phase4BTerminalEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func receive(_ event: Agent.Event) {
        let value: String
        switch event {
        case .finished(let reason): value = "finished:\(reason)"
        case .failed: value = "failed"
        default: return
        }
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func phase4BWorkEvents(
    home: AgentHome, journal: JournalRef, work: WorkRef
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(work)),
        journal: journal,
        actor: TimelineActor(actorID: "phase4b-review-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertNil(read.quarantinedSuffix)
    XCTAssertNil(read.truncatedTail)
    return read.records.map(\.event)
}

func test_nativeAgentPublishesObservedRepositoryReviewBeforeTurnFinishes() async throws {
    guard let host = try phase4BHost() else { return }
    let home = phase4BHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "phase4b-review-session",
        work: WorkRef(workHostID: hostID, workID: "phase4b-review-work"),
        runID: "phase4b-review-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "phase4b-review-client",
        modelID: phase4BModel().qualifiedID,
        makeAttachmentID: { "phase4b-review-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: phase4BModel(), identity: identity)

    _ = try await host.start()
    let hostSession = try await host.createSession(id: identity.workID, cwd: "/tmp")
    let reviewer = ObservedRepositoryReviewer { _, _, _ in
        ObservedRepositoryGitCommandResult(exitCode: 128)
    }
    let agent = Agent(
        provider: Phase4BImmediateProvider(), host: host, writer: writer,
        hostSession: hostSession,
        config: .init(
            model: phase4BModel(), cwd: "/tmp", systemPrompt: "brief",
            repositoryReviewer: reviewer),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    let terminalEvents = Phase4BTerminalEvents()
    await agent.observe { terminalEvents.receive($0) }

    _ = try await bundle.commitInput(
        text: "inspect", deliveryMode: .delivered,
        command: CommandRef(
            commandID: "phase4b-review-command",
            client: ClientRef("phase4b-review-client"),
            causalCursor: await bundle.latestWorkCursor))
    XCTAssertEqual(await agent.send("inspect"), .completed)
    XCTAssertEqual(terminalEvents.snapshot(), ["finished:stop"])

    try await host.destroySession(hostSession)
    await host.stop()
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try phase4BWorkEvents(
        home: home, journal: bundle.workJournal, work: identity.work)
    let artifactIndex = try XCTUnwrap(events.firstIndex {
        $0.type == TimelineEventType.artifact
            && $0.payload["media_type"]?.stringValue == ObservedRepositoryReview.mediaType
    })
    let artifact = events[artifactIndex]
    let turn = try XCTUnwrap(artifact.turn)
    let action = try XCTUnwrap(artifact.action)
    XCTAssertEqual(artifact.run, RunRef(identity.runID))
    XCTAssertEqual(artifact.session, SessionRef(identity.sessionID))
    XCTAssertEqual(artifact.work, identity.work)
    XCTAssertEqual(artifact.sessionAttachment, bundle.sessionAttachment)
    XCTAssertEqual(artifact.causedByEventID, EventRef(
        journal: bundle.workJournal,
        eventID: events[artifactIndex - 1].eventID))

    let turnStart = try XCTUnwrap(events.firstIndex {
        $0.type == TimelineEventType.turnStarted && $0.turn == turn
    })
    let actionIntent = try XCTUnwrap(events.firstIndex {
        $0.type == TimelineEventType.actionIntent && $0.action == action
    })
    let actionStarted = try XCTUnwrap(events.firstIndex {
        $0.type == TimelineEventType.actionStarted && $0.action == action
    })
    let actionOutcome = try XCTUnwrap(events.firstIndex {
        $0.type == TimelineEventType.actionOutcome && $0.action == action
    })
    let turnFinish = try XCTUnwrap(events.firstIndex {
        $0.type == TimelineEventType.turnFinished && $0.turn == turn
    })
    XCTAssertTrue(turnStart < actionIntent)
    XCTAssertTrue(actionIntent < actionStarted)
    XCTAssertTrue(actionStarted < artifactIndex)
    XCTAssertTrue(artifactIndex < actionOutcome)
    XCTAssertTrue(actionOutcome < turnFinish)
    XCTAssertEqual(
        events[actionIntent].payload["kind"]?.stringValue,
        ActionKind.artifact.rawValue)
    XCTAssertEqual(
        events[actionOutcome].payload["state"]?.stringValue,
        ActionExecutionState.failed.rawValue)

    let referenceValue = try XCTUnwrap(artifact.payload["body_reference"])
    let reference = try JSONDecoder().decode(
        TimelineBodyReference.self, from: JSONEncoder().encode(referenceValue))
    let body = try ContextBodyStore(home: home).read(reference)
    let review = try ObservedRepositoryReview.decode(body)
    XCTAssertEqual(review.status, .failed)
    XCTAssertEqual(review.runID, identity.runID)
    XCTAssertEqual(review.turnID, turn.turnID)
    XCTAssertEqual(reference.mediaType, ObservedRepositoryReview.mediaType)
    XCTAssertEqual(reference.byteCount, body.count)
    XCTAssertEqual(
        reference.digest,
        "sha256:" + AviarySHA256.hash(data: body).description)

    let reduced = WorkReducer.reduce(events)
    XCTAssertNil(reduced.activeTurn)
    XCTAssertTrue(reduced.actions.values.allSatisfy { $0.state.isTerminal })
    XCTAssertTrue(reduced.corruptionReasons.isEmpty)
}

func test_nativeAgentCancellationInterruptsRepositoryReviewAndCancelsTurn() async throws {
    try await phase4BTestGatedTerminalOutcome(closeJournal: false)
}

func test_nativeAgentReviewJournalFailureEmitsOnlyFailure() async throws {
    try await phase4BTestGatedTerminalOutcome(closeJournal: true)
}

private func phase4BTestGatedTerminalOutcome(closeJournal: Bool) async throws {
    guard let host = try phase4BHost() else { return }
    let home = phase4BHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "phase4b-cancel-session",
        work: WorkRef(workHostID: hostID, workID: "phase4b-cancel-work"),
        runID: "phase4b-cancel-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "phase4b-cancel-client",
        modelID: phase4BModel().qualifiedID,
        makeAttachmentID: { "phase4b-cancel-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: phase4BModel(), identity: identity)

    _ = try await host.start()
    let hostSession = try await host.createSession(id: identity.workID, cwd: "/tmp")
    let gate = Phase4BRepositoryReviewGate()
    let reviewer = ObservedRepositoryReviewer { _, _, _ in
        gate.markEntered()
        while !Task.isCancelled && !gate.isReleased() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return ObservedRepositoryGitCommandResult(exitCode: 128, cancelled: Task.isCancelled)
    }
    let agent = Agent(
        provider: Phase4BImmediateProvider(), host: host, writer: writer,
        hostSession: hostSession,
        config: .init(
            model: phase4BModel(), cwd: "/tmp", systemPrompt: "brief",
            repositoryReviewer: reviewer),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    let terminalEvents = Phase4BTerminalEvents()
    await agent.observe { terminalEvents.receive($0) }

    _ = try await bundle.commitInput(
        text: "inspect", deliveryMode: .delivered,
        command: CommandRef(
            commandID: "phase4b-cancel-command",
            client: ClientRef("phase4b-cancel-client"),
            causalCursor: await bundle.latestWorkCursor))
    let send = Task { await agent.send("inspect") }
    for _ in 0..<1_000 where !gate.hasEntered() {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(gate.hasEntered())
    XCTAssertEqual(terminalEvents.snapshot(), [],
                   "model completion cannot announce a settled Turn while review is running")
    if closeJournal {
        try await bundle.closeChecked()
        gate.release()
        if case .failed = await send.value {
            XCTAssertEqual(terminalEvents.snapshot(), ["failed"])
        } else {
            XCTFail("review publication on a closed journal must fail the Turn")
        }
        try await host.destroySession(hostSession)
        await host.stop()
        try await writer.closeChecked()
        return
    }
    let cancellationStarted = Date()
    XCTAssertTrue(await agent.requestCancellation(.agentLoop))
    XCTAssertEqual(await send.value, .cancelled)
    XCTAssertEqual(terminalEvents.snapshot(), ["finished:cancelled"])
    XCTAssertTrue(Date().timeIntervalSince(cancellationStarted) < 2)

    try await host.destroySession(hostSession)
    await host.stop()
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try phase4BWorkEvents(
        home: home, journal: bundle.workJournal, work: identity.work)
    let artifact = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.artifact
            && $0.payload["media_type"]?.stringValue == ObservedRepositoryReview.mediaType
    })
    let referenceValue = try XCTUnwrap(artifact.payload["body_reference"])
    let reference = try JSONDecoder().decode(
        TimelineBodyReference.self, from: JSONEncoder().encode(referenceValue))
    let review = try ObservedRepositoryReview.decode(
        ContextBodyStore(home: home).read(reference))
    XCTAssertEqual(review.status, .cancelled)
    let action = try XCTUnwrap(artifact.action)
    let outcome = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionOutcome && $0.action == action
    })
    XCTAssertEqual(outcome.payload["state"]?.stringValue, ActionExecutionState.canceled.rawValue)
    XCTAssertEqual(outcome.payload["failure_kind"]?.stringValue, ActionFailureKind.cancellation.rawValue)
    let turnFinished = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.turnFinished && $0.turn == artifact.turn
    })
    XCTAssertEqual(turnFinished.payload["outcome"]?.stringValue, RunTurnOutcome.canceled.rawValue)
}

let casesObservedRepositoryReviewAgent: [Case] = [
    ("phase4b repository review: native turn publishes retained review before finish", {
        try await test_nativeAgentPublishesObservedRepositoryReviewBeforeTurnFinishes()
    }),
    ("phase4b repository review: accepted cancellation interrupts observation", {
        try await test_nativeAgentCancellationInterruptsRepositoryReviewAndCancelsTurn()
    }),
    ("phase4b repository review: journal failure emits one terminal failure", {
        try await test_nativeAgentReviewJournalFailureEmitsOnlyFailure()
    }),
]
