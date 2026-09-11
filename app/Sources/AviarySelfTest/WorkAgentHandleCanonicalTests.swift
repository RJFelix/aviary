import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private let agentWork = WorkRef(workHostID: "agent-handle-host", workID: "agent-handle-work")
private let agentHost = WorkHostRef(agentWork.workHostID)
private let agentJournal = JournalRef.work(agentWork, journalID: "agent-handle-journal")
private let agentSession = SessionRef("agent-handle-session")
private let agentAttachment = SessionAttachmentRef("agent-handle-attachment")
private let agentRun = RunRef("agent-handle-run")
private let agentHandle = HandleRef("agent-handle")
private let agentDomains: Set<TimelineDomain> = [.work, .runtime, .externalEffects]

private func agentJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

private func agentBody(_ character: Character) -> TimelineBodyReference {
    let digest = "sha256:" + String(repeating: character, count: 64)
    return TimelineBodyReference(
        authority: agentJournal, referenceID: digest,
        mediaType: "application/json", byteCount: 31, digest: digest)
}

private func agentEvent(
    _ type: String, id: String, sequence: Int, previous: String?,
    session: SessionRef? = nil, attachment: SessionAttachmentRef? = nil,
    run: RunRef? = nil, handle: HandleRef? = nil,
    command: CommandRef? = nil, client: ClientRef? = nil,
    causedBy: EventRef? = nil, at: TimeInterval? = nil,
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: agentJournal, sequence: sequence,
        command: command, previousEventID: previous, causedByEventID: causedBy,
        session: session, work: agentWork, workHost: agentHost, client: client,
        sessionAttachment: attachment, run: run, handle: handle,
        actor: TimelineActor(actorID: "agent-handle-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: at ?? Double(sequence)),
        type: type, declaredDomains: type.hasPrefix("agent_handle.") ? agentDomains : [],
        payload: payload)
}

private func agentPrefix() -> (events: [TimelineEvent], origin: WorkAgentHandleOrigin) {
    let origin = WorkAgentHandleOrigin(
        work: agentWork, workHost: agentHost, session: agentSession,
        sessionAttachment: agentAttachment, run: agentRun)
    return ([
        agentEvent(TimelineEventType.workCreated, id: "agent-1", sequence: 1, previous: nil),
        agentEvent(TimelineEventType.sessionAttached, id: "agent-2", sequence: 2,
                   previous: "agent-1", session: agentSession, attachment: agentAttachment),
        agentEvent(TimelineEventType.runStarted, id: "agent-3", sequence: 3,
                   previous: "agent-2", session: agentSession, attachment: agentAttachment,
                   run: agentRun),
    ], origin)
}

private func queuedAgentEvent(
    origin: WorkAgentHandleOrigin, id: String = "agent-4", sequence: Int = 4,
    previous: String = "agent-3"
) -> TimelineEvent {
    agentEvent(
        TimelineEventType.agentHandleQueued, id: id, sequence: sequence, previous: previous,
        session: agentSession, attachment: agentAttachment, run: agentRun,
        handle: agentHandle,
        payload: agentJSON(WorkAgentHandleQueuedPayload(
            origin: origin, label: "background review",
            deadline: Date(timeIntervalSince1970: 100), requestBody: agentBody("a"))))
}

private func startedAgentEvent(
    id: String = "agent-5", sequence: Int = 5, previous: String = "agent-4"
) -> TimelineEvent {
    agentEvent(
        TimelineEventType.agentHandleStarted, id: id, sequence: sequence, previous: previous,
        session: agentSession, attachment: agentAttachment, run: agentRun,
        handle: agentHandle, causedBy: EventRef(journal: agentJournal, eventID: "agent-4"))
}

