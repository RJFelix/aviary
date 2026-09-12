import Foundation
import OpenTelemetrySdk
@testable import AviaryCore

let casesAviaryTelemetryDelivery: [Case] = [
    ("telemetry canonical nondelivery records only committed evidence", {
        for failWrite in [false, true] {
            let (fixture, writer) = try await makeTelemetryDeliveryFixture()
            defer { try? FileManager.default.removeItem(at: fixture.home.root) }
            if failWrite { await fixture.bundle.injectWriterFailure(.beforeWrite, in: .work) }
            let (_, spans) = await AviaryTelemetry.withRecording {
                do {
                    try await fixture.bridge.markUndelivered(
                        fixture.intent, reason: "private nondelivery reason", at: Date())
                    XCTAssertFalse(failWrite)
                } catch { XCTAssertTrue(failWrite) }
                try? await fixture.bundle.closeChecked()
                try? await writer.closeChecked()
            }
            let events = try telemetryDeliveryWorkEvents(fixture)
            let span = try XCTUnwrap(spans.first { $0.name == "aviary.command.canonical_nondelivery" })
            let receipt = span.events.first { $0.name == "aviary.command.canonical_nondelivery" }
            if failWrite {
                XCTAssertNil(receipt)
                XCTAssertEqual(span.attributes["aviary.outcome"], .string("indeterminate"))
                XCTAssertEqual(span.events.first?.attributes["error.type"], .string("canonical_delivery"))
            } else {
                let event = try XCTUnwrap(events.first { $0.type == TimelineEventType.commandNotDelivered })
                XCTAssertEqual(receipt?.attributes["aviary.event.id"], .string(AviaryTelemetry.identity(event.eventID)))
                XCTAssertEqual(receipt?.attributes["aviary.event.sequence"], .int(event.sequence))
                XCTAssertEqual(receipt?.attributes["aviary.event.journal.id"], .string(AviaryTelemetry.journalIdentity(event.journal)))
                XCTAssertEqual(receipt?.attributes["aviary.delivery.state"], .string("not_delivered"))
                XCTAssertEqual(span.attributes["aviary.outcome"], .string("succeeded"))
            }
            XCTAssertFalse(String(describing: spans).contains("private nondelivery reason"))
        }
    }),
    ("telemetry canonical delivery records its committed event", {
        try await testAviaryTelemetryCanonicalDeliveryReceipt()
    }),
    ("telemetry failed canonical delivery does not fabricate a receipt", {
        try await testAviaryTelemetryFailedCanonicalDelivery()
    }),
    ("telemetry canonical delivery after-write uncertainty never invents a receipt", {
        let (fixture, writer) = try await makeTelemetryDeliveryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home.root) }
        await fixture.bundle.injectWriterFailure(.afterWriteBeforeSync, in: .work)
        let (_, spans) = await AviaryTelemetry.withRecording {
            do {
                try await fixture.bridge.markDelivered(fixture.intent, at: Date())
                XCTFail("unconfirmed append returned success")
            } catch { }
            try? await fixture.bundle.closeChecked()
            try? await writer.closeChecked()
        }
        let events = try telemetryDeliveryWorkEvents(fixture)
        XCTAssertEqual(events.filter { $0.type == TimelineEventType.commandDelivered }.count, 1)
        let span = try XCTUnwrap(spans.first { $0.name == "aviary.command.canonical_delivery" })
        XCTAssertEqual(span.attributes["aviary.outcome"], .string("indeterminate"))
        XCTAssertFalse(span.events.contains { $0.name == "aviary.command.canonical_delivery" })
    }),
]

private func telemetryDeliveryModel() -> ModelSpec {
    ModelSpec(rpc: .object([
        "id": .string("delivery-test-model"),
        "provider": .string("delivery-test-provider"),
    ]))
}

private struct TelemetryDeliveryFixture {
    let home: AgentHome
    let identity: SessionWorkIdentity
    let bundle: RunJournalBundle
    let bridge: NativeSessionCommandJournal
    let intent: SessionCommandIntent
}

private func telemetryDeliveryAttributeString(_ span: SpanData, key: String) -> String? {
    guard case .string(let value)? = span.attributes[key] else { return nil }
    return value
}

private func telemetryDeliveryEventAttributeString(
    _ event: SpanData.Event, key: String
) -> String? {
    guard case .string(let value)? = event.attributes[key] else { return nil }
    return value
}

private func telemetryDeliveryEventAttributeInt(
    _ event: SpanData.Event, key: String
) -> Int? {
    guard case .int(let value)? = event.attributes[key] else { return nil }
    return value
}

