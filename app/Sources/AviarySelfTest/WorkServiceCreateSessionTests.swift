import Foundation
@testable import AviaryCore

private let createSessionHost = WorkHostRef("create-session-host")
private let createSessionClient = ClientRef("create-session-client")

private let createSessionCapabilities: Set<WorkServiceCapability> = [
    .observe, .control, .start, .send, .steer, .queue, .hold, .cancel, .end,
    .createSession,
]

private func createSessionAuthorizer(
    client: ClientRef = createSessionClient,
    grants: Set<WorkServiceCapability> = createSessionCapabilities
) -> WorkServiceCapabilityPolicy {
    WorkServiceCapabilityPolicy(grantsByClient: [client: grants])
}

private func createSessionWork(
    client: ClientRef = createSessionClient,
    grants: Set<WorkServiceCapability> = createSessionCapabilities
) async throws -> (InMemoryWorkService, WorkServiceCreateWorkResponse) {
    let service = InMemoryWorkService(
        host: createSessionHost,
        instanceID: "create-session-instance", startIdentity: "create-session-start",
        authorizer: createSessionAuthorizer(client: client, grants: grants))
    let response = try await service.createWork(.init(
        client: client, commandID: "create-work", causalControlCursor: JournalCursor(
            journal: .workHost(createSessionHost), sequence: 0),
        requestedCapabilities: grants.intersection([.observe, .control, .createSession, .send])))
    return (service, response)
}

private func createSessionRequest(
    work: WorkServiceCreateWorkResponse,
    commandID: String = "create-session",
    client: ClientRef = createSessionClient,
    causalControlCursor: JournalCursor? = nil,
    causalWorkCursor: JournalCursor? = nil,
    requestedCapabilities: Set<WorkServiceCapability> = [.observe, .send]
) -> WorkServiceCreateSessionRequest {
    WorkServiceCreateSessionRequest(
        work: work.work.work, journal: work.work.journal,
        attachment: work.attachment.attachment, client: client,
        commandID: commandID,
        causalControlCursor: causalControlCursor ?? work.controlCursor,
        causalWorkCursor: causalWorkCursor ?? work.workCursor,
        requestedCapabilities: requestedCapabilities)
}

private func createSessionJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

