import Foundation

/// Coordinates the read/mutation sequence that precedes an explicit "End and remove command
/// output" action. The coordinator never ends Work and never retries a mutation. Its only
/// successful result is a fresh, identity-fenced observation proving that End may be admitted.
public enum DirectShellEndCleanupCoordinator {
    public struct Identity: Equatable, Sendable {
        public let work: WorkRef
        public let run: RunRef
        public let sessionAttachment: SessionAttachmentRef
        public let hostInstance: WorkHostInstanceRef

        public init(
            work: WorkRef,
            run: RunRef,
            sessionAttachment: SessionAttachmentRef,
            hostInstance: WorkHostInstanceRef
        ) {
            self.work = work
            self.run = run
            self.sessionAttachment = sessionAttachment
            self.hostInstance = hostInstance
        }
    }

    /// The small command projection cleanup needs. Command source and output never enter this
    /// coordinator.
    public struct Entry: Equatable, Sendable {
        public let action: ActionRef
        public let isTerminal: Bool
        public let pendingContext: Bool

        public init(action: ActionRef, isTerminal: Bool, pendingContext: Bool) {
            self.action = action
            self.isTerminal = isTerminal
            self.pendingContext = pendingContext
        }

        public init(_ entry: WorkServiceDirectShellEntry) {
            self.init(
                action: entry.action,
                isTerminal: entry.state.isTerminal,
                pendingContext: entry.pendingContext)
        }
    }

    public struct Observation: Equatable, Sendable {
        public let identity: Identity
        /// True only for a canonical observation of the captured owner when End is currently
        /// allowed and no controller refresh or command remains in flight. End may be allowed
        /// while model work is running; callers must not derive this from recorded Run state.
        public let runOwnerCanEnd: Bool
        public let entries: [Entry]

        public init(identity: Identity, runOwnerCanEnd: Bool, entries: [Entry]) {
            self.identity = identity
            self.runOwnerCanEnd = runOwnerCanEnd
            self.entries = entries
        }
    }

    public enum ReadOutcome: Equatable, Sendable {
        case current(Observation)
        /// A refresh or Inspect read could not yet prove the current canonical state. Reads may
        /// be retried within the shared bound because they have no execution side effect.
        case transientlyUnavailable
        /// The captured Run owner is absent or a Work, Run, Session attachment, or host instance
        /// is known to have changed. This is terminal for the cleanup attempt.
        case identityChanged
    }

    public enum Mutation: Equatable, Sendable {
        case stop(ActionRef)
        case dismiss(ActionRef)

        public var action: ActionRef {
            switch self {
            case .stop(let action), .dismiss(let action): return action
            }
        }
    }

    public enum MutationOutcome: Equatable, Sendable {
        case accepted
        case rejected
        /// The caller cannot prove whether the mutation crossed the Work Host boundary.
        case uncertain
    }

    public enum Outcome: Equatable, Sendable {
        case confirmedReady
        case timedOut
        case identityChanged
        case invalidObservation
        /// Canonical Inspect found live or pending output, but this invocation did not carry the
        /// user's explicit permission to stop and remove it.
        case outputRequiresDecision
        case mutationRejected(Mutation)
        case mutationUncertain(Mutation)
        case cancelled
    }

    public struct Policy: Equatable, Sendable {
        public let timeout: Duration
        public let retryDelay: Duration
        public let maximumReadAttempts: Int

        public init(
            timeout: Duration = .seconds(10),
            retryDelay: Duration = .milliseconds(100),
            maximumReadAttempts: Int = 128
        ) {
            self.timeout = timeout > .zero ? timeout : .zero
            self.retryDelay = retryDelay > .zero ? retryDelay : .zero
            self.maximumReadAttempts = max(1, maximumReadAttempts)
        }
    }

