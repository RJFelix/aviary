import Foundation
@testable import AviaryCore

private let transitionTestWork = WorkRef(workHostID: "transition-host", workID: "transition-work")
private let transitionTestHost = WorkHostRef(transitionTestWork.workHostID)
private let transitionTestJournal = JournalRef.work(transitionTestWork, journalID: "transition-journal")
private let transitionTestSession = SessionRef("transition-session")

private func transitionTestEvent(
    _ type: String,
    id: String,
    sequence: Int,
    previous: String? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    session: SessionRef? = nil,
    attachment: SessionAttachmentRef? = nil,
    run: RunRef? = nil,
    turn: TurnRef? = nil,
    action: ActionRef? = nil,
    handle: HandleRef? = nil,
    command: CommandRef? = nil,
    client: ClientRef? = nil,
    hostSequence: Int? = nil,
    causedBy: EventRef? = nil,
    schemaVersion: Int = TimelineEvent.currentSchemaVersion,
    payloadVersion: Int = 1,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:]),
    actorID: String = "transition-test"
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: transitionTestJournal, sequence: sequence,
        hostSequence: hostSequence, command: command, previousEventID: previous,
        causedByEventID: causedBy, session: session, work: work, workHost: workHost,
        client: client, sessionAttachment: attachment, run: run, turn: turn,
        action: action, handle: handle,
        actor: TimelineActor(actorID: actorID, kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
        schemaVersion: schemaVersion, payloadVersion: payloadVersion,
        type: type, declaredDomains: declaredDomains, payload: payload)
}

private func applyTransition(_ event: TimelineEvent, to state: inout InMemoryWorkTransitionState) {
    WorkReducerTransition.apply(event, to: &state)
}

private func mixedTransitionJournal() -> [TimelineEvent] {
    let attachment = SessionAttachmentRef("mixed-attachment")
    let run = RunRef("mixed-run")
    let action = ActionRef("mixed-action")
    let handle = HandleRef("mixed-handle")
    return [
        transitionTestEvent(TimelineEventType.workCreated, id: "mixed-1", sequence: 1,
                            work: transitionTestWork, workHost: transitionTestHost),
        transitionTestEvent(TimelineEventType.sessionAttached, id: "mixed-2", sequence: 2,
                            previous: "mixed-1", work: transitionTestWork,
                            session: transitionTestSession, attachment: attachment),
        transitionTestEvent(TimelineEventType.runStarted, id: "mixed-3", sequence: 3,
                            previous: "mixed-2", work: transitionTestWork,
                            session: transitionTestSession, attachment: attachment, run: run,
                            payload: .object(["model_id": "transition-model"])),
        transitionTestEvent(TimelineEventType.actionIntent, id: "mixed-4", sequence: 4,
                            previous: "mixed-3", work: transitionTestWork, run: run,
                            action: action, payload: .object([
                                "state": "proposed", "kind": "python", "intent": "mixed action"
                            ])),
        transitionTestEvent(TimelineEventType.actionStarted, id: "mixed-5", sequence: 5,
                            previous: "mixed-4", work: transitionTestWork, run: run,
                            action: action, payload: .object(["state": "running"])),
        transitionTestEvent("future.mixed", id: "mixed-6", sequence: 6,
                            previous: "mixed-5", work: transitionTestWork,
                            declaredDomains: [.runtime], payload: .object(["opaque": "future"])),
        transitionTestEvent(TimelineEventType.actionOutcome, id: "mixed-7", sequence: 7,
                            previous: "mixed-6", work: transitionTestWork, run: run,
                            action: action, payload: .object(["state": "not-a-state"])),
        transitionTestEvent(TimelineEventType.actionOutcome, id: "mixed-8", sequence: 8,
                            previous: "mixed-7", work: transitionTestWork, run: run,
                            action: action,
                            payload: .object(["state": "succeeded", "retry_safety": "idempotent"])),
        transitionTestEvent(TimelineEventType.handleStarted, id: "mixed-9", sequence: 9,
                            previous: "mixed-8", work: transitionTestWork, run: run,
                            handle: handle, payload: .object(["state": "running"])),
        transitionTestEvent(TimelineEventType.handleOutcome, id: "mixed-10", sequence: 10,
                            previous: "mixed-9", work: transitionTestWork, run: run,
                            handle: handle, payload: .object(["state": "completed"])),
        transitionTestEvent(TimelineEventType.runFinished, id: "mixed-11", sequence: 11,
                            previous: "mixed-10", work: transitionTestWork,
                            session: transitionTestSession, attachment: attachment, run: run),
        transitionTestEvent(TimelineEventType.sessionDetached, id: "mixed-12", sequence: 12,
                            previous: "mixed-11", work: transitionTestWork, session: transitionTestSession,
                            attachment: attachment),
        transitionTestEvent(TimelineEventType.workCompleted, id: "mixed-13", sequence: 13,
                            previous: "mixed-12", work: transitionTestWork),
    ]
}

