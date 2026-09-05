import Foundation
@testable import AviaryCore

private let sessionTransitionSession = SessionRef("session-transition")
private let sessionTransitionJournal = JournalRef.session(
    sessionTransitionSession, journalID: "session-transition-journal",
    authority: TimelineAuthorityRef("session-transition-authority"))
private let sessionTransitionWork = WorkRef(
    workHostID: "session-transition-host", workID: "session-transition-work")

private func sessionTransitionJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

private func sessionTransitionEvent(
    _ type: String,
    id: String,
    sequence: Int,
    previous: String? = nil,
    session: SessionRef? = sessionTransitionSession,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    attachment: SessionAttachmentRef? = nil,
    run: RunRef? = nil,
    turn: TurnRef? = nil,
    causedBy: EventRef? = nil,
    parentActivity: EventRef? = nil,
    conversationParent: EventRef? = nil,
    schemaVersion: Int = TimelineEvent.currentSchemaVersion,
    payloadVersion: Int = 1,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: sessionTransitionJournal, sequence: sequence,
        command: nil, previousEventID: previous, causedByEventID: causedBy,
        parentActivityID: parentActivity, conversationParent: conversationParent,
        session: session, work: work,
        workHost: workHost, sessionAttachment: attachment,
        run: run, turn: turn, actor: TimelineActor(actorID: "session-transition-test", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
        schemaVersion: schemaVersion, payloadVersion: payloadVersion,
        type: type, declaredDomains: declaredDomains, payload: payload)
}

private func sessionTransitionContextComponentJSON() -> JSONValue {
    sessionTransitionJSON(ContextComponent(
        componentID: "session-transition-component", inclusionID: "session-transition-inclusion",
        sourceID: "session-transition-source", mode: .history, deliveryMode: .full,
        measuredBytes: 5, includedBytes: 5, deliveredBytes: 5, fullByteCount: 5,
        digest: "sha256:" + String(repeating: "a", count: 64)))
}

private func sessionTransitionEvents() -> [TimelineEvent] {
    let root = sessionTransitionEvent(
        TimelineEventType.sessionCreated, id: "session-transition-1", sequence: 1)
    let attachment = SessionAttachmentRef("session-transition-attachment")
    let attached = sessionTransitionEvent(
        TimelineEventType.sessionAttached, id: "session-transition-2", sequence: 2,
        previous: root.eventID, work: sessionTransitionWork,
        workHost: WorkHostRef(sessionTransitionWork.workHostID), attachment: attachment,
        payload: .object(["capabilities": .array(["observe", "send"])]) )
    let input = sessionTransitionEvent(
        TimelineEventType.inputAccepted, id: "session-transition-3", sequence: 3,
        previous: attached.eventID, attachment: nil,
        payload: .object(["text": "hello from the user"]))
    let message = sessionTransitionEvent(
        TimelineEventType.messageCommitted, id: "session-transition-4", sequence: 4,
        previous: input.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: input.eventID),
        payload: .object(["role": "assistant", "text": "hello from the agent"]))
    let model = sessionTransitionEvent(
        TimelineEventType.modelChanged, id: "session-transition-5", sequence: 5,
        previous: message.eventID, payload: .object(["model_id": "session-model-v2"]))
    let run = RunRef("session-transition-run")
    let context = sessionTransitionEvent(
        TimelineEventType.contextAssembled, id: "session-transition-6", sequence: 6,
        previous: model.eventID, work: sessionTransitionWork,
        workHost: WorkHostRef(sessionTransitionWork.workHostID), run: run,
        payload: .object([
            "components": .array([sessionTransitionContextComponentJSON()])
        ]))
    let attention = sessionTransitionEvent(
        TimelineEventType.sessionAttention, id: "session-transition-7", sequence: 7,
        previous: context.eventID, payload: .object(["attention": "review"]))
    let child = sessionTransitionEvent(
        TimelineEventType.childLifecycle, id: "session-transition-8", sequence: 8,
        previous: attention.eventID, payload: .object(["child_id": "child-1", "state": "completed"]))
    return [root, attached, input, message, model, context, attention, child]
}

