import Foundation
@testable import AviaryCore

private let bundleTestSession = SessionRef("bundle-session")
private let bundleTestWork = WorkRef(workHostID: "bundle-host", workID: "bundle-work")
private let bundleTestHost = WorkHostRef("bundle-host")
private let bundleTestAttachment = SessionAttachmentRef("bundle-attachment")
private let bundleTestAuthority = TimelineAuthorityRef("bundle-session-service")
private let bundleTestActor = TimelineActor(actorID: "bundle-host", kind: "work-host")

private final class BundleTestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0

    func nextID() -> String {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        return "bundle-event-\(next)"
    }
}

private func bundleTestHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-run-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AgentHome(root: root)
}

private func persistBundleTestHost(_ home: AgentHome, expected: String? = nil) throws -> String {
    let host = try home.requirePersistedWorkHostID()
    if let expected { XCTAssertEqual(host, expected) }
    return host
}

private func makeBundle(
    home: AgentHome, runID: String = "run-1",
    failurePlan: (session: TimelineJournalWriter.FailurePlan,
                  work: TimelineJournalWriter.FailurePlan) = (.none, .none),
    ids: BundleTestIDs = BundleTestIDs()
) async throws -> RunJournalBundle {
    try await RunJournalBundle.createFresh(
        home: home, session: bundleTestSession, work: bundleTestWork,
        workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
        sessionAttachment: bundleTestAttachment, run: RunRef(runID), actor: bundleTestActor,
        modelID: "model-one", failurePlan: failurePlan,
        eventIDProvider: { ids.nextID() }, now: { Date(timeIntervalSince1970: 1) })
}

private func bundleEvents(_ home: AgentHome, _ journal: JournalRef, _ url: URL) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: url), journal: journal, actor: bundleTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        throw RunJournalBundleError.invalidJournal(journal: journal, reason: "test tail")
    }
    return read.records.map(\.event)
}

private func bundleStatus(_ bundle: RunJournalBundle) async -> RunJournalBundleStatus {
    await bundle.status
}

private func terminalCommand(
    _ bundle: RunJournalBundle, id: String
) async throws -> CommandRef {
    guard let cursor = await bundle.latestWorkCursor else {
        throw RunJournalBundleError.invalidOperation("test bundle has no Work cursor")
    }
    return CommandRef(
        commandID: id, client: ClientRef("terminal-client"),
        sessionAttachment: bundle.sessionAttachment, causalCursor: cursor)
}

private func exactCommand(
    _ bundle: RunJournalBundle,
    id: String,
    client: ClientRef = ClientRef("bundle-test-client"),
    sessionAttachment: SessionAttachmentRef? = nil
) async throws -> CommandRef {
    guard let cursor = await bundle.latestWorkCursor else {
        throw RunJournalBundleError.invalidOperation("test bundle has no Work cursor")
    }
    return CommandRef(
        commandID: id, client: client, sessionAttachment: sessionAttachment,
        causalCursor: cursor)
}

private let terminalDetailRoundTripMatrix: [String?] = [
    nil,
    "",
    " \t",
    String(repeating: "é", count: 2_000), // exactly 4,000 UTF-8 bytes
]

/// Exercise the response-loss path with the values most likely to disagree between a live
/// request and a cold proof reconstruction. In particular, empty and whitespace details are
/// nonnil values and must remain present in both the event payload and idempotency key.
private func assertTerminalDetailRoundTrip(
    operation: WorkServiceTerminalOperation, detail: String?, index: Int
) async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let work = WorkRef(
        workHostID: hostID,
        workID: "terminal-detail-\(operation.rawValue)-work-\(index)")
    let identity = SessionWorkIdentity(
        sessionID: "terminal-detail-\(operation.rawValue)-session-\(index)",
        work: work,
        runID: "terminal-detail-\(operation.rawValue)-run-\(index)")
    let execution = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "terminal-detail-execution-\(index)",
        makeAttachmentID: { "terminal-detail-attachment-\(index)" })
    _ = try await execution.finishRun(outcome: .completed)
    let attachment = execution.sessionAttachment
    let latestExecutionCursor = await execution.latestWorkCursor
    let causal = try XCTUnwrap(latestExecutionCursor)
    try await execution.closeChecked()

    let terminal = try await RunJournalBundle.openForTerminalMutation(
        home: home, identity: identity, sessionAttachment: attachment,
        actorID: "terminal-detail-committer-\(index)")
    let client = ClientRef("terminal-detail-client-\(index)")
    let command = CommandRef(
        commandID: "terminal-detail-\(operation.rawValue)-command-\(index)",
        client: client, sessionAttachment: attachment, causalCursor: causal)
    let commits: [TimelineJournalCommit]
    switch operation {
    case .complete:
        commits = try await terminal.completeWork(detail: detail, command: command)
    case .destroy:
        commits = try await terminal.destroyWork(
            resourcesQuiesced: true, reason: detail, command: command)
    }
    XCTAssertEqual(commits.count, 2)
    let request = WorkServiceTerminalCommitRequest(
        operation: operation,
        work: terminal.work,
        journal: terminal.workJournal,
        client: client,
        session: terminal.session,
        sessionJournal: terminal.sessionJournal,
        sessionAttachment: attachment,
        causalWorkCursor: causal,
        detail: detail,
        command: command)
    try await terminal.closeChecked()

    // A response can be lost after both appends are durable. The adapter must recover the exact
    // pair from closed canonical files without appending another terminal event.
    let recoveredByAdapter = try await RunJournalBundleWorkServiceTerminalCommitter(
        bundle: terminal).commit(request)
    let recoveredByStaticRead = try XCTUnwrap(
        try RunJournalBundle.readTerminalCommit(
            home: home, identity: identity, sessionAttachment: attachment,
            command: command, detail: detail))
    XCTAssertEqual(recoveredByAdapter.terminalEvent, recoveredByStaticRead.workEvent)
    XCTAssertEqual(
        recoveredByAdapter.resultingWorkCursor, recoveredByStaticRead.workCommit.cursor)
    XCTAssertEqual(
        recoveredByAdapter.pairedSessionCursor,
        recoveredByStaticRead.pairedSessionCommit?.cursor)
    XCTAssertEqual(recoveredByAdapter.resultingWorkCursor, commits[0].cursor)
    XCTAssertEqual(recoveredByAdapter.pairedSessionCursor, commits[1].cursor)
    XCTAssertEqual(recoveredByAdapter.terminalEvent.payload["detail"]?.stringValue, detail)

    let workEvents = try bundleEvents(
        home, terminal.workJournal, home.timelineV2WorkJournalURL(identity.work))
    let terminalType = operation == .complete
        ? TimelineEventType.workCompleted : TimelineEventType.workDestroyed
    XCTAssertEqual(workEvents.filter { $0.type == terminalType }.count, 1)
}

func test_runJournalBundleFreshGenesisAndExactAssembly() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let sessionJournal = bundle.sessionJournal
    let workJournal = bundle.workJournal
    let sessionEvents = try bundleEvents(home, sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    let workEvents = try bundleEvents(home, workJournal, home.timelineV2WorkJournalURL(bundleTestWork))

    XCTAssertEqual(sessionEvents.map(\.type), [TimelineEventType.sessionCreated, TimelineEventType.sessionAttached])
    XCTAssertEqual(workEvents.map(\.type), [TimelineEventType.workCreated, TimelineEventType.sessionAttached, TimelineEventType.runStarted])
    XCTAssertEqual(sessionEvents[1].work, bundleTestWork)
    XCTAssertEqual(workEvents[1].sessionAttachment, bundleTestAttachment)
    XCTAssertEqual(workEvents[2].run, RunRef("run-1"))

    let session = SessionReducer.reduce(sessionEvents)
    let work = WorkReducer.reduce(workEvents)
    XCTAssertTrue(session.structuralIntegrityValid && session.semanticProjectionValid)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
    XCTAssertEqual(session.attachments[bundleTestAttachment.attachmentID]?.work, bundleTestWork)
    XCTAssertEqual(work.sessionAttachments[bundleTestAttachment.attachmentID]?.session, bundleTestSession)
    let latestWorkCursor = await bundle.latestWorkCursor
    let cursor = try XCTUnwrap(latestWorkCursor)
    XCTAssertNotNil(SessionAssembler.assemble(session: session, works: [work], at: [
        bundleTestAttachment.attachmentID: cursor
    ]))
    let status = await bundleStatus(bundle)
    XCTAssertEqual(status.durablePrefix.sessionEventCount, 2)
    XCTAssertEqual(status.durablePrefix.workEventCount, 3)
    try await bundle.closeChecked()
}

func test_runJournalBundleFinishedTurnPublishesExactReadyForReviewWhileRunRemainsActive() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try persistBundleTestHost(home)
    let identity = SessionWorkIdentity(
        sessionID: "notification-live-session",
        work: WorkRef(workHostID: hostID, workID: "notification-live-work"),
        runID: "notification-live-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "notification-live-gui",
        modelID: "notification-model", makeAttachmentID: { "notification-attachment" })

    _ = try await bundle.commitInput(
        text: "do the work", deliveryMode: .delivered,
        command: try await exactCommand(bundle, id: "notification-command"))
    let turn = TurnRef("notification-turn")
    _ = try await bundle.startTurn(turn)
    _ = try await bundle.commitAssistantMessage("finished result")
    let finishCommits = try await bundle.finishTurn(turn)
    XCTAssertEqual(finishCommits.count, 3)
    XCTAssertEqual(finishCommits[0].eventRef.journal.kind, .work)
    XCTAssertEqual(finishCommits[1].eventRef.journal.kind, .session)
    XCTAssertEqual(finishCommits[2].eventRef.journal.kind, .session)

    let catalog = LocalTimelineCatalog.scan(home: home)
    let summary = try XCTUnwrap(catalog.sessionSummaries.first)
    XCTAssertEqual(summary.work.first?.activeRun, RunRef(identity.runID))
    XCTAssertEqual(summary.work.first?.cursorAlignment, .exact)
    XCTAssertEqual(summary.effectiveAttention, .review)
    let candidate = try XCTUnwrap(
        CanonicalNotificationProjection(summaries: [summary]).candidates.first)
    XCTAssertEqual(candidate.kind, .readyForReview)

    _ = try await bundle.finishRun(outcome: .canceled)
    try await bundle.closeChecked()
}