private actor BlockingCreateSessionTerminalCommitter: WorkServiceTerminalCommitter {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func commit(
        _ request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof {
        _ = request
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        throw WorkServiceProtocolError.sourceIncomplete
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

func test_workServiceCreateSessionMintsIndependentSessionAndWorkMirror() async throws {
    let (service, created) = try await createSessionWork()
    let request = createSessionRequest(work: created)
    let response = try await service.createSession(request)

    XCTAssertEqual(response.state, .accepted)
    XCTAssertEqual(response.receipt.operation, .createSession)
    XCTAssertEqual(response.receipt.outcome, .sessionCreated)
    XCTAssertEqual(response.workCursor.sequence, created.workCursor.sequence + 1)
    let session = try XCTUnwrap(response.session)
    let sessionJournal = try XCTUnwrap(response.sessionJournal)
    let sessionAttachment = try XCTUnwrap(response.sessionAttachment)
    let clientAttachment = try XCTUnwrap(response.attachment)
    let relationship = try XCTUnwrap(response.relationship)
    XCTAssertEqual(clientAttachment.session, session)
    XCTAssertEqual(clientAttachment.sessionJournal, sessionJournal)
    XCTAssertEqual(clientAttachment.sessionAttachment, sessionAttachment)
    XCTAssertEqual(relationship.publication, .mirrored)
    XCTAssertEqual(relationship.sessionJournal, sessionJournal)
    XCTAssertEqual(relationship.sessionAttachment, sessionAttachment)
    XCTAssertEqual(relationship.causalWorkCursor, created.workCursor)
    XCTAssertEqual(relationship.resultingWorkCursor, response.workCursor)
    XCTAssertEqual(relationship.sessionCursor, response.sessionCursor)
    XCTAssertTrue(relationship.isAttached)
    XCTAssertTrue(relationship.capabilities.contains(.observe))
    XCTAssertTrue(relationship.capabilities.contains(.send))
    XCTAssertFalse(relationship.capabilities.contains(.createSession))
    XCTAssertEqual(response.work.sessionAttachments.filter {
        $0.session == session
    }.count, 1)
    XCTAssertEqual(response.work.sessionAttachments.first {
        $0.sessionAttachment == sessionAttachment
    }, relationship)

    let workSnapshot = try await service.snapshot(.init(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: createSessionClient,
        target: .work(journal: created.work.journal), afterCursor: created.workCursor))
    XCTAssertEqual(workSnapshot.events.count, 1)
    XCTAssertEqual(workSnapshot.events.first?.type, TimelineEventType.sessionAttached)
    XCTAssertEqual(workSnapshot.events.first?.session, session)
    XCTAssertEqual(workSnapshot.events.first?.sessionAttachment, sessionAttachment)
    XCTAssertEqual(workSnapshot.servedCursor, response.workCursor)

    let sessionSnapshot = try await service.snapshot(.init(
        work: created.work.work, journal: created.work.journal,
        attachment: clientAttachment.attachment, client: createSessionClient,
        target: .session(session: session, journal: sessionJournal), afterCursor: nil))
    XCTAssertEqual(sessionSnapshot.events.map(\.type), [
        TimelineEventType.sessionCreated, TimelineEventType.sessionAttached,
        TimelineEventType.sessionAttachmentCursorAdvanced,
    ])
    XCTAssertEqual(sessionSnapshot.events[0].session, session)
    XCTAssertNil(sessionSnapshot.events[0].work)
    XCTAssertEqual(sessionSnapshot.events[1].work, created.work.work)
    XCTAssertEqual(sessionSnapshot.events[1].sessionAttachment, sessionAttachment)
    XCTAssertEqual(sessionSnapshot.events[2].payload["cursor"],
                   createSessionJSON(response.workCursor))
    XCTAssertEqual(sessionSnapshot.events[2].causedByEventID?.eventID,
                   response.workCursor.eventID)
    XCTAssertEqual(response.sessionCursor?.sequence, 3)
    XCTAssertEqual(sessionSnapshot.servedCursor, response.sessionCursor)
}

func test_workServiceCreateSessionSupportsSecondarySessionAttachAndRejectsCrossClaim() async throws {
    let secondClient = ClientRef("create-session-second-client")
    let grants = createSessionCapabilities
    let service = InMemoryWorkService(
        host: createSessionHost,
        instanceID: "create-session-many-instance", startIdentity: "create-session-many-start",
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            createSessionClient: grants,
            secondClient: grants,
        ]))
    let created = try await service.createWork(.init(
        client: createSessionClient, commandID: "many-create-work",
        causalControlCursor: JournalCursor(journal: .workHost(createSessionHost), sequence: 0),
        requestedCapabilities: [.observe, .control, .createSession, .start]))
    let createdSession = try await service.createSession(.init(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: createSessionClient,
        commandID: "many-create-session", causalControlCursor: created.controlCursor,
        causalWorkCursor: created.workCursor,
        requestedCapabilities: [.observe, .control, .start]))
    let secondarySession = try XCTUnwrap(createdSession.session)
    let secondaryJournal = try XCTUnwrap(createdSession.sessionJournal)
    let secondaryRelationship = try XCTUnwrap(createdSession.relationship)
    let attached = try await service.attach(.init(
        work: created.work.work, journal: created.work.journal, client: secondClient,
        session: secondarySession, sessionJournal: secondaryJournal,
        sessionAttachment: secondaryRelationship.sessionAttachment,
        commandID: "many-attach-second", causalControlCursor: createdSession.controlCursor,
        requestedCapabilities: [.observe, .control, .start]))
    XCTAssertEqual(attached.state, .accepted)
    let secondAttachment = try XCTUnwrap(attached.attachment)
    XCTAssertEqual(secondAttachment.session, secondarySession)
    XCTAssertEqual(secondAttachment.sessionAttachment, secondaryRelationship.sessionAttachment)

    do {
        _ = try await service.attach(.init(
            work: created.work.work, journal: created.work.journal, client: secondClient,
            session: SessionRef("unrecorded-session"),
            sessionJournal: .session(
                SessionRef("unrecorded-session"),
                authority: TimelineAuthorityRef(createSessionHost.workHostID)),
            sessionAttachment: SessionAttachmentRef("unrecorded-relationship"),
            commandID: "many-attach-unrecorded",
            causalControlCursor: attached.resultingControlCursor,
            requestedCapabilities: [.observe]))
        XCTFail("attach accepted a Session tuple with no canonical relationship")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    do {
        _ = try await service.command(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: secondAttachment.attachment, commandID: "many-cross-claim",
            client: secondClient, sessionAttachment: created.sessionAttachment,
            causalWorkCursor: createdSession.workCursor, kind: .start))
        XCTFail("command attributed a secondary client mutation to the primary Session")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    let started = try await service.command(.init(
        work: created.work.work, journal: created.work.journal,
        attachment: secondAttachment.attachment, commandID: "many-secondary-start",
        client: secondClient,
        sessionAttachment: secondaryRelationship.sessionAttachment,
        causalWorkCursor: createdSession.workCursor, kind: .start))
    XCTAssertEqual(started.state, .accepted)
    let activeRun = try XCTUnwrap(try await service.describeWork(.init(
        work: created.work.work, journal: created.work.journal,
        client: secondClient)).currentRun)
    try await service.finishRun(activeRun, for: created.work.work)
    let attributed = try await service.eventsAfterCursor(.init(
        work: created.work.work, journal: created.work.journal,
        attachment: secondAttachment.attachment, client: secondClient,
        target: .work(journal: created.work.journal),
        afterCursor: createdSession.workCursor,
        limit: WorkServiceBounds.maxEventsPerPage))
    XCTAssertEqual(attributed.events.map(\.type), [
        TimelineEventType.runStarted,
        TimelineEventType.commandAccepted,
        TimelineEventType.runFinished,
    ])
    XCTAssertTrue(attributed.events.allSatisfy { $0.session == secondarySession })
    XCTAssertTrue(attributed.events.allSatisfy {
        $0.sessionAttachment == secondaryRelationship.sessionAttachment
    })
}

func test_workServiceColdSeedRetainsCanonicalActiveRunSessionProvenance() async throws {
    let host = WorkHostRef("cold-run-provenance-host")
    let work = WorkRef(workHostID: host.workHostID, workID: "cold-run-provenance-work")
    let journal = JournalRef.work(work)
    let primarySession = SessionRef("cold-primary-session")
    let primaryAttachment = SessionAttachmentRef("cold-primary-attachment")
    let secondarySession = SessionRef("cold-secondary-session")
    let secondaryAttachment = SessionAttachmentRef("cold-secondary-attachment")
    let run = RunRef("cold-secondary-run")
    let actor = TimelineActor(actorID: "cold-host", kind: "self-test")
    let events = [
        TimelineEvent(
            eventID: "cold-work-1", journal: journal, sequence: 1,
            work: work, workHost: host, actor: actor,
            hostRecordedAt: Date(timeIntervalSince1970: 1),
            type: TimelineEventType.workCreated),
        TimelineEvent(
            eventID: "cold-work-2", journal: journal, sequence: 2,
            previousEventID: "cold-work-1", session: secondarySession,
            work: work, workHost: host, sessionAttachment: secondaryAttachment,
            actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 2),
            type: TimelineEventType.sessionAttached),
        TimelineEvent(
            eventID: "cold-work-3", journal: journal, sequence: 3,
            previousEventID: "cold-work-2", session: secondarySession,
            work: work, workHost: host, sessionAttachment: secondaryAttachment,
            run: run, actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 3),
            type: TimelineEventType.runStarted,
            payload: .object(["model_id": .string("cold-model")]))
    ]
    let client = ClientRef("cold-run-reader")
    let service = InMemoryWorkService(
        host: host,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: [.observe]]))
    try await service.register(.init(
        work: work, journal: journal, execution: .running, currentRun: run,
        cursor: JournalCursor(journal: journal, eventID: "cold-work-3", sequence: 3),
        session: primarySession,
        sessionJournal: .session(
            primarySession, authority: TimelineAuthorityRef(host.workHostID)),
        sessionAttachment: primaryAttachment, events: events))
    try await service.finishRun(run, for: work)
    let attached = try await service.attach(.init(
        work: work, journal: journal, client: client, commandID: "cold-run-observe",
        causalControlCursor: JournalCursor(journal: .workHost(host), sequence: 0),
        requestedCapabilities: [.observe]))
    let observer = try XCTUnwrap(attached.attachment)
    let page = try await service.snapshot(.init(
        work: work, journal: journal, attachment: observer.attachment,
        client: client, target: .work(journal: journal), afterCursor: nil,
        limit: WorkServiceBounds.maxEventsPerPage))
    let finished = try XCTUnwrap(page.events.last(where: {
        $0.type == TimelineEventType.runFinished
    }))
    XCTAssertEqual(finished.run, run)
    XCTAssertEqual(finished.session, secondarySession)
    XCTAssertEqual(finished.sessionAttachment, secondaryAttachment)
    XCTAssertNotEqual(finished.session, primarySession)

    let invalid = InMemoryWorkService(
        host: host, authorizer: WorkServiceCapabilityPolicy(grantsByClient: [:]))
    var missingProvenance = events
    missingProvenance[2] = TimelineEvent(
        eventID: "cold-work-3", journal: journal, sequence: 3,
        previousEventID: "cold-work-2", work: work, workHost: host, run: run,
        actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 3),
        type: TimelineEventType.runStarted)
    do {
        try await invalid.register(.init(
            work: work, journal: journal, execution: .running, currentRun: run,
            cursor: JournalCursor(journal: journal, eventID: "cold-work-3", sequence: 3),
            session: primarySession,
            sessionJournal: .session(
                primarySession, authority: TimelineAuthorityRef(host.workHostID)),
            sessionAttachment: primaryAttachment, events: missingProvenance))
        XCTFail("complete active Run seed borrowed primary Session provenance")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("Session attachment provenance"))
    }
}