func test_workAgentHandleTerminalizesAfterOriginRunEnds() {
    let prefix = agentPrefix()
    let queued = queuedAgentEvent(origin: prefix.origin)
    let started = startedAgentEvent()
    let ended = agentEvent(
        TimelineEventType.runFinished, id: "agent-6", sequence: 6, previous: started.eventID,
        session: agentSession, attachment: agentAttachment, run: agentRun)
    let terminal = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-7", sequence: 7,
        previous: ended.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: started.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .succeeded, resultBody: agentBody("b"),
            cleanup: WorkAgentHandleCleanupProof(state: .quiesced))))
    let completed = agentEvent(
        TimelineEventType.workCompleted, id: "agent-8", sequence: 8,
        previous: terminal.eventID)

    let snapshot = WorkReducer.reduce(prefix.events + [queued, started, ended, terminal, completed])
    XCTAssertNil(snapshot.activeRun)
    XCTAssertEqual(snapshot.lifecycle, .completed)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.origin, prefix.origin)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.state, .terminal)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.terminalOutcome, .succeeded)
    XCTAssertTrue(snapshot.semanticProjectionValid)
}

func test_workAgentHandleRejectsForgedOriginAndConflictingTerminal() {
    let prefix = agentPrefix()
    let forged = WorkAgentHandleOrigin(
        work: agentWork, workHost: agentHost, session: agentSession,
        sessionAttachment: agentAttachment, run: RunRef("forged-run"))
    let forgedSnapshot = WorkReducer.reduce(prefix.events + [queuedAgentEvent(origin: forged)])
    XCTAssertNil(forgedSnapshot.agentHandles[agentHandle.handleID])
    XCTAssertFalse(forgedSnapshot.semanticProjectionValid)

    let queued = queuedAgentEvent(origin: prefix.origin)
    let terminal = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-5", sequence: 5,
        previous: queued.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: queued.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .canceled, cleanup: WorkAgentHandleCleanupProof(state: .notStarted))))
    let conflicting = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-6", sequence: 6,
        previous: terminal.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: terminal.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .failed, cleanup: WorkAgentHandleCleanupProof(state: .notStarted))))
    let snapshot = WorkReducer.reduce(prefix.events + [queued, terminal, conflicting])
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.terminalOutcome, .canceled)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.terminalEvent?.eventID, terminal.eventID)
    XCTAssertFalse(snapshot.semanticProjectionValid)
}

func test_workAgentHandleClientCancellationUsesDurableCallerAttachment() {
    let prefix = agentPrefix()
    let queued = queuedAgentEvent(origin: prefix.origin)
    let controllerSession = SessionRef("agent-controller-session")
    let controllerAttachment = SessionAttachmentRef("agent-controller-attachment")
    let attached = agentEvent(
        TimelineEventType.sessionAttached, id: "agent-5", sequence: 5,
        previous: queued.eventID, session: controllerSession, attachment: controllerAttachment)
    let client = ClientRef("agent-controller-client")
    let command = CommandRef(
        commandID: "agent-cancel-command", client: client,
        sessionAttachment: controllerAttachment,
        causalCursor: JournalCursor(
            journal: agentJournal, eventID: attached.eventID, sequence: attached.sequence))
    let canceled = agentEvent(
        TimelineEventType.agentHandleCancelRequested, id: "agent-6", sequence: 6,
        previous: attached.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle, command: command, client: client,
        causedBy: EventRef(journal: agentJournal, eventID: queued.eventID),
        payload: agentJSON(WorkAgentHandleCancelRequestedPayload(cause: .client)))
    let snapshot = WorkReducer.reduce(prefix.events + [queued, attached, canceled])
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.state, .cancelRequested)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.origin, prefix.origin)
    XCTAssertTrue(snapshot.semanticProjectionValid)
}

