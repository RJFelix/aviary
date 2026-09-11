import Foundation

internal protocol WorkAgentChildExecution: Sendable {
    func execute() async -> AgentChildExecutionResult
    func cancel() async -> AgentChildCancellationOutcome
}

extension AgentChildExecutionResource: WorkAgentChildExecution {}

/// Host-internal owner for admission, execution lifetime, and canonical agent Handle records.
/// This actor has no durable registry of its own: after process loss a live canonical Handle is
/// explicitly unavailable, never reconstructed or reported as terminal.
internal actor WorkAgentChildCoordinator {
    typealias ExecutionFactory = @Sendable (HandleRef, Date) -> any WorkAgentChildExecution
    typealias BeforeStartCommit = @Sendable () async -> Void

    static let maximumPromptBytes = 64 * 1_024
    static let maximumRegisteredWorks = 256
    static let maximumAwaitObserversPerHandle = 64
    static let maximumAwaitObserverIDBytes = 512

    enum Failure: Error, Equatable, Sendable {
        case unregisteredWork, wrongOrigin, capacity, alreadyTerminal, notCancelable
        case commandNotQualified, bodyUnavailable, ambiguous
        case admissionUncertain(HandleRef)
        case invalidRequest(String)
    }

    struct Admission: Sendable, Equatable { let handle: HandleRef; let deadline: Date }
    enum BodyAvailability: Sendable, Equatable {
        case available(Data)
        case absent
        case unavailable
    }
    struct ReadResult: Sendable {
        let record: BoundedWorkAgentHandleIndexRecord
        let request: BodyAvailability
        let result: BodyAvailability
    }
    enum CancellationResult: Sendable, Equatable {
        case accepted, alreadyRequested
        case alreadyTerminal(WorkAgentHandleTerminalOutcome?)
        case unavailable
        case ambiguous
    }
    enum InterestResult: Sendable, Equatable { case accepted, notQueued }

    private struct Route {
        let journal: WorkAgentHandleJournal
        let bodyStore: ContextBodyStore
    }
    private struct Key: Hashable, Sendable { let work: WorkRef; let handle: HandleRef }
    private enum Phase: Sendable {
        case admitting, queued, starting, running, cancelRequested, settling
        case terminalUnquiesced, ambiguous
    }
    private enum MutationReconciliation {
        case cancellationCommitted
        case terminal(WorkAgentHandleTerminalOutcome?)
        case unchanged
        case uncertain
    }
    private struct ExecutionSettlement: Sendable {
        let result: AgentChildExecutionResult
        let settledAt: Date
    }
    private struct Entry {
        let work: WorkRef
        let origin: WorkAgentHandleOrigin
        let handle: HandleRef
        let label: String
        let deadline: Date
        let requestBody: TimelineBodyReference
        let reservation: WorkAgentChildAdmissionQueue.Reservation
        var factory: ExecutionFactory?
        var latestLifecycleEvent: EventRef?
        var phase: Phase
        var cancellationCause: WorkAgentHandleCancellationCause?
        var resource: (any WorkAgentChildExecution)?
        var terminalOutcome: WorkAgentHandleTerminalOutcome?
        var executionSettlement: ExecutionSettlement?
        var executionTask: Task<Void, Never>?
        var deadlineTask: Task<Void, Never>?
    }

    private let limits: WorkAgentChildAdmissionQueue.Limits
    private let beforeStartCommit: BeforeStartCommit?
    private var queue: WorkAgentChildAdmissionQueue
    private var routes: [WorkRef: Route] = [:]
    private var entries: [Key: Entry] = [:]
    private var awaitObservers: [Key: Set<String>] = [:]
    private var lifecycleGateHeld = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        limits: WorkAgentChildAdmissionQueue.Limits? = nil,
        beforeStartCommit: BeforeStartCommit? = nil
    ) throws {
        let chosen = try limits ?? WorkAgentChildAdmissionQueue.Limits()
        self.limits = chosen
        self.beforeStartCommit = beforeStartCommit
        queue = WorkAgentChildAdmissionQueue(limits: chosen)
    }

    func register(work: WorkRef, home: AgentHome, actor: TimelineActor) async throws {
        await acquireLifecycleGate()
        defer { releaseLifecycleGate() }
        if routes[work] != nil { return }
        guard routes.count < Self.maximumRegisteredWorks else { throw Failure.capacity }
        routes[work] = Route(
            journal: try WorkAgentHandleJournal(home: home, work: work, actor: actor),
            bodyStore: ContextBodyStore(home: home))
    }

    /// All pilot Run bundles must be opened through the registered route.
    func openRun(
        work: WorkRef, using open: @Sendable () async throws -> RunJournalBundle
    ) async throws -> RunJournalBundle {
        await acquireLifecycleGate()
        defer { releaseLifecycleGate() }
        guard let route = routes[work] else { throw Failure.unregisteredWork }
        return try await route.journal.openRun(using: open)
    }

    func withRunOpen<Value: Sendable>(
        work: WorkRef,
        using open: @Sendable () async throws -> (bundle: RunJournalBundle, value: Value)
    ) async throws -> Value {
        await acquireLifecycleGate()
        defer { releaseLifecycleGate() }
        guard let route = routes[work] else { throw Failure.unregisteredWork }
        return try await route.journal.withRunOpen(using: open)
    }

    func admit(
        origin binding: WorkRunBinding,
        prompt: String,
        label: String,
        deadline: Date,
        makeExecution: @escaping ExecutionFactory,
        now: Date = Date()
    ) async throws -> Admission {
        await acquireLifecycleGate()
        defer { releaseLifecycleGate() }
        let work = binding.workBinding.work
        guard let route = routes[work] else { throw Failure.unregisteredWork }
        guard binding.workBinding.workHost == WorkHostRef(work.workHostID) else {
            throw Failure.wrongOrigin
        }
        guard now.timeIntervalSince1970.isFinite,
              deadline.timeIntervalSince1970.isFinite, deadline > now else {
            throw Failure.invalidRequest("deadline must be finite and in the future")
        }
        guard !label.isEmpty,
              label == label.trimmingCharacters(in: .whitespacesAndNewlines),
              label.utf8.count <= WorkAgentHandleSnapshot.maximumLabelBytes else {
            throw Failure.invalidRequest("label must be non-empty, trimmed, and at most 256 bytes")
        }
        let promptBytes = Data(prompt.utf8)
        guard !promptBytes.isEmpty else { throw Failure.invalidRequest("prompt is empty") }
        guard promptBytes.count <= Self.maximumPromptBytes else {
            throw Failure.invalidRequest("prompt exceeds 64 KiB")
        }

        let handle = HandleRef("agent-child-\(UUID().uuidString.lowercased())")
        let reservation: WorkAgentChildAdmissionQueue.Reservation
        do {
            // Reserve before the body write or first journal await.
            reservation = try queue.reserve(
                work: work, handle: handle, deadline: deadline, now: now)
        } catch { throw Failure.capacity }
        let requestBody: TimelineBodyReference
        do {
            requestBody = try route.bodyStore.retain(
                promptBytes, authority: JournalRef.work(work, journalID: "work"),
                mediaType: "text/plain")
        } catch {
            try? queue.abandonUncommitted(reservation)
            throw error
        }
        let origin = WorkAgentHandleOrigin(
            work: work, workHost: binding.workBinding.workHost,
            session: binding.workBinding.session,
            sessionAttachment: binding.workBinding.sessionAttachment, run: binding.run)
        let key = Key(work: work, handle: handle)
        entries[key] = Entry(
            work: work, origin: origin, handle: handle, label: label, deadline: deadline,
            requestBody: requestBody, reservation: reservation, factory: makeExecution,
            latestLifecycleEvent: nil, phase: .admitting, cancellationCause: nil,
            resource: nil, terminalOutcome: nil, executionSettlement: nil,
            executionTask: nil, deadlineTask: nil)
        do {
            let commit = try await route.journal.append(draft(
                type: TimelineEventType.agentHandleQueued, entry: entries[key]!,
                payload: WorkAgentHandleQueuedPayload(
                    origin: origin, label: label, deadline: deadline, requestBody: requestBody)))
            try queue.commit(reservation)
            entries[key]?.latestLifecycleEvent = commit.eventRef
            entries[key]?.phase = .queued
        } catch let appendError {
            let canonical: BoundedWorkAgentHandleIndexRecord?
            do { canonical = try await canonicalRecord(route: route, handle: handle) }
            catch {
                entries[key]?.phase = .ambiguous
                entries[key]?.factory = nil
                scheduleDeadlineLocked(for: key)
                throw Failure.admissionUncertain(handle)
            }
            if let record = canonical, record.origin == origin,
               record.requestBody == requestBody, record.state == .queued {
                try queue.commit(reservation)
                entries[key]?.latestLifecycleEvent = record.latestLifecycleEvent
                entries[key]?.phase = .queued
            } else if canonical == nil {
                try? queue.abandonUncommitted(reservation)
                entries.removeValue(forKey: key)
                throw appendError
            } else {
                entries[key]?.phase = .ambiguous
                entries[key]?.factory = nil
                scheduleDeadlineLocked(for: key)
                throw Failure.admissionUncertain(handle)
            }
        }
        scheduleDeadlineLocked(for: key)
        await pumpLocked(now: Date())
        return Admission(handle: handle, deadline: deadline)
    }

    func read(work: WorkRef, handle: HandleRef) async throws -> ReadResult {
        await acquireLifecycleGate()
        defer { releaseLifecycleGate() }
        guard let route = routes[work] else { throw Failure.unregisteredWork }
        guard let record = try await canonicalRecord(route: route, handle: handle) else {
            throw Failure.bodyUnavailable
        }
        return ReadResult(
            record: record, request: bodyAvailability(record.requestBody, store: route.bodyStore),
            result: record.resultBody.map { bodyAvailability($0, store: route.bodyStore) } ?? .absent)
    }

    /// Metadata-only canonical polling. This does not load request or result body bytes.
    func inspect(
        work: WorkRef, handle: HandleRef
    ) async throws -> BoundedWorkAgentHandleIndexRecord {
        await acquireLifecycleGate()
        defer { releaseLifecycleGate() }
        guard let route = routes[work] else { throw Failure.unregisteredWork }
        guard let record = try await canonicalRecord(route: route, handle: handle) else {
            throw Failure.bodyUnavailable
        }
        return record
    }

    func awaitInterest(
        work: WorkRef, handle: HandleRef, awaited: Bool
    ) async throws -> InterestResult {
        try await awaitInterest(
            work: work, handle: handle,
            observerID: "internal-singleton-observer", awaited: awaited)
    }

    /// `observerID` is opaque to the coordinator. Bridge callers must qualify it with the
    /// observing Run, delegate, and Future identities so independent Sessions cannot collide.
    func awaitInterest(
        work: WorkRef, handle: HandleRef, observerID: String, awaited: Bool
    ) async throws -> InterestResult {
        await acquireLifecycleGate()
        defer { releaseLifecycleGate() }
        let key = Key(work: work, handle: handle)
        guard let entry = entries[key] else { throw Failure.unregisteredWork }
        guard entry.phase == .queued else { return .notQueued }
        guard !observerID.isEmpty,
              observerID == observerID.trimmingCharacters(in: .whitespacesAndNewlines),
              observerID.utf8.count <= Self.maximumAwaitObserverIDBytes else {
            throw Failure.invalidRequest(
                "await observer identity must be non-empty, trimmed, and at most 512 bytes")
        }
        var observers = awaitObservers[key] ?? []
        if awaited {
            guard observers.contains(observerID)
                    || observers.count < Self.maximumAwaitObserversPerHandle else {
                throw Failure.capacity
            }
            observers.insert(observerID)
        } else {
            observers.remove(observerID)
        }
        if observers.isEmpty { awaitObservers.removeValue(forKey: key) }
        else { awaitObservers[key] = observers }
        try queue.setAwaitInterest(entry.reservation, awaited: !observers.isEmpty)
        await pumpLocked(now: Date())
        return .accepted
    }

    func cancel(
        work: WorkRef, handle: HandleRef, command: CommandRef
    ) async throws -> CancellationResult {
        await acquireLifecycleGate()
        let key = Key(work: work, handle: handle)
        guard let route = routes[work] else {
            releaseLifecycleGate(); throw Failure.unregisteredWork
        }
        guard command.client != nil,
              !command.commandID.isEmpty,
              command.commandID == command.commandID.trimmingCharacters(in: .whitespacesAndNewlines),
              command.sessionAttachment != nil,
              let cursor = command.causalCursor,
              cursor.journal == JournalRef.work(work, journalID: "work") else {
            releaseLifecycleGate(); throw Failure.commandNotQualified
        }
        guard var entry = entries[key] else {
            let record: BoundedWorkAgentHandleIndexRecord?
            do { record = try await canonicalRecord(route: route, handle: handle) }
            catch {
                releaseLifecycleGate()
                throw error
            }
            releaseLifecycleGate()
            guard let record else { throw Failure.bodyUnavailable }
            return record.state == .terminal || record.state == .reaped
                ? .alreadyTerminal(record.terminalOutcome) : .unavailable
        }
        if entry.phase == .ambiguous {
            guard let record = await canonicalRecordIfAvailable(route: route, handle: handle),
                  record.origin == entry.origin else {
                releaseLifecycleGate(); return .ambiguous
            }
            if record.state == .terminal || record.state == .reaped {
                applyCanonicalTerminalLocked(record, key: key)
                releaseLifecycleGate()
                return .alreadyTerminal(record.terminalOutcome)
            }
            // Never launch after an ambiguous start. Only a proven queued state can accept a
            // later explicit cancellation; running without this owner remains unavailable.
            entry.latestLifecycleEvent = record.latestLifecycleEvent
            entry.phase = record.state == .queued ? .queued
                : record.state == .cancelRequested ? .cancelRequested : .ambiguous
            entry.cancellationCause = record.cancellationCause
            entries[key] = entry
            if record.state == .cancelRequested {
                if let settlement = entry.executionSettlement {
                    await settleExecutionLocked(key: key, route: route, settlement: settlement)
                    releaseLifecycleGate()
                    return .alreadyRequested
                }
                if entry.resource == nil, record.startedEvent == nil {
                    let outcome: WorkAgentHandleTerminalOutcome =
                        record.cancellationCause == .deadline ? .expired : .canceled
                    do {
                        try await terminalizeQueuedLocked(
                            key: key, route: route, outcome: outcome)
                    } catch {
                        if case .terminal = await reconcileMutationFailureLocked(
                            key: key, route: route) {
                            // Matching terminal proof already settled the reservation.
                        } else { entries[key]?.phase = .ambiguous }
                    }
                    await pumpLocked(now: Date())
                    releaseLifecycleGate()
                    return .alreadyRequested
                }
                if entry.resource == nil {
                    entries[key]?.phase = .ambiguous
                    releaseLifecycleGate()
                    return .ambiguous
                }
            }
        }
        guard let current = entries[key] else {
            releaseLifecycleGate(); return .ambiguous
        }
        switch current.phase {
        case .cancelRequested:
            let resource = current.resource
            releaseLifecycleGate()
            if let resource { _ = await resource.cancel() }
            return .alreadyRequested
        case .settling:
            releaseLifecycleGate(); return .alreadyRequested
        case .terminalUnquiesced:
            releaseLifecycleGate(); return .alreadyTerminal(current.terminalOutcome)
        case .ambiguous, .starting, .admitting:
            releaseLifecycleGate(); return .ambiguous
        case .queued:
            do {
                let commit = try await appendCancellationLocked(
                    entry: current, route: route, cause: .client, command: command)
                entries[key]?.latestLifecycleEvent = commit.eventRef
                entries[key]?.phase = .cancelRequested
                entries[key]?.cancellationCause = .client
            } catch let appendError {
                switch await reconcileMutationFailureLocked(key: key, route: route) {
                case .cancellationCommitted:
                    entries[key]?.cancellationCause = .client
                case .terminal(let outcome):
                    releaseLifecycleGate(); return .alreadyTerminal(outcome)
                case .unchanged:
                    releaseLifecycleGate(); throw appendError
                case .uncertain:
                    releaseLifecycleGate(); return .ambiguous
                }
            }
            do { try queue.cancelQueued(current.reservation) }
            catch {
                entries[key]?.phase = .ambiguous
                releaseLifecycleGate(); return .ambiguous
            }
            do {
                try await terminalizeQueuedLocked(key: key, route: route, outcome: .canceled)
                await pumpLocked(now: Date())
                releaseLifecycleGate()
                return .accepted
            } catch {
                switch await reconcileMutationFailureLocked(key: key, route: route) {
                case .terminal:
                    await pumpLocked(now: Date())
                    releaseLifecycleGate(); return .accepted
                case .cancellationCommitted:
                    entries[key]?.phase = .ambiguous
                    releaseLifecycleGate(); return .accepted
                case .unchanged, .uncertain:
                    entries[key]?.phase = .ambiguous
                    releaseLifecycleGate(); return .ambiguous
                }
            }
        case .running:
            do {
                let commit = try await appendCancellationLocked(
                    entry: current, route: route, cause: .client, command: command)
                entries[key]?.latestLifecycleEvent = commit.eventRef
                entries[key]?.phase = .cancelRequested
                entries[key]?.cancellationCause = .client
                let resource = entries[key]?.resource
                releaseLifecycleGate()
                if let resource { _ = await resource.cancel() }
                return .accepted
            } catch let appendError {
                let result = await reconcileMutationFailureLocked(key: key, route: route)
                let resource: (any WorkAgentChildExecution)?
                switch result {
                case .cancellationCommitted:
                    entries[key]?.cancellationCause = .client
                    resource = entries[key]?.resource
                case .terminal(let outcome):
                    releaseLifecycleGate(); return .alreadyTerminal(outcome)
                case .unchanged:
                    releaseLifecycleGate(); throw appendError
                case .uncertain:
                    releaseLifecycleGate(); return .ambiguous
                }
                releaseLifecycleGate()
                if let resource { _ = await resource.cancel() }
                return .accepted
            }
        }
    }

    /// Called only with the lifecycle gate held. Resource execution is launched in its own task.
    private func pumpLocked(now: Date) async {
        while let decision = try? queue.next(now: now) {
            switch decision {
            case .expireBeforeExecution(let reservation):
                let key = Key(work: reservation.work, handle: reservation.handle)
                guard let entry = entries[key], entry.phase == .queued,
                      let route = routes[entry.work] else { continue }
                entries[key]?.phase = .settling
                entries[key]?.cancellationCause = .deadline
                do {
                    let commit = try await appendCancellationLocked(
                        entry: entry, route: route, cause: .deadline, command: nil)
                    entries[key]?.latestLifecycleEvent = commit.eventRef
                    entries[key]?.phase = .cancelRequested
                } catch {
                    switch await reconcileMutationFailureLocked(key: key, route: route) {
                    case .terminal:
                        continue
                    case .cancellationCommitted:
                        entries[key]?.cancellationCause = .deadline
                    case .unchanged, .uncertain:
                        entries[key]?.phase = .ambiguous
                        entries[key]?.factory = nil
                        continue
                    }
                }
                do {
                    try await terminalizeQueuedLocked(key: key, route: route, outcome: .expired)
                } catch {
                    if case .terminal = await reconcileMutationFailureLocked(
                        key: key, route: route) { continue }
                    entries[key]?.phase = .ambiguous
                }
            case .execute(let reservation):
                let key = Key(work: reservation.work, handle: reservation.handle)
                guard let entry = entries[key], entry.phase == .queued,
                      let route = routes[entry.work],
                      let cause = entry.latestLifecycleEvent else { continue }
                entries[key]?.phase = .starting
                await beforeStartCommit?()
                do {
                    let started = try await route.journal.append(draft(
                        type: TimelineEventType.agentHandleStarted, entry: entry,
                        causedBy: cause, payload: JSONValue.object([:])))
                    guard let factory = entries[key]?.factory else {
                        entries[key]?.phase = .ambiguous; continue
                    }
                    let resource = factory(entry.handle, entry.deadline)
                    entries[key]?.factory = nil
                    entries[key]?.latestLifecycleEvent = started.eventRef
                    entries[key]?.phase = .running
                    entries[key]?.resource = resource
                    let task = Task { [weak self, resource] in
                        let result = await resource.execute()
                        let settledAt = Date()
                        await self?.finish(key: key, result: result, settledAt: settledAt)
                    }
                    entries[key]?.executionTask = task
                } catch {
                    if await settleExpiredRefusedStartLocked(key: key, route: route) {
                        continue
                    }
                    // Never dispatch after an ambiguous started append, even if a later read sees
                    // `running`: execution recovery is outside this pilot.
                    entries[key]?.factory = nil
                    entries[key]?.phase = .ambiguous
                }
            }
        }
    }

    private func deadlineReached(key: Key) async {
        await acquireLifecycleGate()
        guard let entry = entries[key], let route = routes[entry.work] else {
            releaseLifecycleGate(); return
        }
        switch entry.phase {
        case .queued:
            do {
                let commit = try await appendCancellationLocked(
                    entry: entry, route: route, cause: .deadline, command: nil)
                entries[key]?.latestLifecycleEvent = commit.eventRef
                entries[key]?.phase = .cancelRequested
                entries[key]?.cancellationCause = .deadline
            } catch {
                switch await reconcileMutationFailureLocked(key: key, route: route) {
                case .terminal:
                    await pumpLocked(now: Date())
                    releaseLifecycleGate()
                    return
                case .cancellationCommitted:
                    entries[key]?.cancellationCause = .deadline
                case .unchanged, .uncertain:
                    entries[key]?.phase = .ambiguous
                    entries[key]?.factory = nil
                    releaseLifecycleGate()
                    return
                }
            }
            guard (try? queue.cancelQueued(entry.reservation)) != nil else {
                entries[key]?.phase = .ambiguous
                releaseLifecycleGate()
                return
            }
            do {
                try await terminalizeQueuedLocked(key: key, route: route, outcome: .expired)
                await pumpLocked(now: Date())
            } catch {
                if case .terminal = await reconcileMutationFailureLocked(key: key, route: route) {
                    await pumpLocked(now: Date())
                } else { entries[key]?.phase = .ambiguous }
            }
            releaseLifecycleGate()
        case .running:
            do {
                let commit = try await appendCancellationLocked(
                    entry: entry, route: route, cause: .deadline, command: nil)
                entries[key]?.latestLifecycleEvent = commit.eventRef
                entries[key]?.phase = .cancelRequested
                entries[key]?.cancellationCause = .deadline
                let resource = entries[key]?.resource
                releaseLifecycleGate()
                if let resource { _ = await resource.cancel() }
            } catch {
                let result = await reconcileMutationFailureLocked(key: key, route: route)
                let resource: (any WorkAgentChildExecution)?
                switch result {
                case .cancellationCommitted:
                    entries[key]?.cancellationCause = .deadline
                    resource = entries[key]?.resource
                case .terminal, .unchanged, .uncertain:
                    resource = nil
                }
                releaseLifecycleGate()
                if let resource { _ = await resource.cancel() }
            }
        case .ambiguous:
            if await settleExpiredRefusedStartLocked(key: key, route: route) {
                await pumpLocked(now: Date())
            }
            releaseLifecycleGate()
        default: releaseLifecycleGate()
        }
    }

    private func finish(key: Key, result: AgentChildExecutionResult, settledAt: Date) async {
        await acquireLifecycleGate()
        guard let entry = entries[key], let route = routes[entry.work] else {
            releaseLifecycleGate(); return
        }
        let settlement = ExecutionSettlement(result: result, settledAt: settledAt)
        entries[key]?.executionSettlement = settlement
        await settleExecutionLocked(key: key, route: route, settlement: settlement)
        releaseLifecycleGate()
    }

    private func settleExecutionLocked(
        key: Key, route: Route, settlement: ExecutionSettlement
    ) async {
        guard let entry = entries[key] else { return }
        let result = settlement.result
        entries[key]?.phase = .settling
        entries[key]?.deadlineTask?.cancel()
        entries[key]?.deadlineTask = nil
        entries[key]?.executionTask = nil
        entries[key]?.factory = nil

        let cleanup = WorkAgentHandleCleanupProof(
            state: result.cleanup.isComplete ? .quiesced : .indeterminate)
        let outcome: WorkAgentHandleTerminalOutcome
        if !result.cleanup.isComplete {
            outcome = .indeterminate
        } else if let cause = entry.cancellationCause {
            outcome = cause == .deadline ? .expired : .canceled
        } else if settlement.settledAt >= entry.deadline {
            outcome = .expired
        } else {
            switch result.state {
            case .succeeded: outcome = result.answer == nil ? .failed : .succeeded
            case .failed: outcome = .failed
            case .canceled: outcome = .canceled
            case .expired: outcome = .expired
            }
        }
        var resultBody: TimelineBodyReference?
        let resultText = outcome == .succeeded ? result.answer : (result.detail ?? result.answer)
        if let resultText {
            let bytes = Data(resultText.utf8)
            if bytes.count <= WorkAgentHandleSnapshot.maximumBodyBytes {
                resultBody = try? route.bodyStore.retain(
                    bytes, authority: JournalRef.work(entry.work, journalID: "work"),
                    mediaType: "text/plain")
            }
        }
        let finalOutcome: WorkAgentHandleTerminalOutcome =
            outcome == .succeeded && resultBody == nil ? .failed : outcome
        do {
            try await appendTerminalLocked(
                entry: entries[key]!, route: route, outcome: finalOutcome,
                resultBody: resultBody, cleanup: cleanup)
            awaitObservers.removeValue(forKey: key)
            if cleanup.state == .indeterminate {
                entries[key]?.phase = .terminalUnquiesced
                entries[key]?.terminalOutcome = finalOutcome
            } else {
                settleTerminalLocked(key: key)
                await pumpLocked(now: Date())
            }
        } catch {
            let reconciliation = await reconcileMutationFailureLocked(key: key, route: route)
            switch reconciliation {
            case .terminal:
                break
            case .cancellationCommitted, .unchanged, .uncertain:
                entries[key]?.phase = .ambiguous
            }
        }
    }

    private func terminalizeQueuedLocked(
        key: Key, route: Route, outcome: WorkAgentHandleTerminalOutcome
    ) async throws {
        guard let entry = entries[key] else { throw Failure.ambiguous }
        try await appendTerminalLocked(
            entry: entry, route: route, outcome: outcome, resultBody: nil,
            cleanup: WorkAgentHandleCleanupProof(state: .notStarted))
        settleTerminalLocked(key: key)
    }

    /// A start rejected after queue promotion is only recoverable when an exact read proves the
    /// child never left `queued` and its absolute deadline has now elapsed. The executing queue
    /// reservation is retained until the terminal write is canonically proven.
    private func settleExpiredRefusedStartLocked(key: Key, route: Route) async -> Bool {
        guard let entry = entries[key], Date() >= entry.deadline else { return false }
        let canonical: BoundedWorkAgentHandleIndexRecord?
        do { canonical = try await canonicalRecord(route: route, handle: entry.handle) }
        catch { return false }
        guard let record = canonical else {
            // Only an admission whose queue event was never proven can still be admitting with
            // no lifecycle cursor. Exact canonical absence releases that reservation; read
            // unavailability above deliberately retains the addressable uncertainty instead.
            guard entry.latestLifecycleEvent == nil,
                  (try? queue.abandonUncommitted(entry.reservation)) != nil else { return false }
            entry.deadlineTask?.cancel()
            awaitObservers.removeValue(forKey: key)
            entries.removeValue(forKey: key)
            return true
        }
        guard
              record.state == .queued, record.origin == entry.origin,
              record.requestBody == entry.requestBody, record.label == entry.label,
              record.deadline == entry.deadline else { return false }
        entries[key]?.latestLifecycleEvent = record.latestLifecycleEvent
        entries[key]?.cancellationCause = .deadline
        do {
            let commit = try await appendCancellationLocked(
                entry: entry, route: route, cause: .deadline, command: nil)
            entries[key]?.latestLifecycleEvent = commit.eventRef
            entries[key]?.phase = .cancelRequested
        } catch {
            switch await reconcileMutationFailureLocked(key: key, route: route) {
            case .terminal:
                return true
            case .cancellationCommitted:
                entries[key]?.cancellationCause = .deadline
            case .unchanged, .uncertain:
                entries[key]?.factory = nil
                entries[key]?.phase = .ambiguous
                return true
            }
        }
        do {
            try await terminalizeQueuedLocked(key: key, route: route, outcome: .expired)
        } catch {
            if case .terminal = await reconcileMutationFailureLocked(key: key, route: route) {
                // Matching canonical terminal evidence already settled the reservation.
            } else {
                entries[key]?.factory = nil
                entries[key]?.phase = .ambiguous
            }
        }
        return true
    }

    private func appendCancellationLocked(
        entry: Entry, route: Route, cause: WorkAgentHandleCancellationCause,
        command: CommandRef?
    ) async throws -> TimelineJournalCommit {
        let key = Key(work: entry.work, handle: entry.handle)
        guard let latest = entries[key]?.latestLifecycleEvent else { throw Failure.ambiguous }
        return try await route.journal.append(draft(
            type: TimelineEventType.agentHandleCancelRequested, entry: entry,
            causedBy: latest, command: command,
            payload: WorkAgentHandleCancelRequestedPayload(cause: cause)))
    }

    private func appendTerminalLocked(
        entry: Entry, route: Route, outcome: WorkAgentHandleTerminalOutcome,
        resultBody: TimelineBodyReference?, cleanup: WorkAgentHandleCleanupProof
    ) async throws {
        let key = Key(work: entry.work, handle: entry.handle)
        guard let latest = entries[key]?.latestLifecycleEvent else { throw Failure.ambiguous }
        let commit = try await route.journal.append(draft(
            type: TimelineEventType.agentHandleTerminal, entry: entry,
            causedBy: latest, payload: WorkAgentHandleTerminalPayload(
                outcome: outcome, resultBody: resultBody, cleanup: cleanup)))
        entries[key]?.latestLifecycleEvent = commit.eventRef
    }

    private func reconcileMutationFailureLocked(
        key: Key, route: Route
    ) async -> MutationReconciliation {
        guard let entry = entries[key],
              let record = await canonicalRecordIfAvailable(route: route, handle: entry.handle),
              record.origin == entry.origin else {
            entries[key]?.phase = .ambiguous
            return .uncertain
        }
        switch record.state {
        case .terminal, .reaped:
            let outcome = record.terminalOutcome
            applyCanonicalTerminalLocked(record, key: key)
            return .terminal(outcome)
        case .cancelRequested:
            entries[key]?.latestLifecycleEvent = record.latestLifecycleEvent
            entries[key]?.phase = .cancelRequested
            return .cancellationCommitted
        case .queued, .running:
            if record.latestLifecycleEvent == entry.latestLifecycleEvent {
                entries[key]?.phase = record.state == .queued ? .queued : .running
                entries[key]?.cancellationCause = nil
                return .unchanged
            }
            entries[key]?.phase = .ambiguous
            return .uncertain
        }
    }

    private func applyCanonicalTerminalLocked(
        _ record: BoundedWorkAgentHandleIndexRecord, key: Key
    ) {
        guard entries[key] != nil else { return }
        awaitObservers.removeValue(forKey: key)
        if record.blocksWorkCompletion {
            entries[key]?.latestLifecycleEvent = record.latestLifecycleEvent
            entries[key]?.phase = .terminalUnquiesced
            entries[key]?.terminalOutcome = record.terminalOutcome
            entries[key]?.deadlineTask?.cancel()
            entries[key]?.deadlineTask = nil
            entries[key]?.executionTask = nil
            entries[key]?.factory = nil
        } else {
            settleTerminalLocked(key: key)
        }
    }

    private func settleTerminalLocked(key: Key) {
        guard let entry = entries[key] else { return }
        entry.deadlineTask?.cancel()
        awaitObservers.removeValue(forKey: key)
        // Normalize any local queue state only after matching immutable canonical terminal proof.
        if (try? queue.finish(entry.reservation)) == nil {
            if (try? queue.cancelQueued(entry.reservation)) != nil {
                try? queue.finish(entry.reservation)
            } else if (try? queue.commit(entry.reservation)) != nil {
                try? queue.cancelQueued(entry.reservation)
                try? queue.finish(entry.reservation)
            }
        }
        entries.removeValue(forKey: key)
    }

    private func canonicalRecord(
        route: Route, handle: HandleRef
    ) async throws -> BoundedWorkAgentHandleIndexRecord? {
        let head = try await route.journal.read()
        return head.agentHandles.first { $0.handle == handle }
    }

    private func canonicalRecordIfAvailable(
        route: Route, handle: HandleRef
    ) async -> BoundedWorkAgentHandleIndexRecord? {
        try? await canonicalRecord(route: route, handle: handle)
    }

    private func bodyAvailability(
        _ reference: TimelineBodyReference, store: ContextBodyStore
    ) -> BodyAvailability {
        guard let body = try? store.read(reference) else { return .unavailable }
        return .available(body)
    }

    private func scheduleDeadlineLocked(for key: Key) {
        guard let deadline = entries[key]?.deadline else { return }
        entries[key]?.deadlineTask?.cancel()
        entries[key]?.deadlineTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                let seconds = min(remaining, 60)
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.deadlineReached(key: key)
        }
    }

    private func draft<T: Encodable>(
        type: String, entry: Entry, causedBy: EventRef? = nil,
        command: CommandRef? = nil, payload: T
    ) -> TimelineEventDraft {
        let payloadJSON = JSONValue.parse((try? JSONEncoder().encode(payload)) ?? Data()) ?? .null
        return TimelineEventDraft(
            command: command, causedByEventID: causedBy,
            session: entry.origin.session, work: entry.origin.work,
            workHost: entry.origin.workHost, client: command?.client,
            sessionAttachment: entry.origin.sessionAttachment, run: entry.origin.run,
            handle: entry.handle, type: type,
            declaredDomains: [.work, .runtime, .externalEffects], payload: payloadJSON)
    }

    private func acquireLifecycleGate() async {
        if !lifecycleGateHeld { lifecycleGateHeld = true; return }
        await withCheckedContinuation { lifecycleWaiters.append($0) }
    }

    private func releaseLifecycleGate() {
        if lifecycleWaiters.isEmpty { lifecycleGateHeld = false }
        else { lifecycleWaiters.removeFirst().resume() }
    }
}
