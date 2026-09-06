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
    XCTAssertEqual(work.commands[start.commandID]?.commandKind, .start)
    XCTAssertEqual(work.commands[start.commandID]?.carriesSessionInput, true)
    XCTAssertEqual(work.commands[steer.commandID]?.state, .notDelivered)
    XCTAssertEqual(work.commands[steer.commandID]?.commandKind, .steer)
    XCTAssertEqual(work.commands[steer.commandID]?.carriesSessionInput, true)
    XCTAssertNil(work.activeRun)
    XCTAssertTrue(work.structuralIntegrityValid && work.semanticProjectionValid)
}

let casesCommandDeliveryOutcome: [Case] = [
    ("phase1 command outcome: queued steer cancellation is terminally not delivered", {
        try await test_nativeQueuedSteerCancellationProducesNotDeliveredOutcome()
    }),
    ("phase1 canonical input delivery: exact join states and bounded pending order", {
        try testCanonicalInputDeliveryJoinStates()
    }),
    ("phase1 canonical input delivery: adversarial identity failures are unavailable", {
        try testCanonicalInputDeliveryAdversarialIdentityFailures()
    }),
]

private struct CanonicalInputDeliveryFixture {
    let work: WorkSnapshot
    let session: SessionSnapshot
    let workJournal: JournalRef
    let sessionJournal: JournalRef
    let run: RunRef
    let client: ClientRef
    let attachment: SessionAttachmentRef

    init(commandStates: [CommandDeliveryState] = [.accepted]) {
        let workRef = WorkRef(workHostID: "delivery-host", workID: "delivery-work")
        let workJournal = JournalRef.work(workRef)
        let sessionRef = SessionRef("delivery-session")
        let sessionJournal = JournalRef.session(
            sessionRef, authority: TimelineAuthorityRef("delivery-authority"))
        let run = RunRef("delivery-run")
        let client = ClientRef("delivery-client")
        let attachment = SessionAttachmentRef("delivery-attachment")
        self.workJournal = workJournal
        self.sessionJournal = sessionJournal
        self.run = run
        self.client = client
        self.attachment = attachment

        var work = WorkSnapshot()
        work.journal = workJournal
        work.work = workRef
        work.workHost = WorkHostRef(workRef.workHostID)
        work.sessionAttachments[attachment.attachmentID] = WorkSessionAttachmentSnapshot(
            attachment: attachment, session: sessionRef)
        var messages: [SessionMessageSnapshot] = []
        for (index, state) in commandStates.enumerated() {
            let commandID = "delivery-command-\(index)"
            let acceptance = EventRef(journal: workJournal, eventID: "accept-\(index)")
            let command = CommandRef(
                commandID: commandID, client: client, sessionAttachment: attachment,
                causalCursor: JournalCursor(journal: workJournal, eventID: "before-\(index)", sequence: index))
            work.commands[commandID] = WorkCommandSnapshot(
                command: command, state: state, actor: TimelineActor(actorID: "host"),
                hostSequence: 20 + index, acceptanceEventRef: acceptance,
                deliveryEventRef: state == .accepted
                    ? nil : EventRef(journal: workJournal, eventID: "delivered-\(index)"),
                deliveryActor: state == .accepted ? nil : TimelineActor(actorID: "runtime"),
                deliveryHostSequence: state == .accepted ? nil : 30 + index,
                commandKind: .send, deliveryMode: .queued, acceptanceRun: run,
                carriesSessionInput: true)
            messages.append(SessionMessageSnapshot(
                eventID: "message-\(index)", role: "user", text: "input \(index)",
                sourceEvent: EventRef(journal: sessionJournal, eventID: "message-\(index)"),
                run: run, actor: TimelineActor(actorID: "client"), client: client,
                sessionAttachment: attachment, causedBy: acceptance))
        }
        work.activeRun = run
        self.work = work
        var session = SessionSnapshot()
        session.journal = sessionJournal
        session.session = sessionRef
        session.messages = messages
        session.messageHistory = messages
        self.session = session
    }
}

