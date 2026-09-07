import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private let persistentWork = WorkRef(workHostID: "persistent-work-host", workID: "persistent-work")
private let persistentHost = WorkHostRef(persistentWork.workHostID)
private let persistentJournal = JournalRef.work(persistentWork, journalID: "persistent-work-journal")

private func persistentDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "aviary-persistent-work-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    // Foundation's creation attributes are not consistently applied on Linux. The production
    // map intentionally refuses an inherited umask result, so make the fixture's ownership
    // contract explicit before opening it.
    guard chmod(url.path, mode_t(0o700)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    return url
}

private func persistentMap(at url: URL) throws -> PersistentProjectionRadixMap {
    try PersistentProjectionRadixMap(
        directory: url.appending(path: "map", directoryHint: .isDirectory),
        namespaceID: "persistent-work-namespace", journal: persistentJournal,
        sourceGeneration: String(repeating: "b", count: 64), mapKind: "work-exact-v2")
}

private func persistentValueFiles(
    in directory: URL, containingRecordKind expectedKind: String
) throws -> [URL] {
    let values = directory.appending(path: "map/values", directoryHint: .isDirectory)
    return try FileManager.default.contentsOfDirectory(atPath: values.path).compactMap { name in
        let url = values.appending(path: name)
        let envelope = JSONValue.parse(try Data(contentsOf: url))
        guard let encoded = envelope?["body"]?["bytes"]?.stringValue,
              let bytes = Data(base64Encoded: encoded),
              JSONValue.parse(bytes)?["kind"]?.stringValue == expectedKind else {
            return nil
        }
        return url
    }
}

private func persistentEvent(
    _ type: String, _ id: String, _ sequence: Int, previous: String? = nil,
    run: RunRef? = nil, action: ActionRef? = nil, handle: HandleRef? = nil,
    session: SessionRef? = nil, attachment: SessionAttachmentRef? = nil,
    turn: TurnRef? = nil,
    command: CommandRef? = nil, causedBy: EventRef? = nil,
    hostSequence: Int? = nil, domains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: persistentJournal, sequence: sequence,
        hostSequence: hostSequence, command: command, previousEventID: previous,
        causedByEventID: causedBy, session: session, work: persistentWork,
        workHost: persistentHost, sessionAttachment: attachment, run: run,
        turn: turn, action: action, handle: handle,
        actor: TimelineActor(actorID: "persistent-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)), type: type,
        declaredDomains: domains, payload: payload)
}

private func persistentRepresentativeEvents() -> [TimelineEvent] {
    let session = SessionRef("persistent-session")
    let attachment = SessionAttachmentRef("persistent-attachment")
    let run = RunRef("persistent-run")
    let action = ActionRef("persistent-action")
    let handle = HandleRef("persistent-handle")
    let client = ClientRef("persistent-client")
    let command = CommandRef(
        commandID: "persistent-command", client: client, sessionAttachment: attachment,
        causalCursor: JournalCursor(journal: persistentJournal, eventID: "pw-10", sequence: 10))
    return [
        persistentEvent(TimelineEventType.workCreated, "pw-1", 1),
        persistentEvent(TimelineEventType.sessionAttached, "pw-2", 2, previous: "pw-1",
                         session: session, attachment: attachment),
        persistentEvent(TimelineEventType.runStarted, "pw-3", 3, previous: "pw-2", run: run,
                         session: session, attachment: attachment,
                         payload: .object(["model_id": .string("persistent-model")])),
        persistentEvent(TimelineEventType.actionIntent, "pw-4", 4, previous: "pw-3", run: run,
                         action: action, payload: .object([
                            "state": .string("proposed"), "kind": .string("python"),
                            "intent": .string("persisted action")
                         ])),
        persistentEvent(TimelineEventType.actionStarted, "pw-5", 5, previous: "pw-4", run: run,
                         action: action, payload: .object(["state": .string("running")])),
        persistentEvent(TimelineEventType.actionOutcome, "pw-6", 6, previous: "pw-5", run: run,
                         action: action, payload: .object([
                            "state": .string("succeeded"), "retry_safety": .string("idempotent")
                         ])),
        persistentEvent(TimelineEventType.handleStarted, "pw-7", 7, previous: "pw-6", run: run,
                         handle: handle, payload: .object(["state": .string("running")])),
        persistentEvent(TimelineEventType.handleOutcome, "pw-8", 8, previous: "pw-7", run: run,
                         handle: handle, payload: .object(["state": .string("completed")])),
        persistentEvent(TimelineEventType.runFinished, "pw-9", 9, previous: "pw-8", run: run,
                         session: session, attachment: attachment),
        persistentEvent(TimelineEventType.sessionDetached, "pw-10", 10, previous: "pw-9",
                         session: session, attachment: attachment),
        persistentEvent(TimelineEventType.commandAccepted, "pw-11", 11, previous: "pw-10",
                         session: session, attachment: attachment, command: command,
                         causedBy: EventRef(journal: persistentJournal, eventID: "pw-10"),
                         hostSequence: 11)
    ]
}

