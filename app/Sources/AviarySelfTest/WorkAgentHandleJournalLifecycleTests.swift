import Foundation
@testable import AviaryCore

private func agentHandleJournalLifecycleTestHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "ahjl-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return AgentHome(root: root)
}

private struct AgentHandleJournalLifecycleFixture {
    let home: AgentHome
    let work: WorkRef
    let identity: SessionWorkIdentity
    let route: WorkAgentHandleJournal
    let bundle: RunJournalBundle
    let origin: WorkAgentHandleOrigin
    let store: ContextBodyStore
}

private func agentHandleLifecyclePayload<T: Encodable>(_ value: T) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(value)))
}

private func agentHandleLifecycleDraft(
    _ type: String,
    origin: WorkAgentHandleOrigin,
    handle: HandleRef,
    cause: EventRef? = nil,
    payload: JSONValue = .object([:])
) -> TimelineEventDraft {
    TimelineEventDraft(
        causedByEventID: cause,
        session: origin.session,
        work: origin.work,
        workHost: origin.workHost,
        sessionAttachment: origin.sessionAttachment,
        run: origin.run,
        handle: handle,
        type: type,
        declaredDomains: [.work, .runtime, .externalEffects],
        payload: payload)
}

private func makeAgentHandleJournalLifecycleFixture(
    suffix: String
) async throws -> AgentHandleJournalLifecycleFixture {
    let home = try agentHandleJournalLifecycleTestHome()
    let work = WorkRef(
        workHostID: try home.requirePersistedWorkHostID(),
        workID: "agent-handle-lifecycle-work-\(suffix)")
    let identity = SessionWorkIdentity(
        sessionID: "agent-handle-lifecycle-session-\(suffix)",
        work: work,
        runID: "agent-handle-lifecycle-run-\(suffix)")
    let route = try WorkAgentHandleJournal(
        home: home,
        work: work,
        actor: TimelineActor(actorID: "agent-handle-owner-\(suffix)", kind: "work-host"))
    let bundle = try await route.openRun {
        try await RunJournalBundle.openForExecution(
            home: home,
            identity: identity,
            actorID: "agent-handle-run-\(suffix)",
            makeAttachmentID: { "agent-handle-attachment-\(suffix)" })
    }
    let origin = WorkAgentHandleOrigin(
        work: work,
        workHost: WorkHostRef(work.workHostID),
        session: SessionRef(identity.sessionID),
        sessionAttachment: bundle.sessionAttachment,
        run: RunRef(identity.runID))
    return AgentHandleJournalLifecycleFixture(
        home: home,
        work: work,
        identity: identity,
        route: route,
        bundle: bundle,
        origin: origin,
        store: ContextBodyStore(home: home))
}

private func agentHandleLifecycleQueued(
    _ fixture: AgentHandleJournalLifecycleFixture,
    handle: HandleRef,
    label: String
) async throws -> TimelineJournalCommit {
    let request = try fixture.store.retain(
        Data("request-\(handle.handleID)".utf8), authority: fixture.bundle.workJournal)
    return try await fixture.route.append(agentHandleLifecycleDraft(
        TimelineEventType.agentHandleQueued,
        origin: fixture.origin,
        handle: handle,
        payload: agentHandleLifecyclePayload(WorkAgentHandleQueuedPayload(
            origin: fixture.origin,
            label: label,
            deadline: Date().addingTimeInterval(300),
            requestBody: request))))
}

private func agentHandleLifecycleStarted(
    _ fixture: AgentHandleJournalLifecycleFixture,
    handle: HandleRef,
    queued: TimelineJournalCommit
) async throws -> TimelineJournalCommit {
    try await fixture.route.append(agentHandleLifecycleDraft(
        TimelineEventType.agentHandleStarted,
        origin: fixture.origin,
        handle: handle,
        cause: queued.eventRef))
}

