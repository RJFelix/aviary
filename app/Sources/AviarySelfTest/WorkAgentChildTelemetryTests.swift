import Foundation
import OpenTelemetrySdk

@testable import AviaryCore

private actor WorkAgentChildTelemetryGate {
    private var released = false

    func wait() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !released && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return released
    }

    func release() {
        released = true
    }
}

private actor WorkAgentTelemetryExecution: WorkAgentChildExecution {
    let childID: String
    let gate: WorkAgentChildTelemetryGate?

    init(childID: String, gate: WorkAgentChildTelemetryGate?) {
        self.childID = childID
        self.gate = gate
    }

    func execute() async -> AgentChildExecutionResult {
        if let gate, !(await gate.wait()) {
            return AgentChildExecutionResult(
                childID: childID, state: .failed, detail: "test gate was not released",
                cleanup: AgentChildExecutionCleanup(
                    runtimeSessionDestroyed: true, runtimeStopped: true, transcriptClosed: true))
        }
        let result = await AviaryTelemetry.withSpan("aviary.test.child.inner") {
            AgentChildExecutionResult(
                childID: childID, state: .succeeded, answer: "telemetry answer",
                cleanup: AgentChildExecutionCleanup(
                    runtimeSessionDestroyed: true, runtimeStopped: true, transcriptClosed: true))
        }
        return result
    }

    func cancel() async -> AgentChildCancellationOutcome {
        await gate?.release()
        return .accepted
    }
}

private actor WorkAgentTelemetryUnquiescedExecution: WorkAgentChildExecution {
    let childID: String

    init(childID: String) { self.childID = childID }

    func execute() async -> AgentChildExecutionResult {
        AgentChildExecutionResult(
            childID: childID, state: .failed, detail: "cleanup remains in progress",
            cleanup: AgentChildExecutionCleanup(
                runtimeSessionDestroyed: false, runtimeStopped: false, transcriptClosed: true))
    }

    func cancel() async -> AgentChildCancellationOutcome { .accepted }
}

private final class WorkAgentTelemetryFactoryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private struct WorkAgentTelemetryFixture {
    let home: AgentHome
    let binding: WorkRunBinding
    let bundle: RunJournalBundle
}

