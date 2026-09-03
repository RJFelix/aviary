import Foundation
@testable import AviaryCore

private final class NativeCallbackPeer: Agent.PeerDelegate, @unchecked Sendable {
    func peers(excluding sessionID: String) async -> [Agent.Peer] { [] }
    func deliver(
        to peer: String, text: String, from sessionID: String
    ) async -> (session: String, error: String?) { (peer, nil) }
}

private final class NativeCallbackSelf: Agent.SelfDelegate, @unchecked Sendable {
    func deliverToSelf(
        sessionID: String, text: String, from sourceSessionID: String
    ) async -> Bool { true }
}

private final class NativeCallbackChild: Agent.SpawnDelegate, @unchecked Sendable {
    func startBackground(
        prompt: String, name: String?, model: String?, depth: Int
    ) async -> Agent.SpawnStartResult {
        .running(childID: "native-child", name: name ?? "native-child")
    }
    func children() async -> [Agent.ChildStatus] { [] }
}

private func nativeExecutionEvents(
    at url: URL, journal: JournalRef
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: url), journal: journal,
        actor: TimelineActor(actorID: "integration-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        throw RunJournalBundleError.invalidJournal(
            journal: journal, reason: "integration journal has an invalid tail")
    }
    return read.records.map(\.event)
}

private func nativeBridgeFixture(
    sessionID: String, workID: String, runID: String
) async throws -> (AgentHome, SessionWorkIdentity, RunJournalBundle, SessionWriter) {
    let home = scratchHome()
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: sessionID,
        work: WorkRef(workHostID: hostID, workID: workID),
        runID: runID)
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "bridge-client",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "\(sessionID)-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    return (home, identity, bundle, writer)
}

func test_nativeCommandBridgeRecordsAcceptanceAndExactDeliveryOnce() async throws {
    let (home, identity, bundle, writer) = try await nativeBridgeFixture(
        sessionID: "bridge-session", workID: "bridge-work", runID: "bridge-run")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bridge = try NativeSessionCommandJournal(
        identity: identity, nativeJournal: bundle, legacyProjection: writer)
    let controller = SessionCommandController(identity: identity, journal: bridge)

    let start = await controller.admitAndCommit(
        .start(prompt: "hello"), actorID: "gui", commandID: "bridge-start")
    guard case .accepted(let admitted) = start else {
        XCTFail("the native command bridge should accept Start")
        return
    }
    XCTAssertEqual(
        await controller.awaitDispatch(commandID: admitted.commandID)?.commandID,
        admitted.commandID)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: admitted.commandID))
    XCTAssertTrue(await controller.recordDelivered(commandID: admitted.commandID))
    XCTAssertTrue(await controller.recordDelivered(commandID: admitted.commandID))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: admitted.commandID))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: admitted.commandID))

    let ending = await controller.admitAndCommit(
        .endRun, actorID: "gui", commandID: "bridge-end")
    guard case .accepted(let end) = ending else {
        XCTFail("the native command bridge should accept End")
        return
    }
    XCTAssertEqual(
        await controller.awaitDispatch(commandID: end.commandID)?.commandID,
        end.commandID)
    XCTAssertTrue(await controller.acknowledgeDelivered(commandID: end.commandID))
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: end.commandID))
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let sessionEvents = try nativeExecutionEvents(
        at: home.timelineV2SessionJournalURL(SessionRef(identity.sessionID)),
        journal: bundle.sessionJournal)
    let workEvents = try nativeExecutionEvents(
        at: home.timelineV2WorkJournalURL(identity.work), journal: bundle.workJournal)
    XCTAssertEqual(SessionReducer.reduce(sessionEvents).messages.map(\.text), ["hello"])
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.commandAccepted }.count, 2)
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.commandDelivered }.count, 2,
        "delivery retries must not append duplicate receipts")
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.inputAccepted }.count, 0,
        "conversation inputs belong only in the Session journal")

    let raw = try String(contentsOf: writer.fileURL, encoding: .utf8)
    XCTAssertEqual(raw.components(separatedBy: "aviary.command-intent.v1").count - 1, 2)
}

