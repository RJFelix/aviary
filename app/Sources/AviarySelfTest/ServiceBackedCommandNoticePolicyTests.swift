import Foundation
@testable import AviaryCore

private let noticePolicyWork = WorkRef(workHostID: "notice-host", workID: "notice-work")
private let noticePolicyClient = ClientRef("notice-client")
private let noticePolicyAttachment = ClientAttachmentRef("notice-client-attachment")
private let noticePolicySession = SessionRef("notice-session")
private let noticePolicySessionAttachment = SessionAttachmentRef("notice-session-attachment")
private let noticePolicyJournal = JournalRef.work(noticePolicyWork)
private let noticePolicySessionJournal = JournalRef.session(
    noticePolicySession, journalID: "notice-session-journal",
    authority: TimelineAuthorityRef(noticePolicyWork.workHostID))
private let noticePolicyCommandID = "notice-command"

private func noticePolicyProjection(
    commandID: String = noticePolicyCommandID,
    commandClient: ClientRef = noticePolicyClient,
    commandKind: CanonicalCommandKind? = .send,
    commandState: CommandDeliveryState = .accepted,
    pending: WorkServiceAttachedWorkPendingCommand? = nil,
    canonical: Bool = true,
    connectivity: WorkServiceAttachedWorkConnectivity = .connected(nil),
    lastReceiptCommandID: String = noticePolicyCommandID,
    lastReceiptOutcome: WorkServiceCommandOutcome? = .inputAccepted,
    receiptEventID: String = "accepted-event",
    receiptSequence: Int = 2,
    acceptanceEventID: String? = "accepted-event",
    acceptanceJournal: JournalRef = noticePolicyJournal,
    acceptanceEventSequence: Int = 2,
    acceptanceHostSequence: Int = 2,
    workCursorEventID: String = "accepted-event",
    workCursorSequence: Int = 2,
    readDiagnostics: [String] = [],
    requiresRefresh: Bool? = nil,
    execution: WorkServiceExecutionState = .idle,
    currentRun: RunRef? = nil,
    reducedExecution: WorkExecution? = nil,
    commandAcceptanceRun: RunRef? = nil,
    hostInstanceID: String = "notice-instance",
    hostStartIdentity: String = "notice-start"
) throws -> WorkServiceAttachedWorkProjection {
    let workCursor = JournalCursor(
        journal: noticePolicyJournal, eventID: workCursorEventID,
        sequence: workCursorSequence)
    let causalCursor = JournalCursor(journal: noticePolicyJournal, eventID: "before-event", sequence: 1)
    let sessionCursor = JournalCursor(
        journal: noticePolicySessionJournal, eventID: "session-event", sequence: 1)
    let authorization = WorkServiceAuthorizationOutcome(
        requested: Set(WorkServiceCapability.allCases),
        granted: Set(WorkServiceCapability.allCases), denied: [])
    let attachment = WorkServiceClientAttachment(
        attachment: noticePolicyAttachment, client: noticePolicyClient,
        session: noticePolicySession, sessionJournal: noticePolicySessionJournal,
        sessionAttachment: noticePolicySessionAttachment, authorization: authorization)
    let relationship = WorkServiceSessionAttachmentDescriptor(
        session: noticePolicySession, sessionJournal: noticePolicySessionJournal,
        sessionAttachment: noticePolicySessionAttachment, publication: .mirrored,
        causalSessionCursor: sessionCursor, sessionCursor: sessionCursor,
        causalWorkCursor: workCursor, resultingWorkCursor: workCursor,
        capabilities: [.observe, .control])
    let hostInstance = WorkHostInstanceRef(
        host: WorkHostRef(noticePolicyWork.workHostID), instanceID: hostInstanceID,
        startIdentity: hostStartIdentity)
    let observation = try WorkServiceHostObservation(
        instance: hostInstance, reachability: .observedReachable,
        currentRun: currentRun,
        currentRunSession: currentRun == nil ? nil : noticePolicySession,
        currentRunSessionAttachment: currentRun == nil ? nil : noticePolicySessionAttachment,
        servedCursor: workCursor, sourceCompleteness: canonical ? .complete : .incomplete)
    let descriptor = try WorkServiceWorkDescriptor(
        work: noticePolicyWork, journal: noticePolicyJournal, recordedDisposition: .reusable,
        execution: execution, currentRun: currentRun,
        currentRunSession: currentRun == nil ? nil : noticePolicySession,
        currentRunSessionAttachment: currentRun == nil ? nil : noticePolicySessionAttachment,
        hostObservation: observation,
        attachments: [attachment], sessionAttachments: [relationship])

    var workSnapshot = WorkSnapshot()
    workSnapshot.journal = noticePolicyJournal
    workSnapshot.work = noticePolicyWork
    workSnapshot.workHost = WorkHostRef(noticePolicyWork.workHostID)
    workSnapshot.lifecycle = .active
    workSnapshot.execution = reducedExecution ?? (currentRun == nil ? .idle : .running)
    workSnapshot.activeRun = currentRun
    workSnapshot.activeRunSession = currentRun == nil ? nil : noticePolicySession
    workSnapshot.activeRunSessionAttachment = currentRun == nil
        ? nil : noticePolicySessionAttachment
    workSnapshot.sessionAttachments[noticePolicySessionAttachment.attachmentID] =
        WorkSessionAttachmentSnapshot(
            attachment: noticePolicySessionAttachment, session: noticePolicySession)
    if let acceptanceEventID {
        workSnapshot.eventSequences[acceptanceEventID] = acceptanceEventSequence
    }
    let canonicalID = WorkServiceCommandLedgerIdentity.commandID(
        client: commandClient, commandID: commandID)
    workSnapshot.commands[canonicalID] = WorkCommandSnapshot(
        command: CommandRef(
            commandID: canonicalID, client: commandClient,
            sessionAttachment: noticePolicySessionAttachment, causalCursor: causalCursor),
        state: commandState, actor: TimelineActor(actorID: "notice-host", kind: "host"),
        hostSequence: acceptanceHostSequence,
        acceptanceEventRef: acceptanceEventID.map {
            EventRef(journal: acceptanceJournal, eventID: $0)
        },
        commandKind: commandKind, acceptanceRun: commandAcceptanceRun)

    var sessionSnapshot = SessionSnapshot()
    sessionSnapshot.journal = noticePolicySessionJournal
    sessionSnapshot.session = noticePolicySession
    sessionSnapshot.lifecycle = .active
    let receipt = WorkServiceCommandReceipt(
        work: noticePolicyWork, commandID: lastReceiptCommandID, state: .accepted,
        host: hostInstance, hostSequence: 2,
        causalWorkCursor: causalCursor,
        resultingWorkCursor: JournalCursor(
            journal: noticePolicyJournal, eventID: receiptEventID, sequence: receiptSequence),
        authorization: authorization, outcome: lastReceiptOutcome)
    return WorkServiceAttachedWorkProjection(
        descriptor: descriptor, attachment: attachment,
        capabilities: Set(WorkServiceCapability.allCases), workSnapshot: workSnapshot,
        sessionSnapshot: sessionSnapshot, workCursor: workCursor, sessionCursor: sessionCursor,
        workSourceCompleteness: canonical ? .complete : .incomplete,
        sessionSourceCompleteness: .complete, readDiagnostics: readDiagnostics, connectivity: connectivity,
        pendingCommand: pending, lastReceipt: receipt,
        requiresRefresh: requiresRefresh ?? !canonical)
}

