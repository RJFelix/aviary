import Foundation
@testable import AviaryCore

private let reducerWork = WorkRef(workHostID: "host-test", workID: "work-test")
private let reducerSession = SessionRef("session-test")
private let reducerWorkJournal = JournalRef.work(reducerWork, journalID: "work-journal")
private let reducerSessionJournal = JournalRef.session(
    reducerSession, journalID: "session-journal", authority: TimelineAuthorityRef("session-service"))

private func reducerEvent(
    _ type: String,
    id: String,
    sequence: Int,
    journal: JournalRef,
    hostSequence: Int? = nil,
    previous: String? = nil,
    session: SessionRef? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    client: ClientRef? = nil,
    sessionAttachment: SessionAttachmentRef? = nil,
    clientAttachment: ClientAttachmentRef? = nil,
    run: RunRef? = nil,
    turn: TurnRef? = nil,
    action: ActionRef? = nil,
    handle: HandleRef? = nil,
    command: CommandRef? = nil,
    causedBy: EventRef? = nil,
    parent: EventRef? = nil,
    conversationParent: EventRef? = nil,
    schemaVersion: Int = TimelineEvent.currentSchemaVersion,
    payloadVersion: Int = 1,
    declaredDomains: Set<TimelineDomain> = [],
    links: [TimelineLink] = [],
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: journal, sequence: sequence, hostSequence: hostSequence,
        command: command, previousEventID: previous,
        causedByEventID: causedBy, parentActivityID: parent, conversationParent: conversationParent,
        session: session, work: work,
        workHost: workHost, client: client, sessionAttachment: sessionAttachment,
        clientAttachment: clientAttachment, run: run, turn: turn, action: action,
        handle: handle, actor: TimelineActor(actorID: "self-test", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
        schemaVersion: schemaVersion, payloadVersion: payloadVersion,
        type: type, declaredDomains: declaredDomains, links: links, payload: payload)
}

func test_timelineReducersLinkSessionsAndWork() throws {
    let sessionAttachment = SessionAttachmentRef("session-attachment")
    let client = ClientRef("client-test")
    let clientAttachment = ClientAttachmentRef("client-attachment")
    let run = RunRef("run-test")
    let turn = TurnRef("turn-test")
    let action = ActionRef("action-test")
    let handle = HandleRef("handle-test")

    let workEvents = [
        reducerEvent(TimelineEventType.workCreated, id: "w1", sequence: 1, journal: reducerWorkJournal,
                     work: reducerWork, workHost: WorkHostRef(reducerWork.workHostID)),
        reducerEvent(TimelineEventType.sessionAttached, id: "w2", sequence: 2, journal: reducerWorkJournal,
                     previous: "w1", session: reducerSession, work: reducerWork,
                     sessionAttachment: sessionAttachment),
        reducerEvent(TimelineEventType.clientAttached, id: "w3", sequence: 3, journal: reducerWorkJournal,
                     previous: "w2", client: client, clientAttachment: clientAttachment,
                     payload: .object(["capabilities": .array(["observe", "control"])])),
        reducerEvent(TimelineEventType.runStarted, id: "w4", sequence: 4, journal: reducerWorkJournal,
                     previous: "w3", run: run),
        reducerEvent(TimelineEventType.turnStarted, id: "w5", sequence: 5, journal: reducerWorkJournal,
                     previous: "w4", run: run, turn: turn),
        reducerEvent(TimelineEventType.actionIntent, id: "w6", sequence: 6, journal: reducerWorkJournal,
                     previous: "w5", action: action, payload: .object(["state": "proposed"])),
        reducerEvent(TimelineEventType.actionStarted, id: "w7", sequence: 7, journal: reducerWorkJournal,
                     previous: "w6", action: action, payload: .object(["state": "running"])),
        reducerEvent(TimelineEventType.handleStarted, id: "w8", sequence: 8, journal: reducerWorkJournal,
                     previous: "w7", handle: handle),
        reducerEvent(TimelineEventType.actionOutcome, id: "w9", sequence: 9, journal: reducerWorkJournal,
                     previous: "w8", action: action, payload: .object([
                         "state": "failed", "failure_kind": "timeout", "retry_safety": "unknown"])),
    ]
    let work = WorkReducer.reduce(workEvents)
    XCTAssertEqual(work.work, reducerWork)
    XCTAssertEqual(work.workHost, WorkHostRef(reducerWork.workHostID))
    XCTAssertEqual(work.attachedSessionIDs, [reducerSession.sessionID])
    XCTAssertEqual(work.attachedClientIDs, [client.clientID])
    XCTAssertEqual(work.activeRun, run)
    XCTAssertEqual(work.activeTurn, turn)
    XCTAssertEqual(work.actions[action.actionID]?.failureKind, .timeout)
    XCTAssertEqual(work.actions[action.actionID]?.retrySafety, .unknown)
    XCTAssertEqual(work.handles[handle.handleID]?.state, "running")
    XCTAssertEqual(work.clientAttachments[clientAttachment.attachmentID]?.capabilities, ["observe", "control"])
    XCTAssertTrue(work.causalOrderValid)

    let sessionEvents = [
        reducerEvent(TimelineEventType.sessionCreated, id: "s1", sequence: 1, journal: reducerSessionJournal,
                     session: reducerSession),
        reducerEvent(TimelineEventType.sessionAttached, id: "s2", sequence: 2, journal: reducerSessionJournal,
                     previous: "s1", session: reducerSession, work: reducerWork,
                     sessionAttachment: sessionAttachment),
        reducerEvent(TimelineEventType.clientAttached, id: "s3", sequence: 3, journal: reducerSessionJournal,
                     previous: "s2", session: reducerSession, client: client,
                     clientAttachment: clientAttachment),
    ]
    let session = SessionReducer.reduce(sessionEvents)
    XCTAssertEqual(session.session, reducerSession)
    XCTAssertEqual(session.attachedWork, reducerWork)
    XCTAssertEqual(session.attachedSessionAttachment, sessionAttachment)
    XCTAssertEqual(session.attachedClientIDs, [client.clientID])
    XCTAssertTrue(session.unknownEvents.isEmpty)
    let cursor = JournalCursor(journal: work.journal!, eventID: "w9", sequence: 9)
    XCTAssertNotNil(SessionAssembler.assemble(session: session, work: work, at: cursor))
    XCTAssertNil(SessionAssembler.assemble(
        session: session, work: work,
        at: JournalCursor(journal: reducerSessionJournal, eventID: "s3", sequence: 3)))
}

