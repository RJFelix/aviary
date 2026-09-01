import Foundation

@testable import AviaryCore

func test_sessionWorkIdentityAllocatesIndependentStableReferences() throws {
    let first = SessionWorkIdentity.allocate(
        workHostID: "host-a",
        makeID: { prefix in "\(prefix)-fixed" })
    let resumed = SessionWorkIdentity.allocate(
        workHostID: first.workHostID,
        sessionID: first.sessionID,
        workID: first.workID,
        makeID: { prefix in "\(prefix)-new" })

    XCTAssertEqual(first.sessionID, "session-fixed")
    XCTAssertEqual(first.workID, "work-fixed")
    XCTAssertEqual(first.workHostID, "host-a")
    XCTAssertEqual(first.runID, "run-fixed")
    XCTAssertEqual(resumed.sessionID, first.sessionID)
    XCTAssertEqual(resumed.work, first.work)
    XCTAssertNotEqual(resumed.runID, first.runID)
}

func test_sessionCommandControllerSerializesAdmissionAndAcknowledgements() async throws {
    let identity = SessionWorkIdentity(
        sessionID: "session-1", work: WorkRef(workHostID: "host-1", workID: "work-1"),
        runID: "run-1")
    let controller = SessionCommandController(identity: identity)

    let start = await controller.admit(
        .start(prompt: "hello"), actorID: "gui-a", commandID: "c1")
    guard case .accepted(let admitted) = start else {
        XCTFail("start should be admitted")
        return
    }
    XCTAssertEqual(admitted.sequence, 1)
    XCTAssertEqual(admitted.previousState, .prepared)
    XCTAssertEqual(admitted.state, .preparing)
    XCTAssertEqual(admitted.identity, identity)
    XCTAssertEqual(
        await controller.admit(.start(prompt: "different"), actorID: "gui-b", commandID: "c1"),
        start,
        "an accepted command ID is an idempotency key, not a second command")
    XCTAssertEqual(await controller.awaitDispatch(commandID: "c1")?.commandID, "c1")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "c1"))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "c1"))

    // A second send cannot race through while the first turn is still running.
    let premature = await controller.admit(
        .send(prompt: "too soon"), actorID: "gui-a", commandID: "c2")
    guard case .rejected(_, let reason) = premature else {
        XCTFail("send during a running turn should be rejected")
        return
    }
    XCTAssertEqual(reason, .invalidState(command: "send", state: .running))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "c1"))
    let retriedPremature = await controller.admit(
        .send(prompt: "too soon"), actorID: "gui-a", commandID: "c2")
    XCTAssertEqual(retriedPremature, premature)

    let sends = await withTaskGroup(
        of: SessionCommandAdmission.self, returning: [SessionCommandAdmission].self
    ) { group in
        for id in ["c3", "c4"] {
            group.addTask {
                await controller.admit(.send(prompt: id), actorID: "gui-\(id)", commandID: id)
            }
        }
        var results: [SessionCommandAdmission] = []
        for await result in group { results.append(result) }
        return results
    }
    let acceptedCount = sends.filter {
        if case .accepted = $0 { return true }
        return false
    }.count
    XCTAssertEqual(acceptedCount, 1)
    XCTAssertEqual(await controller.admittedCount, 2)

    let activeSendID = sends.compactMap { admission -> String? in
        guard case .accepted(let command) = admission else { return nil }
        return command.commandID
    }.first
    XCTAssertNotNil(activeSendID)
    XCTAssertEqual(
        await controller.awaitDispatch(commandID: activeSendID ?? "")?.commandID,
        activeSendID)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: activeSendID ?? ""))
    XCTAssertFalse(await controller.acknowledgeTurnFinished(commandID: "c1"))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: activeSendID ?? ""))
}

func test_sessionCommandControllerDispatchIsExactlyOnceForDuplicateWaiters() async throws {
    let identity = SessionWorkIdentity(
        sessionID: "s", work: WorkRef(workHostID: "h", workID: "w"), runID: "r")
    let controller = SessionCommandController(identity: identity)
    _ = await controller.admit(.start(prompt: "run"), actorID: "gui", commandID: "start")

    let results = await withTaskGroup(
        of: AdmittedSessionCommand?.self, returning: [AdmittedSessionCommand?].self
    ) {
        group in
        group.addTask { await controller.awaitDispatch(commandID: "start") }
        group.addTask { await controller.awaitDispatch(commandID: "start") }
        var results: [AdmittedSessionCommand?] = []
        for await result in group { results.append(result) }
        return results
    }
    XCTAssertEqual(results.compactMap { $0 }.count, 1)
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "start"))
    XCTAssertNil(
        await controller.awaitDispatch(commandID: "start"), "completed retries cannot dispatch")
}