private func workAgentTelemetryFixture(
    coordinator: WorkAgentChildCoordinator, suffix: String
) async throws -> WorkAgentTelemetryFixture {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appending(path: "wact-\(String(UUID().uuidString.prefix(8)).lowercased())",
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
    let home = AgentHome(root: root)
    let host = try home.requirePersistedWorkHost()
    let work = WorkRef(workHostID: host.workHostID, workID: "telemetry-work-\(suffix)")
    let binding = WorkRunBinding(
        workBinding: WorkBinding(
            session: SessionRef("telemetry-session-\(suffix)"), work: work, workHost: host,
            sessionAttachment: SessionAttachmentRef("telemetry-attachment-\(suffix)")),
        run: RunRef("telemetry-run-\(suffix)"))
    try await coordinator.register(
        work: work, home: home,
        actor: TimelineActor(actorID: "telemetry-owner-\(suffix)", kind: "self-test"))
    let bundle = try await coordinator.openRun(work: work) {
        try await RunJournalBundle.openForExecution(
            home: home,
            identity: SessionWorkIdentity(
                sessionID: binding.workBinding.session.sessionID, work: work,
                runID: binding.run.runID),
            actorID: "telemetry-parent-\(suffix)",
            makeAttachmentID: { binding.workBinding.sessionAttachment.attachmentID })
    }
    return WorkAgentTelemetryFixture(home: home, binding: binding, bundle: bundle)
}

private func workAgentTelemetryWaitForState(
    _ coordinator: WorkAgentChildCoordinator, work: WorkRef, handle: HandleRef,
    state: WorkAgentHandleState
) async throws -> BoundedWorkAgentHandleIndexRecord {
    for _ in 0..<400 {
        if let record = try? await coordinator.inspect(work: work, handle: handle),
           record.state == state { return record }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw NSError(
        domain: "WorkAgentChildTelemetryTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "child did not reach \(state.rawValue)"])
}

func test_phase5WorkAgentChildTelemetryLinksAdmissionToIndependentExecution() async throws {
    let coordinator = try WorkAgentChildCoordinator(
        limits: try WorkAgentChildAdmissionQueue.Limits(executing: 1, queued: 4, queuedPerWork: 4))
    let fixture = try await workAgentTelemetryFixture(
        coordinator: coordinator, suffix: "linking")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let gate = WorkAgentChildTelemetryGate()
    defer { Task { await gate.release() } }
    let factoryCount = WorkAgentTelemetryFactoryCount()
    let factory: WorkAgentChildCoordinator.ExecutionFactory = { handle, _ in
        let ordinal = factoryCount.next()
        return WorkAgentTelemetryExecution(
            childID: handle.handleID, gate: ordinal == 1 ? gate : nil)
    }

    let (bTerminal, spans) = try await AviaryTelemetry.withRecording(waitingFor: { spans in
        spans.filter { $0.name == "aviary.agent_child.execution" }.count == 2
    }) {
        let a = try await AviaryTelemetry.withSpan("aviary.test.child.admission_a", root: true) {
            try await coordinator.admit(
                origin: fixture.binding, prompt: "first", label: "first",
                makeExecution: factory, admissionContext: AviaryTelemetry.context)
        }
        _ = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: a.handle, state: .running)

        let b = try await AviaryTelemetry.withSpan("aviary.test.child.admission_b", root: true) {
            try await coordinator.admit(
                origin: fixture.binding, prompt: "second", label: "second",
                executionLimits: try WorkAgentExecutionLimits(
                    maximumTokens: 100, maximumEstimatedCostUSD: 0.25),
                makeExecution: factory, admissionContext: AviaryTelemetry.context)
        }
        _ = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: b.handle, state: .queued)

        // Interest arrives under an unrelated caller span. The eventual execution must still
        // link to B's admission rather than inheriting this observer's context.
        try await AviaryTelemetry.withSpan("aviary.test.child.unrelated_observer", root: true) {
            _ = try await coordinator.awaitInterest(
                work: fixture.binding.workBinding.work, handle: b.handle,
                observerID: "telemetry-observer", awaited: true)
        }
        await gate.release()
        let aTerminal = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: a.handle, state: .terminal)
        let bTerminal = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: b.handle, state: .terminal)
        XCTAssertEqual(aTerminal.terminalOutcome, .succeeded)
        XCTAssertEqual(bTerminal.terminalOutcome, .succeeded)
        try await fixture.bundle.closeChecked()
        return bTerminal
    }

    let admissions = spans.filter { $0.name == "aviary.agent_child.admission" }
    XCTAssertEqual(admissions.count, 2)
    let admissionB = try XCTUnwrap(admissions.last)
    XCTAssertEqual(admissionB.attributes["aviary.outcome"], .string("accepted"))
    XCTAssertEqual(admissionB.attributes["aviary.agent_child.limit.tokens"], .int(100))
    XCTAssertEqual(admissionB.attributes["aviary.agent_child.limit.estimated_usd"], .double(0.25))
    XCTAssertEqual(admissionB.attributes["aviary.agent_child.limit.time_enabled"], .bool(false))
    let executionB = try XCTUnwrap(spans.first { span in
        span.name == "aviary.agent_child.execution"
            && span.links.contains { $0.context.spanId == admissionB.spanId }
    })
    XCTAssertNil(executionB.parentSpanId)
    XCTAssertEqual(executionB.links.count, 1)
    XCTAssertNotNil(executionB.attributes["aviary.handle.id"])
    XCTAssertNotNil(executionB.attributes["aviary.work.id"])
    XCTAssertNotNil(executionB.attributes["aviary.run.id"])
    XCTAssertTrue(executionB.attributes["aviary.queue.wait.seconds"] != nil)
    for name in ["aviary.agent_child.started", "aviary.agent_child.terminal"] {
        let event = try XCTUnwrap(executionB.events.first { $0.name == name })
        XCTAssertNotNil(event.attributes["aviary.handle.id"])
        XCTAssertNotNil(event.attributes["aviary.event.id"])
        XCTAssertEqual(event.attributes["aviary.event.journal.id"], .string(AviaryTelemetry.journalIdentity(fixture.bundle.workJournal)))
        XCTAssertNotNil(event.attributes["aviary.event.sequence"])
    }
    let terminalEvent = try XCTUnwrap(executionB.events.first {
        $0.name == "aviary.agent_child.terminal"
    })
    XCTAssertEqual(
        terminalEvent.attributes["aviary.event.id"],
        .string(AviaryTelemetry.identity(bTerminal.latestLifecycleEvent.eventID)))
    let inner = try XCTUnwrap(spans.first {
        $0.name == "aviary.test.child.inner" && $0.traceId == executionB.traceId
    })
    XCTAssertEqual(inner.parentSpanId, executionB.spanId)
    XCTAssertEqual(executionB.attributes["aviary.outcome"], .string("succeeded"))
}

