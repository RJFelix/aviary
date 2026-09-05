import Foundation
@testable import AviaryCore

private let boundedProjectionHost = WorkHostRef("bounded-projection-host")
private let boundedProjectionWork = WorkRef(
    workHostID: boundedProjectionHost.workHostID, workID: "bounded-projection-work")
private let boundedProjectionWorkJournal = JournalRef.work(
    boundedProjectionWork, journalID: "bounded-projection-work-journal")
private let boundedProjectionSession = SessionRef("bounded-projection-session")
private let boundedProjectionSessionJournal = JournalRef.session(
    boundedProjectionSession, journalID: "bounded-projection-session-journal",
    authority: TimelineAuthorityRef("bounded-projection-authority"))
private let boundedProjectionActor = TimelineActor(
    actorID: "bounded-projection-host", kind: "work-host")

private func boundedProjectionEvent(
    id: String,
    journal: JournalRef,
    sequence: Int,
    type: String,
    session: SessionRef? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    run: RunRef? = nil,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: journal, sequence: sequence,
        previousEventID: sequence > 1 ? "\(id.prefix(1))\(sequence - 1)" : nil,
        session: session, work: work, workHost: workHost, run: run,
        actor: boundedProjectionActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, declaredDomains: declaredDomains, payload: payload)
}

private func boundedProjectionWorkEvent(
    id: String, sequence: Int, type: String,
    payload: JSONValue = .object([:]), run: RunRef? = nil, handle: HandleRef? = nil,
    action: ActionRef? = nil,
    declaredDomains: Set<TimelineDomain> = []
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: boundedProjectionWorkJournal, sequence: sequence,
        previousEventID: sequence > 1 ? "w\(sequence - 1)" : nil,
        work: boundedProjectionWork, workHost: boundedProjectionHost, run: run, action: action,
        handle: handle,
        actor: boundedProjectionActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, declaredDomains: declaredDomains, payload: payload)
}

private func boundedProjectionSource(
    journal: JournalRef, events: [TimelineEvent]
) throws -> BoundedReducerProjectionSource {
    var prefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
    var byteCount = 0
    for event in events {
        let line = try DisposableTimelineProjectionStore.canonicalJSON(event)
        byteCount += line.count + 1
        let lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
        prefix = DisposableTimelineProjectionStore.advancePrefixDigest(
            prefix, lineDigest: lineDigest)
    }
    let cursor = JournalCursor(
        journal: journal, eventID: events.last?.eventID, sequence: events.last?.sequence ?? 0)
    return BoundedReducerProjectionSource(
        journal: journal, cursor: cursor, sourceID: "bounded-projection-source",
        sourceGeneration: String(repeating: "a", count: 64),
        sourceFingerprint: String(repeating: "b", count: 64),
        sourceByteCount: byteCount, prefixByteCount: byteCount, prefixDigest: prefix)
}

private func boundedProjectionEmptySource(
    journal: JournalRef
) -> BoundedReducerProjectionSource {
    BoundedReducerProjectionSource(
        journal: journal,
        cursor: JournalCursor(journal: journal, sequence: 0),
        sourceID: "bounded-projection-source",
        sourceGeneration: String(repeating: "a", count: 64),
        sourceFingerprint: String(repeating: "b", count: 64),
        sourceByteCount: 0, prefixByteCount: 0,
        prefixDigest: DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal))
}

private func forgedWorkHead(
    _ head: BoundedWorkReducerHead,
    mutateIndex: BoundedReducerProjectionIndex,
    state: BoundedReducerProjectionState
) throws -> DisposableTimelineProjectionStore.OpaqueReducerHead {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: head.encodedMetadata()) as? [String: Any])
    var coverage = try XCTUnwrap(object["coverage"] as? [String: Any])
    var indexes = try XCTUnwrap(coverage["indexCoverage"] as? [[String: Any]])
    for offset in indexes.indices where indexes[offset]["index"] as? String == mutateIndex.rawValue {
        indexes[offset]["state"] = state.rawValue
    }
    coverage["indexCoverage"] = indexes
    object["coverage"] = coverage
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return DisposableTimelineProjectionStore.OpaqueReducerHead(
        mediaType: BoundedWorkReducerHead.mediaType,
        schemaVersion: BoundedWorkReducerHead.schemaVersion,
        bytes: bytes)
}

