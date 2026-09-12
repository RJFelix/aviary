import Foundation
import OpenTelemetrySdk
@testable import AviaryCore

/// These tests exercise the real Agent seams, rather than testing a hand-written span helper.
let casesAviaryTelemetryAgent: [Case] = [
    ("telemetry Agent records bounded send/provider/tool/callback spans", {
        try await testAviaryTelemetryAgentSpans()
    }),
    ("telemetry native Agent links provider span to canonical action", {
        try await testAviaryTelemetryNativeAgentActionLink()
    }),
    ("telemetry native Agent marks post-dispatch provider failure indeterminate", {
        try await testAviaryTelemetryNativeAgentFailure()
    }),
    ("telemetry Agent pins provider accounting to the dispatch model across a switch", {
        try await testAviaryTelemetryAgentSwitchesModelMidstream()
    }),
    ("telemetry native completed provider with unrecordable outcome is indeterminate", {
        try await testAviaryTelemetryNativeCompletedProviderOutcomeFailure()
    }),
    ("telemetry native Python outcome write failure is indeterminate", {
        try await testAviaryTelemetryActualPythonOutcomeWriteFailure()
    }),
    ("telemetry callback action outcome write failure is indeterminate", {
        try await testAviaryTelemetryCallbackActionOutcomeWriteFailure()
    }),
    ("telemetry native preflight admission is rejected", {
        try await testAviaryTelemetryNativePreflightAdmissionRejected()
    }),
    ("telemetry native partial admission is indeterminate", {
        try await testAviaryTelemetryNativePartialAdmissionIndeterminate()
    }),
    ("telemetry native provider without terminal done is indeterminate", {
        try await testAviaryTelemetryNativeProviderWithoutTerminalDone()
    }),
]

private struct TelemetryAgentProvider: ChatProvider {
    let id = "telemetry-agent-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("bounded answer"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private struct TelemetryAgentProviderFailure: Error {}

private struct TelemetryAgentPeerOutcomeFailure: Agent.PeerDelegate {
    let bundle: RunJournalBundle

    func peers(excluding sessionID: String) async -> [Agent.Peer] { [] }