func test_phase5WorkAgentChildTelemetryRecordsQueuedSettlementWithoutExecution() async throws {
    let coordinator = try WorkAgentChildCoordinator(
        limits: try WorkAgentChildAdmissionQueue.Limits(executing: 1, queued: 2, queuedPerWork: 2))
    let fixture = try await workAgentTelemetryFixture(
        coordinator: coordinator, suffix: "queued-settlement")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let factoryCount = WorkAgentTelemetryFactoryCount()
    let factory: WorkAgentChildCoordinator.ExecutionFactory = { handle, _ in
        let ordinal = factoryCount.next()
        if ordinal == 1 { return WorkAgentTelemetryUnquiescedExecution(childID: handle.handleID) }
        return WorkAgentTelemetryExecution(childID: handle.handleID, gate: nil)
    }

    let (settlement, spans) = try await AviaryTelemetry.withRecording(waitingFor: { spans in
        spans.contains { $0.name == "aviary.agent_child.settlement" }
            && spans.contains { $0.name == "aviary.agent_child.execution" }
    }) {
        let blocker = try await coordinator.admit(
            origin: fixture.binding, prompt: "retain the executing slot", label: "blocker",
            makeExecution: factory)
        let blockerRecord = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: blocker.handle,
            state: .terminal)
        XCTAssertEqual(blockerRecord.terminalOutcome, .indeterminate)

        let target = try await coordinator.admit(
            origin: fixture.binding, prompt: "cancel while queued", label: "queued target",
            makeExecution: factory)
        _ = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: target.handle,
            state: .queued)
        let cursor = try XCTUnwrap(await fixture.bundle.status.durablePrefix.workCursor)
        let cancel = try await coordinator.cancel(
            work: fixture.binding.workBinding.work, handle: target.handle,
            command: CommandRef(
                commandID: "queued-settlement-cancel", client: ClientRef("telemetry-client"),
                sessionAttachment: fixture.binding.workBinding.sessionAttachment,
                causalCursor: cursor))
        XCTAssertEqual(cancel, .accepted)
        let terminal = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: target.handle,
            state: .terminal)
        XCTAssertEqual(terminal.terminalOutcome, .canceled)
        XCTAssertEqual(factoryCount.count, 1)
        try await fixture.bundle.closeChecked()
        return terminal
    }

    let settlementSpan = try XCTUnwrap(spans.first { $0.name == "aviary.agent_child.settlement" })
    XCTAssertNil(settlementSpan.parentSpanId)
    let admissions = spans.filter { $0.name == "aviary.agent_child.admission" }
    XCTAssertEqual(admissions.count, 2)
    let targetAdmission = try XCTUnwrap(admissions.last)
    XCTAssertEqual(settlementSpan.links.count, 1)
    XCTAssertEqual(settlementSpan.links.first?.context.spanId, targetAdmission.spanId)
    XCTAssertEqual(settlementSpan.links.first?.context.traceId, targetAdmission.traceId)
    XCTAssertEqual(settlementSpan.attributes["aviary.outcome"], .string("canceled"))
    XCTAssertEqual(
        spans.first { $0.name == "aviary.agent_child.execution" }?.attributes["aviary.outcome"],
        .string("indeterminate"))
    XCTAssertNil(spans.first {
        $0.name == "aviary.agent_child.execution"
            && $0.attributes["aviary.handle.id"] == settlementSpan.attributes["aviary.handle.id"]
    })
    XCTAssertNotNil(settlementSpan.attributes["aviary.handle.id"])
    let event = try XCTUnwrap(settlementSpan.events.first { $0.name == "aviary.agent_child.terminal" })
    XCTAssertEqual(event.attributes["aviary.event.journal.id"], .string(AviaryTelemetry.journalIdentity(settlement.latestLifecycleEvent.journal)))
    XCTAssertEqual(
        event.attributes["aviary.event.id"],
        .string(AviaryTelemetry.identity(settlement.latestLifecycleEvent.eventID)))
}

