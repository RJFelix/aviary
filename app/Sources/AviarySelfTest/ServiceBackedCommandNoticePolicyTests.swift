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
    readDiagnostics: [String] = []
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
    let observation = try WorkServiceHostObservation(
        instance: WorkHostInstanceRef(
            host: WorkHostRef(noticePolicyWork.workHostID), instanceID: "notice-instance",
            startIdentity: "notice-start"), reachability: .observedReachable,
        currentRun: nil, currentRunSession: nil, currentRunSessionAttachment: nil,
        servedCursor: workCursor, sourceCompleteness: canonical ? .complete : .incomplete)
    let descriptor = try WorkServiceWorkDescriptor(
        work: noticePolicyWork, journal: noticePolicyJournal, recordedDisposition: .reusable,
        execution: .idle, currentRun: nil, currentRunSession: nil,
        currentRunSessionAttachment: nil, hostObservation: observation,
        attachments: [attachment], sessionAttachments: [relationship])

    var workSnapshot = WorkSnapshot()
    workSnapshot.journal = noticePolicyJournal
    workSnapshot.work = noticePolicyWork
    workSnapshot.workHost = WorkHostRef(noticePolicyWork.workHostID)
    workSnapshot.lifecycle = .active
    workSnapshot.execution = .idle
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
        commandKind: commandKind)

    var sessionSnapshot = SessionSnapshot()
    sessionSnapshot.journal = noticePolicySessionJournal
    sessionSnapshot.session = noticePolicySession
    sessionSnapshot.lifecycle = .active
    let receipt = WorkServiceCommandReceipt(
        work: noticePolicyWork, commandID: lastReceiptCommandID, state: .accepted,
        host: WorkHostInstanceRef(
            host: WorkHostRef(noticePolicyWork.workHostID), instanceID: "notice-instance",
            startIdentity: "notice-start"), hostSequence: 2,
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
        requiresRefresh: !canonical)
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

let casesServiceBackedCommandNoticePolicy: [Case] = [
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
]