func test_workAgentHandleCompletionAndDestructionUseDistinctGates() {
    let prefix = agentPrefix()
    let queued = queuedAgentEvent(origin: prefix.origin)
    let prematureCompletion = agentEvent(
        TimelineEventType.workCompleted, id: "agent-5", sequence: 5,
        previous: queued.eventID)
    let liveSnapshot = WorkReducer.reduce(prefix.events + [queued, prematureCompletion])
    XCTAssertEqual(liveSnapshot.lifecycle, .active)
    XCTAssertFalse(liveSnapshot.semanticProjectionValid)

    let terminal = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-5", sequence: 5,
        previous: queued.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: queued.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .canceled, cleanup: WorkAgentHandleCleanupProof(state: .notStarted))))
    let ended = agentEvent(
        TimelineEventType.runFinished, id: "agent-6", sequence: 6, previous: terminal.eventID,
        session: agentSession, attachment: agentAttachment, run: agentRun)
    let prematureDestroy = agentEvent(
        TimelineEventType.workDestroyed, id: "agent-7", sequence: 7, previous: ended.eventID)
    let unreapedSnapshot = WorkReducer.reduce(
        prefix.events + [queued, terminal, ended, prematureDestroy])
    XCTAssertEqual(unreapedSnapshot.lifecycle, .active)
    XCTAssertFalse(unreapedSnapshot.semanticProjectionValid)

    let reaped = agentEvent(
        TimelineEventType.agentHandleReaped, id: "agent-7", sequence: 7,
        previous: ended.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: terminal.eventID),
        payload: agentJSON(WorkAgentHandleReapedPayload(reason: .workDestruction)))
    let destroyed = agentEvent(
        TimelineEventType.workDestroyed, id: "agent-8", sequence: 8, previous: reaped.eventID)
    let destroyedSnapshot = WorkReducer.reduce(prefix.events + [queued, terminal, ended, reaped, destroyed])
    XCTAssertEqual(destroyedSnapshot.lifecycle, .destroyed)
    XCTAssertEqual(destroyedSnapshot.agentHandles[agentHandle.handleID]?.state, .reaped)
    XCTAssertEqual(destroyedSnapshot.agentHandles[agentHandle.handleID]?.terminalOutcome, .canceled)
    XCTAssertTrue(destroyedSnapshot.semanticProjectionValid)
}

func test_workAgentHandleDeadlineRejectsLateStartAndAllowsTypedExpiry() {
    let prefix = agentPrefix()
    let origin = prefix.origin
    let queued = agentEvent(
        TimelineEventType.agentHandleQueued, id: "agent-4", sequence: 4, previous: "agent-3",
        session: agentSession, attachment: agentAttachment, run: agentRun, handle: agentHandle,
        at: 4, payload: agentJSON(WorkAgentHandleQueuedPayload(
            origin: origin, label: "expiring child",
            deadline: Date(timeIntervalSince1970: 4.5), requestBody: agentBody("a"))))
    let lateStart = agentEvent(
        TimelineEventType.agentHandleStarted, id: "agent-5", sequence: 5,
        previous: queued.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: queued.eventID), at: 5)
    let expired = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-6", sequence: 6,
        previous: lateStart.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: queued.eventID), at: 6,
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .expired, cleanup: WorkAgentHandleCleanupProof(state: .notStarted))))
    let snapshot = WorkReducer.reduce(prefix.events + [queued, lateStart, expired])
    XCTAssertNil(snapshot.agentHandles[agentHandle.handleID]?.startedEvent)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.state, .terminal)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.terminalOutcome, .expired)
    XCTAssertEqual(snapshot.quarantinedEvents.map(\.eventID), [lateStart.eventID])
}

func test_workAgentHandleReapsAfterCompletedWorkWithoutLosingOutcome() {
    let prefix = agentPrefix()
    let queued = queuedAgentEvent(origin: prefix.origin)
    let terminal = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-5", sequence: 5,
        previous: queued.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: queued.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .canceled, cleanup: WorkAgentHandleCleanupProof(state: .notStarted))))
    let ended = agentEvent(
        TimelineEventType.runFinished, id: "agent-6", sequence: 6, previous: terminal.eventID,
        session: agentSession, attachment: agentAttachment, run: agentRun)
    let completed = agentEvent(
        TimelineEventType.workCompleted, id: "agent-7", sequence: 7, previous: ended.eventID)
    let reaped = agentEvent(
        TimelineEventType.agentHandleReaped, id: "agent-8", sequence: 8,
        previous: completed.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: terminal.eventID),
        payload: agentJSON(WorkAgentHandleReapedPayload(reason: .retentionExpired)))
    let snapshot = WorkReducer.reduce(prefix.events + [queued, terminal, ended, completed, reaped])
    XCTAssertEqual(snapshot.lifecycle, .completed)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.state, .reaped)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.terminalOutcome, .canceled)
    XCTAssertEqual(snapshot.agentHandles[agentHandle.handleID]?.terminalEvent?.eventID, terminal.eventID)
    XCTAssertTrue(snapshot.semanticProjectionValid)
}