/// The façade, its cold reducer, and the state seam must agree at every prefix, including after
/// malformed records. Golden terminal assertions below independently pin the externally visible
/// contract so a mutation shared by all three execution paths cannot pass on parity alone.
func test_workReducerTransitionDifferentialAtEveryCutPoint() {
    let events = mixedTransitionJournal()
    var live = WorkReducer()
    var direct = InMemoryWorkTransitionState()

    for index in events.indices {
        live.apply(events[index])
        applyTransition(events[index], to: &direct)
        let cold = WorkReducer.reduce(events.prefix(index + 1))
        XCTAssertEqual(live.snapshot, cold, "live/cold mismatch at cut point \(index + 1)")
        XCTAssertEqual(direct.snapshot, cold, "adapter/cold mismatch at cut point \(index + 1)")
    }

    let snapshot = live.snapshot
    XCTAssertEqual(snapshot.lifecycle, .completed)
    XCTAssertEqual(snapshot.execution, .idle)
    XCTAssertTrue(snapshot.attachedSessionIDs.isEmpty)
    XCTAssertEqual(snapshot.actions["mixed-action"]?.state, .succeeded)
    XCTAssertEqual(snapshot.actions["mixed-action"]?.retrySafety, .idempotent)
    XCTAssertTrue(snapshot.activeActionIDs.isEmpty)
    XCTAssertEqual(snapshot.handles["mixed-handle"]?.state, "completed")
    XCTAssertEqual(snapshot.unknownDomains, [.runtime])
    XCTAssertEqual(snapshot.unknownEvents.map(\.event.eventID), ["mixed-6"])
    XCTAssertEqual(snapshot.quarantinedEvents.map(\.eventID), ["mixed-7"])
    XCTAssertEqual(snapshot.lastEventID, "mixed-13")
    XCTAssertEqual(snapshot.lastSequence, 13)
    XCTAssertTrue(snapshot.structuralIntegrityValid)
    XCTAssertFalse(snapshot.semanticProjectionValid)
}

func test_workReducerTransitionPreservesInconsistentActiveActionMembershipOnIntent() {
    let action = ActionRef("inconsistent-active-action")
    var initial = WorkSnapshot()
    initial.journal = transitionTestJournal
    initial.work = transitionTestWork
    initial.workHost = transitionTestHost
    initial.activeActionIDs = [action.actionID]
    initial.lastEventID = "inconsistent-seed"
    initial.lastSequence = 1
    initial.eventSequences["inconsistent-seed"] = 1
    initial.seenEventIDs.insert("inconsistent-seed")

    let intent = transitionTestEvent(
        TimelineEventType.actionIntent,
        id: "inconsistent-intent", sequence: 2, previous: "inconsistent-seed",
        work: transitionTestWork, action: action,
        payload: .object([
            "state": "proposed", "kind": "python", "intent": "preserve membership"
        ]))
    var reducer = WorkReducer(snapshot: initial)
    reducer.apply(intent)

    XCTAssertEqual(reducer.snapshot.actions[action.actionID]?.state, .proposed)
    XCTAssertEqual(reducer.snapshot.activeActionIDs, [action.actionID])
    XCTAssertTrue(reducer.snapshot.semanticProjectionValid)
    XCTAssertEqual(reducer.snapshot.lastEventID, intent.eventID)
}