func test_runJournalBundleExecutionOpenCreatesThenReopensTheMirroredAttachment() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try persistBundleTestHost(home)
    let firstIdentity = SessionWorkIdentity(
        sessionID: "execution-session",
        work: WorkRef(workHostID: hostID, workID: "execution-work"),
        runID: "execution-run-1")
    let first = try await RunJournalBundle.openForExecution(
        home: home, identity: firstIdentity, actorID: "gui-one", modelID: "model-one",
        makeAttachmentID: { "execution-attachment" })
    XCTAssertEqual(first.sessionAttachment, SessionAttachmentRef("execution-attachment"))
    _ = try await first.finishRun()
    try await first.closeChecked()

    let secondIdentity = SessionWorkIdentity(
        sessionID: firstIdentity.sessionID, work: firstIdentity.work,
        runID: "execution-run-2")
    let second = try await RunJournalBundle.openForExecution(
        home: home, identity: secondIdentity, actorID: "cli-two", modelID: "model-two",
        makeAttachmentID: { "must-not-replace" })
    XCTAssertEqual(second.sessionAttachment, SessionAttachmentRef("execution-attachment"))
    XCTAssertEqual(second.run, RunRef("execution-run-2"))
    let sessionEvents = try bundleEvents(
        home, second.sessionJournal,
        home.timelineV2SessionJournalURL(SessionRef(firstIdentity.sessionID)))
    XCTAssertEqual(
        sessionEvents.filter { $0.type == TimelineEventType.sessionAttached }.count, 1)
    let workEvents = try bundleEvents(
        home, second.workJournal, home.timelineV2WorkJournalURL(firstIdentity.work))
    XCTAssertEqual(
        workEvents.filter { $0.type == TimelineEventType.workCreated }.count, 1)
    XCTAssertEqual(workEvents.last?.type, TimelineEventType.runStarted)
    XCTAssertEqual(workEvents.last?.run, RunRef("execution-run-2"))
    try await second.closeChecked()
}

func test_runJournalBundleExecutionOpenRefusesForeignAuthorityAndIncompletePair() async throws {
    let foreignHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: foreignHome.root) }
    let persisted = try persistBundleTestHost(foreignHome)
    do {
        _ = try await RunJournalBundle.openForExecution(
            home: foreignHome,
            identity: SessionWorkIdentity(
                sessionID: "foreign-session",
                work: WorkRef(workHostID: persisted + "-foreign", workID: "foreign-work"),
                runID: "foreign-run"),
            actorID: "gui")
        XCTFail("a launch identity from another Work Host must be refused")
    } catch let error as RunJournalBundleError {
        if case .invalidConfiguration = error { } else { XCTFail("wrong authority error: \(error)") }
    }

    let partialHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: partialHome.root) }
    let partialHost = try persistBundleTestHost(partialHome)
    let identity = SessionWorkIdentity(
        sessionID: "partial-session",
        work: WorkRef(workHostID: partialHost, workID: "partial-work"),
        runID: "partial-run")
    let sessionURL = partialHome.timelineV2SessionJournalURL(SessionRef(identity.sessionID))
    try FileManager.default.createDirectory(
        at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: sessionURL.path, contents: Data()))
    do {
        _ = try await RunJournalBundle.openForExecution(
            home: partialHome, identity: identity, actorID: "gui")
        XCTFail("one native journal without its counterpart must be refused")
    } catch let error as RunJournalBundleError {
        if case .missingCounterpart = error { } else { XCTFail("wrong partial-pair error: \(error)") }
    }
}

func test_runJournalBundleInputAndAssistantTipsRemainOneVisibleChain() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let client = ClientRef("bundle-client")
    do {
        _ = try await bundle.startTurn(TurnRef(""))
        XCTFail("empty TurnRef must be rejected before bytes")
    } catch { }
    _ = try await bundle.startTurn(TurnRef("turn-1"))
    let command1 = try await exactCommand(bundle, id: "command-1", client: client)
    do {
        _ = try await bundle.commitInput(
            text: "foreign", deliveryMode: .queued,
            command: try await exactCommand(
                bundle, id: "foreign", sessionAttachment: SessionAttachmentRef("other")))
        XCTFail("foreign attachment must be rejected before writing")
    } catch { }
    let first = try await bundle.commitInput(text: "first", deliveryMode: .delivered, command: command1)
    XCTAssertEqual(first.count, 4)
    _ = try await bundle.commitAssistantMessage("answer-1")
    _ = try await bundle.commitCompaction(
        summary: "first exchange established the answer", tokensBefore: 1_200,
        droppedMessages: 2)
    _ = try await bundle.finishTurn(TurnRef("turn-1"))

    _ = try await bundle.startTurn(TurnRef("turn-2"))
    let command2 = CommandRef(commandID: "command-2", client: client,
                              sessionAttachment: bundleTestAttachment,
                              causalCursor: await bundle.latestWorkCursor)
    let second = try await bundle.commitInput(text: "second", deliveryMode: .queued, command: command2)
    XCTAssertEqual(second.count, 4)
    _ = try await bundle.commitAssistantMessage("answer-2")
    _ = try await bundle.finishTurn(TurnRef("turn-2"))

    let events = try bundleEvents(home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    let reduced = SessionReducer.reduce(events)
    XCTAssertTrue(reduced.structuralIntegrityValid && reduced.semanticProjectionValid)
    XCTAssertEqual(reduced.messages.map(\.text), ["first", "answer-1", "second", "answer-2"])
    let assistantEvents = events.filter { $0.type == TimelineEventType.messageCommitted }
    XCTAssertEqual(assistantEvents.count, 2)
    XCTAssertTrue(assistantEvents.allSatisfy { $0.sessionAttachment == bundleTestAttachment })
    XCTAssertTrue(reduced.messages.filter { $0.role == ChatRole.assistant.rawValue }
        .allSatisfy { $0.sessionAttachment == bundleTestAttachment })
    XCTAssertTrue(assistantEvents.compactMap { SessionMessageSnapshot.canonicalMessage(from: $0) }
        .allSatisfy { $0.sessionAttachment == bundleTestAttachment })
    XCTAssertEqual(reduced.compactionSummary, "first exchange established the answer")
    XCTAssertEqual(reduced.semanticTip?.eventID, reduced.messages.last?.eventID)
    let workEvents = try bundleEvents(home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let work = WorkReducer.reduce(workEvents)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
    XCTAssertEqual(work.commands["command-1"]?.state, .delivered)
    XCTAssertEqual(work.commands["command-2"]?.state, .accepted)
    XCTAssertEqual(work.commands["command-1"]?.command.causalCursor?.journal, bundle.workJournal)
    XCTAssertEqual(work.commands["command-1"]?.command.causalCursor?.sequence, 4)
    XCTAssertEqual(work.commands["command-1"]?.command.sessionAttachment, bundleTestAttachment)
    try await bundle.closeChecked()
}

func test_runJournalBundleQueuedDeliveryUsesOriginalReceiptAndNoSecondInput() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let prefix = await bundle.status.durablePrefix
    do {
        _ = try await bundle.commitInput(
            text: "ambiguous", deliveryMode: .queued,
            command: CommandRef(commandID: "missing-causal-cursor"))
        XCTFail("canonical command admission must require the caller-observed Work cursor")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation(let reason) = error,
              reason.contains("current pre-receipt Work cursor") else {
            XCTFail("unexpected missing-cursor error: \(error)")
            return
        }
    }
    XCTAssertEqual(await bundle.status.durablePrefix, prefix)
    let command = try await exactCommand(
        bundle, id: "queued-command", client: ClientRef("queued-client"))
    let queued = try await bundle.commitInput(text: "queued", deliveryMode: .queued, command: command)
    XCTAssertEqual(queued.count, 3)
    let beforeDelivery = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let accepted = try XCTUnwrap(beforeDelivery.last(where: { $0.type == TimelineEventType.commandAccepted }))
    let acceptedRef = EventRef(journal: bundle.workJournal, eventID: accepted.eventID)
    let delivered = try await bundle.markInputDelivered(command: command)
    XCTAssertEqual(delivered.eventRef.journal, bundle.workJournal)
    let workEvents = try bundleEvents(home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let delivery = try XCTUnwrap(workEvents.last(where: { $0.type == TimelineEventType.commandDelivered }))
    XCTAssertEqual(delivery.causedByEventID, acceptedRef)
    XCTAssertEqual(delivery.command, accepted.command)
    let reduced = WorkReducer.reduce(workEvents)
    XCTAssertTrue(reduced.structuralIntegrityValid && reduced.semanticProjectionValid)
    XCTAssertEqual(reduced.commands[command.commandID]?.state, .delivered)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.commandAccepted }.count, 1)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.commandDelivered }.count, 1)
    do {
        _ = try await bundle.markInputDelivered(command: command)
        XCTFail("a delivered command must not receive a second delivery receipt")
    } catch { }
    do {
        _ = try await bundle.commitInput(text: "duplicate", deliveryMode: .queued, command: command)
        XCTFail("a command identity must not be accepted twice")
    } catch { }
    try await bundle.closeChecked()
}

func test_runJournalBundleNonConversationalCommandDoesNotCreateAUserMessage() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let command = try await exactCommand(bundle, id: "end-command", client: ClientRef("gui"))
    let accepted = try await bundle.commitCommand(
        label: "end_run", deliveryMode: .queued, command: command,
        metadata: ["scope": .string("run")])
    XCTAssertEqual(accepted.count, 1)
    _ = try await bundle.markCommandDelivered(commandID: command.commandID)

    let sessionEvents = try bundleEvents(
        home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    XCTAssertEqual(sessionEvents.filter { $0.type == TimelineEventType.inputAccepted }.count, 0)
    let workEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let receipt = try XCTUnwrap(workEvents.first(where: {
        $0.type == TimelineEventType.commandAccepted && $0.command?.commandID == command.commandID
    }))
    XCTAssertEqual(receipt.payload["command_kind"]?.stringValue, "end_run")
    XCTAssertEqual(receipt.payload["scope"]?.stringValue, "run")
    let reduced = WorkReducer.reduce(workEvents)
    XCTAssertEqual(reduced.commands[command.commandID]?.state, .delivered)
    XCTAssertTrue(reduced.structuralIntegrityValid && reduced.semanticProjectionValid)
    try await bundle.closeChecked()
}