/// The live façade, cold reduction, and event-local adapter must agree after every prefix.
/// The final assertions below are deliberately independent of that parity relation.
func test_sessionReducerTransitionDifferentialAtEveryPrefix() {
    let events = sessionTransitionEvents()
    var live = SessionReducer()
    var direct = InMemorySessionTransitionState()
    for index in events.indices {
        live.apply(events[index])
        SessionReducerTransition.apply(events[index], to: &direct)
        let cold = SessionReducer.reduce(events.prefix(index + 1))
        XCTAssertEqual(live.snapshot, cold, "live/cold mismatch at prefix \(index + 1)")
        XCTAssertEqual(direct.snapshot, cold, "adapter/cold mismatch at prefix \(index + 1)")
    }

    let snapshot = live.snapshot
    XCTAssertEqual(snapshot.lifecycle, .active)
    XCTAssertEqual(snapshot.session, sessionTransitionSession)
    XCTAssertEqual(snapshot.attachments.count, 1)
    XCTAssertEqual(snapshot.attachments.values.first?.capabilities, ["observe", "send"])
    XCTAssertEqual(snapshot.messages.map(\.text), ["hello from the user", "hello from the agent"])
    XCTAssertEqual(snapshot.messageHistory.count, 2)
    XCTAssertEqual(snapshot.modelID, "session-model-v2")
    XCTAssertEqual(snapshot.attention, .review)
    XCTAssertEqual(snapshot.attentionEvent?.eventID, "session-transition-7")
    XCTAssertEqual(snapshot.contextComponents.count, 1)
    XCTAssertEqual(snapshot.childStates["child-1"], "completed")
    XCTAssertEqual(snapshot.lastEventID, "session-transition-8")
    XCTAssertEqual(snapshot.lastSequence, 8)
    XCTAssertTrue(snapshot.structuralIntegrityValid)
    XCTAssertTrue(snapshot.semanticProjectionValid)
}

func test_sessionReducerTransitionPreservesMalformedUnknownEvidence() {
    let created = sessionTransitionEvent(
        TimelineEventType.sessionCreated, id: "session-evidence-1", sequence: 1)
    let malformedMessage = sessionTransitionEvent(
        TimelineEventType.messageCommitted, id: "session-evidence-2", sequence: 2,
        previous: created.eventID)
    let unknown = sessionTransitionEvent(
        "future.session.transition", id: "session-evidence-3", sequence: 3,
        previous: malformedMessage.eventID, declaredDomains: [.context, .runtime],
        payload: .object(["opaque": .string("keep me")]))
    let malformedAttention = sessionTransitionEvent(
        TimelineEventType.sessionAttention, id: "session-evidence-4", sequence: 4,
        previous: unknown.eventID, payload: .object(["attention": "not-an-attention"]))
    let validModel = sessionTransitionEvent(
        TimelineEventType.modelChanged, id: "session-evidence-5", sequence: 5,
        previous: malformedAttention.eventID, payload: .object(["model": "after-malformed"]))

    var reducer = SessionReducer()
    for event in [created, malformedMessage, unknown, malformedAttention, validModel] {
        reducer.apply(event)
    }
    XCTAssertEqual(reducer.snapshot.messageHistory, [])
    XCTAssertEqual(reducer.snapshot.unknownEvents.map(\.event.eventID), [unknown.eventID, malformedAttention.eventID])
    XCTAssertEqual(reducer.snapshot.unknownDomains, Set(TimelineDomain.allCases))
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [malformedMessage, malformedAttention])
    XCTAssertFalse(reducer.snapshot.semanticProjectionValid)
    XCTAssertTrue(reducer.snapshot.structuralIntegrityValid)
    XCTAssertEqual(reducer.snapshot.modelID, "after-malformed")
    XCTAssertEqual(reducer.snapshot.lastSequence, 5)
}

