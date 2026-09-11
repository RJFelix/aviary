import Foundation
@testable import AviaryCore

private func handleJournalPayload<T: Encodable>(_ value: T) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(value)))
}

private func handleJournalDraft(
    _ type: String, origin: WorkAgentHandleOrigin, handle: HandleRef,
    cause: EventRef? = nil, payload: JSONValue = .object([:])
) -> TimelineEventDraft {
    TimelineEventDraft(
        causedByEventID: cause, session: origin.session, work: origin.work,
        workHost: origin.workHost, sessionAttachment: origin.sessionAttachment,
        run: origin.run, handle: handle, type: type,
        declaredDomains: [.work, .runtime, .externalEffects], payload: payload)
}

func testWorkAgentHandleJournalOutlivesClosedRunWriter() async throws {
    let home = scratchHome()
    let work = WorkRef(workHostID: try home.requirePersistedWorkHostID(), workID: "child-journal-work")
    let identity = SessionWorkIdentity(sessionID: "child-journal-session", work: work, runID: "origin-run")
    let route = try WorkAgentHandleJournal(
        home: home, work: work, actor: TimelineActor(actorID: "child-owner", kind: "work-host"))
    let bundle = try await route.openRun {
        try await RunJournalBundle.openForExecution(
            home: home, identity: identity, actorID: "origin-parent",
            makeAttachmentID: { "origin-attachment" })
    }
    let origin = WorkAgentHandleOrigin(
        work: work, workHost: WorkHostRef(work.workHostID),
        session: SessionRef(identity.sessionID), sessionAttachment: bundle.sessionAttachment,
        run: RunRef(identity.runID))
    let handle = HandleRef("surviving-child")
    let store = ContextBodyStore(home: home)
    let request = try store.retain(Data("private child request".utf8), authority: bundle.workJournal)
    let queued = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleQueued, origin: origin, handle: handle,
        payload: handleJournalPayload(WorkAgentHandleQueuedPayload(
            origin: origin, label: "Surviving child", deadline: Date().addingTimeInterval(60),
            requestBody: request))))
    let started = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleStarted, origin: origin, handle: handle, cause: queued.eventRef))
    _ = try await bundle.finishRun(outcome: .completed)
    let beforeRefusal = try Data(contentsOf: home.timelineV2WorkJournalURL(work))
    let cursor = try XCTUnwrap(await bundle.status.durablePrefix.workCursor)
    do {
        _ = try await bundle.completeWork(command: CommandRef(
            commandID: "finish-with-live-child", client: ClientRef("client"),
            sessionAttachment: origin.sessionAttachment, causalCursor: cursor))
        XCTAssertTrue(false, "Work completion must not ignore a live Work-owned child")
    } catch { XCTAssertTrue(error is RunJournalBundleError) }
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(work)), beforeRefusal)
    try await bundle.closeChecked()

    let result = try store.retain(Data("private final result".utf8), authority: bundle.workJournal)
    let terminalDraft = try handleJournalDraft(
        TimelineEventType.agentHandleTerminal, origin: origin, handle: handle, cause: started.eventRef,
        payload: handleJournalPayload(WorkAgentHandleTerminalPayload(
            outcome: .succeeded, resultBody: result, cleanup: .init(state: .quiesced))))
    let terminal = try await route.append(terminalDraft)
    XCTAssertTrue(terminal.cursor.sequence > cursor.sequence,
                  "child completion was appended after the closed originating Run")
    let finalBytes = try Data(contentsOf: home.timelineV2WorkJournalURL(work))

    // A new host-side route has no live child task or Run writer. It reads the retained fact,
    // not reconstructed execution. Repeated lookup neither consumes the result nor appends.
    let coldRoute = try WorkAgentHandleJournal(
        home: home, work: work, actor: TimelineActor(actorID: "cold-owner", kind: "work-host"))
    let first = try await coldRoute.read()
    let second = try await coldRoute.read()
    XCTAssertEqual(first.agentHandles, second.agentHandles)
    let row = try XCTUnwrap(first.agentHandles.first)
    XCTAssertEqual(row.origin, origin)
    XCTAssertEqual(row.state, .terminal)
    XCTAssertEqual(row.resultBody, result)
    XCTAssertEqual(first.liveAgentHandleCount, 0)
    XCTAssertEqual(first.unreapedAgentHandleCount, 1)
    XCTAssertNil(first.currentRun)
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(work)), finalBytes)
    do {
        _ = try await coldRoute.append(terminalDraft)
        XCTAssertTrue(false, "a second terminal must not be appended")
    } catch { XCTAssertTrue(true) }
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(work)), finalBytes)
    let text = String(decoding: finalBytes, as: UTF8.self)
    XCTAssertFalse(text.contains("private child request"))
    XCTAssertFalse(text.contains("private final result"))
}

