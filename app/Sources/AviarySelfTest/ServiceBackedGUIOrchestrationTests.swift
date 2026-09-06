import Foundation
@testable import AviaryCore

private let guiOrchestrationHost = WorkHostRef("gui-orchestration-host")
private let guiOrchestrationWork = WorkRef(
    workHostID: guiOrchestrationHost.workHostID, workID: "gui-orchestration-work")
private let guiOrchestrationWorkJournal = JournalRef.work(guiOrchestrationWork)
private let guiOrchestrationClient = ClientRef("gui-orchestration-client")
private let guiOrchestrationAuthorizer = ClientAttachmentRef("gui-orchestration-authorizer")

private func guiOrchestrationRequest(
    commandID: String,
    authorizer: ClientAttachmentRef = guiOrchestrationAuthorizer
) -> WorkServiceCreateSessionRequest {
    WorkServiceCreateSessionRequest(
        work: guiOrchestrationWork,
        journal: guiOrchestrationWorkJournal,
        attachment: authorizer,
        client: guiOrchestrationClient,
        commandID: commandID,
        causalControlCursor: JournalCursor(
            journal: .workHost(guiOrchestrationHost), eventID: "control-0", sequence: 0),
        causalWorkCursor: JournalCursor(
            journal: guiOrchestrationWorkJournal, eventID: "work-0", sequence: 0),
        requestedCapabilities: [.observe, .control, .start])
}

private func guiOrchestrationSessionKey(
    sessionID: String,
    sessionAttachmentID: String,
    clientAttachmentID: String
) throws -> ServiceAttachmentKey {
    let session = SessionRef(sessionID)
    let sessionJournal = JournalRef.session(
        session, journalID: "journal-\(sessionID)",
        authority: TimelineAuthorityRef(guiOrchestrationHost.workHostID))
    let workSession = try XCTUnwrap(WorkSessionKey(
        work: guiOrchestrationWork,
        session: session,
        sessionJournal: sessionJournal,
        sessionAttachment: SessionAttachmentRef(sessionAttachmentID)))
    return try XCTUnwrap(ServiceAttachmentKey(
        client: guiOrchestrationClient,
        clientAttachment: ClientAttachmentRef(clientAttachmentID),
        workSession: workSession))
}

private func guiOrchestrationAttachment(
    key: ServiceAttachmentKey,
    authorization: Set<WorkServiceCapability> = [.observe]
) -> WorkServiceClientAttachment {
    WorkServiceClientAttachment(
        attachment: key.clientAttachment,
        client: key.client,
        session: key.workSession.session,
        sessionJournal: key.workSession.sessionJournal,
        sessionAttachment: key.workSession.sessionAttachment,
        authorization: WorkServiceAuthorizationOutcome(
            requested: authorization, granted: authorization, denied: []))
}

private func guiOrchestrationRelationship(
    key: ServiceAttachmentKey,
    workCursorEventID: String
) -> WorkServiceSessionAttachmentDescriptor {
    let sessionCursor = JournalCursor(
        journal: key.workSession.sessionJournal, eventID: "session-1", sequence: 1)
    let workCursor = JournalCursor(
        journal: guiOrchestrationWorkJournal, eventID: workCursorEventID, sequence: 1)
    return WorkServiceSessionAttachmentDescriptor(
        session: key.workSession.session,
        sessionJournal: key.workSession.sessionJournal,
        sessionAttachment: key.workSession.sessionAttachment,
        publication: .mirrored,
        causalSessionCursor: JournalCursor(
            journal: key.workSession.sessionJournal, sequence: 0),
        sessionCursor: sessionCursor,
        causalWorkCursor: JournalCursor(
            journal: guiOrchestrationWorkJournal, sequence: 0),
        resultingWorkCursor: workCursor,
        capabilities: [.observe])
}

private func guiOrchestrationDescriptor(
    relationships: [WorkServiceSessionAttachmentDescriptor],
    attachments: [WorkServiceClientAttachment]
) throws -> WorkServiceWorkDescriptor {
    try WorkServiceWorkDescriptor(
        work: guiOrchestrationWork,
        journal: guiOrchestrationWorkJournal,
        recordedDisposition: .reusable,
        execution: .idle,
        currentRun: nil,
        currentRunSession: nil,
        currentRunSessionAttachment: nil,
        hostObservation: nil,
        attachments: attachments,
        sessionAttachments: relationships)
}

