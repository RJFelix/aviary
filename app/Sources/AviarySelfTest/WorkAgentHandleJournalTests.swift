import Foundation
@testable import AviaryCore

private func handleJournalTestHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "ahj-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return AgentHome(root: root)
}

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

private actor HandleJournalBundleSelectionGate {
    private var armed = false
    private var selected = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arm() { armed = true }

    func pauseIfArmed() async {
        guard armed else { return }
        armed = false
        selected = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSelected() async -> Bool {
        for _ in 0..<500 {
            if selected { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor HandleJournalColdContentionProbe {
    private var attempts = 0

    func observed(_ attempt: Int) { attempts = max(attempts, attempt) }

    func wait(for expected: Int) async -> Bool {
        for _ in 0..<500 {
            if attempts >= expected { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func count() -> Int { attempts }
}

private struct HandleJournalColdSettlementFixture {
    let home: AgentHome
    let work: WorkRef
    let route: WorkAgentHandleJournal
    let bundle: RunJournalBundle
    let origin: WorkAgentHandleOrigin
    let handle: HandleRef
    let started: TimelineJournalCommit
    let providerStarted: TimelineJournalCommit
    let admission: ProviderAdmission
}

private func makeHandleJournalColdSettlementFixture(
    suffix: String,
    retryPolicy: WorkAgentHandleJournal.ColdWriterRetryPolicy = .production,
    failurePlan: TimelineJournalWriter.FailurePlan = .none,
    contentionProbe: HandleJournalColdContentionProbe? = nil
) async throws -> HandleJournalColdSettlementFixture {
    let home = try handleJournalTestHome()
    let work = WorkRef(
        workHostID: try home.requirePersistedWorkHostID(),
        workID: "cold-settlement-work-\(suffix)")
    let identity = SessionWorkIdentity(
        sessionID: "cold-settlement-session-\(suffix)",
        work: work,
        runID: "cold-settlement-run-\(suffix)")
    let route = try WorkAgentHandleJournal(
        home: home,
        work: work,
        actor: TimelineActor(actorID: "cold-settlement-owner-\(suffix)", kind: "work-host"),
        coldWriterRetryPolicy: retryPolicy,
        coldWriterFailurePlan: failurePlan,
        didEncounterColdWriterContention: { attempt in
            await contentionProbe?.observed(attempt)
        })
    let bundle = try await route.openRun {
        try await RunJournalBundle.openForExecution(
            home: home,
            identity: identity,
            actorID: "cold-settlement-parent-\(suffix)",
            makeAttachmentID: { "cold-settlement-attachment-\(suffix)" })
    }
    let origin = WorkAgentHandleOrigin(
        work: work,
        workHost: WorkHostRef(work.workHostID),
        session: SessionRef(identity.sessionID),
        sessionAttachment: bundle.sessionAttachment,
        run: RunRef(identity.runID))
    let handle = HandleRef("cold-settlement-child-\(suffix)")
    let request = try ContextBodyStore(home: home).retain(
        Data("cold settlement request".utf8), authority: bundle.workJournal)
    let queued = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleQueued,
        origin: origin,
        handle: handle,
        payload: handleJournalPayload(WorkAgentHandleQueuedPayload(
            origin: origin,
            label: "Cold settlement child",
            requestBody: request))))
    let started = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleStarted,
        origin: origin,
        handle: handle,
        cause: queued.eventRef))
    let admission = ProviderAdmission(
        purpose: .normal,
        rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
            "id": .string("cold-settlement-model"),
            "provider": .string("fixture"),
        ]))))
    let providerStarted = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleProviderStarted,
        origin: origin,
        handle: handle,
        cause: started.eventRef,
        payload: .object([
            "ordinal": .string("1"),
            "admission": admission.timelineValue,
        ])))
    _ = try await bundle.finishRun(outcome: .completed)
    try await bundle.closeChecked()
    return HandleJournalColdSettlementFixture(
        home: home,
        work: work,
        route: route,
        bundle: bundle,
        origin: origin,
        handle: handle,
        started: started,
        providerStarted: providerStarted,
        admission: admission)
}

private func handleJournalProviderSettlementDraft(
    _ fixture: HandleJournalColdSettlementFixture
) -> TimelineEventDraft {
    let settlement = ProviderSettlement(
        admission: fixture.admission,
        report: nil,
        finality: .unconfirmed)
    return handleJournalDraft(
        TimelineEventType.agentHandleProviderSettled,
        origin: fixture.origin,
        handle: fixture.handle,
        cause: fixture.providerStarted.eventRef,
        payload: .object([
            "ordinal": .string("1"),
            "settlement": settlement.timelineValue,
            "state": .string(ActionExecutionState.failed.rawValue),
        ]))
}

