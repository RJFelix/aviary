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
    clientTimestamp: Date? = nil,
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
        clientTimestamp: clientTimestamp,
        schemaVersion: schemaVersion, payloadVersion: payloadVersion,
        type: type, declaredDomains: declaredDomains, links: links, payload: payload)
}

private func reducerJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

func test_timelineReducersLinkSessionsAndWork() throws {
    let sessionAttachment = SessionAttachmentRef("session-attachment")
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
        reducerEvent(TimelineEventType.runStarted, id: "w3", sequence: 3, journal: reducerWorkJournal,
                     previous: "w2", session: reducerSession,
                     sessionAttachment: sessionAttachment, run: run),
        reducerEvent(TimelineEventType.turnStarted, id: "w4", sequence: 4, journal: reducerWorkJournal,
                     previous: "w3", run: run, turn: turn),
        reducerEvent(TimelineEventType.actionIntent, id: "w5", sequence: 5, journal: reducerWorkJournal,
                     previous: "w4", action: action, payload: .object([
                         "state": "proposed", "kind": "python", "intent": "run fixture action"
                     ])),
        reducerEvent(TimelineEventType.actionStarted, id: "w6", sequence: 6, journal: reducerWorkJournal,
                     previous: "w5", action: action, payload: .object([
                         "state": "running", "kind": "python"
                     ])),
        reducerEvent(TimelineEventType.handleStarted, id: "w7", sequence: 7, journal: reducerWorkJournal,
                     previous: "w6", run: run, handle: handle,
                     payload: .object(["state": .string("running")])),
        reducerEvent(TimelineEventType.actionOutcome, id: "w8", sequence: 8, journal: reducerWorkJournal,
                     previous: "w7", action: action, payload: .object([
                         "state": "failed", "failure_kind": "timeout", "retry_safety": "unknown"])),
    ]
    let work = WorkReducer.reduce(workEvents)
    XCTAssertEqual(work.work, reducerWork)
    XCTAssertEqual(work.workHost, WorkHostRef(reducerWork.workHostID))
    XCTAssertEqual(work.attachedSessionIDs, [reducerSession.sessionID])
    XCTAssertEqual(work.activeRun, run)
    XCTAssertEqual(work.activeTurn, turn)
    XCTAssertEqual(work.actions[action.actionID]?.failureKind, .timeout)
    XCTAssertEqual(work.actions[action.actionID]?.retrySafety, .unknown)
    XCTAssertEqual(work.handles[handle.handleID]?.state, "running")
    XCTAssertTrue(work.causalOrderValid)

    let sessionEvents = [
        reducerEvent(TimelineEventType.sessionCreated, id: "s1", sequence: 1, journal: reducerSessionJournal,
                     session: reducerSession),
        reducerEvent(TimelineEventType.sessionAttached, id: "s2", sequence: 2, journal: reducerSessionJournal,
                     previous: "s1", session: reducerSession, work: reducerWork,
                     sessionAttachment: sessionAttachment),
    ]
    let session = SessionReducer.reduce(sessionEvents)
    XCTAssertEqual(session.session, reducerSession)
    XCTAssertEqual(session.attachedWork, reducerWork)
    XCTAssertEqual(session.attachedSessionAttachment, sessionAttachment)
    XCTAssertTrue(session.unknownEvents.isEmpty)
    let cursor = JournalCursor(journal: work.journal!, eventID: "w8", sequence: 8)
    XCTAssertNotNil(SessionAssembler.assemble(session: session, work: work, at: cursor))
    XCTAssertNil(SessionAssembler.assemble(
        session: session, work: work,
        at: JournalCursor(journal: reducerSessionJournal, eventID: "s2", sequence: 2)))
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
    let attachment = SessionAttachmentRef("equivalence-attachment")
    let run = RunRef("equivalence-run")
    let events = [
        reducerEvent(TimelineEventType.workCreated, id: "p1", sequence: 1, journal: reducerWorkJournal,
                     work: reducerWork),
        reducerEvent(TimelineEventType.sessionAttached, id: "p2", sequence: 2,
                     journal: reducerWorkJournal, previous: "p1", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment),
        reducerEvent(TimelineEventType.runStarted, id: "p3", sequence: 3, journal: reducerWorkJournal,
                     previous: "p2", session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run),
        reducerEvent(TimelineEventType.actionIntent, id: "p4", sequence: 4, journal: reducerWorkJournal,
                     previous: "p3", work: reducerWork, action: action,
                     payload: .object([
                         "state": "proposed", "kind": "python", "intent": "equivalence action"
                     ])),
        reducerEvent(TimelineEventType.actionStarted, id: "p5", sequence: 5, journal: reducerWorkJournal,
                     previous: "p4", work: reducerWork, action: action,
                     payload: .object(["state": "running", "kind": "python"])),
        reducerEvent(TimelineEventType.actionOutcome, id: "p6", sequence: 6, journal: reducerWorkJournal,
                     previous: "p5", work: reducerWork, action: action,
                     payload: .object(["state": "succeeded", "retry_safety": "idempotent"])),
        reducerEvent(TimelineEventType.recoveryCoverage, id: "p7", sequence: 7,
                     journal: reducerWorkJournal, previous: "p6", session: reducerSession,
                     work: reducerWork, workHost: WorkHostRef(reducerWork.workHostID),
                     sessionAttachment: attachment, run: run, payload: .object([
                         "operation": "cold_resume",
                         "work_journal": reducerJSON(reducerWorkJournal),
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

func test_timelineReducersRejectAttachmentAndRunIdentityReuse() throws {
    let attachment = SessionAttachmentRef("identity-attachment")
    let runA = RunRef("identity-run-a")
    let runB = RunRef("identity-run-b")
    let coveragePayload: JSONValue = .object([
        "operation": "cold_resume",
        "work_journal": reducerJSON(reducerWorkJournal),
        "planes": .object(Dictionary(uniqueKeysWithValues: RecoveryPlane.allCases.map {
            ($0.rawValue, JSONValue.string(RecoveryCoverageStatus.preserved.rawValue))
        }))
    ])
    let workEvents = [
        reducerEvent(TimelineEventType.workCreated, id: "i1", sequence: 1,
                     journal: reducerWorkJournal, work: reducerWork),
        reducerEvent(TimelineEventType.sessionAttached, id: "i2", sequence: 2,
                     journal: reducerWorkJournal, previous: "i1", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment),
        reducerEvent(TimelineEventType.sessionAttached, id: "i3", sequence: 3,
                     journal: reducerWorkJournal, previous: "i2", session: SessionRef("other-session"),
                     work: reducerWork, sessionAttachment: attachment),
        reducerEvent(TimelineEventType.runStarted, id: "i4", sequence: 4,
                     journal: reducerWorkJournal, previous: "i3", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment, run: runA),
        reducerEvent(TimelineEventType.runStarted, id: "i5", sequence: 5,
                     journal: reducerWorkJournal, previous: "i4", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment, run: runB),
        reducerEvent(TimelineEventType.runFinished, id: "i6", sequence: 6,
                     journal: reducerWorkJournal, previous: "i5", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment, run: runB),
        reducerEvent(TimelineEventType.runFinished, id: "i7", sequence: 7,
                     journal: reducerWorkJournal, previous: "i6", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment, run: runA),
        reducerEvent(TimelineEventType.runStarted, id: "i8", sequence: 8,
                     journal: reducerWorkJournal, previous: "i7", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment, run: runA),
        reducerEvent(TimelineEventType.sessionDetached, id: "i9", sequence: 9,
                     journal: reducerWorkJournal, previous: "i8", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment),
        reducerEvent(TimelineEventType.recoveryCoverage, id: "i10", sequence: 10,
                     journal: reducerWorkJournal, previous: "i9", session: reducerSession,
                     work: reducerWork, workHost: WorkHostRef(reducerWork.workHostID),
                     sessionAttachment: attachment, run: runA, payload: coveragePayload),
    ]
    let work = WorkReducer.reduce(workEvents)
    XCTAssertEqual(work.sessionAttachments[attachment.attachmentID]?.session, reducerSession)
    XCTAssertNil(work.activeRun)
    XCTAssertEqual(work.observedRunIDs, [runA.runID])
    XCTAssertTrue(work.recovery.isEmpty)
    XCTAssertEqual(work.quarantinedEvents.count, 5)

    let otherWork = WorkRef(workHostID: reducerWork.workHostID, workID: "other-work")
    let sessionEvents = [
        reducerEvent(TimelineEventType.sessionCreated, id: "j1", sequence: 1,
                     journal: reducerSessionJournal, session: reducerSession),
        reducerEvent(TimelineEventType.sessionAttached, id: "j2", sequence: 2,
                     journal: reducerSessionJournal, previous: "j1", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment),
        reducerEvent(TimelineEventType.sessionAttached, id: "j3", sequence: 3,
                     journal: reducerSessionJournal, previous: "j2", session: reducerSession,
                     work: otherWork, sessionAttachment: attachment),
        reducerEvent(TimelineEventType.sessionDetached, id: "j4", sequence: 4,
                     journal: reducerSessionJournal, previous: "j3", session: reducerSession,
                     work: reducerWork, sessionAttachment: attachment),
        reducerEvent(TimelineEventType.recoveryCoverage, id: "j5", sequence: 5,
                     journal: reducerSessionJournal, previous: "j4", session: reducerSession,
                     work: reducerWork, workHost: WorkHostRef(reducerWork.workHostID),
                     sessionAttachment: attachment, run: runA, payload: coveragePayload),
    ]
    let session = SessionReducer.reduce(sessionEvents)
    XCTAssertEqual(session.attachments[attachment.attachmentID]?.work, reducerWork)
    XCTAssertTrue(session.recovery.isEmpty)
    XCTAssertEqual(session.quarantinedEvents.count, 2)
}

func test_timelineReducersRejectEmptyAttachmentIdentities() throws {
    let emptySession = SessionRef("")
    let emptySessionAttachment = SessionAttachmentRef("")
    let workEvents = [
        reducerEvent(TimelineEventType.workCreated, id: "empty-w1", sequence: 1,
                     journal: reducerWorkJournal, work: reducerWork),
        reducerEvent(TimelineEventType.sessionAttached, id: "empty-w2", sequence: 2,
                     journal: reducerWorkJournal, previous: "empty-w1", session: emptySession,
                     work: reducerWork, sessionAttachment: SessionAttachmentRef("valid")),
        reducerEvent(TimelineEventType.sessionAttached, id: "empty-w3", sequence: 3,
                     journal: reducerWorkJournal, previous: "empty-w2", session: reducerSession,
                     work: reducerWork, sessionAttachment: emptySessionAttachment),
    ]
    let work = WorkReducer.reduce(workEvents)
    XCTAssertTrue(work.sessionAttachments.isEmpty)
    XCTAssertEqual(work.quarantinedEvents.count, 2)

    let sessionEvents = [
        reducerEvent(TimelineEventType.sessionCreated, id: "empty-s1", sequence: 1,
                     journal: reducerSessionJournal, session: reducerSession),
        reducerEvent(TimelineEventType.sessionAttached, id: "empty-s2", sequence: 2,
                     journal: reducerSessionJournal, previous: "empty-s1", session: reducerSession,
                     work: WorkRef(workHostID: "", workID: "valid"),
                     sessionAttachment: SessionAttachmentRef("valid")),
        reducerEvent(TimelineEventType.sessionAttached, id: "empty-s3", sequence: 3,
                     journal: reducerSessionJournal, previous: "empty-s2", session: reducerSession,
                     work: reducerWork, sessionAttachment: emptySessionAttachment),
    ]
    let session = SessionReducer.reduce(sessionEvents)
    XCTAssertTrue(session.attachments.isEmpty)
    XCTAssertEqual(session.quarantinedEvents.count, 2)
}

func test_timelineReducerRejectsEmptyActivityIdentities() throws {
    let workCreated = reducerEvent(
        TimelineEventType.workCreated, id: "activity-w1", sequence: 1,
        journal: reducerWorkJournal, work: reducerWork)
    let emptyAction = reducerEvent(
        TimelineEventType.actionIntent, id: "activity-w2", sequence: 2,
        journal: reducerWorkJournal, previous: "activity-w1", work: reducerWork,
        action: ActionRef(""), payload: .object(["state": .string("proposed")]))
    let emptyHandle = reducerEvent(
        TimelineEventType.handleStarted, id: "activity-w3", sequence: 3,
        journal: reducerWorkJournal, previous: "activity-w2", work: reducerWork,
        handle: HandleRef(""), payload: .object(["state": .string("running")]))
    let causeCursor = JournalCursor(
        journal: reducerWorkJournal, eventID: workCreated.eventID, sequence: workCreated.sequence)
    let emptyCommand = reducerEvent(
        TimelineEventType.commandAccepted, id: "activity-w4", sequence: 4,
        journal: reducerWorkJournal, hostSequence: 1, previous: "activity-w3",
        work: reducerWork,
        command: CommandRef(commandID: "", causalCursor: causeCursor),
        causedBy: EventRef(journal: reducerWorkJournal, eventID: workCreated.eventID))
    let snapshot = WorkReducer.reduce([workCreated, emptyAction, emptyHandle, emptyCommand])
    XCTAssertTrue(snapshot.actions.isEmpty)
    XCTAssertTrue(snapshot.handles.isEmpty)
    XCTAssertTrue(snapshot.commands.isEmpty)
    XCTAssertEqual(snapshot.quarantinedEvents.count, 3)
}

func test_sessionReducerAppendsUnselectedMessagesAndRebuildsOnlyAtTipSelection() throws {
    let created = reducerEvent(
        TimelineEventType.sessionCreated, id: "projection-created", sequence: 1,
        journal: reducerSessionJournal, session: reducerSession)
    let toolOnly = reducerEvent(
        TimelineEventType.messageCommitted, id: "projection-tool", sequence: 2,
        journal: reducerSessionJournal, previous: created.eventID, session: reducerSession,
        payload: .object(["role": .string("assistant"), "text": .string("")]))
    let root = reducerEvent(
        TimelineEventType.messageCommitted, id: "projection-root", sequence: 3,
        journal: reducerSessionJournal, previous: toolOnly.eventID, session: reducerSession,
        payload: .object(["role": .string("user"), "text": .string("root")]))
    let child = reducerEvent(
        TimelineEventType.messageCommitted, id: "projection-child", sequence: 4,
        journal: reducerSessionJournal, previous: root.eventID, session: reducerSession,
        conversationParent: EventRef(journal: reducerSessionJournal, eventID: root.eventID),
        payload: .object(["role": .string("assistant"), "text": .string("child")]))
    let selectRoot = reducerEvent(
        TimelineEventType.sessionTipSelected, id: "projection-select-root", sequence: 5,
        journal: reducerSessionJournal, previous: child.eventID, session: reducerSession,
        conversationParent: EventRef(journal: reducerSessionJournal, eventID: root.eventID))
    let selectedBranchMessage = reducerEvent(
        TimelineEventType.messageCommitted, id: "projection-branch-child", sequence: 6,
        journal: reducerSessionJournal, previous: selectRoot.eventID, session: reducerSession,
        conversationParent: EventRef(journal: reducerSessionJournal, eventID: child.eventID),
        payload: .object(["role": .string("assistant"), "text": .string("selected later")]))
    let unselectedBranchMessage = reducerEvent(
        TimelineEventType.messageCommitted, id: "projection-other-branch", sequence: 7,
        journal: reducerSessionJournal, previous: selectedBranchMessage.eventID,
        session: reducerSession,
        conversationParent: EventRef(journal: reducerSessionJournal, eventID: root.eventID),
        payload: .object(["role": .string("assistant"), "text": .string("other branch")]))
    let compaction = reducerEvent(
        TimelineEventType.compaction, id: "projection-compaction", sequence: 8,
        journal: reducerSessionJournal, previous: unselectedBranchMessage.eventID,
        session: reducerSession, payload: .object(["summary": .string("root remains selected")]))
    let selectChild = reducerEvent(
        TimelineEventType.sessionTipSelected, id: "projection-select-child", sequence: 9,
        journal: reducerSessionJournal, previous: compaction.eventID,
        session: reducerSession,
        conversationParent: EventRef(journal: reducerSessionJournal, eventID: child.eventID))

    var reducer = SessionReducer()
    for event in [created, toolOnly, root, child, selectRoot] { reducer.apply(event) }
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["root"])
    XCTAssertEqual(reducer.visibleProjectionRebuildCount, 1)
    XCTAssertEqual(reducer.visibleProjectionMessagesScanned, 3)

    reducer.apply(selectedBranchMessage)
    reducer.apply(unselectedBranchMessage)
    // A selected branch is stable while unrelated/new messages arrive.
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["root"])
    XCTAssertEqual(reducer.visibleProjectionRebuildCount, 1)
    XCTAssertEqual(reducer.visibleProjectionMessagesScanned, 3)

    reducer.apply(compaction)
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["root"])
    XCTAssertEqual(reducer.visibleProjectionRebuildCount, 1)
    XCTAssertEqual(reducer.visibleProjectionMessagesScanned, 3)

    reducer.apply(selectChild)
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["root", "child"])
    XCTAssertEqual(reducer.visibleProjectionRebuildCount, 1)
    XCTAssertEqual(reducer.visibleProjectionMessagesScanned, 3)
    XCTAssertEqual(reducer.visibleProjectionFastPathCount, 1)

    // The same prefix reduced cold must produce the same durable projection.  The instrumentation
    // is intentionally not part of SessionSnapshot and therefore does not affect this equality.
    let cold = SessionReducer.reduce(
        [created, toolOnly, root, child, selectRoot, selectedBranchMessage, unselectedBranchMessage,
         compaction, selectChild])
    XCTAssertEqual(cold, reducer.snapshot)
}

