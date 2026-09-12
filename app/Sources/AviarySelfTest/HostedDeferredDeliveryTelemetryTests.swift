import Foundation
import OpenTelemetrySdk

@testable import AviaryCore

private actor HostedDeferredDeliveryGate {
    typealias Continuation = AsyncThrowingStream<ChatEvent, Error>.Continuation

    private var nextCall = 0
    private var calls: [Int: Continuation] = [:]

    func install(_ continuation: Continuation) {
        calls[nextCall] = continuation
        nextCall += 1
    }

    func hasCall(_ index: Int) -> Bool { calls[index] != nil }

    @discardableResult
    func release(_ index: Int) -> Bool {
        guard let continuation = calls.removeValue(forKey: index) else { return false }
        continuation.yield(.done(stopReason: "stop"))
        continuation.finish()
        return true
    }

    func releaseAll() {
        let pending = Array(calls.values)
        calls.removeAll()
        for continuation in pending {
            continuation.yield(.done(stopReason: "stop"))
            continuation.finish()
        }
    }
}

private struct HostedDeferredDeliveryProvider: ChatProvider {
    let id = "hosted-deferred-delivery"
    let gate: HostedDeferredDeliveryGate

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await gate.install(continuation) }
        }
    }
}

private struct HostedDeferredCanonicalDelivery {
    let event: EventRef
    let sequence: Int
}

private func hostedDeferredWaitForCall(
    _ index: Int, gate: HostedDeferredDeliveryGate
) async throws {
    for _ in 0..<3_000 {
        if await gate.hasCall(index) { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw NSError(
        domain: "HostedDeferredDeliveryTelemetryTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "provider call \(index) was not installed"])
}

private func hostedDeferredWaitForLifecycle(
    _ expected: HostedInHouseWorkLifecycle, work: HostedInHouseWork
) async throws -> HostedInHouseWorkSnapshot {
    var snapshot = await work.snapshot()
    for _ in 0..<3_000 {
        if snapshot.lifecycle == expected { return snapshot }
        try await Task.sleep(nanoseconds: 5_000_000)
        snapshot = await work.snapshot()
    }
    throw NSError(
        domain: "HostedDeferredDeliveryTelemetryTests", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "hosted Work did not reach \(expected.rawValue)"])
}

private func hostedDeferredCommand(
    _ snapshot: HostedInHouseWorkSnapshot,
    id: String,
    client: ClientRef,
    command: SessionCommand
) throws -> HostedInHouseWorkCommand {
    HostedInHouseWorkCommand(
        work: snapshot.identity.work,
        session: SessionRef(snapshot.identity.sessionID),
        sessionAttachment: snapshot.sessionAttachment,
        client: client,
        commandID: id,
        causalCursor: try XCTUnwrap(snapshot.latestWorkCursor),
        command: command)
}

private func hostedDeferredWorkEvents(
    home: AgentHome, work: WorkRef
) throws -> [TimelineEvent] {
    let journal = JournalRef.work(work)
    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(work)),
        journal: journal,
        actor: TimelineActor(actorID: "deferred-telemetry-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        throw RunJournalBundleError.invalidJournal(
            journal: journal, reason: "deferred telemetry fixture has an invalid tail")
    }
    return read.records.map(\.event)
}

private func hostedDeferredAttribute(_ span: SpanData, _ key: String) -> String? {
    guard case .string(let value)? = span.attributes[key] else { return nil }
    return value
}

private func hostedDeferredEventAttribute(_ event: SpanData.Event, _ key: String) -> String? {
    guard case .string(let value)? = event.attributes[key] else { return nil }
    return value
}

private func hostedDeferredEventSequence(_ event: SpanData.Event) -> Int? {
    guard case .int(let value)? = event.attributes["aviary.event.sequence"] else { return nil }
    return value
}