private func noticePolicyNotice(
    commandID: String = noticePolicyCommandID,
    kind: WorkServiceCommandKind = .send,
    client: ClientRef = noticePolicyClient,
    evidence: ServiceBackedCommandNotice.Evidence = .acceptedReceipt(
        resultingWorkCursor: JournalCursor(
            journal: noticePolicyJournal, eventID: "accepted-event", sequence: 2))
) -> ServiceBackedCommandNotice {
    ServiceBackedCommandNotice(
        work: noticePolicyWork, commandID: commandID, kind: kind, client: client,
        attachment: noticePolicyAttachment, sessionAttachment: noticePolicySessionAttachment,
        evidence: evidence)
}

/// Reduce the same command-kind labels written by NativeSessionCommandJournal instead of
/// constructing a typed WorkCommandSnapshot directly. This catches producer vocabulary which
/// otherwise decodes to an unavailable command kind before notice policy sees it.
private func noticePolicyReducedCommandKind(_ rawValue: String) throws -> CanonicalCommandKind? {
    let commandID = WorkServiceCommandLedgerIdentity.commandID(
        client: noticePolicyClient, commandID: noticePolicyCommandID)
    let before = EventRef(journal: noticePolicyJournal, eventID: "attached-event")
    let command = CommandRef(
        commandID: commandID, client: noticePolicyClient,
        sessionAttachment: noticePolicySessionAttachment,
        causalCursor: JournalCursor(
            journal: noticePolicyJournal, eventID: before.eventID, sequence: 2))
    let events = [
        TimelineEvent(
            eventID: "created-event", journal: noticePolicyJournal, sequence: 1,
            work: noticePolicyWork, workHost: WorkHostRef(noticePolicyWork.workHostID),
            actor: TimelineActor(actorID: "notice-host", kind: "work-host"),
            hostRecordedAt: Date(timeIntervalSince1970: 1),
            type: TimelineEventType.workCreated),
        TimelineEvent(
            eventID: before.eventID, journal: noticePolicyJournal, sequence: 2,
            previousEventID: "created-event", session: noticePolicySession,
            work: noticePolicyWork, workHost: WorkHostRef(noticePolicyWork.workHostID),
            sessionAttachment: noticePolicySessionAttachment,
            actor: TimelineActor(actorID: "notice-host", kind: "work-host"),
            hostRecordedAt: Date(timeIntervalSince1970: 2),
            type: TimelineEventType.sessionAttached),
        TimelineEvent(
            eventID: "accepted-event", journal: noticePolicyJournal, sequence: 3,
            hostSequence: 3, idempotencyKey: commandID, command: command,
            previousEventID: before.eventID, causedByEventID: before,
            session: noticePolicySession, work: noticePolicyWork,
            workHost: WorkHostRef(noticePolicyWork.workHostID), client: noticePolicyClient,
            sessionAttachment: noticePolicySessionAttachment,
            actor: TimelineActor(actorID: "notice-host", kind: "work-host"),
            hostRecordedAt: Date(timeIntervalSince1970: 3),
            type: TimelineEventType.commandAccepted,
            payload: .object([
                "command_kind": .string(rawValue),
                "delivery_mode": .string(RunInputDeliveryMode.queued.rawValue),
                "carries_session_input": .bool(false),
            ])),
    ]
    let snapshot = WorkReducer.reduce(events)
    return try XCTUnwrap(snapshot.commands[commandID]).commandKind
}

