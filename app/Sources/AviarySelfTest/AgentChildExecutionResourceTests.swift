import Foundation

@testable import AviaryCore

private actor ChildExecutionGate {
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?

    func install(_ continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    var isInstalled: Bool { continuation != nil }

    func release(answer: String = "child answer") {
        continuation?.yield(.textDelta(answer))
        continuation?.yield(.done(stopReason: "stop"))
        continuation?.finish()
        continuation = nil
    }
}

private struct GatedChildProvider: ChatProvider, @unchecked Sendable {
    let id = "agent-child-gated"
    let gate: ChildExecutionGate

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await gate.install(continuation) }
        }
    }
}

private struct ImmediateChildProvider: ChatProvider {
    let id = "agent-child-immediate"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("immediate child answer"))
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private final class NestedSpawnProvider: ChatProvider, @unchecked Sendable {
    let id = "agent-child-nested"
    private let lock = NSLock()
    private var calls = 0

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let call: Int = lock.withLock {
            calls += 1
            return calls
        }
        return AsyncThrowingStream { continuation in
            if call == 1 {
                continuation.yield(.toolCall(
                    id: "nested-call",
                    name: "python",
                    arguments: .object(["code": .string("spawn('nested').result()")])))
            } else {
                continuation.yield(.textDelta("nested refusal was handled"))
            }
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private func childExecutionBinding(_ suffix: String) -> WorkRunBinding {
    let workHost = WorkHostRef("child-resource-host")
    let work = WorkRef(workHostID: workHost.workHostID, workID: "parent-work-\(suffix)")
    let binding = WorkBinding(
        session: SessionRef("parent-session-\(suffix)"),
        work: work,
        workHost: workHost,
        sessionAttachment: SessionAttachmentRef("parent-attachment-\(suffix)"))
    return WorkRunBinding(workBinding: binding, run: RunRef("parent-run-\(suffix)"))
}

private func childExecutionHostFactory() -> (@Sendable () -> RuntimeHost)? {
    guard let root = EngineLocator.repoRoot(),
          FileManager.default.fileExists(
            atPath: root.appending(path: "runtime-hosts/python3/host.py").path)
    else { return nil }
    return {
        RuntimeHost.bundledPython(repoRoot: root, parentLifetimeLease: true)!
    }
}

private func childExecutionConfiguration(
    home: AgentHome,
    suffix: String,
    provider: any ChatProvider,
    makeHost: @escaping @Sendable () -> RuntimeHost,
    deadline: Date? = Date().addingTimeInterval(30),
    maxIterations: Int? = 3
) -> AgentChildExecutionConfiguration {
    AgentChildExecutionConfiguration(
        origin: childExecutionBinding(suffix),
        childID: "child-\(suffix)",
        deadline: deadline,
        home: home,
        cwd: "/tmp",
        model: fakeModel(),
        provider: provider,
        systemPrompt: "You are a focused child agent.",
        maxIterations: maxIterations,
        makeRuntimeHost: makeHost)
}

private func repeatedChildToolScript(count: Int) -> [[String: Any]] {
    (0..<count).map { _ in
        ["tool": ["name": "python", "arguments": ["code": "1"]]] as [String: Any]
    }
}

func test_agentChildExecutionAllowsMoreThanTwentyCallsWithoutAnImplicitLimit() async throws {
    guard let makeHost = childExecutionHostFactory() else { return }
    var script = repeatedChildToolScript(count: 21)
    script.append(["text": "completed after twenty-one tool turns"])
    guard let server = try FakeProviderServer(script: script) else { return }
    defer { server.stop() }

    let resource = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: scratchHome(), suffix: "unbounded-iterations",
        provider: OpenAICompletionsProvider(
            id: "fake", baseURL: server.baseURL, apiKey: nil),
        makeHost: makeHost, deadline: nil, maxIterations: nil),
        prompt: "keep working until the scripted answer")
    let result = await resource.execute()

    XCTAssertEqual(result.state, .succeeded)
    XCTAssertEqual(result.answer, "completed after twenty-one tool turns")
    XCTAssertTrue(result.cleanup.isComplete)
}

