import Foundation
@testable import AviaryCore

@MainActor
private final class DirectShellEndCleanupHarness {
    typealias Coordinator = DirectShellEndCleanupCoordinator

    var reads: [Coordinator.ReadOutcome]
    var mutationResults: [Coordinator.MutationOutcome]
    private(set) var readCount = 0
    private(set) var mutations: [Coordinator.Mutation] = []

    init(
        reads: [Coordinator.ReadOutcome],
        mutationResults: [Coordinator.MutationOutcome] = []
    ) {
        self.reads = reads
        self.mutationResults = mutationResults
    }

    func read() async -> Coordinator.ReadOutcome {
        defer { readCount += 1 }
        guard readCount < reads.count else { return .transientlyUnavailable }
        return reads[readCount]
    }

    func mutate(_ mutation: Coordinator.Mutation) async -> Coordinator.MutationOutcome {
        mutations.append(mutation)
        guard !mutationResults.isEmpty else { return .uncertain }
        return mutationResults.removeFirst()
    }
}

private func directShellEndCleanupIdentity(
    suffix: String = "primary"
) -> DirectShellEndCleanupCoordinator.Identity {
    let host = WorkHostRef("cleanup-host-\(suffix)")
    return DirectShellEndCleanupCoordinator.Identity(
        work: WorkRef(workHostID: host.workHostID, workID: "cleanup-work-\(suffix)"),
        run: RunRef("cleanup-run-\(suffix)"),
        sessionAttachment: SessionAttachmentRef("cleanup-session-attachment-\(suffix)"),
        hostInstance: WorkHostInstanceRef(
            host: host,
            instanceID: "cleanup-instance-\(suffix)",
            startIdentity: "cleanup-start-\(suffix)"))
}

private func directShellEndCleanupObservation(
    identity: DirectShellEndCleanupCoordinator.Identity,
    idle: Bool = true,
    entries: [DirectShellEndCleanupCoordinator.Entry]
) -> DirectShellEndCleanupCoordinator.ReadOutcome {
    .current(.init(identity: identity, runOwnerCanEnd: idle, entries: entries))
}

private func directShellEndCleanupPolicy(
    maximumReadAttempts: Int = 8
) -> DirectShellEndCleanupCoordinator.Policy {
    .init(
        timeout: .seconds(10),
        retryDelay: .zero,
        maximumReadAttempts: maximumReadAttempts)
}

@MainActor
func testDirectShellEndCleanupRetriesReadAfterAcceptedDismissWithoutRepeatingMutation()
    async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity()
    let action = ActionRef("cleanup-dismiss-action")
    let pending = Coordinator.Entry(
        action: action, isTerminal: true, pendingContext: true)
    let harness = DirectShellEndCleanupHarness(
        reads: [
            directShellEndCleanupObservation(identity: identity, entries: [pending]),
            .transientlyUnavailable,
            directShellEndCleanupObservation(identity: identity, entries: []),
        ],
        mutationResults: [.accepted])

    let outcome = await Coordinator.reconcile(
        identity: identity,
        policy: directShellEndCleanupPolicy(),
        read: { await harness.read() },
        mutate: { await harness.mutate($0) })

    XCTAssertEqual(outcome, .confirmedReady)
    XCTAssertEqual(harness.readCount, 3)
    XCTAssertEqual(harness.mutations, [.dismiss(action)])
}

@MainActor
func testDirectShellEndCleanupPersistentReadFailureNeverBecomesEndReady() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "unavailable")
    let harness = DirectShellEndCleanupHarness(
        reads: [.transientlyUnavailable, .transientlyUnavailable, .transientlyUnavailable])

    let outcome = await Coordinator.reconcile(
        identity: identity,
        policy: directShellEndCleanupPolicy(maximumReadAttempts: 3),
        read: { await harness.read() },
        mutate: { await harness.mutate($0) })

    XCTAssertEqual(outcome, .timedOut)
    XCTAssertEqual(harness.readCount, 3)
    XCTAssertTrue(harness.mutations.isEmpty)
}