private func persistentWorkJournalValue() throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(persistentJournal)))
}

private func testPersistentWorkExactStatePersistsChildAndRecoveryMetadata() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    let session = SessionRef("child-recovery-session")
    let attachment = SessionAttachmentRef("child-recovery-attachment")
    let run = RunRef("child-recovery-run")
    let events = [
        persistentEvent(TimelineEventType.workCreated, "cr-1", 1),
        persistentEvent(TimelineEventType.sessionAttached, "cr-2", 2, previous: "cr-1",
                        session: session, attachment: attachment),
        persistentEvent(TimelineEventType.childLifecycle, "cr-3", 3, previous: "cr-2",
                        payload: .object(["child_id": .string("child-1"),
                                          "state": .string("running")])),
        persistentEvent(TimelineEventType.runStarted, "cr-4", 4, previous: "cr-3", run: run,
                        session: session, attachment: attachment,
                        payload: .object(["model_id": .string("recovery-model")])),
        persistentEvent(TimelineEventType.recoveryCoverage, "cr-5", 5, previous: "cr-4",
                        run: run, session: session, attachment: attachment,
                        payload: .object([
                            "operation": .string("cold_resume"),
                            "planes": .object([
                                "timeline": .string("preserved"),
                                "model_context": .string("reconstructed")
                            ]),
                            "work_journal": try persistentWorkJournalValue(),
                            "caveats": .array([.string("PRIVATE-RECOVERY-CAVEAT")])
                        ]))
    ]
    var root: PersistentProjectionRadixMap.Root?
    for event in events {
        var state = try PersistentWorkExactState(map: map, root: root)
        let result = try state.apply(event)
        root = result.root
        if event.type == TimelineEventType.childLifecycle {
            XCTAssertEqual(result.eventLocalSnapshot.childStates["child-1"], "running")
        }
        if event.type == TimelineEventType.recoveryCoverage {
            XCTAssertEqual(result.eventLocalSnapshot.recovery.count, 1)
            XCTAssertEqual(result.eventLocalSnapshot.recordedRecovery.count, 1)
            let recovery = try XCTUnwrap(result.eventLocalSnapshot.recovery.first)
            XCTAssertEqual(recovery.operation, .coldResume)
            XCTAssertTrue(recovery.caveats.isEmpty)
        }
    }
    let childFiles = try persistentValueFiles(in: directory, containingRecordKind: "child")
    let recoveryFiles = try persistentValueFiles(in: directory, containingRecordKind: "recovery")
    XCTAssertEqual(childFiles.count, 1)
    XCTAssertEqual(recoveryFiles.count, 1)
    for file in childFiles + recoveryFiles {
        XCTAssertFalse(String(data: try Data(contentsOf: file), encoding: .utf8)?.contains(
            "PRIVATE-RECOVERY-CAVEAT") == true)
    }

    let reopened = try PersistentWorkExactState(map: map, root: try XCTUnwrap(root))
    XCTAssertEqual(reopened.eventLocalSnapshot.lastSequence, 5)
    var continued = reopened
    let next = persistentEvent(TimelineEventType.childLifecycle, "cr-6", 6, previous: "cr-5",
                                run: run,
                                payload: .object(["child_id": .string("child-1"),
                                                  "state": .string("done")]))
    let continuation = try continued.apply(next)
    XCTAssertEqual(continuation.eventLocalSnapshot.childStates["child-1"], "done")
    XCTAssertEqual(continuation.eventLocalSnapshot.lastSequence, 6)
}

