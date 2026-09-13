import Foundation

/// The Work-wide provider-usage view used by consumers that need to show direct Work
/// crossings and Work-owned child crossings together.  This is a derived view: the Work
/// journal remains authoritative and no Session or Agent process total is folded into it.
public struct CanonicalWorkUsageInventory: Hashable, Sendable {
    public static let maximumChildren = WorkAgentHandleSnapshot.maximumRetainedPerWork

    public enum Error: Swift.Error, Equatable, Sendable {
        case notCanonical
        case invalidWorkIdentity
        case invalidJournal
        case invalidSnapshot
    }

    public struct Child: Hashable, Sendable {
        public let handleID: String
        public let usage: CanonicalWorkUsage

        public init(handleID: String, usage: CanonicalWorkUsage) {
            self.handleID = handleID
            self.usage = usage
        }
    }

    /// Why the combined value is unavailable. A child-only omission or malformed child
    /// does not erase a truthful direct value. If a
    /// Work-level domain is unknown, direct usage is unavailable because that domain may have
    /// changed the direct aggregate too.
    public enum CombinedAvailability: String, Codable, Hashable, Sendable {
        case complete
        case childFactsUnavailable = "child_facts_unavailable"
        case childFactsOmitted = "child_facts_omitted"
        case childFactsInvalid = "child_facts_invalid"
        case arithmeticOverflow = "arithmetic_overflow"
    }

    public enum DirectAvailability: String, Codable, Hashable, Sendable {
        case complete
        case unavailable
    }

    public let work: WorkRef
    public let journal: JournalRef
    public let direct: CanonicalWorkUsage?
    public let directAvailability: DirectAvailability
    public let children: [Child]
    public let childrenTotal: CanonicalWorkUsage?
    public let omittedChildCount: Int
    public let invalidChildCount: Int
    public let combined: CanonicalWorkUsage?
    public let combinedAvailability: CombinedAvailability

    public var childUsageComplete: Bool {
        directAvailability == .complete
            && omittedChildCount == 0 && invalidChildCount == 0
            && childrenTotal != nil
    }

    /// Constructed only by a controller that has already authenticated the attached Work
    /// projection and its exact cursors. Consumers should retain the resulting value rather
    /// than rebuilding it from an arbitrary decoded projection.
    internal init(projection: WorkServiceAttachedWorkProjection) throws {
        guard projection.isCanonical,
              projection.workSourceCompleteness == .complete,
              projection.workUnknownEvents.isEmpty,
              projection.workCursor.journal == projection.descriptor.journal,
              projection.workCursor.sequence == projection.workSnapshot.lastSequence,
              projection.workCursor.eventID == projection.workSnapshot.lastEventID,
              projection.sessionSnapshot.journal == Optional(projection.sessionCursor.journal),
              projection.sessionCursor.sequence == projection.sessionSnapshot.lastSequence,
              projection.sessionCursor.eventID == projection.sessionSnapshot.lastEventID,
              projection.descriptor.currentRun == projection.workSnapshot.activeRun,
              projection.descriptor.currentRunSession == projection.workSnapshot.activeRunSession,
              projection.descriptor.currentRunSessionAttachment
                  == projection.workSnapshot.activeRunSessionAttachment else {
            throw Error.notCanonical
        }
        try self.init(
            snapshot: projection.workSnapshot,
            expectedWork: projection.descriptor.work,
            expectedJournal: projection.descriptor.journal,
            omittedChildCount: 0)
    }

