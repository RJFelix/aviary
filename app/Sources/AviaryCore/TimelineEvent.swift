import Foundation

// MARK: - Stable references

/// A stable identity for a conversation in the timeline protocol.
public struct SessionRef: Codable, Hashable, Sendable {
    public let sessionID: String

    public init(_ sessionID: String) { self.sessionID = sessionID }
}

/// A stable identity for the host that owns Work.
public struct WorkHostRef: Codable, Hashable, Sendable {
    public let workHostID: String

    public init(_ workHostID: String) { self.workHostID = workHostID }
}

/// A stable identity for a GUI, service client, or other observer/controller.
public struct ClientRef: Codable, Hashable, Sendable {
    public let clientID: String

    public init(_ clientID: String) { self.clientID = clientID }
}

public struct TimelineActor: Codable, Hashable, Sendable {
    public let actorID: String
    public let kind: String

    public init(actorID: String, kind: String = "unknown") {
        self.actorID = actorID
        self.kind = kind
    }
}

public struct JournalCursor: Codable, Hashable, Sendable {
    public let journal: JournalRef
    public let eventID: String?
    public let sequence: Int

    public init(journal: JournalRef, eventID: String? = nil, sequence: Int) {
        self.journal = journal
        self.eventID = eventID
        self.sequence = sequence
    }
}

/// A durable relationship between a conversation and Work.
public struct SessionAttachmentRef: Codable, Hashable, Sendable {
    public let attachmentID: String

    public init(_ attachmentID: String) { self.attachmentID = attachmentID }
}

/// A durable relationship between a client/device and Work.
public struct ClientAttachmentRef: Codable, Hashable, Sendable {
    public let attachmentID: String

    public init(_ attachmentID: String) { self.attachmentID = attachmentID }
}

/// One execution attempt for Work.
public struct RunRef: Codable, Hashable, Sendable {
    public let runID: String

    public init(_ runID: String) { self.runID = runID }
}

/// One user instruction and the work it induces.
public struct TurnRef: Codable, Hashable, Sendable {
    public let turnID: String

    public init(_ turnID: String) { self.turnID = turnID }
}

/// A potentially side-effectful unit of work.
public struct ActionRef: Codable, Hashable, Sendable {
    public let actionID: String

    public init(_ actionID: String) { self.actionID = actionID }
}

/// Durable identity for work that can outlive a turn or run.
public struct HandleRef: Codable, Hashable, Sendable {
    public let handleID: String

    public init(_ handleID: String) { self.handleID = handleID }
}

public struct CommandRef: Codable, Hashable, Sendable {
    public let commandID: String
    public let client: ClientRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let causalCursor: JournalCursor?

    public init(commandID: String, client: ClientRef? = nil,
                sessionAttachment: SessionAttachmentRef? = nil,
                causalCursor: JournalCursor? = nil) {
        self.commandID = commandID
        self.client = client
        self.sessionAttachment = sessionAttachment
        self.causalCursor = causalCursor
    }
}

public enum CommandDeliveryState: String, Codable, Hashable, Sendable {
    case accepted
    case rejected
    case delivered
    case notDelivered = "not_delivered"
    case indeterminate
}

public struct WorkCommandSnapshot: Codable, Hashable, Sendable {
    public let command: CommandRef
    public var state: CommandDeliveryState
    /// Acceptance and delivery are separate provenance facts. A delivery receipt must never
    /// replace the actor/order that admitted the command.
    ///
    /// These are durable event identities, rather than just host metadata. Keeping them in the
    /// projection lets an incremental reducer validate a later delivery receipt even when the
    /// acceptance event was consumed in an earlier reduction pass.
    public let acceptanceEventRef: EventRef?
    public let deliveryEventRef: EventRef?
    public let acceptanceActor: TimelineActor
    public let acceptanceHostSequence: Int
    public let acceptanceIdempotencyKey: String?
    public let deliveryActor: TimelineActor?
    public let deliveryHostSequence: Int?
    public let deliveryIdempotencyKey: String?

    /// Compatibility projections for early consumers.
    public var acceptanceEvent: EventRef? { acceptanceEventRef }
    public var deliveryEvent: EventRef? { deliveryEventRef }
    public var actor: TimelineActor { deliveryActor ?? acceptanceActor }
    public var hostSequence: Int { deliveryHostSequence ?? acceptanceHostSequence }
    public var idempotencyKey: String? { deliveryIdempotencyKey ?? acceptanceIdempotencyKey }

    public init(command: CommandRef, state: CommandDeliveryState, actor: TimelineActor,
                hostSequence: Int, idempotencyKey: String? = nil,
                acceptanceEventRef: EventRef? = nil, deliveryEventRef: EventRef? = nil,
                deliveryActor: TimelineActor? = nil, deliveryHostSequence: Int? = nil,
                deliveryIdempotencyKey: String? = nil) {
        self.command = command
        self.state = state
        self.acceptanceEventRef = acceptanceEventRef
        self.deliveryEventRef = deliveryEventRef
        self.acceptanceActor = actor
        self.acceptanceHostSequence = hostSequence
        self.acceptanceIdempotencyKey = idempotencyKey
        self.deliveryActor = deliveryActor
        self.deliveryHostSequence = deliveryHostSequence
        self.deliveryIdempotencyKey = deliveryIdempotencyKey
    }

    public init(command: CommandRef, state: CommandDeliveryState,
                acceptanceActor: TimelineActor, acceptanceHostSequence: Int,
                acceptanceIdempotencyKey: String? = nil,
                acceptanceEventRef: EventRef? = nil, deliveryEventRef: EventRef? = nil,
                deliveryActor: TimelineActor? = nil, deliveryHostSequence: Int? = nil,
                deliveryIdempotencyKey: String? = nil) {
        self.command = command
        self.state = state
        self.acceptanceEventRef = acceptanceEventRef
        self.deliveryEventRef = deliveryEventRef
        self.acceptanceActor = acceptanceActor
        self.acceptanceHostSequence = acceptanceHostSequence
        self.acceptanceIdempotencyKey = acceptanceIdempotencyKey
        self.deliveryActor = deliveryActor
        self.deliveryHostSequence = deliveryHostSequence
        self.deliveryIdempotencyKey = deliveryIdempotencyKey
    }
}