private func testPersistentWorkExactStateBoundsAttachmentPrefetchByTransition() throws {
    let sessionA = SessionRef("prefetch-session-a")
    let sessionB = SessionRef("prefetch-session-b")
    let attachmentsA = (0..<WorkServiceBounds.maxSessionAttachmentsPerWork).map {
        SessionAttachmentRef("prefetch-a-\($0)")
    }
    let attachmentsB = (0..<WorkServiceBounds.maxSessionAttachmentsPerWork).map {
        SessionAttachmentRef("prefetch-b-\($0)")
    }
    var events = [persistentEvent(TimelineEventType.workCreated, "prefetch-1", 1)]
    for (index, attachment) in attachmentsA.enumerated() {
        let sequence = index + 2
        events.append(persistentEvent(
            TimelineEventType.sessionAttached, "prefetch-\(sequence)", sequence,
            previous: "prefetch-\(sequence - 1)", session: sessionA, attachment: attachment))
    }
    for (index, attachment) in attachmentsB.enumerated() {
        let sequence = attachmentsA.count + index + 2
        events.append(persistentEvent(
            TimelineEventType.sessionAttached, "prefetch-\(sequence)", sequence,
            previous: "prefetch-\(sequence - 1)", session: sessionB, attachment: attachment))
    }
    // The canonical reducer quarantines this identity conflict before staging. Its arbitrary
    // envelope Session must not make exact continuation authenticate both full Sessions.
    let conflictSequence = events.count + 1
    events.append(persistentEvent(
        TimelineEventType.sessionAttached, "prefetch-\(conflictSequence)", conflictSequence,
        previous: "prefetch-\(conflictSequence - 1)", session: sessionB,
        attachment: attachmentsA[0]))
    let capabilitySequence = conflictSequence + 1
    events.append(persistentEvent(
        TimelineEventType.sessionAttachmentCapabilityChanged,
        "prefetch-\(capabilitySequence)", capabilitySequence,
        previous: "prefetch-\(capabilitySequence - 1)", session: sessionB,
        attachment: attachmentsA[0],
        payload: .object(["capabilities": .array([.string("after-conflict")])])))
    let detachSequence = capabilitySequence + 1
    events.append(persistentEvent(
        TimelineEventType.sessionDetached, "prefetch-\(detachSequence)", detachSequence,
        previous: "prefetch-\(detachSequence - 1)", session: sessionB,
        attachment: attachmentsA[0]))

    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var root: PersistentProjectionRadixMap.Root?
    var canonical = InMemoryWorkTransitionState()
    var conflictResult: PersistentWorkExactState.ApplyResult?
    var latestResult: PersistentWorkExactState.ApplyResult?
    for event in events {
        var state = try PersistentWorkExactState(map: map, root: root)
        let result = try state.apply(event)
        WorkReducerTransition.apply(event, to: &canonical)
        // The exact overlay intentionally exposes only the authenticated dependency footprint,
        // not a full membership snapshot. Compare the scalar transition and the affected record;
        // the canonical in-memory reducer remains the oracle for the complete state.
        XCTAssertEqual(result.eventLocalSnapshot.lastSequence, canonical.snapshot.lastSequence)
        XCTAssertEqual(result.eventLocalSnapshot.lifecycle, canonical.snapshot.lifecycle)
        let projectsAttachment = event.type == TimelineEventType.sessionAttached
            || event.type == TimelineEventType.sessionDetached
            || event.type == TimelineEventType.sessionAttachmentCapabilityChanged
            || event.type == TimelineEventType.recoveryCoverage
        if projectsAttachment, let attachment = event.sessionAttachment {
            XCTAssertEqual(
                result.eventLocalSnapshot.sessionAttachments[attachment.attachmentID]?.isAttached,
                canonical.snapshot.sessionAttachments[attachment.attachmentID]?.isAttached)
        }
        if event.sequence == conflictSequence { conflictResult = result }
        latestResult = result
        root = result.root
    }
    let conflict = try XCTUnwrap(conflictResult)
    XCTAssertEqual(conflict.eventLocalSnapshot.quarantinedEvents.count, 1)
    XCTAssertEqual(conflict.eventLocalSnapshot.sessionAttachments[attachmentsA[0].attachmentID]?.isAttached,
                   true)
    let latest = try XCTUnwrap(latestResult)
    XCTAssertEqual(latest.eventLocalSnapshot.lastSequence, canonical.snapshot.lastSequence)
    XCTAssertEqual(
        latest.eventLocalSnapshot.sessionAttachments[attachmentsA[0].attachmentID],
        canonical.snapshot.sessionAttachments[attachmentsA[0].attachmentID])
    XCTAssertNotEqual(latest.root, conflict.root)
}

private func persistentExpectError<T: Error>(_ body: () throws -> Void, _ check: (T) -> Bool,
                                             line: Int = #line) {
    do { try body(); XCTFail("expected error", line: line) }
    catch let error as T { XCTAssertTrue(check(error), "unexpected error: \(error)", line: line) }
    catch { XCTFail("unexpected error: \(error)", line: line) }
}