private func testHostedDeferredDeliveryTelemetryKeepsAdmissionOrigins() async throws {
    let repo = try XCTUnwrap(EngineLocator.repoRoot())
    let host = try XCTUnwrap(RuntimeHost.bundledPython(repoRoot: repo, parentLifetimeLease: true))
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("ahdt-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let home = AgentHome(root: root)
    defer { try? FileManager.default.removeItem(at: home.root) }
    let persistedHost = try home.requirePersistedWorkHost()
    let identity = SessionWorkIdentity(
        sessionID: "deferred-telemetry-session",
        work: WorkRef(
            workHostID: persistedHost.workHostID,
            workID: "deferred-telemetry-work"),
        runID: "deferred-telemetry-run")
    let binding = WorkBinding(
        session: SessionRef(identity.sessionID),
        work: identity.work,
        workHost: persistedHost,
        sessionAttachment: SessionAttachmentRef("deferred-telemetry-attachment"))
    _ = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "deferred-telemetry-control")
    let gate = HostedDeferredDeliveryGate()
    let work = try await HostedInHouseWork.open(configuration: .init(
        home: home,
        cwd: "/tmp",
        model: ModelSpec(rpc: .object([
            "id": .string("deferred-test-model"), "provider": .string("deferred-test-provider"),
        ])),
        provider: HostedDeferredDeliveryProvider(gate: gate),
        runtimeHost: host,
        workRunBinding: WorkRunBinding(workBinding: binding, run: RunRef(identity.runID)),
        serviceActorID: "deferred-telemetry-service",
        systemPrompt: "You are a test agent.",
        maxIterations: 8))
    let client = ClientRef("deferred-telemetry-client")

    do {
        let (deliveryRefs, spans) = try await AviaryTelemetry.withRecording(waitingFor: { spans in
            spans.filter { $0.name == "aviary.command.runtime_delivery" }.count >= 2
                && spans.filter { $0.name == "aviary.command.canonical_delivery" }.count >= 3
        }) {
            var snapshot = await work.snapshot()
            let start = try hostedDeferredCommand(
                snapshot, id: "deferred-start", client: client, command: .start(prompt: ""))
            let startReceipt = try await work.submit(start)
            XCTAssertTrue(startReceipt.wasAdmitted)
            snapshot = try await hostedDeferredWaitForLifecycle(.idle, work: work)

            let send = try hostedDeferredCommand(
                snapshot, id: "deferred-send", client: client,
                command: .send(prompt: "initial input"))
            let sendReceipt = try await AviaryTelemetry.withSpan(
                "aviary.test.deferred.send_root", root: true
            ) {
                try await work.submit(send)
            }
            XCTAssertTrue(sendReceipt.wasAdmitted)
            try await hostedDeferredWaitForCall(0, gate: gate)

            snapshot = await work.snapshot()
            let queue = try hostedDeferredCommand(
                snapshot, id: "deferred-queue", client: client,
                command: .queueFollowUp(text: "queued input"))
            let queueReceipt = try await AviaryTelemetry.withSpan(
                "aviary.test.deferred.queue_root", root: true
            ) {
                try await work.submit(queue)
            }
            XCTAssertTrue(queueReceipt.wasAdmitted)
            XCTAssertTrue(queueReceipt.receipt.delivery.isQueued)

            snapshot = await work.snapshot()
            let steer = try hostedDeferredCommand(
                snapshot, id: "deferred-steer", client: client,
                command: .steer(text: "steering input"))
            let steerReceipt = try await AviaryTelemetry.withSpan(
                "aviary.test.deferred.steer_root", root: true
            ) {
                try await work.submit(steer)
            }
            XCTAssertTrue(steerReceipt.wasAdmitted)
            XCTAssertTrue(steerReceipt.receipt.delivery.isQueued)

            let releasedFirst = await gate.release(0)
            XCTAssertTrue(releasedFirst)
            try await hostedDeferredWaitForCall(1, gate: gate)
            let releasedSecond = await gate.release(1)
            XCTAssertTrue(releasedSecond)
            try await hostedDeferredWaitForCall(2, gate: gate)
            let releasedThird = await gate.release(2)
            XCTAssertTrue(releasedThird)
            snapshot = try await hostedDeferredWaitForLifecycle(.idle, work: work)

            let end = try hostedDeferredCommand(
                snapshot, id: "deferred-end", client: client, command: .endRun)
            let endReceipt = try await work.submit(end)
            XCTAssertTrue(endReceipt.wasAdmitted)
            let ended = try await hostedDeferredWaitForLifecycle(.ended, work: work)
            XCTAssertEqual(ended.journalHealth, .closed)

            let events = try hostedDeferredWorkEvents(home: home, work: identity.work)
            let projected = WorkReducer.reduce(events)
            let queueLedger = WorkServiceCommandLedgerIdentity.commandID(
                client: client, commandID: queue.commandID)
            let steerLedger = WorkServiceCommandLedgerIdentity.commandID(
                client: client, commandID: steer.commandID)
            let queueState = try XCTUnwrap(projected.commands[queueLedger])
            let steerState = try XCTUnwrap(projected.commands[steerLedger])
            func canonicalDelivery(_ state: WorkCommandSnapshot) throws
                -> HostedDeferredCanonicalDelivery
            {
                let ref = try XCTUnwrap(state.deliveryEventRef)
                let event = try XCTUnwrap(events.first {
                    $0.journal == ref.journal && $0.eventID == ref.eventID
                })
                return HostedDeferredCanonicalDelivery(event: ref, sequence: event.sequence)
            }
            let queueDelivery = try canonicalDelivery(queueState)
            let steerDelivery = try canonicalDelivery(steerState)
            return [queue.commandID: queueDelivery, steer.commandID: steerDelivery]
        }

        let sendRoot = try XCTUnwrap(spans.first {
            $0.name == "aviary.test.deferred.send_root"
        })
        let sendAgent = try XCTUnwrap(spans.first {
            $0.name == "aviary.agent.send" && $0.traceId == sendRoot.traceId
        })
        XCTAssertEqual(sendAgent.traceId, sendRoot.traceId)
        let sendLedgerHash = AviaryTelemetry.identity(
            WorkServiceCommandLedgerIdentity.commandID(
                client: client, commandID: "deferred-send"))
        let sendDelivery = try XCTUnwrap(spans.first {
            $0.name == "aviary.command.runtime_delivery"
                && hostedDeferredAttribute($0, "aviary.command.ledger.id") == sendLedgerHash
        })
        XCTAssertEqual(sendDelivery.traceId, sendRoot.traceId)
        XCTAssertEqual(sendDelivery.parentSpanId, sendAgent.spanId)
        XCTAssertTrue(sendDelivery.links.isEmpty)

        for (commandID, rootName) in [
            ("deferred-queue", "aviary.test.deferred.queue_root"),
            ("deferred-steer", "aviary.test.deferred.steer_root"),
        ] {
            let root = try XCTUnwrap(spans.first { $0.name == rootName })
            let commandHash = AviaryTelemetry.identity(commandID)
            let admission = try XCTUnwrap(spans.first {
                $0.name == "aviary.work.admission"
                    && hostedDeferredAttribute($0, "aviary.command.id") == commandHash
            })
            XCTAssertEqual(admission.traceId, root.traceId)
            XCTAssertEqual(admission.parentSpanId, root.spanId)

            let ledgerID = WorkServiceCommandLedgerIdentity.commandID(
                client: client, commandID: commandID)
            let ledgerHash = AviaryTelemetry.identity(ledgerID)
            let runtimeDelivery = try XCTUnwrap(spans.first {
                $0.name == "aviary.command.runtime_delivery"
                    && hostedDeferredAttribute($0, "aviary.command.ledger.id") == ledgerHash
            })
            XCTAssertEqual(runtimeDelivery.traceId, admission.traceId)
            XCTAssertEqual(runtimeDelivery.parentSpanId, admission.spanId)
            XCTAssertEqual(runtimeDelivery.links.count, 1)
            XCTAssertEqual(runtimeDelivery.links.first?.context.traceId, sendRoot.traceId)
            XCTAssertEqual(runtimeDelivery.links.first?.context.spanId, sendAgent.spanId)

            let canonical = try XCTUnwrap(spans.first {
                $0.name == "aviary.command.canonical_delivery"
                    && hostedDeferredAttribute($0, "aviary.command.ledger.id") == ledgerHash
            })
            XCTAssertEqual(canonical.traceId, admission.traceId)
            XCTAssertEqual(canonical.parentSpanId, runtimeDelivery.spanId)
            let canonicalEvent = try XCTUnwrap(canonical.events.first {
                $0.name == "aviary.command.canonical_delivery"
            })
            let delivery = try XCTUnwrap(deliveryRefs[commandID])
            XCTAssertEqual(
                hostedDeferredEventAttribute(canonicalEvent, "aviary.event.id"),
                AviaryTelemetry.identity(delivery.event.eventID))
            XCTAssertEqual(
                hostedDeferredEventAttribute(canonicalEvent, "aviary.event.journal.id"),
                AviaryTelemetry.journalIdentity(delivery.event.journal))
            XCTAssertEqual(hostedDeferredEventSequence(canonicalEvent), delivery.sequence)
        }
        for content in ["initial input", "queued input", "steering input"] {
            XCTAssertFalse(String(describing: spans).contains(content))
        }
    } catch {
        await gate.releaseAll()
        let snapshot = await work.snapshot()
        if snapshot.lifecycle != .ended, let cursor = snapshot.latestWorkCursor {
            let end = HostedInHouseWorkCommand(
                work: identity.work,
                session: SessionRef(identity.sessionID),
                sessionAttachment: snapshot.sessionAttachment,
                client: client,
                commandID: "deferred-cleanup-end",
                causalCursor: cursor,
                command: .endRun)
            _ = try? await work.submit(end)
            _ = try? await hostedDeferredWaitForLifecycle(.ended, work: work)
        }
        throw error
    }
}