/// The journal is part of event identity. A Work journal is authoritative for one WorkRef;
/// a Session journal is authoritative for one conversation. Reducers intentionally consume one
/// journal at a time and never merge records by timestamp.
public enum TimelineJournalOwner: Codable, Hashable, Sendable {
    case work(WorkRef)
    case session(SessionRef)
}

public enum TimelineJournalKind: String, Codable, Hashable, Sendable {
    case work
    case session
}

/// The durable namespace responsible for a journal. This is intentionally separate from a
/// process or GUI identity so Session journals remain addressable across devices/services.
public struct TimelineAuthorityRef: Codable, Hashable, Sendable {
    public let authorityID: String

    public init(_ authorityID: String) { self.authorityID = authorityID }
}

public struct JournalRef: Codable, Hashable, Sendable {
    public let journalID: String
    public let authority: TimelineAuthorityRef
    public let owner: TimelineJournalOwner

    public enum ConstructionError: LocalizedError, Equatable, Sendable {
        case workAuthorityMismatch(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .workAuthorityMismatch(let expected, let actual):
                return "Work journal authority must equal Work Host (expected \(expected), got \(actual))."
            }
        }
    }

    /// Construct a journal reference without allowing an invalid Work authority to trap the
    /// process. Session authorities are intentionally independent of Session identity.
    public init(journalID: String, authority: TimelineAuthorityRef, owner: TimelineJournalOwner) throws {
        if case .work(let work) = owner {
            guard authority.authorityID == work.workHostID else {
                throw ConstructionError.workAuthorityMismatch(
                    expected: work.workHostID, actual: authority.authorityID)
            }
        }
        self.init(uncheckedJournalID: journalID, authority: authority, owner: owner)
    }

    private init(uncheckedJournalID journalID: String, authority: TimelineAuthorityRef,
                 owner: TimelineJournalOwner) {
        self.journalID = journalID
        self.authority = authority
        self.owner = owner
    }

    public static func work(_ work: WorkRef, journalID: String = "work") -> JournalRef {
        JournalRef(uncheckedJournalID: journalID,
                   authority: TimelineAuthorityRef(work.workHostID), owner: .work(work))
    }

    public static func session(
        _ session: SessionRef,
        journalID: String = "session",
        authority: TimelineAuthorityRef
    ) -> JournalRef {
        JournalRef(uncheckedJournalID: journalID, authority: authority, owner: .session(session))
    }

    /// Stable, non-secret namespace for legacy synthetic IDs and cross-journal references.
    public var stableKey: String {
        switch owner {
        case .work(let work): return "authority:\(authority.authorityID)/kind:work/work-host:\(work.workHostID)/work:\(work.workID)/journal:\(journalID)"
        case .session(let session): return "authority:\(authority.authorityID)/kind:session/session:\(session.sessionID)/journal:\(journalID)"
        }
    }

    public var kind: TimelineJournalKind {
        switch owner {
        case .work: return .work
        case .session: return .session
        }
    }

    private enum CodingKeys: String, CodingKey { case authority, kind, journalID = "journal_id", owner }
    private enum OwnerKeys: String, CodingKey {
        case kind, workHostID = "work_host_id", workID = "work_id", sessionID = "session_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let authority = try c.decode(TimelineAuthorityRef.self, forKey: .authority)
        let declaredKind = try c.decode(TimelineJournalKind.self, forKey: .kind)
        let journalID = try c.decode(String.self, forKey: .journalID)
        let owner = try c.superDecoder(forKey: .owner)
        let oc = try owner.container(keyedBy: OwnerKeys.self)
        let ownerKind = try oc.decode(TimelineJournalKind.self, forKey: .kind)
        guard declaredKind == ownerKind else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "Journal kind does not match owner kind")
        }
        switch ownerKind {
        case .work:
            let workHostID = try oc.decode(String.self, forKey: .workHostID)
            guard authority.authorityID == workHostID else {
                throw DecodingError.dataCorruptedError(forKey: .authority, in: c,
                                                       debugDescription: "Work journal authority must equal Work Host")
            }
            self.init(uncheckedJournalID: journalID, authority: authority,
                      owner: .work(WorkRef(workHostID: workHostID,
                                          workID: try oc.decode(String.self, forKey: .workID))))
        case .session:
            self.init(uncheckedJournalID: journalID, authority: authority,
                      owner: .session(SessionRef(try oc.decode(String.self, forKey: .sessionID))))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authority, forKey: .authority)
        try c.encode(kind, forKey: .kind)
        try c.encode(journalID, forKey: .journalID)
        var ownerContainer = c.nestedContainer(keyedBy: OwnerKeys.self, forKey: .owner)
        switch owner {
        case .work(let work):
            try ownerContainer.encode(TimelineJournalKind.work, forKey: .kind)
            try ownerContainer.encode(work.workHostID, forKey: .workHostID)
            try ownerContainer.encode(work.workID, forKey: .workID)
        case .session(let session):
            try ownerContainer.encode(TimelineJournalKind.session, forKey: .kind)
            try ownerContainer.encode(session.sessionID, forKey: .sessionID)
        }
    }
}

/// A causal/evidence reference that cannot accidentally point at a bare event id from another
/// journal. `previousEventID` remains local to its containing JournalRef.
public struct EventRef: Codable, Hashable, Sendable {
    public let journal: JournalRef
    public let eventID: String

    public init(journal: JournalRef, eventID: String) {
        self.journal = journal
        self.eventID = eventID
    }
}

public enum TimelineDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case work
    case session
    case context
    case runtime
    case externalEffects = "external_effects"
}

/// Unknown events are retained with their journal position and raw payload. This lets a newer
/// producer remain inspectable by an older reducer without pretending its facets are complete.
public struct UnknownTimelineEvent: Codable, Hashable, Sendable {
    public let event: TimelineEvent
    public let journalOffset: Int
    public let rawPayload: JSONValue
    public let affectedDomains: Set<TimelineDomain>