private func testPersistentWorkExactStateRepresentativeParity() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var root: PersistentProjectionRadixMap.Root?
    var memory = InMemoryWorkTransitionState()
    for event in persistentRepresentativeEvents() {
        var persistent = try PersistentWorkExactState(map: map, root: root)
        let result = try persistent.apply(event)
        WorkReducerTransition.apply(event, to: &memory)
        XCTAssertEqual(result.eventLocalSnapshot.lifecycle, memory.snapshot.lifecycle, "lifecycle mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.execution, memory.snapshot.execution, "execution mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.activeRun, memory.snapshot.activeRun, "Run mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.modelID, memory.snapshot.modelID, "model mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.activeTurn, memory.snapshot.activeTurn, "Turn mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.lastHostSequence, memory.snapshot.lastHostSequence, "host sequence mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.lastEventID, memory.snapshot.lastEventID, "event identity mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.lastSequence, memory.snapshot.lastSequence, "sequence mismatch at \(event.eventID)")
        XCTAssertEqual(result.eventLocalSnapshot.causalOrderValid, memory.snapshot.causalOrderValid)
        XCTAssertEqual(result.eventLocalSnapshot.structuralIntegrityValid, memory.snapshot.structuralIntegrityValid)
        XCTAssertEqual(result.eventLocalSnapshot.semanticProjectionValid, memory.snapshot.semanticProjectionValid)
        if let action = event.action {
            XCTAssertEqual(result.eventLocalSnapshot.actions[action.actionID], memory.snapshot.actions[action.actionID])
            XCTAssertEqual(
                result.eventLocalSnapshot.activeActionIDs.contains(action.actionID),
                memory.snapshot.activeActionIDs.contains(action.actionID))
        }
        if let handle = event.handle {
            XCTAssertEqual(result.eventLocalSnapshot.handles[handle.handleID], memory.snapshot.handles[handle.handleID])
        }
        let projectsAttachment = event.type == TimelineEventType.sessionAttached
            || event.type == TimelineEventType.sessionDetached
            || event.type == TimelineEventType.sessionAttachmentCapabilityChanged
            || event.type == TimelineEventType.recoveryCoverage
        if projectsAttachment, let attachment = event.sessionAttachment {
            XCTAssertEqual(
                result.eventLocalSnapshot.sessionAttachments[attachment.attachmentID],
                memory.snapshot.sessionAttachments[attachment.attachmentID])
            XCTAssertEqual(result.eventLocalSnapshot.attachedSessionIDs, memory.snapshot.attachedSessionIDs)
        }
        if let command = event.command {
            XCTAssertEqual(result.eventLocalSnapshot.commands[command.commandID], memory.snapshot.commands[command.commandID])
        }
        XCTAssertFalse(result.changedSlots.isEmpty)
        XCTAssertEqual(result.root, persistent.currentRoot)
        root = result.root
    }
    let reopened = try PersistentWorkExactState(map: map, root: try XCTUnwrap(root))
    XCTAssertEqual(reopened.eventLocalSnapshot.lifecycle, .active)
    XCTAssertEqual(reopened.eventLocalSnapshot.activeRun, nil)
    XCTAssertEqual(reopened.eventLocalSnapshot.lastSequence, 11)
}

private func testPersistentWorkExactStateReopenRejectsDuplicate() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var first = try PersistentWorkExactState(map: map)
    let event = persistentEvent(TimelineEventType.workCreated, "reopen-1", 1)
    let result = try first.apply(event)
    var reopened = try PersistentWorkExactState(map: map, root: result.root)
    let oldRoot = reopened.currentRoot
    persistentExpectError({ _ = try reopened.apply(event) }, { (error: PersistentWorkExactState.Error) in
        if case .duplicateEvent("reopen-1") = error { return true }; return false
    })
    XCTAssertEqual(reopened.currentRoot, oldRoot)
    XCTAssertEqual(reopened.eventLocalSnapshot.lifecycle, first.eventLocalSnapshot.lifecycle)
    XCTAssertEqual(reopened.eventLocalSnapshot.lastSequence, first.eventLocalSnapshot.lastSequence)
}

private func testPersistentWorkExactStateReopenPreservesActiveRunOwner() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    let session = SessionRef("reopen-owner-session")
    let attachment = SessionAttachmentRef("reopen-owner-attachment")
    let run = RunRef("reopen-owner-run")
    let turn = TurnRef("reopen-owner-turn")

    var state = try PersistentWorkExactState(map: map)
    var root = try state.apply(persistentEvent(
        TimelineEventType.workCreated, "owner-1", 1)).root
    state = try PersistentWorkExactState(map: map, root: root)
    root = try state.apply(persistentEvent(
        TimelineEventType.sessionAttached, "owner-2", 2, previous: "owner-1",
        session: session, attachment: attachment)).root

    // A cold reopen must retain the exact attachment membership needed to authenticate
    // run.started, and the resulting owner must survive another reopen while the Run lives.
    state = try PersistentWorkExactState(map: map, root: root)
    let started = try state.apply(persistentEvent(
        TimelineEventType.runStarted, "owner-3", 3, previous: "owner-2", run: run,
        session: session, attachment: attachment,
        payload: .object(["model_id": .string("owner-model")])) )
    XCTAssertEqual(started.eventLocalSnapshot.activeRun, run)
    XCTAssertEqual(started.eventLocalSnapshot.activeRunSession, session)
    XCTAssertEqual(started.eventLocalSnapshot.activeRunSessionAttachment, attachment)

    state = try PersistentWorkExactState(map: map, root: started.root)
    let modeled = try state.apply(persistentEvent(
        TimelineEventType.modelChanged, "owner-4", 4, previous: "owner-3", run: run,
        payload: .object(["model_id": .string("owner-model-2")])) )
    XCTAssertEqual(modeled.eventLocalSnapshot.activeRunSession, session)
    XCTAssertEqual(modeled.eventLocalSnapshot.activeRunSessionAttachment, attachment)

    state = try PersistentWorkExactState(map: map, root: modeled.root)
    let turned = try state.apply(persistentEvent(
        TimelineEventType.turnStarted, "owner-5", 5, previous: "owner-4", run: run,
        turn: turn))
    XCTAssertEqual(turned.eventLocalSnapshot.activeRunSession, session)
    XCTAssertEqual(turned.eventLocalSnapshot.activeRunSessionAttachment, attachment)

    state = try PersistentWorkExactState(map: map, root: turned.root)
    let turnFinished = try state.apply(persistentEvent(
        TimelineEventType.turnFinished, "owner-6", 6, previous: "owner-5", run: run,
        turn: turn))
    state = try PersistentWorkExactState(map: map, root: turnFinished.root)
    let finished = try state.apply(persistentEvent(
        TimelineEventType.runFinished, "owner-7", 7, previous: "owner-6", run: run,
        session: session, attachment: attachment))
    XCTAssertNil(finished.eventLocalSnapshot.activeRun)
    XCTAssertNil(finished.eventLocalSnapshot.activeRunSession)
    XCTAssertNil(finished.eventLocalSnapshot.activeRunSessionAttachment)
}