func test_phase5WorkAgentChildTelemetryRecordsRunningCancellation() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await workAgentTelemetryFixture(
        coordinator: coordinator, suffix: "running-cancellation")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let gate = WorkAgentChildTelemetryGate()
    defer { Task { await gate.release() } }
    let factory: WorkAgentChildCoordinator.ExecutionFactory = { handle, _ in
        WorkAgentTelemetryExecution(childID: handle.handleID, gate: gate)
    }

    let (terminal, spans) = try await AviaryTelemetry.withRecording(waitingFor: { spans in
        spans.contains { $0.name == "aviary.agent_child.execution" }
    }) {
        let admission = try await coordinator.admit(
            origin: fixture.binding, prompt: "cancel a running child", label: "running child",
            makeExecution: factory)
        _ = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
            state: .running)
        let cursor = try XCTUnwrap(await fixture.bundle.status.durablePrefix.workCursor)
        let cancellation = try await coordinator.cancel(
            work: fixture.binding.workBinding.work, handle: admission.handle,
            command: CommandRef(
                commandID: "running-cancel", client: ClientRef("telemetry-client"),
                sessionAttachment: fixture.binding.workBinding.sessionAttachment,
                causalCursor: cursor))
        XCTAssertEqual(cancellation, .accepted)
        let terminal = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
            state: .terminal)
        XCTAssertEqual(terminal.terminalOutcome, .canceled)
        try await fixture.bundle.closeChecked()
        return terminal
    }

    let execution = try XCTUnwrap(spans.first { $0.name == "aviary.agent_child.execution" })
    XCTAssertEqual(execution.attributes["aviary.outcome"], .string("canceled"))
    XCTAssertEqual(execution.events.filter { $0.name == "aviary.agent_child.terminal" }.count, 1)
    XCTAssertEqual(execution.events.first { $0.name == "aviary.agent_child.terminal" }?.attributes["aviary.event.journal.id"], .string(AviaryTelemetry.journalIdentity(terminal.latestLifecycleEvent.journal)))
    XCTAssertEqual(
        execution.events.first { $0.name == "aviary.agent_child.terminal" }?.attributes["aviary.event.id"],
        .string(AviaryTelemetry.identity(terminal.latestLifecycleEvent.eventID)))
}

func test_phase5WorkAgentChildTelemetryRecordsQueuedDeadlineWithoutExecution() async throws {
    let coordinator = try WorkAgentChildCoordinator(
        limits: try WorkAgentChildAdmissionQueue.Limits(executing: 1, queued: 2, queuedPerWork: 2))
    let fixture = try await workAgentTelemetryFixture(
        coordinator: coordinator, suffix: "queued-deadline")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let factoryCount = WorkAgentTelemetryFactoryCount()
    let factory: WorkAgentChildCoordinator.ExecutionFactory = { handle, _ in
        let ordinal = factoryCount.next()
        if ordinal == 1 { return WorkAgentTelemetryUnquiescedExecution(childID: handle.handleID) }
        return WorkAgentTelemetryExecution(childID: handle.handleID, gate: nil)
    }

    let (terminal, spans) = try await AviaryTelemetry.withRecording(waitingFor: { spans in
        spans.contains { $0.name == "aviary.agent_child.settlement" }
            && spans.contains { $0.name == "aviary.agent_child.execution" }
    }) {
        let blocker = try await coordinator.admit(
            origin: fixture.binding, prompt: "retain the executing slot", label: "blocker",
            makeExecution: factory)
        _ = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: blocker.handle,
            state: .terminal)
        let target = try await coordinator.admit(
            origin: fixture.binding, prompt: "expire while queued", label: "queued deadline",
            deadline: Date().addingTimeInterval(0.3), makeExecution: factory)
        let terminal = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: target.handle,
            state: .terminal)
        XCTAssertEqual(terminal.terminalOutcome, .expired)
        XCTAssertEqual(factoryCount.count, 1)
        try await fixture.bundle.closeChecked()
        return terminal
    }

    let settlement = try XCTUnwrap(spans.first { $0.name == "aviary.agent_child.settlement" })
    let admissions = spans.filter { $0.name == "aviary.agent_child.admission" }
    XCTAssertEqual(admissions.count, 2)
    let targetAdmission = try XCTUnwrap(admissions.last)
    XCTAssertNil(settlement.parentSpanId)
    XCTAssertEqual(settlement.links.count, 1)
    XCTAssertEqual(settlement.links.first?.context.spanId, targetAdmission.spanId)
    XCTAssertEqual(settlement.links.first?.context.traceId, targetAdmission.traceId)
    XCTAssertEqual(settlement.attributes["aviary.outcome"], .string("expired"))
    XCTAssertEqual(settlement.events.first { $0.name == "aviary.agent_child.terminal" }?.attributes["aviary.event.journal.id"], .string(AviaryTelemetry.journalIdentity(terminal.latestLifecycleEvent.journal)))
    XCTAssertNil(spans.first { $0.name == "aviary.agent_child.execution" &&
        $0.attributes["aviary.handle.id"] == settlement.attributes["aviary.handle.id"] })
    XCTAssertEqual(
        settlement.events.first { $0.name == "aviary.agent_child.terminal" }?.attributes["aviary.event.id"],
        .string(AviaryTelemetry.identity(terminal.latestLifecycleEvent.eventID)))
}