private func agentHandleLifecycleTerminal(
    _ fixture: AgentHandleJournalLifecycleFixture,
    handle: HandleRef,
    cause: TimelineJournalCommit,
    outcome: WorkAgentHandleTerminalOutcome,
    cleanup: WorkAgentHandleCleanupState,
    resultBody: TimelineBodyReference? = nil
) async throws -> TimelineJournalCommit {
    try await fixture.route.append(agentHandleLifecycleDraft(
        TimelineEventType.agentHandleTerminal,
        origin: fixture.origin,
        handle: handle,
        cause: cause.eventRef,
        payload: agentHandleLifecyclePayload(WorkAgentHandleTerminalPayload(
            outcome: outcome,
            resultBody: resultBody,
            cleanup: WorkAgentHandleCleanupProof(state: cleanup)))))
}

private func agentHandleLifecycleCommand(
    _ fixture: AgentHandleJournalLifecycleFixture,
    id: String
) async throws -> CommandRef {
    CommandRef(
        commandID: id,
        client: ClientRef("agent-handle-lifecycle-client"),
        sessionAttachment: fixture.origin.sessionAttachment,
        causalCursor: try XCTUnwrap(await fixture.bundle.latestWorkCursor))
}

func testWorkAgentHandleJournalRejectsSameIdentityFromWrongHome() async throws {
    let routeHome = try agentHandleJournalLifecycleTestHome()
    let foreignHome = try agentHandleJournalLifecycleTestHome()
    defer {
        try? FileManager.default.removeItem(at: routeHome.root)
        try? FileManager.default.removeItem(at: foreignHome.root)
    }
    let hostID = try routeHome.requirePersistedWorkHostID()
    try FileManager.default.createDirectory(
        at: foreignHome.root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    try Data((hostID + "\n").utf8).write(to: foreignHome.workHostIDFile)

    let work = WorkRef(workHostID: hostID, workID: "wrong-home-agent-handle-work")
    let identity = SessionWorkIdentity(
        sessionID: "wrong-home-agent-handle-session",
        work: work,
        runID: "wrong-home-agent-handle-run")
    let route = try WorkAgentHandleJournal(
        home: routeHome,
        work: work,
        actor: TimelineActor(actorID: "right-home-owner", kind: "work-host"))
    let foreignBundle = try await RunJournalBundle.openForExecution(
        home: foreignHome, identity: identity, actorID: "foreign-home-owner")
    do {
        _ = try await route.openRun {
            foreignBundle
        }
        XCTAssertTrue(false, "logical Work identity must not substitute for the canonical file location")
    } catch let failure as WorkAgentHandleJournal.Failure {
        XCTAssertEqual(failure, .wrongWork)
    }
    XCTAssertTrue(await foreignBundle.writersClosed)
    XCTAssertFalse(FileManager.default.fileExists(
        atPath: routeHome.timelineV2WorkJournalURL(work).path))
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: foreignHome.timelineV2WorkJournalURL(work).path))
}

func testWorkAgentHandleJournalCloseBeforeAppendUsesColdWriter() async throws {
    let fixture = try await makeAgentHandleJournalLifecycleFixture(suffix: "close-first")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let closedCursor = try XCTUnwrap(await fixture.bundle.latestWorkCursor)
    try await fixture.bundle.closeChecked()

    let handle = HandleRef("close-first-child")
    let queued = try await agentHandleLifecycleQueued(
        fixture, handle: handle, label: "Close first child")
    XCTAssertTrue(queued.cursor.sequence > closedCursor.sequence)
    XCTAssertEqual(await fixture.bundle.latestWorkCursor, closedCursor,
                   "the closed bundle must not claim the cold writer's append")
    let head = try await fixture.route.read()
    XCTAssertEqual(head.agentHandles.first(where: { $0.handle == handle })?.state, .queued)
    XCTAssertEqual(head.liveAgentHandleCount, 1)
}

func testWorkAgentHandleJournalAppendBeforeCloseUsesLiveBundle() async throws {
    let fixture = try await makeAgentHandleJournalLifecycleFixture(suffix: "append-first")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let handle = HandleRef("append-first-child")
    let queued = try await agentHandleLifecycleQueued(
        fixture, handle: handle, label: "Append first child")
    XCTAssertEqual(await fixture.bundle.latestWorkCursor, queued.cursor,
                   "the live bundle must publish the borrowed writer's cursor")
    try await fixture.bundle.closeChecked()

    let head = try await fixture.route.read()
    XCTAssertEqual(head.agentHandles.first(where: { $0.handle == handle })?.state, .queued)
    XCTAssertEqual(head.liveAgentHandleCount, 1)
}