func test_boundedProjectionMatchesPureReducersAndRoundTrips() throws {
    let workCreated = boundedProjectionWorkEvent(
        id: "w1", sequence: 1, type: TimelineEventType.workCreated)
    let workEvents = [workCreated]
    let workSource = try boundedProjectionSource(
        journal: boundedProjectionWorkJournal, events: workEvents)
    let pureWork = WorkReducer.reduce(workEvents)
    let workHead = try BoundedWorkReducerHead.build(events: workEvents, source: workSource)
    var workAccumulator = BoundedWorkReducerAccumulator()
    for event in workEvents { workAccumulator.append(event) }
    let accumulatedWork = try workAccumulator.finalize(source: workSource)
    XCTAssertEqual(accumulatedWork, workHead, "streaming and sequence construction must agree")

    XCTAssertEqual(workHead.work, pureWork.work)
    XCTAssertEqual(workHead.workHost, pureWork.workHost)
    XCTAssertEqual(workHead.lifecycle, pureWork.lifecycle)
    XCTAssertEqual(workHead.execution, pureWork.execution)
    XCTAssertEqual(workHead.lastEventID, pureWork.lastEventID)
    XCTAssertEqual(workHead.lastSequence, pureWork.lastSequence)
    XCTAssertEqual(workHead.source.cursor, workSource.cursor)
    XCTAssertEqual(workHead.coverage.scalarState, .complete)
    XCTAssertEqual(workHead.coverage.state, .complete)
    XCTAssertTrue(workHead.coverage.isControlling)

    let workBytes = try workHead.encodedMetadata()
    XCTAssertEqual(workBytes, try workHead.encodedMetadata(), "encoding must be deterministic")
    let restoredWork = try BoundedWorkReducerHead.decodeOpaqueReducerHead(
        workHead.opaqueReducerHead())
    XCTAssertEqual(restoredWork, workHead)
    XCTAssertFalse(
        String(decoding: workBytes, as: UTF8.self).contains("work-created-secret"),
        "a reducer head must not acquire raw event payload text")

    let sessionCreated = boundedProjectionEvent(
        id: "s1", journal: boundedProjectionSessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: boundedProjectionSession)
    let sessionEvents = [sessionCreated]
    let sessionSource = try boundedProjectionSource(
        journal: boundedProjectionSessionJournal, events: sessionEvents)
    let pureSession = SessionReducer.reduce(sessionEvents)
    let sessionHead = try BoundedSessionReducerHead.build(
        events: sessionEvents, source: sessionSource)
    var sessionAccumulator = BoundedSessionReducerAccumulator()
    for event in sessionEvents { sessionAccumulator.append(event) }
    let accumulatedSession = try sessionAccumulator.finalize(source: sessionSource)
    XCTAssertEqual(accumulatedSession, sessionHead, "streaming and sequence construction must agree")

    XCTAssertEqual(sessionHead.session, pureSession.session)
    XCTAssertEqual(sessionHead.lifecycle, pureSession.lifecycle)
    XCTAssertEqual(sessionHead.attention, pureSession.attention)
    XCTAssertEqual(sessionHead.lastEventID, pureSession.lastEventID)
    XCTAssertEqual(sessionHead.lastSequence, pureSession.lastSequence)
    XCTAssertEqual(sessionHead.coverage.scalarState, .complete)
    XCTAssertEqual(sessionHead.coverage.state, .complete)
    let sessionBytes = try sessionHead.encodedMetadata()
    XCTAssertEqual(sessionBytes, try sessionHead.encodedMetadata(), "encoding must be deterministic")
    let restoredSession = try BoundedSessionReducerHead.decodeOpaqueReducerHead(
        sessionHead.opaqueReducerHead())
    XCTAssertEqual(restoredSession, sessionHead)
}