func test_sessionCommandControllerIgnoresStaleFailureAfterNewerSendOrEnd() async throws {
    let identity = SessionWorkIdentity(
        sessionID: "s", work: WorkRef(workHostID: "h", workID: "w"), runID: "r")
    let controller = SessionCommandController(identity: identity)
    _ = await controller.admit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    _ = await controller.awaitDispatch(commandID: "start")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "start"))

    let send = await controller.admit(.send(prompt: "next"), actorID: "gui", commandID: "send")
    _ = await controller.awaitDispatch(commandID: "send")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "send"))
    XCTAssertFalse(await controller.markFailed(commandID: "start"))
    XCTAssertEqual(await controller.state, .running)
    XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "send"))

    let end = await controller.admit(.endRun, actorID: "gui", commandID: "end")
    _ = await controller.awaitDispatch(commandID: "end")
    XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "end"))
    XCTAssertFalse(await controller.markFailed(commandID: "send"))
    XCTAssertEqual(await controller.state, .ending)
    guard case .accepted = send, case .accepted = end else {
        XCTFail("send and end should be admitted")
        return
    }
    XCTAssertTrue(await controller.acknowledgeEnd(commandID: "end"))
    XCTAssertEqual(await controller.state, .ended)
}

func test_agentCancellationWaitsForProviderAndPreventsLateToolExecution() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    defer { Task { await host.stop() } }
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let effect = FileManager.default.temporaryDirectory
        .appending(path: "aviary-late-tool-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: effect) }
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
    let hostSession = try await host.createSession(cwd: "/tmp")
    let provider = CancellationIgnoringToolProvider()
    let agent = Agent(
        provider: provider, host: host, writer: writer, hostSession: hostSession,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "test"))
    let events = EventLog()
    await agent.observe { events.record($0) }

    let send = Task { await agent.send("wait, then use the tool") }
    for _ in 0..<100 where !provider.hasStarted {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(
        provider.hasStarted, "the provider call reached its cancellation-insensitive wait")
    await agent.cancel()
    provider.releaseTool(code: "open(\(String(reflecting: effect.path)), 'w').write('bad')")
    XCTAssertEqual(await send.value, .cancelled)
    await agent.waitUntilQuiescent()
    await writer.close()

    XCTAssertFalse(events.names.contains("tool:python"), "a late tool never begins after cancel")
    XCTAssertFalse(
        FileManager.default.fileExists(atPath: effect.path),
        "the runtime observes no external effect from the cancelled provider result")
}

func test_cooperativeProviderCancellationIsNotReportedAsFailure() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    defer { Task { await host.stop() } }
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
    let hostSession = try await host.createSession(cwd: "/tmp")
    let provider = CooperativeCancellationProvider()
    let agent = Agent(
        provider: provider, host: host, writer: writer, hostSession: hostSession,
        config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "test"))
    let events = EventLog()
    await agent.observe { events.record($0) }

    let send = Task { await agent.send("wait cooperatively") }
    for _ in 0..<100 where !provider.hasStarted {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(provider.hasStarted)
    await agent.cancel()
    send.cancel()
    XCTAssertEqual(await send.value, .cancelled)
    await agent.waitUntilQuiescent()
    await writer.close()

    XCTAssertFalse(events.names.contains("failed"))
    XCTAssertTrue(events.names.contains("finished:cancelled"))
}

func test_claudeInputWithoutLiveStdinIsRejected() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let run = try ClaudeCodeRun(
        settings: .init(
            home: home, cwd: "/tmp", model: "sonnet", systemPrompt: "test",
            bridgeExecutable: "/usr/bin/false"),
        bridge: KernelBridge())
    await run.finishInput()
    let delivery = await run.send("must not be reported delivered")
    XCTAssertFalse(delivery.isDelivered)
    XCTAssertTrue(
        delivery.detail?.contains("not accepting input") == true,
        delivery.detail ?? "missing delivery detail")
    await run.stop()
}