func test_sessionReducerMessageAppendScaleUsesNoHistoryRescan() throws {
    let messageCount = 2_048
    let created = reducerEvent(
        TimelineEventType.sessionCreated, id: "scale-created", sequence: 1,
        journal: reducerSessionJournal, session: reducerSession)
    var events = [created]
    events.reserveCapacity(messageCount + 1)
    var previous = created.eventID
    var parent: EventRef?
    for index in 0..<messageCount {
        let id = "scale-message-\(index)"
        let event = reducerEvent(
            TimelineEventType.messageCommitted, id: id, sequence: index + 2,
            journal: reducerSessionJournal, previous: previous, session: reducerSession,
            conversationParent: parent,
            payload: .object([
                "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                "text": .string("message-\(index)"),
            ]))
        events.append(event)
        previous = id
        parent = EventRef(journal: reducerSessionJournal, eventID: id)
    }

    var live = SessionReducer()
    for event in events { live.apply(event) }
    XCTAssertEqual(live.snapshot.messageHistory.count, messageCount)
    XCTAssertEqual(live.snapshot.messages.count, messageCount)
    XCTAssertEqual(live.visibleProjectionRebuildCount, 0)
    XCTAssertEqual(live.visibleProjectionMessagesScanned, 0)

    // Selecting a tip is the explicit semantic operation that pays the linear branch-validation
    // and rebuild cost once; ordinary appends above must not accumulate that cost quadratically.
    let selectTip = reducerEvent(
        TimelineEventType.sessionTipSelected, id: "scale-tip", sequence: messageCount + 2,
        journal: reducerSessionJournal, previous: previous, session: reducerSession,
        conversationParent: parent)
    live.apply(selectTip)
    XCTAssertEqual(live.snapshot.messages.count, messageCount)
    XCTAssertEqual(live.visibleProjectionRebuildCount, 1)
    XCTAssertEqual(live.visibleProjectionMessagesScanned, messageCount)
}