func test_boundedProjectionScalarProvenanceTracksActualTransitions() throws {
    let failedEvents = [
        boundedProjectionWorkEvent(
            id: "w1", sequence: 1, type: TimelineEventType.workCreated),
        boundedProjectionWorkEvent(
            id: "w2", sequence: 2, type: TimelineEventType.workFailed),
    ]
    let failedHead = try BoundedWorkReducerHead.build(
        events: failedEvents,
        source: boundedProjectionSource(
            journal: boundedProjectionWorkJournal, events: failedEvents))
    XCTAssertEqual(failedHead.lifecycle, .active)
    XCTAssertEqual(failedHead.lifecycleEvent?.reference.eventID, "w1")
    XCTAssertEqual(failedHead.execution, .failed)
    XCTAssertEqual(failedHead.executionEvent?.reference.eventID, "w2")
    XCTAssertEqual(failedHead.coverage.scalarState, .complete)

    let run = RunRef("provenance-run")
    let action = ActionRef("provenance-action")
    let actionEvents = [
        boundedProjectionWorkEvent(
            id: "w1", sequence: 1, type: TimelineEventType.workCreated),
        boundedProjectionWorkEvent(
            id: "w2", sequence: 2, type: TimelineEventType.runStarted,
            payload: .object(["model_id": .string("provenance-model")]), run: run),
        boundedProjectionWorkEvent(
            id: "w3", sequence: 3, type: TimelineEventType.actionIntent,
            payload: .object([
                "kind": .string(ActionKind.python.rawValue),
                "intent": .string("exercise execution provenance"),
                "state": .string(ActionExecutionState.proposed.rawValue),
            ]), run: run, action: action),
        boundedProjectionWorkEvent(
            id: "w4", sequence: 4, type: TimelineEventType.actionStarted,
            payload: .object(["state": .string(ActionExecutionState.running.rawValue)]),
            run: run, action: action),
        boundedProjectionWorkEvent(
            id: "w5", sequence: 5, type: TimelineEventType.actionOutcome,
            payload: .object([
                "state": .string(ActionExecutionState.failed.rawValue),
                "failure_kind": .string(ActionFailureKind.task.rawValue),
                "retry_safety": .string(ActionRetrySafety.unknown.rawValue),
            ]), run: run, action: action),
    ]
    let actionHead = try BoundedWorkReducerHead.build(
        events: actionEvents,
        source: boundedProjectionSource(
            journal: boundedProjectionWorkJournal, events: actionEvents))
    XCTAssertEqual(actionHead.execution, .failed)
    XCTAssertEqual(actionHead.executionEvent?.reference.eventID, "w5")
    XCTAssertEqual(actionHead.lifecycleEvent?.reference.eventID, "w1")
    XCTAssertEqual(actionHead.modelEvent?.reference.eventID, "w2")
}