func test_sessionReducerTransitionProjectsAttachmentsAndContextFailures() {
    let created = sessionTransitionEvent(
        TimelineEventType.sessionCreated, id: "session-edge-1", sequence: 1)
    let attachment = SessionAttachmentRef("session-edge-attachment")
    let attached = sessionTransitionEvent(
        TimelineEventType.sessionAttached, id: "session-edge-2", sequence: 2,
        previous: created.eventID, work: sessionTransitionWork,
        workHost: WorkHostRef(sessionTransitionWork.workHostID), attachment: attachment)
    let cursor = sessionTransitionEvent(
        TimelineEventType.sessionAttachmentCursorAdvanced, id: "session-edge-3", sequence: 3,
        previous: attached.eventID, attachment: attachment,
        payload: .object(["cursor": sessionTransitionJSON(JournalCursor(
            journal: JournalRef.work(sessionTransitionWork, journalID: "session-edge-work"),
            eventID: "work-edge-1", sequence: 1))]))
    let recoveryRun = RunRef("session-edge-run")
    let recovery = sessionTransitionEvent(
        TimelineEventType.recoveryCoverage, id: "session-edge-4", sequence: 4,
        previous: cursor.eventID, work: sessionTransitionWork,
        workHost: WorkHostRef(sessionTransitionWork.workHostID), attachment: attachment,
        run: recoveryRun, payload: .object([
            "work_journal": sessionTransitionJSON(
                JournalRef.work(sessionTransitionWork, journalID: "session-edge-work")),
            "operation": "checkpoint",
            "planes": .object(["timeline": "preserved"]),
        ]))
    let badContext = sessionTransitionEvent(
        TimelineEventType.contextAssembled, id: "session-edge-5", sequence: 5,
        previous: recovery.eventID, payload: .object([
            "components": .array([.object(["not": "a component"])])
        ]))
    let goodContext = sessionTransitionEvent(
        TimelineEventType.contextAssembled, id: "session-edge-6", sequence: 6,
        previous: badContext.eventID, payload: .object([
            "components": .array([sessionTransitionContextComponentJSON()])
        ]))
    let detached = sessionTransitionEvent(
        TimelineEventType.sessionDetached, id: "session-edge-7", sequence: 7,
        previous: goodContext.eventID, attachment: attachment)

    var live = SessionReducer()
    for event in [created, attached, cursor, recovery, badContext, goodContext, detached] {
        live.apply(event)
    }
    XCTAssertEqual(live.snapshot.attachments[attachment.attachmentID]?.cursor?.eventID, "work-edge-1")
    XCTAssertFalse(live.snapshot.attachments[attachment.attachmentID]?.isAttached ?? true)
    XCTAssertEqual(live.snapshot.recovery.count, 1)
    XCTAssertEqual(live.snapshot.recordedRecovery.first?.run, recoveryRun)
    XCTAssertEqual(live.snapshot.contextComponents.count, 1)
    XCTAssertEqual(live.snapshot.quarantinedEvents, [badContext])
    XCTAssertFalse(live.snapshot.semanticProjectionValid)
    XCTAssertTrue(live.snapshot.structuralIntegrityValid)
}

func test_sessionReducerTransitionMaterializesBranchesAndPreservesInstrumentation() {
    let root = sessionTransitionEvent(
        TimelineEventType.inputAccepted, id: "session-branch-1", sequence: 1,
        payload: .object(["text": "root"]))
    let child = sessionTransitionEvent(
        TimelineEventType.messageCommitted, id: "session-branch-2", sequence: 2,
        previous: root.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: root.eventID),
        payload: .object(["role": "assistant", "text": "child"]))
    let sibling = sessionTransitionEvent(
        TimelineEventType.messageCommitted, id: "session-branch-3", sequence: 3,
        previous: child.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: root.eventID),
        payload: .object(["role": "assistant", "text": "sibling"]))
    let selectChild = sessionTransitionEvent(
        TimelineEventType.sessionTipSelected, id: "session-branch-4", sequence: 4,
        previous: sibling.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: child.eventID))
    let selectSibling = sessionTransitionEvent(
        TimelineEventType.sessionTipSelected, id: "session-branch-5", sequence: 5,
        previous: selectChild.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: sibling.eventID))

    var reducer = SessionReducer()
    for event in [root, child, sibling, selectChild, selectSibling] { reducer.apply(event) }
    XCTAssertEqual(reducer.snapshot.messages.map(\.text), ["root", "sibling"])
    XCTAssertEqual(reducer.snapshot.messageHistory.map(\.text), ["root", "child", "sibling"])
    XCTAssertEqual(reducer.visibleProjectionRebuildCount, 2)
    XCTAssertEqual(reducer.visibleProjectionMessagesScanned, 6)
    XCTAssertEqual(reducer.visibleProjectionFastPathCount, 0)

    let extensionRoot = sessionTransitionEvent(
        TimelineEventType.inputAccepted, id: "session-extension-1", sequence: 1,
        payload: .object(["text": "extension root"]))
    let extensionSelectRoot = sessionTransitionEvent(
        TimelineEventType.sessionTipSelected, id: "session-extension-2", sequence: 2,
        previous: extensionRoot.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: extensionRoot.eventID))
    let extensionChild = sessionTransitionEvent(
        TimelineEventType.messageCommitted, id: "session-extension-3", sequence: 3,
        previous: extensionSelectRoot.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: extensionRoot.eventID),
        payload: .object(["role": "assistant", "text": "extension child"]))
    let extensionSelectChild = sessionTransitionEvent(
        TimelineEventType.sessionTipSelected, id: "session-extension-4", sequence: 4,
        previous: extensionChild.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: extensionChild.eventID))
    var extensionReducer = SessionReducer()
    for event in [extensionRoot, extensionSelectRoot, extensionChild, extensionSelectChild] {
        extensionReducer.apply(event)
    }
    XCTAssertEqual(extensionReducer.snapshot.messages.map(\.text), ["extension root", "extension child"])
    XCTAssertEqual(extensionReducer.visibleProjectionRebuildCount, 1)
    XCTAssertEqual(extensionReducer.visibleProjectionFastPathCount, 1)
}

