import Foundation
import OpenTelemetrySdk
@testable import AviaryCore

let casesAviaryTelemetryContext: [Case] = [
    ("telemetry context preparation preserves partial native uncertainty", {
        try await testAviaryTelemetryContextPreparationPartialFailure()
    }),
    ("telemetry compaction records bounded canonical commit metadata", {
        try await testAviaryTelemetryCompactionSuccess()
    }),
    ("telemetry compaction failure has no fabricated commit", {
        try await testAviaryTelemetryCompactionFailure()
    }),
    ("telemetry compaction no-op emits no scope", {
        try await testAviaryTelemetryCompactionNoOp()
    }),
    ("telemetry canonical compaction survives legacy projection failure", {
        try await testAviaryTelemetryCanonicalCompactionLegacyFailure()
    }),
]

private actor ContextTelemetryCallCounter {
    private var calls = 0

    func increment() { calls += 1 }
    func value() -> Int { calls }
}

private struct ContextTelemetryProvider: ChatProvider {
    let counter: ContextTelemetryCallCounter
    let id = "telemetry-context-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await counter.increment()
                continuation.yield(.textDelta("context provider must not be called"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private struct ContextTelemetryFailurePeer: Agent.PeerDelegate {
    let bundle: RunJournalBundle

    func peers(excluding sessionID: String) async -> [Agent.Peer] {
        await bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
        return []
    }

    func deliver(to peer: String, text: String, from sessionID: String) async
        -> (session: String, error: String?)
    {
        (peer, nil)
    }
}

private struct TelemetryCompactionFailure: Error {}

private actor TelemetryCompactionProviderState {
    private var calls = 0

    func next() -> Int {
        calls += 1
        return calls
    }

    func value() -> Int { calls }
}

private struct TelemetryCompactionProvider: ChatProvider {
    let state: TelemetryCompactionProviderState
    let failCompaction: Bool
    let legacyProjectionFailureWriter: SessionWriter?
    let id = "telemetry-compaction-provider"

    init(
        state: TelemetryCompactionProviderState,
        failCompaction: Bool,
        legacyProjectionFailureWriter: SessionWriter? = nil
    ) {
        self.state = state
        self.failCompaction = failCompaction
        self.legacyProjectionFailureWriter = legacyProjectionFailureWriter
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let call = await state.next()
                if call == 5, failCompaction {
                    continuation.finish(throwing: TelemetryCompactionFailure())
                    return
                }
                if call == 5, let writer = legacyProjectionFailureWriter {
                    await writer.injectFailure(.beforeWrite)
                }
                continuation.yield(.usage(telemetryContextUsage(input: call <= 4 ? 900 : 50)))
                if call <= 4 {
                    continuation.yield(.toolCall(
                        id: "unknown-\(call)", name: "unknown_tool",
                        arguments: .object([:])))
                    continuation.yield(.done(stopReason: "tool_use"))
                } else {
                    continuation.yield(.textDelta(
                        call == 5 ? "COMPACTION_SUMMARY_SENTINEL" : "done"))
                    continuation.yield(.done(stopReason: "stop"))
                }
                continuation.finish()
            }
        }
    }
}

private func telemetryContextUsage(input: Int) -> Usage {
    var usage = Usage()
    usage.input = input
    usage.totalTokens = input
    return usage
}

private func telemetryContextModel() -> ModelSpec {
    var model = ModelSpec(rpc: .object(["id": .string("test-model"), "provider": .string("fake")]))
    model.contextWindow = 100_000
    return model
}

private func telemetryContextNativeFixture(
    suffix: String, model: ModelSpec
) async throws -> (AgentHome, SessionWorkIdentity, RunJournalBundle, SessionWriter) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-context-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-context-\(suffix)-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-context-\(suffix)-work"),
        runID: "telemetry-context-\(suffix)-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-context-\(suffix)-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-context-\(suffix)-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    return (home, identity, bundle, writer)
}

private func testAviaryTelemetryContextPreparationPartialFailure() async throws {
    let model = telemetryContextModel()
    let (home, identity, bundle, writer) = try await telemetryContextNativeFixture(
        suffix: "partial", model: model)
    defer { try? FileManager.default.removeItem(at: home.root) }
    let calls = ContextTelemetryCallCounter()
    let agent = Agent(
        provider: ContextTelemetryProvider(counter: calls),
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: identity.sessionID,
        config: .init(model: model, cwd: "/tmp", systemPrompt: "context partial"),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))
    await agent.setPeerDelegate(ContextTelemetryFailurePeer(bundle: bundle))

    let (outcome, spans) = await AviaryTelemetry.withRecording {
        let outcome = await agent.send("context crossing must not reach provider")
        try? await bundle.closeChecked()
        try? await writer.closeChecked()
        return outcome
    }

    guard case .failed = outcome else {
        XCTFail("partial context admission must fail the send")
        return
    }
    XCTAssertEqual(await calls.value(), 0)
    let context = try XCTUnwrap(spans.first { $0.name == "aviary.agent.context.prepare" })
    XCTAssertEqual(context.attributes["aviary.outcome"], .string("indeterminate"))
    let send = try XCTUnwrap(spans.first { $0.name == "aviary.agent.send" })
    XCTAssertEqual(send.attributes["aviary.outcome"], .string("indeterminate"))
    let sessionData = try Data(contentsOf: home.timelineV2SessionJournalURL(bundle.session))
    let sessionEvents = TimelineJournalReader.read(
        sessionData, journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "context-telemetry-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertTrue(sessionEvents.contains { $0.type == TimelineEventType.contextAssembled })
    XCTAssertFalse(spans.flatMap(\.events).contains { $0.name == "aviary.agent.context.prepared" })
}