    public init(
        event: TimelineEvent,
        journalOffset: Int,
        rawPayload: JSONValue? = nil,
        affectedDomains: Set<TimelineDomain> = []
    ) {
        self.event = event
        self.journalOffset = journalOffset
        self.rawPayload = rawPayload ?? event.payload
        self.affectedDomains = affectedDomains
    }
}

public enum TimelineEventProvenance: String, Codable, Hashable, Sendable {
    case native
    case legacyAdapted = "legacy_adapted"
}

/// A device-independent address for a large body kept outside the bounded conversation
/// manifest. It deliberately contains no filesystem path or host-local locator.
public struct TimelineBodyReference: Codable, Hashable, Sendable {
    public let authority: JournalRef
    public let referenceID: String
    public let mediaType: String?
    public let byteCount: Int?
    public let digest: String?

    public init(authority: JournalRef, referenceID: String, mediaType: String? = nil,
                byteCount: Int? = nil, digest: String? = nil) {
        self.authority = authority
        self.referenceID = referenceID
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey {
        case authority, referenceID = "reference_id", mediaType = "media_type", byteCount = "byte_count", digest
    }
}

public struct ContextSourceRef: Codable, Hashable, Sendable {
    public let sourceID: String
    public let provenance: EventRef?

    public init(sourceID: String, provenance: EventRef? = nil) {
        self.sourceID = sourceID
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", provenance
    }
}

// MARK: - Typed protocol values

/// Bounded semantic edges between timeline events.
public enum TimelineLinkKind: String, Codable, Hashable, Sendable {
    case derivedFrom = "derived_from"
    case supports
    case contests
    case supersedes
    case retries
    case produced
    case verifies
}

public enum TimelineEvidenceTarget: Codable, Hashable, Sendable {
    case event(EventRef)
    case artifact(TimelineBodyReference)
    case claim(EventRef)

    private enum CodingKeys: String, CodingKey { case kind, event, artifact, claim }
    private enum Kind: String, Codable { case event, artifact, claim }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let ref): try c.encode(Kind.event, forKey: .kind); try c.encode(ref, forKey: .event)
        case .artifact(let ref): try c.encode(Kind.artifact, forKey: .kind); try c.encode(ref, forKey: .artifact)
        case .claim(let ref): try c.encode(Kind.claim, forKey: .kind); try c.encode(ref, forKey: .claim)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .event: self = .event(try c.decode(EventRef.self, forKey: .event))
        case .artifact: self = .artifact(try c.decode(TimelineBodyReference.self, forKey: .artifact))
        case .claim: self = .claim(try c.decode(EventRef.self, forKey: .claim))
        }
    }
}

public struct TimelineLink: Codable, Hashable, Sendable {
    public let kind: TimelineLinkKind
    public let target: TimelineEvidenceTarget

    public init(kind: TimelineLinkKind, target: EventRef) {
        self.kind = kind
        self.target = .event(target)
    }

    public init(kind: TimelineLinkKind, target: TimelineEvidenceTarget) {
        self.kind = kind
        self.target = target
    }
}

/// Names used by the first Timeline v2 reducer. Unknown strings remain valid events.
public enum TimelineEventType {
    public static let workCreated = "work.created"
    public static let workCompleted = "work.completed"
    public static let workFailed = "work.failed"
    public static let workDestroyed = "work.destroyed"
    public static let sessionCreated = "session.created"
    public static let sessionAttached = "session.attached"
    public static let sessionDetached = "session.detached"
    public static let sessionAttachmentCapabilityChanged = "session.attachment_capability_changed"
    public static let sessionAttachmentCursorAdvanced = "session.attachment_cursor_advanced"
    public static let clientAttached = "client.attached"
    public static let clientDetached = "client.detached"
    public static let clientCapabilityChanged = "client.capability_changed"
    public static let clientCursorAdvanced = "client.cursor_advanced"
    public static let runStarted = "run.started"
    public static let runFinished = "run.finished"
    public static let turnStarted = "turn.started"
    public static let turnFinished = "turn.finished"
    public static let inputAccepted = "input.accepted"
    public static let messageCommitted = "message.committed"
    public static let actionStarted = "action.started"
    public static let actionIntent = "action.intent"
    public static let actionOutcome = "action.outcome"
    public static let handleStarted = "handle.started"
    public static let handleOutcome = "handle.outcome"
    public static let recoveryCoverage = "recovery.coverage"
    public static let contextAssembled = "context.assembled"
    public static let sessionAttention = "session.attention"
    public static let sessionCompleted = "session.completed"
    public static let sessionArchived = "session.archived"
    public static let sessionTipSelected = "session.tip_selected"
    public static let compaction = "context.compacted"
    public static let modelChanged = "model.changed"
    public static let decision = "decision.recorded"
    public static let artifact = "artifact.recorded"
    public static let childLifecycle = "child.lifecycle"
    public static let commandAccepted = "command.accepted"
    public static let commandRejected = "command.rejected"
    public static let commandDelivered = "command.delivered"
    public static let commandNotDelivered = "command.not_delivered"
    public static let commandDeliveryIndeterminate = "command.delivery_indeterminate"
    public static let hostOrderObserved = "host.order_observed"
}

/// A terminal action outcome is more precise than a bare failed bit.
public enum ActionExecutionState: String, Codable, Hashable, Sendable {
    case unknown
    case proposed
    case queued
    case running
    case cancelRequested = "cancel_requested"
    case succeeded
    case failed
    case canceled
    case indeterminateEffect = "indeterminate_effect"

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled, .indeterminateEffect: return true
        case .unknown, .proposed, .queued, .running, .cancelRequested: return false
        }
    }
}

public enum ActionFailureKind: String, Codable, Hashable, Sendable {
    case task
    case infrastructure
    case policy
    case timeout
    case cancellation
    case indeterminateEffect = "indeterminate_effect"
    case other
}

public enum ActionRetrySafety: String, Codable, Hashable, Sendable {
    case safe
    case idempotent
    case unsafe
    case unknown
}

public struct ActionOutcome: Codable, Hashable, Sendable {
    public let state: ActionExecutionState
    public let failureKind: ActionFailureKind?
    public let retrySafety: ActionRetrySafety?

