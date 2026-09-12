import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Process-local observations of the bounded span pipeline.
///
/// These counters describe only Aviary's memory and the result returned by its exporter. An
/// export success is not evidence that a collector retained a span, and an export-result failure
/// is not evidence that a timed-out request could not have reached the collector.
public struct AviaryTelemetryExportDiagnostics: Equatable, Sendable {
    public let sampledEndedSpans: Int
    public let acceptedSpans: Int
    public let droppedQueueFullSpans: Int
    public let droppedAfterShutdownSpans: Int
    public let exportAttemptedSpans: Int
    public let exportSucceededSpans: Int
    public let exportResultFailureSpans: Int
    public let abandonedBeforeAttemptSpans: Int
    public let exportBatchAttempts: Int
    public let exportBatchSuccesses: Int
    public let exportBatchResultFailures: Int
    public let drainStarts: Int
    public let drainQuiesced: Int
    public let drainDeadlineExceeded: Int
    public let queuedSpans: Int
    public let inFlightSpans: Int
    public let workerStopped: Bool
    public let countersSaturated: Bool
}

public enum AviaryTelemetryDrainOutcome: String, Equatable, Sendable {
    /// Every locally accepted span reached a terminal exporter result before the deadline.
    case quiesced
    /// The absolute pipeline deadline elapsed with queued or in-flight work remaining.
    case deadlineExceeded = "deadline_exceeded"
}

public struct AviaryTelemetryDrainReceipt: Equatable, Sendable {
    public let outcome: AviaryTelemetryDrainOutcome
    /// Spans whose exporter call was still in flight at the deadline. Delivery is unknown.
    public let unconfirmedAtDeadlineSpans: Int
    public let diagnostics: AviaryTelemetryExportDiagnostics

    /// This is only a local exporter-result statement, never a backend-retention statement.
    public var allAcceptedSpansConfirmedExported: Bool {
        outcome == .quiesced
            && !diagnostics.countersSaturated
            && diagnostics.acceptedSpans == diagnostics.exportSucceededSpans
    }
}

/// A nonnegative integer which makes loss of counter precision explicit.
internal struct AviarySaturatingCounter: Equatable, Sendable {
    private(set) var value: Int
    private(set) var saturated: Bool

    internal init(_ value: Int = 0) {
        self.value = max(0, value)
        saturated = false
    }

    internal mutating func add(_ amount: Int = 1) {
        guard amount > 0, !saturated else { return }
        guard value <= Int.max - amount else {
            value = Int.max
            saturated = true
            return
        }
        value += amount
    }
}

/// Aviary's bounded production span processor.
///
/// The SDK's batch processor does not expose its queue loss or exact drain state. This processor
/// owns one worker and one resident bound across queued and in-flight spans, allowing shutdown to
/// report exactly what this process knew at one absolute deadline. Failed exports are never
/// retried here. `abortExporter` must synchronously request cancellation of the exporter's bounded
/// transport, release any blocking export wait, and tolerate the processor claiming close once
/// after an already-quiesced drain.
internal final class AviaryBoundedSpanProcessor: SpanProcessor, @unchecked Sendable {
    internal static let maximumResidentSpans = 1_024
    internal static let maximumExportBatchSize = 128
    internal static let maximumExportTimeout: TimeInterval = 2

    private let state: State

    internal init(
        spanExporter: any SpanExporter,
        maximumResidentSpans: Int = AviaryBoundedSpanProcessor.maximumResidentSpans,
        maximumExportBatchSize: Int = AviaryBoundedSpanProcessor.maximumExportBatchSize,
        scheduleDelay: TimeInterval = 1,
        exportTimeout: TimeInterval = AviaryBoundedSpanProcessor.maximumExportTimeout,
        abortExporter: @escaping @Sendable () -> Void
    ) {
        let boundedScheduleDelay = scheduleDelay.isFinite ? max(0, scheduleDelay) : 1
        let boundedExportTimeout = exportTimeout.isFinite
            ? min(max(0.001, exportTimeout), Self.maximumExportTimeout)
            : Self.maximumExportTimeout
        state = State(
            exporter: spanExporter,
            residentLimit: min(max(1, maximumResidentSpans), Self.maximumResidentSpans),
            batchLimit: min(
                max(1, maximumExportBatchSize),
                min(max(1, maximumResidentSpans), Self.maximumExportBatchSize)),
            scheduleDelay: boundedScheduleDelay,
            exportTimeout: boundedExportTimeout,
            abortExporter: abortExporter)
        state.start()
    }

    internal var diagnostics: AviaryTelemetryExportDiagnostics { state.diagnostics() }