private func testHostedDeferredDeliveryTelemetryNilOriginIsExplicitRoot() throws {
    let executing = try XCTUnwrap(AviaryTraceContext(
        traceparent: "00-11111111111111112222222222222222-3333333333333333-01"))
    let nilOrigin = HostedInHouseWork.deferredDeliveryTracePlan(
        origin: nil, executing: executing)
    XCTAssertNil(nilOrigin.parent)
    XCTAssertTrue(nilOrigin.root)
    XCTAssertEqual(nilOrigin.links, [executing])

    let origin = try XCTUnwrap(AviaryTraceContext(
        traceparent: "00-aaaaaaaaaaaaaaaabbbbbbbbbbbbbbbb-cccccccccccccccc-01"))
    let admitted = HostedInHouseWork.deferredDeliveryTracePlan(
        origin: origin, executing: executing)
    XCTAssertEqual(admitted.parent, origin)
    XCTAssertFalse(admitted.root)
    XCTAssertEqual(admitted.links, [executing])
    XCTAssertTrue(admitted.parent != executing)

    let sameContext = HostedInHouseWork.deferredDeliveryTracePlan(
        origin: origin, executing: origin)
    XCTAssertEqual(sameContext.parent, origin)
    XCTAssertFalse(sameContext.root)
    XCTAssertTrue(sameContext.links.isEmpty)
}

let casesHostedDeferredDeliveryTelemetry: [Case] = [
    ("hosted deferred delivery keeps Queue and Steer admission origins", {
        try await testHostedDeferredDeliveryTelemetryKeepsAdmissionOrigins()
    }),
    ("hosted deferred delivery with no origin cannot inherit an executing Send", {
        try testHostedDeferredDeliveryTelemetryNilOriginIsExplicitRoot()
    }),
]