    public init(
        state: ActionExecutionState,
        failureKind: ActionFailureKind? = nil,
        retrySafety: ActionRetrySafety? = nil
    ) {
        self.state = state
        self.failureKind = failureKind
        self.retrySafety = retrySafety
    }
}

public enum RecoveryPlane: String, Codable, CaseIterable, Hashable, Sendable {
    case timeline
    case effectiveContext = "effective_context"
    case runtimeNamespace = "runtime_namespace"
    case backgroundWork = "background_work"
    case memoriesArtifactsRepository = "memories_artifacts_repository"
    case externalEffects = "external_effects"
}

public enum RecoveryCoverageStatus: String, Codable, Hashable, Sendable {
    case preserved
    case reconstructed
    case referenced
    case unknown
    case lost
    case notApplicable = "not_applicable"
}

/// Coverage is intentionally a per-plane record, not a single recovered boolean.
public struct RecoveryCoverage: Codable, Hashable, Sendable {
    public var planes: [RecoveryPlane: RecoveryCoverageStatus]
    public let operation: RecoveryOperation
    public var evidence: EventRef?
    public var evidenceCursor: JournalCursor?
    public var caveats: [String]

    public init(
        operation: RecoveryOperation = .unknown,
        planes: [RecoveryPlane: RecoveryCoverageStatus] = RecoveryPlane.allUnknown,
        evidence: EventRef? = nil,
        evidenceCursor: JournalCursor? = nil,
        caveats: [String] = []
    ) {
        self.operation = operation
        self.planes = RecoveryPlane.complete(planes)
        self.evidence = evidence
        self.evidenceCursor = evidenceCursor
        self.caveats = caveats
    }

    private enum CodingKeys: String, CodingKey {
        case operation, planes, evidence, evidenceCursor = "evidence_cursor", caveats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decodeIfPresent(RecoveryOperation.self, forKey: .operation) ?? .unknown
        let planes = try container.decodeIfPresent(
            [RecoveryPlane: RecoveryCoverageStatus].self, forKey: .planes) ?? [:]
        let evidence = try container.decodeIfPresent(EventRef.self, forKey: .evidence)
        let evidenceCursor = try container.decodeIfPresent(JournalCursor.self, forKey: .evidenceCursor)
        let caveats = try container.decodeIfPresent([String].self, forKey: .caveats) ?? []
        self.init(operation: operation, planes: planes, evidence: evidence,
                  evidenceCursor: evidenceCursor, caveats: caveats)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        try container.encode(planes, forKey: .planes)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try container.encodeIfPresent(evidenceCursor, forKey: .evidenceCursor)
        try container.encode(caveats, forKey: .caveats)
    }
}

public enum RecoveryOperation: String, Codable, Hashable, Sendable {
    case reattachLiveHost = "reattach_live_host"
    case coldResume = "cold_resume"
    case checkpoint
    case fork
    case reconstruct
    case restore
    case unknown
}

public extension RecoveryPlane {
    static var allUnknown: [RecoveryPlane: RecoveryCoverageStatus] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, .unknown) })
    }

    static func complete(_ input: [RecoveryPlane: RecoveryCoverageStatus]) -> [RecoveryPlane: RecoveryCoverageStatus] {
        var result = allUnknown
        for (plane, status) in input { result[plane] = status }
        return result
    }
}

public enum ContextComponentMode: String, Codable, Hashable, Sendable {
    case pinned
    case history
    case compactionSummary = "compaction_summary"
    case attachment
    case instruction
    case omitted
}

public enum ContextDeliveryMode: String, Codable, Hashable, Sendable {
    case full
    case truncated
    case summary
    case manifest
}

/// Identity and measured size are per inclusion, not just per source. This makes context
/// carriage measurable when the same source is included in multiple modes or turns.
public struct ContextComponent: Codable, Hashable, Sendable {
    public let componentID: String
    public let inclusionID: String
    public let source: ContextSourceRef
    public var sourceID: String { source.sourceID }
    public let mode: ContextComponentMode
    public let deliveryMode: ContextDeliveryMode
    public let measuredBytes: Int?
    public let includedBytes: Int?
    public let deliveredBytes: Int?
    public let fullByteCount: Int?
    public let bodyReference: TimelineBodyReference?
    public let digest: String?
    public let tokenCount: Int?
    public let tokenizer: String?
    public let omitted: Bool

    public init(
        componentID: String,
        inclusionID: String,
        sourceID: String,
        sourceProvenance: EventRef? = nil,
        mode: ContextComponentMode,
        deliveryMode: ContextDeliveryMode = .full,
        measuredBytes: Int? = nil,
        includedBytes: Int? = nil,
        deliveredBytes: Int? = nil,
        fullByteCount: Int? = nil,
        bodyReference: TimelineBodyReference? = nil,
        digest: String? = nil,
        tokenCount: Int? = nil,
        tokenizer: String? = nil,
        omitted: Bool = false
    ) {
        self.componentID = componentID
        self.inclusionID = inclusionID
        self.source = ContextSourceRef(sourceID: sourceID, provenance: sourceProvenance)
        self.mode = mode
        self.deliveryMode = deliveryMode
        self.measuredBytes = measuredBytes
        self.includedBytes = includedBytes
        self.deliveredBytes = deliveredBytes
        self.fullByteCount = fullByteCount
        self.bodyReference = bodyReference
        self.digest = digest
        self.tokenCount = tokenCount
        self.tokenizer = tokenizer
        self.omitted = omitted
    }