func testServiceBackedCommandNoticePolicyRetainsReceiptUntilCanonicalCatchUp() throws {
    let causal = JournalCursor(journal: noticePolicyJournal, eventID: "before-event", sequence: 1)
    let pending = WorkServiceAttachedWorkPendingCommand(
        state: .awaitingCanonicalEvidence, kind: .send, commandID: noticePolicyCommandID,
        client: noticePolicyClient, attachment: noticePolicyAttachment,
        sessionAttachment: noticePolicySessionAttachment, causalWorkCursor: causal,
        expectedResultingWorkCursor: JournalCursor(
            journal: noticePolicyJournal, eventID: "accepted-event", sequence: 2),
        expectedHostSequence: 2, valueDigest: nil)
    let projection = try noticePolicyProjection(pending: pending, canonical: false)
    XCTAssertEqual(
        ServiceBackedCommandNoticePolicy.disposition(
            for: noticePolicyNotice(), projection: projection), .retain)
}

func testServiceBackedCommandNoticePolicyClearsExactCanonicalAcknowledgement() throws {
    let projection = try noticePolicyProjection()
    XCTAssertTrue(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: projection))
}

func testServiceBackedCommandNoticePolicyDoesNotInferProviderCompletion() throws {
    // Canonical acceptance is sufficient to retire the transport catch-up copy. This does not
    // claim runtime/provider delivery; the policy has no provider completion input at all.
    let accepted = try noticePolicyProjection(commandState: .accepted)
    let delivered = try noticePolicyProjection(commandState: .delivered)
    XCTAssertTrue(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: accepted))
    XCTAssertTrue(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: delivered))
}