func test_workAgentHandleRejectsMissingSuccessResultAndUnknownPayloadFields() {
    let prefix = agentPrefix()
    var rawQueue = agentJSON(WorkAgentHandleQueuedPayload(
        origin: prefix.origin, label: "raw queue",
        deadline: Date(timeIntervalSince1970: 100), requestBody: agentBody("a"))).objectValue!
    rawQueue["private_prompt"] = .string("must not be accepted")
    let malformedQueue = agentEvent(
        TimelineEventType.agentHandleQueued, id: "agent-4", sequence: 4, previous: "agent-3",
        session: agentSession, attachment: agentAttachment, run: agentRun, handle: agentHandle,
        payload: .object(rawQueue))
    let malformedQueueSnapshot = WorkReducer.reduce(prefix.events + [malformedQueue])
    XCTAssertNil(malformedQueueSnapshot.agentHandles[agentHandle.handleID])
    XCTAssertFalse(malformedQueueSnapshot.semanticProjectionValid)

    let queued = queuedAgentEvent(origin: prefix.origin)
    let started = startedAgentEvent()
    let missingResult = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-6", sequence: 6,
        previous: started.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: started.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .succeeded, cleanup: WorkAgentHandleCleanupProof(state: .quiesced))))
    let missingResultSnapshot = WorkReducer.reduce(prefix.events + [queued, started, missingResult])
    XCTAssertEqual(missingResultSnapshot.agentHandles[agentHandle.handleID]?.state, .running)
    XCTAssertNil(missingResultSnapshot.agentHandles[agentHandle.handleID]?.terminalOutcome)
    XCTAssertFalse(missingResultSnapshot.semanticProjectionValid)

    var rawTerminal = agentJSON(WorkAgentHandleTerminalPayload(
        outcome: .failed, cleanup: WorkAgentHandleCleanupProof(state: .quiesced)
    )).objectValue!
    rawTerminal["diagnostic"] = .string("must remain addressable")
    let malformedTerminal = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-6", sequence: 6,
        previous: started.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: started.eventID),
        payload: .object(rawTerminal))
    let malformedTerminalSnapshot = WorkReducer.reduce(
        prefix.events + [queued, started, malformedTerminal])
    XCTAssertEqual(malformedTerminalSnapshot.agentHandles[agentHandle.handleID]?.state, .running)
    XCTAssertNil(malformedTerminalSnapshot.agentHandles[agentHandle.handleID]?.terminalOutcome)
    XCTAssertFalse(malformedTerminalSnapshot.semanticProjectionValid)
}

func test_workAgentHandleIdentityCannotCollideWithLegacyRunHandle() {
    let prefix = agentPrefix()
    let queued = queuedAgentEvent(origin: prefix.origin)
    let legacyCollision = agentEvent(
        TimelineEventType.handleStarted, id: "agent-5", sequence: 5,
        previous: queued.eventID, run: agentRun, handle: agentHandle,
        payload: .object(["state": .string("running")]))
    let agentFirst = WorkReducer.reduce(prefix.events + [queued, legacyCollision])
    XCTAssertNil(agentFirst.handles[agentHandle.handleID])
    XCTAssertEqual(agentFirst.agentHandles[agentHandle.handleID]?.state, .queued)
    XCTAssertFalse(agentFirst.semanticProjectionValid)

    let legacy = agentEvent(
        TimelineEventType.handleStarted, id: "agent-4", sequence: 4,
        previous: "agent-3", run: agentRun, handle: agentHandle,
        payload: .object(["state": .string("running")]))
    let agentCollision = queuedAgentEvent(
        origin: prefix.origin, id: "agent-5", sequence: 5, previous: legacy.eventID)
    let legacyFirst = WorkReducer.reduce(prefix.events + [legacy, agentCollision])
    XCTAssertEqual(legacyFirst.handles[agentHandle.handleID]?.state, "running")
    XCTAssertNil(legacyFirst.agentHandles[agentHandle.handleID])
    XCTAssertFalse(legacyFirst.semanticProjectionValid)
}