func test_nativeCommandBridgeLeavesAcceptedUndeliveredEvidenceWhenLegacyProjectionFails() async throws {
    let (home, identity, bundle, writer) = try await nativeBridgeFixture(
        sessionID: "bridge-failure-session", workID: "bridge-failure-work",
        runID: "bridge-failure-run")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bridge = try NativeSessionCommandJournal(
        identity: identity, nativeJournal: bundle, legacyProjection: writer)
    let controller = SessionCommandController(identity: identity, journal: bridge)
    await writer.injectFailure(.beforeWrite)

    let start = await controller.admitAndCommitReceipt(
        .start(prompt: "must not dispatch"), actorID: "gui", commandID: "failed-start")
    guard case .accepted = start.admission else {
        XCTFail("native acceptance must not be rewritten as rejection when projection fails")
        return
    }
    XCTAssertTrue(start.isAcceptedButUndelivered)
    XCTAssertTrue(
        start.delivery.detail?.contains("Injected Session journal failure") == true)
    XCTAssertNil(await controller.awaitDispatch(commandID: "failed-start"))
    XCTAssertTrue(await controller.isJournalUnavailable)
    XCTAssertEqual(await controller.receipt(for: "failed-start"), start)

    // Retrying the same command id returns the original accepted-but-undelivered receipt. The
    // canonical input is not submitted to Work a second time.
    let retry = await controller.admitAndCommitReceipt(
        .start(prompt: "must not dispatch again"), actorID: "gui", commandID: "failed-start")
    XCTAssertEqual(retry, start)
    let later = await controller.admitAndCommitReceipt(
        .send(prompt: "must not run"), actorID: "gui", commandID: "later")
    XCTAssertEqual(
        later.admission, .rejected(commandID: "later", reason: .journalUnavailable))

    _ = try await bundle.finishRun(
        outcome: .failed, detail: "legacy presentation projection unavailable")
    try await bundle.closeChecked()
    try? await writer.closeChecked()
    let workEvents = try nativeExecutionEvents(
        at: home.timelineV2WorkJournalURL(identity.work), journal: bundle.workJournal)
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.commandAccepted }.count, 1)
    XCTAssertTrue(
        workEvents.filter { $0.type == TimelineEventType.commandDelivered }.isEmpty,
        "failed projection must not be mislabeled as runtime delivery")
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.commandNotDelivered }.count, 1)
    XCTAssertEqual(
        WorkReducer.reduce(workEvents).commands["failed-start"]?.state, .notDelivered)
    let sessionEvents = try nativeExecutionEvents(
        at: home.timelineV2SessionJournalURL(SessionRef(identity.sessionID)),
        journal: bundle.sessionJournal)
    XCTAssertEqual(SessionReducer.reduce(sessionEvents).messages.map(\.text), ["must not dispatch"])
}