private func testAviaryTelemetryCompactionSuccess() async throws {
    var model = telemetryContextModel()
    model.contextWindow = 1_000
    let (home, identity, bundle, writer) = try await telemetryContextNativeFixture(
        suffix: "success", model: model)
    defer { try? FileManager.default.removeItem(at: home.root) }
    let provider = TelemetryCompactionProvider(
        state: TelemetryCompactionProviderState(), failCompaction: false)
    let agent = Agent(
        provider: provider,
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: identity.sessionID,
        config: .init(model: model, cwd: "/tmp", systemPrompt: "compaction telemetry",
                      maxIterations: 12),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))

    let (outcome, spans) = await AviaryTelemetry.withRecording {
        let outcome = await agent.send("grow context")
        try? await writer.closeChecked()
        return outcome
    }
    _ = try? await bundle.finishRun()
    try? await bundle.closeChecked()

    guard case .completed = outcome else {
        XCTFail("bounded compaction fixture should complete")
        return
    }
    let compaction = try XCTUnwrap(spans.first { $0.name == "aviary.agent.compaction" })
    let committed = try XCTUnwrap(compaction.events.first {
        $0.name == "aviary.agent.compaction.committed"
    })
    XCTAssertNotNil(committed.attributes["aviary.event.id"])
    XCTAssertNotNil(committed.attributes["aviary.event.journal.id"])
    XCTAssertNotNil(committed.attributes["aviary.event.sequence"])
    XCTAssertEqual(committed.attributes["aviary.receipt.state"], .string("succeeded"))
    XCTAssertEqual(committed.attributes["aviary.compaction.dropped_messages"], .int(4))
    XCTAssertFalse(committed.attributes.keys.contains { $0.contains("summary") && $0 != "aviary.compaction.summary_bytes" })
    XCTAssertFalse(committed.attributes.keys.contains { $0.contains("path") })

    let sessionData = try Data(contentsOf: home.timelineV2SessionJournalURL(bundle.session))
    let sessionEvents = TimelineJournalReader.read(
        sessionData, journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "context-success-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    let compactionEvent = try XCTUnwrap(sessionEvents.first {
        $0.type == TimelineEventType.compaction
    })
    XCTAssertEqual(
        sessionEvents.filter { $0.type == TimelineEventType.compaction }.count, 1)
    XCTAssertEqual(
        committed.attributes["aviary.event.id"],
        .string(AviaryTelemetry.identity(compactionEvent.eventID)))
    XCTAssertEqual(
        committed.attributes["aviary.event.journal.id"],
        .string(AviaryTelemetry.journalIdentity(compactionEvent.journal)))
    XCTAssertEqual(
        committed.attributes["aviary.event.sequence"], .int(compactionEvent.sequence))
}

private func testAviaryTelemetryCompactionFailure() async throws {
    var model = telemetryContextModel()
    model.contextWindow = 1_000
    let (home, identity, bundle, writer) = try await telemetryContextNativeFixture(
        suffix: "failure", model: model)
    defer { try? FileManager.default.removeItem(at: home.root) }
    let provider = TelemetryCompactionProvider(
        state: TelemetryCompactionProviderState(), failCompaction: true)
    let agent = Agent(
        provider: provider,
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: identity.sessionID,
        config: .init(model: model, cwd: "/tmp", systemPrompt: "compaction failure",
                      maxIterations: 12),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))

    let (outcome, spans) = await AviaryTelemetry.withRecording {
        let outcome = await agent.send("grow context then fail compaction")
        try? await writer.closeChecked()
        return outcome
    }
    _ = try? await bundle.finishRun()
    try? await bundle.closeChecked()

    guard case .completed = outcome else {
        XCTFail("a compaction provider failure should not end the run")
        return
    }
    let compaction = try XCTUnwrap(spans.first { $0.name == "aviary.agent.compaction" })
    XCTAssertEqual(compaction.attributes["aviary.outcome"], .string("failed"))
    XCTAssertTrue(compaction.events.filter {
        $0.name == "aviary.agent.compaction.committed"
    }.isEmpty)
}