func test_workReducerTransitionRejectsDuplicateEventsAndRuns() {
    let first = transitionTestEvent(TimelineEventType.workCreated, id: "duplicate-event-1", sequence: 1,
                                    work: transitionTestWork)
    let attachment = SessionAttachmentRef("duplicate-attachment")
    let attached = transitionTestEvent(
        TimelineEventType.sessionAttached, id: "duplicate-event-2", sequence: 2,
        previous: first.eventID, work: transitionTestWork,
        session: transitionTestSession, attachment: attachment)
    let run = RunRef("duplicate-run")
    let started = transitionTestEvent(TimelineEventType.runStarted, id: "duplicate-event-3", sequence: 3,
                                     previous: attached.eventID, work: transitionTestWork,
                                     session: transitionTestSession, attachment: attachment, run: run)
    let duplicateEvent = transitionTestEvent(TimelineEventType.runStarted, id: started.eventID, sequence: 4,
                                             previous: started.eventID, work: transitionTestWork, run: run)

    var eventReducer = WorkReducer()
    eventReducer.apply(first)
    eventReducer.apply(attached)
    eventReducer.apply(started)
    eventReducer.apply(duplicateEvent)
    XCTAssertFalse(eventReducer.snapshot.structuralIntegrityValid)
    XCTAssertEqual(eventReducer.snapshot.seenEventIDs,
                   [first.eventID, attached.eventID, started.eventID])
    XCTAssertEqual(eventReducer.snapshot.quarantinedEvents, [duplicateEvent])

    let finished = transitionTestEvent(TimelineEventType.runFinished, id: "duplicate-run-3", sequence: 4,
                                       previous: started.eventID, work: transitionTestWork,
                                       session: transitionTestSession, attachment: attachment, run: run)
    let duplicateRun = transitionTestEvent(TimelineEventType.runStarted, id: "duplicate-run-4", sequence: 5,
                                           previous: finished.eventID, work: transitionTestWork,
                                           session: transitionTestSession, attachment: attachment, run: run)
    var runReducer = WorkReducer()
    runReducer.apply(first)
    runReducer.apply(attached)
    runReducer.apply(started)
    runReducer.apply(finished)
    runReducer.apply(duplicateRun)
    XCTAssertTrue(runReducer.snapshot.structuralIntegrityValid)
    XCTAssertFalse(runReducer.snapshot.semanticProjectionValid)
    XCTAssertNil(runReducer.snapshot.activeRun)
    XCTAssertEqual(runReducer.snapshot.observedRunIDs, [run.runID])
    XCTAssertEqual(runReducer.snapshot.quarantinedEvents, [duplicateRun])
}

func test_workReducerTransitionPreservesCommandCausalIdentity() {
    let client = ClientRef("transition-client")
    let attachment = SessionAttachmentRef("transition-command-attachment")
    let command = CommandRef(
        commandID: "transition-command", client: client, sessionAttachment: attachment,
        causalCursor: JournalCursor(journal: transitionTestJournal, eventID: "command-1", sequence: 1))
    let root = transitionTestEvent(TimelineEventType.workCreated, id: "command-1", sequence: 1,
                                   work: transitionTestWork)
    let accepted = transitionTestEvent(
        TimelineEventType.commandAccepted, id: "command-2", sequence: 2, previous: root.eventID,
        work: transitionTestWork, attachment: attachment, command: command, client: client,
        hostSequence: 10, causedBy: EventRef(journal: transitionTestJournal, eventID: root.eventID))
    let delivered = transitionTestEvent(
        TimelineEventType.commandDelivered, id: "command-3", sequence: 3, previous: accepted.eventID,
        work: transitionTestWork, attachment: attachment, command: command, client: client,
        hostSequence: 11, causedBy: EventRef(journal: transitionTestJournal, eventID: accepted.eventID))
    let badDelivery = transitionTestEvent(
        TimelineEventType.commandDelivered, id: "command-4", sequence: 4, previous: delivered.eventID,
        work: transitionTestWork, attachment: attachment, command: command, client: client,
        hostSequence: 12, causedBy: EventRef(journal: transitionTestJournal, eventID: root.eventID))

    var reducer = WorkReducer()
    reducer.apply(root)
    reducer.apply(accepted)
    reducer.apply(delivered)
    let receipt = reducer.snapshot.commands[command.commandID]
    XCTAssertEqual(receipt?.state, .delivered)
    XCTAssertEqual(receipt?.acceptanceEventRef?.eventID, accepted.eventID)
    XCTAssertEqual(receipt?.deliveryEventRef?.eventID, delivered.eventID)
    reducer.apply(badDelivery)
    XCTAssertFalse(reducer.snapshot.semanticProjectionValid)
    XCTAssertEqual(reducer.snapshot.commands[command.commandID]?.deliveryEventRef?.eventID, delivered.eventID)
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [badDelivery])
}