func test_runJournalBundleAllActionKindsPermitOnlyAfterDurableStart() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    do {
        _ = try await bundle.beginAction(action: ActionRef(""), kind: .python, intent: "empty")
        XCTFail("empty ActionRef must be rejected before bytes")
    } catch { }
    for (index, kind) in ActionKind.allCases.enumerated() {
        let before = await bundleStatus(bundle).durablePrefix.workEventCount
        if kind == .provider || kind == .compactionProvider {
            do {
                _ = try await bundle.beginAction(kind: kind, intent: "unqualified model call")
                XCTFail("model calls must require pinned context/accounting admission")
            } catch { }
            XCTAssertEqual(await bundleStatus(bundle).durablePrefix.workEventCount, before)
            continue
        }
        let permit = try await bundle.beginAction(
            action: ActionRef("action-\(index)"), kind: kind,
            intent: "perform \(kind.rawValue)", target: "target-\(index)", scope: "run")
        let afterStart = await bundleStatus(bundle).durablePrefix.workEventCount
        XCTAssertEqual(afterStart, before + 2)
        XCTAssertEqual(permit.kind, kind)
        XCTAssertEqual(permit.intentCommit.cursor.sequence + 1, permit.startedCommit.cursor.sequence)
        _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .idempotent)
        do {
            _ = try await bundle.beginAction(action: ActionRef("action-\(index)"), kind: kind,
                                             intent: "reuse (kind.rawValue)")
            XCTFail("terminal ActionRef must not be reused")
        } catch { }
    }
    let events = try bundleEvents(home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let work = WorkReducer.reduce(events)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionIntent }.count, ActionKind.allCases.count - 2)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionStarted }.count, ActionKind.allCases.count - 2)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionOutcome }.count, ActionKind.allCases.count - 2)
    try await bundle.closeChecked()
}

func test_runJournalBundleActionLifecycleCarriesActiveTurn() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let turn = TurnRef("action-turn")
    _ = try await bundle.startTurn(turn)

    let permit = try await bundle.beginAction(
        action: ActionRef("turn-bound-action"), kind: .mcp,
        intent: "invoke turn-bound action", target: "target", scope: "turn",
        metadata: ["purpose": .string("producer coverage")])
    _ = try await bundle.finishAction(
        permit, state: .failed, retrySafety: .unknown, failureKind: .timeout)

    let events = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let lifecycle = events.filter { event in
        event.action == permit.action
            && [TimelineEventType.actionIntent, TimelineEventType.actionStarted,
                TimelineEventType.actionOutcome].contains(event.type)
    }
    XCTAssertEqual(lifecycle.map(\.type), [
        TimelineEventType.actionIntent, TimelineEventType.actionStarted,
        TimelineEventType.actionOutcome
    ])
    XCTAssertEqual(lifecycle.map(\.turn), [turn, turn, turn])
    XCTAssertEqual(lifecycle.map(\.run), [bundle.run, bundle.run, bundle.run])
    XCTAssertEqual(lifecycle.map(\.action), [permit.action, permit.action, permit.action])
    XCTAssertEqual(lifecycle[0].payload["kind"]?.stringValue, ActionKind.mcp.rawValue)
    XCTAssertEqual(lifecycle[0].payload["intent"]?.stringValue, "invoke turn-bound action")
    XCTAssertEqual(lifecycle[2].payload["failure_kind"]?.stringValue,
                   ActionFailureKind.timeout.rawValue)
    XCTAssertEqual(lifecycle[2].payload["retry_safety"]?.stringValue,
                   ActionRetrySafety.unknown.rawValue)
    try await bundle.closeChecked()
}

func test_runJournalBundleReopenRetainsSingleUseActionIdentities() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let permit = try await bundle.beginAction(
        action: ActionRef("reopened-action"), kind: .python, intent: "run once")
    _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .safe)
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    let reopened = try await RunJournalBundle.reopen(
        home: home, session: bundleTestSession, work: bundleTestWork, workHost: bundleTestHost,
        sessionAuthority: bundleTestAuthority, sessionAttachment: bundleTestAttachment,
        run: RunRef("action-followup"), actor: bundleTestActor)
    do {
        _ = try await reopened.beginAction(action: ActionRef("reopened-action"), kind: .python,
                                           intent: "run twice")
        XCTFail("reopen must retain terminal ActionRef identities")
    } catch { }
    try await reopened.closeChecked()
}

func test_runJournalBundleRecordsBoundedArtifactAndRetainsBodyBeforeEvent() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    _ = try await bundle.startTurn(TurnRef("artifact-turn"))
    let permit = try await bundle.beginAction(
        action: ActionRef("artifact-action"), kind: .artifact,
        intent: "publish a completed-turn artifact")
    let body = Data("artifact bytes must stay out of the journal".utf8)
    do {
        _ = try await bundle.recordArtifact(
            artifactID: "artifact-missing-provenance", label: "label", body: nil,
            action: permit.action, provenance: nil)
        XCTFail("an action-bearing artifact must cite its active action start")
    } catch RunJournalBundleError.invalidOperation { }
    do {
        _ = try await bundle.recordArtifact(
            artifactID: "artifact-unrelated-provenance", label: "label", body: nil,
            action: permit.action,
            provenance: EventRef(journal: bundle.workJournal, eventID: "unrelated-start"))
        XCTFail("an action-bearing artifact must reject an unrelated same-journal cause")
    } catch RunJournalBundleError.invalidOperation { }
    let foreignReview = await ObservedRepositoryReview.observe(
        cwd: home.root, runID: "foreign-run", turnID: "foreign-turn")
    let foreignReviewBody = try foreignReview.encoded()
    do {
        _ = try await bundle.recordArtifact(
            artifactID: "artifact-foreign-review", label: "review.json",
            mediaType: ObservedRepositoryReviewFormat.mediaType,
            body: foreignReviewBody, action: permit.action,
            provenance: permit.startedCommit.eventRef)
        XCTFail("a repository-review body from another Run/Turn must be rejected")
    } catch RunJournalBundleError.invalidOperation { }
    let receipt = try await bundle.recordArtifact(
        artifactID: "artifact-1", label: "review.json", mediaType: "application/json",
        body: body, action: permit.action, provenance: permit.startedCommit.eventRef,
        links: [TimelineLink(kind: .produced, target: permit.startedCommit.eventRef)])

    XCTAssertEqual(receipt.descriptor.artifactID, "artifact-1")
    XCTAssertEqual(receipt.descriptor.work, bundle.work)
    XCTAssertEqual(receipt.descriptor.label, "review.json")
    XCTAssertFalse(receipt.descriptor.metadataWasTruncated)
    XCTAssertEqual(receipt.descriptor.mediaType, "application/json")
    XCTAssertEqual(receipt.descriptor.byteCount, body.count)
    XCTAssertEqual(receipt.descriptor.bodyReference?.authority, bundle.workJournal)
    XCTAssertEqual(receipt.descriptor.bodyReference?.byteCount, body.count)
    XCTAssertEqual(receipt.descriptor.bodyReference?.digest, receipt.descriptor.digest)
    XCTAssertEqual(try ContextBodyStore(home: home).read(
        try XCTUnwrap(receipt.descriptor.bodyReference)), body)

    let finishedAction = try await bundle.beginAction(
        action: ActionRef("inactive-artifact-action"), kind: .artifact,
        intent: "prove artifact provenance requires a live action")
    _ = try await bundle.finishAction(finishedAction, state: .succeeded, retrySafety: .safe)
    do {
        _ = try await bundle.recordArtifact(
            artifactID: "inactive-action-artifact", label: "label", body: nil,
            action: finishedAction.action)
        XCTFail("an artifact cannot cite a terminal action as its active producer")
    } catch RunJournalBundleError.invalidOperation { }

    let workEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let artifactEvent = try XCTUnwrap(
        workEvents.first(where: { $0.eventID == receipt.commit.eventRef.eventID }))
    let serialized = String(
        decoding: try JSONEncoder().encode(artifactEvent), as: UTF8.self)
    XCTAssertTrue(serialized.contains("artifact-1"))
    XCTAssertTrue(serialized.contains("body_reference"))
    XCTAssertFalse(serialized.contains(String(decoding: body, as: UTF8.self)))
    XCTAssertFalse(serialized.contains(home.root.path))
    XCTAssertEqual(artifactEvent.run, bundle.run)
    XCTAssertEqual(artifactEvent.turn, TurnRef("artifact-turn"))
    XCTAssertEqual(artifactEvent.action, permit.action)
    XCTAssertEqual(artifactEvent.causedByEventID, permit.startedCommit.eventRef)
    XCTAssertEqual(artifactEvent.links, receipt.links)

    do {
        _ = try await bundle.recordArtifact(
            artifactID: " artifact-duplicate", label: "label", body: nil)
        XCTFail("leading whitespace in an artifact identity must be rejected")
    } catch RunJournalBundleError.invalidOperation { }
    do {
        _ = try await bundle.recordArtifact(
            artifactID: "artifact-control", label: "bad\nlabel", body: nil)
        XCTFail("control characters in an artifact label must be rejected")
    } catch RunJournalBundleError.invalidOperation { }
    do {
        _ = try await bundle.recordArtifact(
            artifactID: "artifact-media", label: "label", mediaType: "text/\nplain",
            body: nil)
        XCTFail("control characters in a media type must be rejected")
    } catch RunJournalBundleError.invalidOperation { }
    for (index, separator) in ["\u{2028}", "\u{2029}"].enumerated() {
        do {
            _ = try await bundle.recordArtifact(
                artifactID: "artifact-separator-\(index)",
                label: "bad\(separator)label", body: nil)
            XCTFail("Unicode line separators in an artifact label must be rejected")
        } catch RunJournalBundleError.invalidOperation { }
    }
    do {
        _ = try await bundle.recordArtifact(
            artifactID: "artifact-too-large", label: "label",
            body: Data(repeating: 0x61, count: 8 * 1024 * 1024 + 1))
        XCTFail("an artifact body beyond the bounded size must be rejected")
    } catch RunJournalBundleError.invalidOperation { }

    _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .safe)
    _ = try await bundle.finishTurn(TurnRef("artifact-turn"))
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()

    let reopened = try await RunJournalBundle.reopen(
        home: home, session: bundleTestSession, work: bundleTestWork, workHost: bundleTestHost,
        sessionAuthority: bundleTestAuthority, sessionAttachment: bundleTestAttachment,
        run: RunRef("artifact-follow-up"), actor: bundleTestActor)
    do {
        _ = try await reopened.recordArtifact(
            artifactID: "artifact-1", label: "reused", body: nil)
        XCTFail("artifact identities must remain single-use after cold reopen")
    } catch RunJournalBundleError.invalidOperation { }
    try await reopened.closeChecked()
}