    func deliver(to peer: String, text: String, from sessionID: String) async
        -> (session: String, error: String?)
    {
        await bundle.injectWriterFailure(.beforeWrite, in: .work)
        return (peer, nil)
    }
}

private actor TelemetryHeldProviderGate {
    private var started = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !started && ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return started
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

private struct TelemetryHeldProvider: ChatProvider {
    let id = "telemetry-held-provider"
    let gate: TelemetryHeldProviderGate
    let usage: ProviderUsage.RawReport


    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await gate.markStarted()
                await gate.waitUntilReleased()
                continuation.yield(.usage(usage))
                continuation.yield(.textDelta("held answer"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private struct TelemetryReplacementProvider: ChatProvider {
    let id = "telemetry-replacement-provider"
    let usage: ProviderUsage.RawReport


    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.usage(usage))
            continuation.yield(.textDelta("replacement answer"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private actor TelemetryProviderCallCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct TelemetryAgentCompletingWriterFailureProvider: ChatProvider {
    let id = "telemetry-completing-writer-failure-provider"
    let bundle: RunJournalBundle
    let calls: TelemetryProviderCallCounter


    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.increment()
                // The provider has been called only after the native action start is durable.
                // Make its terminal Work receipt fail while allowing the provider itself to
                // complete, so the Agent must not claim a successful effect or retry it.
                await bundle.injectWriterFailure(.beforeWrite, in: .work)
                continuation.yield(.usage(telemetryAgentUsage(input: 9, output: 3)))
                continuation.yield(.textDelta("completed provider body"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private struct TelemetryAgentFailingProvider: ChatProvider {
    let id = "telemetry-agent-failing-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("partial response"))
            continuation.finish(throwing: TelemetryAgentProviderFailure())
        }
    }
}

private struct TelemetryAgentQuietEOFProvider: ChatProvider {
    let id = "telemetry-agent-quiet-eof-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.usage(telemetryAgentUsage(input: 13, output: 5)))
            continuation.yield(.textDelta("QUIET_EOF_RESPONSE"))
            continuation.yield(.toolCall(
                id: "quiet-eof-tool", name: "unknown_tool", arguments: .object([:])))
            // A provider that closes without `.done` has not proved a terminal response.
            continuation.finish()
        }
    }
}

private func telemetryAgentModel() -> ModelSpec {
    var model = ModelSpec(rpc: .object(["id": .string("test-model"), "provider": .string("fake")]))
    model.contextWindow = 100_000
    return model
}

private func telemetryAgentUsage(input: Int, output: Int) -> ProviderUsage.RawReport {
    ProviderUsage.RawReport(inputTokens: input, outputTokens: output, cacheReadTokens: 0,
        cacheWriteTokens: 0, reportedTotalTokens: input + output, inputAccounting: .cacheExclusive)
}

private func telemetryAgentPricedModel(
    id: String, provider: String, inputRate: Double, outputRate: Double
) -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string(id), "provider": .string(provider),
    ]))
    model.contextWindow = 100_000
    model.costInput = inputRate
    model.costOutput = outputRate
    return model
}

private func telemetryAgentAttributeString(_ span: SpanData, key: String) -> String? {
    guard case .string(let value)? = span.attributes[key] else { return nil }
    return value
}

private func telemetryAgentEventAttributeString(
    _ event: SpanData.Event, key: String
) -> String? {
    guard case .string(let value)? = event.attributes[key] else { return nil }
    return value
}

private func testAviaryTelemetryAgentSpans() async throws {
    let (outcome, spans) = try await AviaryTelemetry.withRecording {
        let home = AgentHome(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-telemetry-agent-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: telemetryAgentModel())
        let agent = Agent(
            provider: TelemetryAgentProvider(),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer,
            hostSession: "telemetry-agent-runtime",
            config: .init(
                model: telemetryAgentModel(), cwd: "/tmp", systemPrompt: "telemetry system",
                maxIterations: 1))
        let sendOutcome = await agent.send("do not record this prompt")
        _ = await agent.executeForTesting(
            id: "telemetry-tool-call", name: "unknown_tool", arguments: .object([:]))
        _ = await agent.serveCallback(
            rid: "telemetry-callback", kind: "unknown_callback", payload: .object([:]))
        try? await writer.closeChecked()
        return sendOutcome
    }

    XCTAssertEqual(outcome, .completed)
    let send = try XCTUnwrap(spans.first(where: { $0.name == "aviary.agent.send" }))
    XCTAssertTrue(spans.contains(where: { $0.name == "aviary.agent.provider" }))
    XCTAssertTrue(spans.contains(where: { $0.name == "aviary.agent.tool" }))
    XCTAssertTrue(spans.contains(where: { $0.name == "aviary.agent.callback" }))
    XCTAssertEqual(telemetryAgentAttributeString(send, key: "aviary.outcome"), "completed")
    let provider = try XCTUnwrap(spans.first(where: { $0.name == "aviary.agent.provider" }))
    XCTAssertEqual(provider.kind, .client)
    XCTAssertEqual(provider.parentSpanId?.hexString, send.spanId.hexString)
    let measurements = try XCTUnwrap(provider.events.first {
        $0.name == "aviary.agent.provider.measurements"
    })
    XCTAssertEqual(measurements.attributes["aviary.usage.state"], .string("unreported"))
    XCTAssertEqual(measurements.attributes["aviary.provider.done_observed"], .bool(true))
    XCTAssertNotNil(measurements.attributes["aviary.provider.first_output.seconds"])
    XCTAssertFalse(spans.contains(where: {
        $0.attributes.keys.contains(where: { key in
            key == "aviary.prompt" || key.contains("argument") || key.contains("result")
        })
    }))
    XCTAssertFalse(spans.contains(where: {
        $0.attributes.values.contains(where: { value in
            if case .string(let text) = value { return text.contains("do not record this prompt") }
            return false
        })
    }))
}

private func testAviaryTelemetryNativeAgentActionLink() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-native-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-native-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-native-work"),
        runID: "telemetry-native-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-native-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-native-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)

    let (outcome, spans) = try await AviaryTelemetry.withRecording {
        let agent = Agent(
            provider: TelemetryAgentProvider(),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer, hostSession: "telemetry-native-runtime",
            config: .init(model: model, cwd: "/tmp", systemPrompt: "native telemetry system"),
            nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
        let result = await agent.send("native telemetry prompt must stay private")
        _ = try await bundle.finishRun()
        try await bundle.closeChecked()
        try await writer.closeChecked()
        return result
    }

    XCTAssertEqual(outcome, .completed)
    let workRead = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "telemetry-native-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertNil(workRead.quarantinedSuffix)
    XCTAssertNil(workRead.truncatedTail)
    let events = workRead.records.map(\.event)
    let started = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let finished = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionOutcome && $0.action == started.action
    })
    let action = try XCTUnwrap(started.action)
    let provider = try XCTUnwrap(spans.first {
        $0.name == "aviary.agent.provider"
            && telemetryAgentAttributeString($0, key: "aviary.operation") == "normal"
    })
    XCTAssertEqual(
        telemetryAgentAttributeString(provider, key: "aviary.action.id"),
        AviaryTelemetry.identity(action.actionID))
    XCTAssertEqual(
        telemetryAgentAttributeString(provider, key: "aviary.action.started.id"),
        AviaryTelemetry.identity(started.eventID))
    XCTAssertEqual(
        telemetryAgentAttributeString(provider, key: "aviary.action.started.journal.id"),
        AviaryTelemetry.journalIdentity(started.journal))
    let outcomeEvent = try XCTUnwrap(provider.events.first {
        $0.name == "aviary.agent.action.outcome"
    })
    XCTAssertEqual(
        telemetryAgentEventAttributeString(outcomeEvent, key: "aviary.event.id"),
        AviaryTelemetry.identity(finished.eventID))
    XCTAssertEqual(
        telemetryAgentEventAttributeString(outcomeEvent, key: "aviary.event.journal.id"),
        AviaryTelemetry.journalIdentity(finished.journal))
    XCTAssertEqual(
        telemetryAgentEventAttributeString(outcomeEvent, key: "aviary.action.started.journal.id"),
        AviaryTelemetry.journalIdentity(started.journal))
    XCTAssertEqual(
        telemetryAgentEventAttributeString(outcomeEvent, key: "aviary.action.id"),
        AviaryTelemetry.identity(action.actionID))
    XCTAssertFalse(spans.contains {
        $0.attributes.values.contains {
            if case .string(let value) = $0 {
                return value.contains("native telemetry prompt")
            }
            return false
        }
    })
}

private func testAviaryTelemetryNativeAgentFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-native-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-failure-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-failure-work"),
        runID: "telemetry-failure-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-failure-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-failure-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)

    let (outcome, spans) = try await AviaryTelemetry.withRecording {
        let agent = Agent(
            provider: TelemetryAgentFailingProvider(),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer, hostSession: "telemetry-failure-runtime",
            config: .init(model: model, cwd: "/tmp", systemPrompt: "failure telemetry"),
            nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
        let result = await agent.send("failure prompt must stay private")
        _ = try await bundle.finishRun()
        try await bundle.closeChecked()
        try await writer.closeChecked()
        return result
    }

    guard case .failed = outcome else { XCTFail("provider failure must fail the send"); return }
    let workRead = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "telemetry-failure-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let events = workRead.records.map(\.event)
    let started = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let action = try XCTUnwrap(started.action)
    let canonicalOutcome = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionOutcome && $0.action == action
    })
    XCTAssertEqual(
        canonicalOutcome.payload["state"]?.stringValue,
        ActionExecutionState.indeterminateEffect.rawValue)
    let provider = try XCTUnwrap(spans.first {
        $0.name == "aviary.agent.provider"
            && telemetryAgentAttributeString($0, key: "aviary.operation") == "normal"
    })
    XCTAssertEqual(telemetryAgentAttributeString(provider, key: "aviary.outcome"), "indeterminate")
    XCTAssertEqual(
        telemetryAgentAttributeString(provider, key: "aviary.action.id"),
        AviaryTelemetry.identity(action.actionID))
    let outcomeEvent = try XCTUnwrap(provider.events.first {
        $0.name == "aviary.agent.action.outcome"
    })
    XCTAssertEqual(
        telemetryAgentEventAttributeString(outcomeEvent, key: "aviary.event.id"),
        AviaryTelemetry.identity(canonicalOutcome.eventID))
    XCTAssertEqual(
        telemetryAgentEventAttributeString(outcomeEvent, key: "aviary.outcome"),
        "indeterminate")
    XCTAssertFalse(spans.contains {
        $0.attributes.values.contains {
            if case .string(let value) = $0 { return value.contains("failure prompt") }
            return false
        }
    })
}