@MainActor
func testDirectShellEndCleanupForeignReplacementStopsBeforeFollowupMutation() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "replaced")
    let action = ActionRef("cleanup-replaced-action")
    let live = Coordinator.Entry(
        action: action, isTerminal: false, pendingContext: false)
    let harness = DirectShellEndCleanupHarness(
        reads: [
            directShellEndCleanupObservation(identity: identity, entries: [live]),
            .identityChanged,
        ],
        mutationResults: [.accepted])

    let outcome = await Coordinator.reconcile(
        identity: identity,
        policy: directShellEndCleanupPolicy(),
        read: { await harness.read() },
        mutate: { await harness.mutate($0) })

    XCTAssertEqual(outcome, .identityChanged)
    XCTAssertEqual(harness.mutations, [.stop(action)])
}

@MainActor
func testDirectShellEndCleanupDoesNotReplayUncertainMutation() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "uncertain")
    let action = ActionRef("cleanup-uncertain-action")
    let pending = Coordinator.Entry(
        action: action, isTerminal: true, pendingContext: true)
    let harness = DirectShellEndCleanupHarness(
        reads: [
            directShellEndCleanupObservation(identity: identity, entries: [pending]),
            directShellEndCleanupObservation(identity: identity, entries: []),
        ],
        mutationResults: [.uncertain, .accepted])

    let outcome = await Coordinator.reconcile(
        identity: identity,
        policy: directShellEndCleanupPolicy(),
        read: { await harness.read() },
        mutate: { await harness.mutate($0) })

    XCTAssertEqual(outcome, .mutationUncertain(.dismiss(action)))
    XCTAssertEqual(harness.readCount, 1)
    XCTAssertEqual(harness.mutations, [.dismiss(action)])
}

@MainActor
func testDirectShellEndCleanupStopsThenDismissesOnlyAfterTerminalRead() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "stop-dismiss")
    let action = ActionRef("cleanup-stop-dismiss-action")
    let live = Coordinator.Entry(
        action: action, isTerminal: false, pendingContext: false)
    let terminal = Coordinator.Entry(
        action: action, isTerminal: true, pendingContext: true)
    let harness = DirectShellEndCleanupHarness(
        reads: [
            directShellEndCleanupObservation(identity: identity, idle: false, entries: [live]),
            directShellEndCleanupObservation(identity: identity, entries: [terminal]),
            directShellEndCleanupObservation(identity: identity, entries: []),
        ],
        mutationResults: [.accepted, .accepted])

    let outcome = await Coordinator.reconcile(
        identity: identity,
        policy: directShellEndCleanupPolicy(),
        read: { await harness.read() },
        mutate: { await harness.mutate($0) })

    XCTAssertEqual(outcome, .confirmedReady)
    XCTAssertEqual(harness.readCount, 3)
    XCTAssertEqual(harness.mutations, [.stop(action), .dismiss(action)])
}

@MainActor
func testDirectShellEndCleanupDoesNotMutateFromReadReturnedAfterDeadline() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "late-read")
    let action = ActionRef("cleanup-late-read-action")
    let pending = Coordinator.Entry(
        action: action, isTerminal: true, pendingContext: true)
    var mutationCount = 0

    let outcome = await Coordinator.reconcile(
        identity: identity,
        policy: .init(
            timeout: .milliseconds(1), retryDelay: .zero, maximumReadAttempts: 2),
        read: {
            try? await Task.sleep(for: .milliseconds(10))
            return directShellEndCleanupObservation(identity: identity, entries: [pending])
        },
        mutate: { _ in
            mutationCount += 1
            return .accepted
        })

    XCTAssertEqual(outcome, .timedOut)
    XCTAssertEqual(mutationCount, 0)
}