func test_workReducerTransitionProjectsActionLifecycleAndCheckedCount() {
    let attachment = SessionAttachmentRef("action-attachment")
    let run = RunRef("action-run")
    let action = ActionRef("action-lifecycle")
    let events = [
        transitionTestEvent(TimelineEventType.workCreated, id: "action-1", sequence: 1,
                            work: transitionTestWork),
        transitionTestEvent(TimelineEventType.sessionAttached, id: "action-2", sequence: 2,
                            previous: "action-1", work: transitionTestWork,
                            session: transitionTestSession, attachment: attachment),
        transitionTestEvent(TimelineEventType.runStarted, id: "action-3", sequence: 3,
                            previous: "action-2", work: transitionTestWork,
                            session: transitionTestSession, attachment: attachment, run: run),
        transitionTestEvent(TimelineEventType.actionIntent, id: "action-4", sequence: 4,
                            previous: "action-3", work: transitionTestWork, run: run, action: action,
                            payload: .object(["state": "proposed", "kind": "python", "intent": "do it"])),
        transitionTestEvent(TimelineEventType.actionStarted, id: "action-5", sequence: 5,
                            previous: "action-4", work: transitionTestWork, run: run, action: action,
                            payload: .object(["state": "queued"])),
        transitionTestEvent(TimelineEventType.actionOutcome, id: "action-6", sequence: 6,
                            previous: "action-5", work: transitionTestWork, run: run, action: action,
                            payload: .object(["state": "running"])),
        transitionTestEvent(TimelineEventType.actionOutcome, id: "action-7", sequence: 7,
                            previous: "action-6", work: transitionTestWork, run: run, action: action,
                            payload: .object(["state": "succeeded", "retry_safety": "idempotent"])),
        transitionTestEvent(TimelineEventType.actionOutcome, id: "action-8", sequence: 8,
                            previous: "action-7", work: transitionTestWork, run: run, action: action,
                            payload: .object(["state": "succeeded", "retry_safety": "idempotent"])),
    ]
    var reducer = WorkReducer()
    for event in events { reducer.apply(event) }
    XCTAssertEqual(reducer.snapshot.actions[action.actionID]?.state, .succeeded)
    XCTAssertTrue(reducer.snapshot.activeActionIDs.isEmpty)
    XCTAssertEqual(reducer.snapshot.execution, .idle)
    XCTAssertFalse(reducer.snapshot.semanticProjectionValid)
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [events.last!])

    var state = InMemoryWorkTransitionState()
    for event in events { applyTransition(event, to: &state) }
    XCTAssertEqual(state.activeActionCount, 0)
}

func test_workReducerTransitionGuardsLiveHandleTerminalState() {
    let attachment = SessionAttachmentRef("handle-attachment")
    let run = RunRef("handle-run")
    let handle = HandleRef("handle-terminal")
    let events = [
        transitionTestEvent(TimelineEventType.workCreated, id: "handle-1", sequence: 1,
                            work: transitionTestWork),
        transitionTestEvent(TimelineEventType.sessionAttached, id: "handle-2", sequence: 2,
                            previous: "handle-1", work: transitionTestWork,
                            session: transitionTestSession, attachment: attachment),
        transitionTestEvent(TimelineEventType.runStarted, id: "handle-3", sequence: 3,
                            previous: "handle-2", work: transitionTestWork,
                            session: transitionTestSession, attachment: attachment, run: run),
        transitionTestEvent(TimelineEventType.handleStarted, id: "handle-4", sequence: 4,
                            previous: "handle-3", work: transitionTestWork, run: run, handle: handle,
                            payload: .object(["state": "running"])),
        transitionTestEvent(TimelineEventType.handleOutcome, id: "handle-5", sequence: 5,
                            previous: "handle-4", work: transitionTestWork, run: run, handle: handle,
                            payload: .object(["state": "completed"])),
        transitionTestEvent(TimelineEventType.handleOutcome, id: "handle-6", sequence: 6,
                            previous: "handle-5", work: transitionTestWork, run: run, handle: handle,
                            payload: .object(["state": "failed"])),
    ]
    var reducer = WorkReducer()
    for event in events { reducer.apply(event) }
    XCTAssertEqual(reducer.snapshot.handles[handle.handleID]?.state, "completed")
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [events.last!])
    XCTAssertTrue(reducer.snapshot.structuralIntegrityValid)
}