func test_workServiceCreateSessionCannotOvertakeTerminalReservation() async throws {
    let committer = BlockingCreateSessionTerminalCommitter()
    let grants = createSessionCapabilities.union([.complete])
    let service = InMemoryWorkService(
        host: createSessionHost,
        instanceID: "create-session-race-instance", startIdentity: "create-session-race-start",
        authorizer: createSessionAuthorizer(grants: grants), terminalCommitter: committer)
    let created = try await service.createWork(.init(
        client: createSessionClient, commandID: "race-create-work",
        causalControlCursor: JournalCursor(journal: .workHost(createSessionHost), sequence: 0),
        requestedCapabilities: [.observe, .control, .createSession, .complete]))
    let before = try await service.describeWork(.init(
        work: created.work.work, journal: created.work.journal, client: createSessionClient))
    let terminalTask = Task {
        try await service.command(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, commandID: "race-complete",
            client: createSessionClient, sessionAttachment: created.sessionAttachment,
            causalWorkCursor: created.workCursor, kind: .complete))
    }
    await committer.waitUntilEntered()
    let rejected = try await service.createSession(.init(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: createSessionClient,
        commandID: "race-create-session", causalControlCursor: created.controlCursor,
        causalWorkCursor: created.workCursor, requestedCapabilities: [.observe]))
    XCTAssertEqual(rejected.state, .rejected)
    XCTAssertEqual(rejected.rejection, .terminalProofUnavailable)
    XCTAssertNil(rejected.session)
    XCTAssertNil(rejected.sessionJournal)
    XCTAssertNil(rejected.sessionAttachment)
    XCTAssertNil(rejected.attachment)
    XCTAssertNil(rejected.relationship)
    XCTAssertEqual(rejected.workCursor, created.workCursor)
    XCTAssertEqual(rejected.controlCursor, created.controlCursor)
    let during = try await service.describeWork(.init(
        work: created.work.work, journal: created.work.journal, client: createSessionClient))
    XCTAssertEqual(during.hostObservation?.servedCursor, before.hostObservation?.servedCursor)
    XCTAssertEqual(during.sessionAttachments, before.sessionAttachments)
    XCTAssertEqual(during.attachments, before.attachments)
    await committer.release()
    let terminal = try await terminalTask.value
    XCTAssertEqual(terminal.state, .rejected)
}

