import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

public enum AviaryTraceKind: Sendable { case `internal`, client, server }
public enum AviaryTraceValue: Sendable {
    case string(String), int(Int), double(Double), bool(Bool)
}

/// Diagnostic context only. Never a command identity, authorization, or delivery receipt.
public struct AviaryTraceContext: Sendable, Equatable {
    fileprivate let sdk: SpanContext
    public init?(traceparent: String) {
        guard traceparent.utf8.count == 55 else { return nil }
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "00",
              parts[1].count == 32, parts[2].count == 16, parts[3].count == 2,
              parts.dropFirst().allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
              let hi = UInt64(parts[1].prefix(16), radix: 16),
              let lo = UInt64(parts[1].suffix(16), radix: 16), hi != 0 || lo != 0,
              let span = UInt64(parts[2], radix: 16), span != 0,
              let flags = UInt8(parts[3], radix: 16) else { return nil }
        sdk = .createFromRemoteParent(
            traceId: TraceId(idHi: hi, idLo: lo), spanId: SpanId(id: span),
            traceFlags: TraceFlags(fromByte: flags), traceState: TraceState())
    }
    fileprivate init(_ sdk: SpanContext) { self.sdk = sdk }
    public var traceparent: String {
        "00-\(sdk.traceId.hexString)-\(sdk.spanId.hexString)-\(sdk.traceFlags.hexString)"
    }
}

private final class AviaryActiveSpan: @unchecked Sendable {
    let span: any Span
    private let lock = NSLock()
    private var recordedOutcome: String?
    init(_ span: any Span) { self.span = span }
    func outcome(_ value: String, fallbackOnly: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if fallbackOnly, let recordedOutcome, recordedOutcome != "unknown" { return }
        recordedOutcome = value
        span.setAttribute(key: "aviary.outcome", value: .string(value))
        if ["failed", "rejected", "indeterminate", "unavailable"].contains(value) {
            span.status = .error(description: value)
        }
    }
}

/// Explicit instrumentation backed by the official OTel SDK. No network or body capture by default.
public enum AviaryTelemetry {
    @TaskLocal private static var active: AviaryActiveSpan?
    private static let lock = NSLock()
    private static var provider: TracerProviderSdk?
    private static var configuration = "disabled"
    private static var exportAttempts = 0
    private static var exportFailures = 0
    /// Saturating process-local counters. SDK queue loss is not measured by these counters.
    public static var exportDiagnostics: (attempts: Int, failures: Int) {
        lock.lock(); defer { lock.unlock() }; return (exportAttempts, exportFailures)
    }
    internal static func recordExport(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        if exportAttempts < Int.max { exportAttempts += 1 }
        if !success, exportFailures < Int.max { exportFailures += 1 }
    }
    public static var traceparent: String? {
        guard let span = active?.span, span.context.isValid else { return nil }
        return AviaryTraceContext(span.context).traceparent
    }
    public static var configurationStatus: String {
        lock.lock(); defer { lock.unlock() }; return configuration
    }

    /// A collector must be explicitly selected. Credentials in URLs and implicit env headers are refused.
    public static func configure(serviceName: String, environment: [String: String]) {
        guard environment["AVIARY_OTEL_ENABLED"] == "1" else { return }
        guard let url = endpoint(environment: environment) else {
            lock.lock(); configuration = "invalid_endpoint"; lock.unlock(); return
        }
        lock.lock(); defer { lock.unlock() }
        guard provider == nil else { return }
        let exporter = AviaryOTLPBatchExporter(endpoint: url)
        let processor = BatchSpanProcessor(
            spanExporter: exporter, scheduleDelay: 1, exportTimeout: 2,
            maxQueueSize: 1024, maxExportBatchSize: 128)
        provider = makeProvider(serviceName: serviceName, processor: processor)
        configuration = "enabled"
    }

    internal static func endpoint(environment: [String: String]) -> URL? {
        let raw = environment["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"]
            ?? environment["OTEL_EXPORTER_OTLP_ENDPOINT"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/traces" }
        guard let raw, raw.utf8.count <= 2048, let url = URL(string: raw),
              ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host?.lowercased())
        else { return nil }
        return url
    }