func testServiceBackedCommandNoticePolicyRetainsIncompleteOrForeignEvidence() throws {
    let incomplete = try noticePolicyProjection(canonical: false)
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: incomplete))

    let foreign = try noticePolicyProjection(commandID: "foreign-command", commandClient: ClientRef("foreign-client"))
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: foreign))

    let rejected = try noticePolicyProjection(commandState: .rejected)
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: rejected))
}

func testServiceBackedCommandNoticePolicyRejectsIdentityAndCursorDrift() throws {
    let wrongKind = try noticePolicyProjection(commandKind: .start)
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: wrongKind))

    let wrongSessionAttachment = try noticePolicyProjection()
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(
            ServiceBackedCommandNotice(
                work: noticePolicyWork, commandID: noticePolicyCommandID, kind: .send,
                client: noticePolicyClient, attachment: noticePolicyAttachment,
                sessionAttachment: SessionAttachmentRef("foreign-session-attachment"),
                evidence: .acceptedReceipt(resultingWorkCursor: JournalCursor(
                    journal: noticePolicyJournal, eventID: "accepted-event", sequence: 2))),
            from: wrongSessionAttachment))

    let wrongWorkNotice = ServiceBackedCommandNotice(
        work: WorkRef(workHostID: "notice-host", workID: "foreign-work"),
        commandID: noticePolicyCommandID, kind: .send, client: noticePolicyClient,
        attachment: noticePolicyAttachment, sessionAttachment: noticePolicySessionAttachment,
        evidence: .acceptedReceipt(resultingWorkCursor: JournalCursor(
            journal: noticePolicyJournal, eventID: "accepted-event", sequence: 2)))
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(wrongWorkNotice, from: wrongSessionAttachment))

    let wrongCursor = try noticePolicyProjection()
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(
            noticePolicyNotice(evidence: .acceptedReceipt(resultingWorkCursor: JournalCursor(
                journal: noticePolicyJournal, eventID: "later-event", sequence: 3))),
            from: wrongCursor))

    let wrongEvent = try noticePolicyProjection()
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(
            noticePolicyNotice(evidence: .acceptedReceipt(resultingWorkCursor: JournalCursor(
                journal: noticePolicyJournal, eventID: "foreign-event", sequence: 2))),
            from: wrongEvent))

    let wrongSequence = try noticePolicyProjection()
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(
            noticePolicyNotice(evidence: .acceptedReceipt(resultingWorkCursor: JournalCursor(
                journal: noticePolicyJournal, eventID: "accepted-event", sequence: 1))),
            from: wrongSequence))
}

func testServiceBackedCommandNoticePolicyUsesImmutableReceiptCorrelation() throws {
    let projection = try noticePolicyProjection(
        lastReceiptCommandID: "later-command", lastReceiptOutcome: .inputAccepted,
        acceptanceEventSequence: 57, acceptanceHostSequence: 92,
        workCursorEventID: "later-tip", workCursorSequence: 79)
    XCTAssertTrue(
        ServiceBackedCommandNoticePolicy.shouldClear(
            noticePolicyNotice(evidence: .acceptedReceipt(resultingWorkCursor: JournalCursor(
                journal: noticePolicyJournal, eventID: "accepted-event", sequence: 57))),
            from: projection))
}

