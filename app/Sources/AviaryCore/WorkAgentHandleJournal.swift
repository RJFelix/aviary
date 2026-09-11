import Foundation

/// One host-owned writer route per Work. All pilot Run-bundle opens must pass through this
/// instance. It borrows that bundle's existing writer while open, and serializes cold appends
/// with replacement opens after End. It never opens a second writer behind a live writer's
/// append-chain cache. This is host-internal coordination, not a remotely authorized API.
internal actor WorkAgentHandleJournal {
    enum Failure: Error, Equatable { case wrongWork, writerStillOpen, unavailable, capacity }

    let work: WorkRef
    private let home: AgentHome
    private let actor: TimelineActor
    private var bundle: RunJournalBundle?
    private var gateHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(home: AgentHome, work: WorkRef, actor: TimelineActor) throws {
        guard try home.requirePersistedWorkHostID() == work.workHostID else { throw Failure.wrongWork }
        self.home = home
        self.work = work
        self.actor = actor
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
                return try await bundle.appendAgentHandle(draft)
            case .closed:
                self.bundle = nil
            case .failed:
                throw Failure.unavailable
            }
        }
        let writer = try coldWriter()
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
                return try await bundle.agentHandleHead()
            case .closed:
                self.bundle = nil
            case .failed:
                throw Failure.unavailable
            }
        }
        let writer = try coldWriter()
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
            allowTruncatedTail: false)
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
