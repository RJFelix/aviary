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
        let before = AviaryTelemetry.exportDiagnostics.failures
        XCTAssertEqual(await failedExporter.export(spans: spans, explicitTimeout: 0.1), .failure)
        XCTAssertEqual(await failedExporter.export(spans: spans, explicitTimeout: 0.1), .failure)
        XCTAssertEqual(failing.recorded().count, 2)
        XCTAssertEqual(AviaryTelemetry.exportDiagnostics.failures, before + 2)
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