func testServiceBackedGUIOrchestrationPassivePollDoesNotStealFocus() throws {
    let request = guiOrchestrationRequest(commandID: "poll-recover")
    let key = try guiOrchestrationSessionKey(
        sessionID: "poll-session", sessionAttachmentID: "poll-session-attachment",
        clientAttachmentID: "poll-client-attachment")
    let recovery = try XCTUnwrap(
        ServiceBackedGUIOrchestration.RecoveredCreateSession(
            request: request, attachmentKey: key))
    let currentFocus = try guiOrchestrationSessionKey(
        sessionID: "existing-focus", sessionAttachmentID: "existing-focus-attachment",
        clientAttachmentID: "existing-focus-client")
    let current = ServiceBackedGUIOrchestration.PresentationState(
        selectedSessionID: "already-selected", focusedAttachment: currentFocus)

    let decision = ServiceBackedGUIOrchestration.passivePolling(
        current: current, recoveries: [recovery])
    XCTAssertEqual(decision.presentation, current)
    XCTAssertEqual(decision.adopted, [key])

    let reconciliation = ServiceBackedGUIOrchestration.reconcileCreateSession(
        pending: [request],
        observations: [
            .init(request: request, outcome: .recovered(recovery)),
        ],
        mode: .passivePolling)
    XCTAssertFalse(reconciliation.shouldFocusRecovery)
    XCTAssertFalse(reconciliation.shouldIssueCreateSession)
}

func testServiceBackedGUIOrchestrationStartKeepsBodyAndCommandIdentityTogether() throws {
    let key = try guiOrchestrationSessionKey(
        sessionID: "start-session", sessionAttachmentID: "start-session-attachment",
        clientAttachmentID: "start-client-attachment")
    let retained = try ServiceBackedStartIntent(
        client: key.client,
        work: key.workSession.work,
        session: key.workSession.session,
        sessionJournal: key.workSession.sessionJournal,
        sessionAttachment: key.workSession.sessionAttachment,
        clientAttachment: key.clientAttachment,
        causalWorkCursor: JournalCursor(
            journal: guiOrchestrationWorkJournal, eventID: "start-cursor", sequence: 1),
        commandID: "retained-start-command",
        prompt: "retained prompt bytes")

    let automatic = try XCTUnwrap(ServiceBackedGUIOrchestration.startCommand(
        prompt: retained.prompt, commandID: nil, retained: retained))
    XCTAssertEqual(automatic.prompt, retained.prompt)
    XCTAssertEqual(automatic.commandID, retained.commandID)

    XCTAssertNil(ServiceBackedGUIOrchestration.startCommand(
        prompt: "new composer bytes", commandID: "new-composer-command", retained: retained))
    XCTAssertNil(ServiceBackedGUIOrchestration.startCommand(
        prompt: "different bytes", commandID: retained.commandID, retained: retained))
    XCTAssertNil(ServiceBackedGUIOrchestration.startCommand(
        prompt: "different bytes", commandID: nil, retained: retained))

    let fresh = try XCTUnwrap(ServiceBackedGUIOrchestration.startCommand(
        prompt: "new composer bytes", commandID: "new-composer-command", retained: nil))
    XCTAssertEqual(fresh.prompt, "new composer bytes")
    XCTAssertEqual(fresh.commandID, "new-composer-command")
}