    private enum CodingKeys: String, CodingKey {
        case componentID = "component_id", inclusionID = "inclusion_id", source
        case mode, deliveryMode = "delivery_mode", measuredBytes = "measured_bytes"
        case includedBytes = "included_bytes", deliveredBytes = "delivered_bytes"
        case fullByteCount = "full_byte_count", bodyReference = "body_ref", digest
        case tokenCount = "token_count", tokenizer, omitted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            componentID: try c.decode(String.self, forKey: .componentID),
            inclusionID: try c.decode(String.self, forKey: .inclusionID),
            sourceID: try c.decode(ContextSourceRef.self, forKey: .source).sourceID,
            sourceProvenance: try c.decode(ContextSourceRef.self, forKey: .source).provenance,
            mode: try c.decode(ContextComponentMode.self, forKey: .mode),
            deliveryMode: try c.decode(ContextDeliveryMode.self, forKey: .deliveryMode),
            measuredBytes: try c.decodeIfPresent(Int.self, forKey: .measuredBytes),
            includedBytes: try c.decodeIfPresent(Int.self, forKey: .includedBytes),
            deliveredBytes: try c.decodeIfPresent(Int.self, forKey: .deliveredBytes),
            fullByteCount: try c.decodeIfPresent(Int.self, forKey: .fullByteCount),
            bodyReference: try c.decodeIfPresent(TimelineBodyReference.self, forKey: .bodyReference),
            digest: try c.decodeIfPresent(String.self, forKey: .digest),
            tokenCount: try c.decodeIfPresent(Int.self, forKey: .tokenCount),
            tokenizer: try c.decodeIfPresent(String.self, forKey: .tokenizer),
            omitted: try c.decodeIfPresent(Bool.self, forKey: .omitted) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(componentID, forKey: .componentID)
        try c.encode(inclusionID, forKey: .inclusionID)
        try c.encode(source, forKey: .source)
        try c.encode(mode, forKey: .mode)
        try c.encode(deliveryMode, forKey: .deliveryMode)
        try c.encodeIfPresent(measuredBytes, forKey: .measuredBytes)
        try c.encodeIfPresent(includedBytes, forKey: .includedBytes)
        try c.encodeIfPresent(deliveredBytes, forKey: .deliveredBytes)
        try c.encodeIfPresent(fullByteCount, forKey: .fullByteCount)
        try c.encodeIfPresent(bodyReference, forKey: .bodyReference)
        try c.encodeIfPresent(digest, forKey: .digest)
        try c.encodeIfPresent(tokenCount, forKey: .tokenCount)
        try c.encodeIfPresent(tokenizer, forKey: .tokenizer)
        try c.encode(omitted, forKey: .omitted)
    }
}

// MARK: - Timeline envelope

/// Versioned, append-only event envelope shared by Session and Work journals.
///
/// `type` is deliberately a string rather than an exhaustive enum: future producers must remain
/// readable by older reducers. Unknown event types are retained by reducers as full envelopes.
public struct TimelineEvent: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maxEvidenceLinks = 32

    public let eventID: String
    public let journal: JournalRef
    public let sequence: Int
    /// Optional host-issued sequence and command idempotency key. The journal sequence remains
    /// authoritative; these fields let a remote host deduplicate retries without a GUI owner.
    public let hostSequence: Int?
    public let idempotencyKey: String?
    public let command: CommandRef?
    public let previousEventID: String?
    public let causedByEventID: EventRef?
    public let parentActivityID: EventRef?
    /// Semantic conversation parent; deliberately separate from the physical append-chain link.
    public let conversationParent: EventRef?
    public let session: SessionRef?
    public let work: WorkRef?
    public let workHost: WorkHostRef?
    public let client: ClientRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let clientAttachment: ClientAttachmentRef?
    public let run: RunRef?
    public let turn: TurnRef?
    public let action: ActionRef?
    public let handle: HandleRef?
    public let actor: TimelineActor
    public let hostRecordedAt: Date
    public let clientTimestamp: Date?
    public let schemaVersion: Int
    public let payloadVersion: Int
    public let type: String
    public let declaredDomains: Set<TimelineDomain>
    public let provenance: TimelineEventProvenance
    public let links: [TimelineLink]
    public let payload: JSONValue

    public init(
        eventID: String,
        journal: JournalRef,
        sequence: Int,
        hostSequence: Int? = nil,
        idempotencyKey: String? = nil,
        command: CommandRef? = nil,
        previousEventID: String? = nil,
        causedByEventID: EventRef? = nil,
        parentActivityID: EventRef? = nil,
        conversationParent: EventRef? = nil,
        session: SessionRef? = nil,
        work: WorkRef? = nil,
        workHost: WorkHostRef? = nil,
        client: ClientRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil,
        clientAttachment: ClientAttachmentRef? = nil,
        run: RunRef? = nil,
        turn: TurnRef? = nil,
        action: ActionRef? = nil,
        handle: HandleRef? = nil,
        actor: TimelineActor,
        hostRecordedAt: Date,
        clientTimestamp: Date? = nil,
        schemaVersion: Int = TimelineEvent.currentSchemaVersion,
        payloadVersion: Int = 1,
        type: String,
        declaredDomains: Set<TimelineDomain> = [],
        provenance: TimelineEventProvenance = .native,
        links: [TimelineLink] = [],
        payload: JSONValue = .object([:])
    ) {
        self.eventID = eventID
        self.journal = journal
        self.sequence = sequence
        self.hostSequence = hostSequence
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.previousEventID = previousEventID
        self.causedByEventID = causedByEventID
        self.parentActivityID = parentActivityID
        self.conversationParent = conversationParent
        self.session = session
        self.work = work
        self.workHost = workHost
        self.client = client
        self.sessionAttachment = sessionAttachment
        self.clientAttachment = clientAttachment
        self.run = run
        self.turn = turn
        self.action = action
        self.handle = handle
        self.actor = actor
        self.hostRecordedAt = hostRecordedAt
        self.clientTimestamp = clientTimestamp
        self.schemaVersion = schemaVersion
        self.payloadVersion = payloadVersion
        self.type = type
        self.declaredDomains = declaredDomains
        self.provenance = provenance
        self.links = Array(links.prefix(Self.maxEvidenceLinks))
        self.payload = payload
    }

    public var isKnownType: Bool {
        Self.knownTypes.contains(type)
    }

    /// A namespaced identity for records imported from legacy logs that did not carry event ids.
    public static func syntheticLegacyEventID(journal: JournalRef, offset: Int, rawID: String?) -> String {
        let raw = rawID ?? "none"
        return "legacy:\(journal.stableKey):offset:\(offset):raw:\(raw)"
    }

    private static let knownTypes: Set<String> = [
        TimelineEventType.workCreated, TimelineEventType.workCompleted,
        TimelineEventType.workFailed, TimelineEventType.workDestroyed,
        TimelineEventType.sessionCreated, TimelineEventType.sessionAttached,
        TimelineEventType.sessionDetached, TimelineEventType.sessionAttachmentCapabilityChanged,
        TimelineEventType.sessionAttachmentCursorAdvanced, TimelineEventType.clientAttached,
        TimelineEventType.clientDetached, TimelineEventType.clientCapabilityChanged,
        TimelineEventType.clientCursorAdvanced,
        TimelineEventType.runStarted,
        TimelineEventType.runFinished, TimelineEventType.turnStarted,
        TimelineEventType.turnFinished, TimelineEventType.inputAccepted,
        TimelineEventType.messageCommitted, TimelineEventType.actionStarted,
        TimelineEventType.actionIntent,
        TimelineEventType.actionOutcome, TimelineEventType.handleStarted,
        TimelineEventType.handleOutcome, TimelineEventType.recoveryCoverage,
        TimelineEventType.contextAssembled, TimelineEventType.sessionAttention,
        TimelineEventType.sessionCompleted, TimelineEventType.sessionArchived,
        TimelineEventType.sessionTipSelected,
        TimelineEventType.compaction, TimelineEventType.modelChanged,
        TimelineEventType.decision, TimelineEventType.artifact, TimelineEventType.childLifecycle,
        TimelineEventType.commandAccepted, TimelineEventType.commandRejected,
        TimelineEventType.commandDelivered, TimelineEventType.commandNotDelivered,
        TimelineEventType.commandDeliveryIndeterminate, TimelineEventType.hostOrderObserved,
    ]

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case journal
        case sequence
        case hostSequence = "host_sequence"
        case idempotencyKey = "idempotency_key"
        case command
        case previousEventID = "previous_event_id"
        case causedByEventID = "caused_by_event_id"
        case parentActivityID = "parent_activity_id"
        case conversationParent = "conversation_parent"
        case session
        case work
        case workHost = "work_host"
        case client
        case sessionAttachment = "session_attachment"
        case clientAttachment = "client_attachment"
        case run
        case turn
        case action
        case handle
        case actor
        case hostRecordedAt = "host_recorded_at"
        case clientTimestamp = "client_timestamp"
        case schemaVersion = "schema_version"
        case payloadVersion = "payload_version"
        case type
        case declaredDomains = "declared_domains"
        case provenance
        case links
        case payload
    }
}