func test_workServiceCreateSessionRetryConflictAndStaleAreNoWrite() async throws {
    let (service, created) = try await createSessionWork()
    let request = createSessionRequest(work: created)
    let first = try await service.createSession(request)
    let retry = try await service.createSession(request)
    XCTAssertEqual(retry.state, .duplicate)
    XCTAssertEqual(retry.session, first.session)
    XCTAssertEqual(retry.sessionJournal, first.sessionJournal)
    XCTAssertEqual(retry.sessionAttachment, first.sessionAttachment)
    XCTAssertEqual(retry.attachment, first.attachment)
    XCTAssertEqual(retry.relationship, first.relationship)
    XCTAssertEqual(retry.workCursor, first.workCursor)
    XCTAssertEqual(retry.controlCursor, first.controlCursor)

    let conflict = try await service.createSession(createSessionRequest(
        work: created, requestedCapabilities: [.observe, .steer]))
    XCTAssertEqual(conflict.state, .rejected)
    XCTAssertEqual(conflict.rejection, .conflictingCommand)
    XCTAssertNil(conflict.session)
    XCTAssertNil(conflict.sessionJournal)
    XCTAssertNil(conflict.sessionAttachment)
    XCTAssertNil(conflict.attachment)
    XCTAssertNil(conflict.relationship)
    XCTAssertEqual(conflict.controlCursor, first.controlCursor)
    XCTAssertEqual(conflict.workCursor, first.workCursor)

    let stale = try await service.createSession(createSessionRequest(
        work: created, commandID: "stale-session",
        causalControlCursor: created.controlCursor,
        causalWorkCursor: created.workCursor))
    XCTAssertEqual(stale.state, .rejected)
    XCTAssertEqual(stale.rejection, .staleCursor)
    XCTAssertNil(stale.session)
    XCTAssertNil(stale.attachment)
    XCTAssertEqual(stale.workCursor, first.workCursor)
    XCTAssertEqual(stale.controlCursor, first.controlCursor)
}