private func testPersistentWorkExactStateRejectsDetachedIdentityReuseAndKeepsCounts() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var state = try PersistentWorkExactState(map: map)
    let session = SessionRef("count-session")
    let a = SessionAttachmentRef("count-a")
    let b = SessionAttachmentRef("count-b")
    let c = SessionAttachmentRef("count-c")
    let events = [
        persistentEvent(TimelineEventType.workCreated, "count-1", 1),
        persistentEvent(TimelineEventType.sessionAttached, "count-2", 2, previous: "count-1", session: session, attachment: a),
        persistentEvent(TimelineEventType.sessionAttached, "count-3", 3, previous: "count-2", session: session, attachment: b),
        persistentEvent(TimelineEventType.sessionDetached, "count-4", 4, previous: "count-3", session: session, attachment: a),
        persistentEvent(TimelineEventType.sessionAttached, "count-5", 5, previous: "count-4", session: session, attachment: a),
        persistentEvent(TimelineEventType.sessionAttached, "count-6", 6, previous: "count-5", session: session, attachment: c),
        persistentEvent(TimelineEventType.sessionDetached, "count-7", 7, previous: "count-6", session: session, attachment: b),
        persistentEvent(TimelineEventType.sessionDetached, "count-8", 8, previous: "count-7", session: session, attachment: c)
    ]
    var afterRejectedReuse: PersistentWorkExactState.ApplyResult?
    var afterDetachingB: PersistentWorkExactState.ApplyResult?
    for event in events {
        let result = try state.apply(event)
        if event.eventID == "count-5" { afterRejectedReuse = result }
        if event.eventID == "count-7" { afterDetachingB = result }
    }
    XCTAssertFalse(try XCTUnwrap(
        afterDetachingB?.eventLocalSnapshot.sessionAttachments["count-b"]
    ).isAttached)
    XCTAssertTrue(try XCTUnwrap(afterDetachingB).eventLocalSnapshot.attachedSessionIDs.contains(
        session.sessionID))
    XCTAssertTrue(state.eventLocalSnapshot.attachedSessionIDs.isEmpty)
    XCTAssertFalse(try XCTUnwrap(
        afterRejectedReuse?.eventLocalSnapshot.sessionAttachments["count-a"]
    ).isAttached)
    XCTAssertEqual(try XCTUnwrap(afterRejectedReuse).eventLocalSnapshot.quarantinedEvents.map(\.eventID), ["count-5"])
}

private func testPersistentWorkExactStateDetachUsesStoredSessionAcrossReopen() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    let storedSession = SessionRef("stored-session")
    let misleadingSession = SessionRef("misleading-session")
    let attachment = SessionAttachmentRef("stored-attachment")
    let replacement = SessionAttachmentRef("stored-replacement")
    let events = [
        persistentEvent(TimelineEventType.workCreated, "stored-1", 1),
        persistentEvent(TimelineEventType.sessionAttached, "stored-2", 2,
                        previous: "stored-1", session: storedSession,
                        attachment: attachment),
        persistentEvent(TimelineEventType.sessionDetached, "stored-3", 3,
                        previous: "stored-2", attachment: attachment),
        persistentEvent(TimelineEventType.sessionAttached, "stored-4", 4,
                        previous: "stored-3", session: storedSession,
                        attachment: replacement),
        persistentEvent(TimelineEventType.sessionDetached, "stored-5", 5,
                        previous: "stored-4", session: misleadingSession,
                        attachment: replacement),
    ]
    var memory = InMemoryWorkTransitionState()
    var root: PersistentProjectionRadixMap.Root?
    for event in events {
        var persistent = try PersistentWorkExactState(map: map, root: root)
        let result = try persistent.apply(event)
        WorkReducerTransition.apply(event, to: &memory)
        XCTAssertEqual(
            result.eventLocalSnapshot.attachedSessionIDs,
            memory.snapshot.attachedSessionIDs,
            "attached Session parity mismatch after reopen at \(event.eventID)")
        if let expected = event.sessionAttachment {
            XCTAssertEqual(
                result.eventLocalSnapshot.sessionAttachments[expected.attachmentID]?.isAttached,
                memory.snapshot.sessionAttachments[expected.attachmentID]?.isAttached,
                "attachment state parity mismatch after reopen at \(event.eventID)")
        }
        root = result.root
    }
    XCTAssertTrue(memory.snapshot.attachedSessionIDs.isEmpty)
    XCTAssertFalse(try XCTUnwrap(memory.snapshot.sessionAttachments[attachment.attachmentID]).isAttached)
    XCTAssertFalse(try XCTUnwrap(memory.snapshot.sessionAttachments[replacement.attachmentID]).isAttached)
}