func test_workAgentHandleIndeterminateTerminalStillBlocksCompletionAndReap() {
    let prefix = agentPrefix()
    let queued = queuedAgentEvent(origin: prefix.origin)
    let started = startedAgentEvent()
    let indeterminate = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-6", sequence: 6,
        previous: started.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: started.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .indeterminate,
            cleanup: WorkAgentHandleCleanupProof(state: .indeterminate))))
    let ended = agentEvent(
        TimelineEventType.runFinished, id: "agent-7", sequence: 7,
        previous: indeterminate.eventID, session: agentSession,
        attachment: agentAttachment, run: agentRun)
    let completion = agentEvent(
        TimelineEventType.workCompleted, id: "agent-8", sequence: 8, previous: ended.eventID)
    let reap = agentEvent(
        TimelineEventType.agentHandleReaped, id: "agent-9", sequence: 9,
        previous: completion.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: indeterminate.eventID),
        payload: agentJSON(WorkAgentHandleReapedPayload(reason: .explicitPolicy)))
    let snapshot = WorkReducer.reduce(
        prefix.events + [queued, started, indeterminate, ended, completion, reap])
    let handle = snapshot.agentHandles[agentHandle.handleID]
    XCTAssertEqual(snapshot.lifecycle, .active)
    XCTAssertEqual(handle?.state, .terminal)
    XCTAssertEqual(handle?.terminalOutcome, .indeterminate)
    XCTAssertTrue(handle?.blocksWorkCompletion == true)
    XCTAssertNil(handle?.reapedEvent)
    XCTAssertEqual(snapshot.quarantinedEvents.map(\.eventID), [completion.eventID, reap.eventID])
}

func test_workAgentHandleExactPreflightIgnoresBoundedHistoricalIndexCaps() throws {
    var snapshot = WorkSnapshot()
    snapshot.journal = agentJournal; snapshot.work = agentWork; snapshot.workHost = agentHost
    snapshot.lifecycle = .active; snapshot.execution = .running
    snapshot.activeRun = agentRun; snapshot.activeRunSession = agentSession
    snapshot.activeRunSessionAttachment = agentAttachment
    snapshot.lastEventID = "exact-preflight-seed"; snapshot.lastSequence = 1
    snapshot.seenEventIDs = ["exact-preflight-seed"]
    snapshot.eventSequences = ["exact-preflight-seed": 1]
    snapshot.sessionAttachments[agentAttachment.attachmentID] = WorkSessionAttachmentSnapshot(
        attachment: agentAttachment, session: agentSession)
    for index in 0..<600 {
        let handle = HandleRef("historical-legacy-\(index)")
        snapshot.handles[handle.handleID] = WorkHandleSnapshot(handle: handle, state: "completed")
    }
    for index in 0..<300 {
        let attachment = SessionAttachmentRef("historical-attachment-\(index)")
        snapshot.sessionAttachments[attachment.attachmentID] = WorkSessionAttachmentSnapshot(
            attachment: attachment, session: SessionRef("historical-session-\(index)"),
            isAttached: false)
    }
    let queued = agentEvent(
        TimelineEventType.agentHandleQueued, id: "exact-preflight-2", sequence: 2,
        previous: "exact-preflight-seed", session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        payload: agentJSON(WorkAgentHandleQueuedPayload(
            origin: WorkAgentHandleOrigin(
                work: agentWork, workHost: agentHost, session: agentSession,
                sessionAttachment: agentAttachment, run: agentRun),
            label: "not bounded by history", deadline: Date(timeIntervalSince1970: 100),
            requestBody: agentBody("a"))))
    let result = try WorkAgentHandlePreflight.applying(queued, to: snapshot)
    XCTAssertEqual(result.state, .queued)
    XCTAssertEqual(result.handle, agentHandle)
    var transition = InMemoryWorkTransitionState(snapshot: snapshot)
    WorkReducerTransition.apply(queued, to: &transition)
    let terminal = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "exact-preflight-3", sequence: 3,
        previous: queued.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: queued.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .failed, cleanup: .init(state: .notStarted))))
    let finished = try WorkAgentHandlePreflight.applying(terminal, to: transition.snapshot)
    XCTAssertEqual(finished.state, .terminal)
    XCTAssertEqual(finished.terminalOutcome, .failed)
}