func test_agentChildExecutionExplicitIterationLimitIsFailure() async throws {
    guard let makeHost = childExecutionHostFactory() else { return }
    let script = repeatedChildToolScript(count: 21)
        + [["text": "unreachable final answer"] as [String: Any]]
    guard let server = try FakeProviderServer(script: script) else { return }
    defer { server.stop() }

    let resource = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: scratchHome(), suffix: "bounded-iterations",
        provider: OpenAICompletionsProvider(
            id: "fake", baseURL: server.baseURL, apiKey: nil),
        makeHost: makeHost, deadline: nil, maxIterations: 20),
        prompt: "stop at the explicit iteration ceiling")
    let result = await resource.execute()

    XCTAssertEqual(result.state, .failed)
    XCTAssertTrue(result.answer?.isEmpty != false, "the final scripted answer must remain unreachable")
    XCTAssertTrue(result.detail?.contains("Stopped after 20 model calls") == true)
    XCTAssertTrue(result.cleanup.isComplete)
}

func test_agentChildExecutionOwnsDistinctRuntimeAndTranscript() async throws {
    guard let makeHost = childExecutionHostFactory() else { return }
    let parentHost = makeHost()
    let parentCapabilities = try await parentHost.start()
    let home = scratchHome()
    let gate = ChildExecutionGate()
    let resource = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "owned", provider: GatedChildProvider(gate: gate),
        makeHost: makeHost), prompt: "finish the child task")

    let execution = Task { await resource.execute() }
    for _ in 0..<500 {
        if await gate.isInstalled { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(await gate.isInstalled)
    XCTAssertTrue(await parentHost.isRunning)
    await parentHost.stop()
    XCTAssertFalse(await parentHost.isRunning)
    await gate.release()
    let result = await execution.value

    XCTAssertEqual(result.state, .succeeded)
    XCTAssertEqual(result.answer, "child answer")
    XCTAssertNotNil(result.transcriptURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.transcriptURL!.path))
    XCTAssertNotEqual(result.runtimeIdentity, parentCapabilities.identity)
    XCTAssertTrue(result.cleanup.isComplete)
    XCTAssertEqual(await resource.execute(), result)
    XCTAssertEqual(await resource.cleanup(), result.cleanup)
}

func test_agentChildExecutionCancellationDuringPreparationAndExecutionIsBounded() async throws {
    guard let makeHost = childExecutionHostFactory() else { return }
    let home = scratchHome()

    let cleanedBeforeStart = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "cleanup-before-start", provider: GatedChildProvider(gate: ChildExecutionGate()),
        makeHost: makeHost), prompt: "never start")
    let preCleanup = await cleanedBeforeStart.cleanup()
    XCTAssertTrue(preCleanup.isComplete)
    let preCleanupResult = await cleanedBeforeStart.execute()
    XCTAssertEqual(preCleanupResult.state, .canceled)
    XCTAssertTrue(preCleanupResult.cleanup.isComplete)

    let beforeStart = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "cancel-before-start", provider: GatedChildProvider(gate: ChildExecutionGate()),
        makeHost: makeHost), prompt: "never start")
    XCTAssertEqual(await beforeStart.cancel(), .accepted)
    let beforeResult = await beforeStart.execute()
    XCTAssertEqual(beforeResult.state, .canceled)
    XCTAssertTrue(beforeResult.cleanup.isComplete)

    let gate = ChildExecutionGate()
    let duringExecution = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "cancel-running", provider: GatedChildProvider(gate: gate),
        makeHost: makeHost), prompt: "cancel me")
    let execution = Task { await duringExecution.execute() }
    for _ in 0..<500 {
        if await gate.isInstalled { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(await gate.isInstalled)
    let cancellation = Task { await duringExecution.cancel() }
    for _ in 0..<100 {
        if await duringExecution.cancellationIntentRecorded { break }
        await Task.yield()
    }
    XCTAssertTrue(await duringExecution.cancellationIntentRecorded)
    await gate.release(answer: "late answer")
    XCTAssertEqual(await cancellation.value, .accepted)
    let result = await execution.value
    XCTAssertEqual(result.state, .canceled)
    XCTAssertTrue(result.cleanup.isComplete)
    XCTAssertEqual(await duringExecution.cleanup(), result.cleanup)
}

func test_agentChildExecutionRefusesNestedChildrenExplicitly() async throws {
    guard let makeHost = childExecutionHostFactory() else { return }
    let resource = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: scratchHome(), suffix: "nested-refusal", provider: NestedSpawnProvider(),
        makeHost: makeHost), prompt: "try one nested child")
    let result = await resource.execute()

    XCTAssertEqual(result.state, .succeeded)
    let transcript = try XCTUnwrap(result.transcriptURL)
    let text = String(decoding: try Data(contentsOf: transcript), as: UTF8.self)
    XCTAssertTrue(text.contains("Nested agent children are not supported in this pilot."))
    XCTAssertTrue(result.cleanup.isComplete)
}

