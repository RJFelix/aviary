import Foundation
@testable import AviaryCore

/// Provider crossings are settled at the native action boundary, including terminal responses
/// which have no usage payload and streams which end before terminal evidence.
let casesProviderSettlementAgent: [Case] = [
    ("provider settlement native completed response may have no usage report", {
        try await testProviderSettlementNativeCompletedWithoutReport()
    }),
    ("provider settlement native EOF records unconfirmed usage", {
        try await testProviderSettlementNativeEOF()
    }),
    ("provider settlement native failure retains usage without assistant commit", {
        try await testProviderSettlementNativeFailureAfterUsage()
    }),
    ("provider settlement native cancellation retains usage without assistant commit", {
        try await testProviderSettlementNativeCancellationAfterUsage()
    }),
    ("provider settlement is recomputed from pinned admission rates", {
        try testProviderSettlementUsesPinnedRates()
    }),
]

private struct ProviderSettlementCompletedProvider: ChatProvider {
    let id = "provider-settlement-completed"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("completed without a usage report"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private struct ProviderSettlementEOFProvider: ChatProvider {
    let id = "provider-settlement-eof"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.usage(ProviderUsage.RawReport(
                inputTokens: 13, outputTokens: 5, reportedTotalTokens: 18,
                inputAccounting: .cacheExclusive)))
            continuation.yield(.textDelta("partial before EOF"))
            continuation.finish()
        }
    }
}

private struct ProviderSettlementFailure: Error {}

private struct ProviderSettlementFailingProvider: ChatProvider {
    let id = "provider-settlement-failure"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.usage(ProviderUsage.RawReport(
                inputTokens: 13, outputTokens: 5, reportedTotalTokens: 18,
                inputAccounting: .cacheExclusive)))
            continuation.yield(.textDelta("partial before failure"))
            continuation.finish(throwing: ProviderSettlementFailure())
        }
    }
}

private actor ProviderSettlementCancellationGate {
    private var observed = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markObserved() {
        observed = true
    }

    func waitUntilObserved() async -> Bool {
        if observed { return true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !observed && ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return observed
    }

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private struct ProviderSettlementCancellationProvider: ChatProvider {
    let id = "provider-settlement-cancellation"
    let gate: ProviderSettlementCancellationGate

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.usage(ProviderUsage.RawReport(
                    inputTokens: 13, outputTokens: 5, reportedTotalTokens: 18,
                    inputAccounting: .cacheExclusive)))
                continuation.yield(.textDelta("observed before cancellation"))
                await gate.waitUntilReleased()
                continuation.finish(throwing: CancellationError())
            }
        }
    }
}

private func providerSettlementModel() -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string("provider-settlement-model"), "provider": .string("fake"),
    ]))
    model.contextWindow = 100_000
    model.costInput = 0.25
    model.costOutput = 0.75
    return model
}

private func providerSettlementFixture(
    name: String, provider: ChatProvider
) async throws -> (AgentHome, SessionWorkIdentity, RunJournalBundle, SessionWriter, Agent) {
    let home = AgentHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aviary-agent-test-\(UUID().uuidString)"))
    try FileManager.default.createDirectory(
        at: home.root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "provider-settlement-\(name)-session",
        work: WorkRef(workHostID: hostID, workID: "provider-settlement-\(name)-work"),
        runID: "provider-settlement-\(name)-run")
    let model = providerSettlementModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "provider-settlement-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "provider-settlement-\(name)-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    let agent = Agent(
        provider: provider,
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: "provider-settlement-runtime",
        config: .init(model: model, cwd: "/tmp", systemPrompt: "provider settlement"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    return (home, identity, bundle, writer, agent)
}

private func providerSettlementWorkEvents(
    home: AgentHome, identity: SessionWorkIdentity, bundle: RunJournalBundle
) throws -> [TimelineEvent] {
    TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "provider-settlement-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
}

private func providerSettlementSessionEvents(
    home: AgentHome, bundle: RunJournalBundle
) throws -> [TimelineEvent] {
    TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(bundle.session)),
        journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "provider-settlement-session-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
}

private func testProviderSettlementNativeCompletedWithoutReport() async throws {
    let (home, identity, bundle, writer, agent) = try await providerSettlementFixture(
        name: "completed", provider: ProviderSettlementCompletedProvider())
    defer { try? FileManager.default.removeItem(at: home.root) }

    let outcome = await agent.send("complete without usage")
    XCTAssertEqual(outcome, .completed)
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try providerSettlementWorkEvents(home: home, identity: identity, bundle: bundle)
    let started = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let action = try XCTUnwrap(started.action)
    let terminal = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionOutcome && $0.action == action
    })
    XCTAssertEqual(terminal.payload["state"]?.stringValue, ActionExecutionState.succeeded.rawValue)
    XCTAssertNotNil(terminal.payload["provider_settlement"])
    XCTAssertNil(terminal.payload["provider_settlement"]?.objectValue?["report"])
}