    /// Internal entry point for exact and bounded projection adapters.  `omittedChildCount`
    /// must come from a source that proves the omitted count; callers must not infer it from a
    /// truncated display array.
    internal init(
        snapshot: WorkSnapshot,
        expectedWork: WorkRef,
        expectedJournal: JournalRef,
        omittedChildCount: Int
    ) throws {
        guard omittedChildCount >= 0 else { throw Error.invalidSnapshot }
        guard !expectedWork.workHostID.isEmpty, !expectedWork.workID.isEmpty,
              expectedWork.workHostID.utf8.count <= 256,
              expectedWork.workID.utf8.count <= 256 else {
            throw Error.invalidWorkIdentity
        }
        guard expectedJournal.kind == .work,
              expectedJournal.owner == .work(expectedWork),
              expectedWork.workHostID == expectedJournal.authority.authorityID else {
            throw Error.invalidJournal
        }
        guard snapshot.journal == expectedJournal,
              snapshot.work == expectedWork,
              snapshot.workHost == WorkHostRef(expectedWork.workHostID),
              snapshot.causalOrderValid,
              snapshot.structuralIntegrityValid,
              snapshot.semanticProjectionValid,
              snapshot.quarantinedEvents.isEmpty,
              snapshot.lastSequence >= 0,
              snapshot.agentHandles.count <= Self.maximumChildren else {
            throw Error.invalidSnapshot
        }
        guard snapshot.unknownEvents.isEmpty else { throw Error.notCanonical }
        do {
            try snapshot.providerUsage.validate()
        } catch {
            throw Error.invalidSnapshot
        }

        let agentFactsUnavailable = !snapshot.unknownDomains.isDisjoint(
            with: [.work, .runtime, .externalEffects])
        if agentFactsUnavailable {
            work = expectedWork
            journal = expectedJournal
            direct = nil
            directAvailability = .unavailable
            children = []
            self.childrenTotal = nil
            self.omittedChildCount = 0
            self.invalidChildCount = 0
            combined = nil
            combinedAvailability = .childFactsUnavailable
            return
        }

        struct ValidatedChild {
            let row: Child
            let aggregate: ProviderUsageAggregate
        }
        var validChildren: [ValidatedChild] = []
        var invalidChildCount = 0
        for (key, handle) in snapshot.agentHandles {
            guard key == handle.handle.handleID,
                  !key.isEmpty, key.utf8.count <= 256,
                  handle.origin.work == expectedWork,
                  handle.origin.workHost == WorkHostRef(expectedWork.workHostID) else {
                invalidChildCount += 1
                continue
            }
            do {
                try handle.executionLimits.validate()
                try handle.providerAccounting.validate(
                    origin: handle.origin,
                    handle: handle.handle,
                    execution: handle.startedEvent,
                    journal: expectedJournal,
                    lastSequence: snapshot.lastSequence)
                try handle.providerAccounting.validateLifecycleOrder(
                    executionSequence: handle.startedEvent.flatMap {
                        snapshot.eventSequences[$0.eventID]
                    },
                    cancellationSequence: handle.cancellationEvidence?.event.sequence,
                    terminalSequence: handle.terminalEvidence?.event.sequence)
                validChildren.append(ValidatedChild(
                    row: Child(
                        handleID: key,
                        usage: CanonicalWorkUsage(aggregate: handle.providerAccounting.usage)),
                    aggregate: handle.providerAccounting.usage))
            } catch {
                invalidChildCount += 1
            }
        }
        validChildren.sort { $0.row.handleID < $1.row.handleID }

        work = expectedWork
        journal = expectedJournal
        direct = CanonicalWorkUsage(aggregate: snapshot.providerUsage)
        directAvailability = .complete
        children = validChildren.map(\.row)
        self.omittedChildCount = omittedChildCount
        self.invalidChildCount = invalidChildCount

        guard omittedChildCount == 0, invalidChildCount == 0 else {
            childrenTotal = nil
            combined = nil
            combinedAvailability = omittedChildCount > 0
                ? .childFactsOmitted : .childFactsInvalid
            return
        }
        let childAggregates = validChildren.map(\.aggregate)
        do {
            childrenTotal = CanonicalWorkUsage(aggregate: try Self.merge(
                ProviderUsageAggregate(), childAggregates))
        } catch {
            childrenTotal = nil
            combined = nil
            combinedAvailability = .arithmeticOverflow
            return
        }
        do {
            let aggregate = try Self.merge(
                snapshot.providerUsage, childAggregates)
            combined = CanonicalWorkUsage(aggregate: aggregate)
            combinedAvailability = .complete
        } catch {
            combined = nil
            combinedAvailability = .arithmeticOverflow
        }
    }

    private static func merge(
        _ direct: ProviderUsageAggregate,
        _ children: [ProviderUsageAggregate]
    ) throws -> ProviderUsageAggregate {
        var started = direct.started
        var settled = direct.settled
        var unresolved = direct.unresolved
        var floors = direct.knownFloors
        for aggregate in children {
            let startedResult = started.addingReportingOverflow(aggregate.started)
            guard !startedResult.overflow else { throw Error.invalidSnapshot }
            started = startedResult.partialValue
            let settledResult = settled.addingReportingOverflow(aggregate.settled)
            guard !settledResult.overflow else { throw Error.invalidSnapshot }
            settled = settledResult.partialValue
            unresolved.total = try adding(unresolved.total, aggregate.unresolved.total)
            unresolved.breakdown = try adding(unresolved.breakdown, aggregate.unresolved.breakdown)
            unresolved.cost = try adding(unresolved.cost, aggregate.unresolved.cost)
            floors.inputTokens = try adding(floors.inputTokens, aggregate.knownFloors.inputTokens)
            floors.outputTokens = try adding(floors.outputTokens, aggregate.knownFloors.outputTokens)
            floors.cacheReadTokens = try adding(
                floors.cacheReadTokens, aggregate.knownFloors.cacheReadTokens)
            floors.cacheWriteTokens = try adding(
                floors.cacheWriteTokens, aggregate.knownFloors.cacheWriteTokens)
            floors.totalTokens = try adding(floors.totalTokens, aggregate.knownFloors.totalTokens)
            let cost = floors.cost + aggregate.knownFloors.cost
            guard cost.isFinite, cost >= 0 else { throw Error.invalidSnapshot }
            floors.cost = cost
        }
        let result = ProviderUsageAggregate(
            started: started, settled: settled,
            unresolved: unresolved, knownFloors: floors,
            overflow: .init(
                tokenCounts: direct.tokenOverflow || children.contains { $0.tokenOverflow },
                cost: direct.costOverflow || children.contains { $0.costOverflow }))
        try result.validate()
        return result
    }

    private static func adding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw Error.invalidSnapshot }
        return result.partialValue
    }
}