func testServiceBackedCommandNoticePolicyUsesCanonicalEvidenceAcrossConnectivity() throws {
    let states: [WorkServiceAttachedWorkConnectivity] = [
        .disconnected,
        .discovering,
        .connecting(WorkHostRef(noticePolicyWork.workHostID)),
        .reconnecting(WorkHostRef(noticePolicyWork.workHostID)),
        .unavailable(WorkHostRef(noticePolicyWork.workHostID)),
        .incompatible(WorkHostRef(noticePolicyWork.workHostID)),
    ]
    for connectivity in states {
        let projection = try noticePolicyProjection(connectivity: connectivity)
        XCTAssertTrue(
            ServiceBackedCommandNoticePolicy.shouldClear(
                noticePolicyNotice(), from: projection),
            "canonical command evidence is sufficient despite (connectivity)")
    }

    // A failed controller refresh marks its retained snapshots incomplete. A stale cached
    // canonical pair must not retire a success notice merely because connectivity changed.
    let failedRefresh = try noticePolicyProjection(canonical: false, connectivity: .unavailable(nil))
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(noticePolicyNotice(), from: failedRefresh))
}

func testServiceBackedCommandNoticePolicySettlesLostEndConfirmationExactly() throws {
    let notice = noticePolicyNotice(kind: .end, evidence: .canonicalCommand)
    for state in [CommandDeliveryState.accepted, .delivered] {
        let projection = try noticePolicyProjection(
            commandKind: .end, commandState: state,
            lastReceiptCommandID: "unrelated-receipt",
            lastReceiptOutcome: .inputAccepted)
        XCTAssertTrue(
            ServiceBackedCommandNoticePolicy.shouldClear(notice, from: projection),
            "exact canonical \(state.rawValue) must settle a lost End response")
    }

    let laterPending = WorkServiceAttachedWorkPendingCommand(
        state: .indeterminate, kind: .send, commandID: "later-pending-command",
        client: noticePolicyClient, attachment: noticePolicyAttachment,
        sessionAttachment: noticePolicySessionAttachment,
        causalWorkCursor: JournalCursor(
            journal: noticePolicyJournal, eventID: "accepted-event", sequence: 2),
        valueDigest: nil)
    let crossedBeforeLaterPending = try noticePolicyProjection(
        commandKind: .end, pending: laterPending)
    XCTAssertTrue(ServiceBackedCommandNoticePolicy.hasExactCanonicalCommandEvidence(
        for: notice, in: crossedBeforeLaterPending))
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(
        notice, from: crossedBeforeLaterPending))

    let incomplete = try noticePolicyProjection(commandKind: .end, canonical: false)
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(notice, from: incomplete))
    let foreign = try noticePolicyProjection(commandID: "foreign-end", commandKind: .end)
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(notice, from: foreign))
    let wrongKind = try noticePolicyProjection(commandKind: .send)
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(notice, from: wrongKind))

    let missingProvenance = try noticePolicyProjection(
        commandKind: .end, acceptanceEventID: nil)
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(notice, from: missingProvenance))
    let foreignJournal = try noticePolicyProjection(
        commandKind: .end, acceptanceJournal: noticePolicySessionJournal)
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(notice, from: foreignJournal))
    let futureAcceptance = try noticePolicyProjection(
        commandKind: .end, acceptanceEventSequence: 3)
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(notice, from: futureAcceptance))
    let invalidZeroSequence = try noticePolicyProjection(
        commandKind: .end, acceptanceHostSequence: 0)
    XCTAssertFalse(
        ServiceBackedCommandNoticePolicy.shouldClear(notice, from: invalidZeroSequence))
    let mismatchedTip = try noticePolicyProjection(
        commandKind: .end, acceptanceEventID: "other-event")
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(notice, from: mismatchedTip))
    for state in [CommandDeliveryState.rejected, .notDelivered, .indeterminate] {
        let unsettled = try noticePolicyProjection(commandKind: .end, commandState: state)
        XCTAssertFalse(
            ServiceBackedCommandNoticePolicy.shouldClear(notice, from: unsettled),
            "canonical \(state.rawValue) must not settle uncertain End presentation")
    }
}

