import Foundation

@testable import AviaryCore

/// A deterministic provider boundary for adapter tests. Each model call stays suspended until
/// the test releases it, which makes the distinction between an active turn, a queued follow-up,
/// steering at the next model boundary, and cancellation observable without sleeps or a live API.
private final class InteractionScriptProvider: ChatProvider, @unchecked Sendable {
    let id = "phase0-interaction-script"

    private let lock = NSLock()
    private var waiting: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
    private var received: [ChatRequest] = []

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            received.append(request)
            waiting.append(continuation)
            lock.unlock()
        }
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return received.count
    }

    var requests: [ChatRequest] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func releaseNext(text: String, thinking: String? = nil) {
        lock.lock()
        guard !waiting.isEmpty else {
            lock.unlock()
            return
        }
        let continuation = waiting.removeFirst()
        lock.unlock()

        if let thinking { continuation.yield(.thinkingDelta(thinking)) }
        continuation.yield(.textDelta(text))
        continuation.yield(.usage(ProviderUsage.RawReport()))
        continuation.yield(.done(stopReason: "stop"))
        continuation.finish()
    }

    func waitForCall(_ expected: Int) async -> Bool {
        for _ in 0..<200 {
            if callCount >= expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

/// The smallest adapter-shaped consumer shared by the test and the production drivers: it
/// turns Agent events into one stable live row, retains writer-confirmed mappings, and rebuilds
/// its projection from the parser on a cold reload. Keeping this seam in the executable test
/// target avoids making SwiftUI/AppModel a prerequisite for deterministic core verification.
private final class InteractionAdapterProbe: @unchecked Sendable {
    let overlay = LiveTranscriptOverlay()

    private let lock = NSLock()
    private var turnNumber = 0
    private var turnID: LiveTranscriptTurnID?
    private var messageID: LiveTranscriptMessageID?
    private var revision: UInt64 = 0
    private var pendingCommits: [LiveTranscriptIdentity: String] = [:]
    private var recordedEvents: [String] = []

    func consume(_ event: Agent.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .started:
            recordedEvents.append("started")
        case .inputCommitted:
            recordedEvents.append("input-committed")
        case .textDelta(let text):
            ensureTurn()
            apply(.text(text), lifecycle: .streaming)
        case .thinkingDelta(let text):
            ensureTurn()
            apply(.thinking(text), lifecycle: .streaming)
        case .turnFinished(let durableID, _, _):
            guard let turnID, let messageID else { return }
            revision &+= 1
            _ = overlay.apply(
                turnID: turnID.rawValue, messageID: messageID.rawValue,
                lifecycle: .completed, revision: revision)
            pendingCommits[LiveTranscriptIdentity(turnID: turnID, messageID: messageID)] = durableID
            self.turnID = nil
            self.messageID = nil
            revision = 0
            recordedEvents.append("turn-finished")
        case .finished(let reason):
            if let turnID, let messageID {
                revision &+= 1
                _ = overlay.apply(
                    turnID: turnID.rawValue, messageID: messageID.rawValue,
                    lifecycle: reason == "cancelled" ? .cancelled : .completed,
                    revision: revision)
            }
            recordedEvents.append("finished:\(reason)")
        case .steered(let text):
            recordedEvents.append("steered:\(text)")
        case .failed:
            recordedEvents.append("failed")
        default:
            break
        }
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
    }

    func waitForEvent(_ expected: String) async -> Bool {
        for _ in 0..<200 {
            if events.contains(expected) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    private func ensureTurn() {
        guard turnID == nil else { return }
        turnNumber += 1
        turnID = LiveTranscriptTurnID("probe-turn-\(turnNumber)")
        messageID = LiveTranscriptMessageID("probe-message-\(turnNumber)")
        revision = 0
    }

    private func apply(
        _ content: LiveTranscriptContentDelta, lifecycle: LiveTranscriptLifecycle
    ) {
        guard let turnID, let messageID else { return }
        revision &+= 1
        _ = overlay.apply(
            turnID: turnID.rawValue, messageID: messageID.rawValue,
            content: content, lifecycle: lifecycle, revision: revision)
    }

    /// Reconcile the exact parser snapshot and apply writer-confirmed mappings. This is the
    /// reload operation a GUI performs; no provider content is used to guess a durable row.
    func reload(_ parsed: Transcript) {
        lock.lock()
        let commits = pendingCommits
        pendingCommits.removeAll()
        lock.unlock()

        _ = overlay.reconcile(committed: parsed.items)
        for (identity, durableID) in commits {
            guard let item = parsed.items.first(where: { $0.id == durableID }) else { continue }
            _ = overlay.commit(identity: identity, committedItem: item)
        }
    }
}

enum Phase0InteractionSelfTests {
    static func run() async throws {
        try await longTurnCoversStreamingQueueSteerAndColdParity()
        try await cancellationIsAcknowledgedAndSurvivesReload()
    }

    private static func longTurnCoversStreamingQueueSteerAndColdParity() async throws {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let provider = InteractionScriptProvider()
        let agent = Agent(
            provider: provider, host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "test"))
        let probe = InteractionAdapterProbe()
        await agent.observe { event in probe.consume(event) }

        let controller = SessionCommandController(
            identity: SessionWorkIdentity(
                sessionID: "interaction-session",
                work: WorkRef(workHostID: "interaction-host", workID: "interaction-work"),
                runID: "interaction-run"),
            capabilities: Agent.inHouseCommandCapabilities)
        try await makeIdle(controller)

        guard case .accepted(let sendCommand) = await controller.admit(
            .send(prompt: "long turn"), actorID: "gui", commandID: "send-long")
        else { throw InteractionFailure("the scripted turn should be admitted") }
        _ = await controller.awaitDispatch(commandID: sendCommand.commandID)

        let sending = Task { await agent.send("long turn") }
        guard await provider.waitForCall(1), await probe.waitForEvent("input-committed") else {
            sending.cancel()
            throw InteractionFailure("the first scripted model call did not start")
        }
        XCTAssertTrue(
            await controller.acknowledgeDispatched(commandID: sendCommand.commandID),
            "the send dispatch is released once durable input crosses")
        XCTAssertEqual(provider.callCount, 1, "the long turn must be held at its first model call")

        let steer = await controller.admit(
            .steer(text: "change course now"), actorID: "gui", commandID: "steer-1")
        guard case .accepted = steer else {
            throw InteractionFailure("steering should be admitted while the turn is active")
        }
        XCTAssertTrue(await agent.steer("change course now"))
        _ = await controller.awaitDispatch(commandID: "steer-1")
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "steer-1"))

        let queued = await controller.admit(
            .queueFollowUp(text: "do this after"), actorID: "gui", commandID: "queue-1")
        guard case .accepted = queued else {
            throw InteractionFailure("a follow-up should be admitted while the turn is active")
        }
        XCTAssertTrue(await agent.queueFollowUp("do this after"))
        _ = await controller.awaitDispatch(commandID: "queue-1")
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: "queue-1"))

        provider.releaseNext(text: "first answer", thinking: "thinking first")
        guard await provider.waitForCall(2) else {
            sending.cancel()
            throw InteractionFailure("the steered model call did not start")
        }
        let liveAfterFirst = probe.overlay.snapshot
        XCTAssertTrue(liveAfterFirst.items.contains { $0.plainText.contains("first answer") })
        XCTAssertTrue(
            liveAfterFirst.live.contains { $0.lifecycle == .completed },
            "a durable callback may precede the cold parser; retain the completed overlay")

        provider.releaseNext(text: "steered answer")
        guard await provider.waitForCall(3) else {
            sending.cancel()
            throw InteractionFailure("the queued follow-up model call did not start")
        }
        let requestsBeforeFollowUp = provider.requests
        guard requestsBeforeFollowUp.count >= 3 else {
            throw InteractionFailure("expected three ordered model calls")
        }
        let secondUsers = requestsBeforeFollowUp[1].messages
            .filter { $0.role == .user }.map(\.plainText)
        XCTAssertTrue(secondUsers.contains("change course now"), "steering belongs to next call")
        XCTAssertFalse(secondUsers.contains("do this after"), "queue must not steer the active call")

        provider.releaseNext(text: "queued answer")
        XCTAssertEqual(await sending.value, .completed)
        let requests = provider.requests
        let thirdUsers = requests[2].messages.filter { $0.role == .user }.map(\.plainText)
        XCTAssertTrue(thirdUsers.contains("do this after"), "follow-up belongs after the prior turn")

        XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: "send-long"))
        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        probe.reload(parsed)
        XCTAssertEqual(
            probe.overlay.snapshot.items.map(\.id), parsed.items.map(\.id),
            "cold reload and the live adapter must converge without duplicate rows")
        XCTAssertEqual(probe.overlay.snapshot.live.count, 0)
        await writer.close()
    }

    private static func cancellationIsAcknowledgedAndSurvivesReload() async throws {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let provider = InteractionScriptProvider()
        let agent = Agent(
            provider: provider, host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "test"))
        let probe = InteractionAdapterProbe()
        await agent.observe { event in probe.consume(event) }
        let controller = SessionCommandController(
            identity: SessionWorkIdentity(
                sessionID: "cancel-session",
                work: WorkRef(workHostID: "cancel-host", workID: "cancel-work"),
                runID: "cancel-run"),
            capabilities: Agent.inHouseCommandCapabilities)
        try await makeIdle(controller)

        guard case .accepted(let sendCommand) = await controller.admit(
            .send(prompt: "cancel me"), actorID: "gui", commandID: "send-cancel")
        else { throw InteractionFailure("the cancellable turn should be admitted") }
        _ = await controller.awaitDispatch(commandID: sendCommand.commandID)
        let sending = Task { await agent.send("cancel me") }
        guard await provider.waitForCall(1), await probe.waitForEvent("input-committed") else {
            sending.cancel()
            throw InteractionFailure("the cancellable model call did not start")
        }
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: sendCommand.commandID))

        guard case .accepted(let cancelCommand) = await controller.admit(
            .cancel(scope: .agentLoop), actorID: "gui", commandID: "cancel-1")
        else { throw InteractionFailure("agent-loop cancellation should be admitted") }
        _ = await controller.awaitDispatch(commandID: cancelCommand.commandID)
        XCTAssertTrue(await agent.requestCancellation(.agentLoop))
        provider.releaseNext(text: "late provider answer")
        await agent.waitUntilQuiescent()
        XCTAssertTrue(await controller.acknowledgeCancellation(commandID: cancelCommand.commandID))
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: cancelCommand.commandID))
        XCTAssertEqual(await sending.value, .cancelled)
        XCTAssertEqual(await controller.state, .idle)
        XCTAssertTrue(probe.events.contains("finished:cancelled"))
        XCTAssertFalse(probe.events.contains("failed"))

        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(parsed.outcome?.state, .cancelled)
        probe.reload(parsed)
        XCTAssertEqual(probe.overlay.snapshot.committed.map(\.id), parsed.items.map(\.id))
        await writer.close()
    }

    private static func makeIdle(_ controller: SessionCommandController) async throws {
        guard case .accepted(let start) = await controller.admit(
            .start(prompt: "initial"), actorID: "gui", commandID: "start")
        else { throw InteractionFailure("start should be admitted") }
        _ = await controller.awaitDispatch(commandID: start.commandID)
        XCTAssertTrue(await controller.acknowledgeDispatched(commandID: start.commandID))
        XCTAssertTrue(await controller.acknowledgePreparation(commandID: start.commandID))
        XCTAssertTrue(await controller.acknowledgeTurnFinished(commandID: start.commandID))
    }

    private struct InteractionFailure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