// MARK: - Journal bytes and legacy adaptation

public struct TimelineJournalRecord: Codable, Hashable, Sendable {
    public let event: TimelineEvent
    public let rawLineBytes: Data
    public let byteStart: Int
    public let byteEnd: Int
    public let legacyRawID: String?

    public init(event: TimelineEvent, rawLineBytes: Data, byteStart: Int, byteEnd: Int,
                legacyRawID: String? = nil) {
        self.event = event
        self.rawLineBytes = rawLineBytes
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.legacyRawID = legacyRawID
    }
}

public struct TimelineJournalTail: Codable, Hashable, Sendable {
    public let rawBytes: Data
    public let byteStart: Int
    public let byteEnd: Int

    public init(rawBytes: Data, byteStart: Int, byteEnd: Int) {
        self.rawBytes = rawBytes
        self.byteStart = byteStart
        self.byteEnd = byteEnd
    }
}

public struct TimelineJournalReadResult: Codable, Hashable, Sendable {
    public let records: [TimelineJournalRecord]
    public let quarantinedSuffix: TimelineJournalTail?
    public let truncatedTail: TimelineJournalTail?

    public init(records: [TimelineJournalRecord], quarantinedSuffix: TimelineJournalTail? = nil,
                truncatedTail: TimelineJournalTail? = nil) {
        self.records = records
        self.quarantinedSuffix = quarantinedSuffix
        self.truncatedTail = truncatedTail
    }
}

/// Byte-oriented JSONL reader. A final unterminated line is deliberately not committed. A
/// malformed interior line quarantines that line and all following bytes so a later append cannot
/// make the journal appear contiguous by silently skipping corruption.
public enum TimelineJournalReader {
    public static func read(
        _ data: Data,
        journal: JournalRef,
        actor: TimelineActor,
        hostRecordedAt: Date,
        initialByteOffset: Int = 0,
        initialSequence: Int = 1,
        initialPreviousEventID: String? = nil
    ) -> TimelineJournalReadResult {
        let bytes = Array(data)
        var records: [TimelineJournalRecord] = []
        var offset = 0
        let decoder = JSONDecoder()
        while offset < bytes.count {
            guard let newline = bytes[offset...].firstIndex(of: 0x0A) else {
                return TimelineJournalReadResult(
                    records: records,
                    truncatedTail: TimelineJournalTail(rawBytes: Data(bytes[offset...]),
                                                       byteStart: initialByteOffset + offset,
                                                       byteEnd: initialByteOffset + bytes.count))
            }
            let lineEnd = newline + 1
            let raw = Data(bytes[offset..<lineEnd])
            let content = Data(bytes[offset..<newline])
            guard let value = JSONValue.parse(content) else {
                return TimelineJournalReadResult(
                    records: records,
                    quarantinedSuffix: TimelineJournalTail(rawBytes: Data(bytes[offset...]),
                                                           byteStart: initialByteOffset + offset,
                                                           byteEnd: initialByteOffset + bytes.count))
            }
            if let event = try? decoder.decode(TimelineEvent.self, from: content) {
                let expectedSequence = initialSequence + records.count
                let expectedPrevious = records.last?.event.eventID ?? initialPreviousEventID
                guard event.journal == journal,
                      event.sequence == expectedSequence,
                      event.previousEventID == expectedPrevious
                else {
                    return TimelineJournalReadResult(
                        records: records,
                        quarantinedSuffix: TimelineJournalTail(rawBytes: Data(bytes[offset...]),
                                                               byteStart: initialByteOffset + offset,
                                                               byteEnd: initialByteOffset + bytes.count))
                }
                records.append(TimelineJournalRecord(event: event, rawLineBytes: raw,
                                                     byteStart: initialByteOffset + offset,
                                                     byteEnd: initialByteOffset + lineEnd))
            } else if let object = value.objectValue,
                      object["schema_version"] == nil,
                      object["journal"] == nil,
                      let legacy = adaptLegacy(value, journal: journal,
                                               byteOffset: initialByteOffset + offset,
                                               sequence: initialSequence + records.count,
                                               previousEventID: records.last?.event.eventID ?? initialPreviousEventID,
                                               actor: actor, hostRecordedAt: hostRecordedAt) {
                records.append(TimelineJournalRecord(event: legacy.event, rawLineBytes: raw,
                                                     byteStart: initialByteOffset + offset,
                                                     byteEnd: initialByteOffset + lineEnd,
                                                     legacyRawID: legacy.rawID))
            } else {
                return TimelineJournalReadResult(
                        records: records,
                        quarantinedSuffix: TimelineJournalTail(rawBytes: Data(bytes[offset...]),
                                                           byteStart: initialByteOffset + offset,
                                                           byteEnd: initialByteOffset + bytes.count))
            }
            offset = lineEnd
        }
        return TimelineJournalReadResult(records: records)
    }

