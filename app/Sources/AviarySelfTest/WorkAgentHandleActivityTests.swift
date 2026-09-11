import Foundation
@testable import AviaryCore

private let agentActivityHost = WorkHostRef("agent-activity-host")
private let agentActivityWork = WorkRef(
    workHostID: agentActivityHost.workHostID, workID: "agent-activity-work")
private let agentActivityWorkJournal = JournalRef.work(
    agentActivityWork, journalID: "agent-activity-work-journal")
private let agentActivitySession = SessionRef("agent-activity-session")
private let agentActivitySessionJournal = JournalRef.session(
    agentActivitySession, journalID: "agent-activity-session-journal",
    authority: TimelineAuthorityRef(agentActivityHost.workHostID))

private struct AgentActivityFixture {
    let projection: WorkServiceAttachedWorkProjection
    let work: WorkSnapshot
}

private func agentActivityHandle(
    _ id: String,
    state: WorkAgentHandleState,
    outcome: WorkAgentHandleTerminalOutcome? = nil,
    cleanup: WorkAgentHandleCleanupState? = nil
) -> WorkAgentHandleSnapshot {
    let handle = HandleRef(id)
    let origin = WorkAgentHandleOrigin(
        work: agentActivityWork, workHost: agentActivityHost,
        session: agentActivitySession, sessionAttachment: SessionAttachmentRef("attachment"),
        run: RunRef("parent-run"))
    let queuedEvent = EventRef(journal: agentActivityWorkJournal, eventID: "queued-\(id)")
    var snapshot = WorkAgentHandleSnapshot(
        handle: handle, origin: origin, label: "private label \(id)",
        deadline: Date(timeIntervalSince1970: 0),
        requestBody: TimelineBodyReference(
            authority: agentActivityWorkJournal, referenceID: "private-body-\(id)",
            mediaType: "application/octet-stream", byteCount: 8,
            digest: "sha256:" + String(repeating: "a", count: 64)),
        queuedEvent: queuedEvent)
    snapshot.state = state
    guard let outcome else { return snapshot }
    let terminalEvent = EventRef(journal: agentActivityWorkJournal, eventID: "terminal-\(id)")
    let evidence = WorkAgentHandleEventEvidence(
        event: terminalEvent, sequence: 2, previousEventID: queuedEvent.eventID,
        causedByEventID: nil, hostSequence: nil, work: agentActivityWork,
        workHost: agentActivityHost, session: agentActivitySession,
        sessionAttachment: origin.sessionAttachment, run: origin.run, handle: handle,
        client: ClientRef("agent-activity-client"), actor: TimelineActor(actorID: "fixture"),
        hostRecordedAt: Date(timeIntervalSince1970: 2), provenance: .native)
    snapshot.terminalEvidence = WorkAgentHandleTerminalEvidence(
        outcome: outcome, resultBody: nil,
        cleanup: WorkAgentHandleCleanupProof(state: cleanup ?? .indeterminate, evidence: terminalEvent),
        event: evidence)
    snapshot.latestLifecycleEvent = terminalEvent
    return snapshot
}

