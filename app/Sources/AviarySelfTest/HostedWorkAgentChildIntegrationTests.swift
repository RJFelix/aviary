import Foundation
@testable import AviaryCore

private actor PilotChildProviderGate {
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    var entered: Bool { continuation != nil }
    func install(_ value: AsyncThrowingStream<ChatEvent, Error>.Continuation) { continuation = value }
    func release() {
        continuation?.yield(.textDelta("durable child answer"))
        continuation?.yield(.done(stopReason: "stop"))
        continuation?.finish()
        continuation = nil
    }
}

private final class PilotSpawningProvider: ChatProvider, @unchecked Sendable {
    let id = "pilot-spawning-provider"
    let childGate = PilotChildProviderGate()
    private let lock = NSLock()
    private var parentCalls = 0
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        if request.messages.contains(where: { $0.role == .user && $0.plainText == "pilot child brief" }) {
            return AsyncThrowingStream { continuation in
                Task { await childGate.install(continuation) }
            }
        }
        let call = lock.withLock { parentCalls += 1; return parentCalls }
        return AsyncThrowingStream { continuation in
            if call == 1 {
                continuation.yield(.toolCall(
                    id: "pilot-spawn-call", name: "python",
                    arguments: .object(["code": .string(
                        "child = spawn('pilot child brief', name='Durable child')\nchild.aviary_id")])))
            } else { continuation.yield(.textDelta("Parent finished its own work.")) }
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private func pilotEventually(_ condition: () async throws -> Bool) async rethrows -> Bool {
    for _ in 0..<1_000 {
        if try await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

private func pilotSubmit(
    _ work: HostedInHouseWork, id: String, command: SessionCommand
) async throws -> HostedInHouseWorkReceipt {
    let snapshot = await work.snapshot()
    return try await work.submit(HostedInHouseWorkCommand(
        work: snapshot.identity.work, session: SessionRef(snapshot.identity.sessionID),
        sessionAttachment: snapshot.sessionAttachment, client: ClientRef("pilot-observer"),
        commandID: id, causalCursor: try XCTUnwrap(snapshot.latestWorkCursor), command: command))
}

func testHostedPilotChildSurvivesEndAndSecondSessionReadsColdResult() async throws {
    guard let root = EngineLocator.repoRoot(),
          let parentRuntime = RuntimeHost.bundledPython(repoRoot: root, parentLifetimeLease: true),
          let secondRuntime = RuntimeHost.bundledPython(repoRoot: root, parentLifetimeLease: true)
    else { return }
    let home = scratchHome()
    let host = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef("pilot-parent-chat"),
        work: WorkRef(workHostID: host.workHostID, workID: "pilot-surviving-work"),
        workHost: host, sessionAttachment: SessionAttachmentRef("pilot-parent-attachment"))
    _ = try await RunJournalBundle.createIdleWork(home: home, binding: binding, actorID: "pilot-host")
    let coordinator = try WorkAgentChildCoordinator()
    let provider = PilotSpawningProvider()
    let pilot = WorkAgentChildPilot(
        coordinator: coordinator, deadline: Date().addingTimeInterval(120),
        makeRuntimeHost: { RuntimeHost.bundledPython(repoRoot: root, parentLifetimeLease: true)! })
    func configuration(_ selected: WorkBinding, run: String, runtime: RuntimeHost,
                       policy: WorkAgentChildPilot) -> HostedInHouseWorkConfiguration {
        var result = HostedInHouseWorkConfiguration(
            home: home, cwd: home.root.path, model: fakeModel(), provider: provider,
            runtimeHost: runtime, workRunBinding: WorkRunBinding(workBinding: selected, run: RunRef(run)),
            serviceActorID: "pilot-host", systemPrompt: "Use the Python tool for this fixture.",
            maxIterations: 3)
        result.agentChildPilot = policy
        return result
    }
    let parent = try await HostedInHouseWork.open(configuration: configuration(
        binding, run: "pilot-parent-run", runtime: parentRuntime, policy: pilot))
    do {
        let observer = await parent.subscribe(client: ClientRef("pilot-gui"))
        XCTAssertTrue(observer.accepted)
        XCTAssertTrue(try await pilotSubmit(parent, id: "start", command: .start(prompt: "")).wasAdmitted)
        XCTAssertTrue(await pilotEventually { await parent.snapshot().lifecycle == .idle })
        XCTAssertTrue(try await pilotSubmit(parent, id: "send", command: .send(prompt: "start one child")).wasAdmitted)
        XCTAssertTrue(await pilotEventually {
            let entered = await provider.childGate.entered
            let state = await parent.snapshot()
            return entered && state.lifecycle == .idle
        })
        let handleOutput = try await parentRuntime.execute(
            "print(child.aviary_id)", in: binding.work.workID, timeout: 5)
        XCTAssertNil(handleOutput.exception)
        let handle = HandleRef(handleOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(handle.handleID.hasPrefix("agent-child-"))
        let running = try await coordinator.inspect(work: binding.work, handle: handle)
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.origin.session, binding.session)

        await parent.unsubscribe(observer.id)
        XCTAssertTrue(try await pilotSubmit(parent, id: "end", command: .endRun).wasAdmitted)
        XCTAssertTrue(await pilotEventually {
            let state = await parent.snapshot()
            return state.lifecycle == .ended && state.journalHealth == .closed
        })
        XCTAssertFalse(await parentRuntime.hostProcessIsRunning)
        XCTAssertEqual(try await coordinator.inspect(work: binding.work, handle: handle).state, .running)
        await provider.childGate.release()
        XCTAssertTrue(try await pilotEventually {
            try await coordinator.inspect(work: binding.work, handle: handle).state == .terminal
        })
        let result = try await coordinator.read(work: binding.work, handle: handle)
        XCTAssertEqual(result.record.terminalOutcome, .succeeded)
        XCTAssertEqual(result.result, .available(Data("durable child answer".utf8)))
        XCTAssertEqual(result.record.origin.run, RunRef("pilot-parent-run"))

        let frozenBytes = try Data(contentsOf: home.timelineV2WorkJournalURL(binding.work))
        let cold = try WorkAgentChildCoordinator()
        try await cold.register(work: binding.work, home: home, actor: TimelineActor(actorID: "cold-reader", kind: "work-host"))
        XCTAssertEqual(try await cold.read(work: binding.work, handle: handle).result, result.result)
        XCTAssertEqual(try await cold.read(work: binding.work, handle: handle).result, result.result)
        XCTAssertEqual(try Data(contentsOf: home.timelineV2WorkJournalURL(binding.work)), frozenBytes)

        let events = TimelineJournalReader.read(
            frozenBytes, journal: binding.workJournal, actor: TimelineActor(actorID: "test-reader", kind: "self-test"),
            hostRecordedAt: Date()).records.map(\.event)
        let last = try XCTUnwrap(events.last)
        let cursor = JournalCursor(journal: binding.workJournal, eventID: last.eventID, sequence: try XCTUnwrap(last.sequence))
        let selected = WorkBinding(session: SessionRef("pilot-second-chat"), work: binding.work, workHost: host,
                                   sessionAttachment: SessionAttachmentRef("pilot-second-attachment"))
        let client = ClientRef("pilot-second-gui")
        _ = try await RunJournalBundle.publishSessionAttachment(home: home, request: .init(
            work: binding.work, workHost: host, workJournal: binding.workJournal,
            session: selected.session, sessionJournal: selected.sessionJournal,
            sessionAttachment: selected.sessionAttachment, client: client,
            command: CommandRef(commandID: "attach-second", client: client,
                                sessionAttachment: selected.sessionAttachment, causalCursor: cursor),
            capabilities: ["observe", "start"], causalWorkCursor: cursor), actorID: "pilot-host")
        let coldPilot = WorkAgentChildPilot(coordinator: cold, deadline: pilot.deadline, makeRuntimeHost: pilot.makeRuntimeHost)
        let second = try await HostedInHouseWork.open(configuration: configuration(
            selected, run: "pilot-second-run", runtime: secondRuntime, policy: coldPilot))
        XCTAssertTrue(try await pilotSubmit(second, id: "second-start", command: .start(prompt: "")).wasAdmitted)
        XCTAssertTrue(await pilotEventually { await second.snapshot().lifecycle == .idle })
        let attached = try await secondRuntime.execute(
            "recovered = attach_agent('\(handle.handleID)')\nprint(recovered.result(timeout=5))\nprint(recovered.result(timeout=0))",
            in: binding.work.workID, timeout: 10)
        XCTAssertNil(attached.exception)
        XCTAssertEqual(attached.stdout, "durable child answer\ndurable child answer\n")
        let collision = try await secondRuntime.execute(
            "kept = 42\ntry:\n    attach_agent('\(handle.handleID)', name='kept')\nexcept ValueError:\n    print(kept)",
            in: binding.work.workID, timeout: 5)
        XCTAssertNil(collision.exception)
        XCTAssertEqual(collision.stdout, "42\n")
        XCTAssertTrue(try await pilotSubmit(second, id: "second-end", command: .endRun).wasAdmitted)
        XCTAssertTrue(await pilotEventually { await second.snapshot().journalHealth == .closed })
    } catch {
        await provider.childGate.release()
        await parentRuntime.stop()
        await secondRuntime.stop()
        throw error
    }
}

let casesHostedWorkAgentChildIntegration: [Case] = [
    ("phase5 Hosted child: parent End and second Session retained result", {
        try await testHostedPilotChildSurvivesEndAndSecondSessionReadsColdResult()
    }),
]
