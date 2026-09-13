import Foundation
@testable import AviaryCore

private final class FallbackChildIterationProvider: ChatProvider, @unchecked Sendable {
    let id = "fallback-child-iteration"
    let childPrompt = "complete the long fallback child fixture"
    private let lock = NSLock()
    private var parentCalls = 0
    private var childCalls = 0
    private var parentObservedChildCompletion = false

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let isChild = request.messages.contains {
            $0.role == .user && $0.plainText == childPrompt
        }
        let call: Int = lock.withLock {
            if isChild {
                childCalls += 1
                return childCalls
            }
            parentCalls += 1
            if request.messages.contains(where: { message in
                message.content.contains { content in
                    guard case .toolResult(_, _, let text, let isError) = content else {
                        return false
                    }
                    return !isError && text.contains("fallback child completed")
                }
            }) {
                parentObservedChildCompletion = true
            }
            return parentCalls
        }
        return AsyncThrowingStream { continuation in
            if isChild {
                if call <= 21 {
                    continuation.yield(.toolCall(
                        id: "fallback-child-tool-\(call)",
                        name: "python",
                        arguments: .object(["code": .string("1")])))
                } else {
                    continuation.yield(.textDelta("fallback child completed"))
                }
            } else if call == 1 {
                let code = """
                child = spawn(\(childPrompt.debugDescription), name='Long fallback child')
                print(child.result(timeout=30))
                """
                continuation.yield(.toolCall(
                    id: "fallback-parent-spawn", name: "python",
                    arguments: .object(["code": .string(code)])))
            } else {
                continuation.yield(.textDelta("parent completed"))
            }
            continuation.yield(.done(stopReason: isChild && call <= 21 ? "tool_use" : "stop"))
            continuation.finish()
        }
    }

    func observations() -> (parentCalls: Int, childCalls: Int, parentSawCompletion: Bool) {
        lock.withLock { (parentCalls, childCalls, parentObservedChildCompletion) }
    }
}

private func fallbackChildTestHome(_ suffix: String) throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "afc-\(suffix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return AgentHome(root: root)
}

private func fallbackChildTestModel() -> ModelSpec {
    var model = ModelSpec(rpc: .object([
        "id": .string("fallback-child-model"),
        "provider": .string("fallback-child-iteration"),
    ]))
    model.contextWindow = 100_000
    return model
}

private func runFallbackChildIterationFixture(
    suffix: String, childMaxIterations: Int?
) async throws -> (
    parentCalls: Int, childCalls: Int, parentSawCompletion: Bool, parentAnswer: String
) {
    let root = try XCTUnwrap(EngineLocator.repoRoot())
    let host = try XCTUnwrap(RuntimeHost.bundledPython(repoRoot: root))
    let home = try fallbackChildTestHome(suffix)
    defer { try? FileManager.default.removeItem(at: home.root) }
    let provider = FallbackChildIterationProvider()
    _ = try await host.start()
    let settings: AgentRunner.Settings
    if let childMaxIterations {
        settings = .init(
            home: home, cwd: home.root.path, model: fallbackChildTestModel(),
            systemPrompt: "Use the Python tool for this fixture.",
            maxIterations: 3, childMaxIterations: childMaxIterations)
    } else {
        // Deliberately omit childMaxIterations: this is the user-facing default under test.
        settings = .init(
            home: home, cwd: home.root.path, model: fallbackChildTestModel(),
            systemPrompt: "Use the Python tool for this fixture.", maxIterations: 3)
    }
    let runner = AgentRunner(provider: provider, host: host, settings: settings)
    var writer: SessionWriter?
    do {
        let prepared = try await runner.run(prompt: "run the fallback child fixture")
        writer = prepared.writer
        await runner.stopBackgroundChildren()
        let parentAnswer = await prepared.agent.lastAssistantText
        try await prepared.writer.closeChecked()
        await host.stop()
        let observations = provider.observations()
        return (
            observations.parentCalls, observations.childCalls,
            observations.parentSawCompletion, parentAnswer)
    } catch {
        await runner.stopBackgroundChildren()
        await writer?.close()
        await host.stop()
        throw error
    }
}