func test_nativeCommandBridgeInspectsWorkAfterCanonicalSessionFailure() async throws {
    let (home, identity, bundle, writer) = try await nativeBridgeFixture(
        sessionID: "bridge-canonical-failure-session", workID: "bridge-canonical-failure-work",
        runID: "bridge-canonical-failure-run")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bridge = try NativeSessionCommandJournal(
        identity: identity, nativeJournal: bundle, legacyProjection: writer)
    let controller = SessionCommandController(identity: identity, journal: bridge)

    // Work acceptance is the first native event in commitInput. Fail the following canonical
    // Session append to leave a real accepted prefix rather than a pre-admission failure.
    await bundle.injectWriterFailure(.beforeWrite, in: .session)
    let result = await controller.admitAndCommitReceipt(
        .start(prompt: "canonical session failure"), actorID: "gui",
        commandID: "canonical-session-failure")
    guard case .accepted = result.admission else {
        XCTFail("a durable Work acceptance must not be relabeled as rejection")
        return
    }
    guard case .indeterminate(let reason) = result.delivery else {
        XCTFail("failed native terminalization must remain indeterminate")
        return
    }
    XCTAssertTrue(reason.contains("unavailable") || reason.contains("failure"))
    XCTAssertTrue(result.isAcceptedButUndelivered)
    XCTAssertEqual(
        await bundle.commandState(for: "canonical-session-failure"), .accepted,
        "the Work acceptance remains the durable fact when its outcome cannot be terminalized")
    XCTAssertNil(await controller.awaitDispatch(commandID: "canonical-session-failure"))

    let workEvents = try nativeExecutionEvents(
        at: home.timelineV2WorkJournalURL(identity.work), journal: bundle.workJournal)
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.commandAccepted }.count, 1)
    XCTAssertTrue(
        workEvents.filter { $0.type == TimelineEventType.commandNotDelivered }.isEmpty,
        "not-delivered must not be reported without a durable terminal receipt")
    XCTAssertTrue(
        workEvents.filter { $0.type == TimelineEventType.commandDeliveryIndeterminate }.isEmpty,
        "a failed terminalization leaves Work at accepted, not a fabricated outcome")
    XCTAssertEqual(
        WorkReducer.reduce(workEvents).commands["canonical-session-failure"]?.state, .accepted)
    try? await bundle.closeChecked()
    try? await writer.closeChecked()
}

func test_nativeCommandBridgePreservesCallerCursorAndRefusesStaleCommand() async throws {
    let (home, identity, bundle, writer) = try await nativeBridgeFixture(
        sessionID: "bridge-cursor-session", workID: "bridge-cursor-work",
        runID: "bridge-cursor-run")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bridge = try NativeSessionCommandJournal(
        identity: identity, nativeJournal: bundle, legacyProjection: writer)
    let controller = SessionCommandController(identity: identity, journal: bridge)
    let initialCursor = await bundle.latestWorkCursor

    let start = await controller.admitAndCommitReceipt(
        .start(prompt: "cursor-preserved"), actorID: "gui",
        commandID: "cursor-start", causalCursor: initialCursor)
    guard case .accepted(let admitted) = start.admission else {
        XCTFail("the command with the current caller cursor should be accepted")
        return
    }
    XCTAssertEqual(admitted.causalCursor, initialCursor)
    _ = await controller.awaitDispatch(commandID: admitted.commandID)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: admitted.commandID))
    XCTAssertTrue(await controller.recordDelivered(commandID: admitted.commandID))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: admitted.commandID))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: admitted.commandID))

    let expectedBeforeRejection = await bundle.latestWorkCursor
    let stale = await controller.admitAndCommitReceipt(
        .send(prompt: "stale"), actorID: "gui",
        commandID: "cursor-stale", causalCursor: initialCursor)
    guard case .rejected(_, let reason) = stale.admission else {
        XCTFail("a stale cursor must be refused before native acceptance")
        return
    }
    guard case .causalConflict(let expected, let received) = reason else {
        XCTFail("expected a typed causal conflict, got \(reason)")
        return
    }
    XCTAssertEqual(received, initialCursor)
    XCTAssertEqual(expected, expectedBeforeRejection)
    XCTAssertEqual(await controller.state, .idle)

    let workEvents = try nativeExecutionEvents(
        at: home.timelineV2WorkJournalURL(identity.work), journal: bundle.workJournal)
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.commandAccepted }
            .compactMap { $0.command?.commandID }, ["cursor-start"])
    XCTAssertEqual(
        workEvents.first { $0.command?.commandID == "cursor-start" }?.command?.causalCursor,
        initialCursor)
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.commandRejected }
            .compactMap { $0.command?.commandID }, ["cursor-stale"])
    XCTAssertEqual(
        WorkReducer.reduce(workEvents).commands["cursor-stale"]?.state, .rejected)

    let ending = await controller.admitAndCommitReceipt(
        .endRun, actorID: "gui", commandID: "cursor-end",
        causalCursor: await bundle.latestWorkCursor)
    guard case .accepted(let end) = ending.admission else {
        XCTFail("End should remain available after a typed cursor refusal")
        return
    }
    XCTAssertEqual(await controller.awaitDispatch(commandID: end.commandID)?.commandID, end.commandID)
    XCTAssertTrue(await controller.acknowledgeDelivered(commandID: end.commandID))
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: end.commandID))
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()
}