func test_sessionCommandControllerRequiresDeclaredCancellationCapability() async throws {
    XCTAssertEqual(Agent.supportedCancellationScopes, [.agentLoop])
    XCTAssertTrue(Agent.inHouseCommandCapabilities.supports(.agentLoop))
    XCTAssertFalse(Agent.inHouseCommandCapabilities.supports(.modelStream))
    XCTAssertFalse(Agent.inHouseCommandCapabilities.supports(.currentAction))
    let identity = SessionWorkIdentity(
        sessionID: "s", work: WorkRef(workHostID: "h", workID: "w"), runID: "r")
    let controller = SessionCommandController(identity: identity)
    _ = await controller.admit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))

    let unsupported = await controller.admit(
        .cancel(scope: .currentAction), actorID: "gui", commandID: "cancel-1")
    guard case .rejected(_, let reason) = unsupported else {
        XCTFail("undeclared cancellation must not be guessed as supported")
        return
    }
    XCTAssertEqual(reason, .unsupportedCancellation(scope: .currentAction))
    XCTAssertEqual(await controller.state, .running)

    let capable = SessionCommandController(
        identity: identity,
        capabilities: SessionCommandCapabilities(cancellationScopes: [.agentLoop]))
    _ = await capable.admit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertTrue(await capable.acknowledgePreparation(commandID: "start"))
    let accepted = await capable.admit(
        .cancel(scope: .agentLoop), actorID: "gui", commandID: "cancel-2")
    guard case .accepted(let command) = accepted else {
        XCTFail("declared cancellation should be admitted")
        return
    }
    XCTAssertEqual(command.state, .canceling)
    XCTAssertFalse(
        (await capable.admit(.cancel(scope: .modelStream), actorID: "gui", commandID: "cancel-3"))
            .isAccepted,
        "model-stream cancellation must stay unsupported without a provider interrupt")
    XCTAssertFalse(
        (await capable.admit(.cancel(scope: .currentAction), actorID: "gui", commandID: "cancel-4"))
            .isAccepted,
        "current-action cancellation must stay unsupported without an action handle")
    XCTAssertTrue(await capable.acknowledgeCancellation(commandID: "cancel-2"))
    XCTAssertEqual(await capable.state, .idle)

    let ending = await capable.admit(.endRun, actorID: "gui", commandID: "end")
    guard case .accepted(let endCommand) = ending else {
        XCTFail("end should be admitted")
        return
    }
    XCTAssertEqual(endCommand.state, .ending)
    XCTAssertFalse(await capable.acknowledgeTurnFinished(commandID: "cancel-2"))
    XCTAssertTrue(await capable.acknowledgeEnd(commandID: "end"))
    XCTAssertEqual(await capable.state, .ended)
}

func test_sessionCommandControllerRequiresDeclaredSteeringAndQueues() async throws {
    let identity = SessionWorkIdentity(
        sessionID: "s", work: WorkRef(workHostID: "h", workID: "w"), runID: "r")
    let controller = SessionCommandController(identity: identity)
    _ = await controller.admit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertTrue(await controller.acknowledgePreparation(commandID: "start"))

    let steering = await controller.admit(
        .steer(text: "change course"), actorID: "gui", commandID: "steer")
    let queued = await controller.admit(
        .queueFollowUp(text: "do this later"), actorID: "gui", commandID: "follow-up")
    guard case .rejected(_, let steeringReason) = steering,
        case .rejected(_, let queueReason) = queued
    else {
        XCTFail("undeclared steering and queue capabilities must be rejected")
        return
    }
    XCTAssertEqual(steeringReason, .unsupportedCommand(command: "steer"))
    XCTAssertEqual(queueReason, .unsupportedCommand(command: "queue_follow_up"))

    let capable = SessionCommandController(
        identity: identity,
        capabilities: SessionCommandCapabilities(
            supportsSteering: true, supportsQueuedFollowUps: true))
    _ = await capable.admit(.start(prompt: "run"), actorID: "gui", commandID: "start")
    XCTAssertTrue(await capable.acknowledgePreparation(commandID: "start"))
    guard
        case .accepted = await capable.admit(
            .steer(text: "change course"), actorID: "gui", commandID: "steer"),
        case .accepted = await capable.admit(
            .queueFollowUp(text: "do this later"), actorID: "gui", commandID: "follow-up")
    else {
        XCTFail("declared steering and queue capabilities should be admitted")
        return
    }
}