func testServiceBackedCommandNoticePolicyMatchesNativeLifecycleAliases() throws {
    let nativeEnd = try noticePolicyReducedCommandKind("end_run")
    XCTAssertEqual(nativeEnd, .endRun)
    let endProjection = try noticePolicyProjection(commandKind: nativeEnd)
    XCTAssertTrue(ServiceBackedCommandNoticePolicy.shouldClear(
        noticePolicyNotice(kind: .end), from: endProjection))

    let nativeQueue = try noticePolicyReducedCommandKind("queue_follow_up")
    XCTAssertEqual(nativeQueue, .queueFollowUp)
    let queueProjection = try noticePolicyProjection(commandKind: nativeQueue)
    XCTAssertTrue(ServiceBackedCommandNoticePolicy.shouldClear(
        noticePolicyNotice(kind: .queue), from: queueProjection))

    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(
        noticePolicyNotice(kind: .end), from: queueProjection))
    XCTAssertFalse(ServiceBackedCommandNoticePolicy.shouldClear(
        noticePolicyNotice(kind: .queue), from: endProjection))
}

private func startGraceProjection(
    run: RunRef = RunRef("start-grace-run"),
    execution: WorkServiceExecutionState = .recoveryRequired,
    reducedExecution: WorkExecution = .running,
    pending: WorkServiceAttachedWorkPendingCommand? = nil,
    commandAcceptanceRun: RunRef? = nil,
    acceptanceHostSequence: Int = 2,
    hostInstanceID: String = "notice-instance",
    workCursorEventID: String = "accepted-event",
    workCursorSequence: Int = 2
) throws -> WorkServiceAttachedWorkProjection {
    try noticePolicyProjection(
        commandKind: .start, pending: pending,
        lastReceiptOutcome: .started,
        acceptanceHostSequence: acceptanceHostSequence,
        workCursorEventID: workCursorEventID,
        workCursorSequence: workCursorSequence,
        execution: execution, currentRun: run,
        reducedExecution: reducedExecution,
        commandAcceptanceRun: commandAcceptanceRun ?? run,
        hostInstanceID: hostInstanceID)
}

func testServiceBackedStartPresentationGraceBindsOneExactRun() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let projection = try startGraceProjection()
    var grace = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: try XCTUnwrap(projection.lastReceipt),
        attachment: projection.attachment, now: now))
    XCTAssertEqual(
        grace.reconcile(projection: projection, now: now), .presentPreparing)
    XCTAssertTrue(grace.presentsPreparing(projection: projection, now: now))

    let otherRun = try startGraceProjection(
        run: RunRef("other-start-grace-run"),
        commandAcceptanceRun: RunRef("start-grace-run"))
    XCTAssertEqual(grace.reconcile(projection: otherRun, now: now), .clear)

    var foreignFirstGrace = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: try XCTUnwrap(projection.lastReceipt),
        attachment: projection.attachment, now: now))
    XCTAssertEqual(
        foreignFirstGrace.reconcile(projection: otherRun, now: now), .clear,
        "the first reconciliation must not bind a later Run than the accepted Start")

    var sequenceGrace = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: try XCTUnwrap(projection.lastReceipt),
        attachment: projection.attachment, now: now))
    XCTAssertEqual(
        sequenceGrace.reconcile(
            projection: try startGraceProjection(acceptanceHostSequence: 3), now: now),
        .clear)

    var hostGrace = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: try XCTUnwrap(projection.lastReceipt),
        attachment: projection.attachment, now: now))
    XCTAssertEqual(
        hostGrace.reconcile(projection: projection, now: now), .presentPreparing)
    let otherHost = try startGraceProjection(hostInstanceID: "other-instance")
    XCTAssertEqual(hostGrace.reconcile(projection: otherHost, now: now), .clear)
}