func test_nativeCommandBridgeCausalConflictRestoresRunningForFollowOnCancel() async throws {
    let (home, identity, bundle, writer) = try await nativeBridgeFixture(
        sessionID: "bridge-causal-follow-on-session", workID: "bridge-causal-follow-on-work",
        runID: "bridge-causal-follow-on-run")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bridge = try NativeSessionCommandJournal(
        identity: identity, nativeJournal: bundle, legacyProjection: writer)
    let controller = SessionCommandController(
        identity: identity,
        capabilities: SessionCommandCapabilities(
            supportsSteering: true, cancellationScopes: [.agentLoop]),
        journal: bridge)
    let initialCursor = await bundle.latestWorkCursor

    let start = await controller.admitAndCommitReceipt(
        .start(prompt: "run"), actorID: "gui", commandID: "causal-start",
        causalCursor: initialCursor)
    guard case .accepted(let startCommand) = start.admission else {
        XCTFail("Start should be admitted")
        return
    }
    _ = await controller.awaitDispatch(commandID: startCommand.commandID)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: startCommand.commandID))
    XCTAssertTrue(await controller.recordDelivered(commandID: startCommand.commandID))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: startCommand.commandID))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: startCommand.commandID))

    let send = await controller.admitAndCommitReceipt(
        .send(prompt: "turn"), actorID: "gui", commandID: "causal-turn",
        causalCursor: await bundle.latestWorkCursor)
    guard case .accepted(let sendCommand) = send.admission else {
        XCTFail("the follow-on turn should be admitted")
        return
    }
    _ = await controller.awaitDispatch(commandID: sendCommand.commandID)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: sendCommand.commandID))

    let staleSteer = await controller.admitAndCommitReceipt(
        .steer(text: "stale"), actorID: "gui", commandID: "stale-steer",
        causalCursor: initialCursor)
    guard case .rejected(_, let rejection) = staleSteer.admission else {
        XCTFail("the stale steer should be refused")
        return
    }
    guard case .causalConflict = rejection else {
        XCTFail("the stale steer should produce a typed causal conflict")
        return
    }
    XCTAssertEqual(
        await controller.state, .running,
        "a stale steer must not strand the lifecycle in transient committing")

    // This is the user-visible follow-on: the lifecycle recovered to running, so cancellation
    // remains admissible immediately after the rejected steer.
    let cancel = await controller.admitAndCommitReceipt(
        .cancel(scope: .agentLoop), actorID: "gui", commandID: "follow-on-cancel",
        causalCursor: await bundle.latestWorkCursor)
    guard case .accepted(let cancelCommand) = cancel.admission else {
        XCTFail("cancel should remain accepted after stale steer conflict")
        return
    }
    _ = await controller.awaitDispatch(commandID: cancelCommand.commandID)
    XCTAssertTrue(await controller.acknowledgeDelivered(commandID: cancelCommand.commandID))
    XCTAssertTrue(await controller.acknowledgeCancellation(commandID: cancelCommand.commandID))
    XCTAssertTrue(await controller.recordDelivered(commandID: sendCommand.commandID))

    let ending = await controller.admitAndCommitReceipt(
        .endRun, actorID: "gui", commandID: "causal-end",
        causalCursor: await bundle.latestWorkCursor)
    guard case .accepted(let endCommand) = ending.admission else {
        XCTFail("End should remain available after follow-on cancellation")
        return
    }
    _ = await controller.awaitDispatch(commandID: endCommand.commandID)
    XCTAssertTrue(await controller.acknowledgeDelivered(commandID: endCommand.commandID))
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: endCommand.commandID))
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()
}