func test_timelineReducerTracksCausalOrderAndBoundsLinks() throws {
    let first = reducerEvent(TimelineEventType.workCreated, id: "c1", sequence: 1, journal: reducerWorkJournal,
                             work: reducerWork)
    let second = reducerEvent(TimelineEventType.workCompleted, id: "c2", sequence: 2, journal: reducerWorkJournal,
                              previous: first.eventID, work: reducerWork,
                              causedBy: EventRef(journal: reducerSessionJournal, eventID: "s-source"),
                              parent: EventRef(journal: reducerSessionJournal, eventID: "s-parent"),
                              links: (0..<40).map {
                                  TimelineLink(kind: .supports, target: EventRef(
                                      journal: reducerSessionJournal, eventID: "source-\($0)"))
                              })
    var reducer = WorkReducer()
    reducer.apply(first)
    reducer.apply(second)
    XCTAssertTrue(reducer.snapshot.causalOrderValid)
    XCTAssertEqual(second.links.count, TimelineEvent.maxEvidenceLinks)
    XCTAssertEqual(second.causedByEventID?.journal, reducerSessionJournal)
    XCTAssertEqual(second.parentActivityID?.eventID, "s-parent")

    let outOfOrder = reducerEvent(TimelineEventType.workFailed, id: "c3", sequence: 3, journal: reducerWorkJournal,
                                  previous: "not-c2", work: reducerWork)
    reducer.apply(outOfOrder)
    XCTAssertFalse(reducer.snapshot.causalOrderValid)
    XCTAssertEqual(reducer.snapshot.lifecycle, .completed)
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [outOfOrder])

    let gap = reducerEvent(TimelineEventType.workFailed, id: "c4", sequence: 4, journal: reducerWorkJournal,
                           previous: "c2", work: reducerWork)
    reducer.apply(gap)
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [outOfOrder, gap])
}

func test_timelineReducersPreserveUnknownEventsAndLegacyIdentity() throws {
    let payload: JSONValue = .object([
        "affected_domains": .array(["context", "runtime"]),
        "opaque": .object(["future": "value"]),
    ])
    let created = reducerEvent(TimelineEventType.workCreated, id: "u0", sequence: 1,
                               journal: reducerWorkJournal, work: reducerWork)
    let unknown = reducerEvent("future.event", id: "u1", sequence: 2, journal: reducerWorkJournal,
                               previous: created.eventID, declaredDomains: [.context, .runtime], payload: payload)
    var reducer = WorkReducer()
    reducer.apply(created)
    reducer.apply(unknown)
    XCTAssertFalse(unknown.isKnownType)
    XCTAssertEqual(reducer.snapshot.unknownEvents.count, 1)
    XCTAssertEqual(reducer.snapshot.unknownEvents[0].event, unknown)
    XCTAssertEqual(reducer.snapshot.unknownEvents[0].rawPayload, payload)
    XCTAssertEqual(reducer.snapshot.unknownEvents[0].journalOffset, 1)
    XCTAssertEqual(reducer.snapshot.unknownDomains, [.context, .runtime])
    let futureVersion = reducerEvent(TimelineEventType.workCompleted, id: "u2", sequence: 3,
                                     journal: reducerWorkJournal, previous: unknown.eventID,
                                     schemaVersion: TimelineEvent.currentSchemaVersion + 1,
                                     declaredDomains: [.work])
    reducer.apply(futureVersion)
    XCTAssertEqual(reducer.snapshot.lastEventID, futureVersion.eventID)
    XCTAssertEqual(reducer.snapshot.unknownEvents.count, 2)
    XCTAssertEqual(reducer.snapshot.work, reducerWork)

    let encoded = try JSONEncoder().encode(unknown)
    let decoded = try JSONDecoder().decode(TimelineEvent.self, from: encoded)
    XCTAssertEqual(decoded, unknown)
    XCTAssertEqual(
        TimelineEvent.syntheticLegacyEventID(journal: reducerWorkJournal, offset: 4, rawID: "old"),
        "legacy:\(reducerWorkJournal.stableKey):offset:4:raw:old")

    var sessionReducer = SessionReducer()
    sessionReducer.apply(reducerEvent("future.session", id: "su1", sequence: 1,
                                       journal: reducerSessionJournal, session: reducerSession,
                                       payload: payload))
    XCTAssertEqual(sessionReducer.snapshot.unknownEvents.count, 1)
}