private func testPersistentWorkExactStateUnknownQuarantinePrivacy() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var state = try PersistentWorkExactState(map: map)
    _ = try state.apply(persistentEvent("future.private", "privacy-1", 1,
                                        domains: [.runtime], payload: .object(["secret": .string("do-not-persist")])) )
    _ = try state.apply(persistentEvent(TimelineEventType.actionIntent, "privacy-2", 2, previous: "privacy-1",
                                        action: ActionRef("bad-action"), payload: .object(["secret": .string("do-not-persist")])) )
    var reopened = try PersistentWorkExactState(map: map, root: try XCTUnwrap(state.currentRoot))
    let evidence = try reopened.apply(persistentEvent(TimelineEventType.modelChanged, "privacy-3", 3,
                                                      previous: "privacy-2", payload: .object(["model_id": .string("m")])))
    XCTAssertEqual(evidence.eventLocalSnapshot.unknownDomains, [.runtime])
    XCTAssertFalse(evidence.eventLocalSnapshot.corruptionReasons.isEmpty)
    let bytes = try map.lookup(root: evidence.root, key: "work-exact-v2/scalar").value
    XCTAssertNotNil(bytes)
    XCTAssertFalse(String(data: bytes!, encoding: .utf8)?.contains("do-not-persist") == true)
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    while let file = enumerator.nextObject() as? URL {
        guard (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        XCTAssertFalse(try Data(contentsOf: file).range(
            of: Data("do-not-persist".utf8)) != nil,
            "persistent exact-state object retained a raw private payload")
    }
}

private func testPersistentWorkExactStateMissingObjectFailsClosed() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var state = try PersistentWorkExactState(map: map)
    let root = try state.apply(persistentEvent(TimelineEventType.workCreated, "missing-1", 1)).root
    let values = directory.appending(path: "map/values", directoryHint: .isDirectory)
    for name in try FileManager.default.contentsOfDirectory(atPath: values.path) {
        try FileManager.default.removeItem(at: values.appending(path: name))
    }
    persistentExpectError({ _ = try PersistentWorkExactState(map: map, root: root) }, { (error: PersistentWorkExactState.Error) in
        if case .map(.missingObject) = error { return true }; return false
    })
}

private func testPersistentWorkExactStateTypedRecordFailureFailsClosed() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var state = try PersistentWorkExactState(map: map)
    _ = try state.apply(persistentEvent(TimelineEventType.workCreated, "typed-1", 1))
    _ = try state.apply(persistentEvent(TimelineEventType.actionIntent, "typed-2", 2, previous: "typed-1",
                                        action: ActionRef("typed-action"), payload: .object([
                                            "state": .string("proposed"), "kind": .string("python"),
                                            "intent": .string("typed")
                                        ])))
    let priorRoot = try XCTUnwrap(state.currentRoot)
    let actionFiles = try persistentValueFiles(in: directory, containingRecordKind: "action")
    XCTAssertEqual(actionFiles.count, 1)
    try FileManager.default.removeItem(at: try XCTUnwrap(actionFiles.first))
    persistentExpectError({ _ = try state.apply(persistentEvent(TimelineEventType.actionStarted, "typed-3", 3,
                                                                  previous: "typed-2", action: ActionRef("typed-action"),
                                                                  payload: .object(["state": .string("running")]))) },
                           { (error: PersistentWorkExactState.Error) in
        if case .map(.missingObject) = error { return true }; return false
    })
    XCTAssertEqual(state.currentRoot, priorRoot)
}

private func testPersistentWorkExactStateCorruptTypedRecordFailsClosed() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var state = try PersistentWorkExactState(map: map)
    _ = try state.apply(persistentEvent(TimelineEventType.workCreated, "corrupt-1", 1))
    _ = try state.apply(persistentEvent(TimelineEventType.actionIntent, "corrupt-2", 2, previous: "corrupt-1",
                                        action: ActionRef("corrupt-action"), payload: .object([
                                            "state": .string("proposed"), "kind": .string("python"),
                                            "intent": .string("corrupt")
                                        ])))
    let actionURL = try XCTUnwrap(
        persistentValueFiles(in: directory, containingRecordKind: "action").first)
    try Data("{\"kind\":\"forged\"}".utf8).write(to: actionURL)
    persistentExpectError({ _ = try state.apply(persistentEvent(TimelineEventType.actionStarted, "corrupt-3", 3,
                                                                  previous: "corrupt-2", action: ActionRef("corrupt-action"),
                                                                  payload: .object(["state": .string("running")]))) },
                           { (error: PersistentWorkExactState.Error) in
        if case .map(.invalidObject) = error { return true }; return false
    })
}