func testWorkAgentHandleJournalReconcilesAfterAmbiguousClose() async throws {
    let home = scratchHome()
    let work = WorkRef(workHostID: try home.requirePersistedWorkHostID(), workID: "ambiguous-child-work")
    let identity = SessionWorkIdentity(sessionID: "ambiguous-child-session", work: work, runID: "origin")
    let route = try WorkAgentHandleJournal(
        home: home, work: work, actor: TimelineActor(actorID: "owner", kind: "work-host"))
    let bundle = try await route.openRun {
        try await RunJournalBundle.openForExecution(home: home, identity: identity, actorID: "parent")
    }
    let origin = WorkAgentHandleOrigin(
        work: work, workHost: WorkHostRef(work.workHostID), session: SessionRef(identity.sessionID),
        sessionAttachment: bundle.sessionAttachment, run: RunRef(identity.runID))
    let handle = HandleRef("uncertain-child")
    let body = try ContextBodyStore(home: home).retain(Data("request".utf8), authority: bundle.workJournal)
    let queued = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleQueued, origin: origin, handle: handle,
        payload: handleJournalPayload(WorkAgentHandleQueuedPayload(
            origin: origin, label: "Queued child", deadline: Date().addingTimeInterval(60), requestBody: body))))
    _ = try await bundle.finishRun(outcome: .completed)
    await bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    do {
        _ = try await route.append(handleJournalDraft(
            TimelineEventType.agentHandleTerminal, origin: origin, handle: handle, cause: queued.eventRef,
            payload: handleJournalPayload(WorkAgentHandleTerminalPayload(
                outcome: .failed, cleanup: .init(state: .notStarted)))))
        XCTAssertTrue(false, "lost durable confirmation must surface as uncertainty")
    } catch { XCTAssertTrue(error is RunJournalBundleError) }
    do {
        try await bundle.closeChecked()
        XCTAssertTrue(false, "close retains the prior ambiguous-write failure")
    } catch { XCTAssertTrue(error is RunJournalBundleError) }
    XCTAssertTrue(await bundle.writersClosed)
    let bytes = try Data(contentsOf: home.timelineV2WorkJournalURL(work))
    let head = try await route.read()
    let row = try XCTUnwrap(head.agentHandles.first)
    XCTAssertEqual(row.terminalOutcome, .failed)
    XCTAssertEqual(row.state, .terminal)
    XCTAssertEqual(head.liveAgentHandleCount, 0)
    XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(work)), bytes,
                   "reconciliation must read the durable fact, not retry the terminal write")
}

let casesWorkAgentHandleJournal: [Case] = [
    ("phase5 agent journal: post-End writer handoff and retained cold outcome", {
        try await testWorkAgentHandleJournalOutlivesClosedRunWriter()
    }),
    ("phase5 agent journal: failed closed writer remains canonically readable", {
        try await testWorkAgentHandleJournalReconcilesAfterAmbiguousClose()
    }),
]
