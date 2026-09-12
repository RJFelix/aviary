import Foundation

/// Typed self-consistency evidence within an authenticated derived checkpoint. The digest does
/// not independently authenticate journal bytes; publication and source fencing own that proof.
public struct WorkAgentProviderEventEvidence: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable { case started, settled }
    public let role: Role
    public let ordinal: Int
    public let payloadDigest: String
    public let envelope: WorkAgentHandleEventEvidence
    public var event: EventRef { envelope.event }

    init(_ event: TimelineEvent, role: Role, ordinal: Int) throws {
        self.role = role
        self.ordinal = ordinal
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        payloadDigest = "sha256:" + AviarySHA256.hash(data: try encoder.encode(event.payload)).description
        envelope = WorkAgentHandleEventEvidence(event)
    }
}

/// Independent of the originating Run's active actions. One child executes serial provider
/// crossings; the journal retains every crossing while its Handle keeps a fixed-size continuation.
public struct WorkAgentProviderAccounting: Codable, Hashable, Sendable {
    public private(set) var usage = ProviderUsageAggregate()
    public private(set) var pending: ProviderAdmission?
    public private(set) var started: WorkAgentProviderEventEvidence?
    public private(set) var settled: WorkAgentProviderEventEvidence?

    public init() {}

    public var latestEvent: EventRef? { (settled ?? started)?.event }
    public var evidence: [WorkAgentHandleEventEvidence] { [started, settled].compactMap { $0?.envelope } }

    /// Validate the provider continuation against the Handle lifecycle's proven physical order.
    /// A bounded head does not retain the execution event's sequence, so callers pass nil rather
    /// than deriving one from an unrelated cursor. Cancellation and terminal evidence do retain
    /// exact sequences and must fence the provider events even in that bounded representation.
    internal func validateLifecycleOrder(
        executionSequence: Int?, cancellationSequence: Int?, terminalSequence: Int?
    ) throws {
        if let admissionSequence = started?.envelope.sequence {
            if let executionSequence, executionSequence >= admissionSequence {
                throw Failure.invalidState
            }
            if let cancellationSequence, admissionSequence >= cancellationSequence {
                throw Failure.invalidState
            }
        }
        if let terminalSequence {
            guard evidence.allSatisfy({ $0.sequence < terminalSequence }) else {
                throw Failure.invalidState
            }
        }
    }

    public func validate(
        origin: WorkAgentHandleOrigin, handle: HandleRef, execution: EventRef?,
        journal: JournalRef, lastSequence: Int
    ) throws {
        try usage.validate()
        guard usage.started - usage.settled == (pending == nil ? 0 : 1),
              (usage.started == 0) == (started == nil),
              usage.started != 0 || (pending == nil && settled == nil),
              started == nil || execution != nil,
              usage.started <= lastSequence / 2 + lastSequence % 2,
              usage.settled <= lastSequence - usage.started else { throw Failure.invalidState }
        if let pending { try pending.validate() }
        for (record, role) in [(started, WorkAgentProviderEventEvidence.Role.started), (settled, .settled)] {
            guard let record else { continue }
            guard record.role == role, record.ordinal == usage.started,
                  record.payloadDigest.hasPrefix("sha256:"), record.payloadDigest.utf8.count == 71,
                  record.payloadDigest.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) })
            else { throw Failure.invalidState }
        }
        for proof in evidence {
            guard proof.event.journal == journal, !proof.event.eventID.isEmpty,
                  proof.sequence > 0, proof.sequence <= lastSequence,
                  proof.work == origin.work, proof.workHost == origin.workHost,
                  proof.session == origin.session, proof.sessionAttachment == origin.sessionAttachment,
                  proof.run == origin.run, proof.handle == handle, proof.client == nil,
                  proof.provenance == .native, proof.hostRecordedAt.timeIntervalSince1970.isFinite,
                  proof.causedByEventID?.journal == journal,
                  proof.previousEventID != nil else { throw Failure.invalidState }
        }
        if let started {
            guard pending != nil ? settled == nil : settled != nil else { throw Failure.invalidState }
            if usage.started == 1, started.envelope.causedByEventID != execution { throw Failure.invalidState }
            if let settled {
                guard settled.envelope.causedByEventID == started.event,
                      settled.envelope.sequence > started.envelope.sequence else { throw Failure.invalidState }
            }
        }
    }

    mutating func applyStart(_ event: TimelineEvent, execution: EventRef) throws {
        guard pending == nil, usage.started < Int.max,
              event.causedByEventID == (latestEvent ?? execution),
              case .object(let payload) = event.payload,
              Set(payload.keys) == ["ordinal", "admission"],
              payload["ordinal"]?.stringValue == String(usage.started + 1),
              let admissionValue = payload["admission"] else { throw Failure.invalidTransition }
        let admission = try ProviderAdmission(timelineValue: admissionValue)
        var aggregate = usage
        try aggregate.recordStarted()
        usage = aggregate
        pending = admission
        started = try WorkAgentProviderEventEvidence(event, role: .started, ordinal: usage.started)
        settled = nil
    }

    mutating func applySettlement(_ event: TimelineEvent) throws {
        guard let pending, let started,
              event.causedByEventID == started.event,
              case .object(let payload) = event.payload,
              Set(payload.keys) == ["ordinal", "settlement", "state"],
              payload["ordinal"]?.stringValue == String(usage.started),
              let settlementValue = payload["settlement"],
              let stateRaw = payload["state"]?.stringValue,
              let state = ActionExecutionState(rawValue: stateRaw) else {
            throw Failure.invalidTransition
        }
        let settlement = try ProviderSettlement(timelineValue: settlementValue)
        try settlement.validate(admission: pending, kind: pending.expectedActionKind, state: state)
        var aggregate = usage
        try aggregate.recordSettlement(settlement)
        usage = aggregate
        self.pending = nil
        settled = try WorkAgentProviderEventEvidence(event, role: .settled, ordinal: usage.started)
    }

    public enum Failure: Error, Equatable { case invalidState, invalidTransition, unavailable }
}

