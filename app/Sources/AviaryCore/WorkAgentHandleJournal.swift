import Foundation

/// One host-owned writer route per Work. All pilot Run-bundle opens must pass through this
/// instance. It borrows that bundle's existing writer while open, and serializes cold appends
/// with replacement opens after End. It never opens a second writer behind a live writer's
/// append-chain cache. This is host-internal coordination, not a remotely authorized API.
internal actor WorkAgentHandleJournal {
    enum Failure: Error, Equatable { case wrongWork, writerStillOpen, unavailable, capacity }

    struct ColdWriterRetryPolicy: Sendable {
        static let production = ColdWriterRetryPolicy(
            maximumWaitNanoseconds: 5_000_000_000,
            maximumOpenAttempts: 256,
            initialDelayNanoseconds: 10_000_000,
            maximumDelayNanoseconds: 100_000_000)

        let maximumWaitNanoseconds: UInt64
        let maximumOpenAttempts: Int
        let initialDelayNanoseconds: UInt64
        let maximumDelayNanoseconds: UInt64

        init(
            maximumWaitNanoseconds: UInt64,
            maximumOpenAttempts: Int,
            initialDelayNanoseconds: UInt64,
            maximumDelayNanoseconds: UInt64
        ) {
            self.maximumWaitNanoseconds = maximumWaitNanoseconds
            self.maximumOpenAttempts = max(1, maximumOpenAttempts)
            self.initialDelayNanoseconds = max(1, initialDelayNanoseconds)
            self.maximumDelayNanoseconds = max(
                self.initialDelayNanoseconds, maximumDelayNanoseconds)
        }
    }

    let work: WorkRef
    private let home: AgentHome
    private let actor: TimelineActor
    private let beforeBundleAgentAppend: (@Sendable () async -> Void)?
    private let coldWriterRetryPolicy: ColdWriterRetryPolicy
    private let coldWriterFailurePlan: TimelineJournalWriter.FailurePlan
    private let didEncounterColdWriterContention: (@Sendable (Int) async -> Void)?
    private var bundle: RunJournalBundle?
    private var gateHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        home: AgentHome, work: WorkRef, actor: TimelineActor,
        beforeBundleAgentAppend: (@Sendable () async -> Void)? = nil,
        coldWriterRetryPolicy: ColdWriterRetryPolicy = .production,
        coldWriterFailurePlan: TimelineJournalWriter.FailurePlan = .none,
        didEncounterColdWriterContention: (@Sendable (Int) async -> Void)? = nil
    ) throws {
        guard try home.requirePersistedWorkHostID() == work.workHostID else { throw Failure.wrongWork }
        self.home = home
        self.work = work
        self.actor = actor
        self.beforeBundleAgentAppend = beforeBundleAgentAppend
        self.coldWriterRetryPolicy = coldWriterRetryPolicy
        self.coldWriterFailurePlan = coldWriterFailurePlan
        self.didEncounterColdWriterContention = didEncounterColdWriterContention
    }

    /// The closure only opens a bundle; it must not call this route recursively or start agent
    /// execution. The bundle becomes the published writer route before this method returns.
    func openRun(
        using open: @Sendable () async throws -> RunJournalBundle
    ) async throws -> RunJournalBundle {
        try await withRunOpen {
            let bundle = try await open()
            return (bundle: bundle, value: bundle)
        }
    }

    /// Compose a native bridge under the same route admission as its Bundle. Returning a
    /// bridge first and registering its writer later would leave a competing-open window.
    func withRunOpen<Value: Sendable>(
        using open: @Sendable () async throws -> (bundle: RunJournalBundle, value: Value)
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        if let bundle {
            guard await bundle.writersClosed else { throw Failure.writerStillOpen }
            self.bundle = nil
        }
        let result = try await open()
        let opened = result.bundle
        guard opened.work == work, opened.workJournal == JournalRef.work(work, journalID: "work"),
              await opened.ownsAgentHandleJournal(at: home.timelineV2WorkJournalURL(work)) else {
            try await opened.closeChecked()
            throw Failure.wrongWork
        }
        bundle = opened
        return result.value
    }

    func append(_ draft: TimelineEventDraft) async throws -> TimelineJournalCommit {
        try await acquire()
        defer { release() }
        guard draft.work == work, draft.workHost == WorkHostRef(work.workHostID) else {
            throw Failure.wrongWork
        }
        if let bundle {
            if await bundle.writersClosed { self.bundle = nil }
        }
        if let bundle {
            switch await bundle.status.health {
            case .healthy:
                await beforeBundleAgentAppend?()
                do {
                    return try await bundle.appendAgentHandle(draft)
                } catch RunJournalBundleError.closedBeforeAgentAppend {
                    guard await bundle.writersClosed,
                          await bundle.status.health == .closed else {
                        throw RunJournalBundleError.closedBeforeAgentAppend
                    }
                    self.bundle = nil
                    return try await appendColdLocked(draft)
                }
            case .closed:
                self.bundle = nil
            case .failed:
                throw Failure.unavailable
            }
        }
        return try await appendColdLocked(draft)
    }

    private func appendColdLocked(
        _ draft: TimelineEventDraft
    ) async throws -> TimelineJournalCommit {
        let writer = try await openColdWriterLocked()
        do {
            let result = try await writer.appendAgentHandle(draft)
            try await writer.closeChecked()
            return result
        } catch {
            // An append/close error can follow a durable write. Keep it uncertain; callers
            // must read canonical Handle evidence before deciding whether another append is safe.
            try? await writer.closeChecked()
            throw error
        }
    }

    func read() async throws -> BoundedWorkReducerHead {
        try await acquire()
        defer { release() }
        if let bundle {
            if await bundle.writersClosed { self.bundle = nil }
        }
        if let bundle {
            switch await bundle.status.health {
            case .healthy:
                do {
                    return try await bundle.agentHandleHead()
                } catch {
                    // A canonical read is safe to repeat. If close won after this route chose
                    // the bundle, wait for the bundle's exact closed state before reopening.
                    guard await bundle.writersClosed else { throw error }
                    self.bundle = nil
                    return try await readColdLocked()
                }
            case .closed:
                self.bundle = nil
            case .failed:
                throw Failure.unavailable
            }
        }
        return try await readColdLocked()
    }

    private func readColdLocked() async throws -> BoundedWorkReducerHead {
        let writer = try await openColdWriterLocked()
        do {
            let read = try await writer.readCanonicalProjection(
                expectedWork: work, expectedWorkHost: WorkHostRef(work.workHostID),
                maximumResidentRecords: 0)
            try await writer.closeChecked()
            guard case .work(let head) = read.projection, head.coverage.isControlling,
                  head.coverage.isIndexComplete(.agentHandles) else { throw Failure.unavailable }
            return head
        } catch {
            try? await writer.closeChecked()
            throw error
        }
    }

    private func coldWriter() throws -> TimelineJournalWriter {
        try TimelineJournalWriter(
            reopeningStreaming: home.timelineV2WorkJournalURL(work),
            journal: JournalRef.work(work, journalID: "work"), actor: actor, home: home,
            allowTruncatedTail: false, failurePlan: coldWriterFailurePlan)
    }

    /// A cold constructor has not admitted a mutation, so the single typed owner-lock conflict is
    /// safe to retry. Once a writer opens, append and close errors remain uncertain and are never
    /// retried here. Cancellation does not abandon already-running child settlement; each delay is
    /// performed by an awaited cancellation-independent task. The monotonic budget bounds retries;
    /// successful construction still pays the separately documented journal replay cost.
    private func openColdWriterLocked() async throws -> TimelineJournalWriter {
        let started = DispatchTime.now().uptimeNanoseconds
        var delay = coldWriterRetryPolicy.initialDelayNanoseconds
        var attempt = 0
        var contended = false
        var acquired = false
        defer {
            if contended {
                let ended = DispatchTime.now().uptimeNanoseconds
                AviaryTelemetry.event("aviary.agent_child.journal_acquisition", attributes: [
                    "aviary.work.id": .string(AviaryTelemetry.workIdentity(work)),
                    "aviary.outcome": .string(acquired ? "accepted" : "unavailable"),
                    "aviary.journal.open_attempts": .int(attempt),
                    "aviary.journal.acquisition.seconds": .double(
                        Double(ended >= started ? ended - started : 0) / 1_000_000_000),
                ])
            }
        }
        while true {
            attempt += 1
            do {
                let writer = try coldWriter()
                acquired = true
                return writer
            } catch let error as TimelineJournalWriter.WriterError {
                guard case .competingWriter = error else { throw error }
                contended = true
                await didEncounterColdWriterContention?(attempt)

                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = now >= started ? now - started : 0
                guard attempt < coldWriterRetryPolicy.maximumOpenAttempts,
                      elapsed < coldWriterRetryPolicy.maximumWaitNanoseconds else {
                    throw error
                }
                let remaining = coldWriterRetryPolicy.maximumWaitNanoseconds - elapsed
                await Self.sleepIgnoringCancellation(nanoseconds: min(delay, remaining))
                delay = min(
                    coldWriterRetryPolicy.maximumDelayNanoseconds,
                    delay > UInt64.max / 2 ? UInt64.max : delay * 2)
            }
        }
    }

    private nonisolated static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        await Task.detached {
            try? await Task.sleep(nanoseconds: nanoseconds)
        }.value
    }

    private func acquire() async throws {
        if !gateHeld { gateHeld = true; return }
        guard waiters.count < 64 else { throw Failure.capacity }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { gateHeld = false }
        else { waiters.removeFirst().resume() }
    }
}