func testServiceBackedGUIOrchestrationRetryBlocksRecoveryAndShutdownJoinsIt() {
    var barrier = ServiceBackedGUIOrchestration.CommandBarrier()
    XCTAssertTrue(barrier.canResolveUnresolvedDraft(
        hasUnresolvedDraft: true, isEnding: false))
    XCTAssertTrue(barrier.begin(
        hasUnresolvedDraft: true, allowingUnresolvedDraft: true))
    XCTAssertEqual(barrier.operationsInFlight, 1)
    XCTAssertFalse(barrier.canResolveUnresolvedDraft(
        hasUnresolvedDraft: true, isEnding: false))
    XCTAssertFalse(barrier.begin(
        hasUnresolvedDraft: true, allowingUnresolvedDraft: true))

    barrier.freeze()
    XCTAssertTrue(barrier.admissionFrozen)
    XCTAssertEqual(barrier.operationsInFlight, 1)
    XCTAssertTrue(barrier.finish())
    XCTAssertEqual(barrier.operationsInFlight, 0)
    XCTAssertFalse(barrier.begin(
        hasUnresolvedDraft: false, allowingUnresolvedDraft: false))
    barrier.resume()
    XCTAssertTrue(barrier.begin(
        hasUnresolvedDraft: false, allowingUnresolvedDraft: false))
    XCTAssertTrue(barrier.finish())
}

func testServiceBackedGUIOrchestrationExplicitRecoveredClickDoesNotCreateAgain() throws {
    let request = guiOrchestrationRequest(commandID: "click-recover")
    let key = try guiOrchestrationSessionKey(
        sessionID: "click-session", sessionAttachmentID: "click-session-attachment",
        clientAttachmentID: "click-client-attachment")
    let recovery = try XCTUnwrap(
        ServiceBackedGUIOrchestration.RecoveredCreateSession(
            request: request, attachmentKey: key))

    let decision = ServiceBackedGUIOrchestration.reconcileCreateSession(
        pending: [request],
        observations: [
            .init(request: request, outcome: .recovered(recovery)),
        ],
        mode: .explicitCreate)
    XCTAssertEqual(decision.cleared, [request])
    XCTAssertTrue(decision.retained.isEmpty)
    XCTAssertEqual(decision.recoveries.map(\.attachmentKey), [key])
    XCTAssertTrue(decision.shouldFocusRecovery)
    XCTAssertFalse(decision.shouldIssueCreateSession)
}

func testServiceBackedGUIOrchestrationMixedOutcomesRetainBlockedAndAdoptOnlyExact() throws {
    let recoveredRequest = guiOrchestrationRequest(commandID: "mixed-recovered")
    let blockedRequest = guiOrchestrationRequest(commandID: "mixed-blocked")
    let rejectedRequest = guiOrchestrationRequest(commandID: "mixed-rejected")
    let mismatchedRequest = guiOrchestrationRequest(commandID: "mixed-mismatched")
    let exactKey = try guiOrchestrationSessionKey(
        sessionID: "mixed-session", sessionAttachmentID: "mixed-session-attachment",
        clientAttachmentID: "mixed-client-attachment")
    let wrongKey = try guiOrchestrationSessionKey(
        sessionID: "wrong-session", sessionAttachmentID: "wrong-session-attachment",
        clientAttachmentID: "wrong-client-attachment")
    let exactRecovery = try XCTUnwrap(
        ServiceBackedGUIOrchestration.RecoveredCreateSession(
            request: recoveredRequest, attachmentKey: exactKey))
    let wrongRecovery = try XCTUnwrap(
        ServiceBackedGUIOrchestration.RecoveredCreateSession(
            request: guiOrchestrationRequest(commandID: "other-request"),
            attachmentKey: wrongKey))

    let decision = ServiceBackedGUIOrchestration.reconcileCreateSession(
        pending: [recoveredRequest, blockedRequest, rejectedRequest, mismatchedRequest],
        observations: [
            .init(request: recoveredRequest, outcome: .recovered(exactRecovery)),
            .init(request: blockedRequest, outcome: .blocked),
            .init(request: rejectedRequest, outcome: .rejected),
            // A recovery qualified for another request is not an adoption of this record.
            .init(request: mismatchedRequest, outcome: .recovered(wrongRecovery)),
        ],
        mode: .passivePolling)
    XCTAssertEqual(decision.cleared, [recoveredRequest, rejectedRequest])
    XCTAssertEqual(decision.retained, [blockedRequest, mismatchedRequest])
    XCTAssertEqual(decision.recoveries.map(\.attachmentKey), [exactKey])
    XCTAssertFalse(decision.shouldIssueCreateSession)
}