private func makeTelemetryDeliveryFixture() async throws -> (
    TelemetryDeliveryFixture, SessionWriter
) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "aviary-telemetry-delivery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let home = AgentHome(root: root)
    let hostID = try home.requirePersistedWorkHostID()
    let model = telemetryDeliveryModel()
    let identity = SessionWorkIdentity(
        sessionID: "telemetry-delivery-session",
        work: WorkRef(workHostID: hostID, workID: "telemetry-delivery-work"),
        runID: "telemetry-delivery-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "telemetry-delivery-agent",
        modelID: model.qualifiedID,
        makeAttachmentID: { "telemetry-delivery-attachment" })
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: model, identity: identity)
    let bridge = try NativeSessionCommandJournal(
        identity: identity, nativeJournal: bundle, legacyProjection: writer)
    let admitted = AdmittedSessionCommand(
        identity: identity, commandID: "telemetry-delivery-command", sequence: 1,
        actorID: "telemetry-delivery-client", command: .send(prompt: "delivery prompt"),
        previousState: .idle, state: .running, causalCursor: await bundle.latestWorkCursor)
    let intent = SessionCommandIntent(admitted: admitted)
    try await bridge.commitIntent(intent)
    return (
        TelemetryDeliveryFixture(
            home: home, identity: identity, bundle: bundle, bridge: bridge, intent: intent),
        writer)
}

private func telemetryDeliveryWorkEvents(
    _ fixture: TelemetryDeliveryFixture
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.identity.work)),
        journal: fixture.bundle.workJournal,
        actor: TimelineActor(actorID: "telemetry-delivery-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertNil(read.quarantinedSuffix)
    XCTAssertNil(read.truncatedTail)
    return read.records.map(\.event)
}

private func testAviaryTelemetryCanonicalDeliveryReceipt() async throws {
    let (fixture, writer) = try await makeTelemetryDeliveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    let (_, spans) = try await AviaryTelemetry.withRecording {
        try await fixture.bridge.markDelivered(fixture.intent, at: Date())
        do {
            try await fixture.bridge.markDelivered(fixture.intent, at: Date())
            XCTFail("a duplicate canonical delivery must be rejected")
        } catch {
            // The second attempt must not append or emit another success receipt.
        }
        _ = try await fixture.bundle.finishRun()
        try await fixture.bundle.closeChecked()
        try await writer.closeChecked()
    }

    let events = try telemetryDeliveryWorkEvents(fixture)
    let deliveries = events.filter { $0.type == TimelineEventType.commandDelivered }
    XCTAssertEqual(deliveries.count, 1)
    let delivery = try XCTUnwrap(deliveries.first)
    XCTAssertEqual(spans.filter {
        $0.name == "aviary.command.canonical_delivery" && $0.attributes["aviary.outcome"] == .string("rejected")
    }.count, 1)
    let span = try XCTUnwrap(spans.first {
        $0.name == "aviary.command.canonical_delivery"
            && telemetryDeliveryAttributeString($0, key: "aviary.outcome") == "succeeded"
    })
    XCTAssertEqual(
        telemetryDeliveryAttributeString(span, key: "aviary.command.ledger.id"),
        AviaryTelemetry.identity(fixture.intent.commandID))
    let receipt = try XCTUnwrap(span.events.first {
        $0.name == "aviary.command.canonical_delivery"
    })
    XCTAssertEqual(receipt.attributes["aviary.event.journal.id"], .string(AviaryTelemetry.journalIdentity(delivery.journal)))
    XCTAssertEqual(
        telemetryDeliveryEventAttributeString(receipt, key: "aviary.event.id"),
        AviaryTelemetry.identity(delivery.eventID))
    XCTAssertEqual(
        telemetryDeliveryEventAttributeString(receipt, key: "aviary.delivery.state"),
        "delivered")
    XCTAssertEqual(
        telemetryDeliveryEventAttributeInt(receipt, key: "aviary.event.sequence"),
        delivery.sequence)
}

private func testAviaryTelemetryFailedCanonicalDelivery() async throws {
    let (fixture, writer) = try await makeTelemetryDeliveryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home.root) }
    await fixture.bundle.injectWriterFailure(.beforeWrite, in: .work)
    let (_, spans) = await AviaryTelemetry.withRecording {
        do {
            try await fixture.bridge.markDelivered(fixture.intent, at: Date())
            XCTFail("a failed canonical append must be reported")
        } catch {
            // The failure is the point of this fixture; the telemetry span must not claim delivery.
        }
        try? await writer.closeChecked()
        try? await fixture.bundle.closeChecked()
    }

    let events = try telemetryDeliveryWorkEvents(fixture)
    XCTAssertTrue(events.filter { $0.type == TimelineEventType.commandDelivered }.isEmpty)
    let span = try XCTUnwrap(spans.first { $0.name == "aviary.command.canonical_delivery" })
    XCTAssertEqual(telemetryDeliveryAttributeString(span, key: "aviary.outcome"), "indeterminate")
    XCTAssertTrue(span.events.filter {
        $0.name == "aviary.command.canonical_delivery"
            && telemetryDeliveryEventAttributeString($0, key: "aviary.delivery.state") == "delivered"
    }.isEmpty)
}