private func testAviaryTelemetryAgentSwitchesModelMidstream() async throws {
    let oldModel = telemetryAgentPricedModel(
        id: "dispatch-model", provider: "dispatch-provider", inputRate: 11, outputRate: 22)
    let newModel = telemetryAgentPricedModel(
        id: "next-model", provider: "next-provider", inputRate: 101, outputRate: 202)
    let gate = TelemetryHeldProviderGate()
    let oldUsage = telemetryAgentUsage(input: 100, output: 10)
    let newUsage = telemetryAgentUsage(input: 200, output: 20)

    let (outcomes, spans) = try await AviaryTelemetry.withRecording {
        let home = AgentHome(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("aviary-telemetry-switch-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: home.root) }
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: oldModel)
        let agent = Agent(
            provider: TelemetryHeldProvider(gate: gate, usage: oldUsage),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer,
            hostSession: "telemetry-switch-runtime",
            config: .init(
                model: oldModel, cwd: "/tmp", systemPrompt: "switch system",
                maxIterations: 1))

        let first = Task { await agent.send("held dispatch prompt") }
        XCTAssertTrue(await gate.waitUntilStarted(), "held provider did not enter its stream")
        XCTAssertTrue(await agent.switchModel(
            to: newModel, provider: TelemetryReplacementProvider(usage: newUsage)))
        await gate.release()
        let firstOutcome = await first.value
        let secondOutcome = await agent.send("new dispatch prompt")
        try? await writer.closeChecked()
        return (firstOutcome, secondOutcome)
    }

    XCTAssertEqual(outcomes.0, .completed)
    XCTAssertEqual(outcomes.1, .completed)
    let providerSpans = spans.filter { $0.name == "aviary.agent.provider" }
    XCTAssertEqual(providerSpans.count, 2)
    let oldProvider = try XCTUnwrap(providerSpans.first {
        telemetryAgentAttributeString($0, key: "aviary.model.id_hash")
            == AviaryTelemetry.identity(oldModel.id)
    })
    let newProvider = try XCTUnwrap(providerSpans.first {
        telemetryAgentAttributeString($0, key: "aviary.model.id_hash")
            == AviaryTelemetry.identity(newModel.id)
    })

    for (span, accounting, inputRate, outputRate, input, output) in [
        (oldProvider, "cache_exclusive", 11.0, 22.0, 100, 10),
        (newProvider, "cache_exclusive", 101.0, 202.0, 200, 20),
    ] {
        let measurements = try XCTUnwrap(span.events.first {
            $0.name == "aviary.agent.provider.measurements"
        })
        XCTAssertEqual(measurements.attributes["aviary.usage.input_accounting"],
            .string(accounting))
        XCTAssertEqual(measurements.attributes["aviary.usage.input_tokens"], .int(input))
        XCTAssertEqual(measurements.attributes["aviary.usage.output_tokens"], .int(output))
        let price = try XCTUnwrap(span.events.first { $0.name == "aviary.agent.provider.price" })
        XCTAssertEqual(price.attributes["aviary.pricing.input_per_million_usd"],
            .double(inputRate))
        XCTAssertEqual(price.attributes["aviary.pricing.output_per_million_usd"],
            .double(outputRate))
    }
}

private func testAviaryTelemetryNativeCompletedProviderOutcomeFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-native-completed-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-completed-failure-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-completed-failure-work"),
        runID: "telemetry-completed-failure-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-completed-failure-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-completed-failure-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    let calls = TelemetryProviderCallCounter()

    let (outcome, spans) = await AviaryTelemetry.withRecording {
        let agent = Agent(
            provider: TelemetryAgentCompletingWriterFailureProvider(bundle: bundle, calls: calls),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer, hostSession: "telemetry-completed-failure-runtime",
            config: .init(model: model, cwd: "/tmp", systemPrompt: "completed failure"),
            nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
        let result = await agent.send("completed provider must not be replayed")
        _ = try? await bundle.finishRun()
        try? await bundle.closeChecked()
        try? await writer.closeChecked()
        return result
    }

    guard case .failed = outcome else {
        XCTFail("an unrecordable native outcome must fail the send")
        return
    }
    XCTAssertEqual(await calls.value(), 1)
    let workRead = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "telemetry-completed-failure-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let events = workRead.records.map(\.event)
    let started = try XCTUnwrap(events.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let action = try XCTUnwrap(started.action)
    XCTAssertTrue(events.filter { $0.type == TimelineEventType.actionOutcome && $0.action == action }
        .isEmpty)
    let provider = try XCTUnwrap(spans.first {
        $0.name == "aviary.agent.provider"
            && telemetryAgentAttributeString($0, key: "aviary.operation") == "normal"
    })
    XCTAssertEqual(telemetryAgentAttributeString(provider, key: "aviary.outcome"), "indeterminate")
    XCTAssertEqual(
        telemetryAgentAttributeString(provider, key: "aviary.action.id"),
        AviaryTelemetry.identity(action.actionID))
    XCTAssertFalse(spans.contains {
        $0.attributes.values.contains {
            if case .string(let value) = $0 { return value.contains("completed provider body") }
            return false
        }
    })
}

private func testAviaryTelemetryActualPythonOutcomeWriteFailure() async throws {
    guard let repoRoot = EngineLocator.repoRoot(),
          let host = RuntimeHost.bundledPython(repoRoot: repoRoot, parentLifetimeLease: true)
    else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-python-outcome-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-python-outcome-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-python-outcome-work"),
        runID: "telemetry-python-outcome-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-python-outcome-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-python-outcome-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    _ = try await host.start()
    let hostSession = try await host.createSession(id: identity.sessionID, cwd: "/tmp")
    let agent = Agent(
        provider: TelemetryAgentProvider(), host: host, writer: writer,
        hostSession: hostSession,
        config: .init(model: model, cwd: "/tmp", systemPrompt: "python outcome failure"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    await host.onCallback { _, _, kind, payload in
        // This callback runs after the Python action has started and before its terminal receipt.
        // The next Work append therefore tests an actual Python success with uncertain recording.
        await bundle.injectWriterFailure(.beforeWrite, in: .work)
        return await agent.serveCallback(rid: "python-outcome-callback", kind: kind, payload: payload)
    }

    let (result, spans) = await AviaryTelemetry.withRecording {
        let result = await agent.executeForTesting(
            id: "python-outcome-call", name: "python",
            arguments: .object(["code": .string("ask_app('trace_probe', marker='PRIVATE_TELEMETRY_PAYLOAD')\n41")]))
        _ = try? await bundle.finishRun()
        try? await bundle.closeChecked()
        try? await writer.closeChecked()
        await host.stop()
        return result
    }
    XCTAssertTrue(result.1, "uncertain native outcome must be surfaced as a tool error")
    let tool = try XCTUnwrap(spans.first { $0.name == "aviary.agent.tool" })
    XCTAssertEqual(tool.attributes["aviary.outcome"], .string("indeterminate"))
    XCTAssertEqual(spans.filter { $0.name == "aviary.agent.action.dispatch" }.count, 1)
    XCTAssertFalse(spans.flatMap(\.events).contains { $0.name == "aviary.agent.action.outcome" })
    let executions = spans.filter { $0.name == "aviary.runtime.execute" }
    XCTAssertEqual(executions.count, 1)
    XCTAssertEqual(executions.first?.attributes["aviary.outcome"], .string("completed"))
    XCTAssertFalse(spans.contains { span in
        span.attributes.values.contains {
            if case .string(let value) = $0 { return value.contains("ask_app") || value.contains("PRIVATE_TELEMETRY_PAYLOAD") }
            return false
        }
    })
}

private func testAviaryTelemetryCallbackActionOutcomeWriteFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-callback-outcome-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-callback-outcome-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-callback-outcome-work"),
        runID: "telemetry-callback-outcome-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-callback-outcome-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-callback-outcome-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    let agent = Agent(
        provider: TelemetryAgentProvider(), host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: identity.sessionID,
        config: .init(model: model, cwd: "/tmp", systemPrompt: "callback outcome failure"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    await agent.setPeerDelegate(TelemetryAgentPeerOutcomeFailure(bundle: bundle))

    let (reply, spans) = await AviaryTelemetry.withRecording {
        let reply = await agent.serveCallback(
            rid: "callback-outcome", kind: "message",
            payload: .object(["to": .string("peer"), "text": .string("hello")]))
        _ = try? await bundle.finishRun()
        try? await bundle.closeChecked()
        try? await writer.closeChecked()
        return reply
    }
    XCTAssertNotNil(reply["error"])
    let callback = try XCTUnwrap(spans.first { $0.name == "aviary.agent.callback" })
    XCTAssertEqual(callback.attributes["aviary.outcome"], .string("indeterminate"))
    XCTAssertFalse(spans.flatMap(\.events).contains { $0.name == "aviary.agent.action.outcome" })
    let events = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)), journal: bundle.workJournal,
        actor: TimelineActor(actorID: "telemetry-callback-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertEqual(events.filter { $0.type == TimelineEventType.actionStarted }.count, 1)
    XCTAssertTrue(events.filter { $0.type == TimelineEventType.actionOutcome }.isEmpty)
}

private func testAviaryTelemetryNativePreflightAdmissionRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-admission-rejected-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-admission-rejected-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-admission-rejected-work"),
        runID: "telemetry-admission-rejected-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-admission-rejected-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-admission-rejected-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    _ = try await bundle.finishRun()

    let (result, spans) = await AviaryTelemetry.withRecording {
        let agent = Agent(
            provider: TelemetryAgentProvider(),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer, hostSession: identity.sessionID,
            config: .init(model: model, cwd: "/tmp", systemPrompt: "admission rejection"),
            nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
        let result = await agent.executeForTesting(
            id: "preflight-rejected-call", name: "python",
            arguments: .object(["code": .string("41")]))
        try? await bundle.closeChecked()
        try? await writer.closeChecked()
        return result
    }

    XCTAssertTrue(result.1)
    let dispatch = try XCTUnwrap(spans.first { $0.name == "aviary.agent.action.dispatch" })
    XCTAssertEqual(dispatch.attributes["aviary.outcome"], .string("rejected"))
    let tool = try XCTUnwrap(spans.first { $0.name == "aviary.agent.tool" })
    XCTAssertEqual(tool.attributes["aviary.outcome"], .string("rejected"))
}

private func testAviaryTelemetryNativePartialAdmissionIndeterminate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-admission-partial-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-admission-partial-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-admission-partial-work"),
        runID: "telemetry-admission-partial-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-admission-partial-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-admission-partial-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    await bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)

    let (result, spans) = await AviaryTelemetry.withRecording {
        let agent = Agent(
            provider: TelemetryAgentProvider(),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer, hostSession: identity.sessionID,
            config: .init(model: model, cwd: "/tmp", systemPrompt: "partial admission"),
            nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
        let result = await agent.executeForTesting(
            id: "partial-admission-call", name: "python",
            arguments: .object(["code": .string("41")]))
        try? await bundle.closeChecked()
        try? await writer.closeChecked()
        return result
    }

    XCTAssertTrue(result.1)
    let dispatch = try XCTUnwrap(spans.first { $0.name == "aviary.agent.action.dispatch" })
    XCTAssertEqual(dispatch.attributes["aviary.outcome"], .string("indeterminate"))
    let tool = try XCTUnwrap(spans.first { $0.name == "aviary.agent.tool" })
    XCTAssertEqual(tool.attributes["aviary.outcome"], .string("indeterminate"))
    XCTAssertFalse(spans.flatMap(\.events).contains { $0.name == "aviary.agent.action.outcome" })
    let events = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)), journal: bundle.workJournal,
        actor: TimelineActor(actorID: "telemetry-admission-partial-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertTrue(events.contains { $0.type == TimelineEventType.actionIntent })
    XCTAssertTrue(events.filter { $0.type == TimelineEventType.actionStarted }.isEmpty)
}

private func testAviaryTelemetryNativeProviderWithoutTerminalDone() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-provider-quiet-eof-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-provider-quiet-eof-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-provider-quiet-eof-work"),
        runID: "telemetry-provider-quiet-eof-run")
    let model = telemetryAgentModel()
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-provider-quiet-eof-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-provider-quiet-eof-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    let log = EventLog()

    let (outcome, spans) = await AviaryTelemetry.withRecording {
        let agent = Agent(
            provider: TelemetryAgentQuietEOFProvider(),
            host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
            writer: writer, hostSession: "telemetry-provider-quiet-eof-runtime",
            config: .init(model: model, cwd: "/tmp", systemPrompt: "quiet EOF"),
            nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
        await agent.observe { log.record($0) }
        let result = await agent.send("quiet EOF must not become an assistant turn")
        _ = try? await bundle.finishRun()
        try? await bundle.closeChecked()
        try? await writer.closeChecked()
        return result
    }

    guard case .failed = outcome else {
        XCTFail("provider EOF without done must fail the send")
        return
    }
    XCTAssertFalse(log.names.contains { $0.hasPrefix("tool:") },
                   "an unterminated provider turn must not execute its tool call")
    let provider = try XCTUnwrap(spans.first {
        $0.name == "aviary.agent.provider"
            && telemetryAgentAttributeString($0, key: "aviary.operation") == "normal"
    })
    XCTAssertEqual(telemetryAgentAttributeString(provider, key: "aviary.outcome"), "indeterminate")
    XCTAssertEqual(
        provider.events.first(where: { $0.name == "aviary.agent.provider.measurements" })?
            .attributes["aviary.provider.done_observed"], .bool(false))

    let workEvents = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "telemetry-provider-quiet-eof-work-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    let started = try XCTUnwrap(workEvents.first {
        $0.type == TimelineEventType.actionStarted
            && $0.payload["kind"]?.stringValue == ActionKind.provider.rawValue
    })
    let action = try XCTUnwrap(started.action)
    let terminal = try XCTUnwrap(workEvents.first {
        $0.type == TimelineEventType.actionOutcome && $0.action == action
    })
    XCTAssertEqual(
        terminal.payload["state"]?.stringValue,
        ActionExecutionState.indeterminateEffect.rawValue)
    XCTAssertFalse(workEvents.contains {
        $0.type == TimelineEventType.actionOutcome
            && $0.action == action
            && $0.payload["state"]?.stringValue == ActionExecutionState.succeeded.rawValue
    })

    let sessionEvents = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(bundle.session)),
        journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "telemetry-provider-quiet-eof-session-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertFalse(sessionEvents.contains {
        $0.type == TimelineEventType.messageCommitted
            && $0.payload["role"]?.stringValue == ChatRole.assistant.rawValue
    }, "an unterminated provider turn must not commit an assistant message")
}
