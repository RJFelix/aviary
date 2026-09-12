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
    private static var pipeline: ProductionPipeline?
    private static var productionStopped = false
    private static var configuration = "disabled"
    /// Local queue and exporter results, not a collector-retention or canonical-delivery receipt.
    public static var exportDiagnostics: AviaryTelemetryExportDiagnostics? {
        lock.lock(); let current = pipeline; lock.unlock()
        return current?.processor.diagnostics
    }
    public static var traceparent: String? {
        context?.traceparent
    }
    /// Capture causality for an in-memory deferred operation; never persist this as Work state.
    internal static var context: AviaryTraceContext? {
        guard let span = active?.span, span.context.isValid else { return nil }
        return AviaryTraceContext(span.context)
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
        let processor = AviaryBoundedSpanProcessor(spanExporter: exporter,
            abortExporter: { exporter.abort() })
        let configuredProvider = makeProvider(serviceName: serviceName, processor: processor)
        pipeline = ProductionPipeline(processor: processor, provider: configuredProvider)
        provider = configuredProvider
        configuration = "enabled"
    }

    /// Seal only on actual process exit, never a refused quit or a GUI disconnection from Work.
    /// Repeated/concurrent callers share the pipeline's earliest absolute deadline and receipt.
    @discardableResult
    public static func shutdown(maximumDuration: TimeInterval = 2) async -> AviaryTelemetryDrainReceipt? {
        let duration = maximumDuration.isFinite ? min(max(0, maximumDuration), 10) : 2
        let deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        let current = productionPipeline()
        guard let current else { return nil }
        let receipt = await current.processor.shutdown(deadline: deadline)
        current.finishProviderShutdown()
        setStopped()
        return receipt
    }

    private static func productionPipeline() -> ProductionPipeline? {
        lock.lock(); defer { lock.unlock() }
        return pipeline
    }

    /// Recording fixtures may temporarily replace the active tracer, but never this owned pair.
    private final class ProductionPipeline: @unchecked Sendable {
        let processor: AviaryBoundedSpanProcessor
        let provider: TracerProviderSdk
        private let shutdownLock = NSLock()
        private var providerStopped = false
        init(processor: AviaryBoundedSpanProcessor, provider: TracerProviderSdk) {
            self.processor = processor
            self.provider = provider
        }
        func finishProviderShutdown() {
            shutdownLock.lock(); defer { shutdownLock.unlock() }
            guard !providerStopped else { return }
            // SDK provider shutdown is not internally synchronized. Other callers wait for
            // this short, already-drained processor shutdown rather than invoking it again.
            provider.shutdown()
            providerStopped = true
        }
    }

    private static func setStopped() {
        lock.lock(); defer { lock.unlock() }
        productionStopped = true
        configuration = "stopped"
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
                "aviary.telemetry.schema": .int(2),
            ]))
            .with(spanLimits: SpanLimits().settingAttributeCountLimit(32)
                .settingAttributeValueLengthLimit(128).settingEventCountLimit(32)
                .settingAttributePerEventCountLimit(16).settingLinkCountLimit(8))
            .add(spanProcessor: processor).build()
    }

    public static func identity(_ value: String) -> String {
        AviarySHA256.hash(data: Data(value.utf8.prefix(4096))).description
    }

    /// Work IDs are host-scoped. Length-delimited components avoid ambiguous path-like joins.
    public static func workIdentity(_ work: WorkRef) -> String {
        identity("work:v1:\(work.workHostID.utf8.count):\(work.workHostID)\(work.workID.utf8.count):\(work.workID)")
    }

    /// Canonical event identity includes the complete journal, including its owner and authority.
    /// Length-prefixing the fields avoids ambiguous joins without persisting any component text.
    public static func journalIdentity(_ journal: JournalRef) -> String {
        var fields = ["journal:v1", journal.journalID, journal.authority.authorityID]
        switch journal.owner {
        case .work(let work): fields += ["work", work.workHostID, work.workID]
        case .session(let session): fields += ["session", session.sessionID]
        case .workHost(let host): fields += ["work_host", host.workHostID]
        }
        // Canonical IDs are bounded at ingestion. Reject oversize diagnostic input rather than
        // truncating a journal identity and silently making distinct refs look equal.
        guard fields.allSatisfy({ $0.utf8.count <= 4096 }) else { return "" }
        var data = Data()
        for field in fields {
            data.append(contentsOf: "\(field.utf8.count):".utf8)
            data.append(contentsOf: field.utf8)
        }
        return AviarySHA256.hash(data: data).description
    }

    public enum CanonicalReferenceRole: Sendable { case event, actionStarted }

    public static func canonicalReferenceAttributes(
        _ commit: TimelineJournalCommit, role: CanonicalReferenceRole = .event
    ) -> [String: AviaryTraceValue] {
        guard commit.cursor.journal == commit.eventRef.journal,
              commit.cursor.eventID == commit.eventRef.eventID,
              commit.cursor.sequence > 0, !commit.eventRef.eventID.isEmpty,
              commit.eventRef.eventID.utf8.count <= 4096 else { return [:] }
        let journal = journalIdentity(commit.eventRef.journal)
        guard !journal.isEmpty else { return [:] }
        let prefix = role == .event ? "aviary.event" : "aviary.action.started"
        return [
            "\(prefix).id": .string(identity(commit.eventRef.eventID)),
            "\(prefix).journal.id": .string(journal),
            "\(prefix).sequence": .int(commit.cursor.sequence),
        ]
    }

    public static func withSpan<T>(
        _ name: String, kind: AviaryTraceKind = .internal,
        attributes: [String: AviaryTraceValue] = [:], parent: AviaryTraceContext? = nil,
        root: Bool = false, links: [AviaryTraceContext] = [],
        operation: () async throws -> T
    ) async rethrows -> T {
        guard let span = startSpan(name, kind: kind, attributes: attributes, parent: parent, root: root, links: links)
        else { return try await operation() }
        defer { span.end() }
        return try await $active.withValue(AviaryActiveSpan(span)) {
            do { return try await operation() }
            catch {
                active?.outcome(error is CancellationError ? "cancelled" : "failed", fallbackOnly: true)
                throw error
            }
        }
    }

    /// Covers a synchronous operation's actual lifetime, without extending it over later tasks.
    public static func withSynchronousSpan<T>(
        _ name: String, kind: AviaryTraceKind = .internal,
        attributes: [String: AviaryTraceValue] = [:], parent: AviaryTraceContext? = nil,
        root: Bool = false, links: [AviaryTraceContext] = [], operation: () throws -> T
    ) rethrows -> T {
        guard let span = startSpan(name, kind: kind, attributes: attributes, parent: parent, root: root, links: links)
        else { return try operation() }
        defer { span.end() }
        return try $active.withValue(AviaryActiveSpan(span)) {
            do { return try operation() }
            catch {
                active?.outcome(error is CancellationError ? "cancelled" : "failed", fallbackOnly: true)
                throw error
            }
        }
    }

    /// Explicit roots represent a new attempt, including reconciliation after process loss.
    /// Durable command hashes join attempts; an old span is never reconstructed from storage.
    private static func startSpan(
        _ name: String, kind: AviaryTraceKind, attributes: [String: AviaryTraceValue],
        parent: AviaryTraceContext?, root: Bool, links: [AviaryTraceContext]
    ) -> (any Span)? {
        guard let tracer = currentTracer() else { return nil }
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
        if !root, let context = parent?.sdk ?? inherited { builder.setParent(context) }
        else { builder.setNoParent() }
        // Bound both traversal and exported links; a caller cannot turn this into a history scan.
        var linked = Set<String>()
        for link in links.prefix(8) where link.sdk.isValid {
            let identity = "\(link.sdk.traceId.hexString):\(link.sdk.spanId.hexString)"
            if linked.insert(identity).inserted { builder.addLink(spanContext: link.sdk) }
        }
        for (key, value) in safeAttributes(attributes) { builder.setAttribute(key: key, value: value) }
        return builder.startSpan()
    }

    public static func event(_ name: String, attributes: [String: AviaryTraceValue] = [:]) {
        active?.span.addEvent(name: safeName(name), attributes: safeAttributes(attributes))
    }
    public static func outcome(_ value: String, fallbackOnly: Bool = false) {
        let known: Set<String> = ["completed", "succeeded", "failed", "cancelled", "canceled",
            "rejected", "indeterminate", "accepted", "duplicate", "unavailable", "expired"]
        let value = known.contains(value) ? value : "unknown"
        active?.outcome(value, fallbackOnly: fallbackOnly)
    }
    private static func currentTracer() -> (any Tracer)? {
        lock.lock(); defer { lock.unlock() }
        // The SDK's stopped tracer still creates valid unsampled propagation contexts.
        // Do not originate those after our terminal shutdown. A separate recording provider
        // remains usable; existing/remote unsampled contexts retain their sampling semantics.
        if productionStopped, let provider, let pipeline, provider === pipeline.provider {
            return nil
        }
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
            "aviary.read.target": ["work", "session"],
            "aviary.repository.review.status": ["clean", "changes", "unstable_conflict", "not_repository",
                "timed_out", "cancelled", "failed", "bounded"],
            "aviary.usage.state": ["reported", "unreported", "invalid"],
            "aviary.usage.input_accounting": ["cache_inclusive", "cache_exclusive", "unknown"],
            "aviary.runtime.callback.reply_state": ["accepted", "duplicate", "stale", "invalid", "unknown"],
            "aviary.pricing.source": ["model_spec"],
            "aviary.pricing.state": ["estimated", "unavailable"],
            "aviary.command.kind": ["create", "start", "send", "steer", "queue", "cancel", "end"],
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
            "error.type": ["action_dispatch", "action_outcome", "canonical_delivery", "cancellation", "provider", "mcp", "hook", "runtime"],
        ]
        let identities: Set<String> = ["aviary.request.id", "aviary.command.id", "aviary.work.id",
            "aviary.chat.id", "aviary.create.command.id", "aviary.start.command.id",
            "aviary.command.ledger.id", "aviary.handle.id",
            "aviary.pricing.id",
            "aviary.client.id", "aviary.session.id",
            "aviary.run.id", "aviary.turn.id", "aviary.agent.session.id", "aviary.runtime.session.id",
            "aviary.action.id", "aviary.artifact.id", "aviary.context.manifest.id", "aviary.event.id", "aviary.event.journal.id",
            "aviary.read.journal.id", "aviary.read.event.id",
            "aviary.action.started.id", "aviary.action.started.journal.id",
            "aviary.provider.id_hash", "aviary.model.id_hash"]
        let integers: Set<String> = ["aviary.event.sequence", "aviary.agent.prompt_bytes",
            "aviary.usage.updates", "aviary.usage.input_tokens", "aviary.usage.output_tokens",
            "aviary.usage.cache_read_tokens", "aviary.usage.cache_write_tokens",
            "aviary.usage.total_tokens", "aviary.usage.reasoning_tokens",
            "aviary.input.bytes", "aviary.output.bytes", "aviary.action.started.sequence",
            "aviary.read.sequence", "aviary.control.sequence", "aviary.artifact.bytes",
            "aviary.repository.review.files", "aviary.repository.review.diffs",
            "aviary.repository.review.omissions", "aviary.repository.review.diff_bytes",
            "aviary.repository.review.artifact_bytes",
            "aviary.context.components", "aviary.context.omissions", "aviary.context.measured_bytes",
            "aviary.context.delivered_bytes", "aviary.compaction.dropped_messages",
            "aviary.compaction.tokens_before", "aviary.compaction.summary_bytes"]
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
            case .bool(let value):
                if ["aviary.exception.present", "aviary.provider.done_observed", "aviary.pricing.cache_fallback",
                    "aviary.repository.review.bounded"].contains(key) {
                    result[key] = .bool(value)
                }
            case .double(let value):
                if ["aviary.timeout.seconds", "aviary.queue.wait.seconds", "aviary.provider.first_output.seconds", "aviary.pricing.estimated_usd",
                    "aviary.pricing.input_per_million_usd", "aviary.pricing.output_per_million_usd",
                    "aviary.pricing.cache_read_per_million_usd", "aviary.pricing.cache_write_per_million_usd"].contains(key),
                   value.isFinite, value >= 0 { result[key] = .double(value) }
            }
        }
        return result
    }

    /// Test-only scoped recording. The self-test executable serializes fixtures and owns all spawned tasks.
    internal static func withRecording<T>(
        waitingFor endedSpans: (@Sendable ([SpanData]) -> Bool)? = nil,
        _ operation: () async throws -> T
    ) async rethrows -> (T, [SpanData]) {
        let recorder = AviaryMemorySpanExporter()
        let recorded = makeProvider(serviceName: "aviary", processor: SimpleSpanProcessor(spanExporter: recorder))
        let previous = exchangeProvider(recorded)
        defer { _ = exchangeProvider(previous); recorded.shutdown() }
        let value = try await operation()
        // Canonical settlement can precede an owned task's span.end(). Fixtures may wait for
        // actual exported end evidence, never approximate that boundary with a fixed sleep.
        if let endedSpans {
            for _ in 0..<400 {
                if endedSpans(recorder.snapshot()) || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
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
        exportBatch(spans: spans, explicitTimeout: explicitTimeout)
    }
    private func exportBatch(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        guard spans.count <= 128 else { return .failure }
        let exporter = OtlpHttpTraceExporter(
            endpoint: endpoint, config: .init(timeout: 2, compression: .none, exportAsJson: false),
            httpClient: httpClient, envVarHeaders: [])
        let result = exporter.export(spans: spans, explicitTimeout: min(explicitTimeout ?? 2, 2))
        return result
    }
    func abort() { (httpClient as? AviaryTelemetryHTTPClient)?.shutDown() }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) { abort() }
    func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) async { abort() }
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