func test_boundedProjectionRetainsUnsettledRowsBeforeResolvedRows() throws {
    let run = RunRef("run-1")
    var workEvents: [TimelineEvent] = [
        boundedProjectionWorkEvent(id: "w1", sequence: 1, type: TimelineEventType.workCreated),
        boundedProjectionWorkEvent(
            id: "w2", sequence: 2, type: TimelineEventType.runStarted,
            payload: .object(["model_id": .string("model-1")]), run: run),
    ]
    workEvents.append(contentsOf: [
        boundedProjectionWorkEvent(
            id: "w3", sequence: 3, type: TimelineEventType.handleStarted,
            payload: .object(["state": .string("running")]), run: run,
            handle: HandleRef("finished-handle")),
        boundedProjectionWorkEvent(
            id: "w4", sequence: 4, type: TimelineEventType.handleOutcome,
            payload: .object(["state": .string("completed")]), run: run,
            handle: HandleRef("finished-handle")),
        boundedProjectionWorkEvent(
            id: "w5", sequence: 5, type: TimelineEventType.handleStarted,
            payload: .object(["state": .string("running")]), run: run,
            handle: HandleRef("live-handle")),
    ])
    let oldAction = ActionRef("resolved-old")
    let activeAction = ActionRef("active-action")
    let newAction = ActionRef("resolved-new")
    workEvents.append(contentsOf: [
        boundedProjectionWorkEvent(
            id: "w6", sequence: 6, type: TimelineEventType.actionIntent,
            payload: .object([
                "kind": .string(ActionKind.provider.rawValue),
                "intent": .string("old"), "state": .string(ActionExecutionState.proposed.rawValue)
            ]), run: run, action: oldAction),
        boundedProjectionWorkEvent(
            id: "w7", sequence: 7, type: TimelineEventType.actionStarted,
            payload: .object(["state": .string(ActionExecutionState.running.rawValue)]),
            run: run, action: oldAction),
        boundedProjectionWorkEvent(
            id: "w8", sequence: 8, type: TimelineEventType.actionOutcome,
            payload: .object([
                "state": .string(ActionExecutionState.succeeded.rawValue),
                "retry_safety": .string(ActionRetrySafety.safe.rawValue)
            ]), run: run, action: oldAction),
        boundedProjectionWorkEvent(
            id: "w9", sequence: 9, type: TimelineEventType.actionIntent,
            payload: .object([
                "kind": .string(ActionKind.provider.rawValue),
                "intent": .string("active"), "state": .string(ActionExecutionState.proposed.rawValue)
            ]), run: run, action: activeAction),
        boundedProjectionWorkEvent(
            id: "w10", sequence: 10, type: TimelineEventType.actionStarted,
            payload: .object(["state": .string(ActionExecutionState.running.rawValue)]),
            run: run, action: activeAction),
        boundedProjectionWorkEvent(
            id: "w11", sequence: 11, type: TimelineEventType.actionIntent,
            payload: .object([
                "kind": .string(ActionKind.python.rawValue),
                "intent": .string("new"), "state": .string(ActionExecutionState.proposed.rawValue)
            ]), run: run, action: newAction),
        boundedProjectionWorkEvent(
            id: "w12", sequence: 12, type: TimelineEventType.actionStarted,
            payload: .object(["state": .string(ActionExecutionState.running.rawValue)]),
            run: run, action: newAction),
        boundedProjectionWorkEvent(
            id: "w13", sequence: 13, type: TimelineEventType.actionOutcome,
            payload: .object([
                "state": .string(ActionExecutionState.failed.rawValue),
                "failure_kind": .string(ActionFailureKind.task.rawValue),
                "retry_safety": .string(ActionRetrySafety.unknown.rawValue)
            ]), run: run, action: newAction),
    ])
    let source = try boundedProjectionSource(journal: boundedProjectionWorkJournal, events: workEvents)
    let limits = BoundedTimelineReducerProjectionLimits(
        maximumActions: 1, maximumHandles: 1)
    let head = try BoundedWorkReducerHead.build(events: workEvents, source: source, limits: limits)

    XCTAssertEqual(head.actions.map { $0.action.actionID }, ["active-action"])
    XCTAssertEqual(head.handles.map { $0.handle.handleID }, ["live-handle"])
    XCTAssertEqual(head.coverage.scalarState, .complete)
    XCTAssertEqual(head.coverage.state, .sourceIncomplete)
    XCTAssertEqual(head.coverage.coverage(for: .actions)?.totalCount, 3)
    XCTAssertEqual(head.coverage.coverage(for: .actions)?.retainedCount, 1)
    XCTAssertEqual(head.coverage.coverage(for: .handles)?.omittedCount, 1)

    do {
        _ = try head.action(for: "resolved-old")
        XCTFail("a missing row in an incomplete bounded index must not look absent")
    } catch let error as BoundedTimelineReducerProjectionError {
        XCTAssertEqual(error, .indexIncomplete(.actions))
    }
    do {
        _ = try head.handle(for: "finished-handle")
        XCTFail("a missing Handle row in an incomplete bounded index must not look absent")
    } catch let error as BoundedTimelineReducerProjectionError {
        XCTAssertEqual(error, .indexIncomplete(.handles))
    }
    XCTAssertEqual(try head.handle(for: "live-handle").state, .active)

    let arbitraryHandle = BoundedWorkHandleIndexRecord(
        handle: HandleRef("raw-state-handle"), state: "terminal")
    XCTAssertEqual(arbitraryHandle.state, .active,
                   "only WorkReducer's exact terminal vocabulary is terminal")
    let arbitraryHandleBytes = try JSONEncoder().encode(arbitraryHandle)
    XCTAssertFalse(String(decoding: arbitraryHandleBytes, as: UTF8.self).contains("terminal"))
    let arbitraryChild = BoundedChildIndexRecord(childID: "raw-state-child", state: "paused-by-host")
    XCTAssertEqual(arbitraryChild.state, .unknown)
    let arbitraryChildBytes = try JSONEncoder().encode(arbitraryChild)
    XCTAssertFalse(String(decoding: arbitraryChildBytes, as: UTF8.self).contains("paused-by-host"))
}