func test_nativeExecutionAgentProviderPythonAndConversationReduceFromDisk() async throws {
    guard let server = try FakeProviderServer(script: [
        ["tool": ["name": "python", "arguments": ["code": "answer = 6 * 7\nanswer"]]],
        ["text": "The answer is 42.", "input_tokens": 250, "output_tokens": 8],
    ]) else { print("      skipped: no provider fixture"); return }
    defer { server.stop() }
    guard let host = try makeHost(.reference) else { return }

    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "native-e2e-session",
        work: WorkRef(workHostID: hostID, workID: "native-e2e-work"),
        runID: "native-e2e-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "integration-client",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "native-e2e-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)

    _ = try await bundle.commitInput(
        text: "what is six times seven?", deliveryMode: .delivered,
        command: CommandRef(commandID: "native-e2e-start", client: ClientRef("integration-client")))
    _ = try await host.start()
    let hostSession = try await host.createSession(id: identity.workID, cwd: "/tmp")
    let agent = Agent(
        provider: OpenAICompletionsProvider(
            id: "fake", baseURL: server.baseURL, apiKey: "test-key"),
        host: host, writer: writer, hostSession: hostSession,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "be brief"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    await agent.enableHooks(true)

    let outcome = await agent.send("what is six times seven?")
    XCTAssertEqual(outcome, .completed)
    try await writer.closeChecked()
    try await host.destroySession(hostSession)
    await host.stop()
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()

    let sessionEvents = try nativeExecutionEvents(
        at: home.timelineV2SessionJournalURL(SessionRef(identity.sessionID)),
        journal: bundle.sessionJournal)
    let workEvents = try nativeExecutionEvents(
        at: home.timelineV2WorkJournalURL(identity.work), journal: bundle.workJournal)
    let session = SessionReducer.reduce(sessionEvents)
    let work = WorkReducer.reduce(workEvents)
    XCTAssertTrue(session.structuralIntegrityValid && session.semanticProjectionValid)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
    XCTAssertEqual(session.messages.map(\.text), [
        "what is six times seven?", "The answer is 42.",
    ])
    XCTAssertNil(work.activeRun)

    let actions = workEvents.filter { $0.type == TimelineEventType.actionIntent }
    XCTAssertEqual(actions.count, 4, "two model requests, one hook, and one Python execution")
    XCTAssertEqual(
        actions.compactMap { $0.payload["kind"]?.stringValue }
            .filter { $0 == ActionKind.provider.rawValue }.count,
        2)
    XCTAssertEqual(
        actions.compactMap { $0.payload["kind"]?.stringValue }
            .filter { $0 == ActionKind.python.rawValue }.count,
        1)
    XCTAssertEqual(
        actions.compactMap { $0.payload["kind"]?.stringValue }
            .filter { $0 == ActionKind.hook.rawValue }.count,
        1)
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.actionOutcome }.count,
        actions.count)
    XCTAssertTrue(
        workEvents.filter { $0.type == TimelineEventType.actionOutcome }
            .allSatisfy {
                $0.payload["retry_safety"]?.stringValue == ActionRetrySafety.unsafe.rawValue
            },
        "provider cost, hooks, and arbitrary Python are not safely retryable")
    XCTAssertTrue(work.actions.values.allSatisfy { $0.state.isTerminal })

    let cursor = try XCTUnwrap(session.attachments["native-e2e-attachment"]?.cursor)
    let assembled = try XCTUnwrap(
        SessionAssembler.assemble(
            session: session, works: [work],
            at: ["native-e2e-attachment": cursor]))
    XCTAssertEqual(assembled.session.session, SessionRef(identity.sessionID))
    XCTAssertEqual(
        assembled.worksByAttachmentID["native-e2e-attachment"]?.execution, .idle)

    let legacy = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
    let legacyConversation = legacy.items.compactMap { item -> String? in
        guard item.kind == .user || item.kind == .assistant else { return nil }
        let text = item.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    XCTAssertEqual(legacyConversation, session.messages.map(\.text),
                   "the legacy UI adapter and native conversation must agree")
}

