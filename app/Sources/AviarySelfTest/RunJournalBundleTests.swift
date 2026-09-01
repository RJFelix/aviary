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
    let command1 = CommandRef(commandID: "command-1", client: client)
    do {
        _ = try await bundle.startTurn(TurnRef(""))
        XCTFail("empty TurnRef must be rejected before bytes")
    } catch { }
    _ = try await bundle.startTurn(TurnRef("turn-1"))
    do {
        _ = try await bundle.commitInput(
            text: "foreign", deliveryMode: .queued,
            command: CommandRef(commandID: "foreign", sessionAttachment: SessionAttachmentRef("other")))
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
    XCTAssertEqual(second.count, 3)
    _ = try await bundle.commitAssistantMessage("answer-2")
    _ = try await bundle.finishTurn(TurnRef("turn-2"))

    let events = try bundleEvents(home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    let reduced = SessionReducer.reduce(events)
    XCTAssertTrue(reduced.structuralIntegrityValid && reduced.semanticProjectionValid)
    XCTAssertEqual(reduced.messages.map(\.text), ["first", "answer-1", "second", "answer-2"])
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
    let command = CommandRef(commandID: "queued-command", client: ClientRef("queued-client"))
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
    let command = CommandRef(commandID: "end-command", client: ClientRef("gui"))
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
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionIntent }.count, ActionKind.allCases.count)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionStarted }.count, ActionKind.allCases.count)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionOutcome }.count, ActionKind.allCases.count)
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

func test_runJournalBundleSemanticGateSerializesConcurrentMutations() async throws {
    let home = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let bundle = try await makeBundle(home: home)

    let inputResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<2 {
            group.addTask {
                do {
                    _ = try await bundle.commitInput(
                        text: "same", deliveryMode: .queued,
                        command: CommandRef(commandID: "concurrent-command"))
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
        command: CommandRef(commandID: "deliver-later"))
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

func test_runJournalBundlePartialPrefixesLatchAndRefusePermits() async throws {
    let firstHome = try bundleTestHome()
    defer { try? FileManager.default.removeItem(at: firstHome.root) }
    let first = try await makeBundle(home: firstHome)
    await first.injectWriterFailure(.beforeWrite, in: .work)
    do {
        _ = try await first.commitInput(
            text: "lost", deliveryMode: .delivered,
            command: CommandRef(commandID: "first-failure"))
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
            command: CommandRef(commandID: "second-failure"))
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
    let permit = try await bundle.beginAction(kind: .provider, intent: "call provider")
    do {
        _ = try await bundle.finishAction(permit, state: .failed, retrySafety: .unknown)
        XCTFail("failed action must carry failure kind")
    } catch { }
    _ = try await bundle.finishAction(
        permit, state: .failed, retrySafety: .unknown, failureKind: .task)
    let retry = try await bundle.beginAction(kind: .provider, intent: "retry safely")
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
    XCTAssertEqual(finishCommits.map(\.cursor.journal), [bundle.workJournal, bundle.sessionJournal])
    let finishedSessionEvents = try bundleEvents(
        home, bundle.sessionJournal, home.timelineV2SessionJournalURL(bundleTestSession))
    let finishedWorkEvents = try bundleEvents(
        home, bundle.workJournal, home.timelineV2WorkJournalURL(bundleTestWork))
    XCTAssertEqual(finishedSessionEvents.last?.type, TimelineEventType.sessionAttachmentCursorAdvanced)
    XCTAssertEqual(finishedSessionEvents.last?.payload["cursor"]?["sequence"]?.intValue,
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
        text: "root", deliveryMode: .delivered, command: CommandRef(commandID: "root-command"))
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
        XCTAssertEqual(prefix.sessionEventCount, 3)
        XCTAssertEqual(prefix.workEventCount, 4)
    }
    let reopened = try await RunJournalBundle.reopen(
        home: home, session: bundleTestSession, work: bundleTestWork, workHost: bundleTestHost,
        sessionAuthority: bundleTestAuthority, sessionAttachment: bundleTestAttachment,
        run: RunRef("run-after-close"), actor: bundleTestActor)
    try await reopened.closeChecked()
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