func test_phase5WorkAgentChildTelemetryMarksAfterWriteTerminalAsIndeterminate() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await workAgentTelemetryFixture(
        coordinator: coordinator, suffix: "after-write-terminal")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let gate = WorkAgentChildTelemetryGate()
    defer { Task { await gate.release() } }
    let factory: WorkAgentChildCoordinator.ExecutionFactory = { handle, _ in
        WorkAgentTelemetryExecution(childID: handle.handleID, gate: gate)
    }

    let (_, spans) = try await AviaryTelemetry.withRecording(waitingFor: { spans in
        spans.contains { $0.name == "aviary.agent_child.execution" }
    }) {
        let admission = try await coordinator.admit(
            origin: fixture.binding, prompt: "terminal write may be uncertain",
            label: "after-write", makeExecution: factory)
        _ = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
            state: .running)
        await fixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
        await gate.release()
        var reachedAmbiguous = false
        for _ in 0..<400 {
            if (await coordinator.ownerObservation()).ambiguousCount == 1 {
                reachedAmbiguous = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(reachedAmbiguous)
        // The failed sync leaves the canonical terminal unreadable until the bundle closes.
        try? await fixture.bundle.closeChecked()
        let terminal = try await workAgentTelemetryWaitForState(
            coordinator, work: fixture.binding.workBinding.work, handle: admission.handle,
            state: .terminal)
        XCTAssertEqual(terminal.terminalOutcome, .succeeded)
        return terminal
    }

    let execution = try XCTUnwrap(spans.first { $0.name == "aviary.agent_child.execution" })
    XCTAssertEqual(execution.attributes["aviary.outcome"], .string("indeterminate"))
    // The append was not proven at the time the task ended, so no terminal event is emitted.
    // The canonical read above proves the later terminal independently of this span.
    XCTAssertNil(execution.events.first { $0.name == "aviary.agent_child.terminal" })
}

func test_phase5WorkAgentChildTelemetryRejectedAdmissionHasNoEffect() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await workAgentTelemetryFixture(coordinator: coordinator, suffix: "rejected")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let count = WorkAgentTelemetryFactoryCount()
    let before = await fixture.bundle.status.durablePrefix.workCursor
    let (_, spans) = try await AviaryTelemetry.withRecording {
        do {
            _ = try await coordinator.admit(
                origin: fixture.binding, prompt: "", label: "invalid empty request",
                makeExecution: { handle, _ in
                    _ = count.next()
                    return WorkAgentTelemetryExecution(childID: handle.handleID, gate: nil)
                })
            XCTFail("empty request was admitted")
        } catch WorkAgentChildCoordinator.Failure.invalidRequest { }
        let after = await fixture.bundle.status.durablePrefix.workCursor
        XCTAssertEqual(after, before)
        XCTAssertEqual((await coordinator.ownerObservation()).totalOwnedEntryCount, 0)
        try await fixture.bundle.closeChecked()
    }
    XCTAssertEqual(count.count, 0)
    let admission = try XCTUnwrap(spans.first { $0.name == "aviary.agent_child.admission" })
    XCTAssertEqual(admission.attributes["aviary.outcome"], .string("rejected"))
    XCTAssertTrue(admission.events.isEmpty)
    XCTAssertFalse(spans.contains { $0.name == "aviary.agent_child.execution" })
}