func test_nativeExecutionAgentCallbackEffectsHaveTypedActionReceipts() async throws {
    let (home, identity, bundle, writer) = try await nativeBridgeFixture(
        sessionID: "callback-session", workID: "callback-work", runID: "callback-run")
    defer { try? FileManager.default.removeItem(at: home.root) }
    guard let host = try makeHost(.reference) else { return }
    var callbackModel = fakeModel()
    callbackModel.inputModalities = ["image"]
    let agent = Agent(
        provider: OpenAICompletionsProvider(
            id: "fake", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
        host: host, writer: writer, hostSession: "callback-host",
        config: .init(model: callbackModel, cwd: "/tmp", systemPrompt: "s"),
        nativeJournal: bundle)
    await agent.setPeerDelegate(NativeCallbackPeer())
    await agent.setSelfDelegate(NativeCallbackSelf())
    await agent.setSpawnDelegate(NativeCallbackChild())
    await agent.setMemory(MemoryStore(repoRoot: nil, home: home, cwd: "/tmp"))
    await agent.setArtifacts(ArtifactStore(home: home, sessionID: writer.sessionID))

    XCTAssertNil((await agent.serveCallback(rid: "callback-message", kind: "message", payload: .object([
        "to": .string("peer-1"), "text": .string("hello"),
    ]))) ["error"])
    XCTAssertNil((await agent.serveCallback(rid: "callback-notify", kind: "notify", payload: .object([
        "text": .string("hello self"),
    ]))) ["error"])
    XCTAssertNil((await agent.serveCallback(rid: "callback-spawn", kind: "spawn", payload: .object([
        "prompt": .string("do work"),
    ]))) ["error"])
    XCTAssertNil((await agent.serveCallback(rid: "callback-remember", kind: "remember", payload: .object([
        "text": .string("durable fact"),
    ]))) ["error"])
    XCTAssertNil((await agent.serveCallback(rid: "callback-artifact", kind: "artifact", payload: .object([
        "text": .string("body"), "title": .string("Receipt"), "format": .string("md"),
    ]))) ["error"])
    let imageReply = await agent.serveCallback(rid: "callback-image", kind: "attach_image", payload: .object([
        "path": .string(home.root.appending(path: "missing.png").path),
    ]))
    XCTAssertNotNil(imageReply["error"])

    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()
    let workEvents = try nativeExecutionEvents(
        at: home.timelineV2WorkJournalURL(identity.work), journal: bundle.workJournal)
    let actions = WorkReducer.reduce(workEvents).actions
    let recordedKinds = workEvents.filter { $0.type == TimelineEventType.actionIntent }
        .compactMap { $0.payload["kind"]?.stringValue }
    for kind in [
        ActionKind.peerDelivery, .selfDelivery, .child, .memory, .artifact, .imageRead,
    ] {
        XCTAssertEqual(
            workEvents.filter {
                $0.type == TimelineEventType.actionIntent
                    && $0.payload["kind"]?.stringValue == kind.rawValue
            }.count, 1, "missing \(kind), recorded: \(recordedKinds)")
    }
    XCTAssertTrue(actions.values.allSatisfy { $0.state.isTerminal })
    let imageActionID = workEvents.first {
        $0.type == TimelineEventType.actionIntent
            && $0.payload["kind"]?.stringValue == ActionKind.imageRead.rawValue
    }?.action?.actionID
    for outcome in workEvents.filter({ $0.type == TimelineEventType.actionOutcome }) {
        XCTAssertEqual(
            outcome.payload["retry_safety"]?.stringValue,
            outcome.action?.actionID == imageActionID
                ? ActionRetrySafety.safe.rawValue : ActionRetrySafety.unsafe.rawValue)
    }
}

func test_nativeExecutionCompactionProviderHasTerminalReceipt() async throws {
    var script: [[String: Any]] = []
    for i in 0..<4 {
        script.append(["tool": ["name": "python", "arguments": ["code": "step = \(i)"]],
                       "input_tokens": 900] as [String: Any])
    }
    script.append(["text": "Earlier: four steps ran.", "input_tokens": 50])
    script.append(["text": "All done.", "input_tokens": 100])
    guard let server = try FakeProviderServer(script: script) else {
        print("      skipped: no provider fixture"); return
    }
    defer { server.stop() }
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    defer { Task { await host.stop() } }

    let (home, identity, bundle, _) = try await nativeBridgeFixture(
        sessionID: "compaction-session", workID: "compaction-work", runID: "compaction-run")
    defer { try? FileManager.default.removeItem(at: home.root) }
    var model = fakeModel()
    model.contextWindow = 1000
    let hostSession = try await host.createSession(id: identity.workID, cwd: "/tmp")
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    let agent = Agent(
        provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
        host: host, writer: writer, hostSession: hostSession,
        config: .init(model: model, cwd: "/tmp", systemPrompt: "sys", maxIterations: 12),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    await agent.send("do six things")
    try await writer.closeChecked()
    try await host.destroySession(hostSession)
    await host.stop()
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()

    let workEvents = try nativeExecutionEvents(
        at: home.timelineV2WorkJournalURL(identity.work), journal: bundle.workJournal)
    let compactions = workEvents.filter {
        $0.type == TimelineEventType.actionIntent
            && $0.payload["kind"]?.stringValue == ActionKind.compactionProvider.rawValue
    }
    XCTAssertEqual(compactions.count, 1)
    let actionID = try XCTUnwrap(compactions.first?.action?.actionID)
    let outcomes = workEvents.filter {
        $0.type == TimelineEventType.actionOutcome && $0.action?.actionID == actionID
    }
    XCTAssertEqual(outcomes.count, 1)
    XCTAssertEqual(outcomes.first?.payload["state"]?.stringValue, "succeeded")
    XCTAssertEqual(
        outcomes.first?.payload["retry_safety"]?.stringValue,
        ActionRetrySafety.unsafe.rawValue,
        "a second compaction request can duplicate provider cost")
    let sessionEvents = try nativeExecutionEvents(
        at: home.timelineV2SessionJournalURL(SessionRef(identity.sessionID)),
        journal: bundle.sessionJournal)
    XCTAssertEqual(
        sessionEvents.filter { $0.type == TimelineEventType.compaction }.count, 1)
    XCTAssertEqual(
        SessionReducer.reduce(sessionEvents).compactionSummary,
        "Earlier: four steps ran.")
}

let casesNativeExecutionIntegration: [Case] = [
    ("phase1 native execution: command bridge preserves acceptance and delivery", {
        try await test_nativeCommandBridgeRecordsAcceptanceAndExactDeliveryOnce()
    }),
    ("phase1 native execution: projection failure remains accepted and undelivered", {
        try await test_nativeCommandBridgeLeavesAcceptedUndeliveredEvidenceWhenLegacyProjectionFails()
    }),
    ("phase1 native execution: canonical Session failure preserves Work acceptance", {
        try await test_nativeCommandBridgeInspectsWorkAfterCanonicalSessionFailure()
    }),
    ("phase1 native execution: caller cursors are preserved and stale commands refused", {
        try await test_nativeCommandBridgePreservesCallerCursorAndRefusesStaleCommand()
    }),
    ("phase1 native execution: stale steer restores lifecycle for follow-on cancel", {
        try await test_nativeCommandBridgeCausalConflictRestoresRunningForFollowOnCancel()
    }),
    ("phase1 native execution: provider, Python, reducers, and legacy parity", {
        try await test_nativeExecutionAgentProviderPythonAndConversationReduceFromDisk()
    }),
    ("phase1 native execution: callback effects have typed action receipts", {
        try await test_nativeExecutionAgentCallbackEffectsHaveTypedActionReceipts()
    }),
    ("phase1 native execution: compaction provider has a terminal receipt", {
        try await test_nativeExecutionCompactionProviderHasTerminalReceipt()
    }),
]