func test_runJournalBundleSemanticGateSerializesConcurrentMutations() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let concurrentCommand = try await exactCommand(bundle, id: "concurrent-command")

    let inputResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    _ = try await bundle.commitInput(
                        text: "same", deliveryMode: .queued,
                        command: concurrentCommand)
                    return true
                } catch { return false }
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    XCTAssertEqual(inputResults.filter { $0 }.count, 1)
    XCTAssertEqual(inputResults.filter { !$0 }.count, 1)
    _ = try await bundle.markCommandDelivered(commandID: "concurrent-command")

    let actionResults = await withTaskGroup(of: EffectPermit?.self, returning: [EffectPermit?].self) { group in
        for _ in 0..<2 {
            group.addTask {
                try? await bundle.beginAction(
                    action: ActionRef("concurrent-action"), kind: .python, intent: "same")
            }
        }
        var results: [EffectPermit?] = []
        for await result in group { results.append(result) }
        return results
    }
    XCTAssertEqual(actionResults.compactMap { $0 }.count, 1)
    if let permit = actionResults.compactMap({ $0 }).first {
        _ = try await bundle.finishAction(permit, state: .succeeded, retrySafety: .safe)
    }

    let turnAndFinish = await withTaskGroup(of: String.self, returning: [String].self) { group in
        group.addTask {
            do { _ = try await bundle.startTurn(TurnRef("race-turn")); return "turn" }
            catch { return "turn-failed" }
        }
        group.addTask {
            do { _ = try await bundle.finishRun(); return "run" }
            catch { return "run-failed" }
        }
        var results: [String] = []
        for await result in group { results.append(result) }
        return results
    }
    XCTAssertEqual(turnAndFinish.filter { $0 == "turn" || $0 == "run" }.count, 1)
    if turnAndFinish.contains("turn") {
        _ = try await bundle.finishTurn(TurnRef("race-turn"))
        _ = try await bundle.finishRun()
    }

    let workEvents = try bundleEvents(home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let hostSequences = workEvents.compactMap(\.hostSequence)
    XCTAssertEqual(Set(hostSequences).count, hostSequences.count)
    let reduced = WorkReducer.reduce(workEvents)
    XCTAssertTrue(reduced.structuralIntegrityValid && reduced.semanticProjectionValid)
    try await bundle.closeChecked()
}

func test_runJournalBundleQueuedCommandMustTerminalizeBeforeFinishedRunReopen() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home, runID: "queued-run")
    _ = try await bundle.commitInput(
        text: "deliver later", deliveryMode: .queued,
        command: try await exactCommand(bundle, id: "deliver-later"))
    do {
        _ = try await bundle.finishRun()
        XCTFail("a Run must not finish while an accepted command has no delivery outcome")
    } catch let error as RunJournalBundleError {
        XCTAssertEqual(error, .unfinishedCommands(["deliver-later"]))
    }
    _ = try await bundle.markCommandNotDelivered(
        commandID: "deliver-later", reason: "the active turn ended before delivery")
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()

    let reopened = try await RunJournalBundle.reopen(
        home: home, session: bundleTestSession, work: bundleTestWork, workHost: bundleTestHost,
        sessionAuthority: bundleTestAuthority, sessionAttachment: bundleTestAttachment,
        run: RunRef("delivery-run"), actor: bundleTestActor)
    let workEvents = try bundleEvents(home, reopened.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let reduced = WorkReducer.reduce(workEvents)
    XCTAssertTrue(reduced.structuralIntegrityValid && reduced.semanticProjectionValid)
    XCTAssertEqual(reduced.commands["deliver-later"]?.state, .notDelivered)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.commandAccepted }.count, 1)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.commandDelivered }.count, 0)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.commandNotDelivered }.count, 1)
    let sessionEvents = try bundleEvents(
        home, reopened.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    XCTAssertEqual(sessionEvents.filter { $0.type == TimelineEventType.inputAccepted }.count, 1)
    try await reopened.closeChecked()
}

func test_runJournalBundleTerminalRunOutcomesRemainTyped() async throws {
    let outcomes: [RunTerminalOutcome] = [.completed, .failed, .canceled, .held, .indeterminate]
    for (index, outcome) in outcomes.enumerated() {
        let home = try bundleTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let bundle = try await makeBundle(home: home, runID: "outcome-\(index)")
        _ = try await bundle.finishRun(outcome: outcome, detail: "detail-\(index)")
        let events = try bundleEvents(home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
        let finished = try XCTUnwrap(events.last(where: { $0.type == TimelineEventType.runFinished }))
        XCTAssertEqual(finished.payload["state"]?.stringValue, outcome.rawValue)
        XCTAssertEqual(finished.payload["detail"]?.stringValue, "detail-\(index)")
        let reduced = WorkReducer.reduce(events)
        XCTAssertTrue(reduced.structuralIntegrityValid && reduced.semanticProjectionValid)
        switch outcome {
        // WorkExecution is intentionally coarser than the typed terminal outcome: the current
        // reducer projects canceled and indeterminate runs to idle until a richer execution
        // projection is introduced. The durable run.finished payload remains lossless above.
        case .completed, .canceled, .indeterminate: XCTAssertEqual(reduced.execution, .idle)
        case .failed: XCTAssertEqual(reduced.execution, .failed)
        case .held: XCTAssertEqual(reduced.execution, .held)
        }
        try await bundle.closeChecked()
    }
}

func test_runJournalBundleTurnOutcomesReachCatalogNotificationsAndDeduplicate() async throws {
    let cases: [(RunTurnOutcome, SessionAttention, CanonicalNotificationKind?)] = [
        (.completed, .review, .readyForReview),
        (.failed, .error, .needsYou),
        (.canceled, .none, nil)
    ]
    for (index, item) in cases.enumerated() {
        let home = try bundleTestHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let bundle = try await makeBundle(home: home, runID: "turn-outcome-\(index)")
        _ = try await bundle.startTurn(TurnRef("turn-outcome"))
        let turnCommits = try await bundle.finishTurn(
            TurnRef("turn-outcome"), outcome: item.0)
        XCTAssertEqual(
            turnCommits.filter { $0.eventRef.journal == bundle.sessionJournal }.count,
            item.1 == .none ? 1 : 2)
        let workEvents = try bundleEvents(
            home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
        let finishedTurn = try XCTUnwrap(
            workEvents.last(where: { $0.type == TimelineEventType.turnFinished }))
        XCTAssertEqual(finishedTurn.payload["outcome"]?.stringValue, item.0.rawValue)
        let turnCatalog = LocalTimelineCatalog.scan(home: home)
        let turnSummary = try XCTUnwrap(turnCatalog.sessions.first?.summary)
        var delivery = CanonicalNotificationDelivery()
        _ = delivery.plan(CanonicalNotificationProjection(summaries: []))
        let turnPlan = delivery.plan(CanonicalNotificationProjection(summaries: [turnSummary]))
        if let expectedKind = item.2 {
            XCTAssertEqual(turnPlan.candidates.first?.kind, expectedKind)
            delivery.commit(try XCTUnwrap(turnPlan.candidates.first))
        } else {
            XCTAssertTrue(turnPlan.candidates.isEmpty)
        }
        _ = try await bundle.finishRun(
            outcome: item.0 == .failed ? .failed : item.0 == .canceled ? .canceled : .completed)
        let catalog = LocalTimelineCatalog.scan(home: home)
        let summary = try XCTUnwrap(catalog.sessions.first?.summary)
        XCTAssertEqual(summary.attention, item.1)
        let projection = CanonicalNotificationProjection(summaries: [summary])
        if let expectedKind = item.2 {
            XCTAssertEqual(projection.candidates.first?.kind, expectedKind)
            XCTAssertTrue(delivery.plan(projection).candidates.isEmpty,
                          "finishRun must not repeat a turn-boundary notification")
        } else {
            XCTAssertEqual(projection.observedStates[CanonicalAttentionIdentity.sessionRow(
                journal: summary.journal)], CanonicalNotificationState.none)
        }
        let sessionEvents = try bundleEvents(
            home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
        XCTAssertEqual(sessionEvents.filter { $0.type == TimelineEventType.sessionAttention }.count,
                       item.1 == .none ? 0 : 1,
                       "finishRun must not append the same attention after finishTurn")
        try await bundle.closeChecked()
    }

    let reopenHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: reopenHome.root) }
    let first = try await makeBundle(home: reopenHome, runID: "authored-first")
    _ = try await first.setAttention(.review)
    _ = try await first.finishRun(outcome: .completed)
    try await first.closeChecked()
    let reopenIDs = BundleTestIDs()
    let reopened = try await RunJournalBundle.reopen(
        home: reopenHome, session: bundleTestSession, work: bundleTestWork,
        workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
        sessionAttachment: bundleTestAttachment, run: RunRef("authored-second"),
        actor: bundleTestActor, eventIDProvider: { "reopen-" + reopenIDs.nextID() },
        now: { Date(timeIntervalSince1970: 1) })
    XCTAssertNil(try await reopened.setAttention(.review),
                 "reopen must seed authored attention from SessionReducer")
    _ = try await reopened.finishRun(outcome: .completed)
    let reopenedEvents = try bundleEvents(
        reopenHome, reopened.sessionJournal,
        reopenHome.timelineV2SessionJournalURL(bundleTestSession))
    XCTAssertEqual(reopenedEvents.filter { $0.type == TimelineEventType.sessionAttention }.count, 1)
    try await reopened.closeChecked()
}

func test_runJournalBundlePartialPrefixesLatchAndRefusePermits() async throws {
    let firstHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: firstHome.root) }
    let first = try await makeBundle(home: firstHome)
    await first.injectWriterFailure(.beforeWrite, in: .work)
    do {
        _ = try await first.commitInput(
            text: "lost", deliveryMode: .delivered,
            command: try await exactCommand(first, id: "first-failure"))
        XCTFail("first journal failure must throw")
    } catch { }
    let firstStatus = await bundleStatus(first)
    XCTAssertEqual(firstStatus.durablePrefix.workEventCount, 3)
    XCTAssertEqual(firstStatus.durablePrefix.sessionEventCount, 2)
    if case .failed = firstStatus.health { } else { XCTFail("first failure must latch bundle") }
    let firstEvents = try bundleEvents(
        firstHome, first.workJournal, firstHome.timelineV2WorkJournalURL(bundleTestWork))
    XCTAssertEqual(firstStatus.durablePrefix.hostOrder,
                   firstEvents.compactMap(\.hostSequence).max() ?? 0)
    do {
        _ = try await first.beginAction(kind: .python, intent: "must not run")
        XCTFail("latched bundle must not issue a permit")
    } catch { }
    try? await first.closeChecked()

    let secondHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: secondHome.root) }
    let second = try await makeBundle(home: secondHome)
    await second.injectWriterFailure(.beforeWrite, in: .session)
    do {
        _ = try await second.commitInput(
            text: "work prefix", deliveryMode: .delivered,
            command: try await exactCommand(second, id: "second-failure"))
        XCTFail("second journal failure must throw")
    } catch { }
    let secondStatus = await bundleStatus(second)
    XCTAssertEqual(secondStatus.durablePrefix.workEventCount, 5)
    XCTAssertEqual(secondStatus.durablePrefix.sessionEventCount, 2)
    XCTAssertEqual(secondStatus.durablePrefix.failedJournal, second.sessionJournal)
    if case .failed = secondStatus.health { } else { XCTFail("second failure must latch bundle") }
    let secondEvents = try bundleEvents(
        secondHome, second.workJournal, secondHome.timelineV2WorkJournalURL(bundleTestWork))
    let secondSessionEvents = try bundleEvents(
        secondHome, second.sessionJournal, secondHome.timelineV2SessionJournalURL(bundleTestSession))
    XCTAssertEqual(secondStatus.durablePrefix.hostOrder,
                   max(secondEvents.compactMap(\.hostSequence).max() ?? 0,
                       secondSessionEvents.compactMap(\.hostSequence).max() ?? 0))
    do {
        _ = try await second.beginAction(kind: .python, intent: "must not run")
        XCTFail("latched bundle must not issue a permit")
    } catch { }
    try? await second.closeChecked()
}

