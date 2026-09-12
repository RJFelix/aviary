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

private struct TelemetryAgentFailingProvider: ChatProvider {
    let id = "telemetry-agent-failing-provider"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("partial response"))
            continuation.finish(throwing: TelemetryAgentProviderFailure())
        }
    }
}

private func telemetryAgentModel() -> ModelSpec {
    var model = ModelSpec(rpc: .object(["id": .string("test-model"), "provider": .string("fake")]))
    model.contextWindow = 100_000
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
    let outcomeEvent = try XCTUnwrap(provider.events.first {
        $0.name == "aviary.agent.action.outcome"
    })
    XCTAssertEqual(
        telemetryAgentEventAttributeString(outcomeEvent, key: "aviary.event.id"),
        AviaryTelemetry.identity(finished.eventID))
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
    XCTAssertFalse(spans.contains {
        $0.attributes.values.contains {
            if case .string(let value) = $0 { return value.contains("failure prompt") }
            return false
        }
    })
}