func test_agentChildExecutionRejectsUnleasedSharedAndAdoptedHosts() async throws {
    guard let root = EngineLocator.repoRoot() else { return }
    let home = scratchHome()

    let unleased = RuntimeHost.bundledPython(
        repoRoot: root, parentLifetimeLease: false)!
    let unleasedResource = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "unleased", provider: ImmediateChildProvider(),
        makeHost: { unleased }), prompt: "must be refused")
    let unleasedResult = await unleasedResource.execute()
    XCTAssertEqual(unleasedResult.state, .failed)
    XCTAssertTrue(unleasedResult.detail?.contains("fresh, exclusively leased") == true)
    XCTAssertFalse(await unleased.isRunning)

    let shared = RuntimeHost.bundledPython(
        repoRoot: root, parentLifetimeLease: true)!
    _ = try await shared.start()
    let sharedResource = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "shared", provider: ImmediateChildProvider(),
        makeHost: { shared }), prompt: "must be refused")
    let sharedResult = await sharedResource.execute()
    XCTAssertEqual(sharedResult.state, .failed)
    XCTAssertTrue(await shared.isRunning)
    await shared.stop()

    let owner = RuntimeHost.bundledPython(
        repoRoot: root, parentLifetimeLease: true)!
    _ = try await owner.start()
    let descriptor = try XCTUnwrap(await owner.adoptionDescriptor)
    await owner.disconnect()
    let adopted = try RuntimeHost.adopt(descriptor)
    let adoptedResource = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "adopted", provider: ImmediateChildProvider(),
        makeHost: { adopted }), prompt: "must be refused")
    let adoptedResult = await adoptedResource.execute()
    XCTAssertEqual(adoptedResult.state, .failed)
    XCTAssertFalse(await adopted.isConnected)
    await adopted.stop()
}

func test_agentChildExecutionRejectsExpiredAndInvalidConfigurationBeforeHostStart() async throws {
    guard let makeHost = childExecutionHostFactory() else { return }
    let home = scratchHome()
    let expired = AgentChildExecutionResource(configuration: childExecutionConfiguration(
        home: home, suffix: "expired", provider: ImmediateChildProvider(),
        makeHost: makeHost, deadline: Date().addingTimeInterval(-1)),
        prompt: "expired")
    let expiredResult = await expired.execute()
    XCTAssertEqual(expiredResult.state, .expired)
    XCTAssertTrue(expiredResult.cleanup.isComplete)

    let invalidIterations = AgentChildExecutionResource(configuration: .init(
        origin: childExecutionBinding("invalid-iterations"),
        childID: "child-invalid-iterations",
        deadline: Date().addingTimeInterval(30),
        home: home,
        cwd: "/tmp",
        model: fakeModel(),
        provider: ImmediateChildProvider(),
        systemPrompt: "test",
        maxIterations: 0,
        makeRuntimeHost: makeHost), prompt: "invalid")
    let invalidResult = await invalidIterations.execute()
    XCTAssertEqual(invalidResult.state, .failed)
    XCTAssertTrue(invalidResult.detail?.contains("maxIterations") == true)
    XCTAssertTrue(invalidResult.cleanup.isComplete)
}

let casesAgentChildExecutionResource: [Case] = [
    ("phase5 child resource owns a distinct runtime and transcript", {
        try await test_agentChildExecutionOwnsDistinctRuntimeAndTranscript()
    }),
    ("phase5 child resource cancellation is bounded and idempotent", {
        try await test_agentChildExecutionCancellationDuringPreparationAndExecutionIsBounded()
    }),
    ("phase5 child resource refuses nested children explicitly", {
        try await test_agentChildExecutionRefusesNestedChildrenExplicitly()
    }),
    ("phase5 child resource rejects unleased, shared, and adopted hosts", {
        try await test_agentChildExecutionRejectsUnleasedSharedAndAdoptedHosts()
    }),
    ("phase5 child resource rejects expired and invalid configuration", {
        try await test_agentChildExecutionRejectsExpiredAndInvalidConfigurationBeforeHostStart()
    }),
    ("phase5 child resource: nil limits allow more than twenty model calls", {
        try await test_agentChildExecutionAllowsMoreThanTwentyCallsWithoutAnImplicitLimit()
    }),
    ("phase5 child resource: explicit iteration limit is a failure", {
        try await test_agentChildExecutionExplicitIterationLimitIsFailure()
    }),
]