func test_timelineReducersLiveAndColdPrefixEquivalence() throws {
    let action = ActionRef("equivalence-action")
    let events = [
        reducerEvent(TimelineEventType.workCreated, id: "p1", sequence: 1, journal: reducerWorkJournal,
                     work: reducerWork),
        reducerEvent(TimelineEventType.runStarted, id: "p2", sequence: 2, journal: reducerWorkJournal,
                     previous: "p1", work: reducerWork, run: RunRef("equivalence-run")),
        reducerEvent(TimelineEventType.actionIntent, id: "p3", sequence: 3, journal: reducerWorkJournal,
                     previous: "p2", work: reducerWork, action: action,
                     payload: .object(["state": "proposed"])),
        reducerEvent(TimelineEventType.actionStarted, id: "p4", sequence: 4, journal: reducerWorkJournal,
                     previous: "p3", work: reducerWork, action: action,
                     payload: .object(["state": "running"])),
        reducerEvent(TimelineEventType.actionOutcome, id: "p5", sequence: 5, journal: reducerWorkJournal,
                     previous: "p4", work: reducerWork, action: action,
                     payload: .object(["state": "succeeded", "retry_safety": "idempotent"])),
        reducerEvent(TimelineEventType.recoveryCoverage, id: "p6", sequence: 6, journal: reducerWorkJournal,
                     previous: "p5", work: reducerWork, payload: .object([
                         "operation": "cold_resume",
                         "planes": .object(["timeline": "preserved", "runtime_namespace": "lost"]),
                         "caveats": .array(["host was not reattached"]),
                     ])),
    ]
    var live = WorkReducer()
    for event in events { live.apply(event) }
    let cold = WorkReducer.reduce(events)
    XCTAssertEqual(live.snapshot, cold)
    XCTAssertEqual(cold.recovery[0].planes[.externalEffects], .unknown)
    XCTAssertEqual(cold.recovery[0].operation, .coldResume)

    let sessionEvents = [
        reducerEvent(TimelineEventType.sessionCreated, id: "sp1", sequence: 1, journal: reducerSessionJournal,
                     session: reducerSession),
        reducerEvent(TimelineEventType.inputAccepted, id: "sp2", sequence: 2, journal: reducerSessionJournal,
                     previous: "sp1", session: reducerSession,
                     payload: .object(["text": "hello"])),
        reducerEvent(TimelineEventType.contextAssembled, id: "sp3", sequence: 3, journal: reducerSessionJournal,
                     previous: "sp2", session: reducerSession, payload: .object([
                         "components": .array([.object([
                             "component_id": "component-1", "inclusion_id": "inclusion-1",
                             "source": .object(["source_id": "source-1"]),
                             "mode": "history", "delivery_mode": "full",
                             "measured_bytes": 100, "included_bytes": 80, "delivered_bytes": 80,
                             "full_byte_count": 100, "omitted": false,
                         ])]),
                     ])),
    ]
    var liveSession = SessionReducer()
    for event in sessionEvents { liveSession.apply(event) }
    XCTAssertEqual(liveSession.snapshot, SessionReducer.reduce(sessionEvents))
    XCTAssertEqual(liveSession.snapshot.contextComponents[0].componentID, "component-1")
    XCTAssertEqual(liveSession.snapshot.contextComponents[0].inclusionID, "inclusion-1")
}