private func agentActivityFixture(
    handles: [WorkAgentHandleSnapshot], connected: Bool = true,
    sourceComplete: Bool = true, unknownRuntime: Bool = false,
    workUnknownDomains: Set<TimelineDomain> = [], sessionUnknownDomains: Set<TimelineDomain> = []
) throws -> AgentActivityFixture {
    let clientAttachment = ClientAttachmentRef("client-attachment")
    let sessionAttachment = SessionAttachmentRef("attachment")
    let client = ClientRef("agent-activity-client")
    let run: RunRef? = nil
    let workCursor = JournalCursor(
        journal: agentActivityWorkJournal, eventID: "work-tip", sequence: 3)
    let sessionCursor = JournalCursor(
        journal: agentActivitySessionJournal, eventID: "session-tip", sequence: 2)
    let attachment = WorkServiceClientAttachment(
        attachment: clientAttachment, client: client, session: agentActivitySession,
        sessionJournal: agentActivitySessionJournal, sessionAttachment: sessionAttachment,
        authorization: WorkServiceAuthorizationOutcome(requested: [], granted: [], denied: []))
    let relationship = WorkServiceSessionAttachmentDescriptor(
        session: agentActivitySession, sessionJournal: agentActivitySessionJournal,
        sessionAttachment: sessionAttachment, publication: .mirrored,
        causalSessionCursor: JournalCursor(journal: agentActivitySessionJournal, sequence: 0),
        sessionCursor: sessionCursor,
        causalWorkCursor: JournalCursor(journal: agentActivityWorkJournal, sequence: 1),
        resultingWorkCursor: workCursor, capabilities: [])
    let workspace = try WorkHostWorkspaceID(
        "workspace-12345678-1234-1234-1234-123456789abc")
    let descriptor = try WorkServiceWorkDescriptor(
        work: agentActivityWork, journal: agentActivityWorkJournal,
        recordedDisposition: .reusable, execution: .idle, currentRun: run,
        currentRunSession: nil, currentRunSessionAttachment: nil,
        configuration: WorkServiceWorkConfiguration(workspaceID: workspace),
        hostObservation: nil, attachments: [attachment],
        sessionAttachments: [relationship], artifacts: [])
    var work = WorkSnapshot()
    work.journal = agentActivityWorkJournal
    work.work = agentActivityWork
    work.workHost = agentActivityHost
    work.lifecycle = .active
    work.execution = .idle
    work.lastSequence = workCursor.sequence
    work.lastEventID = workCursor.eventID
    work.attachedSessionIDs = [agentActivitySession.sessionID]
    work.sessionAttachments[sessionAttachment.attachmentID] = WorkSessionAttachmentSnapshot(
        attachment: sessionAttachment, session: agentActivitySession)
    work.agentHandles = Dictionary(uniqueKeysWithValues: handles.map {
        ($0.handle.handleID, $0)
    })
    work.childStates = ["legacy-child": "done"]
    work.unknownDomains = workUnknownDomains
    if unknownRuntime { work.unknownDomains.insert(.runtime) }
    var session = SessionSnapshot()
    session.journal = agentActivitySessionJournal
    session.session = agentActivitySession
    session.lifecycle = .active
    session.lastSequence = sessionCursor.sequence
    session.lastEventID = sessionCursor.eventID
    session.unknownDomains = sessionUnknownDomains
    session.attachments[sessionAttachment.attachmentID] = SessionAttachmentSnapshot(
        attachment: sessionAttachment, work: agentActivityWork, cursor: workCursor)
    let projection = WorkServiceAttachedWorkProjection(
        descriptor: descriptor, attachment: attachment,
        capabilities: Set(WorkServiceCapability.allCases), workSnapshot: work,
        sessionSnapshot: session, workCursor: workCursor, sessionCursor: sessionCursor,
        workSourceCompleteness: sourceComplete ? .complete : .incomplete,
        sessionSourceCompleteness: .complete,
        connectivity: connected ? .connected(nil) : .disconnected)
    return AgentActivityFixture(projection: projection, work: work)
}

func testWorkAgentHandleActivityProjectionAndPresentation() throws {
    let fixture = try agentActivityFixture(handles: [
        agentActivityHandle("queued", state: .queued),
        agentActivityHandle("running", state: .running),
        agentActivityHandle("cancel", state: .cancelRequested),
        agentActivityHandle("uncertain", state: .terminal, outcome: .indeterminate, cleanup: .indeterminate),
        agentActivityHandle("settled", state: .terminal, outcome: .succeeded, cleanup: .quiesced),
        agentActivityHandle("reaped", state: .reaped, outcome: .canceled, cleanup: .quiesced),
    ])
    let working = CanonicalWorkingStateProjection(projection: fixture.projection)
    XCTAssertTrue(working.isCanonical)
    XCTAssertNil(working.currentRun)
    XCTAssertEqual(working.agentHandles.count, 6)
    XCTAssertEqual(working.children.count, 1)

    let activity = ChatAgentHandleActivityPresentation(
        workingState: working, sourceIsCurrent: true)
    XCTAssertTrue(activity.isAvailable)
    XCTAssertTrue(activity.hasRecords)
    XCTAssertEqual(activity.queuedCount, 1)
    XCTAssertEqual(activity.runningCount, 1)
    XCTAssertEqual(activity.cancellationRequestedCount, 1)
    XCTAssertEqual(activity.terminalCleanupIndeterminateCount, 1)
    XCTAssertEqual(activity.settledCount, 1)
    XCTAssertEqual(activity.reapedCount, 1)
    XCTAssertEqual(activity.blockingCount, 4)
    XCTAssertEqual(activity.rows.first?.status, .queued)
    XCTAssertEqual(activity.rows[3].status, .terminalCleanupIndeterminate)
    XCTAssertTrue(activity.summary.contains("recorded queued"))
    XCTAssertTrue(activity.disclosure.contains("not proof"))
    XCTAssertFalse(activity.summary.contains("private label"))
    XCTAssertFalse(ChatChildActivityPresentation(
        workingState: working, sourceIsCurrent: true).summary.contains("recorded queued"))
}

