import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf
@testable import AviaryCore

private final class TelemetryCaptureHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        lock.lock(); requests.append(request); lock.unlock()
        if succeeds {
            completion(.success(HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!))
        } else { completion(.failure(TelemetryFixtureError())) }
    }
    func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
private struct TelemetryFixtureError: Error {}

let casesAviaryTelemetry: [Case] = [
    ("telemetry: unsampled context survives asynchronous and synchronous scopes", {
        let wire = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"
        let parent = try XCTUnwrap(AviaryTraceContext(traceparent: wire))
        let (_, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.unsampled", parent: parent) {
                XCTAssertEqual(AviaryTelemetry.traceparent, wire)
                AviaryTelemetry.event("aviary.test.no_export")
                AviaryTelemetry.outcome("failed")
                AviaryTelemetry.withSynchronousSpan("aviary.test.unsampled_sync") {
                    XCTAssertEqual(AviaryTelemetry.traceparent, wire)
                    AviaryTelemetry.event("aviary.test.no_export")
                }
                await AviaryTelemetry.withSpan("aviary.test.unsampled_async", kind: .client) {
                    XCTAssertEqual(AviaryTelemetry.traceparent, wire)
                }
                XCTAssertEqual(AviaryTelemetry.traceparent, wire)
            }
            XCTAssertNil(AviaryTelemetry.traceparent)
        }
        XCTAssertTrue(spans.isEmpty)
        let (_, rooted) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.unsampled_outer", parent: parent) {
                await AviaryTelemetry.withSpan("aviary.test.independent", root: true) {
                    XCTAssertNotEqual(AviaryTelemetry.traceparent, wire)
                }
                XCTAssertEqual(AviaryTelemetry.traceparent, wire)
            }
        }
        XCTAssertEqual(rooted.count, 1)
        XCTAssertNil(rooted.first?.parentSpanId)
    }),
    ("telemetry: completed quiet diagnostics preserve duration without lending context", {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let (_, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.outer") {
                let parent = AviaryTelemetry.traceparent
                AviaryTelemetry.completedSpan("aviary.test.quiet", kind: .client,
                    attributes: ["raw.error": .string("secret-error")],
                    elapsedSeconds: 1.75, outcome: "unavailable", finishedAt: end)
                XCTAssertEqual(AviaryTelemetry.traceparent, parent)
                AviaryTelemetry.completedSpan("aviary.test.invalid", kind: .client,
                    attributes: [:], elapsedSeconds: .nan, outcome: "failed")
                AviaryTelemetry.completedSpan("aviary.test.before_epoch", kind: .client,
                    attributes: [:], elapsedSeconds: 5, outcome: "failed",
                    finishedAt: Date(timeIntervalSince1970: 1))
                AviaryTelemetry.completedSpan("aviary.test.unrepresentable", kind: .client,
                    attributes: [:], elapsedSeconds: 1, outcome: "failed",
                    finishedAt: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude))
            }
        }
        XCTAssertEqual(spans.count, 2)
        let quiet = try XCTUnwrap(spans.first { $0.name == "aviary.test.quiet" })
        let outer = try XCTUnwrap(spans.first { $0.name == "aviary.test.outer" })
        XCTAssertNil(quiet.parentSpanId)
        XCTAssertNotEqual(quiet.traceId, outer.traceId)
        XCTAssertEqual(quiet.startTime, end.addingTimeInterval(-1.75))
        XCTAssertEqual(quiet.endTime, end)
        XCTAssertEqual(quiet.status, .error(description: "unavailable"))
        XCTAssertNil(quiet.attributes["raw.error"])
    }),
    ("telemetry: production shutdown is shared and cannot stop a recording scope", {
        AviaryTelemetry.configure(serviceName: "aviary", environment: [
            "AVIARY_OTEL_ENABLED": "1",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://127.0.0.1:1/v1/traces",
        ])
        let (_, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.before_shutdown") {}
            async let first = AviaryTelemetry.shutdown(maximumDuration: 0)
            async let second = AviaryTelemetry.shutdown(maximumDuration: 1)
            let receipts = await (first, second)
            XCTAssertNotNil(receipts.0)
            XCTAssertEqual(receipts.0, receipts.1)
            XCTAssertEqual(receipts.0?.outcome, .quiesced)
            await AviaryTelemetry.withSpan("aviary.test.after_shutdown") {}
        }
        XCTAssertEqual(Set(spans.map(\.name)), ["aviary.test.before_shutdown", "aviary.test.after_shutdown"])
        XCTAssertEqual(AviaryTelemetry.configurationStatus, "stopped")
        XCTAssertEqual(AviaryTelemetry.exportDiagnostics?.drainStarts, 1)
        XCTAssertEqual(AviaryTelemetry.exportDiagnostics?.exportBatchAttempts, 0)
        let before = AviaryTelemetry.exportDiagnostics
        let value = await AviaryTelemetry.withSpan("aviary.test.stopped_production", root: true) {
            XCTAssertNil(AviaryTelemetry.traceparent)
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(AviaryTelemetry.exportDiagnostics?.sampledEndedSpans, before?.sampledEndedSpans)
        XCTAssertEqual(AviaryTelemetry.exportDiagnostics?.exportBatchAttempts, before?.exportBatchAttempts)
    }),
    ("telemetry: canonical joins include complete journal identity", {
        let journals: [JournalRef] = [
            .session(SessionRef("private-session"), journalID: "private-journal", authority: TimelineAuthorityRef("private-authority")),
            .session(SessionRef("private-session"), journalID: "private-journal", authority: TimelineAuthorityRef("other-authority")),
            .session(SessionRef("other-session"), journalID: "private-journal", authority: TimelineAuthorityRef("private-authority")),
            .session(SessionRef("private-session"), journalID: "other-journal", authority: TimelineAuthorityRef("private-authority")),
            .work(WorkRef(workHostID: "private-authority", workID: "private-session"), journalID: "private-journal"),
            .workHost(WorkHostRef("private-authority"), journalID: "private-journal"),
        ]
        func commit(_ journal: JournalRef) -> TimelineJournalCommit {
            TimelineJournalCommit(
                eventRef: EventRef(journal: journal, eventID: "same-event"),
                cursor: JournalCursor(journal: journal, eventID: "same-event", sequence: 7))
        }
        XCTAssertEqual(Set(journals.map(AviaryTelemetry.journalIdentity)).count, journals.count)
        let a = JournalRef.session(SessionRef("c"), journalID: "a:b", authority: TimelineAuthorityRef("d"))
        let b = JournalRef.session(SessionRef("c"), journalID: "a", authority: TimelineAuthorityRef("b:d"))
        XCTAssertNotEqual(AviaryTelemetry.journalIdentity(a), AviaryTelemetry.journalIdentity(b))
        let (_, spans) = await AviaryTelemetry.withRecording {
            for journal in journals {
                await AviaryTelemetry.withSpan("aviary.test.canonical", attributes:
                    AviaryTelemetry.canonicalReferenceAttributes(commit(journal))) {}
            }
            await AviaryTelemetry.withSpan("aviary.test.canonical_pair", attributes:
                AviaryTelemetry.canonicalReferenceAttributes(commit(journals[0])).merging(
                    AviaryTelemetry.canonicalReferenceAttributes(commit(journals[1]), role: .actionStarted)
                ) { _, exact in exact }) {}
        }
        for span in spans where span.name == "aviary.test.canonical" {
            XCTAssertEqual(span.attributes["aviary.event.id"], .string(AviaryTelemetry.identity("same-event")))
            XCTAssertEqual(span.attributes["aviary.event.sequence"], .int(7))
            XCTAssertNotNil(span.attributes["aviary.event.journal.id"])
        }
        let pair = try XCTUnwrap(spans.first { $0.name == "aviary.test.canonical_pair" })
        XCTAssertEqual(pair.attributes["aviary.event.journal.id"], .string(AviaryTelemetry.journalIdentity(journals[0])))
        XCTAssertEqual(pair.attributes["aviary.action.started.journal.id"], .string(AviaryTelemetry.journalIdentity(journals[1])))
        XCTAssertFalse(String(describing: spans).contains("private-"))
        let wrong = TimelineJournalCommit(eventRef: commit(journals[0]).eventRef, cursor: commit(journals[1]).cursor)
        XCTAssertTrue(AviaryTelemetry.canonicalReferenceAttributes(wrong).isEmpty)
        let wrongEvent = TimelineJournalCommit(eventRef: commit(journals[0]).eventRef,
            cursor: JournalCursor(journal: journals[0], eventID: "another", sequence: 7))
        XCTAssertTrue(AviaryTelemetry.canonicalReferenceAttributes(wrongEvent).isEmpty)
        let oversized = JournalRef.session(SessionRef(String(repeating: "x", count: 4097)), authority: TimelineAuthorityRef("host"))
        XCTAssertTrue(AviaryTelemetry.canonicalReferenceAttributes(commit(oversized)).isEmpty)
    }),
    ("telemetry: Work joins include unambiguous host identity", {
        let a = WorkRef(workHostID: "host/a", workID: "b")
        let b = WorkRef(workHostID: "host", workID: "a/b")
        let c = WorkRef(workHostID: "other", workID: "b")
        XCTAssertNotEqual(AviaryTelemetry.workIdentity(a), AviaryTelemetry.workIdentity(b))
        XCTAssertNotEqual(AviaryTelemetry.workIdentity(a), AviaryTelemetry.workIdentity(c))
        XCTAssertEqual(AviaryTelemetry.workIdentity(a), AviaryTelemetry.workIdentity(a))
        XCTAssertEqual(AviaryTelemetry.workIdentity(a).utf8.count, 64)
    }),
    ("telemetry: deferred roots have bounded explicit links", {
        let (_, spans) = try await AviaryTelemetry.withRecording {
            let contexts = try (0..<12).map { index in
                try AviaryTelemetry.withSynchronousSpan("aviary.test.origin_\(index)", root: true) {
                    try XCTUnwrap(AviaryTelemetry.context)
                }
            }
            await AviaryTelemetry.withSpan("aviary.test.unrelated", root: true) {
                await AviaryTelemetry.withSpan("aviary.test.deferred", root: true,
                    links: [contexts[0]] + contexts) {
                    await AviaryTelemetry.withSpan("aviary.test.deferred_child") {
                        AviaryTelemetry.outcome("completed")
                    }
                }
            }
        }
        let deferred = try XCTUnwrap(spans.first { $0.name == "aviary.test.deferred" })
        let unrelated = try XCTUnwrap(spans.first { $0.name == "aviary.test.unrelated" })
        let child = try XCTUnwrap(spans.first { $0.name == "aviary.test.deferred_child" })
        XCTAssertNil(deferred.parentSpanId)
        XCTAssertNotEqual(deferred.traceId, unrelated.traceId)
        XCTAssertEqual(child.parentSpanId, deferred.spanId)
        XCTAssertEqual(child.traceId, deferred.traceId)
        XCTAssertEqual(deferred.links.count, 7, "Only first eight inputs are traversed, with duplicates removed")
        for index in 0..<7 {
            let origin = try XCTUnwrap(spans.first { $0.name == "aviary.test.origin_\(index)" })
            XCTAssertEqual(deferred.links[index].context.traceId, origin.traceId)
            XCTAssertEqual(deferred.links[index].context.spanId, origin.spanId)
            XCTAssertTrue(deferred.links[index].attributes.isEmpty)
        }
        let client = TelemetryCaptureHTTP()
        let exporter = AviaryOTLPBatchExporter(
            endpoint: URL(string: "http://127.0.0.1:4318/v1/traces")!, httpClient: client)
        XCTAssertEqual(await exporter.export(spans: [deferred], explicitTimeout: 1), .success)
        let body = try XCTUnwrap(client.recorded().first?.httpBody)
        let wire = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: body)
        let exported = try XCTUnwrap(wire.resourceSpans.flatMap { $0.scopeSpans }.flatMap { $0.spans }.first)
        XCTAssertTrue(exported.parentSpanID.isEmpty)
        XCTAssertEqual(exported.links.count, deferred.links.count)
        for (link, expected) in zip(exported.links, deferred.links) {
            var traceID = Data(count: 16)
            var spanID = Data(count: 8)
            expected.context.traceId.copyBytesTo(dest: &traceID, destOffset: 0)
            expected.context.spanId.copyBytesTo(dest: &spanID, destOffset: 0)
            XCTAssertEqual(link.traceID, traceID)
            XCTAssertEqual(link.spanID, spanID)
            XCTAssertTrue(link.attributes.isEmpty)
        }
    }),
    ("telemetry: inclusive cached input is not charged twice", {
        let model = ModelSpec(rpc: .object([
            "id": .string("model"), "provider": .string("provider"),
            "cost": .object(["input": .number(2), "output": .number(4),
                "cacheRead": .number(0.2), "cacheWrite": .number(3)])]))
        let (_, spans) = await AviaryTelemetry.withRecording {
            for accounting in [ProviderUsageAccounting.cacheInclusive, .cacheExclusive, .unknown] {
                await AviaryTelemetry.withSpan("aviary.test.\(accounting.rawValue)") {
                    var usage = Usage()
                    usage.input = 100; usage.cacheRead = 50; usage.cacheWrite = 10
                    usage.output = 20; usage.totalTokens = 120
                    var measurement = AviaryProviderTelemetry()
                    measurement.observe(.usage(usage))
                    measurement.record(model: model, accounting: accounting)
                }
            }
            await AviaryTelemetry.withSpan("aviary.test.inconsistent_cache") {
                var usage = Usage(); usage.input = 1; usage.cacheRead = Int.max
                var measurement = AviaryProviderTelemetry()
                measurement.observe(.usage(usage))
                measurement.record(model: model, accounting: .cacheInclusive)
            }
        }
        for (kind, expected) in [("cache_inclusive", 0.0002), ("cache_exclusive", 0.00032)] {
            let span = try XCTUnwrap(spans.first { $0.name == "aviary.test.\(kind)" })
            let price = try XCTUnwrap(span.events.first { $0.name == "aviary.agent.provider.price" })
            guard case .double(let cost)? = price.attributes["aviary.pricing.estimated_usd"] else {
                XCTFail("Missing accounted estimate"); continue
            }
            XCTAssertTrue(abs(cost - expected) < 0.000000001)
            XCTAssertEqual(price.attributes["aviary.pricing.cache_read_per_million_usd"], .double(0.2))
        }
        for name in ["unknown", "inconsistent_cache"] {
            let span = try XCTUnwrap(spans.first { $0.name == "aviary.test.\(name)" })
            let price = try XCTUnwrap(span.events.first { $0.name == "aviary.agent.provider.price" })
            XCTAssertEqual(price.attributes["aviary.pricing.state"], .string("unavailable"))
            XCTAssertNil(price.attributes["aviary.pricing.estimated_usd"])
        }
    }),
    ("telemetry: provider measurements replace usage and retain pricing provenance", {
        let model = ModelSpec(rpc: .object([
            "id": .string("private/model"), "provider": .string("private-provider"),
            "cost": .object(["input": .number(2), "output": .number(4)])]))
        let (_, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.provider") {
                var measurement = AviaryProviderTelemetry(now: 100)
                measurement.observe(.requestBody(.string("secret request")), now: 200)
                measurement.observe(.textDelta(""), now: 300)
                measurement.observe(.thinkingDelta("secret thinking"), now: 1_000_000_100)
                measurement.observe(.textDelta("secret output"), now: 2_000_000_100)
                var usage = Usage()
                usage.input = 100; usage.output = 1; usage.cacheRead = 50; usage.cacheWrite = 10
                usage.totalTokens = 161
                measurement.observe(.usage(usage))
                usage.output = 20; usage.totalTokens = 180; usage.reasoning = 5
                measurement.observe(.usage(usage))
                measurement.observe(.done(stopReason: "private stop reason"))
                measurement.record(model: model, accounting: .cacheExclusive)
            }
        }
        let span = try XCTUnwrap(spans.first)
        let usage = try XCTUnwrap(span.events.first { $0.name == "aviary.agent.provider.measurements" })
        XCTAssertEqual(usage.attributes["aviary.usage.input_tokens"], .int(100))
        XCTAssertEqual(usage.attributes["aviary.usage.output_tokens"], .int(20))
        XCTAssertEqual(usage.attributes["aviary.usage.total_tokens"], .int(180))
        XCTAssertEqual(usage.attributes["aviary.usage.reasoning_tokens"], .int(5))
        XCTAssertEqual(usage.attributes["aviary.usage.updates"], .int(2))
        XCTAssertEqual(usage.attributes["aviary.provider.first_output.seconds"], .double(1))
        XCTAssertEqual(usage.attributes["aviary.provider.done_observed"], .bool(true))
        let price = try XCTUnwrap(span.events.first { $0.name == "aviary.agent.provider.price" })
        XCTAssertEqual(price.attributes["aviary.pricing.source"], .string("model_spec"))
        XCTAssertEqual(price.attributes["aviary.pricing.state"], .string("estimated"))
        XCTAssertEqual(price.attributes["aviary.pricing.cache_fallback"], .bool(true))
        guard case .double(let cost)? = price.attributes["aviary.pricing.estimated_usd"] else {
            XCTFail("Missing configured-rate estimate"); return
        }
        XCTAssertTrue(abs(cost - 0.0004) < 0.000000001)
        XCTAssertNotNil(price.attributes["aviary.pricing.id"])
        XCTAssertFalse(String(describing: span.events).contains("secret"))
        XCTAssertFalse(String(describing: span.events).contains("private"))
    }),
    ("telemetry: missing invalid and partial provider measurements are not free usage", {
        let model = ModelSpec(rpc: .object(["id": .string("model"), "provider": .string("provider")]))
        let (_, spans) = await AviaryTelemetry.withRecording {
            for mode in ["missing", "invalid", "unpriced", "partial"] {
                await AviaryTelemetry.withSpan("aviary.test.\(mode)") {
                    var measurement = AviaryProviderTelemetry(now: 10)
                    if mode != "missing" {
                        var usage = Usage()
                        usage.input = mode == "invalid" ? -1 : 100
                        usage.output = 20; usage.totalTokens = 120
                        measurement.observe(.usage(usage))
                    }
                    var configured = model
                    if mode == "partial" { configured.costInput = 2 }
                    measurement.record(model: configured, accounting: .cacheExclusive)
                }
            }
        }
        for mode in ["missing", "invalid", "unpriced", "partial"] {
            let span = try XCTUnwrap(spans.first { $0.name == "aviary.test.\(mode)" })
            let usage = try XCTUnwrap(span.events.first { $0.name == "aviary.agent.provider.measurements" })
            XCTAssertEqual(usage.attributes["aviary.provider.done_observed"], .bool(false))
            XCTAssertNil(usage.attributes["aviary.provider.first_output.seconds"])
            XCTAssertNil(usage.attributes["aviary.usage.reasoning_tokens"])
            let price = span.events.first { $0.name == "aviary.agent.provider.price" }
            XCTAssertNil(price?.attributes["aviary.pricing.estimated_usd"])
            if mode == "missing" || mode == "invalid" {
                XCTAssertNil(price)
                XCTAssertNil(usage.attributes["aviary.usage.total_tokens"])
                XCTAssertEqual(usage.attributes["aviary.usage.state"], .string(mode == "missing" ? "unreported" : "invalid"))
            } else {
                XCTAssertEqual(price?.attributes["aviary.pricing.state"], .string("unavailable"))
            }
        }
    }),
    ("telemetry: synchronous saves and recovery roots preserve scope and identity", {
        let command = AviaryTelemetry.identity("persisted-create-command")
        let (_, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.enclosing") {
                let enclosing = AviaryTelemetry.traceparent
                let saved = AviaryTelemetry.withSynchronousSpan("aviary.test.save", attributes: [
                    "aviary.chat.id": .string(AviaryTelemetry.identity("saved-chat")),
                    "aviary.create.command.id": .string(command)], root: true) {
                    AviaryTelemetry.outcome("succeeded")
                    return 42
                }
                XCTAssertEqual(saved, 42)
                XCTAssertEqual(AviaryTelemetry.traceparent, enclosing)
                let parent = enclosing.flatMap(AviaryTraceContext.init(traceparent:))
                await AviaryTelemetry.withSpan("aviary.test.reconcile", attributes: [
                    "aviary.create.command.id": .string(command)], parent: parent, root: true) {
                    AviaryTelemetry.withSynchronousSpan("aviary.test.read") {}
                }
                XCTAssertEqual(AviaryTelemetry.traceparent, enclosing)
                do {
                    try AviaryTelemetry.withSynchronousSpan("aviary.test.save_failed", root: true) {
                        AviaryTelemetry.outcome("indeterminate")
                        throw TelemetryFixtureError()
                    }
                    XCTFail("Expected original synchronous error")
                } catch { XCTAssertTrue(error is TelemetryFixtureError) }
                XCTAssertEqual(AviaryTelemetry.traceparent, enclosing)
            }
        }
        let enclosing = try XCTUnwrap(spans.first { $0.name == "aviary.test.enclosing" })
        let save = try XCTUnwrap(spans.first { $0.name == "aviary.test.save" })
        let recovery = try XCTUnwrap(spans.first { $0.name == "aviary.test.reconcile" })
        let read = try XCTUnwrap(spans.first { $0.name == "aviary.test.read" })
        let failed = try XCTUnwrap(spans.first { $0.name == "aviary.test.save_failed" })
        XCTAssertNil(save.parentSpanId)
        XCTAssertNil(recovery.parentSpanId)
        XCTAssertNotEqual(enclosing.traceId, save.traceId)
        XCTAssertNotEqual(save.traceId, recovery.traceId)
        XCTAssertEqual(save.attributes["aviary.create.command.id"], recovery.attributes["aviary.create.command.id"])
        XCTAssertEqual(read.parentSpanId, recovery.spanId)
        XCTAssertEqual(read.traceId, recovery.traceId)
        XCTAssertEqual(failed.attributes["aviary.outcome"], .string("indeterminate"))
        XCTAssertNil(AviaryTelemetry.traceparent)
    }),
    ("telemetry: strict context and explicit collector configuration", {
        let valid = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        XCTAssertEqual(AviaryTraceContext(traceparent: valid)?.traceparent, valid)
        for invalid in ["", valid.uppercased(), valid + "-extra",
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
            String(repeating: "f", count: 10000)] {
            XCTAssertNil(AviaryTraceContext(traceparent: invalid))
        }
        XCTAssertEqual(AviaryTelemetry.endpoint(environment: [
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318/"])?.absoluteString,
            "http://127.0.0.1:4318/v1/traces")
        XCTAssertNotNil(AviaryTelemetry.endpoint(environment: [
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://collector.example/v1/traces"]))
        for invalid in ["http://remote.example/v1/traces", "https://u:secret@host/v1/traces",
            "https://host/v1/traces?token=secret", "https://host/v1/traces#secret", "file:///tmp/log"] {
            XCTAssertNil(AviaryTelemetry.endpoint(environment: ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": invalid]))
        }
    }),
    ("telemetry: nested concurrent context and metadata policy", {
        let (value, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.root", attributes: [
                "aviary.work.id": .string(AviaryTelemetry.identity("work-one")),
                "aviary.prompt": .string("SECRET prompt"), "aviary.secret.number": .int(1234),
                "error.type": .string("SECRET error under valid key"),
                "aviary.operation": .string("SECRET operation"),
                "aviary.input.bytes": .int(12), "aviary.output.bytes": .string("SECRET"),
                "aviary.run.id": .string("raw-id"), "aviary.timeout.seconds": .double(.infinity)]) {
                    await withTaskGroup(of: Void.self) { group in
                        for _ in 0..<8 {
                            group.addTask {
                                await AviaryTelemetry.withSpan("aviary.test.child") {
                                    await Task.yield()
                                    AviaryTelemetry.event("aviary.test.event", attributes: [
                                        "aviary.event.id": .string(AviaryTelemetry.identity("event")),
                                        "aviary.event.sequence": .int(3), "error.message": .string("SECRET")])
                                }
                            }
                        }
                    }
                    return 42
                }
        }
        XCTAssertEqual(value, 42)
        let root = try XCTUnwrap(spans.first(where: { $0.name == "aviary.test.root" }))
        let children = spans.filter { $0.name == "aviary.test.child" }
        XCTAssertEqual(children.count, 8)
        XCTAssertEqual(Set(children.map { $0.spanId.hexString }).count, 8)
        for child in children {
            XCTAssertEqual(child.traceId, root.traceId)
            XCTAssertEqual(child.parentSpanId, root.spanId)
            XCTAssertEqual(child.events.count, 1)
        }
        XCTAssertEqual(root.attributes.count, 2)
        XCTAssertNil(root.attributes["aviary.prompt"])
        XCTAssertNil(root.attributes["aviary.secret.number"])
        XCTAssertNil(AviaryTelemetry.traceparent)
    }),
    ("telemetry: failure does not change execution and exports standard OTLP", {
        let (caught, spans) = await AviaryTelemetry.withRecording {
            do {
                try await AviaryTelemetry.withSpan("aviary.test.failure") { throw TelemetryFixtureError() }
                return false
            } catch { return error is TelemetryFixtureError }
        }
        XCTAssertTrue(caught)
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.status, .error(description: "failed"))
        let client = TelemetryCaptureHTTP()
        let exporter = AviaryOTLPBatchExporter(endpoint: URL(string: "http://127.0.0.1:4318/v1/traces")!, httpClient: client)
        XCTAssertEqual(await exporter.export(spans: spans, explicitTimeout: 1), .success)
        let request = try XCTUnwrap(client.recorded().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let data = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
        let decoded = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: data)
        let exported = decoded.resourceSpans.flatMap { $0.scopeSpans }.flatMap { $0.spans }
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?.name, "aviary.test.failure")
        let failing = TelemetryCaptureHTTP(succeeds: false)
        let failedExporter = AviaryOTLPBatchExporter(endpoint: request.url!, httpClient: failing)
        XCTAssertEqual(await failedExporter.export(spans: spans, explicitTimeout: 0.1), .failure)
        XCTAssertEqual(await failedExporter.export(spans: spans, explicitTimeout: 0.1), .failure)
        XCTAssertEqual(failing.recorded().count, 2)
    }),
    ("telemetry: server parent cannot inherit unrelated listener task", {
        let (_, spans) = await AviaryTelemetry.withRecording {
            await AviaryTelemetry.withSpan("aviary.test.listener") {
                await AviaryTelemetry.withSpan("aviary.test.server", kind: .server) {}
            }
        }
        let listener = try XCTUnwrap(spans.first { $0.name == "aviary.test.listener" })
        let server = try XCTUnwrap(spans.first { $0.name == "aviary.test.server" })
        XCTAssertNil(server.parentSpanId)
        XCTAssertNotEqual(server.traceId, listener.traceId)
    }),
    ("telemetry: explicit rejection and uncertainty survive thrown errors", {
        let (_, spans) = await AviaryTelemetry.withRecording {
            for classification in ["rejected", "indeterminate", "unavailable"] {
                do {
                    try await AviaryTelemetry.withSpan("aviary.test.\(classification)") {
                        AviaryTelemetry.outcome(classification)
                        AviaryTelemetry.outcome("completed", fallbackOnly: true)
                        throw TelemetryFixtureError()
                    }
                } catch {}
            }
        }
        for classification in ["rejected", "indeterminate", "unavailable"] {
            let span = try XCTUnwrap(spans.first { $0.name == "aviary.test.\(classification)" })
            XCTAssertEqual(span.attributes["aviary.outcome"], .string(classification))
            XCTAssertEqual(span.status, .error(description: classification))
        }
    }),
]