    /// Reconcile command output before End. `read` should refresh the exact attachment and then
    /// Inspect; `mutate` should issue exactly the requested Stop or Dismiss once. The coordinator
    /// deliberately has no End callback, so a failure or cancellation cannot terminalize Work.
    @MainActor
    public static func reconcile(
        identity: Identity,
        permitsCleanup: Bool = true,
        policy: Policy = Policy(),
        read: @escaping @MainActor () async -> ReadOutcome,
        mutate: @escaping @MainActor (Mutation) async -> MutationOutcome
    ) async -> Outcome {
        let deadline = ContinuousClock.now.advanced(by: policy.timeout)
        var readAttempts = 0
        var stopped: Set<ActionRef> = []
        var dismissed: Set<ActionRef> = []

        while readAttempts < policy.maximumReadAttempts {
            guard !Task.isCancelled else { return .cancelled }
            guard ContinuousClock.now <= deadline else { return .timedOut }
            readAttempts += 1

            let readOutcome = await read()
            // The read callback can suspend for the rest of the shared deadline. Never turn a
            // late or cancelled result into a mutation or an End-ready proof.
            guard !Task.isCancelled else { return .cancelled }
            guard ContinuousClock.now <= deadline else { return .timedOut }
            switch readOutcome {
            case .identityChanged:
                return .identityChanged
            case .transientlyUnavailable:
                guard await waitForRetry(policy.retryDelay, deadline: deadline) else {
                    return Task.isCancelled ? .cancelled : .timedOut
                }
                continue
            case .current(let observation):
                guard observation.identity == identity else { return .identityChanged }
                let actions = observation.entries.map(\.action)
                guard Set(actions).count == actions.count else { return .invalidObservation }
                let hasOutstandingOutput = observation.entries.contains {
                    !$0.isTerminal || $0.pendingContext
                }
                if hasOutstandingOutput && !permitsCleanup {
                    return .outputRequiresDecision
                }

                if let live = observation.entries.first(where: { !$0.isTerminal }) {
                    if stopped.contains(live.action) {
                        guard await waitForRetry(policy.retryDelay, deadline: deadline) else {
                            return Task.isCancelled ? .cancelled : .timedOut
                        }
                        continue
                    }
                    let mutation = Mutation.stop(live.action)
                    stopped.insert(live.action)
                    let mutationOutcome = await mutate(mutation)
                    guard !Task.isCancelled else { return .cancelled }
                    guard ContinuousClock.now <= deadline else { return .timedOut }
                    switch mutationOutcome {
                    case .accepted:
                        continue
                    case .rejected:
                        return .mutationRejected(mutation)
                    case .uncertain:
                        return .mutationUncertain(mutation)
                    }
                }

                if let pending = observation.entries.first(where: { $0.pendingContext }) {
                    // Dismiss is valid only after a terminal result. Treat a contradictory read
                    // as invalid instead of asking the mutator to reinterpret it.
                    guard pending.isTerminal else { return .invalidObservation }
                    if dismissed.contains(pending.action) {
                        guard await waitForRetry(policy.retryDelay, deadline: deadline) else {
                            return Task.isCancelled ? .cancelled : .timedOut
                        }
                        continue
                    }
                    let mutation = Mutation.dismiss(pending.action)
                    dismissed.insert(pending.action)
                    let mutationOutcome = await mutate(mutation)
                    guard !Task.isCancelled else { return .cancelled }
                    guard ContinuousClock.now <= deadline else { return .timedOut }
                    switch mutationOutcome {
                    case .accepted:
                        continue
                    case .rejected:
                        return .mutationRejected(mutation)
                    case .uncertain:
                        return .mutationUncertain(mutation)
                    }
                }

                if observation.runOwnerCanEnd { return .confirmedReady }
                guard await waitForRetry(policy.retryDelay, deadline: deadline) else {
                    return Task.isCancelled ? .cancelled : .timedOut
                }
            }
        }
        return Task.isCancelled ? .cancelled : .timedOut
    }

    @MainActor
    private static func waitForRetry(
        _ delay: Duration,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        guard !Task.isCancelled, ContinuousClock.now <= deadline else { return false }
        if delay == .zero {
            await Task.yield()
        } else {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return false
            }
        }
        return !Task.isCancelled && ContinuousClock.now <= deadline
    }
}