func test_phase5WorkAgentChildTelemetryUncertainAdmissionRetainsHandleWithoutExecution() async throws {
    let coordinator = try WorkAgentChildCoordinator()
    let fixture = try await workAgentTelemetryFixture(coordinator: coordinator, suffix: "uncertain")
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let count = WorkAgentTelemetryFactoryCount()
    await fixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
    let (_, spans) = try await AviaryTelemetry.withRecording {
        var retained: HandleRef?
        do {
            _ = try await coordinator.admit(
                origin: fixture.binding, prompt: "keep the uncertain admission", label: "uncertain",
                makeExecution: { handle, _ in
                    _ = count.next()
                    return WorkAgentTelemetryExecution(childID: handle.handleID, gate: nil)
                })
            XCTFail("uncertain admission returned success")
        } catch WorkAgentChildCoordinator.Failure.admissionUncertain(let handle) {
            retained = handle
        }
        let handle = try XCTUnwrap(retained)
        XCTAssertEqual((await coordinator.ownerObservation()).ambiguousCount, 1)
        XCTAssertEqual(count.count, 0)
        try? await fixture.bundle.closeChecked()
        let canonical = try await coordinator.inspect(work: fixture.binding.workBinding.work, handle: handle)
        XCTAssertEqual(canonical.state, .queued)
        XCTAssertEqual(canonical.origin.run, fixture.binding.run)
        XCTAssertEqual(count.count, 0)
    }
    let admission = try XCTUnwrap(spans.first { $0.name == "aviary.agent_child.admission" })
    XCTAssertEqual(admission.attributes["aviary.outcome"], .string("indeterminate"))
    XCTAssertFalse(admission.events.contains { $0.name == "aviary.agent_child.queued" })
    XCTAssertFalse(spans.contains { $0.name == "aviary.agent_child.execution" })
}

let casesWorkAgentChildTelemetry: [Case] = [
    ("phase5 child telemetry: limit reasons are bounded and retained", {
        let (_, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.child.limited", root: true) {
                for reason in ["tokenThresholdReached", "costThresholdReached",
                               "tokenAccountingUnknown", "costAccountingUnknown", "private-raw-reason"] {
                    AviaryTelemetry.event("aviary.agent_child.provider.limit_refused", attributes: [
                        "aviary.outcome": .string("limited"),
                        "aviary.agent_child.limit.reason": .string(reason),
                    ])
                }
            }
        }
        let events = try XCTUnwrap(spans.first).events
        XCTAssertEqual(events.count, 5)
        for event in events.prefix(4) {
            XCTAssertEqual(event.attributes["aviary.outcome"], .string("limited"))
            XCTAssertNotNil(event.attributes["aviary.agent_child.limit.reason"])
        }
        XCTAssertNil(events.last?.attributes["aviary.agent_child.limit.reason"])
    }),
    ("phase5 child telemetry: rejected admission has no effect", {
        try await test_phase5WorkAgentChildTelemetryRejectedAdmissionHasNoEffect()
    }),
    ("phase5 child telemetry: uncertain admission retains Handle without execution", {
        try await test_phase5WorkAgentChildTelemetryUncertainAdmissionRetainsHandleWithoutExecution()
    }),
    ("phase5 child telemetry: admission links independent execution", {
        try await test_phase5WorkAgentChildTelemetryLinksAdmissionToIndependentExecution()
    }),
    ("phase5 child telemetry: queued settlement has no execution", {
        try await test_phase5WorkAgentChildTelemetryRecordsQueuedSettlementWithoutExecution()
    }),
    ("phase5 child telemetry: running cancellation outcome", {
        try await test_phase5WorkAgentChildTelemetryRecordsRunningCancellation()
    }),
    ("phase5 child telemetry: queued deadline has no execution", {
        try await test_phase5WorkAgentChildTelemetryRecordsQueuedDeadlineWithoutExecution()
    }),
    ("phase5 child telemetry: after-write terminal is indeterminate", {
        try await test_phase5WorkAgentChildTelemetryMarksAfterWriteTerminalAsIndeterminate()
    }),
]
