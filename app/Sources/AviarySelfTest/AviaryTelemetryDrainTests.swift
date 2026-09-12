import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import AviaryCore

private final class TelemetryDrainExporter: SpanExporter, @unchecked Sendable {
    private let condition = NSCondition()
    private let configuredResult: SpanExporterResultCode
    private var blocksExports: Bool
    private var wasAborted = false
    private var batches: [[String]] = []
    private var abortCount = 0

    init(result: SpanExporterResultCode = .success, blocked: Bool = false) {
        configuredResult = result
        blocksExports = blocked
    }

    func export(
        spans: [SpanData], explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        condition.lock()
        batches.append(spans.map(\.name))
        condition.broadcast()
        while blocksExports, !wasAborted { condition.wait() }
        let result: SpanExporterResultCode = wasAborted ? .failure : configuredResult
        condition.unlock()
        return result
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) { abort() }

    func release() {
        condition.lock()
        blocksExports = false
        condition.broadcast()
        condition.unlock()
    }

    func abort() {
        condition.lock()
        wasAborted = true
        abortCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func snapshot() -> (batches: [[String]], aborts: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (batches, abortCount)
    }
}

private func telemetryDrainProvider(
    processor: AviaryBoundedSpanProcessor
) -> TracerProviderSdk {
    TracerProviderBuilder().add(spanProcessor: processor).build()
}

private func telemetryDrainEmit(
    _ count: Int, provider: TracerProviderSdk, prefix: String = "drain"
) {
    let tracer = provider.get(instrumentationName: "aviary.drain.tests")
    for index in 0..<count {
        tracer.spanBuilder(spanName: "\(prefix)-\(index)").startSpan().end()
    }
}

private func telemetryDrainEventually(
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return predicate()
}

let casesAviaryTelemetryDrain: [Case] = [
    ("telemetry drain: one resident cap includes queued and in-flight spans", {
        let exporter = TelemetryDrainExporter(blocked: true)
        let processor = AviaryBoundedSpanProcessor(
            spanExporter: exporter, maximumResidentSpans: 3,
            maximumExportBatchSize: 1, scheduleDelay: 0, exportTimeout: 1,
            abortExporter: { exporter.abort() })
        let provider = telemetryDrainProvider(processor: processor)
        defer { provider.shutdown() }

        telemetryDrainEmit(1, provider: provider, prefix: "held")
        XCTAssertTrue(await telemetryDrainEventually {
            exporter.snapshot().batches.count == 1
        })
        telemetryDrainEmit(3, provider: provider, prefix: "queued")
        let during = processor.diagnostics
        XCTAssertEqual(during.sampledEndedSpans, 4)
        XCTAssertEqual(during.acceptedSpans, 3)
        XCTAssertEqual(during.inFlightSpans, 1)
        XCTAssertEqual(during.queuedSpans, 2)
        XCTAssertEqual(during.droppedQueueFullSpans, 1)

        exporter.release()
        let receipt = await processor.shutdown(
            deadline: ContinuousClock.now.advanced(by: .seconds(1)))
        XCTAssertEqual(receipt.outcome, .quiesced)
        XCTAssertTrue(receipt.allAcceptedSpansConfirmedExported)
        XCTAssertEqual(receipt.diagnostics.exportAttemptedSpans, 3)
        XCTAssertEqual(receipt.diagnostics.exportSucceededSpans, 3)
        XCTAssertEqual(receipt.diagnostics.exportBatchAttempts, 3)
        XCTAssertEqual(receipt.diagnostics.exportBatchSuccesses, 3)
        XCTAssertEqual(receipt.diagnostics.queuedSpans, 0)
        XCTAssertEqual(receipt.diagnostics.inFlightSpans, 0)
        XCTAssertTrue(await telemetryDrainEventually { processor.diagnostics.workerStopped })
        XCTAssertEqual(exporter.snapshot().batches.flatMap { $0 }.count, 3)
        XCTAssertEqual(exporter.snapshot().aborts, 1)
        provider.shutdown()
        XCTAssertEqual(exporter.snapshot().aborts, 1)
    }),
    ("telemetry drain: exporter failure quiesces without retry or retention claim", {
        let exporter = TelemetryDrainExporter(result: .failure, blocked: true)
        let processor = AviaryBoundedSpanProcessor(
            spanExporter: exporter, maximumResidentSpans: 10,
            maximumExportBatchSize: 3, scheduleDelay: 60, exportTimeout: 1,
            abortExporter: { exporter.abort() })
        let provider = telemetryDrainProvider(processor: processor)
        defer { provider.shutdown() }
        telemetryDrainEmit(3, provider: provider, prefix: "failed-first")
        XCTAssertTrue(await telemetryDrainEventually {
            exporter.snapshot().batches.count == 1
        })
        telemetryDrainEmit(2, provider: provider, prefix: "failed-second")
        exporter.release()

        let receipt = await processor.shutdown(
            deadline: ContinuousClock.now.advanced(by: .seconds(1)))
        XCTAssertEqual(receipt.outcome, .quiesced)
        XCTAssertFalse(receipt.allAcceptedSpansConfirmedExported)
        XCTAssertEqual(receipt.diagnostics.acceptedSpans, 5)
        XCTAssertEqual(receipt.diagnostics.exportAttemptedSpans, 5)
        XCTAssertEqual(receipt.diagnostics.exportSucceededSpans, 0)
        XCTAssertEqual(receipt.diagnostics.exportResultFailureSpans, 5)
        XCTAssertEqual(receipt.diagnostics.exportBatchAttempts, 2)
        XCTAssertEqual(receipt.diagnostics.exportBatchResultFailures, 2)
        let exported = exporter.snapshot().batches.flatMap { $0 }
        XCTAssertEqual(exported.count, 5)
        XCTAssertEqual(Set(exported).count, 5)
    }),
    ("telemetry drain: callers share one absolute deadline and abort uncertainty", {
        let exporter = TelemetryDrainExporter(blocked: true)
        let processor = AviaryBoundedSpanProcessor(
            spanExporter: exporter, maximumResidentSpans: 4,
            maximumExportBatchSize: 1, scheduleDelay: 0, exportTimeout: 2,
            abortExporter: { exporter.abort() })
        let provider = telemetryDrainProvider(processor: processor)
        defer { provider.shutdown() }

        telemetryDrainEmit(1, provider: provider, prefix: "inflight")
        XCTAssertTrue(await telemetryDrainEventually {
            exporter.snapshot().batches.count == 1
        })
        telemetryDrainEmit(2, provider: provider, prefix: "waiting")
        let started = Date()
        let firstDeadline = ContinuousClock.now.advanced(by: .milliseconds(80))
        let first = Task { await processor.shutdown(deadline: firstDeadline) }
        XCTAssertTrue(await telemetryDrainEventually {
            processor.diagnostics.drainStarts == 1
        })
        let second = Task {
            await processor.shutdown(
                deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        }
        let firstReceipt = await first.value
        let secondReceipt = await second.value

        XCTAssertEqual(firstReceipt, secondReceipt)
        XCTAssertEqual(firstReceipt.outcome, .deadlineExceeded)
        XCTAssertEqual(firstReceipt.unconfirmedAtDeadlineSpans, 1)
        XCTAssertEqual(firstReceipt.diagnostics.abandonedBeforeAttemptSpans, 2)
        XCTAssertEqual(firstReceipt.diagnostics.queuedSpans, 0)
        XCTAssertEqual(firstReceipt.diagnostics.inFlightSpans, 1)
        XCTAssertEqual(firstReceipt.diagnostics.drainStarts, 1)
        XCTAssertEqual(firstReceipt.diagnostics.drainDeadlineExceeded, 1)
        XCTAssertTrue(Date().timeIntervalSince(started) < 0.5)
        XCTAssertEqual(exporter.snapshot().aborts, 1)

        telemetryDrainEmit(1, provider: provider, prefix: "late")
        XCTAssertTrue(await telemetryDrainEventually { processor.diagnostics.workerStopped })
        let after = processor.diagnostics
        XCTAssertEqual(after.droppedAfterShutdownSpans, 1)
        XCTAssertEqual(after.exportResultFailureSpans, 1)
        XCTAssertEqual(after.queuedSpans, 0)
        XCTAssertEqual(after.inFlightSpans, 0)
        XCTAssertTrue(after.workerStopped)
    }),
    ("telemetry drain: counter saturation is explicit", {
        var counter = AviarySaturatingCounter(Int.max - 1)
        counter.add()
        XCTAssertEqual(counter.value, Int.max)
        XCTAssertFalse(counter.saturated)
        counter.add()
        XCTAssertEqual(counter.value, Int.max)
        XCTAssertTrue(counter.saturated)
        counter.add(100)
        XCTAssertEqual(counter.value, Int.max)
        XCTAssertTrue(counter.saturated)
    }),
    ("telemetry drain: an empty zero-deadline pipeline is already quiesced", {
        let exporter = TelemetryDrainExporter()
        let processor = AviaryBoundedSpanProcessor(
            spanExporter: exporter, scheduleDelay: 60,
            abortExporter: { exporter.abort() })
        let provider = telemetryDrainProvider(processor: processor)

        let receipt = await processor.shutdown(deadline: ContinuousClock.now)
        XCTAssertEqual(receipt.outcome, .quiesced)
        XCTAssertTrue(receipt.allAcceptedSpansConfirmedExported)
        XCTAssertEqual(receipt.unconfirmedAtDeadlineSpans, 0)
        XCTAssertEqual(receipt.diagnostics.acceptedSpans, 0)
        XCTAssertEqual(receipt.diagnostics.drainStarts, 1)
        XCTAssertEqual(receipt.diagnostics.drainQuiesced, 1)
        XCTAssertEqual(receipt.diagnostics.drainDeadlineExceeded, 0)
        XCTAssertEqual(exporter.snapshot().aborts, 1)
        XCTAssertTrue(await telemetryDrainEventually { processor.diagnostics.workerStopped })
        provider.shutdown()
        XCTAssertEqual(exporter.snapshot().aborts, 1)
    }),
]