private func handleJournalEvents(
    _ fixture: HandleJournalColdSettlementFixture
) throws -> [TimelineEvent] {
    TimelineJournalReader.read(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work)),
        journal: fixture.bundle.workJournal,
        actor: TimelineActor(actorID: "cold-settlement-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
}

func testWorkAgentHandleJournalOutlivesClosedRunWriter() async throws {
    let home = try handleJournalTestHome()
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
    let home = try handleJournalTestHome()
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

func testWorkAgentHandleJournalRetriesOnlyPrewriteCloseAcrossEnd() async throws {
    let home = try handleJournalTestHome()
    let work = WorkRef(
        workHostID: try home.requirePersistedWorkHostID(), workID: "provider-handoff-work")
    let identity = SessionWorkIdentity(
        sessionID: "provider-handoff-session", work: work, runID: "provider-handoff-run")
    let gate = HandleJournalBundleSelectionGate()
    let route = try WorkAgentHandleJournal(
        home: home, work: work,
        actor: TimelineActor(actorID: "provider-handoff-owner", kind: "work-host"),
        beforeBundleAgentAppend: { await gate.pauseIfArmed() })
    let bundle = try await route.openRun {
        try await RunJournalBundle.openForExecution(
            home: home, identity: identity, actorID: "provider-handoff-parent",
            makeAttachmentID: { "provider-handoff-attachment" })
    }
    let origin = WorkAgentHandleOrigin(
        work: work, workHost: WorkHostRef(work.workHostID),
        session: SessionRef(identity.sessionID), sessionAttachment: bundle.sessionAttachment,
        run: RunRef(identity.runID))
    let handle = HandleRef("provider-handoff-child")
    let body = try ContextBodyStore(home: home).retain(
        Data("provider handoff request".utf8), authority: bundle.workJournal)
    let queued = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleQueued, origin: origin, handle: handle,
        payload: handleJournalPayload(WorkAgentHandleQueuedPayload(
            origin: origin, label: "Provider handoff", requestBody: body))))
    let started = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleStarted, origin: origin, handle: handle,
        cause: queued.eventRef))
    let admission = ProviderAdmission(
        purpose: .normal,
        rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
            "id": .string("provider-handoff-model"),
            "provider": .string("fixture"),
        ]))))

    await gate.arm()
    let providerStartTask = Task {
        try await route.append(handleJournalDraft(
            TimelineEventType.agentHandleProviderStarted, origin: origin, handle: handle,
            cause: started.eventRef, payload: .object([
                "ordinal": .string("1"), "admission": admission.timelineValue,
            ])))
    }
    defer { Task { await gate.release() } }
    guard await gate.waitUntilSelected() else {
        await gate.release()
        providerStartTask.cancel()
        _ = try? await providerStartTask.value
        throw NSError(
            domain: "WorkAgentHandleJournalTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out selecting the parent bundle"])
    }

    _ = try await bundle.finishRun(outcome: .completed)
    try await bundle.closeChecked()
    await gate.release()
    let providerStarted = try await providerStartTask.value

    let settlement = ProviderSettlement(
        admission: admission, report: nil, finality: .unconfirmed)
    _ = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleProviderSettled, origin: origin, handle: handle,
        cause: providerStarted.eventRef, payload: .object([
            "ordinal": .string("1"), "settlement": settlement.timelineValue,
            "state": .string(ActionExecutionState.failed.rawValue),
        ])))
    _ = try await route.append(handleJournalDraft(
        TimelineEventType.agentHandleTerminal, origin: origin, handle: handle,
        cause: started.eventRef,
        payload: handleJournalPayload(WorkAgentHandleTerminalPayload(
            outcome: .failed, cleanup: .init(state: .quiesced)))))

    let events = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "provider-handoff-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    let providerStarts = events.filter {
        $0.type == TimelineEventType.agentHandleProviderStarted && $0.handle == handle
    }
    XCTAssertEqual(providerStarts.count, 1, "the pre-write close handoff must append exactly once")
    XCTAssertEqual(providerStarts.first?.eventID, providerStarted.eventRef.eventID)
    XCTAssertTrue(
        (try XCTUnwrap(events.first { $0.type == TimelineEventType.runFinished }?.sequence))
            < providerStarted.cursor.sequence)
    let head = try await route.read()
    let record = try head.agentHandle(for: handle.handleID)
    XCTAssertEqual(record.state, .terminal)
    XCTAssertEqual(record.providerAccounting.usage.started, 1)
    XCTAssertEqual(record.providerAccounting.usage.settled, 1)
    XCTAssertNil(record.providerAccounting.pending)
}