func test_workServiceCreateSessionRequiresAuthorizingCapabilityAndReturnsNoFacts() async throws {
    let (service, created) = try await createSessionWork(
        grants: [.observe, .control])
    let response = try await service.createSession(createSessionRequest(work: created))
    XCTAssertEqual(response.state, .rejected)
    XCTAssertEqual(response.rejection, .authorizationDenied)
    XCTAssertFalse(response.authorization.granted.contains(.createSession))
    XCTAssertNil(response.session)
    XCTAssertNil(response.sessionJournal)
    XCTAssertNil(response.sessionAttachment)
    XCTAssertNil(response.attachment)
    XCTAssertNil(response.relationship)
    XCTAssertEqual(response.workCursor, created.workCursor)
    XCTAssertEqual(response.controlCursor, created.controlCursor)
}

func test_workServiceCreateSessionTerminalReferenceDoesNotMutateWork() async throws {
    let work = WorkRef(workHostID: createSessionHost.workHostID, workID: "terminal-work")
    let journal = JournalRef.work(work)
    let serviceWithoutProof = InMemoryWorkService(
        host: createSessionHost, authorizer: createSessionAuthorizer())
    try await serviceWithoutProof.register(.init(
        work: work, journal: journal, disposition: .completed,
        execution: .idle, cursor: JournalCursor(journal: journal, sequence: 0)))
    let unprovenAttached = try await serviceWithoutProof.attach(.init(
        work: work, journal: journal, client: createSessionClient,
        commandID: "terminal-unproven-attach",
        causalControlCursor: JournalCursor(
            journal: .workHost(createSessionHost), sequence: 0),
        requestedCapabilities: [.observe, .createSession]))
    let unprovenAttachment = try XCTUnwrap(unprovenAttached.attachment)
    let unproven = try await serviceWithoutProof.createSession(.init(
        work: work, journal: journal, attachment: unprovenAttachment.attachment,
        client: createSessionClient, commandID: "terminal-unproven-session",
        causalControlCursor: unprovenAttached.resultingControlCursor,
        causalWorkCursor: JournalCursor(journal: journal, sequence: 0),
        requestedCapabilities: [.observe]))
    XCTAssertEqual(unproven.state, .rejected)
    XCTAssertEqual(unproven.rejection, .invalidState)
    XCTAssertNil(unproven.session)
    XCTAssertNil(unproven.sessionJournal)
    XCTAssertNil(unproven.sessionAttachment)
    XCTAssertNil(unproven.attachment)
    XCTAssertNil(unproven.relationship)

    let terminalCreated = TimelineEvent(
        eventID: "terminal-created", journal: journal, sequence: 1,
        work: work, workHost: WorkHostRef(work.workHostID),
        actor: TimelineActor(actorID: "terminal-seed", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1), type: TimelineEventType.workCreated)
    let terminalCompleted = TimelineEvent(
        eventID: "terminal-completed", journal: journal, sequence: 2,
        previousEventID: terminalCreated.eventID,
        work: work, workHost: WorkHostRef(work.workHostID),
        actor: TimelineActor(actorID: "terminal-seed", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 2), type: TimelineEventType.workCompleted)
    let service = InMemoryWorkService(
        host: createSessionHost, authorizer: createSessionAuthorizer())
    try await service.register(.init(
        work: work, journal: journal, disposition: .completed,
        execution: .idle,
        cursor: JournalCursor(journal: journal, eventID: terminalCompleted.eventID, sequence: 2),
        events: [terminalCreated, terminalCompleted]))
    let attached = try await service.attach(.init(
        work: work, journal: journal, client: createSessionClient,
        commandID: "terminal-attach",
        causalControlCursor: JournalCursor(
            journal: .workHost(createSessionHost), sequence: 0),
        requestedCapabilities: [.observe, .createSession]))
    let clientAttachment = try XCTUnwrap(attached.attachment)
    let before = try await service.describeWork(.init(
        work: work, journal: journal, client: createSessionClient))
    let beforeEvents = try await service.snapshot(.init(
        work: work, journal: journal, attachment: clientAttachment.attachment,
        client: createSessionClient, target: .work(journal: journal), afterCursor: nil))
    let response = try await service.createSession(.init(
        work: work, journal: journal, attachment: clientAttachment.attachment,
        client: createSessionClient, commandID: "terminal-session",
        causalControlCursor: attached.resultingControlCursor,
        causalWorkCursor: try XCTUnwrap(before.hostObservation?.servedCursor),
        requestedCapabilities: [.observe, .send]))
    XCTAssertEqual(response.state, .accepted)
    XCTAssertEqual(response.relationship?.publication, .terminalReference)
    XCTAssertTrue(response.relationship?.capabilities.contains(.observe) ?? false)
    XCTAssertFalse(response.relationship?.capabilities.contains(.send) ?? true)
    XCTAssertTrue(response.authorization.denied.contains(.send))
    XCTAssertFalse(response.attachment?.authorization.granted.contains(.send) ?? true)
    let createdAttachment = try XCTUnwrap(response.attachment)
    let sendAfterTerminal = try await service.command(.init(
        work: work, journal: journal, attachment: createdAttachment.attachment,
        commandID: "terminal-send", client: createSessionClient,
        sessionAttachment: response.sessionAttachment,
        causalWorkCursor: response.workCursor, kind: .send))
    XCTAssertEqual(sendAfterTerminal.state, .rejected)
    XCTAssertEqual(sendAfterTerminal.rejection, .authorizationDenied)
    XCTAssertEqual(response.workCursor, before.hostObservation?.servedCursor)
    let after = try await service.describeWork(.init(
        work: work, journal: journal, client: createSessionClient))
    let afterEvents = try await service.snapshot(.init(
        work: work, journal: journal, attachment: clientAttachment.attachment,
        client: createSessionClient, target: .work(journal: journal), afterCursor: nil))
    XCTAssertEqual(after.hostObservation?.servedCursor, before.hostObservation?.servedCursor)
    XCTAssertEqual(afterEvents.events, beforeEvents.events)
    XCTAssertEqual(afterEvents.servedCursor, beforeEvents.servedCursor)
    XCTAssertEqual(response.relationship?.causalWorkCursor, response.workCursor)
    XCTAssertEqual(response.relationship?.resultingWorkCursor, response.workCursor)
    XCTAssertEqual(response.sessionCursor?.sequence, 3)

    let denied = try await service.createSession(.init(
        work: work, journal: journal, attachment: clientAttachment.attachment,
        client: createSessionClient, commandID: "terminal-session-without-observe",
        causalControlCursor: response.controlCursor,
        causalWorkCursor: response.workCursor,
        requestedCapabilities: [.send]))
    XCTAssertEqual(denied.state, .rejected)
    XCTAssertEqual(denied.rejection, .authorizationDenied)
    XCTAssertNil(denied.session)
    XCTAssertNil(denied.attachment)
    XCTAssertEqual(denied.workCursor, response.workCursor)
    XCTAssertEqual(denied.controlCursor, response.controlCursor)
}