private func testPersistentWorkExactStateRejectsScalarWithoutExactWorkIdentity() throws {
    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var state = try PersistentWorkExactState(map: map)
    let root = try state.apply(persistentEvent(
        TimelineEventType.workCreated, "scalar-identity-1", 1)).root
    let key = "work-exact-v2/scalar"
    let encoded = try XCTUnwrap(try map.lookup(root: root, key: key).value)
    guard case .object(var object) = try XCTUnwrap(JSONValue.parse(encoded)) else {
        XCTFail("scalar record was not an object")
        return
    }
    object["work"] = .null
    object["workHost"] = .null
    let forged = try JSONEncoder().encode(JSONValue.object(object))
    let forgedRoot = try map.setting(root: root, key: key, value: forged).newRoot
    persistentExpectError({
        _ = try PersistentWorkExactState(map: map, root: forgedRoot)
    }, { (error: PersistentWorkExactState.Error) in
        error == .invalidRecord
    })
}

private func testPersistentWorkExactStateRejectsImpossibleAttachmentCount() throws {
    struct ForgedCountRecord: Codable {
        let kind: String
        let scope: String
        let session: SessionRef
        let count: Int
        let activeAttachmentIDs: [String]
    }

    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    let session = SessionRef("forged-count-session")
    let attachment = SessionAttachmentRef("forged-count-attachment")
    var state = try PersistentWorkExactState(map: map)
    _ = try state.apply(persistentEvent(
        TimelineEventType.workCreated, "forged-count-1", 1))
    let validRoot = try state.apply(persistentEvent(
        TimelineEventType.sessionAttached, "forged-count-2", 2,
        previous: "forged-count-1", session: session, attachment: attachment)).root
    let kind = "attachment-count"
    let identity = session.sessionID
    let material = "work-exact-slot-v1\0\(kind.count):\(kind)\0\(identity.utf8.count):\(identity)"
    let key = "work-exact-v2/\(kind)/"
        + AviarySHA256.hash(data: Data(material.utf8)).description
    let forged = try JSONEncoder().encode(ForgedCountRecord(
        kind: kind, scope: persistentJournal.stableKey,
        session: session, count: Int.max,
        activeAttachmentIDs: [attachment.attachmentID]))
    let forgedRoot = try map.setting(root: validRoot, key: key, value: forged).newRoot
    var reopened = try PersistentWorkExactState(map: map, root: forgedRoot)
    let priorRoot = reopened.currentRoot
    persistentExpectError({
        _ = try reopened.apply(persistentEvent(
            TimelineEventType.sessionDetached, "forged-count-3", 3,
            previous: "forged-count-2", session: session, attachment: attachment))
    }, { (error: PersistentWorkExactState.Error) in
        error == .invalidRecord
    })
    XCTAssertEqual(reopened.currentRoot, priorRoot)
}

private func testPersistentWorkExactStateRejectsFeasibleButFalseAttachmentMembership() throws {
    struct ForgedCountRecord: Codable {
        let kind: String
        let scope: String
        let session: SessionRef
        let count: Int
        let activeAttachmentIDs: [String]
    }

    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    let session = SessionRef("forged-feasible-session")
    let attachment = SessionAttachmentRef("forged-feasible-attachment")
    var state = try PersistentWorkExactState(map: map)
    _ = try state.apply(persistentEvent(
        TimelineEventType.workCreated, "forged-feasible-1", 1))
    let validRoot = try state.apply(persistentEvent(
        TimelineEventType.sessionAttached, "forged-feasible-2", 2,
        previous: "forged-feasible-1", session: session, attachment: attachment)).root
    let kind = "attachment-count"
    let identity = session.sessionID
    let material = "work-exact-slot-v1\0\(kind.count):\(kind)\0\(identity.utf8.count):\(identity)"
    let key = "work-exact-v2/\(kind)/"
        + AviarySHA256.hash(data: Data(material.utf8)).description
    let forged = try JSONEncoder().encode(ForgedCountRecord(
        kind: kind, scope: persistentJournal.stableKey, session: session, count: 2,
        activeAttachmentIDs: [attachment.attachmentID, "forged-missing-attachment"]))
    let forgedRoot = try map.setting(root: validRoot, key: key, value: forged).newRoot
    var reopened = try PersistentWorkExactState(map: map, root: forgedRoot)
    let priorRoot = reopened.currentRoot
    persistentExpectError({
        _ = try reopened.apply(persistentEvent(
            TimelineEventType.sessionDetached, "forged-feasible-3", 3,
            previous: "forged-feasible-2", session: session, attachment: attachment))
    }, { (error: PersistentWorkExactState.Error) in
        error == .invalidRecord
    })
    XCTAssertEqual(reopened.currentRoot, priorRoot)
}