func test_workReducerTransitionKeepsSessionAttachedUntilLastAttachmentDetaches() {
    let first = SessionAttachmentRef("session-attachment-a")
    let second = SessionAttachmentRef("session-attachment-b")
    let events = [
        transitionTestEvent(TimelineEventType.workCreated, id: "attachment-1", sequence: 1,
                            work: transitionTestWork),
        transitionTestEvent(TimelineEventType.sessionAttached, id: "attachment-2", sequence: 2,
                            previous: "attachment-1", work: transitionTestWork,
                            session: transitionTestSession, attachment: first),
        transitionTestEvent(TimelineEventType.sessionAttached, id: "attachment-3", sequence: 3,
                            previous: "attachment-2", work: transitionTestWork,
                            session: transitionTestSession, attachment: second),
        transitionTestEvent(TimelineEventType.sessionDetached, id: "attachment-4", sequence: 4,
                            previous: "attachment-3", work: transitionTestWork, attachment: first),
        transitionTestEvent(TimelineEventType.sessionAttached, id: "attachment-5", sequence: 5,
                            previous: "attachment-4", work: transitionTestWork,
                            session: transitionTestSession, attachment: first),
        transitionTestEvent(TimelineEventType.sessionDetached, id: "attachment-6", sequence: 6,
                            previous: "attachment-5", work: transitionTestWork, attachment: second),
    ]
    var state = InMemoryWorkTransitionState()
    applyTransition(events[0], to: &state)
    applyTransition(events[1], to: &state)
    applyTransition(events[2], to: &state)
    XCTAssertEqual(state.activeSessionAttachmentCount(for: transitionTestSession), 2)
    XCTAssertEqual(state.snapshot.attachedSessionIDs, [transitionTestSession.sessionID])
    applyTransition(events[3], to: &state)
    XCTAssertEqual(state.activeSessionAttachmentCount(for: transitionTestSession), 1)
    XCTAssertEqual(state.snapshot.attachedSessionIDs, [transitionTestSession.sessionID])
    applyTransition(events[4], to: &state)
    XCTAssertEqual(state.activeSessionAttachmentCount(for: transitionTestSession), 2)
    XCTAssertEqual(state.snapshot.attachedSessionIDs, [transitionTestSession.sessionID])
    applyTransition(events[5], to: &state)
    XCTAssertEqual(state.activeSessionAttachmentCount(for: transitionTestSession), 1)
    XCTAssertEqual(state.snapshot.attachedSessionIDs, [transitionTestSession.sessionID])
    // Detach the reattached first attachment, leaving no active attachments.
    let finalDetach = transitionTestEvent(TimelineEventType.sessionDetached, id: "attachment-7", sequence: 7,
                                          previous: "attachment-6", work: transitionTestWork, attachment: first)
    applyTransition(finalDetach, to: &state)
    XCTAssertEqual(state.activeSessionAttachmentCount(for: transitionTestSession), 0)
    XCTAssertTrue(state.snapshot.attachedSessionIDs.isEmpty)
    // A second detach of an already detached attachment is harmless and must not underflow.
    let repeatedDetach = transitionTestEvent(TimelineEventType.sessionDetached, id: "attachment-8", sequence: 8,
                                             previous: finalDetach.eventID, work: transitionTestWork, attachment: first)
    applyTransition(repeatedDetach, to: &state)
    XCTAssertEqual(state.activeSessionAttachmentCount(for: transitionTestSession), 0)
    XCTAssertTrue(state.snapshot.attachedSessionIDs.isEmpty)
}