func test_workServiceCreateSessionRejectsNoncanonicalTerminalSeedAndFabricatedRelationship() async throws {
    let work = WorkRef(workHostID: createSessionHost.workHostID, workID: "forged-terminal-work")
    let journal = JournalRef.work(work)
    let created = TimelineEvent(
        eventID: "forged-terminal-created", journal: journal, sequence: 1,
        work: work, workHost: createSessionHost,
        actor: TimelineActor(actorID: "forged-seed", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1), type: TimelineEventType.workCreated)
    let completed = TimelineEvent(
        eventID: "forged-terminal-completed", journal: journal, sequence: 2,
        previousEventID: "not-the-created-event",
        work: work, workHost: createSessionHost,
        actor: TimelineActor(actorID: "forged-seed", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 2), type: TimelineEventType.workCompleted)
    let service = InMemoryWorkService(
        host: createSessionHost, authorizer: createSessionAuthorizer())
    try await service.register(.init(
        work: work, journal: journal, disposition: .completed, execution: .idle,
        cursor: JournalCursor(journal: journal, eventID: completed.eventID, sequence: 2),
        events: [created, completed]))
    let attached = try await service.attach(.init(
        work: work, journal: journal, client: createSessionClient,
        commandID: "forged-terminal-attach",
        causalControlCursor: JournalCursor(journal: .workHost(createSessionHost), sequence: 0),
        requestedCapabilities: [.observe, .createSession]))
    let attachment = try XCTUnwrap(attached.attachment)
    let rejected = try await service.createSession(.init(
        work: work, journal: journal, attachment: attachment.attachment,
        client: createSessionClient, commandID: "forged-terminal-session",
        causalControlCursor: attached.resultingControlCursor,
        causalWorkCursor: JournalCursor(
            journal: journal, eventID: completed.eventID, sequence: 2),
        requestedCapabilities: [.observe]))
    XCTAssertEqual(rejected.state, .rejected)
    XCTAssertEqual(rejected.rejection, .invalidState)
    XCTAssertNil(rejected.relationship)

    let seedSession = SessionRef("metadata-only-session")
    let seedAttachment = SessionAttachmentRef("metadata-only-attachment")
    let metadataWork = WorkRef(
        workHostID: createSessionHost.workHostID, workID: "metadata-only-work")
    let metadataJournal = JournalRef.work(metadataWork)
    let metadataService = InMemoryWorkService(
        host: createSessionHost, authorizer: createSessionAuthorizer())
    try await metadataService.register(.init(
        work: metadataWork, journal: metadataJournal,
        session: seedSession,
        sessionJournal: .session(
            seedSession, authority: TimelineAuthorityRef(createSessionHost.workHostID)),
        sessionAttachment: seedAttachment))
    let descriptor = try await metadataService.describeWork(.init(
        work: metadataWork, journal: metadataJournal, client: createSessionClient))
    XCTAssertTrue(descriptor.sessionAttachments.isEmpty)
    do {
        _ = try await metadataService.attach(.init(
            work: metadataWork, journal: metadataJournal, client: createSessionClient,
            session: seedSession, sessionJournal: .session(
                seedSession, authority: TimelineAuthorityRef(createSessionHost.workHostID)),
            sessionAttachment: seedAttachment, commandID: "metadata-only-attach",
            causalControlCursor: JournalCursor(
                journal: .workHost(createSessionHost), sequence: 0),
            requestedCapabilities: [.observe]))
        XCTFail("seed metadata was fabricated into a mirrored Session relationship")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }
}