func test_runJournalBundleOutcomeFailureRequiresMetadataButCanContinue() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let permit = try await bundle.beginAction(kind: .providerSetup, intent: "construct provider")
    do {
        _ = try await bundle.finishAction(permit, state: .failed, retrySafety: .unknown)
        XCTFail("failed action must carry failure kind")
    } catch { }
    _ = try await bundle.finishAction(
        permit, state: .failed, retrySafety: .unknown, failureKind: .task)
    let retry = try await bundle.beginAction(kind: .providerSetup, intent: "retry setup safely")
    _ = try await bundle.finishAction(retry, state: .succeeded, retrySafety: .idempotent)
    let events = try bundleEvents(home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let reduced = WorkReducer.reduce(events)
    XCTAssertTrue(reduced.semanticProjectionValid)
    XCTAssertEqual(reduced.actions[permit.action.actionID]?.failureKind, .task)
    try await bundle.closeChecked()
}

func test_runJournalBundleReopenNPlusOneAndRefusesIncompletePairsOrActiveWriters() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    let finishCommits = try await bundle.finishRun()
    XCTAssertEqual(finishCommits.map(\.cursor.journal), [
        bundle.workJournal, bundle.sessionJournal, bundle.sessionJournal])
    let finishedSessionEvents = try bundleEvents(
        home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    let finishedWorkEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    let cursorAdvanced = try XCTUnwrap(finishedSessionEvents.last(where: {
        $0.type == TimelineEventType.sessionAttachmentCursorAdvanced
    }))
    XCTAssertEqual(cursorAdvanced.payload["cursor"]?["sequence"]?.intValue,
                   finishedWorkEvents.last?.sequence)
    for operation in 0..<4 {
        do {
            switch operation {
            case 0:
                _ = try await bundle.commitInput(
                    text: "late", deliveryMode: .queued, command: CommandRef(commandID: "late"))
            case 1:
                _ = try await bundle.startTurn(TurnRef("late-turn"))
            case 2:
                _ = try await bundle.changeModel("late-model")
            default:
                _ = try await bundle.commitAssistantMessage("late")
            }
            XCTFail("a finished Run must not accept semantic mutation \(operation)")
        } catch { }
    }
    try await bundle.closeChecked()

    let reopened = try await RunJournalBundle.reopen(
        home: home, session: bundleTestSession, work: bundleTestWork, workHost: bundleTestHost,
        sessionAuthority: bundleTestAuthority, sessionAttachment: bundleTestAttachment,
        run: RunRef("run-2"), actor: bundleTestActor,
        eventIDProvider: { "reopened-event" }, now: { Date(timeIntervalSince1970: 2) })
    let workEvents = try bundleEvents(home, reopened.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    XCTAssertEqual(workEvents.first?.type, TimelineEventType.workCreated)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.workCreated }.count, 1)
    XCTAssertEqual(workEvents.last?.run, RunRef("run-2"))
    XCTAssertEqual(workEvents.last?.sequence, 5)
    XCTAssertEqual((await bundleStatus(reopened)).durablePrefix.workEventCount, 5)
    try await reopened.closeChecked()

    let activeHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: activeHome.root) }
    let active = try await makeBundle(home: activeHome)
    do {
        _ = try await RunJournalBundle.reopen(
            home: activeHome, session: bundleTestSession, work: bundleTestWork,
            workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
            sessionAttachment: bundleTestAttachment, run: RunRef("run-active"), actor: bundleTestActor)
        XCTFail("an existing writer must not be duplicated")
    } catch let error as RunJournalBundleError {
        if case .duplicateActiveWriter = error { } else { XCTFail("wrong active writer error: \(error)") }
    }
    try? await active.closeChecked()
    do {
        _ = try await RunJournalBundle.reopen(
            home: activeHome, session: bundleTestSession, work: bundleTestWork,
            workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
            sessionAttachment: bundleTestAttachment, run: RunRef("run-active-cold"),
            actor: bundleTestActor)
        XCTFail("cold resume must not silently replace an active prior Run")
    } catch let error as RunJournalBundleError {
        if case .invalidOperation = error { } else { XCTFail("wrong active Run refusal: \(error)") }
    }

    let proposedHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: proposedHome.root) }
    let proposed = try await makeBundle(home: proposedHome)
    await proposed.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    do {
        _ = try await proposed.beginAction(action: ActionRef("proposed-only"), kind: .python,
                                            intent: "write intent, then lose the start receipt")
        XCTFail("injected action start failure must throw")
    } catch { }
    try? await proposed.closeChecked()
    do {
        _ = try await RunJournalBundle.reopen(
            home: proposedHome, session: bundleTestSession, work: bundleTestWork,
            workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
            sessionAttachment: bundleTestAttachment, run: RunRef("run-proposed-cold"),
            actor: bundleTestActor)
        XCTFail("cold resume must refuse a proposed-only action")
    } catch let error as RunJournalBundleError {
        if case .unfinishedActions(let ids) = error {
            XCTAssertEqual(ids, ["proposed-only"])
        } else { XCTFail("wrong proposed action refusal: \(error)") }
    }

    let missingHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: missingHome.root) }
    let missing = try await makeBundle(home: missingHome)
    try await missing.closeChecked()
    try FileManager.default.removeItem(at: missingHome.timelineV2WorkJournalURL(bundleTestWork))
    do {
        _ = try await RunJournalBundle.reopen(
            home: missingHome, session: bundleTestSession, work: bundleTestWork,
            workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
            sessionAttachment: bundleTestAttachment, run: RunRef("run-missing"), actor: bundleTestActor)
        XCTFail("one missing journal must be refused")
    } catch let error as RunJournalBundleError {
        if case .missingCounterpart = error { } else { XCTFail("wrong missing counterpart error: \(error)") }
    }

    let corruptHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: corruptHome.root) }
    let corrupt = try await makeBundle(home: corruptHome)
    _ = try await corrupt.finishRun()
    try await corrupt.closeChecked()
    let corruptURL = corruptHome.timelineV2SessionJournalURL(bundleTestSession)
    var corruptBytes = try Data(contentsOf: corruptURL)
    corruptBytes.append(Data("{not-json}\n".utf8))
    try corruptBytes.write(to: corruptURL)
    do {
        _ = try await RunJournalBundle.reopen(
            home: corruptHome, session: bundleTestSession, work: bundleTestWork,
            workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
            sessionAttachment: bundleTestAttachment, run: RunRef("run-corrupt"), actor: bundleTestActor)
        XCTFail("a malformed native tail must be refused")
    } catch let error as RunJournalBundleError {
        switch error {
        case .invalidJournal:
            break
        case .writer(.invalidJournal):
            break
        default:
            XCTFail("wrong corrupt journal error: \(error)")
        }
    }
}

func test_runJournalBundleReopenContinuesFromSemanticTipNotPhysicalTail() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    _ = try await bundle.commitInput(
        text: "root", deliveryMode: .delivered,
        command: try await exactCommand(bundle, id: "root-command"))
    _ = try await bundle.commitAssistantMessage("selected answer")
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()

    let sessionURL = home.timelineV2SessionJournalURL(bundleTestSession)
    let beforeBranch = try bundleEvents(home, bundle.sessionJournal, sessionURL)
    let beforeState = SessionReducer.reduce(beforeBranch)
    let selectedTip = try XCTUnwrap(beforeState.semanticTip)
    let branchWriter = try TimelineJournalWriter(
        reopening: sessionURL, journal: bundle.sessionJournal, actor: bundleTestActor, home: home,
        eventIDProvider: { "unselected-branch" }, now: { Date(timeIntervalSince1970: 3) })
    _ = try await branchWriter.append(TimelineEventDraft(
        hostSequence: 99, conversationParent: selectedTip,
        session: bundleTestSession, type: TimelineEventType.messageCommitted,
        declaredDomains: [.session], payload: .object([
            "role": .string("assistant"), "text": .string("unselected branch")
        ])))
    try await branchWriter.closeChecked()

    let reopened = try await RunJournalBundle.reopen(
        home: home, session: bundleTestSession, work: bundleTestWork, workHost: bundleTestHost,
        sessionAuthority: bundleTestAuthority, sessionAttachment: bundleTestAttachment,
        run: RunRef("branch-followup"), actor: bundleTestActor,
        eventIDProvider: { "branch-followup-event-\(UUID().uuidString)" })
    _ = try await reopened.commitAssistantMessage("continued from selected tip")
    let after = try bundleEvents(home, reopened.sessionJournal, sessionURL)
    let continued = try XCTUnwrap(after.last(where: {
        $0.type == TimelineEventType.messageCommitted && $0.payload["text"]?.stringValue == "continued from selected tip"
    }))
    XCTAssertEqual(continued.conversationParent, selectedTip)
    try await reopened.closeChecked()
}