func testServiceBackedGUIOrchestrationInspectSelectsOneAttachmentQualifiedKey() throws {
    let firstKey = try guiOrchestrationSessionKey(
        sessionID: "inspect-a", sessionAttachmentID: "inspect-a-attachment",
        clientAttachmentID: "inspect-a-client")
    let secondKey = try guiOrchestrationSessionKey(
        sessionID: "inspect-b", sessionAttachmentID: "inspect-b-attachment",
        clientAttachmentID: "inspect-b-client")
    let descriptor = try guiOrchestrationDescriptor(
        relationships: [
            guiOrchestrationRelationship(key: firstKey, workCursorEventID: "work-a"),
            guiOrchestrationRelationship(key: secondKey, workCursorEventID: "work-b"),
        ],
        attachments: [guiOrchestrationAttachment(key: firstKey)])

    let decision = try XCTUnwrap(ServiceBackedGUIOrchestration.inspect(
        descriptor: descriptor,
        client: guiOrchestrationClient,
        targetSessionAttachment: firstKey.workSession.sessionAttachment))
    XCTAssertEqual(decision.target.workSession, firstKey.workSession)
    XCTAssertEqual(decision.existingAttachmentKey, firstKey)
    XCTAssertEqual(decision.existingAttachment?.attachment, firstKey.clientAttachment)
    XCTAssertTrue(decision.shouldFocus)

    let attachDecision = try XCTUnwrap(ServiceBackedGUIOrchestration.inspect(
        descriptor: descriptor,
        client: guiOrchestrationClient,
        targetSessionAttachment: secondKey.workSession.sessionAttachment))
    XCTAssertEqual(attachDecision.target.workSession, secondKey.workSession)
    XCTAssertNil(attachDecision.existingAttachmentKey)
    XCTAssertNil(attachDecision.existingAttachment)
    XCTAssertTrue(attachDecision.shouldFocus)
}

func testServiceBackedGUIOrchestrationInspectRejectsAmbiguousRelationship() throws {
    let firstKey = try guiOrchestrationSessionKey(
        sessionID: "ambiguous-a", sessionAttachmentID: "ambiguous-attachment",
        clientAttachmentID: "ambiguous-client-a")
    let secondKey = try guiOrchestrationSessionKey(
        sessionID: "ambiguous-b", sessionAttachmentID: "ambiguous-attachment",
        clientAttachmentID: "ambiguous-client-b")
    let descriptor = try guiOrchestrationDescriptor(
        relationships: [
            guiOrchestrationRelationship(key: firstKey, workCursorEventID: "work-c"),
            guiOrchestrationRelationship(key: secondKey, workCursorEventID: "work-d"),
        ],
        attachments: [])
    XCTAssertNil(ServiceBackedGUIOrchestration.inspect(
        descriptor: descriptor,
        client: guiOrchestrationClient,
        targetSessionAttachment: firstKey.workSession.sessionAttachment))
}

let casesServiceBackedGUIOrchestration: [Case] = [
    ("phase3 GUI orchestration: Start keeps exact body and command identity paired", {
        try testServiceBackedGUIOrchestrationStartKeepsBodyAndCommandIdentityTogether()
    }),
    ("phase3 GUI orchestration: retry blocks recovery and shutdown joins it", {
        testServiceBackedGUIOrchestrationRetryBlocksRecoveryAndShutdownJoinsIt()
    }),
    ("phase3 GUI orchestration: passive recovery preserves selection and focus", {
        try testServiceBackedGUIOrchestrationPassivePollDoesNotStealFocus()
    }),
    ("phase3 GUI orchestration: recovered Create click does not issue a second Create", {
        try testServiceBackedGUIOrchestrationExplicitRecoveredClickDoesNotCreateAgain()
    }),
    ("phase3 GUI orchestration: mixed outcomes retain blocked records", {
        try testServiceBackedGUIOrchestrationMixedOutcomesRetainBlockedAndAdoptOnlyExact()
    }),
    ("phase3 GUI orchestration: Inspect resolves one attachment-qualified key", {
        try testServiceBackedGUIOrchestrationInspectSelectsOneAttachmentQualifiedKey()
    }),
    ("phase3 GUI orchestration: Inspect rejects duplicate relationship ids", {
        try testServiceBackedGUIOrchestrationInspectRejectsAmbiguousRelationship()
    }),
]