func test_workServiceCreateSessionDescriptorIsBounded() async throws {
    let (service, created) = try await createSessionWork()
    var control = created.controlCursor
    var work = created.workCursor
    for index in 0..<(WorkServiceBounds.maxSessionAttachmentsPerWork - 1) {
        let response = try await service.createSession(.init(
            work: created.work.work, journal: created.work.journal,
            attachment: created.attachment.attachment, client: createSessionClient,
            commandID: "bounded-session-\(index)", causalControlCursor: control,
            causalWorkCursor: work, requestedCapabilities: [.observe]))
        XCTAssertEqual(response.state, .accepted)
        control = response.controlCursor
        work = response.workCursor
    }
    let descriptor = try await service.describeWork(.init(
        work: created.work.work, journal: created.work.journal,
        client: createSessionClient))
    XCTAssertEqual(descriptor.sessionAttachments.count,
                   WorkServiceBounds.maxSessionAttachmentsPerWork)
    XCTAssertNil(descriptor.omissions.first(where: { $0.category == "session_attachments" }))
    XCTAssertTrue(descriptor.sessionAttachments.allSatisfy {
        $0.session.sessionID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && $0.sessionJournal.journalID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && $0.sessionAttachment.attachmentID.utf8.count
                <= WorkServiceBounds.maxIdentityCharacters
    })

    let rejected = try await service.createSession(.init(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: createSessionClient,
        commandID: "bounded-session-rejected", causalControlCursor: control,
        causalWorkCursor: work, requestedCapabilities: [.observe]))
    XCTAssertEqual(rejected.state, .rejected)
    XCTAssertEqual(rejected.rejection, .invalidState)
    XCTAssertNil(rejected.session)
    XCTAssertNil(rejected.sessionJournal)
    XCTAssertNil(rejected.sessionAttachment)
    XCTAssertNil(rejected.attachment)
    XCTAssertNil(rejected.relationship)
    XCTAssertEqual(rejected.controlCursor, control)
    XCTAssertEqual(rejected.workCursor, work)
    let afterRejected = try await service.describeWork(.init(
        work: created.work.work, journal: created.work.journal,
        client: createSessionClient))
    XCTAssertEqual(afterRejected.sessionAttachments.count,
                   WorkServiceBounds.maxSessionAttachmentsPerWork)
    XCTAssertNil(afterRejected.omissions.first(where: { $0.category == "session_attachments" }))
}