private func testPersistentWorkExactStateRejectsSequenceBoundaryWithoutPublishing() throws {
    struct ForgedScalarRecord: Codable {
        let schemaVersion: Int
        let kind: String
        let journal: JournalRef?
        let work: WorkRef?
        let workHost: WorkHostRef?
        let lifecycle: WorkLifecycle
        let execution: WorkExecution
        let activeRun: RunRef?
        let modelID: String?
        let activeTurn: TurnRef?
        let lastHostSequence: Int?
        let unknownDomains: Set<TimelineDomain>
        let lastEventID: String?
        let lastSequence: Int
        let causalOrderValid: Bool
        let structuralIntegrityValid: Bool
        let semanticProjectionValid: Bool
        let seenEventCount: Int
        let activeActionCount: Int
        let outstandingHandleCount: Int
        let lastUnknownEventID: String?
        let lastQuarantineEventID: String?
    }

    let directory = try persistentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try persistentMap(at: directory)
    var initial = try PersistentWorkExactState(map: map)
    let initialRoot = try initial.apply(persistentEvent(
        TimelineEventType.workCreated, "boundary-initial", 1)).root
    let forgedScalar = ForgedScalarRecord(
        schemaVersion: PersistentWorkExactState.schemaVersion, kind: "scalar",
        journal: persistentJournal, work: persistentWork, workHost: persistentHost,
        lifecycle: .active, execution: .idle, activeRun: nil, modelID: nil,
        activeTurn: nil, lastHostSequence: nil, unknownDomains: [],
        lastEventID: "boundary-prior", lastSequence: Int.max - 1,
        causalOrderValid: true, structuralIntegrityValid: true,
        semanticProjectionValid: true, seenEventCount: Int.max - 1,
        activeActionCount: 0, outstandingHandleCount: 0,
        lastUnknownEventID: nil, lastQuarantineEventID: nil)
    let forgedRoot = try map.setting(
        root: initialRoot, key: "work-exact-v2/scalar",
        value: try JSONEncoder().encode(forgedScalar)).newRoot
    for event in [
        persistentEvent(
            TimelineEventType.modelChanged, "boundary-model", Int.max,
            previous: "boundary-prior", payload: .object(["model_id": .string("m")])),
        persistentEvent(
            TimelineEventType.sessionAttached, "boundary-attachment", Int.max,
            previous: "boundary-prior", session: SessionRef("boundary-session"),
            attachment: SessionAttachmentRef("boundary-session-attachment")),
    ] {
        var reopened = try PersistentWorkExactState(map: map, root: forgedRoot)
        let priorRoot = reopened.currentRoot
        persistentExpectError({ _ = try reopened.apply(event) }, {
            (error: PersistentWorkExactState.Error) in error == .invalidRecord
        })
        XCTAssertEqual(reopened.currentRoot, priorRoot)
    }
}

let casesPersistentWorkExactState: [Case] = [
    ("phase3 persistent Work exact state bounds attachment prefetch by transition", {
        try testPersistentWorkExactStateBoundsAttachmentPrefetchByTransition()
    }),
    ("phase3 persistent Work exact state persists child and recovery metadata", {
        try testPersistentWorkExactStatePersistsChildAndRecoveryMetadata()
    }),
    ("phase3 persistent Work exact state matches reducer across representative slots", {
        try testPersistentWorkExactStateRepresentativeParity()
    }),
    ("phase3 persistent Work exact state rejects duplicate after reopen", {
        try testPersistentWorkExactStateReopenRejectsDuplicate()
    }),
    ("phase3 persistent Work exact state preserves active Run owner after reopen", {
        try testPersistentWorkExactStateReopenPreservesActiveRunOwner()
    }),
    ("phase3 persistent Work exact state rejects detached identity reuse and keeps counts exact", {
        try testPersistentWorkExactStateRejectsDetachedIdentityReuseAndKeepsCounts()
    }),
    ("phase3 persistent Work exact state derives detach Session from stored attachment", {
        try testPersistentWorkExactStateDetachUsesStoredSessionAcrossReopen()
    }),
    ("phase3 persistent Work exact state preserves unknown and quarantine evidence privately", {
        try testPersistentWorkExactStateUnknownQuarantinePrivacy()
    }),
    ("phase3 persistent Work exact state fails closed on missing objects", {
        try testPersistentWorkExactStateMissingObjectFailsClosed()
    }),
    ("phase3 persistent Work exact state fails closed on missing typed records", {
        try testPersistentWorkExactStateTypedRecordFailureFailsClosed()
    }),
    ("phase3 persistent Work exact state fails closed on corrupt typed records", {
        try testPersistentWorkExactStateCorruptTypedRecordFailsClosed()
    }),
    ("phase3 persistent Work exact state rejects scalar without exact Work identity", {
        try testPersistentWorkExactStateRejectsScalarWithoutExactWorkIdentity()
    }),
    ("phase3 persistent Work exact state rejects impossible attachment counts", {
        try testPersistentWorkExactStateRejectsImpossibleAttachmentCount()
    }),
    ("phase3 persistent Work exact state rejects feasible false attachment membership", {
        try testPersistentWorkExactStateRejectsFeasibleButFalseAttachmentMembership()
    }),
    ("phase3 persistent Work exact state rejects terminal sequence boundary", {
        try testPersistentWorkExactStateRejectsSequenceBoundaryWithoutPublishing()
    }),
]