func test_runJournalBundleCheckedCloseReportsPartialClose() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    _ = try await bundle.finishRun()
    await bundle.injectWriterFailure(.close, in: .session)
    do {
        try await bundle.closeChecked()
        XCTFail("injected close must be reported")
    } catch let error as RunJournalBundleError {
        guard case .closeFailed(let prefix, _) = error else {
            XCTFail("expected partial close, got \(error)"); return
        }
        XCTAssertEqual(prefix.sessionEventCount, 4)
        XCTAssertEqual(prefix.workEventCount, 4)
    }
    let reopened = try await RunJournalBundle.reopen(
        home: home, session: bundleTestSession, work: bundleTestWork, workHost: bundleTestHost,
        sessionAuthority: bundleTestAuthority, sessionAttachment: bundleTestAttachment,
        run: RunRef("run-after-close"), actor: bundleTestActor)
    try await reopened.closeChecked()
}

func test_runJournalBundleProducesCanonicalAttentionTransitions() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    _ = try await bundle.commitInput(
        text: "work on this", deliveryMode: .delivered,
        command: try await exactCommand(bundle, id: "attention-input"))
    let during: SessionSnapshot = SessionReducer.reduce(
        try bundleEvents(home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundle.session)))
    XCTAssertEqual(during.attention, SessionAttention.none)
    _ = try await bundle.finishRun(outcome: .completed)
    let finished: SessionSnapshot = SessionReducer.reduce(
        try bundleEvents(home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundle.session)))
    XCTAssertEqual(finished.attention, SessionAttention.review)
    XCTAssertTrue(try bundleEvents(home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundle.session))
        .contains { $0.type == TimelineEventType.sessionAttention })
    try await bundle.closeChecked()
}

func test_runJournalBundleCanceledTaskStillFinishesAndCloses() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)

    let teardown = Task {
        // Cancellation wakes this suspension while leaving the task's cancellation flag set.
        // Terminal journal operations must still cross their semantic gate afterward.
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        _ = try await bundle.finishRun(outcome: .canceled, detail: "pre-canceled teardown")
        try await bundle.closeChecked()
    }
    teardown.cancel()
    try await teardown.value

    let workEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    XCTAssertEqual(workEvents.last?.type, TimelineEventType.runFinished)
    XCTAssertEqual(workEvents.last?.payload["state"]?.stringValue, RunTerminalOutcome.canceled.rawValue)
    XCTAssertEqual((await bundleStatus(bundle)).health, .closed)
}

func test_runJournalBundleCompleteWorkIsSeparateFromFinishedRunAndClosesMutation() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)

    do {
        _ = try await bundle.completeWork(
            command: try await terminalCommand(bundle, id: "complete-active"))
        XCTFail("active Run must be finished before Work completion")
    } catch { }
    _ = try await bundle.startHandle(HandleRef("terminal-handle"))
    do {
        _ = try await bundle.finishRun()
        XCTFail("finishRun must reject a live canonical Handle")
    } catch let error as RunJournalBundleError {
        guard case .unfinishedHandles(["terminal-handle"]) = error else {
            XCTFail("wrong live Handle error: \(error)")
            return
        }
    }
    let beforeHandleFinish = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    XCTAssertFalse(beforeHandleFinish.contains { $0.type == TimelineEventType.runFinished })
    _ = try await bundle.finishHandle(HandleRef("terminal-handle"))
    _ = try await bundle.finishRun(outcome: .completed)
    let reusableLifecycle = await bundle.lifecycle
    XCTAssertEqual(reusableLifecycle, .active)
    let beforeOversizedDetail = (await bundleStatus(bundle)).durablePrefix
    do {
        _ = try await bundle.completeWork(
            detail: String(repeating: "x", count: 4_001),
            command: try await terminalCommand(bundle, id: "complete-oversized"))
        XCTFail("oversized completion detail must be rejected before append")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation = error else {
            XCTFail("wrong oversized detail error: \(error)")
            return
        }
    }
    XCTAssertEqual((await bundleStatus(bundle)).durablePrefix, beforeOversizedDetail)

    let completionCommand = try await terminalCommand(bundle, id: "complete-work")
    let terminal = try await bundle.completeWork(
        detail: "done for now", command: completionCommand)
    XCTAssertEqual(terminal.count, 2)
    XCTAssertEqual(terminal[0].eventRef.journal, bundle.workJournal)
    let completedLifecycle = await bundle.lifecycle
    XCTAssertEqual(completedLifecycle, .completed)

    let workEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.workCompleted }.count, 1)
    XCTAssertEqual(workEvents.last?.type, TimelineEventType.workCompleted)
    XCTAssertEqual(workEvents.last?.command, completionCommand)
    XCTAssertNotNil(workEvents.last?.idempotencyKey)
    XCTAssertEqual(workEvents.last?.payload["detail"]?.stringValue, "done for now")
    let work = WorkReducer.reduce(workEvents)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
    XCTAssertEqual(work.lifecycle, .completed)
    XCTAssertNil(work.activeRun)
    let sessionEvents = try bundleEvents(
        home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    let session = SessionReducer.reduce(sessionEvents)
    XCTAssertTrue(session.structuralIntegrityValid && session.semanticProjectionValid)
    XCTAssertEqual(session.attachments[bundleTestAttachment.attachmentID]?.cursor, terminal[0].cursor)
    XCTAssertEqual(
        sessionEvents.last?.causedByEventID,
        terminal[0].eventRef)

    do {
        _ = try await bundle.commitInput(
            text: "must not mutate completed Work", deliveryMode: .queued,
            command: CommandRef(commandID: "after-complete"))
        XCTFail("completed Work must reject later mutations")
    } catch let error as RunJournalBundleError {
        guard case .workTerminal(.completed) = error else {
            XCTFail("wrong terminal error: \(error)")
            return
        }
    }
    try await bundle.closeChecked()

    do {
        _ = try await RunJournalBundle.reopen(
            home: home, session: bundleTestSession, work: bundleTestWork,
            workHost: bundleTestHost, sessionAuthority: bundleTestAuthority,
            sessionAttachment: bundleTestAttachment, run: RunRef("run-after-complete"),
            actor: bundleTestActor)
        XCTFail("completed Work must not accept a replacement Run")
    } catch let error as RunJournalBundleError {
        guard case .workTerminal(.completed) = error else {
            XCTFail("wrong reopen error: \(error)")
            return
        }
    }

    for (index, detail) in terminalDetailRoundTripMatrix.enumerated() {
        try await assertTerminalDetailRoundTrip(
            operation: .complete, detail: detail, index: index)
    }
}

func test_runJournalBundleTerminalCommitterRecoversExactRetryWithoutSecondEvent() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    _ = try await bundle.finishRun(outcome: .completed)
    let command = try await terminalCommand(bundle, id: "terminal-adapter-complete")
    let cursor = try XCTUnwrap(command.causalCursor)
    let request = WorkServiceTerminalCommitRequest(
        operation: .complete, work: bundle.work, journal: bundle.workJournal,
        client: try XCTUnwrap(command.client), session: bundle.session,
        sessionJournal: bundle.sessionJournal,
        sessionAttachment: bundle.sessionAttachment,
        causalWorkCursor: cursor, detail: "stable retry", command: command)

    let firstAdapter = RunJournalBundleWorkServiceTerminalCommitter(bundle: bundle)
    let committed = try await firstAdapter.commit(request)
    XCTAssertEqual(committed.command, command)
    XCTAssertEqual(committed.causalWorkCursor, cursor)
    XCTAssertEqual(committed.terminalEvent.type, TimelineEventType.workCompleted)
    XCTAssertEqual(committed.terminalEvent.journal, committed.resultingWorkCursor.journal)
    XCTAssertEqual(committed.terminalEvent.eventID, committed.resultingWorkCursor.eventID)
    XCTAssertEqual(committed.terminalEvent.sequence, committed.resultingWorkCursor.sequence)
    XCTAssertEqual(committed.session, bundle.session)
    XCTAssertEqual(committed.sessionJournal, bundle.sessionJournal)
    XCTAssertTrue(committed.sessionPairingVerified)
    XCTAssertNotNil(committed.pairedSessionCursor)

    // Model the response being lost and the service adapter restarting after its writers close.
    // Canonical lookup must return the exact prior proof rather than appending a second event.
    try await bundle.closeChecked()
    let restartedAdapter = RunJournalBundleWorkServiceTerminalCommitter(bundle: bundle)
    let recovered = try await restartedAdapter.commit(request)
    XCTAssertEqual(recovered, committed)
    XCTAssertEqual(try await restartedAdapter.committedProof(for: request), committed)

    let workEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundle.work))
    XCTAssertEqual(
        workEvents.filter {
            $0.type == TimelineEventType.workCompleted && $0.command == command
        }.count,
        1)
    let sessionEvents = try bundleEvents(
        home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundle.session))
    XCTAssertEqual(
        sessionEvents.filter {
            $0.type == TimelineEventType.sessionAttachmentCursorAdvanced
                && $0.command == command
        }.count,
        1)

}