func test_sessionReducerProducerMessageTipSequenceStaysLinear() throws {
    let messageCount = 2_048
    let created = reducerEvent(
        TimelineEventType.sessionCreated, id: "producer-created", sequence: 1,
        journal: reducerSessionJournal, session: reducerSession)

    var reducer = SessionReducer()
    reducer.apply(created)
    var previousEventID = created.eventID
    var previousMessage: EventRef?

    for index in 0..<messageCount {
        let messageID = "producer-message-\(index)"
        let message = reducerEvent(
            TimelineEventType.messageCommitted, id: messageID, sequence: index * 2 + 2,
            journal: reducerSessionJournal, previous: previousEventID, session: reducerSession,
            conversationParent: previousMessage,
            payload: .object([
                "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                "text": .string("producer-message-\(index)"),
            ]))
        reducer.apply(message)

        let tip = reducerEvent(
            TimelineEventType.sessionTipSelected, id: "producer-tip-\(index)", sequence: index * 2 + 3,
            journal: reducerSessionJournal, previous: messageID, session: reducerSession,
            conversationParent: EventRef(journal: reducerSessionJournal, eventID: messageID))
        reducer.apply(tip)
        previousEventID = tip.eventID
        previousMessage = EventRef(journal: reducerSessionJournal, eventID: messageID)
    }

    XCTAssertEqual(reducer.snapshot.messageHistory.count, messageCount)
    XCTAssertEqual(reducer.snapshot.messages.count, messageCount)
    XCTAssertEqual(reducer.snapshot.messages.map(\.eventID).last, "producer-message-\(messageCount - 1)")
    // The first selection builds the initial branch. Every native producer-shaped subsequent
    // message+tip pair extends that branch and must not rescan the historical message list.
    XCTAssertEqual(reducer.visibleProjectionRebuildCount, 1)
    XCTAssertEqual(reducer.visibleProjectionMessagesScanned, 1)
    XCTAssertEqual(reducer.visibleProjectionFastPathCount, messageCount - 1)
    XCTAssertTrue(reducer.visibleProjectionMessagesScanned + reducer.visibleProjectionFastPathCount
                  <= messageCount + 1)
}