private struct TelemetryCompactionNoOpProvider: ChatProvider {
    let id = "telemetry-compaction-noop-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.usage(telemetryContextUsage(input: 1)))
            continuation.yield(.textDelta("no compaction"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private func testAviaryTelemetryCompactionNoOp() async throws {
    var model = telemetryContextModel()
    model.contextWindow = 1_000
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-context-noop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionWriter(home: AgentHome(root: root), cwd: "/tmp", model: model)
    let agent = Agent(
        provider: TelemetryCompactionNoOpProvider(),
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: "context-noop-runtime",
        config: .init(model: model, cwd: "/tmp", systemPrompt: "no compaction", maxIterations: 1))
    let (outcome, spans) = await AviaryTelemetry.withRecording {
        let outcome = await agent.send("small context")
        try? await writer.closeChecked()
        return outcome
    }
    XCTAssertEqual(outcome, .completed)
    XCTAssertTrue(spans.filter { $0.name == "aviary.agent.compaction" }.isEmpty)
}

private func testAviaryTelemetryCanonicalCompactionLegacyFailure() async throws {
    var model = telemetryContextModel()
    model.contextWindow = 1_000
    let (home, identity, bundle, writer) = try await telemetryContextNativeFixture(
        suffix: "legacy-failure", model: model)
    defer { try? FileManager.default.removeItem(at: home.root) }
    let state = TelemetryCompactionProviderState()
    let provider = TelemetryCompactionProvider(
        state: state, failCompaction: false, legacyProjectionFailureWriter: writer)
    let agent = Agent(
        provider: provider,
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: identity.sessionID,
        config: .init(model: model, cwd: "/tmp", systemPrompt: "SYSTEM_TELEMETRY_SENTINEL",
                      maxIterations: 12),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))

    let (outcome, spans) = await AviaryTelemetry.withRecording {
        let outcome = await agent.send("USER_TELEMETRY_SENTINEL")
        try? await writer.closeChecked()
        return outcome
    }
    _ = try? await bundle.finishRun()
    try? await bundle.closeChecked()

    guard case .failed = outcome else {
        XCTFail("a failed legacy projection must fail the send")
        return
    }
    let compaction = try XCTUnwrap(spans.first { $0.name == "aviary.agent.compaction" })
    XCTAssertEqual(compaction.attributes["aviary.outcome"], .string("indeterminate"))
    let send = try XCTUnwrap(spans.first { $0.name == "aviary.agent.send" })
    XCTAssertEqual(send.attributes["aviary.outcome"], .string("indeterminate"))
    XCTAssertEqual(compaction.events.filter {
        $0.name == "aviary.agent.compaction.committed"
    }.count, 1)

    let workEvents = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "context-legacy-failure-work-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    XCTAssertEqual(await state.value(), 5)
    XCTAssertEqual(workEvents.filter {
        $0.type == TimelineEventType.actionIntent
            && $0.payload["kind"]?.stringValue == ActionKind.compactionProvider.rawValue
    }.count, 1)

    let sessionEvents = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(bundle.session)),
        journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "context-legacy-failure-session-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    let compactionEvent = try XCTUnwrap(sessionEvents.first {
        $0.type == TimelineEventType.compaction
    })
    XCTAssertEqual(sessionEvents.filter { $0.type == TimelineEventType.compaction }.count, 1)
    let committed = try XCTUnwrap(compaction.events.first {
        $0.name == "aviary.agent.compaction.committed"
    })
    XCTAssertEqual(
        committed.attributes["aviary.event.id"],
        .string(AviaryTelemetry.identity(compactionEvent.eventID)))
    XCTAssertEqual(
        committed.attributes["aviary.event.journal.id"],
        .string(AviaryTelemetry.journalIdentity(compactionEvent.journal)))
    XCTAssertEqual(
        committed.attributes["aviary.event.sequence"], .int(compactionEvent.sequence))
    XCTAssertEqual(compactionEvent.payload["summary"], .string("COMPACTION_SUMMARY_SENTINEL"))

    let traceValues = spans.flatMap { span in
        Array(span.attributes.values) + span.events.flatMap { $0.attributes.values }
    }
    XCTAssertFalse(traceValues.contains { value in
        guard case .string(let text) = value else { return false }
        return text.contains("SYSTEM_TELEMETRY_SENTINEL")
            || text.contains("USER_TELEMETRY_SENTINEL")
            || text.contains("COMPACTION_SUMMARY_SENTINEL")
    })
    let serializedSpans = spans.map { String(describing: $0) }.joined(separator: "\n")
    XCTAssertFalse(serializedSpans.contains("SYSTEM_TELEMETRY_SENTINEL"))
    XCTAssertFalse(serializedSpans.contains("USER_TELEMETRY_SENTINEL"))
    XCTAssertFalse(serializedSpans.contains("COMPACTION_SUMMARY_SENTINEL"))
}