func test_workReducerTransitionSeparatesUnknownAndSemanticQuarantineEvidence() {
    let created = transitionTestEvent(TimelineEventType.workCreated, id: "evidence-1", sequence: 1,
                                      work: transitionTestWork)
    let unknown = transitionTestEvent("future.evidence", id: "evidence-2", sequence: 2,
                                     previous: created.eventID, work: transitionTestWork,
                                     declaredDomains: [.context, .runtime], payload: .object(["raw": true]))
    let malformed = transitionTestEvent(TimelineEventType.modelChanged, id: "evidence-3", sequence: 3,
                                       previous: unknown.eventID, work: transitionTestWork)
    let valid = transitionTestEvent(TimelineEventType.modelChanged, id: "evidence-4", sequence: 4,
                                   previous: malformed.eventID, work: transitionTestWork,
                                   payload: .object(["model_id": "after-error"]))
    var reducer = WorkReducer()
    reducer.apply(created)
    reducer.apply(unknown)
    reducer.apply(malformed)
    reducer.apply(valid)
    XCTAssertEqual(reducer.snapshot.unknownEvents.map(\.event.eventID), [unknown.eventID])
    XCTAssertEqual(reducer.snapshot.unknownDomains, [.context, .runtime])
    XCTAssertEqual(reducer.snapshot.quarantinedEvents, [malformed])
    XCTAssertFalse(reducer.snapshot.semanticProjectionValid)
    XCTAssertTrue(reducer.snapshot.structuralIntegrityValid)
    XCTAssertEqual(reducer.snapshot.modelID, "after-error")
}

func test_workReducerTransitionCountersDoNotUnderflow() {
    var state = InMemoryWorkTransitionState()
    let action = ActionRef("counter-action")
    let proposed = WorkActionSnapshot(action: action, kind: .python)
    let running = WorkActionSnapshot(action: action, state: .running, kind: .python)
    let terminal = WorkActionSnapshot(action: action, state: .succeeded, retrySafety: .idempotent, kind: .python)
    state.stageAction(proposed, active: false)
    state.stageAction(proposed, active: false)
    XCTAssertEqual(state.activeActionCount, 0)
    state.stageAction(running, active: true)
    state.stageAction(running, active: true)
    XCTAssertEqual(state.activeActionCount, 1)
    state.stageAction(terminal, active: false)
    state.stageAction(terminal, active: false)
    XCTAssertEqual(state.activeActionCount, 0)

    let handle = HandleRef("counter-handle")
    state.stageHandle(WorkHandleSnapshot(handle: handle, state: "running"))
    XCTAssertEqual(state.outstandingHandleCount, 1)
    state.stageHandle(WorkHandleSnapshot(handle: handle, state: "completed"))
    state.stageHandle(WorkHandleSnapshot(handle: handle, state: "completed"))
    XCTAssertEqual(state.outstandingHandleCount, 0)
    state.stageSessionAttachmentDetached("missing-attachment")
    XCTAssertEqual(state.outstandingHandleCount, 0)
}

let casesWorkReducerTransition: [Case] = [
    ("phase3 Work transition matches live and cold reducer at every prefix", {
        test_workReducerTransitionDifferentialAtEveryCutPoint()
    }),
    ("phase3 Work transition rejects duplicate events and Run identities", {
        test_workReducerTransitionRejectsDuplicateEventsAndRuns()
    }),
    ("phase3 Work transition preserves command causal identity", {
        test_workReducerTransitionPreservesCommandCausalIdentity()
    }),
    ("phase3 Work transition projects action lifecycle with checked counts", {
        test_workReducerTransitionProjectsActionLifecycleAndCheckedCount()
    }),
    ("phase3 Work transition guards terminal Handle state", {
        test_workReducerTransitionGuardsLiveHandleTerminalState()
    }),
    ("phase3 Work transition keeps Session attached until the last detach", {
        test_workReducerTransitionKeepsSessionAttachedUntilLastAttachmentDetaches()
    }),
    ("phase3 Work transition separates unknown and quarantined evidence", {
        test_workReducerTransitionSeparatesUnknownAndSemanticQuarantineEvidence()
    }),
    ("phase3 Work transition counters do not underflow", {
        test_workReducerTransitionCountersDoNotUnderflow()
    }),
    ("phase3 Work transition preserves inconsistent active membership on intent", {
        test_workReducerTransitionPreservesInconsistentActiveActionMembershipOnIntent()
    }),
]