let casesWorkServiceCreateSession: [Case] = [
    ("phase3 Work service createSession: independent Session and Work mirror", {
        try await test_workServiceCreateSessionMintsIndependentSessionAndWorkMirror()
    }),
    ("phase3 Work service createSession: secondary GUI attaches exact Session relationship", {
        try await test_workServiceCreateSessionSupportsSecondarySessionAttachAndRejectsCrossClaim()
    }),
    ("phase3 Work service createSession: cold active Run keeps canonical Session provenance", {
        try await test_workServiceColdSeedRetainsCanonicalActiveRunSessionProvenance()
    }),
    ("phase3 Work service createSession: terminal reservation blocks overtaking mutation", {
        try await test_workServiceCreateSessionCannotOvertakeTerminalReservation()
    }),
    ("phase3 Work service createSession: retry conflict and stale are no-write", {
        try await test_workServiceCreateSessionRetryConflictAndStaleAreNoWrite()
    }),
    ("phase3 Work service createSession: authorizing capability is required", {
        try await test_workServiceCreateSessionRequiresAuthorizingCapabilityAndReturnsNoFacts()
    }),
    ("phase3 Work service createSession: terminal reference preserves Work", {
        try await test_workServiceCreateSessionTerminalReferenceDoesNotMutateWork()
    }),
    ("phase3 Work service createSession: terminal and relationship evidence is canonical", {
        try await test_workServiceCreateSessionRejectsNoncanonicalTerminalSeedAndFabricatedRelationship()
    }),
    ("phase3 Work service createSession: descriptor is bounded", {
        try await test_workServiceCreateSessionDescriptorIsBounded()
    }),
]