func testWorkAgentHandleJournalRetriesColdOwnerContentionForCanceledSettlement() async throws {
    let probe = HandleJournalColdContentionProbe()
    let fixture = try await makeHandleJournalColdSettlementFixture(
        suffix: "released-owner",
        retryPolicy: .init(
            maximumWaitNanoseconds: 1_000_000_000,
            maximumOpenAttempts: 64,
            initialDelayNanoseconds: 10_000_000,
            maximumDelayNanoseconds: 25_000_000),
        contentionProbe: probe)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let competingOwner = try TimelineJournalWriter(
        reopeningStreaming: fixture.home.timelineV2WorkJournalURL(fixture.work),
        journal: fixture.bundle.workJournal,
        actor: TimelineActor(actorID: "temporary-cold-owner", kind: "self-test"),
        home: fixture.home,
        allowTruncatedTail: false)
    let before = try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work))
    let append = Task {
        try await fixture.route.append(handleJournalProviderSettlementDraft(fixture))
    }
    guard await probe.wait(for: 1) else {
        append.cancel()
        try? await competingOwner.closeChecked()
        _ = try? await append.value
        throw NSError(
            domain: "WorkAgentHandleJournalTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "timed out observing cold writer contention"])
    }
    XCTAssertEqual(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work)), before,
        "constructor contention must occur before any settlement append")

    // Child settlement remains a durability obligation even if its execution task was canceled.
    append.cancel()
    try await competingOwner.closeChecked()
    let committed = try await append.value
    let events = try handleJournalEvents(fixture)
    let settlements = events.filter {
        $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == fixture.handle
    }
    XCTAssertEqual(settlements.count, 1)
    XCTAssertEqual(settlements.first?.eventID, committed.eventRef.eventID)
    let head = try await fixture.route.read()
    let record = try head.agentHandle(for: fixture.handle.handleID)
    XCTAssertEqual(record.providerAccounting.usage.started, 1)
    XCTAssertEqual(record.providerAccounting.usage.settled, 1)
    XCTAssertNil(record.providerAccounting.pending)
}

func testWorkAgentHandleJournalBoundsSustainedColdOwnerContention() async throws {
    let probe = HandleJournalColdContentionProbe()
    let fixture = try await makeHandleJournalColdSettlementFixture(
        suffix: "bounded-owner",
        retryPolicy: .init(
            maximumWaitNanoseconds: 5_000_000_000,
            maximumOpenAttempts: 3,
            initialDelayNanoseconds: 1_000_000,
            maximumDelayNanoseconds: 1_000_000),
        contentionProbe: probe)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let competingOwner = try TimelineJournalWriter(
        reopeningStreaming: fixture.home.timelineV2WorkJournalURL(fixture.work),
        journal: fixture.bundle.workJournal,
        actor: TimelineActor(actorID: "sustained-cold-owner", kind: "self-test"),
        home: fixture.home,
        allowTruncatedTail: false)
    let before = try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work))
    do {
        _ = try await fixture.route.append(handleJournalProviderSettlementDraft(fixture))
        XCTAssertTrue(false, "sustained owner contention must remain bounded")
    } catch let error as TimelineJournalWriter.WriterError {
        guard case .competingWriter = error else {
            XCTAssertTrue(false, "wrong sustained-contention error: \(error)")
            return
        }
    }
    XCTAssertEqual(await probe.count(), 3)
    XCTAssertEqual(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work)), before,
        "exhausting cold-open retries must not mutate the journal")

    try await competingOwner.closeChecked()
    _ = try await fixture.route.append(handleJournalProviderSettlementDraft(fixture))
    XCTAssertEqual(
        try handleJournalEvents(fixture).filter {
            $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == fixture.handle
        }.count,
        1,
        "an explicit retry after proven pre-write contention must append once")
}