func test_timelineSessionSupportsManyAttachmentsAndDetachIsolation() throws {
    let secondWork = WorkRef(workHostID: "host-test", workID: "work-two")
    let secondJournal = JournalRef.work(secondWork, journalID: "work-two-journal")
    let firstAttachment = SessionAttachmentRef("attachment-one")
    let secondAttachment = SessionAttachmentRef("attachment-two")
    let events = [
        reducerEvent(TimelineEventType.sessionCreated, id: "m1", sequence: 1, journal: reducerSessionJournal,
                     session: reducerSession),
        reducerEvent(TimelineEventType.sessionAttached, id: "m2", sequence: 2, journal: reducerSessionJournal,
                     previous: "m1", session: reducerSession, work: reducerWork,
                     sessionAttachment: firstAttachment),
        reducerEvent(TimelineEventType.sessionAttached, id: "m3", sequence: 3, journal: reducerSessionJournal,
                     previous: "m2", session: reducerSession, work: secondWork,
                     sessionAttachment: secondAttachment),
        reducerEvent(TimelineEventType.sessionAttachmentCapabilityChanged, id: "m4", sequence: 4,
                     journal: reducerSessionJournal, previous: "m3", session: reducerSession,
                     sessionAttachment: secondAttachment,
                     payload: .object(["capabilities": .array(["observe"])])),
        reducerEvent(TimelineEventType.sessionDetached, id: "m5", sequence: 5, journal: reducerSessionJournal,
                     previous: "m4", session: reducerSession, sessionAttachment: firstAttachment),
    ]
    let snapshot = SessionReducer.reduce(events)
    XCTAssertEqual(snapshot.attachments.count, 2)
    XCTAssertFalse(snapshot.attachments[firstAttachment.attachmentID]!.isAttached)
    XCTAssertTrue(snapshot.attachments[secondAttachment.attachmentID]!.isAttached)
    XCTAssertEqual(snapshot.attachments[secondAttachment.attachmentID]!.capabilities, ["observe"])
    XCTAssertEqual(snapshot.attachedWork, secondWork)

    let firstWork = WorkReducer.reduce([reducerEvent(
        TimelineEventType.workCreated, id: "mw1", sequence: 1, journal: reducerWorkJournal, work: reducerWork)])
    let otherWork = WorkReducer.reduce([reducerEvent(
        TimelineEventType.workCreated, id: "mw2", sequence: 1, journal: secondJournal, work: secondWork)])
    let assembled = SessionAssembler.assemble(
        session: snapshot, works: [firstWork, otherWork],
        at: [secondAttachment.attachmentID: JournalCursor(
            journal: secondJournal, eventID: "mw2", sequence: 1)])
    XCTAssertNotNil(assembled)
}