func testWorkAgentHandleJournalIndeterminateCleanupBlocksCompletion() async throws {
    let fixture = try await makeAgentHandleJournalLifecycleFixture(suffix: "indeterminate")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let handle = HandleRef("indeterminate-child")
    let queued = try await agentHandleLifecycleQueued(
        fixture, handle: handle, label: "Indeterminate child")
    let started = try await agentHandleLifecycleStarted(
        fixture, handle: handle, queued: queued)
    _ = try await agentHandleLifecycleTerminal(
        fixture,
        handle: handle,
        cause: started,
        outcome: .indeterminate,
        cleanup: .indeterminate)
    _ = try await fixture.bundle.finishRun(outcome: .indeterminate)
    let beforeCompletion = try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work))

    do {
        _ = try await fixture.bundle.completeWork(command: try await agentHandleLifecycleCommand(
            fixture, id: "complete-with-indeterminate-child"))
        XCTAssertTrue(false, "indeterminate cleanup must remain policy-live for Work completion")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation(let reason) = error,
              reason.contains("agent children remain outstanding") else {
            XCTAssertTrue(false, "wrong indeterminate-completion error: \(error)")
            return
        }
    }
    XCTAssertEqual(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work)),
        beforeCompletion)
    let head = try await fixture.route.read()
    let row = try XCTUnwrap(head.agentHandles.first(where: { $0.handle == handle }))
    XCTAssertEqual(row.state, .terminal)
    XCTAssertEqual(row.cleanup?.state, .indeterminate)
    XCTAssertTrue(row.blocksWorkCompletion)
    XCTAssertEqual(head.liveAgentHandleCount, 1)
    try await fixture.bundle.closeChecked()
}

func testWorkAgentHandleJournalReapsCompletedWorkLiveAndColdAsMetadata() async throws {
    let fixture = try await makeAgentHandleJournalLifecycleFixture(suffix: "completed-reap")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let liveHandle = HandleRef("live-reap-child")
    let coldHandle = HandleRef("cold-reap-child")
    let resultBytes = Data("retained child result".utf8)
    let result = try fixture.store.retain(resultBytes, authority: fixture.bundle.workJournal)

    let liveQueued = try await agentHandleLifecycleQueued(
        fixture, handle: liveHandle, label: "Live reap child")
    let liveStarted = try await agentHandleLifecycleStarted(
        fixture, handle: liveHandle, queued: liveQueued)
    let liveTerminal = try await agentHandleLifecycleTerminal(
        fixture,
        handle: liveHandle,
        cause: liveStarted,
        outcome: .succeeded,
        cleanup: .quiesced,
        resultBody: result)

    let coldQueued = try await agentHandleLifecycleQueued(
        fixture, handle: coldHandle, label: "Cold reap child")
    let coldStarted = try await agentHandleLifecycleStarted(
        fixture, handle: coldHandle, queued: coldQueued)
    let coldTerminal = try await agentHandleLifecycleTerminal(
        fixture,
        handle: coldHandle,
        cause: coldStarted,
        outcome: .succeeded,
        cleanup: .quiesced,
        resultBody: result)

    _ = try await fixture.bundle.finishRun(outcome: .completed)
    _ = try await fixture.bundle.completeWork(command: try await agentHandleLifecycleCommand(
        fixture, id: "complete-before-reap"))

    let liveReap = try await fixture.route.append(agentHandleLifecycleDraft(
        TimelineEventType.agentHandleReaped,
        origin: fixture.origin,
        handle: liveHandle,
        cause: liveTerminal.eventRef,
        payload: agentHandleLifecyclePayload(WorkAgentHandleReapedPayload(
            reason: .explicitPolicy))))
    XCTAssertEqual(await fixture.bundle.latestWorkCursor, liveReap.cursor)
    try await fixture.bundle.closeChecked()

    let coldReap = try await fixture.route.append(agentHandleLifecycleDraft(
        TimelineEventType.agentHandleReaped,
        origin: fixture.origin,
        handle: coldHandle,
        cause: coldTerminal.eventRef,
        payload: agentHandleLifecyclePayload(WorkAgentHandleReapedPayload(
            reason: .retentionExpired))))
    XCTAssertTrue(coldReap.cursor.sequence > liveReap.cursor.sequence)

    let head = try await fixture.route.read()
    XCTAssertEqual(head.lifecycle, .completed)
    XCTAssertEqual(head.liveAgentHandleCount, 0)
    XCTAssertEqual(head.unreapedAgentHandleCount, 0)
    XCTAssertEqual(head.retainedAgentHandleCount, 2)
    let liveRow = try XCTUnwrap(head.agentHandles.first(where: { $0.handle == liveHandle }))
    let coldRow = try XCTUnwrap(head.agentHandles.first(where: { $0.handle == coldHandle }))
    XCTAssertEqual(liveRow.state, .reaped)
    XCTAssertEqual(liveRow.reapReason, .explicitPolicy)
    XCTAssertEqual(liveRow.resultBody, result)
    XCTAssertEqual(coldRow.state, .reaped)
    XCTAssertEqual(coldRow.reapReason, .retentionExpired)
    XCTAssertEqual(coldRow.resultBody, result)
    XCTAssertEqual(try fixture.store.read(result), resultBytes,
                   "this journal seam reaps metadata only; resource deletion is coordinator-owned")
}