func testWorkAgentHandleJournalNeverRetriesAmbiguousColdAppend() async throws {
    let probe = HandleJournalColdContentionProbe()
    let fixture = try await makeHandleJournalColdSettlementFixture(
        suffix: "ambiguous-append",
        failurePlan: .init(point: .afterWriteBeforeSync),
        contentionProbe: probe)
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    do {
        _ = try await fixture.route.append(handleJournalProviderSettlementDraft(fixture))
        XCTAssertTrue(false, "lost settlement confirmation must remain uncertain")
    } catch let error as TimelineJournalWriter.WriterError {
        XCTAssertEqual(error, .injected(.afterWriteBeforeSync))
    }
    XCTAssertEqual(await probe.count(), 0, "an admitted append failure is not open contention")
    XCTAssertEqual(
        try handleJournalEvents(fixture).filter {
            $0.type == TimelineEventType.agentHandleProviderSettled && $0.handle == fixture.handle
        }.count,
        1,
        "the uncertain cold append must never be repeated")
    let head = try await fixture.route.read()
    let record = try head.agentHandle(for: fixture.handle.handleID)
    XCTAssertEqual(record.providerAccounting.usage.started, 1)
    XCTAssertEqual(record.providerAccounting.usage.settled, 1)
    XCTAssertNil(record.providerAccounting.pending)
}

func testWorkAgentHandleJournalContentionTelemetryIsBounded() async throws {
    let (_, acquiredSpans) = try await AviaryTelemetry.withRecording {
        try await AviaryTelemetry.withSpan("aviary.test.journal_contention", root: true) {
            try await testWorkAgentHandleJournalRetriesColdOwnerContentionForCanceledSettlement()
        }
    }
    let acquired = acquiredSpans.flatMap(\.events).filter {
        $0.name == "aviary.agent_child.journal_acquisition"
    }
    XCTAssertEqual(acquired.count, 1, "poll retries must produce only one acquisition event")
    let event = try XCTUnwrap(acquired.first)
    XCTAssertEqual(event.attributes["aviary.outcome"], .string("accepted"))
    XCTAssertEqual(Set(event.attributes.keys), Set([
        "aviary.work.id", "aviary.outcome", "aviary.journal.open_attempts",
        "aviary.journal.acquisition.seconds",
    ]), "paths and error bodies are not acquisition metadata")
    if case .int(let attempts) = event.attributes["aviary.journal.open_attempts"] {
        XCTAssertTrue(attempts >= 2)
    } else { XCTAssertTrue(false, "missing attempt count") }
    if case .double(let elapsed) = event.attributes["aviary.journal.acquisition.seconds"] {
        XCTAssertTrue(elapsed >= 0)
    } else { XCTAssertTrue(false, "missing elapsed time") }

    let (_, exhaustedSpans) = try await AviaryTelemetry.withRecording {
        try await AviaryTelemetry.withSpan("aviary.test.journal_exhausted", root: true) {
            try await testWorkAgentHandleJournalBoundsSustainedColdOwnerContention()
        }
    }
    let exhausted = exhaustedSpans.flatMap(\.events).filter {
        $0.name == "aviary.agent_child.journal_acquisition"
    }
    XCTAssertEqual(exhausted.count, 1, "a later uncontended explicit retry emits no wait event")
    XCTAssertEqual(exhausted.first?.attributes["aviary.outcome"], .string("unavailable"))
    XCTAssertEqual(exhausted.first?.attributes["aviary.journal.open_attempts"], .int(3))

    let (_, uncontendedSpans) = try await AviaryTelemetry.withRecording {
        try await AviaryTelemetry.withSpan("aviary.test.journal_uncontended", root: true) {
            try await testWorkAgentHandleJournalNeverRetriesAmbiguousColdAppend()
        }
    }
    XCTAssertFalse(uncontendedSpans.flatMap(\.events).contains {
        $0.name == "aviary.agent_child.journal_acquisition"
    }, "an uncontended but uncertain append is not acquisition contention")
}

let casesWorkAgentHandleJournal: [Case] = [
    ("phase5 agent journal: contention telemetry is one bounded event", {
        try await testWorkAgentHandleJournalContentionTelemetryIsBounded()
    }),
    ("phase5 agent journal: post-End writer handoff and retained cold outcome", {
        try await testWorkAgentHandleJournalOutlivesClosedRunWriter()
    }),
    ("phase5 agent journal: failed closed writer remains canonically readable", {
        try await testWorkAgentHandleJournalReconcilesAfterAmbiguousClose()
    }),
    ("phase5 agent journal: provider admission retries only a pre-write End close", {
        try await testWorkAgentHandleJournalRetriesOnlyPrewriteCloseAcrossEnd()
    }),
    ("phase5 agent journal: canceled settlement waits for a cold owner lease", {
        try await testWorkAgentHandleJournalRetriesColdOwnerContentionForCanceledSettlement()
    }),
    ("phase5 agent journal: sustained cold owner contention is bounded", {
        try await testWorkAgentHandleJournalBoundsSustainedColdOwnerContention()
    }),
    ("phase5 agent journal: ambiguous cold append is never retried", {
        try await testWorkAgentHandleJournalNeverRetriesAmbiguousColdAppend()
    }),
]