func testWorkAgentHandleActivityRejectsInvalidAndRetainsDisconnectedCanonicalFacts() throws {
    let handles = [agentActivityHandle("running", state: .running)]
    let canonicalFixture = try agentActivityFixture(handles: handles)
    let working = CanonicalWorkingStateProjection(projection: canonicalFixture.projection)
    let disconnectedFixture = try agentActivityFixture(handles: handles, connected: false)
    let disconnectedWorking = CanonicalWorkingStateProjection(
        projection: disconnectedFixture.projection)
    let stale = ChatAgentHandleActivityPresentation(
        workingState: disconnectedWorking, sourceIsCurrent: false)
    XCTAssertTrue(stale.isAvailable)
    XCTAssertTrue(stale.hasRecords)
    XCTAssertFalse(stale.sourceIsCurrent)
    XCTAssertTrue(stale.disclosure.contains("not confirmed"))

    let incompleteFixture = try agentActivityFixture(handles: handles, sourceComplete: false)
    let unknownFixture = try agentActivityFixture(handles: handles, unknownRuntime: true)
    for invalid in [incompleteFixture.projection, unknownFixture.projection] {
        let invalidWorking = CanonicalWorkingStateProjection(projection: invalid)
        let unavailable = ChatAgentHandleActivityPresentation(
            workingState: invalidWorking, sourceIsCurrent: true)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertFalse(unavailable.hasRecords)
        XCTAssertTrue(unavailable.summary.contains("unavailable"))
    }
    XCTAssertFalse(working.agentHandles.first?.handleID.isEmpty ?? true)
    for domains in [
        (Set<TimelineDomain>([.session]), Set<TimelineDomain>()),
        (Set<TimelineDomain>(), Set<TimelineDomain>([.session])),
        (Set<TimelineDomain>(), Set<TimelineDomain>([.work])),
    ] {
        let fixture = try agentActivityFixture(
            handles: handles, workUnknownDomains: domains.0, sessionUnknownDomains: domains.1)
        let projection = CanonicalWorkingStateProjection(projection: fixture.projection)
        XCTAssertTrue(projection.isCanonical, "only the new agent availability is narrowed")
        XCTAssertFalse(projection.agentHandleFactsAvailable)
        XCTAssertTrue(projection.agentHandles.isEmpty)
        XCTAssertFalse(ChatAgentHandleActivityPresentation(
            workingState: projection, sourceIsCurrent: true).isAvailable)
    }
}

func testWorkAgentHandleActivityIsBoundedAndOmitsPrivateFields() throws {
    let fixture = try agentActivityFixture(handles:
        (0..<256).map {
            agentActivityHandle("settled-\($0)", state: .terminal, outcome: .succeeded, cleanup: .quiesced)
        }
        + (0..<44).map {
            agentActivityHandle("blocking-\($0)", state: .running)
        })
    let working = CanonicalWorkingStateProjection(projection: fixture.projection)
    XCTAssertEqual(working.agentHandles.count, CanonicalWorkingStateProjection.maximumAgentHandles)
    XCTAssertEqual(working.omittedAgentHandleCount, 44)
    let activity = ChatAgentHandleActivityPresentation(
        workingState: working, sourceIsCurrent: true)
    XCTAssertEqual(activity.rows.count, 256)
    XCTAssertEqual(activity.omittedCount, 44)
    XCTAssertEqual(activity.runningCount, 44)
    XCTAssertEqual(activity.rows.first?.status, .running)
    let encoded = String(decoding: try JSONEncoder().encode(working), as: UTF8.self)
    XCTAssertFalse(encoded.contains("private label"))
    XCTAssertFalse(encoded.contains("private-body"))
    XCTAssertFalse(encoded.contains("commands"))
}

let casesWorkAgentHandleActivity: [Case] = [
    ("phase5 recorded Work-owned agent activity: canonical lifecycle presentation", {
        try testWorkAgentHandleActivityProjectionAndPresentation()
    }),
    ("phase5 recorded Work-owned agent activity: invalid and disconnected views", {
        try testWorkAgentHandleActivityRejectsInvalidAndRetainsDisconnectedCanonicalFacts()
    }),
    ("phase5 recorded Work-owned agent activity: bounded privacy-safe rows", {
        try testWorkAgentHandleActivityIsBoundedAndOmitsPrivateFields()
    }),
]