func test_timelineReducerRejectsInvalidTurnAndHandleActivityEnvelopes() throws {
    let run = RunRef("activity-run")
    let foreignRun = RunRef("foreign-run")
    let turn = TurnRef("activity-turn")
    let otherTurn = TurnRef("other-turn")
    let handle = HandleRef("activity-handle")
    let attachment = SessionAttachmentRef("activity-session-attachment")

    let turnEvents = [
        reducerEvent(TimelineEventType.workCreated, id: "envelope-turn-1", sequence: 1,
                     journal: reducerWorkJournal, work: reducerWork),
        reducerEvent(TimelineEventType.sessionAttached, id: "envelope-turn-attachment", sequence: 2,
                     journal: reducerWorkJournal, previous: "envelope-turn-1",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment),
        reducerEvent(TimelineEventType.runStarted, id: "envelope-turn-2", sequence: 3,
                     journal: reducerWorkJournal, previous: "envelope-turn-attachment",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run),
        // Every invalid semantic event still advances the journal cursor, but must not alter
        // the effective activity state. This makes the suffix safe to reduce after quarantine.
        reducerEvent(TimelineEventType.turnStarted, id: "envelope-turn-3", sequence: 4,
                     journal: reducerWorkJournal, previous: "envelope-turn-2", work: reducerWork),
        reducerEvent(TimelineEventType.turnStarted, id: "envelope-turn-4", sequence: 5,
                     journal: reducerWorkJournal, previous: "envelope-turn-3", work: reducerWork,
                     run: run, turn: TurnRef("   ")),
        reducerEvent(TimelineEventType.turnStarted, id: "envelope-turn-5", sequence: 6,
                     journal: reducerWorkJournal, previous: "envelope-turn-4", work: reducerWork,
                     run: foreignRun, turn: otherTurn),
        reducerEvent(TimelineEventType.turnStarted, id: "envelope-turn-6", sequence: 7,
                     journal: reducerWorkJournal, previous: "envelope-turn-5", work: reducerWork,
                     run: run, turn: turn),
        reducerEvent(TimelineEventType.turnStarted, id: "envelope-turn-7", sequence: 8,
                     journal: reducerWorkJournal, previous: "envelope-turn-6", work: reducerWork,
                     run: run, turn: otherTurn),
        reducerEvent(TimelineEventType.turnFinished, id: "envelope-turn-8", sequence: 9,
                     journal: reducerWorkJournal, previous: "envelope-turn-7", work: reducerWork,
                     run: run),
        reducerEvent(TimelineEventType.turnFinished, id: "envelope-turn-9", sequence: 10,
                     journal: reducerWorkJournal, previous: "envelope-turn-8", work: reducerWork,
                     run: foreignRun, turn: turn),
        reducerEvent(TimelineEventType.turnFinished, id: "envelope-turn-10", sequence: 11,
                     journal: reducerWorkJournal, previous: "envelope-turn-9", work: reducerWork,
                     run: run, turn: otherTurn),
        // A mismatched turn finish must not clear the turn, so finishing the Run remains
        // inadmissible until the matching turn finish arrives.
        reducerEvent(TimelineEventType.runFinished, id: "envelope-turn-11", sequence: 12,
                     journal: reducerWorkJournal, previous: "envelope-turn-10",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run),
        reducerEvent(TimelineEventType.turnFinished, id: "envelope-turn-12", sequence: 13,
                     journal: reducerWorkJournal, previous: "envelope-turn-11", work: reducerWork,
                     run: run, turn: turn),
        reducerEvent(TimelineEventType.runFinished, id: "envelope-turn-13", sequence: 14,
                     journal: reducerWorkJournal, previous: "envelope-turn-12",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run),
    ]
    let turns = WorkReducer.reduce(turnEvents)
    XCTAssertNil(turns.activeRun)
    XCTAssertNil(turns.activeTurn)
    XCTAssertEqual(turns.execution, .idle)
    XCTAssertEqual(
        turns.quarantinedEvents.map(\.eventID),
        ["envelope-turn-3", "envelope-turn-4", "envelope-turn-5", "envelope-turn-7",
         "envelope-turn-8", "envelope-turn-9", "envelope-turn-10", "envelope-turn-11"])
    XCTAssertTrue(turns.structuralIntegrityValid)
    XCTAssertFalse(turns.semanticProjectionValid)

    let handleEvents = [
        reducerEvent(TimelineEventType.workCreated, id: "envelope-handle-1", sequence: 1,
                     journal: reducerWorkJournal, work: reducerWork),
        reducerEvent(TimelineEventType.sessionAttached, id: "envelope-handle-attachment", sequence: 2,
                     journal: reducerWorkJournal, previous: "envelope-handle-1",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment),
        reducerEvent(TimelineEventType.runStarted, id: "envelope-handle-2", sequence: 3,
                     journal: reducerWorkJournal, previous: "envelope-handle-attachment",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run),
        reducerEvent(TimelineEventType.handleOutcome, id: "envelope-handle-3", sequence: 4,
                     journal: reducerWorkJournal, previous: "envelope-handle-2", work: reducerWork,
                     run: run, handle: handle,
                     payload: .object(["state": .string("succeeded")])),
        reducerEvent(TimelineEventType.handleStarted, id: "envelope-handle-4", sequence: 5,
                     journal: reducerWorkJournal, previous: "envelope-handle-3", work: reducerWork,
                     handle: handle, payload: .object(["state": .string("running")])),
        reducerEvent(TimelineEventType.handleStarted, id: "envelope-handle-5", sequence: 6,
                     journal: reducerWorkJournal, previous: "envelope-handle-4", work: reducerWork,
                     run: run, handle: HandleRef(""),
                     payload: .object(["state": .string("running")])),
        reducerEvent(TimelineEventType.handleStarted, id: "envelope-handle-6", sequence: 7,
                     journal: reducerWorkJournal, previous: "envelope-handle-5", work: reducerWork,
                     run: foreignRun, handle: HandleRef("foreign-handle"),
                     payload: .object(["state": .string("running")])),
        reducerEvent(TimelineEventType.handleStarted, id: "envelope-handle-7", sequence: 8,
                     journal: reducerWorkJournal, previous: "envelope-handle-6", work: reducerWork,
                     run: run, handle: HandleRef("empty-state"),
                     payload: .object(["state": .string("   ")])),
        reducerEvent(TimelineEventType.handleStarted, id: "envelope-handle-8", sequence: 9,
                     journal: reducerWorkJournal, previous: "envelope-handle-7", work: reducerWork,
                     run: run, handle: handle,
                     payload: .object(["state": .string("running")])),
        reducerEvent(TimelineEventType.handleStarted, id: "envelope-handle-9", sequence: 10,
                     journal: reducerWorkJournal, previous: "envelope-handle-8", work: reducerWork,
                     run: run, handle: handle,
                     payload: .object(["state": .string("running")])),
        // The outstanding Handle blocks run.finished; an outcome cannot bypass that boundary.
        reducerEvent(TimelineEventType.runFinished, id: "envelope-handle-10", sequence: 11,
                     journal: reducerWorkJournal, previous: "envelope-handle-9",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run),
        reducerEvent(TimelineEventType.handleOutcome, id: "envelope-handle-11", sequence: 12,
                     journal: reducerWorkJournal, previous: "envelope-handle-10", work: reducerWork,
                     run: foreignRun, handle: handle,
                     payload: .object(["state": .string("succeeded")])),
        reducerEvent(TimelineEventType.handleOutcome, id: "envelope-handle-12", sequence: 13,
                     journal: reducerWorkJournal, previous: "envelope-handle-11", work: reducerWork,
                     run: run, handle: handle,
                     payload: .object(["state": .string("   ")])),
        reducerEvent(TimelineEventType.handleOutcome, id: "envelope-handle-13", sequence: 14,
                     journal: reducerWorkJournal, previous: "envelope-handle-12", work: reducerWork,
                     run: run, handle: handle,
                     payload: .object(["state": .string("succeeded")])),
        // A terminal Handle cannot be reused or terminalized by a second outcome.
        reducerEvent(TimelineEventType.handleOutcome, id: "envelope-handle-14", sequence: 15,
                     journal: reducerWorkJournal, previous: "envelope-handle-13", work: reducerWork,
                     run: run, handle: handle,
                     payload: .object(["state": .string("failed")])),
        reducerEvent(TimelineEventType.runFinished, id: "envelope-handle-15", sequence: 16,
                     journal: reducerWorkJournal, previous: "envelope-handle-14",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run),
    ]
    let handles = WorkReducer.reduce(handleEvents)
    XCTAssertNil(handles.activeRun)
    XCTAssertEqual(handles.handles[handle.handleID]?.state, "succeeded")
    XCTAssertEqual(handles.quarantinedEvents.map(\.eventID), [
        "envelope-handle-3", "envelope-handle-4", "envelope-handle-5", "envelope-handle-6",
        "envelope-handle-7", "envelope-handle-9", "envelope-handle-10", "envelope-handle-11",
        "envelope-handle-12", "envelope-handle-14",
    ])
    XCTAssertTrue(handles.structuralIntegrityValid)
    XCTAssertFalse(handles.semanticProjectionValid)
}