@MainActor
func testDirectShellEndCleanupDoesNotMutateFromReadReturnedAfterCancellation() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "cancelled-read")
    let action = ActionRef("cleanup-cancelled-read-action")
    let pending = Coordinator.Entry(
        action: action, isTerminal: true, pendingContext: true)
    var mutationCount = 0

    let task = Task { @MainActor in
        await Coordinator.reconcile(
            identity: identity,
            policy: directShellEndCleanupPolicy(),
            read: {
                withUnsafeCurrentTask { $0?.cancel() }
                return directShellEndCleanupObservation(identity: identity, entries: [pending])
            },
            mutate: { _ in
                mutationCount += 1
                return .accepted
            })
    }
    let outcome = await task.value

    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(mutationCount, 0)
}

@MainActor
func testDirectShellEndCleanupPlainEndRequiresDecisionForRemotePendingOutput() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "plain-pending")
    let action = ActionRef("cleanup-plain-pending-action")
    let pending = Coordinator.Entry(
        action: action, isTerminal: true, pendingContext: true)
    let harness = DirectShellEndCleanupHarness(reads: [
        directShellEndCleanupObservation(identity: identity, entries: [pending]),
    ])

    let outcome = await Coordinator.reconcile(
        identity: identity,
        permitsCleanup: false,
        policy: directShellEndCleanupPolicy(),
        read: { await harness.read() },
        mutate: { await harness.mutate($0) })

    XCTAssertEqual(outcome, .outputRequiresDecision)
    XCTAssertTrue(harness.mutations.isEmpty)
}

@MainActor
func testDirectShellEndCleanupPlainEndAcceptsCanonicalEmptyRemoteTray() async throws {
    typealias Coordinator = DirectShellEndCleanupCoordinator
    let identity = directShellEndCleanupIdentity(suffix: "plain-empty")
    let harness = DirectShellEndCleanupHarness(reads: [
        directShellEndCleanupObservation(identity: identity, entries: []),
    ])

    let outcome = await Coordinator.reconcile(
        identity: identity,
        permitsCleanup: false,
        policy: directShellEndCleanupPolicy(),
        read: { await harness.read() },
        mutate: { await harness.mutate($0) })

    XCTAssertEqual(outcome, .confirmedReady)
    XCTAssertTrue(harness.mutations.isEmpty)
}

let casesDirectShellEndCleanupCoordinator: [Case] = [
    ("End cleanup retries read after accepted Dismiss without mutation replay", {
        try await testDirectShellEndCleanupRetriesReadAfterAcceptedDismissWithoutRepeatingMutation()
    }),
    ("End cleanup persistent read failure never becomes End-ready", {
        try await testDirectShellEndCleanupPersistentReadFailureNeverBecomesEndReady()
    }),
    ("End cleanup foreign replacement prevents follow-up mutation", {
        try await testDirectShellEndCleanupForeignReplacementStopsBeforeFollowupMutation()
    }),
    ("End cleanup uncertain mutation is never replayed", {
        try await testDirectShellEndCleanupDoesNotReplayUncertainMutation()
    }),
    ("End cleanup reads terminal state before Dismiss", {
        try await testDirectShellEndCleanupStopsThenDismissesOnlyAfterTerminalRead()
    }),
    ("End cleanup ignores a read returned after its deadline", {
        try await testDirectShellEndCleanupDoesNotMutateFromReadReturnedAfterDeadline()
    }),
    ("End cleanup ignores a read returned after cancellation", {
        try await testDirectShellEndCleanupDoesNotMutateFromReadReturnedAfterCancellation()
    }),
    ("plain End requires a decision for remotely observed pending output", {
        try await testDirectShellEndCleanupPlainEndRequiresDecisionForRemotePendingOutput()
    }),
    ("plain End accepts an authoritative empty remote tray", {
        try await testDirectShellEndCleanupPlainEndAcceptsCanonicalEmptyRemoteTray()
    }),
]