private func testProviderSettlementNativeEOF() async throws {
    let (home, identity, bundle, writer, agent) = try await providerSettlementFixture(
        name: "eof", provider: ProviderSettlementEOFProvider())
    defer { try? FileManager.default.removeItem(at: home.root) }

    let outcome = await agent.send("EOF must remain indeterminate")
    guard case .failed = outcome else {
        XCTFail("provider EOF without done must fail the send")
        return
    }
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try providerSettlementWorkEvents(home: home, identity: identity, bundle: bundle)
    let started = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let action = try XCTUnwrap(started.action)
    let terminal = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionOutcome && $0.action == action
    })
    XCTAssertEqual(
        terminal.payload["state"]?.stringValue,
        ActionExecutionState.indeterminateEffect.rawValue)
    let settlement = try XCTUnwrap(terminal.payload["provider_settlement"])
    XCTAssertEqual(settlement.objectValue?["finality"]?.stringValue, "unconfirmed")
    XCTAssertNotNil(settlement.objectValue?["report"])
}

private func testProviderSettlementNativeFailureAfterUsage() async throws {
    let (home, identity, bundle, writer, agent) = try await providerSettlementFixture(
        name: "failure", provider: ProviderSettlementFailingProvider())
    defer { try? FileManager.default.removeItem(at: home.root) }

    let outcome = await agent.send("failure must retain usage")
    guard case .failed = outcome else {
        XCTFail("provider failure after usage must fail the send")
        return
    }
    XCTAssertEqual((await agent.totalUsage).totalTokens, 18)
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try providerSettlementWorkEvents(home: home, identity: identity, bundle: bundle)
    let started = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let action = try XCTUnwrap(started.action)
    let outcomes = events.filter { $0.type == TimelineEventType.actionOutcome && $0.action == action }
    XCTAssertEqual(outcomes.count, 1)
    let terminal = try XCTUnwrap(outcomes.first)
    XCTAssertEqual(
        terminal.payload["state"]?.stringValue,
        ActionExecutionState.indeterminateEffect.rawValue)
    XCTAssertEqual(terminal.payload["provider_settlement"]?.objectValue?["finality"]?.stringValue,
                   "unconfirmed")
    XCTAssertNotNil(terminal.payload["provider_settlement"]?.objectValue?["report"])

    let sessionEvents = try providerSettlementSessionEvents(home: home, bundle: bundle)
    XCTAssertFalse(sessionEvents.contains {
        $0.type == TimelineEventType.messageCommitted
            && $0.payload["role"]?.stringValue == ChatRole.assistant.rawValue
    })
}

private func testProviderSettlementNativeCancellationAfterUsage() async throws {
    let gate = ProviderSettlementCancellationGate()
    let (home, identity, bundle, writer, agent) = try await providerSettlementFixture(
        name: "cancellation", provider: ProviderSettlementCancellationProvider(gate: gate))
    defer { try? FileManager.default.removeItem(at: home.root) }

    await agent.observe { event in
        if case .textDelta = event {
            Task { await gate.markObserved() }
        }
    }
    let sending = Task { await agent.send("cancel after usage") }
    XCTAssertTrue(await gate.waitUntilObserved(), "Agent did not observe provider output")
    await agent.cancel()
    await gate.release()
    let outcome = await sending.value
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual((await agent.totalUsage).totalTokens, 18)
    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()

    let events = try providerSettlementWorkEvents(home: home, identity: identity, bundle: bundle)
    let started = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let action = try XCTUnwrap(started.action)
    let outcomes = events.filter { $0.type == TimelineEventType.actionOutcome && $0.action == action }
    XCTAssertEqual(outcomes.count, 1)
    let terminal = try XCTUnwrap(outcomes.first)
    XCTAssertEqual(
        terminal.payload["state"]?.stringValue,
        ActionExecutionState.indeterminateEffect.rawValue)
    XCTAssertEqual(terminal.payload["provider_settlement"]?.objectValue?["finality"]?.stringValue,
                   "unconfirmed")
    XCTAssertNotNil(terminal.payload["provider_settlement"]?.objectValue?["report"])

    let sessionEvents = try providerSettlementSessionEvents(home: home, bundle: bundle)
    XCTAssertFalse(sessionEvents.contains {
        $0.type == TimelineEventType.messageCommitted
            && $0.payload["role"]?.stringValue == ChatRole.assistant.rawValue
    })
}

private func testProviderSettlementUsesPinnedRates() throws {
    let model = providerSettlementModel()
    let admission = ProviderAdmission(
        purpose: .normal, rates: ProviderUsage.RateSnapshot(model: model))
    let report = ProviderUsage.RawReport(
        inputTokens: 4, outputTokens: 2, cacheReadTokens: 0, cacheWriteTokens: 0, reportedTotalTokens: 6,
        inputAccounting: .cacheExclusive)
    let settlement = ProviderSettlement(
        admission: admission, report: report, finality: .finalReport)
    XCTAssertEqual(settlement.accounted.totalTokens, 6)
    XCTAssertTrue(abs((settlement.accounted.price.total ?? -1) - 0.0000025) < 1e-12)
    XCTAssertEqual(settlement.finality, .finalReport)
}