func test_boundedProjectionUnknownAndCorruptPrefixesStayMetadataOnly() throws {
    let created = boundedProjectionWorkEvent(
        id: "w1", sequence: 1, type: TimelineEventType.workCreated)
    let unknown = boundedProjectionWorkEvent(
        id: "w2", sequence: 2, type: "future.runtime.effect",
        payload: .object(["secret": .string("do-not-copy")]),
        declaredDomains: [.runtime])
    let unknownEvents = [created, unknown]
    XCTAssertEqual(unknown.previousEventID, "w1")
    XCTAssertEqual(unknown.journal, created.journal)
    let pureBefore = WorkReducer.reduce(unknownEvents)
    XCTAssertEqual(pureBefore.corruptionReasons.count, 0)
    XCTAssertEqual(pureBefore.unknownEvents.count, 1)
    XCTAssertEqual(pureBefore.lastSequence, 2)
    XCTAssertEqual(pureBefore.lastEventID, "w2")
    let unknownHead: BoundedWorkReducerHead
    do {
        unknownHead = try BoundedWorkReducerHead.build(
            events: unknownEvents,
            source: try boundedProjectionSource(
                journal: boundedProjectionWorkJournal, events: unknownEvents))
    } catch {
        XCTFail("unknown prefix build failed: \(error)")
        throw error
    }
    let pureUnknown = WorkReducer.reduce(unknownEvents)

    XCTAssertEqual(unknownHead.lifecycle, pureUnknown.lifecycle)
    XCTAssertEqual(unknownHead.lastSequence, pureUnknown.lastSequence)
    XCTAssertEqual(unknownHead.unknowns.count, 1)
    XCTAssertEqual(unknownHead.unknowns.first?.event.reference.eventID, "w2")
    let unknownRow = try XCTUnwrap(unknownHead.unknowns.first)
    XCTAssertEqual(unknownRow.affectedDomains, [TimelineDomain.runtime])
    XCTAssertEqual(unknownHead.coverage.scalarState, .sourceIncomplete)
    XCTAssertEqual(unknownHead.coverage.state, .sourceIncomplete)
    XCTAssertTrue(unknownHead.coverage.isControlling == false)
    let unknownBytes = try unknownHead.encodedMetadata()
    XCTAssertFalse(String(decoding: unknownBytes, as: UTF8.self).contains("do-not-copy"))

    let malformed = boundedProjectionWorkEvent(
        id: "w2", sequence: 2, type: TimelineEventType.runFinished)
    let malformedEvents = [created, malformed]
    let malformedHead: BoundedWorkReducerHead
    do {
        malformedHead = try BoundedWorkReducerHead.build(
            events: malformedEvents,
            source: try boundedProjectionSource(
                journal: boundedProjectionWorkJournal, events: malformedEvents))
    } catch {
        XCTFail("malformed prefix build failed: \(error)")
        throw error
    }
    let pureMalformed = WorkReducer.reduce(malformedEvents)
    XCTAssertFalse(pureMalformed.semanticProjectionValid)
    XCTAssertEqual(malformedHead.corruption.count, 1)
    XCTAssertEqual(malformedHead.coverage.scalarState, .requiresRebuild)
    XCTAssertEqual(malformedHead.coverage.state, .requiresRebuild)
    XCTAssertEqual(malformedHead.coverage.corruptionCount, 1)
    XCTAssertEqual(malformedHead.coverage.coverage(for: .corruption)?.state, .requiresRebuild)
    XCTAssertTrue(malformedHead.corruption.first?.reason.digest.hasPrefix("sha256:") == true)
}