    private struct LegacyAdapted {
        let event: TimelineEvent
        let rawID: String?
    }

    private static func adaptLegacy(
        _ value: JSONValue,
        journal: JournalRef,
        byteOffset: Int,
        sequence: Int,
        previousEventID: String?,
        actor: TimelineActor,
        hostRecordedAt: Date
    ) -> LegacyAdapted? {
        guard let object = value.objectValue else { return nil }
        let rawID = object["event_id"]?.stringValue ?? object["id"]?.stringValue
            ?? object["uuid"]?.stringValue
        let type = object["type"]?.stringValue ?? "legacy.entry"
        let event = TimelineEvent(
            eventID: TimelineEvent.syntheticLegacyEventID(journal: journal, offset: byteOffset, rawID: rawID),
            journal: journal, sequence: sequence, previousEventID: previousEventID,
            actor: actor, hostRecordedAt: hostRecordedAt, type: type,
            declaredDomains: Set(TimelineDomain.allCases), provenance: .legacyAdapted,
            payload: value)
        return LegacyAdapted(event: event, rawID: rawID)
    }
}

/// Incremental reader state for paged/streamed journal reads. Incomplete bytes are retained
/// until the next chunk; committed records keep absolute byte ranges and legacy IDs.
public struct TimelineJournalReaderState: Sendable {
    public let journal: JournalRef
    public let actor: TimelineActor
    public let hostRecordedAt: Date
    private var pending: Data = Data()
    private var byteOffset: Int
    private var sequence: Int
    private var previousEventID: String?
    private var isQuarantined = false

    public init(journal: JournalRef, actor: TimelineActor, hostRecordedAt: Date,
                initialByteOffset: Int = 0, initialSequence: Int = 1,
                initialPreviousEventID: String? = nil) {
        self.journal = journal
        self.actor = actor
        self.hostRecordedAt = hostRecordedAt
        self.byteOffset = initialByteOffset
        self.sequence = initialSequence
        self.previousEventID = initialPreviousEventID
    }

    public mutating func append(_ chunk: Data, final: Bool = false) -> TimelineJournalReadResult {
        pending.append(chunk)
        if isQuarantined {
            return TimelineJournalReadResult(
                records: [],
                quarantinedSuffix: TimelineJournalTail(
                    rawBytes: pending, byteStart: byteOffset, byteEnd: byteOffset + pending.count))
        }
        let result = TimelineJournalReader.read(
            pending, journal: journal, actor: actor, hostRecordedAt: hostRecordedAt,
            initialByteOffset: byteOffset, initialSequence: sequence,
            initialPreviousEventID: previousEventID)
        if let suffix = result.quarantinedSuffix {
            // `result.records` is the committed prefix. Advance the cursor before retaining the
            // corrupt suffix; otherwise a subsequent observer would replay the prefix against
            // stale sequence/previous values and lose stable offsets.
            if let last = result.records.last {
                previousEventID = last.event.eventID
                sequence = last.event.sequence + 1
                byteOffset = last.byteEnd
            }
            pending = suffix.rawBytes
            isQuarantined = true
            return result
        }
        if let tail = result.truncatedTail, !final {
            pending = tail.rawBytes
        } else {
            pending = Data()
        }
        if let last = result.records.last {
            previousEventID = last.event.eventID
            sequence = last.event.sequence + 1
            byteOffset = last.byteEnd
        } else if pending.isEmpty {
            byteOffset += chunk.count
        }
        if final { pending = Data() }
        return result
    }
}

// MARK: - Reducer snapshots

public enum WorkLifecycle: String, Codable, Hashable, Sendable {
    case active
    case completed
    case destroyed
    case unknown
}

public enum WorkExecution: String, Codable, Hashable, Sendable {
    case unknown
    case idle
    case preparing
    case running
    case canceling
    case held
    case failed
}

public struct WorkActionSnapshot: Codable, Hashable, Sendable {
    public let action: ActionRef
    public var state: ActionExecutionState
    public var failureKind: ActionFailureKind?
    public var retrySafety: ActionRetrySafety?

    public init(
        action: ActionRef,
        state: ActionExecutionState = .proposed,
        failureKind: ActionFailureKind? = nil,
        retrySafety: ActionRetrySafety? = nil
    ) {
        self.action = action
        self.state = state
        self.failureKind = failureKind
        self.retrySafety = retrySafety
    }
}

public struct WorkHandleSnapshot: Codable, Hashable, Sendable {
    public let handle: HandleRef
    public var state: String

    public init(handle: HandleRef, state: String = "pending") {
        self.handle = handle
        self.state = state
    }
}

public struct ClientAttachmentSnapshot: Codable, Hashable, Sendable {
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public var cursor: JournalCursor?
    public var capabilities: Set<String>
    public var isAttached: Bool

    public init(
        attachment: ClientAttachmentRef,
        client: ClientRef,
        cursor: JournalCursor? = nil,
        isAttached: Bool = true,
        capabilities: Set<String> = []
    ) {
        self.attachment = attachment
        self.client = client
        self.cursor = cursor
        self.isAttached = isAttached
        self.capabilities = capabilities
    }
}