func testServiceBackedStartPresentationGraceWaitsThenExpiresOrClears() throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let projection = try startGraceProjection()
    let receipt = try XCTUnwrap(projection.lastReceipt)

    var catchingUp = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: receipt, attachment: projection.attachment, now: now, duration: 2))
    let older = try startGraceProjection(
        workCursorEventID: "before-event", workCursorSequence: 1)
    XCTAssertEqual(
        catchingUp.reconcile(projection: older, now: now), .awaitingCanonicalEvidence)
    XCTAssertEqual(
        catchingUp.reconcile(
            projection: projection, now: now.addingTimeInterval(2)), .clear)

    var healthy = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: receipt, attachment: projection.attachment, now: now))
    XCTAssertEqual(healthy.reconcile(projection: projection, now: now), .presentPreparing)
    XCTAssertEqual(
        healthy.reconcile(
            projection: try startGraceProjection(execution: .running), now: now), .clear)

    var failed = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: receipt, attachment: projection.attachment, now: now))
    XCTAssertEqual(
        failed.reconcile(
            projection: try startGraceProjection(reducedExecution: .failed), now: now), .clear)
}

func testServiceBackedStartPresentationGraceRejectsRecoveryAndPendingReceipts() throws {
    let now = Date(timeIntervalSince1970: 30_000)
    let acceptedProjection = try startGraceProjection()
    let accepted = try XCTUnwrap(acceptedProjection.lastReceipt)
    let duplicate = WorkServiceCommandReceipt(
        work: accepted.work, commandID: accepted.commandID, state: .duplicate,
        host: accepted.host, hostSequence: accepted.hostSequence,
        hostProvenance: accepted.hostProvenance,
        causalWorkCursor: accepted.causalWorkCursor,
        resultingWorkCursor: accepted.resultingWorkCursor,
        authorization: accepted.authorization, outcome: accepted.outcome)
    XCTAssertNil(ServiceBackedStartPresentationGrace(
        receipt: duplicate, attachment: acceptedProjection.attachment, now: now))

    let recovery = try noticePolicyProjection(
        commandKind: .start, lastReceiptOutcome: .startRecoveryRequired,
        execution: .recoveryRequired, currentRun: RunRef("start-grace-run"))
    XCTAssertNil(ServiceBackedStartPresentationGrace(
        receipt: try XCTUnwrap(recovery.lastReceipt),
        attachment: recovery.attachment, now: now))

    let causal = JournalCursor(
        journal: noticePolicyJournal, eventID: "before-event", sequence: 1)
    let pending = WorkServiceAttachedWorkPendingCommand(
        state: .indeterminate, kind: .start, commandID: noticePolicyCommandID,
        client: noticePolicyClient, attachment: noticePolicyAttachment,
        sessionAttachment: noticePolicySessionAttachment,
        causalWorkCursor: causal, valueDigest: nil)
    let projection = acceptedProjection
    var grace = try XCTUnwrap(ServiceBackedStartPresentationGrace(
        receipt: try XCTUnwrap(projection.lastReceipt),
        attachment: projection.attachment, now: now))
    XCTAssertEqual(
        grace.reconcile(
            projection: try startGraceProjection(pending: pending), now: now), .clear)
}