func test_sessionAttentionMalformedPayloadIsUnknownNotNone() throws {
    let events = [
        reducerEvent(TimelineEventType.sessionCreated, id: "attention-s1", sequence: 1,
                     journal: reducerSessionJournal, session: reducerSession),
        reducerEvent(TimelineEventType.sessionAttention, id: "attention-s2", sequence: 2,
                     journal: reducerSessionJournal, previous: "attention-s1",
                     session: reducerSession, payload: .object(["attention": .string("future")]))
    ]
    let snapshot = SessionReducer.reduce(events)
    XCTAssertEqual(snapshot.attention, .none,
                   "malformed attention must not be interpreted as a clearing transition")
    XCTAssertTrue(snapshot.unknownDomains.contains(.session))
    XCTAssertFalse(snapshot.semanticProjectionValid)
    XCTAssertEqual(snapshot.unknownEvents.map(\.event.eventID), ["attention-s2"])
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
                              payload: .object([
                                  "state": "proposed", "kind": "python", "intent": "outstanding action"
                              ]))
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

func test_timelineProjectsCanonicalMessageAndActionMetadataAcrossIncrementalPages() throws {
    let run = RunRef("metadata-run")
    let turn = TurnRef("metadata-turn")
    let action = ActionRef("metadata-action")
    let attachment = SessionAttachmentRef("metadata-session-attachment")
    let causedBy = EventRef(journal: reducerWorkJournal, eventID: "metadata-run-start")
    let links = [TimelineLink(kind: .supports, target: causedBy)]
    let workEvents = [
        reducerEvent(TimelineEventType.workCreated, id: "metadata-work-1", sequence: 1,
                     journal: reducerWorkJournal, work: reducerWork,
                     workHost: WorkHostRef(reducerWork.workHostID)),
        reducerEvent(TimelineEventType.sessionAttached, id: "metadata-work-attachment", sequence: 2,
                     journal: reducerWorkJournal, previous: "metadata-work-1",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment),
        reducerEvent(TimelineEventType.runStarted, id: "metadata-run-start", sequence: 3,
                     journal: reducerWorkJournal, previous: "metadata-work-attachment",
                     session: reducerSession, work: reducerWork,
                     sessionAttachment: attachment, run: run,
                     payload: .object(["model_id": .string("model-metadata")])),
        reducerEvent(TimelineEventType.turnStarted, id: "metadata-turn-start", sequence: 4,
                     journal: reducerWorkJournal, previous: "metadata-run-start", work: reducerWork,
                     run: run, turn: turn),
        reducerEvent(TimelineEventType.actionIntent, id: "metadata-action-intent", sequence: 5,
                     journal: reducerWorkJournal, previous: "metadata-turn-start", work: reducerWork,
                     run: run, turn: turn, action: action, causedBy: causedBy,
                     clientTimestamp: Date(timeIntervalSince1970: 104), links: links,
                     payload: .object([
                         "state": .string("proposed"), "kind": .string("python"),
                         "intent": .string("run the checked script"),
                         "target": .string("workspace"), "scope": .string("turn"),
                         "metadata": .object([
                             "argv": .array([.string("python"), .string("script.py")]),
                             "attempt": .number(1), "structured": .object(["safe": .bool(true)])
                         ])
                     ])),
        reducerEvent(TimelineEventType.actionStarted, id: "metadata-action-started", sequence: 6,
                     journal: reducerWorkJournal, previous: "metadata-action-intent", work: reducerWork,
                     run: run, turn: turn, action: action,
                     causedBy: EventRef(journal: reducerWorkJournal, eventID: "metadata-action-intent"),
                     parent: EventRef(journal: reducerWorkJournal, eventID: "metadata-action-intent"),
                     clientTimestamp: Date(timeIntervalSince1970: 105),
                     payload: .object(["state": .string("running"), "kind": .string("python")])),
        reducerEvent(TimelineEventType.actionOutcome, id: "metadata-action-outcome", sequence: 7,
                     journal: reducerWorkJournal, previous: "metadata-action-started", work: reducerWork,
                     run: run, turn: turn, action: action,
                     causedBy: EventRef(journal: reducerWorkJournal, eventID: "metadata-action-started"),
                     parent: EventRef(journal: reducerWorkJournal, eventID: "metadata-action-started"),
                     clientTimestamp: Date(timeIntervalSince1970: 106),
                     links: [TimelineLink(kind: .produced,
                                          target: EventRef(journal: reducerWorkJournal,
                                                           eventID: "metadata-action-intent"))],
                     payload: .object([
                         "state": .string("failed"), "kind": .string("python"),
                         "failure_kind": .string("timeout"), "retry_safety": .string("unknown")
                     ])),
    ]

    var liveWork = WorkReducer()
    for event in workEvents { liveWork.apply(event) }
    let coldWork = WorkReducer.reduce(workEvents)
    XCTAssertEqual(liveWork.snapshot, coldWork)
    let projectedAction = try XCTUnwrap(coldWork.actions[action.actionID])
    XCTAssertEqual(projectedAction.kind, .python)
    XCTAssertEqual(projectedAction.intent, "run the checked script")
    XCTAssertEqual(projectedAction.target, "workspace")
    XCTAssertEqual(projectedAction.scope, "turn")
    XCTAssertEqual(projectedAction.metadata["attempt"], .number(1))
    XCTAssertEqual(projectedAction.metadata["argv"], .array([.string("python"), .string("script.py")]))
    XCTAssertEqual(projectedAction.state, .failed)
    XCTAssertEqual(projectedAction.failureKind, .timeout)
    XCTAssertEqual(projectedAction.retrySafety, .unknown)
    XCTAssertEqual(projectedAction.intentEvent?.sourceEvent.eventID, "metadata-action-intent")
    XCTAssertEqual(projectedAction.intentEvent?.run, run)
    XCTAssertEqual(projectedAction.intentEvent?.turn, turn)
    XCTAssertEqual(projectedAction.intentEvent?.hostRecordedAt,
                   Date(timeIntervalSince1970: 5))
    XCTAssertEqual(projectedAction.intentEvent?.clientTimestamp,
                   Date(timeIntervalSince1970: 104))
    XCTAssertEqual(projectedAction.intentEvent?.causedBy, causedBy)
    XCTAssertEqual(projectedAction.intentEvent?.links, links)
    XCTAssertEqual(projectedAction.startedEvent?.sourceEvent.eventID, "metadata-action-started")
    XCTAssertEqual(projectedAction.startedEvent?.parentActivity?.eventID, "metadata-action-intent")
    XCTAssertEqual(projectedAction.startedEvent?.clientTimestamp,
                   Date(timeIntervalSince1970: 105))
    XCTAssertEqual(projectedAction.outcomeEvent?.sourceEvent.eventID, "metadata-action-outcome")
    XCTAssertEqual(projectedAction.outcomeEvent?.turn, turn)
    XCTAssertEqual(projectedAction.outcomeEvent?.hostRecordedAt,
                   Date(timeIntervalSince1970: 7))
    XCTAssertEqual(projectedAction.outcomeEvent?.clientTimestamp,
                   Date(timeIntervalSince1970: 106))

    let clientTime = Date(timeIntervalSince1970: 987_654)
    let userEvent = reducerEvent(
        TimelineEventType.inputAccepted, id: "metadata-user", sequence: 2,
        journal: reducerSessionJournal, previous: "metadata-session", session: reducerSession,
        run: run, turn: turn,
        causedBy: EventRef(journal: reducerSessionJournal, eventID: "metadata-command"),
        parent: EventRef(journal: reducerWorkJournal, eventID: "metadata-action-outcome"),
        clientTimestamp: clientTime,
        payload: .object(["text": .string("exact user message")]))
    let assistantEvent = reducerEvent(
        TimelineEventType.messageCommitted, id: "metadata-assistant", sequence: 3,
        journal: reducerSessionJournal, previous: userEvent.eventID, session: reducerSession,
        run: run, turn: turn,
        causedBy: EventRef(journal: reducerSessionJournal, eventID: userEvent.eventID),
        parent: EventRef(journal: reducerWorkJournal, eventID: "metadata-action-outcome"),
        conversationParent: EventRef(journal: reducerSessionJournal, eventID: userEvent.eventID),
        links: [TimelineLink(kind: .produced,
                             target: EventRef(journal: reducerWorkJournal,
                                              eventID: "metadata-action-outcome"))],
        payload: .object(["role": .string("assistant"), "text": .string("exact assistant message")]))
    let tip = reducerEvent(
        TimelineEventType.sessionTipSelected, id: "metadata-tip", sequence: 4,
        journal: reducerSessionJournal, previous: assistantEvent.eventID, session: reducerSession,
        conversationParent: EventRef(journal: reducerSessionJournal, eventID: assistantEvent.eventID))
    let sessionEvents = [
        reducerEvent(TimelineEventType.sessionCreated, id: "metadata-session", sequence: 1,
                     journal: reducerSessionJournal, session: reducerSession),
        userEvent, assistantEvent, tip,
    ]
    var liveSession = SessionReducer()
    for event in sessionEvents { liveSession.apply(event) }
    let coldSession = SessionReducer.reduce(sessionEvents)
    XCTAssertEqual(liveSession.snapshot, coldSession)
    XCTAssertEqual(coldSession.messages.map(\.text), ["exact user message", "exact assistant message"])
    let user = try XCTUnwrap(coldSession.messages.first)
    let assistant = try XCTUnwrap(coldSession.messages.last)
    XCTAssertEqual(user.sourceEvent, EventRef(journal: reducerSessionJournal, eventID: userEvent.eventID))
    XCTAssertEqual(user.hostRecordedAt, Date(timeIntervalSince1970: 2))
    XCTAssertEqual(user.clientTimestamp, clientTime)
    XCTAssertEqual(user.run, run)
    XCTAssertEqual(user.turn, turn)
    XCTAssertEqual(user.causedBy?.eventID, "metadata-command")
    XCTAssertEqual(user.parentActivity?.eventID, "metadata-action-outcome")
    XCTAssertEqual(assistant.sourceEvent?.eventID, assistantEvent.eventID)
    XCTAssertEqual(assistant.conversationParent?.eventID, userEvent.eventID)
    XCTAssertEqual(assistant.links.first?.kind, .produced)
    XCTAssertEqual(assistant.links.first?.target, .event(
        EventRef(journal: reducerWorkJournal, eventID: "metadata-action-outcome")))
    XCTAssertNil(assistant.clientTimestamp)

    // Bounds are measured in UTF-8 bytes, but truncation never bisects a Unicode scalar or
    // grapheme cluster. The marker-like metadata remains structured producer data, not a wire
    // parser heuristic.
    let unicode = String(repeating: "🙂", count: WorkActionSnapshot.maxTextBytes)
    let bounded = WorkActionSnapshot(
        action: ActionRef("unicode-action"), kind: .mcp, intent: unicode,
        metadata: ["unicode": .string(unicode)])
    XCTAssertTrue((bounded.intent?.utf8.count ?? Int.max) <= WorkActionSnapshot.maxTextBytes)
    XCTAssertFalse(bounded.intent?.contains("�") ?? true)
    XCTAssertTrue(bounded.metadataWasTruncated)
    if case .string(let value) = bounded.metadata["unicode"] {
        XCTAssertTrue(value.utf8.count <= 512)
        XCTAssertFalse(value.contains("�"))
        let expectedPrefix = String(repeating: "🙂", count: 512 / "🙂".utf8.count)
        XCTAssertEqual(value, expectedPrefix)
    } else {
        XCTFail("bounded structured metadata should retain its typed string value")
    }
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