    private static func makeProvider(serviceName: String, processor: any SpanProcessor) -> TracerProviderSdk {
        TracerProviderBuilder()
            .with(resource: Resource(attributes: [
                "service.name": .string(serviceName == "aviaryd" ? "aviaryd" : "aviary"),
                "service.instance.id": .string(UUID().uuidString.lowercased()),
                "aviary.telemetry.schema": .int(1),
            ]))
            .with(spanLimits: SpanLimits().settingAttributeCountLimit(32)
                .settingAttributeValueLengthLimit(128).settingEventCountLimit(32)
                .settingAttributePerEventCountLimit(16).settingLinkCountLimit(8))
            .add(spanProcessor: processor).build()
    }

    public static func identity(_ value: String) -> String {
        AviarySHA256.hash(data: Data(value.utf8.prefix(4096))).description
    }

    public static func withSpan<T>(
        _ name: String, kind: AviaryTraceKind = .internal,
        attributes: [String: AviaryTraceValue] = [:], parent: AviaryTraceContext? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        guard let tracer = currentTracer() else { return try await operation() }
        let builder = tracer.spanBuilder(spanName: safeName(name))
        switch kind {
        case .internal: builder.setSpanKind(spanKind: .internal)
        case .client: builder.setSpanKind(spanKind: .client)
        case .server: builder.setSpanKind(spanKind: .server)
        }
        // Server work has only the explicitly propagated parent. A listener created under an
        // unrelated task must not lend that task's context to malformed/unparented requests.
        let inherited: SpanContext?
        switch kind {
        case .server: inherited = nil
        case .internal, .client: inherited = active?.span.context
        }
        if let context = parent?.sdk ?? inherited { builder.setParent(context) }
        else { builder.setNoParent() }
        for (key, value) in safeAttributes(attributes) { builder.setAttribute(key: key, value: value) }
        let span = builder.startSpan()
        defer { span.end() }
        return try await $active.withValue(AviaryActiveSpan(span)) {
            do { return try await operation() }
            catch {
                active?.outcome(error is CancellationError ? "cancelled" : "failed", fallbackOnly: true)
                throw error
            }
        }
    }