func test_agentRunnerDestroysRuntimeSessionWhenWriterSetupFails() async throws {
    guard let host = try makeHost(.reference) else { return }
    _ = try await host.start()
    defer { Task { await host.stop() } }

    // `/dev/null` is a file, so SessionWriter cannot create the sessions directory beneath it.
    // The runtime session is created first; this makes the assertion catch the leak rather than
    // merely proving that preparation failed.
    let impossibleHome = AgentHome(
        root: URL(fileURLWithPath: "/dev/null")
            .appending(path: "aviary-writer-failure-" + UUID().uuidString))
    let identity = SessionWorkIdentity(
        sessionID: "writer-failure-session",
        work: WorkRef(workHostID: "test-host", workID: "writer-failure-work"),
        runID: "writer-failure-run")
    let runner = AgentRunner(
        provider: CooperativeCancellationProvider(), host: host,
        settings: .init(
            home: impossibleHome, cwd: "/tmp", model: fakeModel(), systemPrompt: "test",
            identity: identity))

    do {
        _ = try await runner.prepare()
        XCTFail("writer setup should fail beneath /dev/null")
    } catch {
        // Expected: the cleanup contract is what this test is exercising.
    }

    XCTAssertEqual(
        try await host.sessions(), [],
        "a failed writer setup must not leave the runtime session addressable")
}

func test_sessionCommandControllerCoversTheControlContractMatrix() async throws {
    enum Engine: CaseIterable, Equatable { case inHouse, claudeCode }
    enum Lifecycle: CaseIterable, Equatable {
        case prepared, preparing, running, idle, canceling, failed, ending, ended
    }
    enum Control: CaseIterable, Equatable {
        case start, send, steer, queue, cancelLoop, cancelModel, cancelAction, end

        var command: SessionCommand {
            switch self {
            case .start: return .start(prompt: "start")
            case .send: return .send(prompt: "send")
            case .steer: return .steer(text: "steer")
            case .queue: return .queueFollowUp(text: "later")
            case .cancelLoop: return .cancel(scope: .agentLoop)
            case .cancelModel: return .cancel(scope: .modelStream)
            case .cancelAction: return .cancel(scope: .currentAction)
            case .end: return .endRun
            }
        }
    }

    func controller(engine: Engine, at lifecycle: Lifecycle) async -> SessionCommandController? {
        let capabilities =
            engine == .inHouse
            ? Agent.inHouseCommandCapabilities
            : SessionCommandCapabilities()
        let identity = SessionWorkIdentity(
            sessionID: "matrix-session",
            work: WorkRef(workHostID: "matrix-host", workID: "matrix-work"),
            runID: "matrix-run")
        let controller = SessionCommandController(
            identity: identity, capabilities: capabilities)
        if lifecycle == .prepared { return controller }

        _ = await controller.admit(
            .start(prompt: "initial"), actorID: "matrix", commandID: "matrix-start")
        if lifecycle == .preparing { return controller }
        XCTAssertTrue(await controller.acknowledgePreparation(commandID: "matrix-start"))
        if lifecycle == .running { return controller }
        if lifecycle == .canceling {
            guard engine == .inHouse else { return nil }
            _ = await controller.admit(
                .cancel(scope: .agentLoop), actorID: "matrix", commandID: "matrix-cancel")
            return controller
        }
        if lifecycle == .failed {
            XCTAssertTrue(await controller.markFailed(commandID: "matrix-start"))
            return controller
        }
        if lifecycle == .idle {
            XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "matrix-start"))
            return controller
        }
        _ = await controller.admit(.endRun, actorID: "matrix", commandID: "matrix-end")
        if lifecycle == .ending { return controller }
        XCTAssertTrue(await controller.acknowledgeEnd(commandID: "matrix-end"))
        return controller
    }

    func expected(engine: Engine, lifecycle: Lifecycle, control: Control) -> Bool {
        switch lifecycle {
        case .prepared:
            return control == .start || control == .end
        case .preparing, .canceling, .failed:
            return control == .end
        case .running:
            switch control {
            case .steer, .queue, .cancelLoop: return engine == .inHouse
            case .end: return true
            default: return false
            }
        case .idle:
            return control == .send || control == .end
        case .ending, .ended:
            return false
        }
    }

    var exercised = 0
    for engine in Engine.allCases {
        for lifecycle in Lifecycle.allCases {
            guard let base = await controller(engine: engine, at: lifecycle) else {
                XCTAssertTrue(
                    engine == .claudeCode && lifecycle == .canceling,
                    "only an unsupported cancellation state may be unreachable")
                continue
            }
            for control in Control.allCases {
                // Each admission mutates lifecycle, so reconstruct the same starting cell.
                let candidate =
                    control == .start
                    ? base
                    : await controller(engine: engine, at: lifecycle) ?? base
                let admission = await candidate.admit(
                    control.command, actorID: "matrix", commandID: "cell-\(exercised)")
                XCTAssertEqual(
                    admission.isAccepted,
                    expected(engine: engine, lifecycle: lifecycle, control: control),
                    "\(engine) × \(lifecycle) × \(control)")
                exercised += 1
            }
        }
    }
    XCTAssertEqual(
        exercised, 120, "two engines × eight states × eight controls, minus one unreachable state")
}