func testWorkAgentHandleJournalDestroyRefusesUnreapedTerminal() async throws {
    let fixture = try await makeAgentHandleJournalLifecycleFixture(suffix: "destroy-unreaped")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let handle = HandleRef("unreaped-child")
    let queued = try await agentHandleLifecycleQueued(
        fixture, handle: handle, label: "Unreaped child")
    let started = try await agentHandleLifecycleStarted(
        fixture, handle: handle, queued: queued)
    _ = try await agentHandleLifecycleTerminal(
        fixture,
        handle: handle,
        cause: started,
        outcome: .failed,
        cleanup: .quiesced)
    _ = try await fixture.bundle.finishRun(outcome: .failed)
    let beforeDestruction = try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work))

    do {
        _ = try await fixture.bundle.destroyWork(
            resourcesQuiesced: true,
            command: try await agentHandleLifecycleCommand(
                fixture, id: "destroy-with-unreaped-child"))
        XCTAssertTrue(false, "Work destruction must retain terminal child results until reap")
    } catch let error as RunJournalBundleError {
        guard case .invalidOperation(let reason) = error,
              reason.contains("retained results to be reaped") else {
            XCTAssertTrue(false, "wrong unreaped-destruction error: \(error)")
            return
        }
    }
    XCTAssertEqual(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work)),
        beforeDestruction)
    let head = try await fixture.route.read()
    XCTAssertEqual(head.liveAgentHandleCount, 0)
    XCTAssertEqual(head.unreapedAgentHandleCount, 1)
    XCTAssertEqual(head.lifecycle, .active)
    try await fixture.bundle.closeChecked()
}

let casesWorkAgentHandleJournalLifecycle: [Case] = [
    ("phase5 agent journal lifecycle: wrong-home bundle is refused", {
        try await testWorkAgentHandleJournalRejectsSameIdentityFromWrongHome()
    }),
    ("phase5 agent journal lifecycle: close before append uses cold writer", {
        try await testWorkAgentHandleJournalCloseBeforeAppendUsesColdWriter()
    }),
    ("phase5 agent journal lifecycle: append before close uses live bundle", {
        try await testWorkAgentHandleJournalAppendBeforeCloseUsesLiveBundle()
    }),
    ("phase5 agent journal lifecycle: indeterminate cleanup blocks completion", {
        try await testWorkAgentHandleJournalIndeterminateCleanupBlocksCompletion()
    }),
    ("phase5 agent journal lifecycle: completed Work reaps live and cold metadata", {
        try await testWorkAgentHandleJournalReapsCompletedWorkLiveAndColdAsMetadata()
    }),
    ("phase5 agent journal lifecycle: destruction refuses unreaped results", {
        try await testWorkAgentHandleJournalDestroyRefusesUnreapedTerminal()
    }),
]