func test_runJournalBundleTerminalMutationReopensWithoutStartingAnotherRun() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "terminal-reopen-session",
        work: WorkRef(workHostID: hostID, workID: "terminal-reopen-work"),
        runID: "terminal-reopen-run")
    let execution = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "terminal-reopen-execution",
        makeAttachmentID: { "terminal-reopen-attachment" })
    _ = try await execution.finishRun(outcome: .completed)
    let finishedCursor = await execution.latestWorkCursor
    let causal = try XCTUnwrap(finishedCursor)
    let attachment = execution.sessionAttachment
    let workJournal = execution.workJournal
    let sessionJournal = execution.sessionJournal
    try await execution.closeChecked()

    let terminal = try await RunJournalBundle.openForTerminalMutation(
        home: home, identity: identity, sessionAttachment: attachment,
        actorID: "terminal-reopen-committer")
    XCTAssertEqual(await terminal.latestWorkCursor, causal)
    XCTAssertEqual(await terminal.lifecycle, .active)
    let command = CommandRef(
        commandID: "terminal-reopen-complete", client: ClientRef("terminal-reopen-client"),
        sessionAttachment: attachment, causalCursor: causal)
    let commits = try await terminal.completeWork(detail: "complete after End", command: command)
    XCTAssertEqual(commits.count, 2)
    try await terminal.closeChecked()

    // A service restart/lost response reads the already-terminal pair without acquiring writer
    // ownership or appending a replacement Run.
    let proof = try XCTUnwrap(
        try RunJournalBundle.readTerminalCommit(
            home: home, identity: identity, sessionAttachment: attachment,
            command: command, detail: "complete after End"))
    XCTAssertEqual(proof.workCommit, commits[0])
    XCTAssertEqual(proof.pairedSessionCommit, commits[1])

    do {
        _ = try await RunJournalBundle.openForTerminalMutation(
            home: home, identity: identity, sessionAttachment: attachment,
            actorID: "terminal-reopen-writer-proof")
        XCTFail("terminal proof lookup must not reopen a writer on terminal Work")
    } catch let error as RunJournalBundleError {
        guard case .workTerminal(.completed) = error else {
            XCTFail("wrong terminal writer proof error: \(error)")
            return
        }
    }

    let workEvents = try bundleEvents(
        home, workJournal, home.timelineV2WorkJournalURL(identity.work))
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.runStarted }.count, 1)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.runFinished }.count, 1)
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.workCompleted }.count, 1)
    let sessionEvents = try bundleEvents(
        home, sessionJournal, home.timelineV2SessionJournalURL(SessionRef(identity.sessionID)))
    XCTAssertEqual(
        sessionEvents.filter {
            $0.type == TimelineEventType.sessionAttachmentCursorAdvanced
                && $0.command == command
        }.count,
        1)

    // Recovery proof is descriptor-based and must never follow a replaced canonical locator.
    let workURL = home.timelineV2WorkJournalURL(identity.work)
    let movedWorkURL = workURL.appendingPathExtension("terminal-proof-source")
    try FileManager.default.moveItem(at: workURL, to: movedWorkURL)
    try FileManager.default.createSymbolicLink(at: workURL, withDestinationURL: movedWorkURL)
    do {
        _ = try RunJournalBundle.readTerminalCommit(
            home: home, identity: identity, sessionAttachment: attachment,
            command: command, detail: "complete after End")
        XCTFail("terminal proof must reject a symlinked canonical Work journal")
    } catch let error as RunJournalBundleError {
        guard case .invalidJournal(let journal, _) = error else {
            XCTFail("wrong symlinked terminal proof error: \(error)")
            return
        }
        XCTAssertEqual(journal, workJournal)
    }
}

func test_runJournalBundleCreatesIdleWorkBeforeAnyRunStarts() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let host = try home.requirePersistedWorkHost()
    let session = SessionRef("idle-create-session")
    let work = WorkRef(workHostID: host.workHostID, workID: "idle-create-work")
    let attachment = SessionAttachmentRef("idle-create-attachment")
    let binding = WorkBinding(
        session: session,
        work: work,
        workHost: host,
        sessionAttachment: attachment)

    let created = try await RunJournalBundle.createIdleWork(
        home: home,
        binding: binding,
        actorID: "idle-create-control")
    XCTAssertEqual(created.binding, binding)
    XCTAssertEqual(created.commits.count, 4)
    XCTAssertEqual(created.sessionCursor.sequence, 2)
    XCTAssertEqual(created.workCursor.sequence, 2)

    let workEvents = try bundleEvents(
        home, binding.workJournal, home.timelineV2WorkJournalURL(work))
    XCTAssertEqual(workEvents.map(\.type), [
        TimelineEventType.workCreated,
        TimelineEventType.sessionAttached,
    ])
    XCTAssertFalse(workEvents.contains { $0.type == TimelineEventType.runStarted })
    let reducedWork = WorkReducer.reduce(workEvents)
    XCTAssertTrue(reducedWork.structuralIntegrityValid)
    XCTAssertTrue(reducedWork.semanticProjectionValid)
    XCTAssertNil(reducedWork.activeRun)
    XCTAssertEqual(reducedWork.lifecycle, .active)

    let sessionEvents = try bundleEvents(
        home, binding.sessionJournal, home.timelineV2SessionJournalURL(session))
    XCTAssertEqual(sessionEvents.map(\.type), [
        TimelineEventType.sessionCreated,
        TimelineEventType.sessionAttached,
    ])
    let reducedSession = SessionReducer.reduce(sessionEvents)
    XCTAssertTrue(reducedSession.structuralIntegrityValid)
    XCTAssertTrue(reducedSession.semanticProjectionValid)

    // Start is a distinct later ownership transition with its own host-minted Run identity.
    let executionBinding = WorkRunBinding(
        workBinding: binding,
        run: RunRef("idle-create-run"))
    let execution = try await RunJournalBundle.openForExecution(
        home: home,
        binding: executionBinding,
        actorID: "idle-create-execution")
    let executionAttachment = execution.sessionAttachment
    XCTAssertEqual(executionAttachment, attachment)
    let afterStart = try bundleEvents(
        home, binding.workJournal, home.timelineV2WorkJournalURL(work))
    XCTAssertEqual(afterStart.filter { $0.type == TimelineEventType.runStarted }.count, 1)
    XCTAssertEqual(afterStart.last?.run, RunRef("idle-create-run"))
    _ = try await execution.finishRun(outcome: .canceled)
    try await execution.closeChecked()
}

func test_runJournalBundleSessionPublicationRejectsStalePartialSaga() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let host = try home.requirePersistedWorkHost()
    let primary = WorkBinding(
        session: SessionRef("publication-primary-session"),
        work: WorkRef(workHostID: host.workHostID, workID: "publication-shared-work"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("publication-primary-attachment"))
    let idle = try await RunJournalBundle.createIdleWork(
        home: home, binding: primary, actorID: "publication-idle-control")

    func request(
        suffix: String, client: ClientRef
    ) -> RunJournalBundleSessionPublicationRequest {
        let session = SessionRef("publication-session-\(suffix)")
        let attachment = SessionAttachmentRef("publication-attachment-\(suffix)")
        return RunJournalBundleSessionPublicationRequest(
            work: primary.work, workHost: host, workJournal: primary.workJournal,
            session: session,
            sessionJournal: .session(
                session, journalID: "session",
                authority: TimelineAuthorityRef(host.workHostID)),
            sessionAttachment: attachment, client: client,
            command: CommandRef(
                commandID: "publication-command-\(suffix)", client: client,
                sessionAttachment: attachment, causalCursor: idle.workCursor),
            capabilities: [WorkServiceCapability.observe.rawValue],
            causalWorkCursor: idle.workCursor)
    }
    let requestA = request(suffix: "a", client: ClientRef("publication-client-a"))
    let requestB = request(suffix: "b", client: ClientRef("publication-client-b"))

    do {
        _ = try await RunJournalBundle.publishSessionAttachment(
            home: home, request: requestA, actorID: "publication-host",
            failurePlan: (.none, .init(point: .beforeWrite)))
        XCTFail("injected Work-mirror failure unexpectedly completed publication A")
    } catch {
        XCTAssertTrue(true)
    }
    let partialA = try bundleEvents(
        home, requestA.sessionJournal,
        home.timelineV2SessionJournalURL(requestA.session))
    XCTAssertEqual(partialA.map(\.type), [
        TimelineEventType.sessionCreated, TimelineEventType.sessionAttached,
    ])

    let publicationB = try await RunJournalBundle.publishSessionAttachment(
        home: home, request: requestB, actorID: "publication-host")
    XCTAssertEqual(publicationB.resultingWorkCursor.sequence,
                   idle.workCursor.sequence + 1)
    let workBytesAfterB = try Data(
        contentsOf: home.timelineV2WorkJournalURL(primary.work))
    do {
        _ = try await RunJournalBundle.publishSessionAttachment(
            home: home, request: requestA, actorID: "publication-host")
        XCTFail("stale publication A appended after publication B won the causal Work cursor")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation(let reason) = error,
              reason.contains("cursor advanced") else {
            XCTFail("wrong stale publication error: \(error)")
            return
        }
    }
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(primary.work)),
                   workBytesAfterB)
    let stillPartialA = try bundleEvents(
        home, requestA.sessionJournal,
        home.timelineV2SessionJournalURL(requestA.session))
    XCTAssertEqual(stillPartialA.map(\.type), partialA.map(\.type))
    let exactB = try await RunJournalBundle.publishSessionAttachment(
        home: home, request: requestB, actorID: "publication-host")
    XCTAssertEqual(exactB, publicationB)
}

