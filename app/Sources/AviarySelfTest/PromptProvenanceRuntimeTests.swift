import Foundation
@testable import AviaryCore

private actor PromptRuntimeRequestRecorder {
    private(set) var requests: [ChatRequest] = []
    func append(_ request: ChatRequest) { requests.append(request) }
}

private struct PromptRuntimeRecordingProvider: ChatProvider {
    let recorder: PromptRuntimeRequestRecorder
    var id: String { "prompt-runtime-recording" }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.append(request)
                continuation.yield(.textDelta("done"))
                continuation.yield(.done(stopReason: "stop"))
                continuation.finish()
            }
        }
    }
}

private func promptRuntimeModel() -> ModelSpec {
    ModelSpec(rpc: .object([
        "id": .string("model"), "name": .string("Model"),
        "provider": .string("provider"), "context_window": .number(100_000),
    ]))
}

func test_promptProvenanceRuntimePreservesProviderBytesAndGeneratedGoalSource() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-prompt-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-runtime-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-runtime-work")
    let run = RunRef("prompt-runtime-run")
    let identity = SessionWorkIdentity(
        sessionID: session.sessionID, work: work, runID: run.runID)
    let model = promptRuntimeModel()
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-runtime-service"),
        sessionAttachment: SessionAttachmentRef("prompt-runtime-attachment"), run: run,
        actor: TimelineActor(actorID: "prompt-runtime-test", kind: "self-test"),
        modelID: model.qualifiedID)
    let writer = try SessionWriter(
        home: home, cwd: root.path, model: model, identity: identity)
    let assembly = try SystemPromptAssembly.build(
        cwd: root.path, memory: "producer-side marker <available_skills>",
        includeContextFiles: false)
    let goal = Goal(
        text: "Prove prompt provenance", tokenBudget: 4_000,
        startedAt: Date(timeIntervalSince1970: 1))
    let recorder = PromptRuntimeRequestRecorder()
    let agent = Agent(
        provider: PromptRuntimeRecordingProvider(recorder: recorder),
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: "unused-prompt-runtime",
        config: .init(
            model: model, cwd: root.path, systemPrompt: assembly.flattenedText,
            systemPromptAssembly: assembly, maxIterations: 1, goal: goal),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))

    XCTAssertEqual(await agent.send("hello"), .completed)
    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 1)
    let request = try XCTUnwrap(requests.first)
    let expectedBriefing = goal.briefing(spent: 0)
    let expectedSystem = assembly.flattenedText + "\n\n" + expectedBriefing
    let expectedGoalSource = try PromptSource(
        sourceID: "generated:goal-briefing:v1", kind: .generated,
        label: "Goal briefing", identity: "generated:goal-briefing:v1",
        fullBody: expectedBriefing, deliveredBody: expectedBriefing,
        renderedBody: "\n\n" + expectedBriefing,
        deliveredByteOffsetInRendered: 2,
        renderedByteOffset: assembly.flattenedByteCount)
    let expectedAssembly = try SystemPromptAssembly(
        text: expectedSystem, sources: assembly.sources + [expectedGoalSource])
    XCTAssertEqual(request.messages.first?.plainText, expectedSystem)

    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2SessionJournalURL(session)),
        journal: bundle.sessionJournal,
        actor: TimelineActor(actorID: "prompt-runtime-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1))
    let snapshot = SessionReducer.reduce(read.records.map(\.event))
    XCTAssertTrue(snapshot.semanticProjectionValid)
    let manifest = try XCTUnwrap(snapshot.contextManifest)
    let sources = try XCTUnwrap(manifest.systemPromptSources)
    XCTAssertEqual(sources.last?.sourceID, "generated:goal-briefing:v1")
    XCTAssertEqual(sources.last?.kind, .generated)
    XCTAssertEqual(sources.last?.status, .present)
    XCTAssertEqual(sources.reduce(0) { $0 + $1.renderedByteCount }, Data(expectedSystem.utf8).count)
    XCTAssertEqual(manifest.systemPromptAssemblyID, expectedAssembly.digest)
    let renderedText = try sources.map { source -> String in
        guard let reference = source.renderedBodyReference else {
            XCTAssertEqual(source.renderedByteCount, 0)
            return ""
        }
        return try XCTUnwrap(String(
            data: ContextBodyStore(home: home).read(reference), encoding: .utf8))
    }.joined()
    XCTAssertEqual(renderedText, expectedSystem)

    _ = try await bundle.finishRun()
    try await bundle.closeChecked()
    try await writer.closeChecked()
}

func test_promptProvenanceRuntimeMismatchPreventsProviderEffect() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-prompt-runtime-mismatch-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let session = SessionRef("prompt-runtime-mismatch-session")
    let work = WorkRef(workHostID: hostID, workID: "prompt-runtime-mismatch-work")
    let run = RunRef("prompt-runtime-mismatch-run")
    let identity = SessionWorkIdentity(
        sessionID: session.sessionID, work: work, runID: run.runID)
    let model = promptRuntimeModel()
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: WorkHostRef(hostID),
        sessionAuthority: TimelineAuthorityRef("prompt-runtime-service"),
        sessionAttachment: SessionAttachmentRef("prompt-runtime-attachment"), run: run,
        actor: TimelineActor(actorID: "prompt-runtime-test", kind: "self-test"),
        modelID: model.qualifiedID)
    let writer = try SessionWriter(
        home: home, cwd: root.path, model: model, identity: identity)
    let assembly = try SystemPromptAssembly.build(cwd: root.path, includeContextFiles: false)
    let recorder = PromptRuntimeRequestRecorder()
    let agent = Agent(
        provider: PromptRuntimeRecordingProvider(recorder: recorder),
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: "unused-prompt-runtime",
        config: .init(
            model: model, cwd: root.path, systemPrompt: assembly.flattenedText + " mismatch",
            systemPromptAssembly: assembly, maxIterations: 1),
        nativeJournal: bundle, contextBodyStore: ContextBodyStore(home: home))

    if case .failed = await agent.send("hello") { } else {
        XCTFail("a mismatched source assembly must fail the run")
    }
    XCTAssertEqual(await recorder.requests.count, 0)
    _ = try await bundle.finishRun(outcome: .failed, detail: "expected prompt mismatch")
    try await writer.closeChecked()
    try await bundle.closeChecked()
}