func test_agentHomeWorkHostIdentityIsDurable() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-host-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = AgentHome(root: root)
    let first = home.workHostID
    let second = home.workHostID
    XCTAssertEqual(first, second)
    XCTAssertTrue(FileManager.default.fileExists(atPath: home.workHostIDFile.path))
}

func test_sessionWriterReturnsTheDurableAssistantIdentity() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
    let messageID = try await writer.appendAssistant(
        text: "durable answer", thinking: "", toolCalls: [], usage: nil,
        stopReason: "end_turn")
    await writer.close()

    let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
    XCTAssertTrue(
        transcript.items.contains {
            $0.id == messageID && $0.plainText == "durable answer"
        }, "the live adapter's writer-confirmed id must identify the parsed durable row")
}

func test_sessionWriterPersistsAndRecoversIdentityWithoutChangingLegacyShape() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let identity = SessionWorkIdentity(
        sessionID: "session-fixed", work: WorkRef(workHostID: "host-fixed", workID: "work-fixed"),
        runID: "run-fixed")

    let writer = try SessionWriter(home: home, cwd: "/tmp/project", model: nil, identity: identity)
    XCTAssertEqual(writer.identity, identity)
    let firstLine = try XCTUnwrap(
        String(contentsOf: writer.fileURL, encoding: .utf8)
            .split(separator: "\n", maxSplits: 1).first)
    let headerData = try XCTUnwrap(String(firstLine).data(using: .utf8))
    let header = JSONValue.parse(headerData)
    XCTAssertEqual(header?["workHostId"]?.stringValue, "host-fixed")
    XCTAssertEqual(header?["workId"]?.stringValue, "work-fixed")
    XCTAssertEqual(header?["runId"]?.stringValue, "run-fixed")
    await writer.close()

    let recovered = try XCTUnwrap(
        SessionWriter.recoverIdentity(home: home, sessionID: "session-fixed"))
    XCTAssertEqual(recovered.sessionID, identity.sessionID)
    XCTAssertEqual(recovered.work, identity.work)
    XCTAssertNotEqual(recovered.runID, identity.runID)

    let legacyID = "legacy-session"
    let legacyURL = home.sessionFile(id: legacyID)
    try FileManager.default.createDirectory(
        at: home.sessionsDir, withIntermediateDirectories: true)
    try Data(
        #"{"type":"session","version":1,"id":"legacy-session","timestamp":"2026-08-31T00:00:00Z","cwd":"/tmp"}"#
            .utf8
    ).write(to: legacyURL)
    let legacy = try XCTUnwrap(SessionWriter.recoverIdentity(home: home, sessionID: legacyID))
    XCTAssertEqual(legacy.workHostID, home.workHostID)
    XCTAssertEqual(legacy.workID, "legacy-work-\(legacyID)")
    let legacyAgain = try XCTUnwrap(
        SessionWriter.recoverIdentity(home: home, sessionID: legacyID))
    XCTAssertEqual(legacy.work, legacyAgain.work)
    XCTAssertNotEqual(legacy.runID, legacyAgain.runID)

    let resumed = try SessionWriter(
        home: home, resuming: legacyID, cwd: "/tmp", model: nil, identity: legacy)
    XCTAssertEqual(resumed.identity, legacy)
    await resumed.close()
    let resumedText = try String(contentsOf: resumed.fileURL, encoding: .utf8)
    XCTAssertTrue(resumedText.contains("\"run_start\""))
}