func test_runJournalBundleSessionPublicationRejectsCursorWithoutMirror() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let host = try home.requirePersistedWorkHost()
    let primary = WorkBinding(
        session: SessionRef("publication-orphan-primary"),
        work: WorkRef(workHostID: host.workHostID, workID: "publication-orphan-work"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("publication-orphan-primary-attachment"))
    let idle = try await RunJournalBundle.createIdleWork(
        home: home, binding: primary, actorID: "publication-orphan-control")
    let session = SessionRef("publication-orphan-session")
    let attachment = SessionAttachmentRef("publication-orphan-attachment")
    let client = ClientRef("publication-orphan-client")
    let sessionJournal = JournalRef.session(
        session, journalID: "session", authority: TimelineAuthorityRef(host.workHostID))
    let command = CommandRef(
        commandID: "publication-orphan-command", client: client,
        sessionAttachment: attachment, causalCursor: idle.workCursor)
    let request = RunJournalBundleSessionPublicationRequest(
        work: primary.work, workHost: host, workJournal: primary.workJournal,
        session: session, sessionJournal: sessionJournal,
        sessionAttachment: attachment, client: client, command: command,
        capabilities: [WorkServiceCapability.observe.rawValue],
        causalWorkCursor: idle.workCursor)
    do {
        _ = try await RunJournalBundle.publishSessionAttachment(
            home: home, request: request, actorID: "publication-orphan-host",
            failurePlan: (.none, .init(point: .beforeWrite)))
        XCTFail("injected Work-mirror failure unexpectedly completed publication")
    } catch {
        XCTAssertTrue(true)
    }

    let writer = try TimelineJournalWriter(
        reopening: home.timelineV2SessionJournalURL(session),
        journal: sessionJournal,
        actor: TimelineActor(actorID: "publication-orphan-host", kind: "work-host-control"),
        home: home)
    let workCause = EventRef(
        journal: primary.workJournal, eventID: try XCTUnwrap(idle.workCursor.eventID))
    let encodedCursor = try XCTUnwrap(
        JSONValue.parse(try JSONEncoder().encode(idle.workCursor)))
    _ = try await writer.append(TimelineEventDraft(
        hostSequence: 100, idempotencyKey: command.commandID, command: command,
        causedByEventID: workCause,
        session: session, work: primary.work, workHost: host, client: client,
        sessionAttachment: attachment,
        type: TimelineEventType.sessionAttachmentCursorAdvanced,
        declaredDomains: [.session, .work], payload: .object([
            "capabilities": .array([.string(WorkServiceCapability.observe.rawValue)]),
            "cursor": encodedCursor,
        ])))
    try await writer.closeChecked()
    let workBytesBeforeRetry = try Data(
        contentsOf: home.timelineV2WorkJournalURL(primary.work))
    do {
        _ = try await RunJournalBundle.publishSessionAttachment(
            home: home, request: request, actorID: "publication-orphan-host")
        XCTFail("Session cursor evidence without its Work mirror was repaired as success")
    } catch let error as RunJournalBundleError {
        guard case .invalidGenesis(_, let reason) = error,
              reason.contains("without its Work publication mirror") else {
            XCTFail("wrong orphaned Session cursor error: \(error)")
            return
        }
    }
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(primary.work)),
                   workBytesBeforeRetry)
    XCTAssertEqual(try bundleEvents(
        home, sessionJournal,
        home.timelineV2SessionJournalURL(session)).count, 3)
}

func test_runJournalBundleTerminalMutationRejectsStaleRunGeneration() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let work = WorkRef(workHostID: hostID, workID: "terminal-generation-work")
    let firstIdentity = SessionWorkIdentity(
        sessionID: "terminal-generation-session", work: work, runID: "terminal-run-1")
    let first = try await RunJournalBundle.openForExecution(
        home: home, identity: firstIdentity, actorID: "terminal-generation-first",
        makeAttachmentID: { "terminal-generation-attachment" })
    _ = try await first.finishRun(outcome: .completed)
    let attachment = first.sessionAttachment
    try await first.closeChecked()

    let latestIdentity = SessionWorkIdentity(
        sessionID: firstIdentity.sessionID, work: work, runID: "terminal-run-2")
    let latest = try await RunJournalBundle.openForExecution(
        home: home, identity: latestIdentity, actorID: "terminal-generation-latest")
    _ = try await latest.finishRun(outcome: .completed)
    try await latest.closeChecked()

    do {
        _ = try await RunJournalBundle.openForTerminalMutation(
            home: home, identity: firstIdentity, sessionAttachment: attachment,
            actorID: "terminal-generation-stale")
        XCTFail("an earlier Run generation must not terminalize Work after a later Run")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation(let reason) = error,
              reason.contains("latest canonical Run") else {
            XCTFail("wrong stale terminal generation error: \(error)")
            return
        }
    }

    let terminal = try await RunJournalBundle.openForTerminalMutation(
        home: home, identity: latestIdentity, sessionAttachment: attachment,
        actorID: "terminal-generation-current")
    try await terminal.closeChecked()
}

func test_runJournalBundleDestroyWorkRequiresQuiescedResourcesAndWritesOneTombstone() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)
    _ = try await bundle.finishRun(outcome: .canceled)
    let beforeOversizedDetail = (await bundleStatus(bundle)).durablePrefix
    do {
        _ = try await bundle.destroyWork(
            resourcesQuiesced: true, reason: String(repeating: "x", count: 4_001),
            command: try await terminalCommand(bundle, id: "destroy-oversized"))
        XCTFail("oversized destruction detail must be rejected before append")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation = error else {
            XCTFail("wrong oversized destruction detail error: \(error)")
            return
        }
    }
    XCTAssertEqual((await bundleStatus(bundle)).durablePrefix, beforeOversizedDetail)

    // The limit is on the encoded durable body, not Swift Character count. Two thousand and
    // one two-byte scalars fit the character-shaped bound but exceed 4,000 UTF-8 bytes.
    do {
        _ = try await bundle.destroyWork(
            resourcesQuiesced: true,
            reason: String(repeating: "é", count: 2_001),
            command: try await terminalCommand(bundle, id: "destroy-multibyte-oversized"))
        XCTFail("multibyte destruction detail must be rejected by UTF-8 byte size")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation = error else {
            XCTFail("wrong multibyte destruction detail error: \(error)")
            return
        }
    }
    XCTAssertEqual((await bundleStatus(bundle)).durablePrefix, beforeOversizedDetail)

    do {
        _ = try await bundle.destroyWork(
            resourcesQuiesced: false,
            command: try await terminalCommand(bundle, id: "destroy-not-quiesced"))
        XCTFail("destruction must require explicit service resource quiescence")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation(let reason) = error,
              reason.contains("resources are quiesced") else {
            XCTFail("wrong non-quiesced destruction error: \(error)")
            return
        }
    }

    let destroyCommand = try await terminalCommand(bundle, id: "destroy-work")
    let terminal = try await bundle.destroyWork(
        resourcesQuiesced: true, reason: "deleted", command: destroyCommand)
    XCTAssertEqual(terminal.count, 2)
    let destroyedLifecycle = await bundle.lifecycle
    XCTAssertEqual(destroyedLifecycle, .destroyed)
    let workEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    XCTAssertEqual(workEvents.filter { $0.type == TimelineEventType.workDestroyed }.count, 1)
    XCTAssertEqual(workEvents.last?.type, TimelineEventType.workDestroyed)
    XCTAssertEqual(workEvents.last?.command, destroyCommand)
    XCTAssertNotNil(workEvents.last?.idempotencyKey)
    XCTAssertEqual(workEvents.last?.payload["tombstone"]?.boolValue, true)
    XCTAssertEqual(workEvents.last?.payload["detail"]?.stringValue, "deleted")
    let work = WorkReducer.reduce(workEvents)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
    XCTAssertEqual(work.lifecycle, .destroyed)

    do {
        _ = try await bundle.destroyWork(
            resourcesQuiesced: true,
            command: try await terminalCommand(bundle, id: "destroy-again"))
        XCTFail("destroy must be exactly once")
    } catch let error as RunJournalBundleError {
        guard case .workTerminal(.destroyed) = error else {
            XCTFail("wrong duplicate destruction error: \(error)")
            return
        }
    }
    try await bundle.closeChecked()

    for (index, detail) in terminalDetailRoundTripMatrix.enumerated() {
        try await assertTerminalDetailRoundTrip(
            operation: .destroy, detail: detail, index: index)
    }
}

func test_timelineJournalWriterStreamingReopenStreamsAndRecoversTail() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let host = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef("bounded-reopen-session"),
        work: WorkRef(workHostID: host.workHostID, workID: "bounded-reopen-work"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("bounded-reopen-attachment"))
    let created = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "bounded-reopen-genesis")
    let url = home.timelineV2WorkJournalURL(binding.work)
    let partial = try FileHandle(forWritingTo: url)
    try partial.seekToEnd()
    try partial.write(contentsOf: Data("{\"unterminated\":\"tail".utf8))
    try partial.close()

    let writer = try TimelineJournalWriter(
        reopeningStreaming: url, journal: binding.workJournal,
        actor: TimelineActor(actorID: "bounded-reopen", kind: "work-host-control"),
        home: home, maximumChunkBytes: 32, maximumRecordBytes: 4 * 1_024)
    XCTAssertEqual(await writer.nextSequenceNumber, created.workCursor.sequence + 1)
    try await writer.closeChecked()

    let bytes = try Data(contentsOf: url)
    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("unterminated"))
    let read = TimelineJournalReader.read(
        bytes, journal: binding.workJournal,
        actor: TimelineActor(actorID: "bounded-reopen", kind: "work-host-control"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertNil(read.truncatedTail)
    XCTAssertNil(read.quarantinedSuffix)
    XCTAssertEqual(read.records.count, created.workCursor.sequence)
}

func test_workTerminalReducerRejectsCompletionAndDestructionWithLiveCanonicalHandle() {
    let work = WorkRef(workHostID: "terminal-handle-host", workID: "terminal-handle-work")
    let journal = JournalRef.work(work, journalID: "work")
    let host = WorkHostRef(work.workHostID)
    let session = SessionRef("terminal-handle-session")
    let attachment = SessionAttachmentRef("terminal-handle-attachment")
    let run = RunRef("terminal-handle-run")
    let handle = HandleRef("terminal-handle")
    func event(
        _ type: String, _ id: String, _ sequence: Int,
        session: SessionRef? = nil, attachment: SessionAttachmentRef? = nil,
        run: RunRef? = nil, handle: HandleRef? = nil,
        payload: JSONValue = .object([:])
    ) -> TimelineEvent {
        TimelineEvent(
            eventID: id, journal: journal, sequence: sequence,
            hostSequence: sequence, previousEventID: sequence == 1 ? nil : "e\(sequence - 1)",
            session: session, work: work, workHost: host,
            sessionAttachment: attachment, run: run, handle: handle,
            actor: TimelineActor(actorID: "terminal-test", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
            type: type, declaredDomains: [.work], payload: payload)
    }

    let events = [
        event(TimelineEventType.workCreated, "e1", 1),
        event(TimelineEventType.sessionAttached, "e2", 2,
              session: session, attachment: attachment),
        event(TimelineEventType.runStarted, "e3", 3,
              session: session, attachment: attachment, run: run),
        event(TimelineEventType.handleStarted, "e4", 4, run: run, handle: handle,
              payload: .object(["state": .string("running")])),
        event(TimelineEventType.workCompleted, "e5", 5),
        event(TimelineEventType.workDestroyed, "e6", 6),
    ]
    let reduced = WorkReducer.reduce(events)
    XCTAssertFalse(reduced.semanticProjectionValid)
    XCTAssertEqual(reduced.lifecycle, .active)
    XCTAssertEqual(reduced.handles[handle.handleID]?.state, "running")
    XCTAssertEqual(reduced.quarantinedEvents.map(\.type), [
        TimelineEventType.workCompleted, TimelineEventType.workDestroyed
    ])
}