func testFallbackChildIterationDefaultsAreOptional() async throws {
    let root = try XCTUnwrap(EngineLocator.repoRoot())
    let host = try XCTUnwrap(RuntimeHost.bundledPython(repoRoot: root))
    let home = try fallbackChildTestHome("shape")
    defer { try? FileManager.default.removeItem(at: home.root) }
    let model = fallbackChildTestModel()
    let provider = FallbackChildIterationProvider()
    let runnerSettings = AgentRunner.Settings(
        home: home, cwd: home.root.path, model: model, systemPrompt: "fixture")
    XCTAssertNil(runnerSettings.childMaxIterations)
    XCTAssertEqual(runnerSettings.maxIterations, 40)

    let workHost = WorkHostRef(try home.requirePersistedWorkHostID())
    let binding = WorkBinding(
        session: SessionRef("fallback-shape-session"),
        work: WorkRef(workHostID: workHost.workHostID, workID: "fallback-shape-work"),
        workHost: workHost,
        sessionAttachment: SessionAttachmentRef("fallback-shape-attachment"))
    let workRun = WorkRunBinding(workBinding: binding, run: RunRef("fallback-shape-run"))
    let factory = InHouseWorkFactory.Configuration(
        home: home, cwd: home.root.path, model: model, provider: provider,
        runtimeHost: host, workRunBinding: workRun, serviceActorID: "fallback-shape-host",
        systemPrompt: "fixture")
    XCTAssertNil(factory.childMaxIterations)
    XCTAssertEqual(factory.maxIterations, 40)
    let hosted = HostedInHouseWorkConfiguration(
        home: home, cwd: home.root.path, model: model, provider: provider,
        runtimeHost: host, workRunBinding: workRun, serviceActorID: "fallback-shape-host",
        systemPrompt: "fixture")
    XCTAssertNil(hosted.childMaxIterations)
    XCTAssertEqual(hosted.maxIterations, 40)
    let explicit = AgentRunner.Settings(
        home: home, cwd: home.root.path, model: model, systemPrompt: "fixture",
        childMaxIterations: 20)
    XCTAssertEqual(explicit.childMaxIterations, 20)
    let explicitFactory = InHouseWorkFactory.Configuration(
        home: home, cwd: home.root.path, model: model, provider: provider,
        runtimeHost: host, workRunBinding: workRun, serviceActorID: "fallback-shape-host",
        systemPrompt: "fixture", childMaxIterations: 20)
    XCTAssertEqual(explicitFactory.childMaxIterations, 20)
    let explicitHosted = HostedInHouseWorkConfiguration(
        home: home, cwd: home.root.path, model: model, provider: provider,
        runtimeHost: host, workRunBinding: workRun, serviceActorID: "fallback-shape-host",
        systemPrompt: "fixture", childMaxIterations: 20)
    XCTAssertEqual(explicitHosted.childMaxIterations, 20)
}

func testFallbackChildDefaultRunsPastTwentyProviderTurns() async throws {
    let result = try await runFallbackChildIterationFixture(
        suffix: "unlimited", childMaxIterations: nil)
    XCTAssertEqual(result.childCalls, 22)
    XCTAssertEqual(result.parentCalls, 2)
    XCTAssertTrue(result.parentSawCompletion)
    XCTAssertEqual(result.parentAnswer, "parent completed")
}

func testFallbackChildExplicitTwentyTurnLimitStillApplies() async throws {
    let result = try await runFallbackChildIterationFixture(
        suffix: "limited", childMaxIterations: 20)
    XCTAssertEqual(result.childCalls, 20)
    XCTAssertEqual(result.parentCalls, 2)
    XCTAssertFalse(result.parentSawCompletion)
    XCTAssertEqual(result.parentAnswer, "parent completed")
}

let casesFallbackChildIterationDefaults: [Case] = [
    ("fallback child iterations: default is unlimited without changing parent", {
        try await testFallbackChildIterationDefaultsAreOptional()
    }),
    ("fallback child iterations: default runs beyond twenty provider turns", {
        try await testFallbackChildDefaultRunsPastTwentyProviderTurns()
    }),
    ("fallback child iterations: explicit twenty-turn ceiling remains enforced", {
        try await testFallbackChildExplicitTwentyTurnLimitStillApplies()
    }),
]