    internal let isStartRequired = false
    internal let isEndRequired = true

    internal func onStart(parentContext: SpanContext?, span: ReadableSpan) {}

    internal func onEnd(span: ReadableSpan) {
        guard span.context.traceFlags.sampled else { return }
        state.enqueue(span.toSpanData())
    }

    /// Seal admission and wait only until the earliest deadline supplied by any caller.
    internal func shutdown(
        deadline requestedDeadline: ContinuousClock.Instant
    ) async -> AviaryTelemetryDrainReceipt {
        var deadline = requestedDeadline
        while true {
            if Task.isCancelled { deadline = min(deadline, ContinuousClock.now) }
            let poll = state.pollDrain(requestedDeadline: deadline, now: ContinuousClock.now)
            if let receipt = poll.receipt {
                state.closeExporter()
                return receipt
            }
            deadline = poll.deadline
            let delay = Self.pollDelayNanoseconds(until: deadline)
            if delay == 0 { continue }
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    /// Provider shutdown is a nonblocking, immediate-abort fallback. Production lifecycle code
    /// should call the async absolute-deadline shutdown above before shutting down the provider.
    internal func shutdown(explicitTimeout: TimeInterval?) {
        _ = state.pollDrain(
            requestedDeadline: ContinuousClock.now, now: ContinuousClock.now)
        state.closeExporter()
    }

    /// Wake the worker and wait for the accepted prefix visible at entry, subject to one local
    /// timeout. This is a processing barrier only; it makes no retention claim.
    internal func forceFlush(timeout: TimeInterval?) {
        state.forceFlush(timeout: min(
            max(0, timeout ?? Self.maximumExportTimeout), Self.maximumExportTimeout))
    }

    deinit {
        _ = state.pollDrain(
            requestedDeadline: ContinuousClock.now, now: ContinuousClock.now)
        state.closeExporter()
    }

    private static func pollDelayNanoseconds(
        until deadline: ContinuousClock.Instant
    ) -> UInt64 {
        let remaining = State.seconds(from: ContinuousClock.now, until: deadline)
        guard remaining > 0 else { return 0 }
        return UInt64(max(1, min(remaining, 0.005) * 1_000_000_000))
    }

    private final class State: @unchecked Sendable {
        private enum Phase: Equatable { case open, draining, quiesced, deadlineExceeded }

        struct DrainPoll {
            let receipt: AviaryTelemetryDrainReceipt?
            let deadline: ContinuousClock.Instant
            let shouldAbort: Bool
        }

        let exporter: any SpanExporter
        let abortClosure: @Sendable () -> Void
        let residentLimit: Int
        let batchLimit: Int
        let scheduleDelay: TimeInterval
        let exportTimeout: TimeInterval
        let condition = NSCondition()

        var queue: [SpanData] = []
        var inFlightSpans = 0
        var residentSpans = 0
        var nextBatchAt: Date?
        var flushTarget = 0
        private var phase: Phase = .open
        var drainDeadline: ContinuousClock.Instant?
        var terminalReceipt: AviaryTelemetryDrainReceipt?
        var worker: Thread?
        var workerStopped = false
        var exporterClosed = false

        var sampledEndedSpans = AviarySaturatingCounter()
        var acceptedSpans = AviarySaturatingCounter()
        var droppedQueueFullSpans = AviarySaturatingCounter()
        var droppedAfterShutdownSpans = AviarySaturatingCounter()
        var exportAttemptedSpans = AviarySaturatingCounter()
        var exportSucceededSpans = AviarySaturatingCounter()
        var exportResultFailureSpans = AviarySaturatingCounter()
        var abandonedBeforeAttemptSpans = AviarySaturatingCounter()
        var exportBatchAttempts = AviarySaturatingCounter()
        var exportBatchSuccesses = AviarySaturatingCounter()
        var exportBatchResultFailures = AviarySaturatingCounter()
        var drainStarts = AviarySaturatingCounter()
        var drainQuiesced = AviarySaturatingCounter()
        var drainDeadlineExceeded = AviarySaturatingCounter()
        var resolvedAcceptedSpans = AviarySaturatingCounter()

        init(
            exporter: any SpanExporter, residentLimit: Int, batchLimit: Int,
            scheduleDelay: TimeInterval, exportTimeout: TimeInterval,
            abortExporter: @escaping @Sendable () -> Void
        ) {
            self.exporter = exporter
            abortClosure = abortExporter
            self.residentLimit = residentLimit
            self.batchLimit = min(batchLimit, residentLimit)
            self.scheduleDelay = scheduleDelay
            self.exportTimeout = exportTimeout
        }

        func start() {
            let thread = Thread { [weak self] in self?.runWorker() }
            thread.name = "aviary.telemetry.export"
            condition.lock()
            worker = thread
            condition.unlock()
            thread.start()
        }

        func closeExporter() {
            condition.lock()
            let shouldClose = !exporterClosed
            exporterClosed = true
            condition.unlock()
            if shouldClose { abortClosure() }
        }

        func enqueue(_ span: SpanData) {
            condition.lock()
            defer { condition.unlock() }
            sampledEndedSpans.add()
            guard phase == .open else {
                droppedAfterShutdownSpans.add()
                return
            }
            guard residentSpans < residentLimit else {
                droppedQueueFullSpans.add()
                return
            }
            let wasEmpty = queue.isEmpty
            queue.append(span)
            residentSpans += 1
            acceptedSpans.add()
            if wasEmpty { nextBatchAt = Date().addingTimeInterval(scheduleDelay) }
            condition.broadcast()
        }

        func diagnostics() -> AviaryTelemetryExportDiagnostics {
            condition.lock()
            defer { condition.unlock() }
            return diagnosticsLocked()
        }

        func pollDrain(
            requestedDeadline: ContinuousClock.Instant,
            now: ContinuousClock.Instant
        ) -> DrainPoll {
            condition.lock()
            defer { condition.unlock() }
            if let terminalReceipt {
                return DrainPoll(
                    receipt: terminalReceipt,
                    deadline: drainDeadline ?? requestedDeadline,
                    shouldAbort: false)
            }
            if phase == .open {
                phase = .draining
                drainStarts.add()
                drainDeadline = requestedDeadline
                condition.broadcast()
            } else if phase == .draining,
                      let existing = drainDeadline,
                      requestedDeadline < existing {
                drainDeadline = requestedDeadline
                condition.broadcast()
            }
            let sharedDeadline = drainDeadline ?? requestedDeadline
            if queue.isEmpty, inFlightSpans == 0 {
                drainQuiesced.add()
                phase = .quiesced
                let receipt = AviaryTelemetryDrainReceipt(
                    outcome: .quiesced, unconfirmedAtDeadlineSpans: 0,
                    diagnostics: diagnosticsLocked())
                terminalReceipt = receipt
                condition.broadcast()
                return DrainPoll(
                    receipt: receipt, deadline: sharedDeadline, shouldAbort: false)
            }
            guard now >= sharedDeadline else {
                return DrainPoll(receipt: nil, deadline: sharedDeadline, shouldAbort: false)
            }
            return expireDrainLocked(deadline: sharedDeadline)
        }

        func forceFlush(timeout: TimeInterval) {
            condition.lock()
            guard phase == .open else {
                condition.unlock()
                return
            }
            let target = acceptedSpans.value
            guard resolvedAcceptedSpans.value < target else {
                condition.unlock()
                return
            }
            flushTarget = max(flushTarget, target)
            condition.broadcast()
            let deadline = Date().addingTimeInterval(timeout)
            while phase == .open, resolvedAcceptedSpans.value < target,
                  condition.wait(until: deadline) {}
            condition.unlock()
        }

        private func runWorker() {
            while true {
                condition.lock()
                if phase == .draining, let deadline = drainDeadline,
                   ContinuousClock.now >= deadline {
                    let poll = expireDrainLocked(deadline: deadline)
                    condition.unlock()
                    if poll.shouldAbort { closeExporter() }
                    continue
                }
                switch phase {
                case .quiesced, .deadlineExceeded:
                    workerStopped = true
                    condition.broadcast()
                    condition.unlock()
                    return
                case .draining where queue.isEmpty && inFlightSpans == 0:
                    workerStopped = true
                    drainQuiesced.add()
                    phase = .quiesced
                    let receipt = AviaryTelemetryDrainReceipt(
                        outcome: .quiesced, unconfirmedAtDeadlineSpans: 0,
                        diagnostics: diagnosticsLocked())
                    terminalReceipt = receipt
                    condition.broadcast()
                    condition.unlock()
                    return
                case .open where queue.isEmpty:
                    condition.wait()
                    condition.unlock()
                    continue
                default:
                    break
                }

                if phase == .open {
                    let flushRequested = resolvedAcceptedSpans.value < flushTarget
                    let batchReady = queue.count >= batchLimit
                    let scheduled = nextBatchAt ?? Date()
                    if !flushRequested, !batchReady, Date() < scheduled {
                        _ = condition.wait(until: scheduled)
                        condition.unlock()
                        continue
                    }
                }

                guard !queue.isEmpty else {
                    condition.unlock()
                    continue
                }
                let count = min(batchLimit, queue.count)
                let batch = Array(queue.prefix(count))
                queue.removeFirst(count)
                inFlightSpans = count
                nextBatchAt = queue.isEmpty ? nil : Date()
                exportAttemptedSpans.add(count)
                exportBatchAttempts.add()
                let timeout: TimeInterval
                if phase == .draining, let deadline = drainDeadline {
                    timeout = min(exportTimeout, max(0.001,
                        Self.seconds(from: ContinuousClock.now, until: deadline)))
                } else {
                    timeout = exportTimeout
                }
                condition.unlock()

                let result = exporter.export(spans: batch, explicitTimeout: timeout)

                condition.lock()
                var shouldAbort = false
                // Preserve the state at the absolute deadline before recording a result which
                // arrived too late. In particular, the receipt must retain this batch as
                // unconfirmed-at-deadline even if the exporter returns immediately afterward.
                if phase == .draining, let deadline = drainDeadline,
                   ContinuousClock.now >= deadline {
                    shouldAbort = expireDrainLocked(deadline: deadline).shouldAbort
                }
                switch result {
                case .success:
                    exportSucceededSpans.add(count)
                    exportBatchSuccesses.add()
                case .failure:
                    exportResultFailureSpans.add(count)
                    exportBatchResultFailures.add()
                }
                resolvedAcceptedSpans.add(count)
                residentSpans -= count
                inFlightSpans = 0
                if resolvedAcceptedSpans.value >= flushTarget { flushTarget = 0 }
                condition.broadcast()
                condition.unlock()
                if shouldAbort { closeExporter() }
            }
        }

        private func expireDrainLocked(
            deadline: ContinuousClock.Instant
        ) -> DrainPoll {
            guard terminalReceipt == nil else {
                return DrainPoll(
                    receipt: terminalReceipt, deadline: deadline, shouldAbort: false)
            }
            let abandoned = queue.count
            queue.removeAll(keepingCapacity: false)
            nextBatchAt = nil
            residentSpans -= abandoned
            abandonedBeforeAttemptSpans.add(abandoned)
            resolvedAcceptedSpans.add(abandoned)
            drainDeadlineExceeded.add()
            phase = .deadlineExceeded
            condition.broadcast()
            let receipt = AviaryTelemetryDrainReceipt(
                outcome: .deadlineExceeded,
                unconfirmedAtDeadlineSpans: inFlightSpans,
                diagnostics: diagnosticsLocked())
            terminalReceipt = receipt
            return DrainPoll(receipt: receipt, deadline: deadline, shouldAbort: true)
        }

        private func diagnosticsLocked() -> AviaryTelemetryExportDiagnostics {
            let counters = [sampledEndedSpans, acceptedSpans, droppedQueueFullSpans,
                droppedAfterShutdownSpans, exportAttemptedSpans, exportSucceededSpans,
                exportResultFailureSpans, abandonedBeforeAttemptSpans, exportBatchAttempts,
                exportBatchSuccesses, exportBatchResultFailures, drainStarts, drainQuiesced,
                drainDeadlineExceeded, resolvedAcceptedSpans]
            return AviaryTelemetryExportDiagnostics(
                sampledEndedSpans: sampledEndedSpans.value,
                acceptedSpans: acceptedSpans.value,
                droppedQueueFullSpans: droppedQueueFullSpans.value,
                droppedAfterShutdownSpans: droppedAfterShutdownSpans.value,
                exportAttemptedSpans: exportAttemptedSpans.value,
                exportSucceededSpans: exportSucceededSpans.value,
                exportResultFailureSpans: exportResultFailureSpans.value,
                abandonedBeforeAttemptSpans: abandonedBeforeAttemptSpans.value,
                exportBatchAttempts: exportBatchAttempts.value,
                exportBatchSuccesses: exportBatchSuccesses.value,
                exportBatchResultFailures: exportBatchResultFailures.value,
                drainStarts: drainStarts.value,
                drainQuiesced: drainQuiesced.value,
                drainDeadlineExceeded: drainDeadlineExceeded.value,
                queuedSpans: queue.count,
                inFlightSpans: inFlightSpans,
                workerStopped: workerStopped,
                countersSaturated: counters.contains(where: \.saturated))
        }

        static func seconds(
            from start: ContinuousClock.Instant,
            until deadline: ContinuousClock.Instant
        ) -> TimeInterval {
            guard start < deadline else { return 0 }
            let components = start.duration(to: deadline).components
            return max(0,
                Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        }
    }
}