func test_sessionReducerTransitionPreservesInconsistentInitialVisibleProjection() {
    let seedRoot = SessionMessageSnapshot(
        eventID: "session-inconsistent-root", role: "user", text: "seed",
        sourceEvent: EventRef(journal: sessionTransitionJournal, eventID: "session-inconsistent-root"))
    let synthetic = SessionMessageSnapshot(
        eventID: "session-inconsistent-synthetic", role: "assistant", text: "synthetic visible row")
    var initial = SessionSnapshot()
    initial.journal = sessionTransitionJournal
    initial.session = sessionTransitionSession
    initial.messageHistory = [seedRoot]
    initial.messages = [seedRoot, synthetic]
    initial.semanticTip = seedRoot.sourceEvent
    initial.seenEventIDs = [seedRoot.eventID]
    initial.lastEventID = seedRoot.eventID
    initial.lastSequence = 1

    let child = sessionTransitionEvent(
        TimelineEventType.messageCommitted, id: "session-inconsistent-child", sequence: 2,
        previous: seedRoot.eventID,
        conversationParent: seedRoot.sourceEvent,
        payload: .object(["role": "assistant", "text": "new child"]))
    let select = sessionTransitionEvent(
        TimelineEventType.sessionTipSelected, id: "session-inconsistent-select", sequence: 3,
        previous: child.eventID,
        conversationParent: EventRef(journal: sessionTransitionJournal, eventID: child.eventID))

    var live = SessionReducer(snapshot: initial)
    live.apply(child)
    live.apply(select)
    XCTAssertEqual(live.snapshot.messages.map(\.text), ["seed", "synthetic visible row", "new child"])
    XCTAssertEqual(live.snapshot.messageHistory.map(\.text), ["seed", "new child"])

    var direct = InMemorySessionTransitionState(snapshot: initial)
    SessionReducerTransition.apply(child, to: &direct)
    SessionReducerTransition.apply(select, to: &direct)
    XCTAssertEqual(direct.snapshot, live.snapshot)
}

let casesSessionReducerTransition: [Case] = [
    ("phase3 Session transition matches live and cold prefixes with golden projection", {
        test_sessionReducerTransitionDifferentialAtEveryPrefix()
    }),
    ("phase3 Session transition preserves malformed and unknown evidence", {
        test_sessionReducerTransitionPreservesMalformedUnknownEvidence()
    }),
    ("phase3 Session transition projects attachments and context failures", {
        test_sessionReducerTransitionProjectsAttachmentsAndContextFailures()
    }),
    ("phase3 Session transition materializes branches with bounded instrumentation", {
        test_sessionReducerTransitionMaterializesBranchesAndPreservesInstrumentation()
    }),
    ("phase3 Session transition preserves inconsistent initial visible projection", {
        test_sessionReducerTransitionPreservesInconsistentInitialVisibleProjection()
    }),
]