func test_workAgentHandlePersistentExactStateColdParityAndPrivacy() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "aviary-agent-handle-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard chmod(directory.path, mode_t(0o700)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try PersistentProjectionRadixMap(
        directory: directory.appending(path: "map", directoryHint: .isDirectory),
        namespaceID: "agent-handle-exact-v4", journal: agentJournal,
        sourceGeneration: String(repeating: "c", count: 64), mapKind: "work-exact-v4")

    let prefix = agentPrefix()
    let queued = queuedAgentEvent(origin: prefix.origin)
    let started = startedAgentEvent()
    let ended = agentEvent(
        TimelineEventType.runFinished, id: "agent-6", sequence: 6, previous: started.eventID,
        session: agentSession, attachment: agentAttachment, run: agentRun)
    var root: PersistentProjectionRadixMap.Root?
    for event in prefix.events + [queued, started, ended] {
        var exact = try PersistentWorkExactState(map: map, root: root)
        root = try exact.apply(event).root
    }

    var cold = try PersistentWorkExactState(map: map, root: try XCTUnwrap(root))
    let terminal = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-7", sequence: 7,
        previous: ended.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: started.eventID),
        payload: agentJSON(WorkAgentHandleTerminalPayload(
            outcome: .succeeded, resultBody: agentBody("b"),
            cleanup: WorkAgentHandleCleanupProof(state: .quiesced))))
    let coldResult = try cold.apply(terminal)
    let native = WorkReducer.reduce(prefix.events + [queued, started, ended, terminal])
    XCTAssertEqual(coldResult.eventLocalSnapshot.agentHandles[agentHandle.handleID],
                   native.agentHandles[agentHandle.handleID])

    var privatePayload = agentJSON(WorkAgentHandleTerminalPayload(
        outcome: .failed, cleanup: WorkAgentHandleCleanupProof(state: .quiesced)
    )).objectValue!
    privatePayload["diagnostic"] = .string("PRIVATE-AGENT-RESULT-BODY")
    let malformed = agentEvent(
        TimelineEventType.agentHandleTerminal, id: "agent-8", sequence: 8,
        previous: terminal.eventID, session: agentSession, attachment: agentAttachment,
        run: agentRun, handle: agentHandle,
        causedBy: EventRef(journal: agentJournal, eventID: terminal.eventID),
        payload: .object(privatePayload))
    _ = try cold.apply(malformed)

    let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    while let file = enumerator?.nextObject() as? URL {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        let text = String(data: try Data(contentsOf: file), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("PRIVATE-AGENT-RESULT-BODY"))
    }
}

let casesWorkAgentHandleCanonical: [Case] = [
    ("Work-owned agent Handle settles after origin Run End", {
        test_workAgentHandleTerminalizesAfterOriginRunEnds()
    }),
    ("Work-owned agent Handle rejects forged origin and conflicting terminal", {
        test_workAgentHandleRejectsForgedOriginAndConflictingTerminal()
    }),
    ("Work-owned agent Handle client cancel uses durable caller attachment", {
        test_workAgentHandleClientCancellationUsesDurableCallerAttachment()
    }),
    ("Work-owned agent Handle has distinct completion and destruction gates", {
        test_workAgentHandleCompletionAndDestructionUseDistinctGates()
    }),
    ("Work-owned agent Handle deadline refuses late start and records expiry", {
        test_workAgentHandleDeadlineRejectsLateStartAndAllowsTypedExpiry()
    }),
    ("Work-owned agent Handle can reap after completed Work", {
        test_workAgentHandleReapsAfterCompletedWorkWithoutLosingOutcome()
    }),
    ("Work-owned agent Handle rejects missing result and raw payload fields", {
        test_workAgentHandleRejectsMissingSuccessResultAndUnknownPayloadFields()
    }),
    ("Work-owned and legacy Handle identities cannot collide", {
        test_workAgentHandleIdentityCannotCollideWithLegacyRunHandle()
    }),
    ("indeterminate terminal agent Handle still blocks completion and reap", {
        test_workAgentHandleIndeterminateTerminalStillBlocksCompletionAndReap()
    }),
    ("exact agent Handle preflight ignores bounded historical index caps", {
        try test_workAgentHandleExactPreflightIgnoresBoundedHistoricalIndexCaps()
    }),
    ("Work-owned agent Handle cold exact state preserves parity and privacy", {
        try test_workAgentHandlePersistentExactStateColdParityAndPrivacy()
    }),
]