public struct SessionAttachmentSnapshot: Codable, Hashable, Sendable {
    public let attachment: SessionAttachmentRef
    public let work: WorkRef
    public var cursor: JournalCursor?
    public var capabilities: Set<String>
    public var isAttached: Bool

    public init(
        attachment: SessionAttachmentRef,
        work: WorkRef,
        cursor: JournalCursor? = nil,
        capabilities: Set<String> = [],
        isAttached: Bool = true
    ) {
        self.attachment = attachment
        self.work = work
        self.cursor = cursor
        self.capabilities = capabilities
        self.isAttached = isAttached
    }
}

public struct WorkSessionAttachmentSnapshot: Codable, Hashable, Sendable {
    public let attachment: SessionAttachmentRef
    public let session: SessionRef
    public var capabilities: Set<String>
    public var isAttached: Bool

    public init(attachment: SessionAttachmentRef, session: SessionRef,
                capabilities: Set<String> = [], isAttached: Bool = true) {
        self.attachment = attachment
        self.session = session
        self.capabilities = capabilities
        self.isAttached = isAttached
    }
}

public struct WorkSnapshot: Codable, Hashable, Sendable {
    public var journal: JournalRef?
    public var work: WorkRef?
    public var workHost: WorkHostRef?
    public var lifecycle: WorkLifecycle = .unknown
    public var execution: WorkExecution = .idle
    public var attachedSessionIDs: Set<String> = []
    public var sessionAttachments: [String: WorkSessionAttachmentSnapshot] = [:]
    public var attachedClientIDs: Set<String> = []
    public var clientAttachments: [String: ClientAttachmentSnapshot] = [:]
    public var activeRun: RunRef?
    /// The currently effective model, projected from run/model events rather than inferred by
    /// a secondary reader scanning arbitrary payloads.
    public var modelID: String?
    public var activeTurn: TurnRef?
    public var activeActionIDs: Set<String> = []
    public var actions: [String: WorkActionSnapshot] = [:]
    public var handles: [String: WorkHandleSnapshot] = [:]
    public var commands: [String: WorkCommandSnapshot] = [:]
    /// Minimal typed projection for child lifecycle events. Keeping this in the Work snapshot
    /// prevents a Census/report reader from re-scanning opaque payloads.
    public var childStates: [String: String] = [:]
    public var lastHostSequence: Int?
    public var recovery: [RecoveryCoverage] = []
    public var semanticTip: EventRef?
    public var unknownDomains: Set<TimelineDomain> = []
    public var lastEventID: String?
    public var lastSequence: Int = 0
    public var eventSequences: [String: Int] = [:]
    public var causalOrderValid = true
    public var structuralIntegrityValid = true
    public var semanticProjectionValid = true
    public var seenEventIDs: Set<String> = []
    public var unknownEvents: [UnknownTimelineEvent] = []
    public var quarantinedEvents: [TimelineEvent] = []
    public var corruptionReasons: [String] = []

    public init() {}
}

public struct SessionMessageSnapshot: Codable, Hashable, Sendable {
    public let eventID: String
    public let role: String
    public let text: String
    public let conversationParent: EventRef?

    public init(eventID: String, role: String, text: String, conversationParent: EventRef? = nil) {
        self.eventID = eventID
        self.role = role
        self.text = text
        self.conversationParent = conversationParent
    }
}

public enum SessionLifecycle: String, Codable, Hashable, Sendable {
    case active
    case completed
    case archived
    case unknown
}

public enum SessionAttention: String, Codable, Hashable, Sendable {
    case none
    case input
    case confirmation
    case error
    case review
}

public struct SessionSnapshot: Codable, Hashable, Sendable {
    public var journal: JournalRef?
    public var session: SessionRef?
    public var attachments: [String: SessionAttachmentSnapshot] = [:]
    public var attachedClientIDs: Set<String> = []
    public var clientAttachments: [String: ClientAttachmentSnapshot] = [:]
    public var lifecycle: SessionLifecycle = .unknown
    /// Reserved for session-local lifecycle projections. Work execution is supplied by
    /// SessionAssembler from the attached WorkSnapshot, never reduced here.
    public var execution: WorkExecution = .idle
    public var attention: SessionAttention = .none
    /// Kept for compatibility with early consumers; these are not populated by SessionReducer.
    public var activeRun: RunRef?
    public var modelID: String?
    public var activeTurn: TurnRef?
    public var messages: [SessionMessageSnapshot] = []
    public var messageHistory: [SessionMessageSnapshot] = []
    public var contextComponents: [ContextComponent] = []
    /// The latest complete provider-bound context crossing. Legacy fixtures may carry only
    /// `contextComponents`; a nil value therefore means "older projection," not "no context."
    public var contextManifest: ContextManifest?
    /// Authoritative context-carriage totals, scoped by Run. Optional preserves decoding of
    /// snapshots created before cumulative manifests existed.
    public var contextCumulativeDeliveredBytesByRun: [String: Int]?
    public var contextBoundaryEventID: String?
    /// The latest compaction summary is a durable context projection, not merely an unknown
    /// event retained for a future reader.
    public var compactionSummary: String?
    /// Child lifecycle is retained on whichever journal records the observation.
    public var childStates: [String: String] = [:]
    public var recovery: [RecoveryCoverage] = []
    public var semanticTip: EventRef?
    public var unknownDomains: Set<TimelineDomain> = []
    public var lastEventID: String?
    public var lastSequence: Int = 0
    public var causalOrderValid = true
    public var structuralIntegrityValid = true
    public var semanticProjectionValid = true
    public var seenEventIDs: Set<String> = []
    public var unknownEvents: [UnknownTimelineEvent] = []
    public var quarantinedEvents: [TimelineEvent] = []
    public var corruptionReasons: [String] = []

    public init() {}

    /// Compatibility conveniences; the attachment map is authoritative and may contain N Work.
    public var attachedWork: WorkRef? {
        let active = attachments.values.filter(\.isAttached)
        return active.count == 1 ? active[0].work : nil
    }

    public var attachedSessionAttachment: SessionAttachmentRef? {
        let active = attachments.values.filter(\.isAttached)
        return active.count == 1 ? active[0].attachment : nil
    }
}