    public static func event(_ name: String, attributes: [String: AviaryTraceValue] = [:]) {
        active?.span.addEvent(name: safeName(name), attributes: safeAttributes(attributes))
    }
    public static func outcome(_ value: String) {
        let known: Set<String> = ["completed", "succeeded", "failed", "cancelled", "canceled",
            "rejected", "indeterminate", "accepted", "duplicate", "unavailable", "expired"]
        let value = known.contains(value) ? value : "unknown"
        active?.outcome(value)
    }
    private static func currentTracer() -> (any Tracer)? {
        lock.lock(); defer { lock.unlock() }
        return provider?.get(instrumentationName: "aviary.core", instrumentationVersion: "1")
    }
    private static func safeName(_ name: String) -> String {
        guard name.utf8.count <= 96, !name.isEmpty,
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95 })
        else { return "aviary.invalid_instrumentation_name" }
        return name
    }
    private static func safeAttributes(_ attributes: [String: AviaryTraceValue]) -> [String: AttributeValue] {
        let strings: [String: Set<String>] = [
            "rpc.system": ["aviary.work", "aviary_work_service", "aviary_work"],
            "rpc.method": ["handshake", "list_works", "describe_work", "create_work", "create_session",
                "complete_work", "attach", "detach", "update_capabilities", "acknowledge_read", "snapshot",
                "events_after_cursor", "history_before_cursor", "fetch_artifact", "fetch_body", "command", "cancel_agent_handle"],
            "aviary.operation": ["normal", "compaction"],
            "aviary.command.kind": ["start", "send", "steer", "queue", "cancel", "end"],
            "aviary.outcome": ["unknown", "completed", "succeeded", "failed", "cancelled", "canceled",
                "rejected", "indeterminate", "accepted", "duplicate", "unavailable", "expired"],
            "aviary.action.kind": Set(ActionKind.allCases.map(\.rawValue)),
            "aviary.tool.kind": ["python", "mcp", "other"],
            "aviary.callback.kind": ["spawn", "agent_handle", "list", "peer_message", "self_delivery", "web", "memory", "other"],
            "aviary.receipt.state": ["accepted", "duplicate", "rejected", "indeterminate", "started",
                "succeeded", "failed", "canceled", "indeterminate_effect"],
            "aviary.delivery.state": ["not_attempted", "queued", "delivered", "not_delivered", "indeterminate"],
            "aviary.retry.safety": ["safe", "idempotent", "unsafe", "unknown"],
            "aviary.failure.kind": ["task", "infrastructure", "policy", "timeout", "cancellation", "indeterminate_effect", "other"],
            "error.type": ["action_dispatch", "action_outcome", "cancellation", "provider", "mcp", "hook", "runtime"],
        ]
        let identities: Set<String> = ["aviary.request.id", "aviary.command.id", "aviary.work.id",
            "aviary.client.id", "aviary.session.id",
            "aviary.run.id", "aviary.agent.session.id", "aviary.runtime.session.id",
            "aviary.action.id", "aviary.event.id", "aviary.action.started.id", "aviary.provider.id_hash", "aviary.model.id_hash"]
        let integers: Set<String> = ["aviary.event.sequence", "aviary.agent.prompt_bytes",
            "aviary.input.bytes", "aviary.output.bytes", "aviary.action.started.sequence"]
        var result: [String: AttributeValue] = [:]
        for key in attributes.keys.sorted().prefix(32) {
            switch attributes[key]! {
            case .string(let value):
                if identities.contains(key) {
                    guard value.utf8.count == 64,
                          value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
                } else { guard strings[key]?.contains(value) == true else { continue } }
                guard value.utf8.count <= 128,
                      value.utf8.allSatisfy({ (32...126).contains($0) }) else { continue }
                result[key] = .string(value)
            case .int(let value): if integers.contains(key), value >= 0 { result[key] = .int(value) }
            case .bool(let value): if key == "aviary.exception.present" { result[key] = .bool(value) }
            case .double(let value):
                if key == "aviary.timeout.seconds", value.isFinite, value >= 0 { result[key] = .double(value) }
            }
        }
        return result
    }

    /// Test-only scoped recording. The self-test executable serializes fixtures and owns all spawned tasks.
    internal static func withRecording<T>(
        _ operation: () async throws -> T
    ) async rethrows -> (T, [SpanData]) {
        let recorder = AviaryMemorySpanExporter()
        let recorded = makeProvider(serviceName: "aviary", processor: SimpleSpanProcessor(spanExporter: recorder))
        let previous = exchangeProvider(recorded)
        defer { _ = exchangeProvider(previous); recorded.shutdown() }
        let value = try await operation()
        recorded.forceFlush(timeout: 2)
        return (value, recorder.snapshot())
    }
    private static func exchangeProvider(_ next: TracerProviderSdk?) -> TracerProviderSdk? {
        lock.lock(); defer { lock.unlock() }
        let old = provider; provider = next; return old
    }
}

/// A fresh exporter per bounded SDK batch avoids accumulating the upstream exporter's retry list
/// indefinitely while a collector is down. Export failure never retries a user/Work operation.
internal final class AviaryOTLPBatchExporter: SpanExporter, @unchecked Sendable {
    let endpoint: URL
    let httpClient: any HTTPClient
    init(endpoint: URL, httpClient: any HTTPClient = AviaryTelemetryHTTPClient()) {
        self.endpoint = endpoint; self.httpClient = httpClient
    }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        exportBatch(spans: spans, explicitTimeout: explicitTimeout)
    }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
        await Task.detached { self.exportBatch(spans: spans, explicitTimeout: explicitTimeout) }.value
    }
    private func exportBatch(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        guard spans.count <= 128 else { AviaryTelemetry.recordExport(success: false); return .failure }
        let exporter = OtlpHttpTraceExporter(
            endpoint: endpoint, config: .init(timeout: 2, compression: .none, exportAsJson: false),
            httpClient: httpClient, envVarHeaders: [])
        let result = exporter.export(spans: spans, explicitTimeout: min(explicitTimeout ?? 2, 2))
        AviaryTelemetry.recordExport(success: result == .success)
        return result
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
    func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) async {}
}

private final class AviaryMemorySpanExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [SpanData] = []
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        record(spans)
    }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
        record(spans)
    }
    private func record(_ spans: [SpanData]) -> SpanExporterResultCode {
        lock.lock(); defer { lock.unlock() }
        self.spans.append(contentsOf: spans.prefix(max(0, 4096 - self.spans.count)))
        return .success
    }
    func snapshot() -> [SpanData] { lock.lock(); defer { lock.unlock() }; return spans }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
    func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) async {}
}