func test_timelineJournalReaderPreservesBytesAndLegacyTailSemantics() throws {
    let first = reducerEvent(TimelineEventType.workCreated, id: "r1", sequence: 1,
                             journal: reducerWorkJournal, work: reducerWork)
    let firstBytes = try JSONEncoder().encode(first) + Data([0x0A])
    let legacyBytes = Data("{\"id\":\"legacy-1\",\"type\":\"legacy.entry\"}\n".utf8)
    let malformed = Data("{\"schema_version\":2}\n".utf8)
    let trailing = Data("later\n".utf8)
    var journalBytes = firstBytes
    journalBytes.append(contentsOf: legacyBytes)
    journalBytes.append(contentsOf: malformed)
    journalBytes.append(contentsOf: trailing)
    let result = TimelineJournalReader.read(
        journalBytes,
        journal: reducerWorkJournal, actor: TimelineActor(actorID: "reader", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    XCTAssertEqual(result.records.count, 2)
    XCTAssertEqual(result.records[0].rawLineBytes, firstBytes)
    XCTAssertEqual(result.records[1].legacyRawID, "legacy-1")
    XCTAssertEqual(result.records[1].event.provenance, .legacyAdapted)
    XCTAssertEqual(result.records[1].event.previousEventID, first.eventID)
    XCTAssertEqual(result.records[1].event.hostRecordedAt, Date(timeIntervalSince1970: 1))
    XCTAssertNotNil(result.quarantinedSuffix)
    XCTAssertNil(result.truncatedTail)

    var tailBytes = firstBytes
    tailBytes.append(contentsOf: Data("unterminated".utf8))
    let tail = TimelineJournalReader.read(
        tailBytes, journal: reducerWorkJournal, actor: TimelineActor(actorID: "reader", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    XCTAssertEqual(tail.records.count, 1)
    XCTAssertEqual(tail.truncatedTail?.rawBytes, Data("unterminated".utf8))
    XCTAssertNil(tail.quarantinedSuffix)

    var incremental = TimelineJournalReaderState(
        journal: reducerWorkJournal, actor: TimelineActor(actorID: "reader", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    let split = firstBytes.count / 2
    let firstChunk = incremental.append(firstBytes.prefix(split))
    XCTAssertTrue(firstChunk.records.isEmpty)
    let secondChunk = incremental.append(firstBytes.dropFirst(split), final: true)
    XCTAssertEqual(secondChunk.records.count, 1)
    XCTAssertEqual(secondChunk.records[0].byteStart, 0)
    XCTAssertEqual(secondChunk.records[0].rawLineBytes, firstBytes)

    var incrementalCorrupt = TimelineJournalReaderState(
        journal: reducerWorkJournal, actor: TimelineActor(actorID: "reader", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    let corruptPrefix = firstBytes + malformed
    let corruptResult = incrementalCorrupt.append(corruptPrefix)
    XCTAssertEqual(corruptResult.records.count, 1)
    XCTAssertEqual(corruptResult.records[0].byteEnd, firstBytes.count)
    XCTAssertEqual(corruptResult.quarantinedSuffix?.byteStart, firstBytes.count)
    // A latched suffix remains addressable, while the committed prefix cursor is not replayed.
    let stillCorrupt = incrementalCorrupt.append(Data("new\n".utf8))
    XCTAssertTrue(stillCorrupt.records.isEmpty)
    XCTAssertEqual(stillCorrupt.quarantinedSuffix?.byteStart, firstBytes.count)

    let wholeLegacy = TimelineJournalReader.read(
        firstBytes + legacyBytes, journal: reducerWorkJournal,
        actor: TimelineActor(actorID: "reader", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    var pagedLegacy = TimelineJournalReaderState(
        journal: reducerWorkJournal, actor: TimelineActor(actorID: "reader", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    var firstPage = firstBytes
    firstPage.append(contentsOf: legacyBytes.prefix(5))
    _ = pagedLegacy.append(firstPage)
    let pagedLegacyResult = pagedLegacy.append(Data(legacyBytes.dropFirst(5)), final: true)
    XCTAssertEqual(pagedLegacyResult.records.first?.event.eventID, wholeLegacy.records.last?.event.eventID)
    XCTAssertEqual(pagedLegacyResult.records.first?.byteStart, wholeLegacy.records.last?.byteStart)
}

func test_timelineValidatesActionLifecycleContextAndSemanticTip() throws {
    let retained = ContextComponent(
        componentID: "component-retained", inclusionID: "inclusion-retained", sourceID: "source",
        sourceProvenance: EventRef(journal: reducerSessionJournal, eventID: "source-event"),
        mode: .history, deliveryMode: .truncated, measuredBytes: 200, includedBytes: 80,
        deliveredBytes: 80, fullByteCount: 200,
        bodyReference: TimelineBodyReference(
            authority: reducerSessionJournal, referenceID: "body", byteCount: 200,
            digest: "sha256:digest"),
        digest: "sha256:digest")
    XCTAssertEqual(retained.inclusionID, "inclusion-retained")
    XCTAssertEqual(retained.bodyReference?.authority, reducerSessionJournal)
    XCTAssertEqual(retained.source.provenance?.journal, reducerSessionJournal)
    XCTAssertEqual(try JSONDecoder().decode(ContextComponent.self, from: JSONEncoder().encode(retained)), retained)
    let retainedJSON = JSONValue.parse(try JSONEncoder().encode(retained))!
    XCTAssertEqual(
        try JSONDecoder().decode(ContextComponent.self, from: JSONEncoder().encode(retainedJSON)),
        retained)
    var contextReducer = SessionReducer()
    contextReducer.apply(reducerEvent(TimelineEventType.sessionCreated, id: "cx1", sequence: 1,
                                      journal: reducerSessionJournal, session: reducerSession))
    contextReducer.apply(reducerEvent(TimelineEventType.contextAssembled, id: "cx2", sequence: 2,
                                      journal: reducerSessionJournal, previous: "cx1", session: reducerSession,
                                      payload: .object(["components": .array([retainedJSON])])))
    XCTAssertEqual(contextReducer.snapshot.contextComponents, [retained])

    let action = ActionRef("outstanding")
    let invalidStart = reducerEvent(TimelineEventType.actionStarted, id: "v1", sequence: 1,
                                    journal: reducerWorkJournal, action: action,
                                    payload: .object(["state": "running"]))
    let intent = reducerEvent(TimelineEventType.actionIntent, id: "v2", sequence: 1,
                              journal: reducerWorkJournal, action: action,
                              payload: .object(["state": "proposed"]))
    var invalidWork = WorkReducer()
    invalidWork.apply(invalidStart)
    XCTAssertEqual(invalidWork.snapshot.quarantinedEvents, [invalidStart])
    var work = WorkReducer()
    work.apply(intent)
    let start = reducerEvent(TimelineEventType.actionStarted, id: "v3", sequence: 2,
                             journal: reducerWorkJournal, previous: "v2", action: action,
                             payload: .object(["state": "running"]))
    work.apply(start)
    let completed = reducerEvent(TimelineEventType.workCompleted, id: "v4", sequence: 3,
                                 journal: reducerWorkJournal, previous: "v3", work: reducerWork)
    work.apply(completed)
    XCTAssertTrue(work.snapshot.activeActionIDs.contains(action.actionID))
    XCTAssertEqual(work.snapshot.actions[action.actionID]?.state, .running)
    let incompleteOutcome = reducerEvent(TimelineEventType.actionOutcome, id: "v5", sequence: 4,
                                         journal: reducerWorkJournal, previous: "v4", action: action,
                                         payload: .object(["state": "succeeded"]))
    let validOutcome = reducerEvent(TimelineEventType.actionOutcome, id: "v6", sequence: 5,
                                    journal: reducerWorkJournal, previous: "v5", action: action,
                                    payload: .object(["state": "succeeded", "retry_safety": "idempotent"]))
    work.apply(incompleteOutcome)
    work.apply(validOutcome)
    XCTAssertEqual(work.snapshot.actions[action.actionID]?.state, .succeeded)
    XCTAssertTrue(work.snapshot.structuralIntegrityValid)
    var failedRun = WorkReducer()
    failedRun.apply(reducerEvent(TimelineEventType.workFailed, id: "vf", sequence: 1,
                                 journal: reducerWorkJournal, work: reducerWork))
    XCTAssertEqual(failedRun.snapshot.execution, .failed)
    XCTAssertEqual(failedRun.snapshot.lifecycle, .active)

    let tipRoot = reducerEvent(TimelineEventType.messageCommitted, id: "v5", sequence: 1,
                               journal: reducerSessionJournal, session: reducerSession,
                               payload: .object(["role": "user", "text": "tip root"]))
    let tip = reducerEvent(TimelineEventType.sessionTipSelected, id: "v6", sequence: 2,
                           journal: reducerSessionJournal, previous: "v5", session: reducerSession,
                           conversationParent: EventRef(journal: reducerSessionJournal, eventID: tipRoot.eventID))
    let malformedContext = reducerEvent(TimelineEventType.contextAssembled, id: "v7", sequence: 3,
                                        journal: reducerSessionJournal, previous: "v6", session: reducerSession,
                                        payload: .object(["components": .array([.object(["bad": true])])]))
    var session = SessionReducer()
    session.apply(tipRoot)
    session.apply(tip)
    session.apply(malformedContext)
    XCTAssertEqual(session.snapshot.quarantinedEvents, [malformedContext])
    XCTAssertEqual(session.snapshot.semanticTip, tip.conversationParent)
    let afterSemanticError = reducerEvent(TimelineEventType.sessionAttention, id: "v8", sequence: 4,
                                          journal: reducerSessionJournal, previous: "v7", session: reducerSession,
                                          payload: .object(["attention": "input"]))
    session.apply(afterSemanticError)
    XCTAssertTrue(session.snapshot.structuralIntegrityValid)
    XCTAssertFalse(session.snapshot.semanticProjectionValid)
    XCTAssertEqual(session.snapshot.attention, .input)

    var branchSession = SessionReducer()
    let root = reducerEvent(TimelineEventType.messageCommitted, id: "b1", sequence: 1,
                            journal: reducerSessionJournal, session: reducerSession,
                            payload: .object(["role": "user", "text": "root"]))
    let child = reducerEvent(TimelineEventType.messageCommitted, id: "b2", sequence: 2,
                             journal: reducerSessionJournal, previous: "b1", session: reducerSession,
                             conversationParent: EventRef(journal: reducerSessionJournal, eventID: root.eventID),
                             payload: .object(["role": "assistant", "text": "child"]))
    let select = reducerEvent(TimelineEventType.sessionTipSelected, id: "b3", sequence: 3,
                              journal: reducerSessionJournal, previous: "b2", session: reducerSession,
                              conversationParent: EventRef(journal: reducerSessionJournal, eventID: child.eventID))
    branchSession.apply(root)
    branchSession.apply(child)
    branchSession.apply(select)
    XCTAssertEqual(branchSession.snapshot.messages.map(\.text), ["root", "child"])
}

func test_timelineProjectsCommandReceiptsAndRejectsHostReordering() throws {
    let command = CommandRef(commandID: "command-1", client: ClientRef("client"),
                             causalCursor: JournalCursor(journal: reducerWorkJournal, sequence: 0))
    let accepted = reducerEvent(TimelineEventType.commandAccepted, id: "q1", sequence: 1,
                                journal: reducerWorkJournal, hostSequence: 10, client: command.client,
                                command: command)
    let delivered = reducerEvent(TimelineEventType.commandDelivered, id: "q2", sequence: 2,
                                 journal: reducerWorkJournal, hostSequence: 11, previous: "q1", client: command.client,
                                 command: command,
                                 causedBy: EventRef(journal: reducerWorkJournal, eventID: accepted.eventID))
    let reordered = reducerEvent(TimelineEventType.commandRejected, id: "q3", sequence: 3,
                                 journal: reducerWorkJournal, hostSequence: 10, previous: "q2", client: command.client,
                                 command: command)
    var reducer = WorkReducer()
    reducer.apply(accepted)
    reducer.apply(delivered)
    XCTAssertEqual(reducer.snapshot.commands[command.commandID]?.state, .delivered)
    reducer.apply(reordered)
    XCTAssertFalse(reducer.snapshot.structuralIntegrityValid)
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [reordered])
}

func test_timelineJournalAuthorityAndCommandReceiptProvenance() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let encoded = try encoder.encode(reducerWorkJournal)
    XCTAssertEqual(try decoder.decode(JournalRef.self, from: encoded), reducerWorkJournal)

    let mismatchedOwner = Data(#"{"authority":{"authorityID":"service"},"kind":"session","journal_id":"j","owner":{"kind":"work","work_host_id":"host-test","work_id":"work-test"}}"#.utf8)
    do {
        _ = try decoder.decode(JournalRef.self, from: mismatchedOwner)
        XCTFail("owner kind mismatch should be rejected")
    } catch {}
    let mismatchedWorkAuthority = Data(#"{"authority":{"authorityID":"other-host"},"kind":"work","journal_id":"j","owner":{"kind":"work","work_host_id":"host-test","work_id":"work-test"}}"#.utf8)
    do {
        _ = try decoder.decode(JournalRef.self, from: mismatchedWorkAuthority)
        XCTFail("work authority mismatch should be rejected")
    } catch {}

    let cursor = JournalCursor(journal: reducerWorkJournal, sequence: 0)
    let command = CommandRef(commandID: "provenance-command", client: ClientRef("client-a"), causalCursor: cursor)
    let accepted = reducerEvent(TimelineEventType.commandAccepted, id: "p1", sequence: 1,
                                journal: reducerWorkJournal, hostSequence: 20, client: command.client,
                                command: command)
    let delivered = reducerEvent(TimelineEventType.commandDelivered, id: "p2", sequence: 2,
                                 journal: reducerWorkJournal, hostSequence: 21, previous: "p1", client: command.client,
                                 command: command,
                                 causedBy: EventRef(journal: reducerWorkJournal, eventID: accepted.eventID))
    var reducer = WorkReducer()
    reducer.apply(accepted)
    reducer.apply(delivered)
    let receipt = try XCTUnwrap(reducer.snapshot.commands[command.commandID])
    XCTAssertEqual(receipt.acceptanceHostSequence, 20)
    XCTAssertEqual(receipt.deliveryHostSequence, 21)

    let duplicateDelivery = reducerEvent(TimelineEventType.commandDelivered, id: "p2-retry", sequence: 3,
                                         journal: reducerWorkJournal, hostSequence: 22, previous: "p2",
                                         client: command.client, command: command,
                                         causedBy: EventRef(journal: reducerWorkJournal, eventID: accepted.eventID))
    reducer.apply(duplicateDelivery)
    XCTAssertEqual(reducer.snapshot.commands[command.commandID]?.deliveryHostSequence, 21)

    let conflicting = CommandRef(commandID: command.commandID, client: ClientRef("client-b"), causalCursor: cursor)
    let conflictEvent = reducerEvent(TimelineEventType.commandAccepted, id: "p3", sequence: 4,
                                     journal: reducerWorkJournal, hostSequence: 23, previous: "p2-retry",
                                     client: conflicting.client, command: conflicting)
    reducer.apply(conflictEvent)
    XCTAssertFalse(reducer.snapshot.semanticProjectionValid)
    XCTAssertEqual(reducer.snapshot.commands[command.commandID]?.acceptanceHostSequence, 20)
}

func test_timelineCommandReceiptsRequireExactCausalReferencesAndRetainThem() throws {
    let root = reducerEvent(TimelineEventType.workCreated, id: "causal-root", sequence: 1,
                            journal: reducerWorkJournal, work: reducerWork,
                            workHost: WorkHostRef(reducerWork.workHostID))
    let rootRef = EventRef(journal: reducerWorkJournal, eventID: root.eventID)
    let cursor = JournalCursor(journal: reducerWorkJournal, eventID: root.eventID, sequence: 1)
    let command = CommandRef(commandID: "causal-command", client: ClientRef("causal-client"),
                             causalCursor: cursor)
    let accepted = reducerEvent(TimelineEventType.commandAccepted, id: "causal-accepted", sequence: 2,
                                journal: reducerWorkJournal, hostSequence: 10, previous: root.eventID,
                                client: command.client, command: command, causedBy: rootRef)

    var prefixReducer = WorkReducer()
    prefixReducer.apply(root)
    prefixReducer.apply(accepted)
    XCTAssertTrue(prefixReducer.snapshot.semanticProjectionValid)
    let acceptance = try XCTUnwrap(prefixReducer.snapshot.commands[command.commandID])
    XCTAssertEqual(acceptance.acceptanceEventRef, EventRef(
        journal: reducerWorkJournal, eventID: accepted.eventID))
    XCTAssertNil(acceptance.deliveryEventRef)

    // The acceptance reference survives reduction from a previously materialized prefix.
    let delivered = reducerEvent(TimelineEventType.commandDelivered, id: "causal-delivered", sequence: 3,
                                 journal: reducerWorkJournal, hostSequence: 11,
                                 previous: accepted.eventID, client: command.client,
                                 command: command, causedBy: acceptance.acceptanceEventRef)
    let incrementallyReduced = WorkReducer.reduce([delivered], initial: prefixReducer.snapshot)
    XCTAssertTrue(incrementallyReduced.semanticProjectionValid)
    XCTAssertEqual(incrementallyReduced.commands[command.commandID]?.state, .delivered)
    XCTAssertEqual(incrementallyReduced.commands[command.commandID]?.acceptanceEventRef,
                   acceptance.acceptanceEventRef)
    XCTAssertEqual(incrementallyReduced.commands[command.commandID]?.deliveryEventRef,
                   EventRef(journal: reducerWorkJournal, eventID: delivered.eventID))

    // Every terminal delivery outcome must name that same durable acceptance event.
    let outcomes: [(String, CommandDeliveryState)] = [
        (TimelineEventType.commandDelivered, .delivered),
        (TimelineEventType.commandNotDelivered, .notDelivered),
        (TimelineEventType.commandDeliveryIndeterminate, .indeterminate),
    ]
    for (index, outcome) in outcomes.enumerated() {
        var reducer = WorkReducer(snapshot: prefixReducer.snapshot)
        let event = reducerEvent(outcome.0, id: "causal-outcome-\(index)", sequence: 3,
                                 journal: reducerWorkJournal, hostSequence: 20 + index,
                                 previous: accepted.eventID, client: command.client,
                                 command: command, causedBy: acceptance.acceptanceEventRef)
        reducer.apply(event)
        XCTAssertTrue(reducer.snapshot.semanticProjectionValid)
        XCTAssertEqual(reducer.snapshot.commands[command.commandID]?.state, outcome.1)
        XCTAssertEqual(reducer.snapshot.commands[command.commandID]?.deliveryEventRef,
                       EventRef(journal: reducerWorkJournal, eventID: event.eventID))
    }

    // A rejected admission is also required to describe exactly the cursor it observed.
    let rejectedCommand = CommandRef(commandID: "causal-rejected", client: command.client,
                                      causalCursor: cursor)
    let rejected = reducerEvent(TimelineEventType.commandRejected, id: "causal-rejected-receipt",
                                sequence: 2, journal: reducerWorkJournal, hostSequence: 30,
                                previous: root.eventID, client: rejectedCommand.client,
                                command: rejectedCommand, causedBy: rootRef)
    var rejectedReducer = WorkReducer()
    rejectedReducer.apply(root)
    rejectedReducer.apply(rejected)
    XCTAssertTrue(rejectedReducer.snapshot.semanticProjectionValid)
    XCTAssertEqual(rejectedReducer.snapshot.commands[rejectedCommand.commandID]?.state, .rejected)
    XCTAssertEqual(rejectedReducer.snapshot.commands[rejectedCommand.commandID]?.acceptanceEventRef,
                   EventRef(journal: reducerWorkJournal, eventID: rejected.eventID))

    let badCauses: [(String, EventRef?)] = [
        ("nil", nil),
        ("wrong-event", EventRef(journal: reducerWorkJournal, eventID: "not-the-root")),
        ("wrong-journal", EventRef(journal: reducerSessionJournal, eventID: root.eventID)),
    ]
    for admissionType in [TimelineEventType.commandAccepted, TimelineEventType.commandRejected] {
        for (index, badCause) in badCauses.enumerated() {
            let badCommand = CommandRef(
                commandID: "bad-\(admissionType)-\(index)", client: command.client,
                causalCursor: cursor)
            let badEvent = reducerEvent(
                admissionType, id: "bad-admission-\(admissionType)-\(index)", sequence: 2,
                journal: reducerWorkJournal, hostSequence: 40 + index,
                previous: root.eventID, client: badCommand.client, command: badCommand,
                causedBy: badCause.1)
            var reducer = WorkReducer()
            reducer.apply(root)
            reducer.apply(badEvent)
            XCTAssertFalse(reducer.snapshot.semanticProjectionValid,
                           "bad \(admissionType) cause \(badCause.0) must be quarantined")
            XCTAssertNil(reducer.snapshot.commands[badCommand.commandID])
        }
    }

    // A cursor with no durable event identity permits no cause, but never an invented one.
    let nilCursor = JournalCursor(journal: reducerWorkJournal, sequence: 0)
    let nilCursorCommand = CommandRef(commandID: "nil-cursor-command", client: command.client,
                                      causalCursor: nilCursor)
    let nilCursorAccepted = reducerEvent(
        TimelineEventType.commandAccepted, id: "nil-cursor-accepted", sequence: 1,
        journal: reducerWorkJournal, hostSequence: 50, client: nilCursorCommand.client,
        command: nilCursorCommand)
    var nilCursorReducer = WorkReducer()
    nilCursorReducer.apply(nilCursorAccepted)
    XCTAssertTrue(nilCursorReducer.snapshot.semanticProjectionValid)
    XCTAssertEqual(nilCursorReducer.snapshot.commands[nilCursorCommand.commandID]?.state, .accepted)

    // Missing, wrong-event, and wrong-journal delivery causes all fail closed, including when
    // the reducer starts from a snapshot that already contains the valid acceptance.
    for (index, badCause) in badCauses.enumerated() {
        var reducer = WorkReducer(snapshot: prefixReducer.snapshot)
        let badDelivery = reducerEvent(
            TimelineEventType.commandDelivered, id: "bad-delivery-\(index)", sequence: 3,
            journal: reducerWorkJournal, hostSequence: 60 + index,
            previous: accepted.eventID, client: command.client, command: command,
            causedBy: badCause.1)
        reducer.apply(badDelivery)
        XCTAssertFalse(reducer.snapshot.semanticProjectionValid,
                       "bad delivery cause \(badCause.0) must be quarantined")
        XCTAssertEqual(reducer.snapshot.commands[command.commandID]?.state, .accepted)
        XCTAssertNil(reducer.snapshot.commands[command.commandID]?.deliveryEventRef)
    }
}

func test_timelineWorkTerminalLifecycleIsImmutableAndRequiresQuiescence() {
    let created = reducerEvent(TimelineEventType.workCreated, id: "l1", sequence: 1,
                               journal: reducerWorkJournal, work: reducerWork,
                               workHost: WorkHostRef(reducerWork.workHostID))
    let completed = reducerEvent(TimelineEventType.workCompleted, id: "l2", sequence: 2,
                                 journal: reducerWorkJournal, previous: "l1")
    let destroyed = reducerEvent(TimelineEventType.workDestroyed, id: "l3", sequence: 3,
                                 journal: reducerWorkJournal, previous: "l2")
    let reactivated = reducerEvent(TimelineEventType.workCreated, id: "l4", sequence: 4,
                                   journal: reducerWorkJournal, previous: "l3")
    var reducer = WorkReducer()
    reducer.apply(created)
    reducer.apply(completed)
    XCTAssertEqual(reducer.snapshot.lifecycle, .completed)
    reducer.apply(destroyed)
    reducer.apply(reactivated)
    XCTAssertEqual(reducer.snapshot.lifecycle, .completed)
    XCTAssertFalse(reducer.snapshot.semanticProjectionValid)
}