func test_boundedProjectionRejectsForgedCompleteIndexBeforeLookup() throws {
    let run = RunRef("run-1")
    let events = [
        boundedProjectionWorkEvent(id: "w1", sequence: 1, type: TimelineEventType.workCreated),
        boundedProjectionWorkEvent(
            id: "w2", sequence: 2, type: TimelineEventType.runStarted,
            payload: .object(["model_id": .string("model-1")]), run: run),
        boundedProjectionWorkEvent(
            id: "w3", sequence: 3, type: TimelineEventType.handleStarted,
            payload: .object(["state": .string("running")]), run: run,
            handle: HandleRef("kept")),
        boundedProjectionWorkEvent(
            id: "w4", sequence: 4, type: TimelineEventType.handleStarted,
            payload: .object(["state": .string("running")]), run: run,
            handle: HandleRef("evicted")),
    ]
    let source = try boundedProjectionSource(journal: boundedProjectionWorkJournal, events: events)
    let head = try BoundedWorkReducerHead.build(
        events: events, source: source,
        limits: BoundedTimelineReducerProjectionLimits(maximumHandles: 1))
    let forged = try forgedWorkHead(head, mutateIndex: .handles, state: .complete)
    do {
        _ = try BoundedWorkReducerHead.decodeOpaqueReducerHead(forged)
        XCTFail("a forged complete index must not be usable for indexNotFound lookups")
    } catch let error as BoundedTimelineReducerProjectionError {
        XCTAssertEqual(error, .invalidOffsets)
    }
}

func test_boundedSessionProjectionIndexesMessageAndContextMetadataWithoutBodies() throws {
    let sessionCreated = boundedProjectionEvent(
        id: "s1", journal: boundedProjectionSessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: boundedProjectionSession)
    let message = boundedProjectionEvent(
        id: "s2", journal: boundedProjectionSessionJournal, sequence: 2,
        type: TimelineEventType.messageCommitted, session: boundedProjectionSession,
        payload: .object(["role": .string("user"), "text": .string("private message body")]))
    let events = [sessionCreated, message]
    let head = try BoundedSessionReducerHead.build(
        events: events,
        source: boundedProjectionSource(journal: boundedProjectionSessionJournal, events: events))
    let promptSource = ContextManifestSource(
        sourceID: "memory:one", inclusionID: "include-memory", kind: .memory,
        status: .missing, label: "secret prompt description",
        deliveredByteCount: 0,
        deliveredDigest: "sha256:" + String(repeating: "d", count: 64),
        renderedByteCount: 0,
        renderedDigest: "sha256:" + String(repeating: "d", count: 64))
    let row = try head.message(for: "s2")
    XCTAssertEqual(row.text.byteCount, Data("private message body".utf8).count)
    XCTAssertEqual(head.coverage.scalarState, .complete)
    XCTAssertEqual(head.coverage.state, .complete)

    // Prompt source construction is intentionally tested independently here because the Session
    // reducer only receives a context crossing after the native body-retention boundary.
    let promptRow = BoundedPromptSourceIndexRecord(source: promptSource)
    XCTAssertEqual(promptRow.label, "source:memory")
    XCTAssertEqual(promptRow.labelByteCount, "secret prompt description".utf8.count)

    do {
        _ = try head.message(for: "missing-message")
        XCTFail("a missing row in a complete index should be explicit, not nil")
    } catch let error as BoundedTimelineReducerProjectionError {
        XCTAssertEqual(error, .indexNotFound(.messages))
    }
    let bytes = try head.encodedMetadata()
    let text = String(decoding: bytes, as: UTF8.self)
    XCTAssertFalse(text.contains("private message body"))
    XCTAssertFalse(text.contains("secret prompt description"))
    XCTAssertFalse(text.contains("repr"))
}

let casesBoundedTimelineReducerProjection: [Case] = [
    ("phase1 bounded projection: pure reducer parity and deterministic opaque round trips", {
        try test_boundedProjectionMatchesPureReducersAndRoundTrips()
    }),
    ("phase1 bounded projection: scalar provenance follows canonical transitions", {
        try test_boundedProjectionScalarProvenanceTracksActualTransitions()
    }),
    ("phase1 bounded projection: active and unsettled rows outrank resolved history", {
        try test_boundedProjectionRetainsUnsettledRowsBeforeResolvedRows()
    }),
    ("phase1 bounded projection: unknown and corrupt prefixes remain metadata-only", {
        try test_boundedProjectionUnknownAndCorruptPrefixesStayMetadataOnly()
    }),
    ("phase1 bounded projection: forged complete indexes fail closed before lookup", {
        try test_boundedProjectionRejectsForgedCompleteIndexBeforeLookup()
    }),
    ("phase1 bounded projection: Session indexes never persist message bodies", {
        try test_boundedSessionProjectionIndexesMessageAndContextMetadataWithoutBodies()
    }),
]