/// The adapter must durably admit before returning, and settle before reporting success. A
/// failed operation may have committed; it must latch rather than replay a potentially billed call.
public protocol ChildProviderAccounting: Sendable {
    func begin(_ admission: ProviderAdmission, requestModel: String, targetModel: String) async throws
    func finish(_ settlement: ProviderSettlement, state: ActionExecutionState) async throws
}

internal actor WorkAgentChildProviderLedger: ChildProviderAccounting {
    private let journal: WorkAgentHandleJournal
    private let handle: HandleRef
    private let origin: WorkAgentHandleOrigin
    private let execution: EventRef
    private var usage: ProviderUsageAggregate
    private var pending: ProviderAdmission?
    private var latest: EventRef
    private var unavailable = false
    private var mutating = false

    init(journal: WorkAgentHandleJournal, record: BoundedWorkAgentHandleIndexRecord) throws {
        guard record.state == .running, let execution = record.startedEvent,
              record.providerAccounting.pending == nil else {
            throw WorkAgentProviderAccounting.Failure.unavailable
        }
        self.journal = journal
        handle = record.handle
        origin = record.origin
        self.execution = execution
        usage = record.providerAccounting.usage
        pending = record.providerAccounting.pending
        latest = record.providerAccounting.latestEvent ?? execution
    }

    func begin(_ admission: ProviderAdmission, requestModel: String, targetModel: String) async throws {
        guard !unavailable, !mutating, pending == nil,
              usage.started < Int.max else { throw WorkAgentProviderAccounting.Failure.unavailable }
        try admission.validate(contextModelID: requestModel, targetModel: targetModel)
        var nextUsage = usage
        try nextUsage.recordStarted()
        try await commit(type: TimelineEventType.agentHandleProviderStarted,
                         cause: latest,
                         nextUsage: nextUsage, nextPending: admission,
                         payload: .object([
                            "ordinal": .string(String(usage.started + 1)),
                            "admission": admission.timelineValue,
                         ]))
    }

    func finish(_ settlement: ProviderSettlement, state: ActionExecutionState) async throws {
        guard !unavailable, !mutating, let pending else { throw WorkAgentProviderAccounting.Failure.unavailable }
        try settlement.validate(admission: pending, kind: pending.expectedActionKind, state: state)
        var nextUsage = usage
        try nextUsage.recordSettlement(settlement)
        try await commit(type: TimelineEventType.agentHandleProviderSettled, cause: latest,
                         nextUsage: nextUsage, nextPending: nil,
                         payload: .object([
                            "ordinal": .string(String(usage.started)),
                            "settlement": settlement.timelineValue, "state": .string(state.rawValue),
                         ]))
    }

    private func commit(type: String, cause: EventRef, nextUsage: ProviderUsageAggregate,
                        nextPending: ProviderAdmission?, payload: JSONValue) async throws {
        mutating = true
        defer { mutating = false }
        do {
            let commit = try await journal.append(TimelineEventDraft(
                causedByEventID: cause, session: origin.session, work: origin.work,
                workHost: origin.workHost, sessionAttachment: origin.sessionAttachment,
                run: origin.run, handle: handle, type: type,
                declaredDomains: [.work, .runtime, .externalEffects], payload: payload))
            usage = nextUsage
            pending = nextPending
            latest = commit.eventRef
            AviaryTelemetry.event("aviary.agent_child.provider.accounted", attributes:
                AviaryTelemetry.canonicalReferenceAttributes(commit, role: .event))
        } catch {
            unavailable = true
            throw error
        }
    }
}