let casesServiceBackedCommandNoticePolicy: [Case] = [
    ("service command notice: accepted message refresh has a real noncanonical progress state", {
        let catchingUp = try noticePolicyProjection(requiresRefresh: true)
        XCTAssertFalse(catchingUp.isCanonical)
        XCTAssertFalse(catchingUp.needsRecovery)
        let notice = noticePolicyNotice()
        func shows(_ projection: WorkServiceAttachedWorkProjection,
                   _ candidate: ServiceBackedCommandNotice = noticePolicyNotice(),
                   error: Bool = false) -> Bool {
            ChatAcceptedMessageRefreshPolicy.shouldShow(
                notice: candidate, noticeWasSuccessful: true, projection: projection,
                hasErrorBanner: error)
        }
        XCTAssertTrue(shows(catchingUp, notice))
        XCTAssertFalse(shows(try noticePolicyProjection()))
        XCTAssertFalse(shows(try noticePolicyProjection(canonical: false)))
        XCTAssertFalse(shows(try noticePolicyProjection(connectivity: .disconnected, requiresRefresh: true)))
        XCTAssertFalse(shows(catchingUp, error: true))
        XCTAssertFalse(shows(catchingUp, noticePolicyNotice(client: ClientRef("other-client"))))
        XCTAssertFalse(shows(catchingUp, noticePolicyNotice(commandID: "other-command")))
        XCTAssertFalse(shows(catchingUp, noticePolicyNotice(evidence: .canonicalCommand)))
        XCTAssertFalse(shows(catchingUp, noticePolicyNotice(kind: .end)))
    }),
    ("service command notice: recovered read diagnostics no longer block input", {
        let history = ["earlier connection failed"]
        let failed = try noticePolicyProjection(canonical: false, readDiagnostics: history)
        XCTAssertEqual(ServiceBackedGUIControlPolicy.blockingReadDiagnostic(in: failed), history.last)
        XCTAssertFalse(ServiceBackedGUIControlPolicy(projection: failed).canSubmitText)
        let recovered = try noticePolicyProjection(readDiagnostics: history)
        XCTAssertNil(ServiceBackedGUIControlPolicy.blockingReadDiagnostic(in: recovered))
        XCTAssertTrue(ServiceBackedGUIControlPolicy(projection: recovered).canSubmitText)
        XCTAssertEqual(recovered.readDiagnostics, history)
    }),
    ("service command notice retains receipt until canonical catch-up", {
        try testServiceBackedCommandNoticePolicyRetainsReceiptUntilCanonicalCatchUp()
    }),
    ("service command notice clears exact canonical acknowledgement", {
        try testServiceBackedCommandNoticePolicyClearsExactCanonicalAcknowledgement()
    }),
    ("service command notice does not infer provider completion", {
        try testServiceBackedCommandNoticePolicyDoesNotInferProviderCompletion()
    }),
    ("service command notice retains incomplete or foreign evidence", {
        try testServiceBackedCommandNoticePolicyRetainsIncompleteOrForeignEvidence()
    }),
    ("service command notice rejects identity and cursor drift", {
        try testServiceBackedCommandNoticePolicyRejectsIdentityAndCursorDrift()
    }),
    ("service command notice uses immutable receipt correlation", {
        try testServiceBackedCommandNoticePolicyUsesImmutableReceiptCorrelation()
    }),
    ("service command notice uses canonical evidence across connectivity", {
        try testServiceBackedCommandNoticePolicyUsesCanonicalEvidenceAcrossConnectivity()
    }),
    ("service command notice settles lost End confirmation exactly", {
        try testServiceBackedCommandNoticePolicySettlesLostEndConfirmationExactly()
    }),
    ("service command notice matches native lifecycle aliases", {
        try testServiceBackedCommandNoticePolicyMatchesNativeLifecycleAliases()
    }),
    ("accepted Start presentation grace binds one exact Run and host", {
        try testServiceBackedStartPresentationGraceBindsOneExactRun()
    }),
    ("accepted Start presentation grace is bounded and clears healthy or failed state", {
        try testServiceBackedStartPresentationGraceWaitsThenExpiresOrClears()
    }),
    ("accepted Start presentation grace rejects recovery and pending receipts", {
        try testServiceBackedStartPresentationGraceRejectsRecoveryAndPendingReceipts()
    }),
]