private func testCanonicalInputDeliveryJoinStates() throws {
    let fixture = CanonicalInputDeliveryFixture(
        commandStates: [.accepted, .delivered, .notDelivered, .indeterminate])
    let projection = CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: fixture.session)
    XCTAssertTrue(projection.isCanonical)
    XCTAssertEqual(projection.rows.map(\.state), [
        .acceptedWaitingDelivery, .delivered, .notDelivered, .indeterminateUnknownEffect])
    XCTAssertEqual(projection.unresolvedAcceptedCommands.map(\.commandID), ["delivery-command-0"])
    XCTAssertEqual(projection.unresolvedAcceptedCommands.first?.hostSequence, 20)

    // Two independent observers/cold reductions must produce byte-for-byte equal projections.
    let cold = CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: fixture.session)
    XCTAssertEqual(projection, cold)
}

private func testCanonicalInputDeliveryAdversarialIdentityFailures() throws {
    let fixture = CanonicalInputDeliveryFixture()

    var missingCause = fixture.session
    missingCause.messages[0] = SessionMessageSnapshot(
        eventID: "missing", role: "user", text: "x",
        sourceEvent: fixture.sessionJournal == fixture.sessionJournal
            ? EventRef(journal: fixture.sessionJournal, eventID: "missing") : nil,
        run: fixture.run, client: fixture.client, sessionAttachment: fixture.attachment)
    missingCause.messageHistory = missingCause.messages
    let missing = CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: missingCause)
    XCTAssertEqual(missing.rows.first(where: { $0.messageEvent?.eventID == "missing" })?.issue, .missingCause)
    XCTAssertFalse(missing.isCanonical)

    var foreignCause = fixture.session
    foreignCause.messages[0] = SessionMessageSnapshot(
        eventID: "foreign-cause", role: "user", text: "x",
        sourceEvent: EventRef(journal: fixture.sessionJournal, eventID: "foreign-cause"),
        run: fixture.run, client: fixture.client, sessionAttachment: fixture.attachment,
        causedBy: EventRef(journal: fixture.sessionJournal, eventID: "accept-0"))
    foreignCause.messageHistory = foreignCause.messages
    XCTAssertEqual(CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: foreignCause).rows.first(where: {
            $0.messageEvent?.eventID == "foreign-cause"
        })?.issue, .foreignCause)

    var wrongClient = fixture.session
    wrongClient.messages[0] = SessionMessageSnapshot(
        eventID: "wrong-client", role: "user", text: "x",
        sourceEvent: EventRef(journal: fixture.sessionJournal, eventID: "wrong-client"),
        run: fixture.run, client: ClientRef("foreign"), sessionAttachment: fixture.attachment,
        causedBy: fixture.work.commands["delivery-command-0"]?.acceptanceEventRef)
    wrongClient.messageHistory = wrongClient.messages
    XCTAssertEqual(CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: wrongClient).rows.first(where: {
            $0.messageEvent?.eventID == "wrong-client"
        })?.issue, .clientMismatch)

    var wrongRun = fixture.session
    wrongRun.messages[0] = SessionMessageSnapshot(
        eventID: "wrong-run", role: "user", text: "x",
        sourceEvent: EventRef(journal: fixture.sessionJournal, eventID: "wrong-run"),
        run: RunRef("foreign-run"), client: fixture.client, sessionAttachment: fixture.attachment,
        causedBy: fixture.work.commands["delivery-command-0"]?.acceptanceEventRef)
    wrongRun.messageHistory = wrongRun.messages
    XCTAssertEqual(CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: wrongRun).rows.first(where: {
            $0.messageEvent?.eventID == "wrong-run"
        })?.issue, .runMismatch)

    var duplicate = fixture.work
    let first = try XCTUnwrap(duplicate.commands["delivery-command-0"])
    duplicate.commands["duplicate"] = WorkCommandSnapshot(
        command: CommandRef(commandID: "delivery-command-0", client: fixture.client,
                             sessionAttachment: fixture.attachment), state: .accepted,
        actor: TimelineActor(actorID: "host"), hostSequence: 19,
        acceptanceEventRef: first.acceptanceEventRef, commandKind: .send,
        deliveryMode: .queued, acceptanceRun: fixture.run, carriesSessionInput: true)
    XCTAssertEqual(CanonicalInputDeliveryProjection(
        workSnapshot: duplicate, sessionSnapshot: fixture.session).rows.first(where: {
            $0.messageEvent?.eventID == "message-0"
        })?.issue, .duplicateAcceptance)

    var wrongAttachment = fixture.session
    wrongAttachment.messages[0] = SessionMessageSnapshot(
        eventID: "wrong-attachment", role: "user", text: "x",
        sourceEvent: EventRef(journal: fixture.sessionJournal, eventID: "wrong-attachment"),
        run: fixture.run, client: fixture.client,
        sessionAttachment: SessionAttachmentRef("foreign-attachment"),
        causedBy: fixture.work.commands["delivery-command-0"]?.acceptanceEventRef)
    wrongAttachment.messageHistory = wrongAttachment.messages
    XCTAssertEqual(CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: wrongAttachment).rows.first(where: {
            $0.messageEvent?.eventID == "wrong-attachment"
        })?.issue, .sessionAttachmentMismatch)

    // Acceptance is committed before the Session message; retain a metadata-only pending row.
    var noMessage = fixture.session
    noMessage.messages = []
    noMessage.messageHistory = []
    let metadataOnly = CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: noMessage)
    XCTAssertEqual(metadataOnly.unresolvedAcceptedCommands.count, 1)
    XCTAssertNil(metadataOnly.unresolvedAcceptedCommands.first?.messageEvent)
    XCTAssertTrue(metadataOnly.isCanonical)

    var unavailableOrphanWork = fixture.work
    let orphanCommand = try XCTUnwrap(
        unavailableOrphanWork.commands["delivery-command-0"])
    unavailableOrphanWork.commands["delivery-command-0"] = WorkCommandSnapshot(
        command: orphanCommand.command, state: orphanCommand.state,
        acceptanceActor: orphanCommand.acceptanceActor,
        acceptanceHostSequence: orphanCommand.acceptanceHostSequence,
        acceptanceIdempotencyKey: orphanCommand.acceptanceIdempotencyKey,
        acceptanceEventRef: orphanCommand.acceptanceEventRef,
        deliveryEventRef: orphanCommand.deliveryEventRef,
        deliveryActor: orphanCommand.deliveryActor,
        deliveryHostSequence: orphanCommand.deliveryHostSequence,
        deliveryIdempotencyKey: orphanCommand.deliveryIdempotencyKey,
        commandKind: nil, deliveryMode: orphanCommand.deliveryMode,
        acceptanceRun: orphanCommand.acceptanceRun)
    let unavailableOrphan = CanonicalInputDeliveryProjection(
        workSnapshot: unavailableOrphanWork, sessionSnapshot: noMessage)
    XCTAssertEqual(unavailableOrphan.rows.first?.state, .provenanceUnavailable)
    XCTAssertEqual(unavailableOrphan.rows.first?.issue, .commandKindUnavailable)
    XCTAssertNil(unavailableOrphan.rows.first?.messageEvent)

    var missingInputFactWork = fixture.work
    let missingFactCommand = try XCTUnwrap(
        missingInputFactWork.commands["delivery-command-0"])
    missingInputFactWork.commands["delivery-command-0"] = WorkCommandSnapshot(
        command: missingFactCommand.command, state: missingFactCommand.state,
        acceptanceActor: missingFactCommand.acceptanceActor,
        acceptanceHostSequence: missingFactCommand.acceptanceHostSequence,
        acceptanceIdempotencyKey: missingFactCommand.acceptanceIdempotencyKey,
        acceptanceEventRef: missingFactCommand.acceptanceEventRef,
        commandKind: .send, deliveryMode: missingFactCommand.deliveryMode,
        acceptanceRun: missingFactCommand.acceptanceRun, carriesSessionInput: nil)
    let missingInputFact = CanonicalInputDeliveryProjection(
        workSnapshot: missingInputFactWork, sessionSnapshot: noMessage)
    XCTAssertEqual(missingInputFact.rows.first?.state, .provenanceUnavailable)
    XCTAssertEqual(missingInputFact.rows.first?.issue, .inputFactUnavailable)

    var missingAcceptanceWork = fixture.work
    let missingAcceptanceCommand = try XCTUnwrap(
        missingAcceptanceWork.commands["delivery-command-0"])
    missingAcceptanceWork.commands["delivery-command-0"] = WorkCommandSnapshot(
        command: missingAcceptanceCommand.command, state: .accepted,
        actor: missingAcceptanceCommand.acceptanceActor,
        hostSequence: missingAcceptanceCommand.acceptanceHostSequence,
        commandKind: .send, deliveryMode: .queued,
        acceptanceRun: fixture.run, carriesSessionInput: true)
    let missingAcceptanceProjection = CanonicalInputDeliveryProjection(
        workSnapshot: missingAcceptanceWork, sessionSnapshot: noMessage)
    XCTAssertEqual(missingAcceptanceProjection.rows.first?.state, .provenanceUnavailable)
    XCTAssertEqual(missingAcceptanceProjection.rows.first?.issue, .missingAcceptance)

    var noTerminalMessage = CanonicalInputDeliveryFixture(commandStates: [.indeterminate]).session
    noTerminalMessage.messages = []
    noTerminalMessage.messageHistory = []
    let terminalMetadata = CanonicalInputDeliveryProjection(
        workSnapshot: CanonicalInputDeliveryFixture(commandStates: [.indeterminate]).work,
        sessionSnapshot: noTerminalMessage)
    XCTAssertEqual(terminalMetadata.rows.first?.state, .indeterminateUnknownEffect)
    XCTAssertNil(terminalMetadata.rows.first?.messageEvent)

    let incomplete = CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: fixture.session,
        workSourceCompleteness: .incomplete)
    XCTAssertEqual(incomplete.rows.first?.state, .provenanceUnavailable)
    XCTAssertEqual(incomplete.unresolvedAcceptedCommands.count, 0)
    XCTAssertEqual(incomplete.sourceCompleteness, .incomplete)

    var malformedOutcome = fixture.work
    malformedOutcome.commands["delivery-command-0"] = WorkCommandSnapshot(
        command: try XCTUnwrap(malformedOutcome.commands["delivery-command-0"]).command,
        state: .accepted, actor: TimelineActor(actorID: "host"), hostSequence: 20,
        acceptanceEventRef: EventRef(journal: fixture.workJournal, eventID: "accept-0"),
        deliveryEventRef: EventRef(journal: fixture.workJournal, eventID: "unexpected"),
        deliveryActor: TimelineActor(actorID: "runtime"), deliveryHostSequence: 21,
        commandKind: .send, deliveryMode: .queued, acceptanceRun: fixture.run,
        carriesSessionInput: true)
    let malformed = CanonicalInputDeliveryProjection(
        workSnapshot: malformedOutcome, sessionSnapshot: fixture.session)
    XCTAssertEqual(malformed.rows.first(where: { $0.messageEvent?.eventID == "message-0" })?.issue,
                   .deliveryEvidenceUnavailable)

    let bounded = CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: fixture.session,
        maximumUnresolvedCommands: 0)
    XCTAssertEqual(bounded.unresolvedAcceptedCommands.count, 0)
    XCTAssertEqual(bounded.omittedUnresolvedAcceptedCommandCount, 1)
    XCTAssertFalse(bounded.isCanonical)

    // Explicit input facts distinguish an empty Start and lifecycle commands from a nonempty
    // Start. Only the latter may become an orphan Session-input row.
    func extraCommand(_ id: String, _ kind: CanonicalCommandKind, _ carries: Bool, _ offset: Int)
        -> WorkCommandSnapshot {
        WorkCommandSnapshot(
            command: CommandRef(commandID: id, client: fixture.client,
                                 sessionAttachment: fixture.attachment), state: .accepted,
            actor: TimelineActor(actorID: "host"), hostSequence: 100 + offset,
            acceptanceEventRef: EventRef(journal: fixture.workJournal, eventID: "extra-\(id)"),
            commandKind: kind, deliveryMode: .queued, acceptanceRun: fixture.run,
            carriesSessionInput: carries)
    }
    var kinds = fixture.work
    kinds.commands["cancel"] = extraCommand("cancel", .cancel, false, 1)
    kinds.commands["empty-start"] = extraCommand("empty-start", .start, false, 2)
    kinds.commands["input-start"] = extraCommand("input-start", .start, true, 3)
    let kindProjection = CanonicalInputDeliveryProjection(
        workSnapshot: kinds, sessionSnapshot: noMessage)
    XCTAssertEqual(kindProjection.unresolvedAcceptedCommands.map(\.commandID), [
        "delivery-command-0", "input-start"])
    XCTAssertFalse(kindProjection.rows.contains { $0.commandID == "cancel" })
    XCTAssertFalse(kindProjection.rows.contains { $0.commandID == "empty-start" })
    XCTAssertTrue(kindProjection.rows.contains { $0.commandID == "input-start" })

    var unattributed = fixture.work
    unattributed.sessionAttachments.removeValue(forKey: fixture.attachment.attachmentID)
    let unattributedProjection = CanonicalInputDeliveryProjection(
        workSnapshot: unattributed, sessionSnapshot: noMessage)
    XCTAssertTrue(unattributedProjection.rows.isEmpty)
    XCTAssertEqual(unattributedProjection.omittedAttentionCount, 1)
    XCTAssertTrue(unattributedProjection.omissions.contains {
        $0.category == "canonical_input_delivery.unattributed_inputs" && $0.count == 1
    })
    XCTAssertFalse(unattributedProjection.isCanonical)

    // Historical joins remain valid after a later detach; the attachment identity is not
    // rewritten into the current `isAttached` bit.
    var detached = fixture.work
    detached.sessionAttachments[fixture.attachment.attachmentID]?.isAttached = false
    let detachedProjection = CanonicalInputDeliveryProjection(
        workSnapshot: detached, sessionSnapshot: fixture.session)
    XCTAssertEqual(detachedProjection.rows.first?.state, .acceptedWaitingDelivery)
    XCTAssertTrue(detachedProjection.isCanonical)

    // Indeterminate and unproven rows outrank old resolved history under the hard row bound.
    let priorityFixture = CanonicalInputDeliveryFixture(
        commandStates: [.accepted, .indeterminate, .delivered])
    let priority = CanonicalInputDeliveryProjection(
        workSnapshot: priorityFixture.work, sessionSnapshot: priorityFixture.session,
        maximumRows: 2)
    XCTAssertTrue(priority.rows.contains { $0.state == .acceptedWaitingDelivery })
    XCTAssertTrue(priority.rows.contains { $0.state == .indeterminateUnknownEffect })
    XCTAssertFalse(priority.rows.contains { $0.state == .delivered })
    XCTAssertEqual(priority.omittedAttentionCount, 0)

    let attentionOverflow = CanonicalInputDeliveryProjection(
        workSnapshot: priorityFixture.work, sessionSnapshot: priorityFixture.session,
        maximumRows: 1)
    XCTAssertTrue(attentionOverflow.rows.contains { $0.state == .acceptedWaitingDelivery })
    XCTAssertEqual(attentionOverflow.omittedAttentionCount, 1)
    XCTAssertTrue(attentionOverflow.omissions.contains {
        $0.category == "canonical_input_delivery.attention" && $0.count == 1
    })

    // Locally derived attention must survive even when a remote source already fills the
    // bounded omission list with lexically earlier categories.
    let crowdedAttention = CanonicalInputDeliveryProjection(
        workSnapshot: priorityFixture.work, sessionSnapshot: priorityFixture.session,
        workOmissions: (0..<64).map {
            WorkServiceOmission(category: String(format: "aaa.remote.%03d", $0), count: 1)
        }, maximumRows: 1)
    XCTAssertEqual(crowdedAttention.omissions.count, 64)
    XCTAssertTrue(crowdedAttention.omissions.contains {
        $0.category == "canonical_input_delivery.attention" && $0.count == 1
    })
    XCTAssertFalse(crowdedAttention.omissions.contains { $0.category == "aaa.remote.063" })

    let metadataOutcomeFixture = CanonicalInputDeliveryFixture(
        commandStates: [.notDelivered, .delivered])
    var noOutcomeMessages = metadataOutcomeFixture.session
    noOutcomeMessages.messages = []
    noOutcomeMessages.messageHistory = []
    let metadataOutcome = CanonicalInputDeliveryProjection(
        workSnapshot: metadataOutcomeFixture.work,
        sessionSnapshot: noOutcomeMessages, maximumRows: 1)
    XCTAssertEqual(metadataOutcome.rows.first?.state, .notDelivered)
    XCTAssertEqual(metadataOutcome.rows.first?.messageEvent, nil)
    XCTAssertEqual(metadataOutcome.omittedAttentionCount, 0)

    let saturated = CanonicalInputDeliveryProjection(
        workSnapshot: fixture.work, sessionSnapshot: fixture.session,
        workOmissions: [
            WorkServiceOmission(category: "overflow", count: Int.max),
            WorkServiceOmission(category: "overflow", count: Int.max),
        ])
    XCTAssertEqual(saturated.omissions.first(where: { $0.category == "overflow" })?.count,
                   CanonicalInputDeliveryProjection.maximumOmissionCount)

    let oversizedOmission = Data(
        "{\"category\":\"remote\",\"count\":1000001}".utf8)
    do {
        _ = try JSONDecoder().decode(WorkServiceOmission.self, from: oversizedOmission)
        XCTFail("decoded an omission count above the Work service protocol bound")
    } catch {
        XCTAssertTrue(true)
    }
}
