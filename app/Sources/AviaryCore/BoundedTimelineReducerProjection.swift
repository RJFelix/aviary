import Foundation

/// The durable, bounded projection state for a reducer head.
///
/// A projection is an index and a recovery hint, never a second authority.  The canonical JSONL
/// journal and ``WorkReducer``/``SessionReducer`` remain the source of truth.  In particular, no
/// record in this file contains a message body, tool argument, action text, arbitrary payload, or
/// Python value.  Large values are represented by an address, byte count, and digest instead.
public enum BoundedReducerProjectionState: String, Codable, Hashable, Sendable {
    case complete
    /// The reducer saw an unknown event or the bounded index could not retain every exact row.
    /// Callers may use retained rows for diagnostics, but must not treat the projection as a
    /// complete canonical view until the journal is reduced again.
    case sourceIncomplete = "source_incomplete"
    /// A semantic or structural reducer failure was observed.  A fresh canonical reduction is
    /// required before this projection can be used to make a control decision.
    case requiresRebuild = "requires_rebuild"
}

public enum BoundedReducerProjectionIndex: String, Codable, CaseIterable, Hashable, Sendable {
    case actions
    case handles
    case agentHandles = "agent_handles"
    case commands
    case attachments
    case messages
    case context
    case recovery
    case unknowns
    case corruption
    case children
}

public struct BoundedReducerProjectionOmission: Codable, Hashable, Sendable {
    public let index: BoundedReducerProjectionIndex
    public let omittedCount: Int

    public init(index: BoundedReducerProjectionIndex, omittedCount: Int) {
        self.index = index
        self.omittedCount = max(0, omittedCount)
    }
}

/// Completeness is tracked per index.  A long-lived Work may have a complete scalar head while
/// its bounded historical action index is only a prefix; callers must not turn that omission
/// into a false claim that the Work itself is unavailable.
public struct BoundedReducerProjectionIndexCoverage: Codable, Hashable, Sendable {
    public let index: BoundedReducerProjectionIndex
    public let state: BoundedReducerProjectionState
    public let totalCount: Int
    public let retainedCount: Int
    public let omittedCount: Int

    public init(
        index: BoundedReducerProjectionIndex,
        state: BoundedReducerProjectionState,
        totalCount: Int,
        retainedCount: Int,
        omittedCount: Int
    ) {
        self.index = index
        self.state = state
        self.totalCount = max(0, totalCount)
        self.retainedCount = max(0, retainedCount)
        self.omittedCount = max(0, omittedCount)
    }
}

/// A diagnostic deliberately stores a digest of a reason, not the reason itself.  Reducer error
/// strings can contain user-provided text and are not safe to copy into a durable head.
public struct BoundedReducerProjectionDiagnostic: Codable, Hashable, Sendable {
    public let code: String
    public let reasonDigest: String
    public let sourceEvent: BoundedReducerProjectionEvent?

    public init(
        code: String,
        reasonDigest: String,
        sourceEvent: BoundedReducerProjectionEvent? = nil
    ) {
        self.code = code
        self.reasonDigest = reasonDigest
        self.sourceEvent = sourceEvent
    }
}

public struct BoundedReducerProjectionCoverage: Codable, Hashable, Sendable {
    public let state: BoundedReducerProjectionState
    public let scalarState: BoundedReducerProjectionState
    public let indexCoverage: [BoundedReducerProjectionIndexCoverage]
    public let omissions: [BoundedReducerProjectionOmission]
    public let unknownEventCount: Int
    public let corruptionCount: Int
    /// Number of reducer facts that had no canonical event/source observation at projection time.
    /// This is distinct from bounded historical row omission: a complete scalar head can coexist
    /// with omitted resolved index rows, but it cannot claim complete evidence for an unobserved
    /// fact.
    public let missingSourceEvidenceCount: Int
    /// Whether an unsettled/active item was evicted by a bounded index.
    public let activeItemsOmitted: Bool
    public let activeItemCount: Int
    public let retainedActiveItemCount: Int
    public let diagnostics: [BoundedReducerProjectionDiagnostic]

    public init(
        state: BoundedReducerProjectionState,
        scalarState: BoundedReducerProjectionState? = nil,
        indexCoverage: [BoundedReducerProjectionIndexCoverage] = [],
        omissions: [BoundedReducerProjectionOmission] = [],
        unknownEventCount: Int = 0,
        corruptionCount: Int = 0,
        missingSourceEvidenceCount: Int = 0,
        activeItemsOmitted: Bool = false,
        activeItemCount: Int = 0,
        retainedActiveItemCount: Int = 0,
        diagnostics: [BoundedReducerProjectionDiagnostic] = []
    ) {
        self.state = state
        self.scalarState = scalarState ?? state
        self.indexCoverage = indexCoverage.sorted { $0.index.rawValue < $1.index.rawValue }
        var omissionCounts: [BoundedReducerProjectionIndex: Int] = [:]
        for omission in omissions {
            omissionCounts[omission.index, default: 0] += omission.omittedCount
        }
        self.omissions = omissionCounts.map {
            BoundedReducerProjectionOmission(index: $0.key, omittedCount: $0.value)
        }.sorted { lhs, rhs in
            lhs.index.rawValue < rhs.index.rawValue
        }
        self.unknownEventCount = max(0, unknownEventCount)
        self.corruptionCount = max(0, corruptionCount)
        self.missingSourceEvidenceCount = max(0, missingSourceEvidenceCount)
        self.activeItemsOmitted = activeItemsOmitted
        self.activeItemCount = max(0, activeItemCount)
        self.retainedActiveItemCount = max(0, retainedActiveItemCount)
        self.diagnostics = diagnostics
    }

    public var isControlling: Bool { scalarState == .complete }

    public func coverage(for index: BoundedReducerProjectionIndex) -> BoundedReducerProjectionIndexCoverage? {
        indexCoverage.first { $0.index == index }
    }

    public func isIndexComplete(_ index: BoundedReducerProjectionIndex) -> Bool {
        coverage(for: index)?.state == .complete
    }
}

/// Evidence tying one reducer head to one exact canonical source prefix.
///
/// ``prefixDigest`` is the canonical JSONL prefix digest at ``cursor``.  A source generation is
/// separate from an observation fingerprint: appending to a file changes the observation but
/// must not silently replace the physical/remote source represented by a head.
public struct BoundedReducerProjectionSource: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let journal: JournalRef
    public let cursor: JournalCursor
    public let sourceID: String
    public let sourceGeneration: String
    public let sourceFingerprint: String
    public let sourceByteCount: Int
    public let prefixByteCount: Int
    public let prefixDigest: String

    public init(
        journal: JournalRef,
        cursor: JournalCursor,
        sourceID: String,
        sourceGeneration: String,
        sourceFingerprint: String,
        sourceByteCount: Int,
        prefixByteCount: Int,
        prefixDigest: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.journal = journal
        self.cursor = cursor
        self.sourceID = sourceID
        self.sourceGeneration = sourceGeneration
        self.sourceFingerprint = sourceFingerprint
        self.sourceByteCount = sourceByteCount
        self.prefixByteCount = prefixByteCount
        self.prefixDigest = prefixDigest
    }

    public init(
        source: DisposableTimelineProjectionStore.SourceFingerprint,
        cursor: JournalCursor
    ) {
        self.init(
            journal: source.journal,
            cursor: cursor,
            sourceID: source.sourceID,
            sourceGeneration: source.sourceGeneration,
            sourceFingerprint: source.fingerprint,
            sourceByteCount: source.sourceByteCount,
            prefixByteCount: source.prefixByteCount,
            prefixDigest: source.prefixDigest)
    }
}

/// A reference to a canonical event, with enough position/digest metadata for a later direct
/// lookup.  ``canonicalDigest`` is optional for snapshot-only adaptation; canonical builds fill
/// it whenever the source event was available.
public struct BoundedReducerProjectionEvent: Codable, Hashable, Sendable {
    public let reference: EventRef
    public let sequence: Int?
    public let type: String?
    public let canonicalDigest: String?

    public init(
        reference: EventRef,
        sequence: Int? = nil,
        type: String? = nil,
        canonicalDigest: String? = nil
    ) {
        self.reference = reference
        self.sequence = sequence
        self.type = type
        self.canonicalDigest = canonicalDigest
    }
}

public struct BoundedReducerProjectionDigest: Codable, Hashable, Sendable {
    public let byteCount: Int
    public let digest: String

    public init(byteCount: Int, digest: String) {
        self.byteCount = max(0, byteCount)
        self.digest = digest
    }
}

public struct BoundedReducerProjectionRun: Codable, Hashable, Sendable {
    public let run: RunRef
    public let sourceEvent: BoundedReducerProjectionEvent?

    public init(run: RunRef, sourceEvent: BoundedReducerProjectionEvent? = nil) {
        self.run = run
        self.sourceEvent = sourceEvent
    }
}

public struct BoundedReducerProjectionTurn: Codable, Hashable, Sendable {
    public let turn: TurnRef
    public let sourceEvent: BoundedReducerProjectionEvent?

    public init(turn: TurnRef, sourceEvent: BoundedReducerProjectionEvent? = nil) {
        self.turn = turn
        self.sourceEvent = sourceEvent
    }
}

public struct BoundedWorkActionIndexRecord: Codable, Hashable, Sendable {
    public let action: ActionRef
    public let kind: ActionKind
    public let state: ActionExecutionState
    public let failureKind: ActionFailureKind?
    public let retrySafety: ActionRetrySafety?
    public let intent: BoundedReducerProjectionDigest?
    public let target: BoundedReducerProjectionDigest?
    public let scope: BoundedReducerProjectionDigest?
    public let metadata: BoundedReducerProjectionDigest?
    public let metadataWasTruncated: Bool
    public let providerAdmission: ProviderAdmission?
    public let providerSettlement: ProviderSettlement?
    public let intentEvent: BoundedReducerProjectionEvent?
    public let startedEvent: BoundedReducerProjectionEvent?
    public let outcomeEvent: BoundedReducerProjectionEvent?

    public init(
        action: ActionRef,
        kind: ActionKind,
        state: ActionExecutionState,
        failureKind: ActionFailureKind? = nil,
        retrySafety: ActionRetrySafety? = nil,
        intent: BoundedReducerProjectionDigest? = nil,
        target: BoundedReducerProjectionDigest? = nil,
        scope: BoundedReducerProjectionDigest? = nil,
        metadata: BoundedReducerProjectionDigest? = nil,
        metadataWasTruncated: Bool = false,
        providerAdmission: ProviderAdmission? = nil,
        providerSettlement: ProviderSettlement? = nil,
        intentEvent: BoundedReducerProjectionEvent? = nil,
        startedEvent: BoundedReducerProjectionEvent? = nil,
        outcomeEvent: BoundedReducerProjectionEvent? = nil
    ) {
        self.action = action
        self.kind = kind
        self.state = state
        self.failureKind = failureKind
        self.retrySafety = retrySafety
        self.intent = intent
        self.target = target
        self.scope = scope
        self.metadata = metadata
        self.metadataWasTruncated = metadataWasTruncated
        self.providerAdmission = providerAdmission
        self.providerSettlement = providerSettlement
        self.intentEvent = intentEvent
        self.startedEvent = startedEvent
        self.outcomeEvent = outcomeEvent
    }
}

public struct BoundedWorkHandleIndexRecord: Codable, Hashable, Sendable {
    public let handle: HandleRef
    /// Fixed projection vocabulary. The producer state itself is never persisted.
    public let state: BoundedHandleState
    /// Digest of the producer's state spelling, retained for exact inspection/correlation without
    /// copying arbitrary state text into the durable head. The digest carries the byte count.
    public let stateDigest: BoundedReducerProjectionDigest
    public let sourceEvent: BoundedReducerProjectionEvent?

    public init(
        handle: HandleRef,
        state: String,
        sourceEvent: BoundedReducerProjectionEvent? = nil
    ) {
        self.handle = handle
        self.state = BoundedTimelineReducerProjection.classifyHandleState(state)
        self.stateDigest = BoundedTimelineReducerProjection.digestTextValueForRecord(state)
        self.sourceEvent = sourceEvent
    }
}

public struct BoundedWorkAgentHandleIndexRecord: Codable, Hashable, Sendable {
    public let handle: HandleRef
    public let origin: WorkAgentHandleOrigin
    public let label: String
    public let deadline: Date?
    public let requestBody: TimelineBodyReference
    public let state: WorkAgentHandleState
    public let cancellationEvidence: WorkAgentHandleCancellationEvidence?
    public let terminalEvidence: WorkAgentHandleTerminalEvidence?
    public let reapReason: WorkAgentHandleReapReason?
    public let queuedEvent: EventRef
    public let startedEvent: EventRef?
    public let latestLifecycleEvent: EventRef
    public let reapedEvent: EventRef?
    public let providerAccounting: WorkAgentProviderAccounting

    public var cancellationCause: WorkAgentHandleCancellationCause? {
        cancellationEvidence?.cause
    }
    public var cancellationEvent: EventRef? { cancellationEvidence?.event.event }
    public var terminalOutcome: WorkAgentHandleTerminalOutcome? { terminalEvidence?.outcome }
    public var resultBody: TimelineBodyReference? { terminalEvidence?.resultBody }
    public var cleanup: WorkAgentHandleCleanupProof? { terminalEvidence?.cleanup }
    public var terminalEvent: EventRef? { terminalEvidence?.event.event }

    public var blocksWorkCompletion: Bool {
        state.isLive || cleanup?.state == .indeterminate
    }

    public init(_ snapshot: WorkAgentHandleSnapshot) {
        handle = snapshot.handle; origin = snapshot.origin; label = snapshot.label
        deadline = snapshot.deadline; requestBody = snapshot.requestBody; state = snapshot.state
        cancellationEvidence = snapshot.cancellationEvidence
        terminalEvidence = snapshot.terminalEvidence; reapReason = snapshot.reapReason
        queuedEvent = snapshot.queuedEvent; startedEvent = snapshot.startedEvent
        latestLifecycleEvent = snapshot.latestLifecycleEvent
        reapedEvent = snapshot.reapedEvent
        providerAccounting = snapshot.providerAccounting
    }

}

/// Append-time semantic check backed by the exact canonical Work snapshot returned alongside the
/// bounded head. The writer still owns physical sequencing and commits; this prevents drafting an
/// agent mutation that the canonical reducer would immediately quarantine. This intentionally
/// consumes the full-scan result: bounded historical-index limits must never become admission
/// limits, and cleanup evidence is authenticated through the snapshot's exact event map.
internal enum WorkAgentHandlePreflight {
    enum Error: Swift.Error, Equatable, Sendable { case invalidSnapshot; case rejected }

    static func applying(
        _ event: TimelineEvent, to snapshot: WorkSnapshot
    ) throws -> WorkAgentHandleSnapshot {
        let types: Set<String> = [
            TimelineEventType.agentHandleQueued, TimelineEventType.agentHandleStarted,
            TimelineEventType.agentHandleCancelRequested, TimelineEventType.agentHandleTerminal,
            TimelineEventType.agentHandleReaped,
            TimelineEventType.agentHandleProviderStarted, TimelineEventType.agentHandleProviderSettled,
        ]
        guard types.contains(event.type), snapshot.causalOrderValid,
              snapshot.structuralIntegrityValid, snapshot.semanticProjectionValid,
              snapshot.agentHandles.count <= WorkAgentHandleSnapshot.maximumRetainedPerWork,
              Set(snapshot.handles.keys).isDisjoint(with: Set(snapshot.agentHandles.keys)) else {
            throw Error.invalidSnapshot
        }
        var transition = InMemoryWorkTransitionState(snapshot: snapshot)
        WorkReducerTransition.apply(event, to: &transition)
        let after = transition.snapshot
        guard after.semanticProjectionValid, after.structuralIntegrityValid,
              let handleID = event.handle?.handleID,
              let result = after.agentHandles[handleID],
              result.latestLifecycleEvent.eventID == event.eventID
                || result.providerAccounting.latestEvent?.eventID == event.eventID else { throw Error.rejected }
        return result
    }
}

/// Stable, bounded classification of the states emitted by WorkReducer. Any state spelling
/// outside the four terminal values is intentionally treated as active; it is represented only
/// by its digest in ``BoundedWorkHandleIndexRecord``.
public enum BoundedHandleState: String, Codable, Hashable, Sendable {
    case active
    case succeeded
    case failed
    case canceled
    case completed
}

public struct BoundedWorkAttachmentIndexRecord: Codable, Hashable, Sendable {
    public let attachment: SessionAttachmentRef
    public let session: SessionRef
    public let capabilities: [String]
    public let isAttached: Bool
    public let sourceEvent: BoundedReducerProjectionEvent?

    public init(
        attachment: SessionAttachmentRef,
        session: SessionRef,
        capabilities: [String] = [],
        isAttached: Bool = true,
        sourceEvent: BoundedReducerProjectionEvent? = nil
    ) {
        self.attachment = attachment
        self.session = session
        self.capabilities = capabilities.sorted()
        self.isAttached = isAttached
        self.sourceEvent = sourceEvent
    }
}

public struct BoundedCommandIndexRecord: Codable, Hashable, Sendable {
    public let command: CommandRef
    public let state: CommandDeliveryState
    public let acceptanceActor: TimelineActor
    public let acceptanceHostSequence: Int
    public let acceptanceIdempotencyKey: BoundedReducerProjectionDigest?
    public let acceptanceEvent: BoundedReducerProjectionEvent?
    public let deliveryActor: TimelineActor?
    public let deliveryHostSequence: Int?
    public let deliveryIdempotencyKey: BoundedReducerProjectionDigest?
    public let deliveryEvent: BoundedReducerProjectionEvent?

    public init(
        command: CommandRef,
        state: CommandDeliveryState,
        acceptanceActor: TimelineActor,
        acceptanceHostSequence: Int,
        acceptanceIdempotencyKey: BoundedReducerProjectionDigest? = nil,
        acceptanceEvent: BoundedReducerProjectionEvent? = nil,
        deliveryActor: TimelineActor? = nil,
        deliveryHostSequence: Int? = nil,
        deliveryIdempotencyKey: BoundedReducerProjectionDigest? = nil,
        deliveryEvent: BoundedReducerProjectionEvent? = nil
    ) {
        self.command = command
        self.state = state
        self.acceptanceActor = acceptanceActor
        self.acceptanceHostSequence = acceptanceHostSequence
        self.acceptanceIdempotencyKey = acceptanceIdempotencyKey
        self.acceptanceEvent = acceptanceEvent
        self.deliveryActor = deliveryActor
        self.deliveryHostSequence = deliveryHostSequence
        self.deliveryIdempotencyKey = deliveryIdempotencyKey
        self.deliveryEvent = deliveryEvent
    }
}

public struct BoundedSessionAttachmentIndexRecord: Codable, Hashable, Sendable {
    public let attachment: SessionAttachmentRef
    public let work: WorkRef
    public let cursor: JournalCursor?
    public let capabilities: [String]
    public let isAttached: Bool
    public let sourceEvent: BoundedReducerProjectionEvent?

    public init(
        attachment: SessionAttachmentRef,
        work: WorkRef,
        cursor: JournalCursor? = nil,
        capabilities: [String] = [],
        isAttached: Bool = true,
        sourceEvent: BoundedReducerProjectionEvent? = nil
    ) {
        self.attachment = attachment
        self.work = work
        self.cursor = cursor
        self.capabilities = capabilities.sorted()
        self.isAttached = isAttached
        self.sourceEvent = sourceEvent
    }
}

public struct BoundedMessageIndexRecord: Codable, Hashable, Sendable {
    public let event: BoundedReducerProjectionEvent
    public let role: String
    public let text: BoundedReducerProjectionDigest
    public let conversationParent: EventRef?
    public let run: RunRef?
    public let turn: TurnRef?
    public let provenance: TimelineEventProvenance?
    public let visible: Bool

    public init(
        event: BoundedReducerProjectionEvent,
        role: String,
        text: BoundedReducerProjectionDigest,
        conversationParent: EventRef? = nil,
        run: RunRef? = nil,
        turn: TurnRef? = nil,
        provenance: TimelineEventProvenance? = nil,
        visible: Bool = true
    ) {
        self.event = event
        self.role = role
        self.text = text
        self.conversationParent = conversationParent
        self.run = run
        self.turn = turn
        self.provenance = provenance
        self.visible = visible
    }
}

public struct BoundedContextIndexRecord: Codable, Hashable, Sendable {
    public let componentID: String
    public let inclusionID: String
    public let sourceID: String
    public let sourceProvenance: EventRef?
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
        component: ContextComponent,
        maximumIdentifierBytes: Int = 512,
        maximumTextBytes: Int = 4_096
    ) {
        self.componentID = BoundedTimelineReducerProjection.bounded(
            component.componentID, maxBytes: maximumIdentifierBytes)
        self.inclusionID = BoundedTimelineReducerProjection.bounded(
            component.inclusionID, maxBytes: maximumIdentifierBytes)
        self.sourceID = BoundedTimelineReducerProjection.bounded(
            component.sourceID, maxBytes: maximumIdentifierBytes)
        self.sourceProvenance = component.source.provenance
        self.mode = component.mode
        self.deliveryMode = component.deliveryMode
        self.measuredBytes = component.measuredBytes
        self.includedBytes = component.includedBytes
        self.deliveredBytes = component.deliveredBytes
        self.fullByteCount = component.fullByteCount
        self.bodyReference = component.bodyReference
        self.digest = component.digest
        self.tokenCount = component.tokenCount
        self.tokenizer = component.tokenizer.map {
            BoundedTimelineReducerProjection.bounded($0, maxBytes: maximumTextBytes)
        }
        self.omitted = component.omitted
    }
}

/// Metadata-only form of a producer-side prompt source.  It intentionally omits every source
/// body; body references remain device-independent addresses for explicit inspection later.
public struct BoundedPromptSourceIndexRecord: Codable, Hashable, Sendable {
    public let sourceID: String
    public let inclusionID: String
    public let kind: PromptSourceKind
    public let status: PromptSourceStatus
    /// A fixed, non-secret display label.  The producer's arbitrary label is retained only as a
    /// digest below; skill/memory descriptions are not trusted presentation text.
    public let label: String
    public let labelDigest: BoundedReducerProjectionDigest?
    public let labelByteCount: Int
    public let fullByteCount: Int?
    public let fullDigest: String?
    public let deliveredByteCount: Int
    public let deliveredDigest: String
    public let deliveredByteOffsetInRendered: Int
    public let renderedByteCount: Int
    public let renderedDigest: String
    public let fullBodyReference: TimelineBodyReference?
    public let deliveredBodyReference: TimelineBodyReference?
    public let renderedBodyReference: TimelineBodyReference?
    public let provenance: EventRef?

    public init(
        source: ContextManifestSource,
        maximumIdentifierBytes: Int = 512,
        maximumTextBytes: Int = 4_096
    ) {
        self.sourceID = BoundedTimelineReducerProjection.bounded(
            source.sourceID, maxBytes: maximumIdentifierBytes)
        self.inclusionID = BoundedTimelineReducerProjection.bounded(
            source.inclusionID, maxBytes: maximumIdentifierBytes)
        self.kind = source.kind
        self.status = source.status
        self.label = "source:\(source.kind.rawValue)"
        self.labelDigest = BoundedTimelineReducerProjection.digestText(source.label)
        self.labelByteCount = source.label.utf8.count
        self.fullByteCount = source.fullByteCount
        self.fullDigest = source.fullDigest
        self.deliveredByteCount = source.deliveredByteCount
        self.deliveredDigest = source.deliveredDigest
        self.deliveredByteOffsetInRendered = source.deliveredByteOffsetInRendered
        self.renderedByteCount = source.renderedByteCount
        self.renderedDigest = source.renderedDigest
        self.fullBodyReference = source.fullBodyReference
        self.deliveredBodyReference = source.deliveredBodyReference
        self.renderedBodyReference = source.renderedBodyReference
        self.provenance = source.provenance
    }
}

public struct BoundedRecoveryPlaneStatus: Codable, Hashable, Sendable {
    public let plane: RecoveryPlane
    public let status: RecoveryCoverageStatus

    public init(plane: RecoveryPlane, status: RecoveryCoverageStatus) {
        self.plane = plane
        self.status = status
    }
}

public struct BoundedRecoveryIndexRecord: Codable, Hashable, Sendable {
    public let planes: [BoundedRecoveryPlaneStatus]
    public let operation: RecoveryOperation
    public let evidence: EventRef?
    public let evidenceCursor: JournalCursor?
    public let caveatCount: Int
    public let caveatDigest: String?
    public let sourceEvent: BoundedReducerProjectionEvent?
    public let run: RunRef?

    public init(
        coverage: RecoveryCoverage,
        sourceEvent: BoundedReducerProjectionEvent? = nil,
        run: RunRef? = nil
    ) {
        self.planes = RecoveryPlane.allCases.sorted { $0.rawValue < $1.rawValue }.map {
            BoundedRecoveryPlaneStatus(plane: $0, status: coverage.planes[$0] ?? .unknown)
        }
        self.operation = coverage.operation
        self.evidence = coverage.evidence
        self.evidenceCursor = coverage.evidenceCursor
        self.caveatCount = coverage.caveats.count
        self.caveatDigest = BoundedTimelineReducerProjection.digestTextArray(coverage.caveats)
        self.sourceEvent = sourceEvent
        self.run = run
    }
}

public struct BoundedUnknownIndexRecord: Codable, Hashable, Sendable {
    public let event: BoundedReducerProjectionEvent
    public let journalOffset: Int
    public let type: String
    public let affectedDomains: [TimelineDomain]
    public let payload: BoundedReducerProjectionDigest

    public init(
        event: BoundedReducerProjectionEvent,
        journalOffset: Int,
        type: String,
        affectedDomains: [TimelineDomain],
        payload: BoundedReducerProjectionDigest
    ) {
        self.event = event
        self.journalOffset = journalOffset
        self.type = type
        self.affectedDomains = affectedDomains.sorted { $0.rawValue < $1.rawValue }
        self.payload = payload
    }
}

public struct BoundedCorruptionIndexRecord: Codable, Hashable, Sendable {
    public let event: BoundedReducerProjectionEvent?
    public let reason: BoundedReducerProjectionDigest

    public init(
        event: BoundedReducerProjectionEvent?,
        reason: BoundedReducerProjectionDigest
    ) {
        self.event = event
        self.reason = reason
    }
}

public struct BoundedChildIndexRecord: Codable, Hashable, Sendable {
    public let childID: String
    public let state: BoundedChildState
    public let stateDigest: BoundedReducerProjectionDigest
    public let sourceEvent: BoundedReducerProjectionEvent?

    public init(
        childID: String,
        state: String,
        sourceEvent: BoundedReducerProjectionEvent? = nil
    ) {
        self.childID = childID
        self.state = BoundedTimelineReducerProjection.classifyChildState(state)
        self.stateDigest = BoundedTimelineReducerProjection.digestTextValueForRecord(state)
        self.sourceEvent = sourceEvent
    }
}

/// Metadata-only classification of child lifecycle state. Unknown producer values are retained
/// as ``unknown`` plus a digest, never as arbitrary durable text.
public enum BoundedChildState: String, Codable, Hashable, Sendable {
    case running
    case done
    case failed
    case canceled
    case unknown
}

public struct BoundedWorkReducerHead: Codable, Hashable, Sendable {
    public static let schemaVersion = 8
    public static let mediaType = "application/x-aviary-bounded-work-reducer-head"

    public let schemaVersion: Int
    public let source: BoundedReducerProjectionSource
    public let coverage: BoundedReducerProjectionCoverage
    public let work: WorkRef?
    public let workHost: WorkHostRef?
    public let lifecycle: WorkLifecycle
    public let lifecycleEvent: BoundedReducerProjectionEvent?
    public let execution: WorkExecution
    public let executionEvent: BoundedReducerProjectionEvent?
    public let currentRun: BoundedReducerProjectionRun?
    /// Exact owner envelope recorded by the canonical ``run.started`` marker. A client must
    /// use this pair for control authorization; it is not inferred from the Work's first
    /// attachment or from a launch template.
    public let activeRunSession: SessionRef?
    public let activeRunSessionAttachment: SessionAttachmentRef?
    public let currentTurn: BoundedReducerProjectionTurn?
    public let modelID: String?
    public let modelEvent: BoundedReducerProjectionEvent?
    public let activeActionIDs: [String]
    public let actions: [BoundedWorkActionIndexRecord]
    /// Exact fixed Work-lifetime accounting scalar. It remains authoritative when old action
    /// rows are omitted by bounded index coverage.
    public let providerUsage: ProviderUsageAggregate
    public let handles: [BoundedWorkHandleIndexRecord]
    /// Complete at the pilot's lifetime bound; this is never a sampled recent-history index.
    public let agentHandles: [BoundedWorkAgentHandleIndexRecord]
    public let liveAgentHandleCount: Int
    public let unreapedAgentHandleCount: Int
    public let retainedAgentHandleCount: Int
    public let attachments: [BoundedWorkAttachmentIndexRecord]
    public let commands: [BoundedCommandIndexRecord]
    public let children: [BoundedChildIndexRecord]
    public let recovery: [BoundedRecoveryIndexRecord]
    public let unknowns: [BoundedUnknownIndexRecord]
    public let corruption: [BoundedCorruptionIndexRecord]
    public let lastHostSequence: Int?
    public let lastEventID: String?
    public let lastSequence: Int
    public let causalOrderValid: Bool
    public let structuralIntegrityValid: Bool
    public let semanticProjectionValid: Bool

    public static func build<S: Sequence>(
        events: S,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws -> BoundedWorkReducerHead where S.Element == TimelineEvent {
        try BoundedTimelineReducerProjection.buildWork(
            events: events, source: source, limits: limits)
    }

    public func validate(
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws {
        try BoundedTimelineReducerProjection.validateWorkHead(self, limits: limits)
    }

    public func action(for actionID: String) throws -> BoundedWorkActionIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            actionID, index: .actions, rows: actions, coverage: coverage,
            id: { $0.action.actionID })
    }

    public func handle(for handleID: String) throws -> BoundedWorkHandleIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            handleID, index: .handles, rows: handles, coverage: coverage,
            id: { $0.handle.handleID })
    }

    public func agentHandle(for handleID: String) throws -> BoundedWorkAgentHandleIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            handleID, index: .agentHandles, rows: agentHandles, coverage: coverage,
            id: { $0.handle.handleID })
    }

    public func attachment(for attachmentID: String) throws -> BoundedWorkAttachmentIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            attachmentID, index: .attachments, rows: attachments, coverage: coverage,
            id: { $0.attachment.attachmentID })
    }

    public func command(for commandID: String) throws -> BoundedCommandIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            commandID, index: .commands, rows: commands, coverage: coverage,
            id: { $0.command.commandID })
    }

    public func child(for childID: String) throws -> BoundedChildIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            childID, index: .children, rows: children, coverage: coverage,
            id: { $0.childID })
    }

    public func encodedMetadata() throws -> Data {
        try BoundedTimelineReducerProjection.canonicalJSON(self)
    }

    public func opaqueReducerHead() throws -> DisposableTimelineProjectionStore.OpaqueReducerHead {
        try validate()
        return DisposableTimelineProjectionStore.OpaqueReducerHead(
            mediaType: Self.mediaType, schemaVersion: Self.schemaVersion,
            bytes: try encodedMetadata())
    }

    public static func decodeOpaqueReducerHead(
        _ opaque: DisposableTimelineProjectionStore.OpaqueReducerHead,
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws -> BoundedWorkReducerHead {
        guard opaque.mediaType == mediaType, opaque.schemaVersion == schemaVersion else {
            throw BoundedTimelineReducerProjectionError.schemaMismatch
        }
        let value = try JSONDecoder().decode(Self.self, from: opaque.bytes)
        try value.validate(limits: limits)
        return value
    }
}

public struct BoundedSessionReducerHead: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let mediaType = "application/x-aviary-bounded-session-reducer-head"

    public let schemaVersion: Int
    public let source: BoundedReducerProjectionSource
    public let coverage: BoundedReducerProjectionCoverage
    public let session: SessionRef?
    public let lifecycle: SessionLifecycle
    public let lifecycleEvent: BoundedReducerProjectionEvent?
    public let execution: WorkExecution
    public let attention: SessionAttention
    public let attentionEvent: BoundedReducerProjectionEvent?
    public let currentRun: BoundedReducerProjectionRun?
    public let currentTurn: BoundedReducerProjectionTurn?
    public let modelID: String?
    public let modelEvent: BoundedReducerProjectionEvent?
    public let attachments: [BoundedSessionAttachmentIndexRecord]
    public let messageHistory: [BoundedMessageIndexRecord]
    public let visibleMessages: [BoundedMessageIndexRecord]
    public let context: [BoundedContextIndexRecord]
    public let contextManifestID: String?
    public let contextRequestID: String?
    public let contextModelID: String?
    public let contextMeasuredBytes: Int?
    public let contextDeliveredBytes: Int?
    public let contextCumulativeDeliveredBytes: Int?
    public let contextOmissionCount: Int
    public let promptAssemblyID: String?
    public let promptSources: [BoundedPromptSourceIndexRecord]
    public let compaction: BoundedReducerProjectionDigest?
    public let compactionEvent: BoundedReducerProjectionEvent?
    public let childStates: [BoundedChildIndexRecord]
    public let recovery: [BoundedRecoveryIndexRecord]
    public let unknowns: [BoundedUnknownIndexRecord]
    public let corruption: [BoundedCorruptionIndexRecord]
    public let semanticTip: EventRef?
    public let lastEventID: String?
    public let lastSequence: Int
    public let causalOrderValid: Bool
    public let structuralIntegrityValid: Bool
    public let semanticProjectionValid: Bool

    public static func build<S: Sequence>(
        events: S,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws -> BoundedSessionReducerHead where S.Element == TimelineEvent {
        try BoundedTimelineReducerProjection.buildSession(
            events: events, source: source, limits: limits)
    }

    public func validate(
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws {
        try BoundedTimelineReducerProjection.validateSessionHead(self, limits: limits)
    }

    public func attachment(for attachmentID: String) throws -> BoundedSessionAttachmentIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            attachmentID, index: .attachments, rows: attachments, coverage: coverage,
            id: { $0.attachment.attachmentID })
    }

    public func message(for eventID: String) throws -> BoundedMessageIndexRecord {
        guard !eventID.isEmpty else {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
        if let row = visibleMessages.first(where: { $0.event.reference.eventID == eventID }) {
            return row
        }
        if let row = messageHistory.first(where: { $0.event.reference.eventID == eventID }) {
            return row
        }
        guard coverage.isIndexComplete(.messages) else {
            throw BoundedTimelineReducerProjectionError.indexIncomplete(.messages)
        }
        throw BoundedTimelineReducerProjectionError.indexNotFound(.messages)
    }

    public func contextComponent(for componentID: String) throws -> BoundedContextIndexRecord {
        try BoundedTimelineReducerProjection.lookup(
            componentID, index: .context, rows: context, coverage: coverage,
            id: { $0.componentID })
    }

    public func encodedMetadata() throws -> Data {
        try BoundedTimelineReducerProjection.canonicalJSON(self)
    }

    public func opaqueReducerHead() throws -> DisposableTimelineProjectionStore.OpaqueReducerHead {
        try validate()
        return DisposableTimelineProjectionStore.OpaqueReducerHead(
            mediaType: Self.mediaType, schemaVersion: Self.schemaVersion,
            bytes: try encodedMetadata())
    }

    public static func decodeOpaqueReducerHead(
        _ opaque: DisposableTimelineProjectionStore.OpaqueReducerHead,
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws -> BoundedSessionReducerHead {
        guard opaque.mediaType == mediaType, opaque.schemaVersion == schemaVersion else {
            throw BoundedTimelineReducerProjectionError.schemaMismatch
        }
        let value = try JSONDecoder().decode(Self.self, from: opaque.bytes)
        try value.validate(limits: limits)
        return value
    }
}

public struct BoundedTimelineReducerProjectionLimits: Codable, Hashable, Sendable {
    public static let `default` = BoundedTimelineReducerProjectionLimits()

    public let maximumHeadBytes: Int
    public let maximumIdentifierBytes: Int
    public let maximumTextBytes: Int
    public let maximumActions: Int
    public let maximumHandles: Int
    public let maximumAgentHandles: Int
    public let maximumCommands: Int
    public let maximumAttachments: Int
    public let maximumMessages: Int
    public let maximumContextComponents: Int
    public let maximumPromptSources: Int
    public let maximumRecoveryClaims: Int
    public let maximumUnknowns: Int
    public let maximumCorruptionRecords: Int
    public let maximumChildren: Int
    public let maximumDiagnostics: Int

    public init(
        maximumHeadBytes: Int = 1 * 1_024 * 1_024,
        maximumIdentifierBytes: Int = 512,
        maximumTextBytes: Int = 4_096,
        maximumActions: Int = 512,
        maximumHandles: Int = 512,
        maximumAgentHandles: Int = WorkAgentHandleSnapshot.maximumRetainedPerWork,
        maximumCommands: Int = 512,
        maximumAttachments: Int = 256,
        maximumMessages: Int = 1_024,
        maximumContextComponents: Int = 256,
        maximumPromptSources: Int = 256,
        maximumRecoveryClaims: Int = 256,
        maximumUnknowns: Int = 256,
        maximumCorruptionRecords: Int = 256,
        maximumChildren: Int = 256,
        maximumDiagnostics: Int = 128
    ) {
        self.maximumHeadBytes = Self.clamp(maximumHeadBytes, upper: 4 * 1_024 * 1_024)
        self.maximumIdentifierBytes = Self.clamp(maximumIdentifierBytes, upper: 4 * 1_024)
        self.maximumTextBytes = Self.clamp(maximumTextBytes, upper: 1 * 1_024 * 1_024)
        self.maximumActions = Self.clamp(maximumActions, upper: 16_384)
        self.maximumHandles = Self.clamp(maximumHandles, upper: 16_384)
        self.maximumAgentHandles = Self.clamp(
            maximumAgentHandles, upper: WorkAgentHandleSnapshot.maximumRetainedPerWork)
        self.maximumCommands = Self.clamp(maximumCommands, upper: 16_384)
        self.maximumAttachments = Self.clamp(maximumAttachments, upper: 16_384)
        self.maximumMessages = Self.clamp(maximumMessages, upper: 32_768)
        self.maximumContextComponents = Self.clamp(maximumContextComponents, upper: 16_384)
        self.maximumPromptSources = Self.clamp(maximumPromptSources, upper: 16_384)
        self.maximumRecoveryClaims = Self.clamp(maximumRecoveryClaims, upper: 16_384)
        self.maximumUnknowns = Self.clamp(maximumUnknowns, upper: 16_384)
        self.maximumCorruptionRecords = Self.clamp(maximumCorruptionRecords, upper: 16_384)
        self.maximumChildren = Self.clamp(maximumChildren, upper: 16_384)
        self.maximumDiagnostics = Self.clamp(maximumDiagnostics, upper: 4_096)
    }

    private static func clamp(_ value: Int, upper: Int) -> Int {
        max(1, min(value, upper))
    }
}

public enum BoundedTimelineReducerProjectionError: Error, LocalizedError, Equatable, Sendable {
    case schemaMismatch
    case sourceMismatch
    case invalidSource
    case invalidCursor
    case invalidIdentity
    case invalidDigest
    case invalidOffsets
    case duplicateIdentity
    case invalidOrdering
    case oversize
    case sourceIncomplete
    /// The requested row may have been evicted by the bounded index.  Callers must obtain a
    /// canonical read (or a future secondary index) before treating absence as fact.
    case indexIncomplete(BoundedReducerProjectionIndex)
    /// The index is complete and the requested identity is not present in the source prefix.
    case indexNotFound(BoundedReducerProjectionIndex)

    public var errorDescription: String? {
        switch self {
        case .schemaMismatch: return "Reducer projection schema is not supported."
        case .sourceMismatch: return "Reducer projection does not match its canonical source."
        case .invalidSource: return "Reducer projection source evidence is invalid."
        case .invalidCursor: return "Reducer projection cursor is invalid."
        case .invalidIdentity: return "Reducer projection identity is invalid."
        case .invalidDigest: return "Reducer projection digest is invalid."
        case .invalidOffsets: return "Reducer projection offset is invalid."
        case .duplicateIdentity: return "Reducer projection contains a duplicate identity."
        case .invalidOrdering: return "Reducer projection records are not in canonical order."
        case .oversize: return "Reducer projection exceeds its bounded encoding limit."
        case .sourceIncomplete: return "Reducer projection lacks complete canonical source evidence."
        case .indexIncomplete(let index):
            return "The bounded \(index.rawValue) index is incomplete; canonical lookup is required."
        case .indexNotFound(let index):
            return "The \(index.rawValue) identity is not present in the complete bounded index."
        }
    }
}

/// Namespace for construction/validation helpers.  Keeping these operations together avoids
/// duplicating the source and metadata contracts in Work and Session heads.
public enum BoundedTimelineReducerProjection {
    fileprivate static func lookup<Row>(
        _ identity: String,
        index: BoundedReducerProjectionIndex,
        rows: [Row],
        coverage: BoundedReducerProjectionCoverage,
        id: (Row) -> String
    ) throws -> Row {
        guard validIdentifier(identity) else {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
        if let row = rows.first(where: { id($0) == identity }) {
            return row
        }
        guard coverage.isIndexComplete(index) else {
            throw BoundedTimelineReducerProjectionError.indexIncomplete(index)
        }
        throw BoundedTimelineReducerProjectionError.indexNotFound(index)
    }

    public static func buildWork<S: Sequence>(
        events: S,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws -> BoundedWorkReducerHead where S.Element == TimelineEvent {
        var accumulator = BoundedWorkReducerAccumulator(limits: limits)
        for event in events { accumulator.append(event) }
        return try accumulator.finalize(source: source)
    }

    public static func buildSession<S: Sequence>(
        events: S,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws -> BoundedSessionReducerHead where S.Element == TimelineEvent {
        var accumulator = BoundedSessionReducerAccumulator(limits: limits)
        for event in events { accumulator.append(event) }
        return try accumulator.finalize(source: source)
    }

    fileprivate static func makeIndexCoverage(
        _ index: BoundedReducerProjectionIndex,
        total: Int,
        retained: Int,
        state intrinsicState: BoundedReducerProjectionState? = nil
    ) -> BoundedReducerProjectionIndexCoverage {
        let boundedTotal = Swift.max(0, total)
        let boundedRetained = Swift.min(boundedTotal, Swift.max(0, retained))
        let omitted = boundedTotal - boundedRetained
        let state: BoundedReducerProjectionState
        if intrinsicState == .requiresRebuild {
            state = .requiresRebuild
        } else if intrinsicState == .sourceIncomplete || omitted > 0 {
            state = .sourceIncomplete
        } else {
            state = .complete
        }
        return BoundedReducerProjectionIndexCoverage(
            index: index, state: state, totalCount: boundedTotal,
            retainedCount: boundedRetained, omittedCount: omitted)
    }

    fileprivate static func scalarState(
        snapshotCausalOrderValid: Bool,
        snapshotStructuralIntegrityValid: Bool,
        snapshotSemanticProjectionValid: Bool,
        corruptionCount: Int,
        unknownCount: Int,
        missingSourceEvidence: Int,
        activeItemsOmitted: Bool
    ) -> BoundedReducerProjectionState {
        if !snapshotCausalOrderValid || !snapshotStructuralIntegrityValid
            || !snapshotSemanticProjectionValid || corruptionCount > 0 {
            return .requiresRebuild
        }
        if unknownCount > 0 || missingSourceEvidence > 0 || activeItemsOmitted {
            return .sourceIncomplete
        }
        return .complete
    }

    fileprivate static func overallState(
        scalar: BoundedReducerProjectionState,
        indexes: [BoundedReducerProjectionIndexCoverage]
    ) -> BoundedReducerProjectionState {
        if scalar == .requiresRebuild || indexes.contains(where: { $0.state == .requiresRebuild }) {
            return .requiresRebuild
        }
        if scalar == .sourceIncomplete || indexes.contains(where: { $0.state != .complete }) {
            return .sourceIncomplete
        }
        return .complete
    }

    private static func latestSequence(_ events: [BoundedReducerProjectionEvent?]) -> Int {
        events.compactMap { $0?.sequence }.max() ?? -1
    }

    private static func actionIsUnsettled(_ state: ActionExecutionState) -> Bool {
        !state.isTerminal
    }

    private static func actionIsActive(_ state: ActionExecutionState) -> Bool {
        switch state {
        case .queued, .running, .cancelRequested:
            return true
        case .unknown, .proposed, .succeeded, .failed, .canceled, .indeterminateEffect:
            return false
        }
    }

    private static func validProviderEvidence(_ action: BoundedWorkActionIndexRecord) -> Bool {
        guard action.state != .unknown else { return false }
        switch action.kind {
        case .provider, .compactionProvider:
            guard let admission = action.providerAdmission,
                  (try? admission.validate(kind: action.kind)) != nil else { return false }
            if action.state.isTerminal {
                guard let settlement = action.providerSettlement else { return false }
                return (try? settlement.validate(
                    admission: admission, kind: action.kind, state: action.state)) != nil
            }
            return action.providerSettlement == nil
        default:
            return action.providerAdmission == nil && action.providerSettlement == nil
        }
    }

    fileprivate static func classifyHandleState(_ state: String) -> BoundedHandleState {
        switch state {
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "canceled": return .canceled
        case "completed": return .completed
        default: return .active
        }
    }

    fileprivate static func handleIsUnsettled(_ state: String) -> Bool {
        classifyHandleState(state) == .active
    }

    fileprivate static func handleIsUnsettled(_ state: BoundedHandleState) -> Bool {
        state == .active
    }

    private static func commandIsUnsettled(_ state: CommandDeliveryState) -> Bool {
        switch state {
        case .accepted, .indeterminate: return true
        case .rejected, .delivered, .notDelivered: return false
        }
    }

    fileprivate static func actionLess(
        _ lhs: BoundedWorkActionIndexRecord, _ rhs: BoundedWorkActionIndexRecord
    ) -> Bool {
        let lhsUnsettled = actionIsUnsettled(lhs.state)
        let rhsUnsettled = actionIsUnsettled(rhs.state)
        if lhsUnsettled != rhsUnsettled { return lhsUnsettled }
        let lhsSequence = latestSequence([lhs.intentEvent, lhs.startedEvent, lhs.outcomeEvent])
        let rhsSequence = latestSequence([rhs.intentEvent, rhs.startedEvent, rhs.outcomeEvent])
        if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
        return lhs.action.actionID < rhs.action.actionID
    }

    fileprivate static func handleLess(
        _ lhs: BoundedWorkHandleIndexRecord, _ rhs: BoundedWorkHandleIndexRecord
    ) -> Bool {
        let lhsUnsettled = handleIsUnsettled(lhs.state)
        let rhsUnsettled = handleIsUnsettled(rhs.state)
        if lhsUnsettled != rhsUnsettled { return lhsUnsettled }
        let lhsSequence = lhs.sourceEvent?.sequence ?? -1
        let rhsSequence = rhs.sourceEvent?.sequence ?? -1
        if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
        return lhs.handle.handleID < rhs.handle.handleID
    }

    fileprivate static func attachmentLess(
        _ lhs: BoundedWorkAttachmentIndexRecord, _ rhs: BoundedWorkAttachmentIndexRecord
    ) -> Bool {
        if lhs.isAttached != rhs.isAttached { return lhs.isAttached }
        let lhsSequence = lhs.sourceEvent?.sequence ?? -1
        let rhsSequence = rhs.sourceEvent?.sequence ?? -1
        if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
        return lhs.attachment.attachmentID < rhs.attachment.attachmentID
    }

    fileprivate static func commandLess(
        _ lhs: BoundedCommandIndexRecord, _ rhs: BoundedCommandIndexRecord
    ) -> Bool {
        let lhsUnsettled = commandIsUnsettled(lhs.state)
        let rhsUnsettled = commandIsUnsettled(rhs.state)
        if lhsUnsettled != rhsUnsettled { return lhsUnsettled }
        let lhsSequence = max(
            lhs.acceptanceHostSequence,
            lhs.deliveryHostSequence ?? lhs.acceptanceHostSequence)
        let rhsSequence = max(
            rhs.acceptanceHostSequence,
            rhs.deliveryHostSequence ?? rhs.acceptanceHostSequence)
        if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
        return lhs.command.commandID < rhs.command.commandID
    }

    fileprivate static func classifyChildState(_ state: String) -> BoundedChildState {
        switch state {
        case "running": return .running
        case "done": return .done
        case "failed": return .failed
        case "canceled": return .canceled
        default: return .unknown
        }
    }

    private static func childIsUnsettled(_ state: BoundedChildState) -> Bool {
        switch state {
        case .done, .failed, .canceled: return false
        case .running, .unknown: return true
        }
    }

    fileprivate static func childLess(
        _ lhs: BoundedChildIndexRecord, _ rhs: BoundedChildIndexRecord
    ) -> Bool {
        let lhsUnsettled = childIsUnsettled(lhs.state)
        let rhsUnsettled = childIsUnsettled(rhs.state)
        if lhsUnsettled != rhsUnsettled { return lhsUnsettled }
        return lhs.childID < rhs.childID
    }

    fileprivate static func messageLess(
        _ lhs: BoundedMessageIndexRecord, _ rhs: BoundedMessageIndexRecord
    ) -> Bool {
        let lhsSequence = lhs.event.sequence ?? Int.max
        let rhsSequence = rhs.event.sequence ?? Int.max
        if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
        return lhs.event.reference.eventID < rhs.event.reference.eventID
    }

    fileprivate static func sessionAttachmentLess(
        _ lhs: BoundedSessionAttachmentIndexRecord,
        _ rhs: BoundedSessionAttachmentIndexRecord
    ) -> Bool {
        if lhs.isAttached != rhs.isAttached { return lhs.isAttached }
        let lhsSequence = lhs.sourceEvent?.sequence ?? -1
        let rhsSequence = rhs.sourceEvent?.sequence ?? -1
        if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
        return lhs.attachment.attachmentID < rhs.attachment.attachmentID
    }

    private static func activeActionCount(_ snapshot: WorkSnapshot) -> Int {
        snapshot.actions.values.reduce(into: 0) { count, action in
            if actionIsUnsettled(action.state) { count += 1 }
        }
    }

    private static func activeHandleCount(_ snapshot: WorkSnapshot) -> Int {
        snapshot.handles.values.reduce(into: 0) { count, handle in
            if handleIsUnsettled(handle.state) { count += 1 }
        }
    }

    private static func activeAttachmentCount(_ snapshot: WorkSnapshot) -> Int {
        snapshot.sessionAttachments.values.reduce(into: 0) { count, attachment in
            if attachment.isAttached { count += 1 }
        }
    }

    private static func activeCommandCount(_ snapshot: WorkSnapshot) -> Int {
        snapshot.commands.values.reduce(into: 0) { count, command in
            if commandIsUnsettled(command.state) { count += 1 }
        }
    }

    private static func activeChildCount(_ snapshot: WorkSnapshot) -> Int {
        snapshot.childStates.values.reduce(into: 0) { count, state in
            if childIsUnsettled(classifyChildState(state)) { count += 1 }
        }
    }

    private static func activeWorkItemCount(_ snapshot: WorkSnapshot) -> Int {
        activeActionCount(snapshot) + activeHandleCount(snapshot)
            + snapshot.agentHandles.values.filter(\.blocksWorkCompletion).count
            + activeAttachmentCount(snapshot) + activeCommandCount(snapshot)
            + activeChildCount(snapshot)
    }

    private static func activeWorkRowCount(
        actions: [BoundedWorkActionIndexRecord],
        handles: [BoundedWorkHandleIndexRecord],
        agentHandles: [BoundedWorkAgentHandleIndexRecord],
        attachments: [BoundedWorkAttachmentIndexRecord],
        commands: [BoundedCommandIndexRecord],
        children: [BoundedChildIndexRecord]
    ) -> Int {
        actions.reduce(into: 0) { if actionIsUnsettled($1.state) { $0 += 1 } }
            + handles.reduce(into: 0) { if handleIsUnsettled($1.state) { $0 += 1 } }
            + agentHandles.reduce(into: 0) { if $1.blocksWorkCompletion { $0 += 1 } }
            + attachments.reduce(into: 0) { if $1.isAttached { $0 += 1 } }
            + commands.reduce(into: 0) { if commandIsUnsettled($1.state) { $0 += 1 } }
            + children.reduce(into: 0) { if childIsUnsettled($1.state) { $0 += 1 } }
    }

    private static func missingWorkSourceEvidence(
        snapshot: WorkSnapshot,
        actions: [BoundedWorkActionIndexRecord],
        handles: [BoundedWorkHandleIndexRecord],
        agentHandles: [BoundedWorkAgentHandleIndexRecord],
        attachments: [BoundedWorkAttachmentIndexRecord],
        commands: [BoundedCommandIndexRecord],
        children: [BoundedChildIndexRecord],
        recovery: [BoundedRecoveryIndexRecord],
        corruption: [BoundedCorruptionIndexRecord],
        trace: Trace
    ) -> Int {
        var count = trace.missingSourceEvidence
        if snapshot.lifecycle != .unknown && trace.lifecycle == nil { count += 1 }
        if snapshot.execution != .idle && trace.execution == nil { count += 1 }
        if snapshot.activeRun != nil && trace.currentRun == nil { count += 1 }
        if snapshot.activeTurn != nil && trace.currentTurn == nil { count += 1 }
        if snapshot.modelID != nil && trace.model == nil && trace.currentRun == nil { count += 1 }
        count += actions.filter {
            $0.intentEvent == nil && $0.startedEvent == nil && $0.outcomeEvent == nil
        }.count
        count += handles.filter { $0.sourceEvent == nil }.count
        count += agentHandles.filter { $0.latestLifecycleEvent.eventID.isEmpty }.count
        count += attachments.filter { $0.sourceEvent == nil }.count
        count += commands.filter {
            $0.acceptanceEvent == nil && $0.deliveryEvent == nil
        }.count
        count += children.filter { $0.sourceEvent == nil }.count
        count += recovery.filter { $0.sourceEvent == nil }.count
        count += corruption.filter { $0.event == nil }.count
        // Unknowns are always event-addressable; a missing event can only arise from a malformed
        // synthetic adaptation and is handled by validation rather than silently promoted.
        return count
    }

    private static func missingSessionSourceEvidence(
        snapshot: SessionSnapshot,
        attachments: [BoundedSessionAttachmentIndexRecord],
        history: [BoundedMessageIndexRecord],
        visible: [BoundedMessageIndexRecord],
        context: [BoundedContextIndexRecord],
        promptSources: [BoundedPromptSourceIndexRecord],
        children: [BoundedChildIndexRecord],
        recovery: [BoundedRecoveryIndexRecord],
        corruption: [BoundedCorruptionIndexRecord],
        trace: Trace
    ) -> Int {
        var count = trace.missingSourceEvidence
        if snapshot.lifecycle != .unknown && trace.lifecycle == nil { count += 1 }
        if snapshot.activeRun != nil && trace.currentRun == nil { count += 1 }
        if snapshot.activeTurn != nil && trace.currentTurn == nil { count += 1 }
        if snapshot.modelID != nil && trace.model == nil { count += 1 }
        if snapshot.attention != .none && trace.attention == nil { count += 1 }
        count += attachments.filter { $0.sourceEvent == nil }.count
        count += history.filter { $0.event.reference.eventID.isEmpty }.count
        count += visible.filter { $0.event.reference.eventID.isEmpty }.count
        count += context.filter { $0.sourceProvenance == nil }.count
        count += promptSources.filter { $0.provenance == nil }.count
        count += children.filter { $0.sourceEvent == nil }.count
        count += recovery.filter { $0.sourceEvent == nil }.count
        count += corruption.filter { $0.event == nil }.count
        return count
    }

    fileprivate static func makeWorkHead(
        snapshot: WorkSnapshot,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits,
        trace: Trace
    ) throws -> BoundedWorkReducerHead {
        let actionRows = snapshot.actions.values.compactMap { action -> BoundedWorkActionIndexRecord? in
            let id = action.action.actionID
            return BoundedWorkActionIndexRecord(
                action: action.action, kind: action.kind, state: action.state,
                failureKind: action.failureKind, retrySafety: action.retrySafety,
                intent: digestText(action.intent), target: digestText(action.target),
                scope: digestText(action.scope), metadata: digestJSON(action.metadata),
                metadataWasTruncated: action.metadataWasTruncated,
                providerAdmission: action.providerAdmission,
                providerSettlement: action.providerSettlement,
                intentEvent: trace.actionEvents[id]?.intent ?? projectionEvent(action.intentEvent),
                startedEvent: trace.actionEvents[id]?.started ?? projectionEvent(action.startedEvent),
                outcomeEvent: trace.actionEvents[id]?.outcome ?? projectionEvent(action.outcomeEvent))
        }.sorted(by: actionLess)
        let retainedActionRows = Array(actionRows.prefix(limits.maximumActions))
        let handleRows = snapshot.handles.values.map { value in
            BoundedWorkHandleIndexRecord(
                handle: value.handle, state: bounded(value.state, maxBytes: limits.maximumTextBytes),
                sourceEvent: trace.handleEvents[value.handle.handleID])
        }.sorted(by: handleLess)
        let retainedHandleRows = Array(handleRows.prefix(limits.maximumHandles))
        let agentHandleRows = snapshot.agentHandles.values.map(
            BoundedWorkAgentHandleIndexRecord.init
        ).sorted {
            if $0.blocksWorkCompletion != $1.blocksWorkCompletion {
                return $0.blocksWorkCompletion
            }
            return $0.handle.handleID < $1.handle.handleID
        }
        let retainedAgentHandleRows = Array(agentHandleRows.prefix(limits.maximumAgentHandles))
        let attachmentRows = snapshot.sessionAttachments.values.map { value in
            BoundedWorkAttachmentIndexRecord(
                attachment: value.attachment, session: value.session,
                capabilities: value.capabilities.filter {
                    validIdentifier($0, maxBytes: limits.maximumIdentifierBytes)
                }.sorted(),
                isAttached: value.isAttached,
                sourceEvent: trace.attachmentEvents[value.attachment.attachmentID])
        }.sorted(by: attachmentLess)
        let retainedAttachmentRows = Array(attachmentRows.prefix(limits.maximumAttachments))
        let commandRows = snapshot.commands.values.map { value in
            let id = value.command.commandID
            return BoundedCommandIndexRecord(
                command: value.command, state: value.state,
                acceptanceActor: value.acceptanceActor,
                acceptanceHostSequence: value.acceptanceHostSequence,
                acceptanceIdempotencyKey: digestText(value.acceptanceIdempotencyKey),
                acceptanceEvent: trace.commandEvents[id]?.acceptance ?? projectionEvent(value.acceptanceEventRef),
                deliveryActor: value.deliveryActor,
                deliveryHostSequence: value.deliveryHostSequence,
                deliveryIdempotencyKey: digestText(value.deliveryIdempotencyKey),
                deliveryEvent: trace.commandEvents[id]?.delivery ?? projectionEvent(value.deliveryEventRef))
        }.sorted(by: commandLess)
        let retainedCommandRows = Array(commandRows.prefix(limits.maximumCommands))
        let childRows = makeChildRows(
            snapshot.childStates, sourceEvents: trace.childEvents, max: limits.maximumChildren)
        let childCount = snapshot.childStates.count
        let recoveryRows = makeRecoveryRows(
            coverage: snapshot.recovery,
            recorded: snapshot.recordedRecovery,
            sourceEvents: trace.recoveryEvents,
            max: limits.maximumRecoveryClaims)
        let unknownRows = makeUnknownRows(snapshot.unknownEvents, max: limits.maximumUnknowns)
        let corruptionRows = makeCorruptionRows(
            reasons: snapshot.corruptionReasons,
            events: snapshot.quarantinedEvents,
            max: limits.maximumCorruptionRecords)
        let recoveryTotal = Swift.max(snapshot.recovery.count, snapshot.recordedRecovery.count)
        let corruptionTotal = Swift.max(snapshot.corruptionReasons.count, snapshot.quarantinedEvents.count)
        var omissions: [BoundedReducerProjectionOmission] = []
        appendOmission(&omissions, .actions, snapshot.actions.count, retainedActionRows.count)
        appendOmission(&omissions, .handles, snapshot.handles.count, retainedHandleRows.count)
        appendOmission(&omissions, .agentHandles, snapshot.agentHandles.count,
                       retainedAgentHandleRows.count)
        appendOmission(&omissions, .attachments, snapshot.sessionAttachments.count, retainedAttachmentRows.count)
        appendOmission(&omissions, .commands, snapshot.commands.count, retainedCommandRows.count)
        appendOmission(&omissions, .children, childCount, childRows.count)
        appendOmission(&omissions, .recovery, recoveryTotal, recoveryRows.count)
        appendOmission(&omissions, .unknowns, snapshot.unknownEvents.count, unknownRows.count)
        appendOmission(&omissions, .corruption, corruptionTotal, corruptionRows.count)
        let missingSourceEvidence = missingWorkSourceEvidence(
            snapshot: snapshot, actions: retainedActionRows, handles: retainedHandleRows,
            agentHandles: retainedAgentHandleRows,
            attachments: retainedAttachmentRows, commands: retainedCommandRows, children: childRows,
            recovery: recoveryRows, corruption: corruptionRows, trace: trace)
        let activeItemCount = Swift.max(
            activeWorkItemCount(snapshot), snapshot.activeActionIDs.count)
        let retainedActiveItemCount = activeWorkRowCount(
            actions: retainedActionRows, handles: retainedHandleRows,
            agentHandles: retainedAgentHandleRows,
            attachments: retainedAttachmentRows, commands: retainedCommandRows, children: childRows)
        let activeItemsOmitted = retainedActiveItemCount < activeItemCount
        let indexCoverage = [
            makeIndexCoverage(.actions, total: snapshot.actions.count, retained: retainedActionRows.count,
                              state: trace.overflowedIndexes.contains(.actions)
                                  || actionRows.contains(where: {
                                      $0.intentEvent == nil && $0.startedEvent == nil && $0.outcomeEvent == nil
                                  }) ? .sourceIncomplete : nil),
            makeIndexCoverage(.handles, total: snapshot.handles.count, retained: retainedHandleRows.count,
                              state: trace.overflowedIndexes.contains(.handles)
                                  || handleRows.contains(where: { $0.sourceEvent == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.agentHandles, total: snapshot.agentHandles.count,
                              retained: retainedAgentHandleRows.count,
                              state: snapshot.agentHandles.count
                                  <= WorkAgentHandleSnapshot.maximumRetainedPerWork ? nil : .requiresRebuild),
            makeIndexCoverage(.attachments, total: snapshot.sessionAttachments.count,
                              retained: retainedAttachmentRows.count,
                              state: trace.overflowedIndexes.contains(.attachments)
                                  || attachmentRows.contains(where: { $0.sourceEvent == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.commands, total: snapshot.commands.count, retained: retainedCommandRows.count,
                              state: trace.overflowedIndexes.contains(.commands)
                                  || commandRows.contains(where: {
                                      $0.acceptanceEvent == nil && $0.deliveryEvent == nil
                                  }) ? .sourceIncomplete : nil),
            makeIndexCoverage(.children, total: childCount, retained: childRows.count,
                              state: trace.overflowedIndexes.contains(.children)
                                  || childRows.contains(where: { $0.sourceEvent == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.recovery, total: recoveryTotal, retained: recoveryRows.count,
                              state: trace.overflowedIndexes.contains(.recovery)
                                  || recoveryRows.contains(where: { $0.sourceEvent == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.unknowns, total: snapshot.unknownEvents.count, retained: unknownRows.count,
                              state: snapshot.unknownEvents.isEmpty ? nil : .sourceIncomplete),
            makeIndexCoverage(.corruption, total: corruptionTotal, retained: corruptionRows.count,
                              state: corruptionTotal == 0 ? nil : .requiresRebuild)
        ]
        let scalar = scalarState(
            snapshotCausalOrderValid: snapshot.causalOrderValid,
            snapshotStructuralIntegrityValid: snapshot.structuralIntegrityValid,
            snapshotSemanticProjectionValid: snapshot.semanticProjectionValid,
            corruptionCount: corruptionTotal,
            unknownCount: snapshot.unknownEvents.count + trace.unknownCount,
            missingSourceEvidence: missingSourceEvidence,
            activeItemsOmitted: activeItemsOmitted)
        let state = overallState(scalar: scalar, indexes: indexCoverage)
        let coverage = BoundedReducerProjectionCoverage(
            state: state, scalarState: scalar, indexCoverage: indexCoverage, omissions: omissions,
            unknownEventCount: snapshot.unknownEvents.count,
            corruptionCount: corruptionTotal,
            missingSourceEvidenceCount: missingSourceEvidence,
            activeItemsOmitted: activeItemsOmitted,
            activeItemCount: activeItemCount,
            retainedActiveItemCount: retainedActiveItemCount,
            diagnostics: makeDiagnostics(snapshot: snapshot, max: limits.maximumDiagnostics))
        let currentRun = snapshot.activeRun.map {
            BoundedReducerProjectionRun(run: $0, sourceEvent: trace.currentRun)
        }
        let currentTurn = snapshot.activeTurn.map {
            BoundedReducerProjectionTurn(turn: $0, sourceEvent: trace.currentTurn)
        }
        let head = BoundedWorkReducerHead(
            projectionMarker: (),
            schemaVersion: BoundedWorkReducerHead.schemaVersion,
            source: source, coverage: coverage, work: snapshot.work, workHost: snapshot.workHost,
            lifecycle: snapshot.lifecycle, lifecycleEvent: trace.lifecycle,
            execution: snapshot.execution, executionEvent: trace.execution,
            currentRun: currentRun, activeRunSession: snapshot.activeRunSession,
            activeRunSessionAttachment: snapshot.activeRunSessionAttachment,
            currentTurn: currentTurn, modelID: boundedOptional(
                snapshot.modelID, maxBytes: limits.maximumIdentifierBytes), modelEvent: trace.model,
            activeActionIDs: Array(snapshot.activeActionIDs.sorted().prefix(limits.maximumActions)).map {
                bounded($0, maxBytes: limits.maximumIdentifierBytes)
            }, actions: retainedActionRows,
            providerUsage: snapshot.providerUsage,
            handles: retainedHandleRows, agentHandles: retainedAgentHandleRows,
            liveAgentHandleCount: snapshot.agentHandles.values.filter(\.blocksWorkCompletion).count,
            unreapedAgentHandleCount: snapshot.agentHandles.values.filter { $0.state != .reaped }.count,
            retainedAgentHandleCount: snapshot.agentHandles.count,
            attachments: retainedAttachmentRows, commands: retainedCommandRows,
            children: childRows, recovery: recoveryRows, unknowns: unknownRows,
            corruption: corruptionRows, lastHostSequence: snapshot.lastHostSequence,
            lastEventID: snapshot.lastEventID, lastSequence: snapshot.lastSequence,
            causalOrderValid: snapshot.causalOrderValid,
            structuralIntegrityValid: snapshot.structuralIntegrityValid,
            semanticProjectionValid: snapshot.semanticProjectionValid)
        try enforceHeadSize(head, limits: limits)
        return head
    }

    fileprivate static func makeSessionHead(
        snapshot: SessionSnapshot,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits,
        trace: Trace
    ) throws -> BoundedSessionReducerHead {
        let attachmentRows = snapshot.attachments.values.map { value in
            BoundedSessionAttachmentIndexRecord(
                attachment: value.attachment, work: value.work, cursor: value.cursor,
                capabilities: value.capabilities.filter {
                    validIdentifier($0, maxBytes: limits.maximumIdentifierBytes)
                }.sorted(),
                isAttached: value.isAttached,
                sourceEvent: trace.attachmentEvents[value.attachment.attachmentID])
        }.sorted(by: sessionAttachmentLess)
        let retainedAttachmentRows = Array(attachmentRows.prefix(limits.maximumAttachments))
        let historyRows = makeMessageRows(
            snapshot.messageHistory, trace: trace, max: limits.maximumMessages)
        let visibleRows = makeMessageRows(
            snapshot.messages, trace: trace, max: limits.maximumMessages)
        let sourceLessMessageCount = snapshot.messageHistory.filter { $0.sourceEvent == nil }.count
            + snapshot.messages.filter { $0.sourceEvent == nil }.count
        let contextRows = snapshot.contextComponents.map {
            BoundedContextIndexRecord(
                component: $0, maximumIdentifierBytes: limits.maximumIdentifierBytes,
                maximumTextBytes: limits.maximumTextBytes)
        }.sorted { lhs, rhs in
            (lhs.inclusionID, lhs.componentID) < (rhs.inclusionID, rhs.componentID)
        }
        let retainedContextRows = Array(contextRows.prefix(limits.maximumContextComponents))
        let promptRows = (snapshot.contextPromptSources ?? []).map {
            BoundedPromptSourceIndexRecord(
                source: $0, maximumIdentifierBytes: limits.maximumIdentifierBytes,
                maximumTextBytes: limits.maximumTextBytes)
        }.sorted { lhs, rhs in
            (lhs.inclusionID, lhs.sourceID) < (rhs.inclusionID, rhs.sourceID)
        }
        let retainedPromptRows = Array(promptRows.prefix(limits.maximumPromptSources))
        let childRows = makeChildRows(
            snapshot.childStates, sourceEvents: trace.childEvents, max: limits.maximumChildren)
        let recoveryRows = makeRecoveryRows(
            coverage: snapshot.recovery,
            recorded: snapshot.recordedRecovery,
            sourceEvents: trace.recoveryEvents,
            max: limits.maximumRecoveryClaims)
        let unknownRows = makeUnknownRows(snapshot.unknownEvents, max: limits.maximumUnknowns)
        let corruptionRows = makeCorruptionRows(
            reasons: snapshot.corruptionReasons,
            events: snapshot.quarantinedEvents,
            max: limits.maximumCorruptionRecords)
        let recoveryTotal = Swift.max(snapshot.recovery.count, snapshot.recordedRecovery.count)
        let corruptionTotal = Swift.max(snapshot.corruptionReasons.count, snapshot.quarantinedEvents.count)
        let messageTotal = snapshot.messageHistory.count + snapshot.messages.count
        let retainedMessageCount = historyRows.count + visibleRows.count
        var omissions: [BoundedReducerProjectionOmission] = []
        appendOmission(&omissions, .attachments, snapshot.attachments.count, retainedAttachmentRows.count)
        appendOmission(&omissions, .messages, messageTotal, retainedMessageCount)
        appendOmission(&omissions, .context, snapshot.contextComponents.count, retainedContextRows.count)
        appendOmission(&omissions, .context, (snapshot.contextPromptSources ?? []).count, retainedPromptRows.count)
        appendOmission(&omissions, .children, snapshot.childStates.count, childRows.count)
        appendOmission(&omissions, .recovery, recoveryTotal, recoveryRows.count)
        appendOmission(&omissions, .unknowns, snapshot.unknownEvents.count, unknownRows.count)
        appendOmission(&omissions, .corruption, corruptionTotal, corruptionRows.count)
        let missingSourceEvidence = missingSessionSourceEvidence(
            snapshot: snapshot, attachments: attachmentRows, history: historyRows,
            visible: visibleRows, context: contextRows, promptSources: promptRows,
            children: makeChildRows(snapshot.childStates, sourceEvents: trace.childEvents,
                                    max: snapshot.childStates.count + 1),
            recovery: recoveryRows, corruption: corruptionRows, trace: trace)
            + sourceLessMessageCount
        let activeItemCount = snapshot.attachments.values.filter { $0.isAttached }.count
            + snapshot.childStates.values.filter { childIsUnsettled(classifyChildState($0)) }.count
        let retainedActiveItemCount = retainedAttachmentRows.reduce(into: 0) {
            if $1.isAttached { $0 += 1 }
        } + childRows.reduce(into: 0) {
            if childIsUnsettled($1.state) { $0 += 1 }
        }
        let activeItemsOmitted = retainedActiveItemCount < activeItemCount
        let context = snapshot.contextManifest
        let compaction = snapshot.compactionSummary.flatMap { digestText($0) }
        let indexCoverage = [
            makeIndexCoverage(.attachments, total: snapshot.attachments.count,
                              retained: retainedAttachmentRows.count,
                              state: trace.overflowedIndexes.contains(.attachments)
                                  || attachmentRows.contains(where: { $0.sourceEvent == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.messages, total: messageTotal, retained: retainedMessageCount,
                              state: trace.overflowedIndexes.contains(.messages)
                                  || retainedMessageCount < messageTotal ? .sourceIncomplete : nil),
            makeIndexCoverage(.context, total: snapshot.contextComponents.count
                              + (snapshot.contextPromptSources ?? []).count,
                              retained: retainedContextRows.count + retainedPromptRows.count,
                              state: contextRows.contains(where: { $0.sourceProvenance == nil })
                                  || promptRows.contains(where: { $0.provenance == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.children, total: snapshot.childStates.count, retained: childRows.count,
                              state: trace.overflowedIndexes.contains(.children)
                                  || childRows.contains(where: { $0.sourceEvent == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.recovery, total: recoveryTotal, retained: recoveryRows.count,
                              state: trace.overflowedIndexes.contains(.recovery)
                                  || recoveryRows.contains(where: { $0.sourceEvent == nil })
                                  ? .sourceIncomplete : nil),
            makeIndexCoverage(.unknowns, total: snapshot.unknownEvents.count, retained: unknownRows.count,
                              state: snapshot.unknownEvents.isEmpty ? nil : .sourceIncomplete),
            makeIndexCoverage(.corruption, total: corruptionTotal, retained: corruptionRows.count,
                              state: corruptionTotal == 0 ? nil : .requiresRebuild)
        ]
        let scalar = scalarState(
            snapshotCausalOrderValid: snapshot.causalOrderValid,
            snapshotStructuralIntegrityValid: snapshot.structuralIntegrityValid,
            snapshotSemanticProjectionValid: snapshot.semanticProjectionValid,
            corruptionCount: corruptionTotal,
            unknownCount: snapshot.unknownEvents.count + trace.unknownCount,
            missingSourceEvidence: missingSourceEvidence,
            activeItemsOmitted: activeItemsOmitted)
        let state = overallState(scalar: scalar, indexes: indexCoverage)
        let coverage = BoundedReducerProjectionCoverage(
            state: state, scalarState: scalar, indexCoverage: indexCoverage, omissions: omissions,
            unknownEventCount: snapshot.unknownEvents.count,
            corruptionCount: corruptionTotal,
            missingSourceEvidenceCount: missingSourceEvidence,
            activeItemsOmitted: activeItemsOmitted,
            activeItemCount: activeItemCount,
            retainedActiveItemCount: retainedActiveItemCount,
            diagnostics: makeDiagnostics(snapshot: snapshot, max: limits.maximumDiagnostics))
        let currentRun = snapshot.activeRun.map {
            BoundedReducerProjectionRun(run: $0, sourceEvent: trace.currentRun)
        }
        let currentTurn = snapshot.activeTurn.map {
            BoundedReducerProjectionTurn(turn: $0, sourceEvent: trace.currentTurn)
        }
        let head = BoundedSessionReducerHead(
            projectionMarker: (),
            schemaVersion: BoundedSessionReducerHead.schemaVersion,
            source: source, coverage: coverage, session: snapshot.session,
            lifecycle: snapshot.lifecycle, lifecycleEvent: trace.lifecycle,
            execution: snapshot.execution, attention: snapshot.attention,
            attentionEvent: trace.attention ?? projectionEvent(snapshot.attentionEvent),
            currentRun: currentRun, currentTurn: currentTurn,
            modelID: boundedOptional(snapshot.modelID, maxBytes: limits.maximumIdentifierBytes),
            modelEvent: trace.model, attachments: retainedAttachmentRows,
            messageHistory: historyRows, visibleMessages: visibleRows, context: retainedContextRows,
            contextManifestID: boundedOptional(context?.manifestID,
                                               maxBytes: limits.maximumIdentifierBytes),
            contextRequestID: boundedOptional(context?.requestID,
                                              maxBytes: limits.maximumIdentifierBytes),
            contextModelID: boundedOptional(context?.modelID,
                                             maxBytes: limits.maximumIdentifierBytes),
            contextMeasuredBytes: context?.measuredBytes,
            contextDeliveredBytes: context?.deliveredBytes,
            contextCumulativeDeliveredBytes: context?.cumulativeDeliveredBytes,
            contextOmissionCount: context?.omissions.count ?? 0,
            promptAssemblyID: boundedOptional(snapshot.contextPromptAssemblyID,
                                              maxBytes: limits.maximumIdentifierBytes),
            promptSources: retainedPromptRows, compaction: compaction,
            compactionEvent: trace.compaction,
            childStates: childRows,
            recovery: recoveryRows, unknowns: unknownRows, corruption: corruptionRows,
            semanticTip: snapshot.semanticTip, lastEventID: snapshot.lastEventID,
            lastSequence: snapshot.lastSequence, causalOrderValid: snapshot.causalOrderValid,
            structuralIntegrityValid: snapshot.structuralIntegrityValid,
            semanticProjectionValid: snapshot.semanticProjectionValid)
        try enforceHeadSize(head, limits: limits)
        return head
    }

    fileprivate struct Trace: Sendable {
        var lifecycle: BoundedReducerProjectionEvent?
        var execution: BoundedReducerProjectionEvent?
        var currentRun: BoundedReducerProjectionEvent?
        var currentTurn: BoundedReducerProjectionEvent?
        var model: BoundedReducerProjectionEvent?
        var attention: BoundedReducerProjectionEvent?
        var compaction: BoundedReducerProjectionEvent?
        var actionEvents: [String: ActionEvents] = [:]
        /// Provenance slots are bounded independently from reducer state. Keep active identities
        /// ahead of resolved history so a long journal cannot evict evidence for live work.
        var activeActionIDs: Set<String> = []
        var handleEvents: [String: BoundedReducerProjectionEvent] = [:]
        var activeHandleIDs: Set<String> = []
        var attachmentEvents: [String: BoundedReducerProjectionEvent] = [:]
        var activeAttachmentIDs: Set<String> = []
        var commandEvents: [String: CommandEvents] = [:]
        var activeCommandIDs: Set<String> = []
        var messageEvents: [String: BoundedReducerProjectionEvent] = [:]
        var childEvents: [String: BoundedReducerProjectionEvent] = [:]
        var activeChildIDs: Set<String> = []
        var recoveryEvents: [String: BoundedReducerProjectionEvent] = [:]
        var unknownCount = 0
        var missingSourceEvidence = 0
        var overflow = false
        var overflowedIndexes: Set<BoundedReducerProjectionIndex> = []

        fileprivate init() {}

        mutating func observe(
            _ event: TimelineEvent,
            limits: BoundedTimelineReducerProjectionLimits,
            active: TraceActivity = .empty
        ) {
            let source = projectionEvent(event)
            switch event.type {
            case TimelineEventType.compaction:
                compaction = source
            case TimelineEventType.actionIntent:
                guard let id = event.action?.actionID else { return }
                updateAction(id, limits: limits, isActive: active.actions.contains(id)) {
                    $0.intent = source
                }
            case TimelineEventType.actionStarted:
                guard let id = event.action?.actionID else { return }
                updateAction(id, limits: limits, isActive: active.actions.contains(id)) {
                    $0.started = source
                }
            case TimelineEventType.actionOutcome:
                guard let id = event.action?.actionID else { return }
                updateAction(id, limits: limits, isActive: active.actions.contains(id)) {
                    $0.outcome = source
                }
            case TimelineEventType.handleStarted, TimelineEventType.handleOutcome:
                guard let id = event.handle?.handleID else { return }
                if !Self.setBoundedPrioritized(
                    &handleEvents, activeKeys: &activeHandleIDs, key: id, value: source,
                    isActive: active.handles.contains(id), max: limits.maximumHandles) {
                    overflow = true
                    overflowedIndexes.insert(.handles)
                }
            case TimelineEventType.sessionAttached, TimelineEventType.sessionDetached,
                 TimelineEventType.sessionAttachmentCapabilityChanged,
                 TimelineEventType.sessionAttachmentCursorAdvanced:
                guard let id = event.sessionAttachment?.attachmentID else { return }
                if !Self.setBoundedPrioritized(
                    &attachmentEvents, activeKeys: &activeAttachmentIDs, key: id, value: source,
                    isActive: active.attachments.contains(id), max: limits.maximumAttachments) {
                    overflow = true
                    overflowedIndexes.insert(.attachments)
                }
            case TimelineEventType.commandAccepted, TimelineEventType.commandRejected:
                guard let id = event.command?.commandID else { return }
                updateCommand(id, limits: limits, isActive: active.commands.contains(id)) {
                    $0.acceptance = source
                }
            case TimelineEventType.commandDelivered, TimelineEventType.commandNotDelivered,
                 TimelineEventType.commandDeliveryIndeterminate:
                guard let id = event.command?.commandID else { return }
                updateCommand(id, limits: limits, isActive: active.commands.contains(id)) {
                    $0.delivery = source
                }
            case TimelineEventType.inputAccepted, TimelineEventType.messageCommitted:
                if !Self.setBounded(&messageEvents, key: event.eventID, value: source, max: limits.maximumMessages) {
                    overflow = true
                    overflowedIndexes.insert(.messages)
                }
            case TimelineEventType.recoveryCoverage:
                if !Self.setBounded(&recoveryEvents, key: event.eventID, value: source, max: limits.maximumRecoveryClaims) {
                    overflow = true
                    overflowedIndexes.insert(.recovery)
                }
            case TimelineEventType.childLifecycle:
                guard let childID = event.payload["child_id"]?.stringValue else { return }
                if !Self.setBoundedPrioritized(
                    &childEvents, activeKeys: &activeChildIDs, key: childID, value: source,
                    isActive: active.children.contains(childID), max: limits.maximumChildren) {
                    overflow = true
                    overflowedIndexes.insert(.children)
                }
            default:
                break
            }
        }

        private mutating func updateAction(
            _ key: String,
            limits: BoundedTimelineReducerProjectionLimits,
            isActive: Bool,
            _ body: (inout ActionEvents) -> Void
        ) {
            var value = actionEvents[key] ?? ActionEvents()
            body(&value)
            if !Self.setBoundedPrioritized(
                &actionEvents, activeKeys: &activeActionIDs, key: key, value: value,
                isActive: isActive, max: limits.maximumActions) {
                overflow = true
                overflowedIndexes.insert(.actions)
            }
        }

        private mutating func updateCommand(
            _ key: String,
            limits: BoundedTimelineReducerProjectionLimits,
            isActive: Bool,
            _ body: (inout CommandEvents) -> Void
        ) {
            var value = commandEvents[key] ?? CommandEvents()
            body(&value)
            if !Self.setBoundedPrioritized(
                &commandEvents, activeKeys: &activeCommandIDs, key: key, value: value,
                isActive: isActive, max: limits.maximumCommands) {
                overflow = true
                overflowedIndexes.insert(.commands)
            }
        }

        private static func setBounded<K: Hashable, V>(
            _ dictionary: inout [K: V], key: K, value: V, max: Int
        ) -> Bool {
            if dictionary[key] == nil && dictionary.count >= max {
                return false
            }
            dictionary[key] = value
            return true
        }

        private static func setBoundedPrioritized<K: Hashable, V>(
            _ dictionary: inout [K: V],
            activeKeys: inout Set<K>,
            key: K,
            value: V,
            isActive: Bool,
            max: Int
        ) -> Bool {
            if dictionary[key] != nil {
                dictionary[key] = value
                if isActive {
                    activeKeys.insert(key)
                } else {
                    activeKeys.remove(key)
                }
                return true
            }
            guard max > 0 else { return false }
            if dictionary.count >= max {
                guard isActive,
                      let evicted = dictionary.keys.first(where: { !activeKeys.contains($0) }) else {
                    return false
                }
                dictionary.removeValue(forKey: evicted)
                activeKeys.remove(evicted)
            }
            dictionary[key] = value
            if isActive { activeKeys.insert(key) }
            return true
        }
    }

    fileprivate struct TraceActivity: Sendable {
        static let empty = TraceActivity()

        var actions: Set<String> = []
        var handles: Set<String> = []
        var attachments: Set<String> = []
        var commands: Set<String> = []
        var children: Set<String> = []
    }

    fileprivate static func consumeWorkEvent(
        _ event: TimelineEvent,
        reducer: inout WorkReducer,
        trace: inout Trace,
        limits: BoundedTimelineReducerProjectionLimits
    ) {
        let beforeSeen = reducer.snapshot.seenEventIDs.contains(event.eventID)
        let beforeUnknown = reducer.snapshot.unknownEvents.count
        let beforeCorruption = reducer.snapshot.quarantinedEvents.count
        let beforeLifecycle = reducer.snapshot.lifecycle
        let beforeExecution = reducer.snapshot.execution
        let beforeRun = reducer.snapshot.activeRun
        let beforeTurn = reducer.snapshot.activeTurn
        let beforeModel = reducer.snapshot.modelID
        reducer.apply(event)
        let after = reducer.snapshot
        let accepted = !beforeSeen && after.seenEventIDs.contains(event.eventID)
        let quarantined = after.quarantinedEvents.count > beforeCorruption
        if accepted && !quarantined {
            let active = TraceActivity(
                actions: after.activeActionIDs,
                handles: Set(after.handles.values.filter {
                    handleIsUnsettled($0.state)
                }.map { $0.handle.handleID }),
                attachments: Set(after.sessionAttachments.values.filter(\.isAttached)
                    .map { $0.attachment.attachmentID }),
                commands: Set(after.commands.values.filter {
                    commandIsUnsettled($0.state)
                }.map { $0.command.commandID }),
                children: Set(after.childStates.compactMap {
                    childIsUnsettled(classifyChildState($0.value)) ? $0.key : nil
                }))
            trace.observe(event, limits: limits, active: active)
            let source = projectionEvent(event)
            if after.lifecycle != beforeLifecycle { trace.lifecycle = source }
            if after.execution != beforeExecution { trace.execution = source }
            if after.activeRun != beforeRun { trace.currentRun = source }
            if after.activeTurn != beforeTurn { trace.currentTurn = source }
            if after.modelID != beforeModel { trace.model = source }
        }
        if after.unknownEvents.count > beforeUnknown {
            trace.unknownCount += after.unknownEvents.count - beforeUnknown
        }
    }

    fileprivate static func consumeSessionEvent(
        _ event: TimelineEvent,
        reducer: inout SessionReducer,
        trace: inout Trace,
        limits: BoundedTimelineReducerProjectionLimits
    ) {
        let beforeSeen = reducer.snapshot.seenEventIDs.contains(event.eventID)
        let beforeUnknown = reducer.snapshot.unknownEvents.count
        let beforeCorruption = reducer.snapshot.quarantinedEvents.count
        let beforeLifecycle = reducer.snapshot.lifecycle
        let beforeRun = reducer.snapshot.activeRun
        let beforeTurn = reducer.snapshot.activeTurn
        let beforeModel = reducer.snapshot.modelID
        let beforeAttention = reducer.snapshot.attention
        reducer.apply(event)
        let after = reducer.snapshot
        let accepted = !beforeSeen && after.seenEventIDs.contains(event.eventID)
        let quarantined = after.quarantinedEvents.count > beforeCorruption
        if accepted && !quarantined {
            let active = TraceActivity(
                attachments: Set(after.attachments.values.filter(\.isAttached)
                    .map { $0.attachment.attachmentID }),
                children: Set(after.childStates.compactMap {
                    childIsUnsettled(classifyChildState($0.value)) ? $0.key : nil
                }))
            trace.observe(event, limits: limits, active: active)
            let source = projectionEvent(event)
            if after.lifecycle != beforeLifecycle { trace.lifecycle = source }
            if after.activeRun != beforeRun { trace.currentRun = source }
            if after.activeTurn != beforeTurn { trace.currentTurn = source }
            if after.modelID != beforeModel { trace.model = source }
            if after.attention != beforeAttention { trace.attention = source }
        }
        if after.unknownEvents.count > beforeUnknown {
            trace.unknownCount += after.unknownEvents.count - beforeUnknown
        }
    }

    fileprivate struct ActionEvents: Sendable {
        var intent: BoundedReducerProjectionEvent?
        var started: BoundedReducerProjectionEvent?
        var outcome: BoundedReducerProjectionEvent?
    }

    fileprivate struct CommandEvents: Sendable {
        var acceptance: BoundedReducerProjectionEvent?
        var delivery: BoundedReducerProjectionEvent?
    }

    fileprivate static func validateWorkHead(
        _ head: BoundedWorkReducerHead,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard head.schemaVersion == BoundedWorkReducerHead.schemaVersion else {
            throw BoundedTimelineReducerProjectionError.schemaMismatch
        }
        try validateSource(head.source, limits: limits)
        guard head.lastSequence >= 0,
              head.lastSequence == head.source.cursor.sequence,
              head.lastEventID == head.source.cursor.eventID else {
            throw BoundedTimelineReducerProjectionError.invalidCursor
        }
        try validateProjectionRows(head, limits: limits)
        try validateEvents(head.source, head.lifecycleEvent, limits: limits)
        try validateEvents(head.source, head.executionEvent, limits: limits)
        try validateEvents(head.source, head.currentRun?.sourceEvent, limits: limits)
        try validateEvents(head.source, head.currentTurn?.sourceEvent, limits: limits)
        try validateEvents(head.source, head.modelEvent, limits: limits)
        try validateRows(head.source, head.actions.flatMap(actionEvent), limits: limits)
        try validateRows(head.source, head.handles.compactMap(\.sourceEvent), limits: limits)
        try validateRows(head.source, head.attachments.compactMap(\.sourceEvent), limits: limits)
        try validateRows(head.source, head.commands.flatMap { [$0.acceptanceEvent, $0.deliveryEvent].compactMap { $0 } }, limits: limits)
        try validateRows(head.source, head.children.compactMap(\.sourceEvent), limits: limits)
        try validateRows(head.source, head.recovery.compactMap { $0.sourceEvent }, limits: limits)
        try validateRows(head.source, head.unknowns.map(\.event), limits: limits)
        try validateRows(head.source, head.corruption.compactMap(\.event), limits: limits)
        try validateRows(head.source, head.coverage.diagnostics.compactMap(\.sourceEvent), limits: limits)
        try validateUnique(head.actions.map { $0.action.actionID })
        guard head.actions.allSatisfy({ validProviderEvidence($0) }) else {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
        do { try head.providerUsage.validate() }
        catch { throw BoundedTimelineReducerProjectionError.invalidOffsets }
        guard head.providerUsage.started <= head.lastSequence,
              head.providerUsage.settled <= head.providerUsage.started else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        try validateUnique(head.handles.map { $0.handle.handleID })
        try validateUnique(head.agentHandles.map { $0.handle.handleID })
        guard Set(head.handles.map { $0.handle.handleID }).isDisjoint(
            with: Set(head.agentHandles.map { $0.handle.handleID })) else {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
        try validateUnique(head.attachments.map { $0.attachment.attachmentID })
        try validateUnique(head.commands.map { $0.command.commandID })
        try validateUnique(head.children.map(\.childID))
        guard head.actions == head.actions.sorted(by: actionLess),
              head.handles == head.handles.sorted(by: handleLess),
              head.agentHandles == head.agentHandles.sorted(by: {
                  if $0.blocksWorkCompletion != $1.blocksWorkCompletion {
                      return $0.blocksWorkCompletion
                  }
                  return $0.handle.handleID < $1.handle.handleID
              }),
              head.attachments == head.attachments.sorted(by: attachmentLess),
              head.commands == head.commands.sorted(by: commandLess),
              head.children == head.children.sorted(by: childLess) else {
            throw BoundedTimelineReducerProjectionError.invalidOrdering
        }
        try validateCoverage(head.coverage, limits: limits)
        let workRequiredIndexes: Set<BoundedReducerProjectionIndex> = [
            .actions, .handles, .agentHandles, .commands, .attachments, .children,
            .recovery, .unknowns, .corruption
        ]
        var workSourceIncompleteIndexes: Set<BoundedReducerProjectionIndex> = []
        if head.actions.contains(where: {
            $0.intentEvent == nil && $0.startedEvent == nil && $0.outcomeEvent == nil
        }) { workSourceIncompleteIndexes.insert(.actions) }
        if head.handles.contains(where: { $0.sourceEvent == nil }) {
            workSourceIncompleteIndexes.insert(.handles)
        }
        if head.attachments.contains(where: { $0.sourceEvent == nil }) {
            workSourceIncompleteIndexes.insert(.attachments)
        }
        if head.commands.contains(where: {
            $0.acceptanceEvent == nil && $0.deliveryEvent == nil
        }) { workSourceIncompleteIndexes.insert(.commands) }
        if head.children.contains(where: { $0.sourceEvent == nil }) {
            workSourceIncompleteIndexes.insert(.children)
        }
        if head.recovery.contains(where: { $0.sourceEvent == nil }) {
            workSourceIncompleteIndexes.insert(.recovery)
        }
        try validateDerivedCoverage(
            head.coverage, requiredIndexes: workRequiredIndexes,
            retainedCounts: [
                .actions: head.actions.count, .handles: head.handles.count,
                .agentHandles: head.agentHandles.count,
                .commands: head.commands.count, .attachments: head.attachments.count,
                .children: head.children.count, .recovery: head.recovery.count,
                .unknowns: head.unknowns.count, .corruption: head.corruption.count
            ],
            maximums: [
                .actions: limits.maximumActions, .handles: limits.maximumHandles,
                .agentHandles: limits.maximumAgentHandles,
                .commands: limits.maximumCommands, .attachments: limits.maximumAttachments,
                .children: limits.maximumChildren, .recovery: limits.maximumRecoveryClaims,
                .unknowns: limits.maximumUnknowns, .corruption: limits.maximumCorruptionRecords
            ], sourceIncompleteIndexes: workSourceIncompleteIndexes,
            unknownTotal: head.coverage.unknownEventCount,
            corruptionTotal: head.coverage.corruptionCount,
            scalarInputs: (
                causal: head.causalOrderValid,
                structural: head.structuralIntegrityValid,
                semantic: head.semanticProjectionValid))
        let retainedActiveItemCount = activeWorkRowCount(
            actions: head.actions, handles: head.handles, agentHandles: head.agentHandles,
            attachments: head.attachments, commands: head.commands, children: head.children)
        guard head.coverage.retainedActiveItemCount == retainedActiveItemCount,
              head.coverage.activeItemCount >= retainedActiveItemCount else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        let allWorkIndexesComplete = workRequiredIndexes.allSatisfy {
            head.coverage.isIndexComplete($0)
        }
        if allWorkIndexesComplete && head.coverage.activeItemCount != retainedActiveItemCount {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        if head.coverage.isIndexComplete(.actions) {
            let activeIDs = Set(head.actions.filter { actionIsActive($0.state) }
                .map { $0.action.actionID })
            guard activeIDs == Set(head.activeActionIDs),
                  head.providerUsage.started - head.providerUsage.settled
                    <= activeIDs.count else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
            var providerSteps: [CompleteProviderUsageProjectionStep] = []
            for action in head.actions
            where action.kind == .provider || action.kind == .compactionProvider {
                guard let intentSequence = action.intentEvent?.sequence,
                      intentSequence > 0 else {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
                if action.state == .proposed {
                    guard action.startedEvent == nil, action.outcomeEvent == nil else {
                        throw BoundedTimelineReducerProjectionError.invalidOffsets
                    }
                    continue
                }
                guard let startedSequence = action.startedEvent?.sequence,
                      startedSequence > 0 else {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
                if intentSequence >= startedSequence {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
                providerSteps.append(.started(
                    sequence: startedSequence, actionID: action.action.actionID))
                if action.state.isTerminal {
                    guard let settlement = action.providerSettlement,
                          let outcomeSequence = action.outcomeEvent?.sequence,
                          startedSequence < outcomeSequence else {
                        throw BoundedTimelineReducerProjectionError.invalidOffsets
                    }
                    providerSteps.append(.settled(
                        sequence: outcomeSequence, actionID: action.action.actionID,
                        settlement: settlement))
                }
            }
            guard (try? rebuildCompleteProviderUsage(from: providerSteps)) == head.providerUsage else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
        }
        let agentCoverage = head.coverage.coverage(for: .agentHandles)
        guard head.retainedAgentHandleCount == agentCoverage?.totalCount,
              head.retainedAgentHandleCount <= WorkAgentHandleSnapshot.maximumRetainedPerWork,
              head.liveAgentHandleCount >= head.agentHandles.filter(\.blocksWorkCompletion).count,
              head.unreapedAgentHandleCount >= head.agentHandles.filter({ $0.state != .reaped }).count,
              head.liveAgentHandleCount <= head.unreapedAgentHandleCount else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        if head.coverage.isIndexComplete(.agentHandles) {
            guard head.retainedAgentHandleCount == head.agentHandles.count,
                  head.liveAgentHandleCount == head.agentHandles.filter(\.blocksWorkCompletion).count,
                  head.unreapedAgentHandleCount == head.agentHandles.filter({ $0.state != .reaped }).count else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
        }
        try enforceHeadSize(head, limits: limits)
    }

    fileprivate static func validateSessionHead(
        _ head: BoundedSessionReducerHead,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard head.schemaVersion == BoundedSessionReducerHead.schemaVersion else {
            throw BoundedTimelineReducerProjectionError.schemaMismatch
        }
        try validateSource(head.source, limits: limits)
        guard head.lastSequence >= 0,
              head.lastSequence == head.source.cursor.sequence,
              head.lastEventID == head.source.cursor.eventID else {
            throw BoundedTimelineReducerProjectionError.invalidCursor
        }
        try validateProjectionRows(head, limits: limits)
        try validateEvents(head.source, head.lifecycleEvent, limits: limits)
        try validateEvents(head.source, head.attentionEvent, limits: limits)
        try validateEvents(head.source, head.currentRun?.sourceEvent, limits: limits)
        try validateEvents(head.source, head.currentTurn?.sourceEvent, limits: limits)
        try validateEvents(head.source, head.modelEvent, limits: limits)
        try validateEvents(head.source, head.compactionEvent, limits: limits)
        try validateRows(head.source, head.attachments.compactMap(\.sourceEvent), limits: limits)
        try validateRows(head.source, head.childStates.compactMap(\.sourceEvent), limits: limits)
        try validateRows(head.source, head.messageHistory.map(\.event), limits: limits)
        try validateRows(head.source, head.visibleMessages.map(\.event), limits: limits)
        try validateRows(head.source, head.recovery.compactMap { $0.sourceEvent }, limits: limits)
        try validateRows(head.source, head.unknowns.map(\.event), limits: limits)
        try validateRows(head.source, head.corruption.compactMap(\.event), limits: limits)
        try validateRows(head.source, head.coverage.diagnostics.compactMap(\.sourceEvent), limits: limits)
        try validateUnique(head.attachments.map { $0.attachment.attachmentID })
        try validateUnique(head.messageHistory.map { $0.event.reference.eventID })
        try validateUnique(head.visibleMessages.map { $0.event.reference.eventID })
        guard head.attachments == head.attachments.sorted(by: sessionAttachmentLess),
              head.messageHistory == head.messageHistory.sorted(by: messageLess),
              head.visibleMessages == head.visibleMessages.sorted(by: messageLess),
              head.context == head.context.sorted(by: {
                  ($0.inclusionID, $0.componentID) < ($1.inclusionID, $1.componentID)
              }),
              head.promptSources == head.promptSources.sorted(by: {
                  ($0.inclusionID, $0.sourceID) < ($1.inclusionID, $1.sourceID)
              }),
              head.childStates == head.childStates.sorted(by: childLess) else {
            throw BoundedTimelineReducerProjectionError.invalidOrdering
        }
        try validateUnique(head.context.map { $0.inclusionID })
        try validateUnique(head.promptSources.map { $0.inclusionID })
        try validateUniquePairs(head.context.map { ($0.inclusionID, $0.componentID) })
        try validateUniquePairs(head.promptSources.map { ($0.inclusionID, $0.sourceID) })
        try validateCoverage(head.coverage, limits: limits)
        let sessionRequiredIndexes: Set<BoundedReducerProjectionIndex> = [
            .attachments, .messages, .context, .children, .recovery, .unknowns, .corruption
        ]
        var sessionSourceIncompleteIndexes: Set<BoundedReducerProjectionIndex> = []
        if head.attachments.contains(where: { $0.sourceEvent == nil }) {
            sessionSourceIncompleteIndexes.insert(.attachments)
        }
        if head.context.contains(where: { $0.sourceProvenance == nil })
            || head.promptSources.contains(where: { $0.provenance == nil }) {
            sessionSourceIncompleteIndexes.insert(.context)
        }
        if head.childStates.contains(where: { $0.sourceEvent == nil }) {
            sessionSourceIncompleteIndexes.insert(.children)
        }
        if head.recovery.contains(where: { $0.sourceEvent == nil }) {
            sessionSourceIncompleteIndexes.insert(.recovery)
        }
        try validateDerivedCoverage(
            head.coverage, requiredIndexes: sessionRequiredIndexes,
            retainedCounts: [
                .attachments: head.attachments.count,
                .messages: head.messageHistory.count + head.visibleMessages.count,
                .context: head.context.count + head.promptSources.count,
                .children: head.childStates.count, .recovery: head.recovery.count,
                .unknowns: head.unknowns.count, .corruption: head.corruption.count
            ],
            maximums: [
                .attachments: limits.maximumAttachments,
                .messages: limits.maximumMessages * 2,
                .context: limits.maximumContextComponents + limits.maximumPromptSources,
                .children: limits.maximumChildren, .recovery: limits.maximumRecoveryClaims,
                .unknowns: limits.maximumUnknowns, .corruption: limits.maximumCorruptionRecords
            ], sourceIncompleteIndexes: sessionSourceIncompleteIndexes,
            unknownTotal: head.coverage.unknownEventCount,
            corruptionTotal: head.coverage.corruptionCount,
            scalarInputs: (
                causal: head.causalOrderValid,
                structural: head.structuralIntegrityValid,
                semantic: head.semanticProjectionValid))
        let retainedActiveItemCount = head.attachments.reduce(into: 0) {
            if $1.isAttached { $0 += 1 }
        } + head.childStates.reduce(into: 0) {
            if childIsUnsettled($1.state) { $0 += 1 }
        }
        guard head.coverage.retainedActiveItemCount == retainedActiveItemCount,
              head.coverage.activeItemCount >= retainedActiveItemCount else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        let allSessionIndexesComplete = sessionRequiredIndexes.allSatisfy {
            head.coverage.isIndexComplete($0)
        }
        if allSessionIndexesComplete && head.coverage.activeItemCount != retainedActiveItemCount {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        try enforceHeadSize(head, limits: limits)
    }

    private static func validateCoverage(
        _ coverage: BoundedReducerProjectionCoverage,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard coverage.unknownEventCount >= 0, coverage.corruptionCount >= 0,
              coverage.missingSourceEvidenceCount >= 0,
              coverage.activeItemCount >= 0,
              coverage.retainedActiveItemCount >= 0,
              coverage.retainedActiveItemCount <= coverage.activeItemCount,
              coverage.activeItemsOmitted ==
                (coverage.retainedActiveItemCount < coverage.activeItemCount),
              coverage.omissions.count <= 2 * BoundedReducerProjectionIndex.allCases.count,
              coverage.diagnostics.count <= limits.maximumDiagnostics else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        try validateSortedUnique(coverage.indexCoverage.map { $0.index.rawValue })
        for index in coverage.indexCoverage {
            guard index.totalCount >= 0, index.retainedCount >= 0,
                  index.retainedCount <= index.totalCount,
                  index.omittedCount == index.totalCount - index.retainedCount else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
            guard index.totalCount <= Int.max / 4 else {
                throw BoundedTimelineReducerProjectionError.oversize
            }
        }
        try validateSortedUnique(coverage.omissions.map { $0.index.rawValue })
        for omission in coverage.omissions {
            guard omission.omittedCount > 0 else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
        }
        for diagnostic in coverage.diagnostics {
            guard validIdentifier(diagnostic.code), validDigest(diagnostic.reasonDigest) else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        }
    }

    private static func validateDerivedCoverage(
        _ coverage: BoundedReducerProjectionCoverage,
        requiredIndexes: Set<BoundedReducerProjectionIndex>,
        retainedCounts: [BoundedReducerProjectionIndex: Int],
        maximums: [BoundedReducerProjectionIndex: Int],
        sourceIncompleteIndexes: Set<BoundedReducerProjectionIndex>,
        unknownTotal: Int,
        corruptionTotal: Int,
        scalarInputs: (
            causal: Bool,
            structural: Bool,
            semantic: Bool
        )
    ) throws {
        let actualIndexes = Set(coverage.indexCoverage.map(\.index))
        guard actualIndexes == requiredIndexes else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        guard coverage.unknownEventCount == unknownTotal,
              coverage.corruptionCount == corruptionTotal else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }

        var omissionCounts: [BoundedReducerProjectionIndex: Int] = [:]
        for omission in coverage.omissions {
            guard omission.omittedCount > 0 else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
            omissionCounts[omission.index] = omission.omittedCount
        }

        var incompleteFromRows = sourceIncompleteIndexes
        for index in requiredIndexes {
            guard let record = coverage.coverage(for: index),
                  let retained = retainedCounts[index],
                  let maximum = maximums[index],
                  record.retainedCount == retained,
                  record.retainedCount <= maximum else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
            let expectedOmitted = record.totalCount - record.retainedCount
            guard expectedOmitted == record.omittedCount,
                  record.totalCount >= retained,
                  omissionCounts[index, default: 0] == expectedOmitted else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
            if record.omittedCount > 0 { incompleteFromRows.insert(index) }
            let expectedState: BoundedReducerProjectionState
            if index == .corruption && corruptionTotal > 0 {
                expectedState = .requiresRebuild
            } else if index == .unknowns && unknownTotal > 0 {
                expectedState = .sourceIncomplete
            } else if incompleteFromRows.contains(index) {
                expectedState = .sourceIncomplete
            } else {
                expectedState = .complete
            }
            guard record.state == expectedState else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
        }
        let expectedOmissionIndexes = Set(requiredIndexes.filter {
            (coverage.coverage(for: $0)?.omittedCount ?? 0) > 0
        })
        guard Set(omissionCounts.keys) == expectedOmissionIndexes else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }

        let expectedScalar: BoundedReducerProjectionState
        if !scalarInputs.causal || !scalarInputs.structural || !scalarInputs.semantic
            || corruptionTotal > 0 {
            expectedScalar = .requiresRebuild
        } else if unknownTotal > 0 || coverage.missingSourceEvidenceCount > 0
                    || coverage.activeItemsOmitted {
            expectedScalar = .sourceIncomplete
        } else {
            expectedScalar = .complete
        }
        guard coverage.scalarState == expectedScalar else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        let expectedOverall = overallState(scalar: expectedScalar, indexes: coverage.indexCoverage)
        guard coverage.state == expectedOverall else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
    }

    private static func validateIdentifierValue(
        _ value: String,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard validIdentifier(value, maxBytes: limits.maximumIdentifierBytes) else {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
    }

    private static func validateDigestValue(
        _ value: BoundedReducerProjectionDigest,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard value.byteCount >= 0, value.byteCount <= Int.max / 4,
              validDigest(value.digest) else {
            throw BoundedTimelineReducerProjectionError.invalidDigest
        }
    }

    private static func validateOptionalDigest(
        _ value: BoundedReducerProjectionDigest?,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        if let value { try validateDigestValue(value, limits: limits) }
    }

    private static func validateJournal(
        _ journal: JournalRef,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        try validateIdentifierValue(journal.journalID, limits: limits)
        try validateIdentifierValue(journal.authority.authorityID, limits: limits)
        switch journal.owner {
        case .work(let work):
            try validateIdentifierValue(work.workID, limits: limits)
            try validateIdentifierValue(work.workHostID, limits: limits)
            guard journal.authority.authorityID == work.workHostID else {
                throw BoundedTimelineReducerProjectionError.invalidSource
            }
        case .session(let session):
            try validateIdentifierValue(session.sessionID, limits: limits)
        case .workHost(let workHost):
            try validateIdentifierValue(workHost.workHostID, limits: limits)
            guard journal.authority.authorityID == workHost.workHostID else {
                throw BoundedTimelineReducerProjectionError.invalidSource
            }
        }
    }

    private static func validateCursor(
        _ cursor: JournalCursor,
        limits: BoundedTimelineReducerProjectionLimits = .default
    ) throws {
        try validateJournal(cursor.journal, limits: limits)
        guard
              cursor.sequence >= 0, cursor.sequence < Int.max,
              cursor.sequence == 0
                ? cursor.eventID == nil
                : cursor.eventID.map({ validIdentifier($0, maxBytes: limits.maximumIdentifierBytes) }) == true else {
            throw BoundedTimelineReducerProjectionError.invalidCursor
        }
    }

    private static func validateReference(
        _ reference: EventRef,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard reference.journal == source.journal,
              validIdentifier(reference.eventID, maxBytes: limits.maximumIdentifierBytes) else {
            throw BoundedTimelineReducerProjectionError.invalidSource
        }
    }

    private static func validateBodyReference(
        _ reference: TimelineBodyReference?,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard let reference else { return }
        try validateJournal(reference.authority, limits: limits)
        guard reference.authority == source.journal,
              validIdentifier(reference.referenceID, maxBytes: limits.maximumIdentifierBytes),
              reference.mediaType.map({ validIdentifier($0, maxBytes: limits.maximumTextBytes) }) ?? true,
              reference.byteCount.map({ $0 >= 0 && $0 <= Int.max / 4 }) ?? false,
              reference.digest.map(validDigest) ?? false else {
            throw BoundedTimelineReducerProjectionError.invalidDigest
        }
        if let byteCount = reference.byteCount, let digest = reference.digest {
            guard reference.referenceID == digest else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
            _ = byteCount
        }
    }

    private static func validateProjectionEvent(
        _ event: BoundedReducerProjectionEvent?,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard let event else { return }
        try validateReference(event.reference, source: source, limits: limits)
        if let sequence = event.sequence {
            guard sequence >= 0, sequence <= source.cursor.sequence else {
                throw BoundedTimelineReducerProjectionError.invalidCursor
            }
        }
        if let type = event.type {
            try validateIdentifierValue(type, limits: limits)
        }
        if let digest = event.canonicalDigest, !validDigest(digest) {
            throw BoundedTimelineReducerProjectionError.invalidDigest
        }
    }

    private static func validateActor(
        _ actor: TimelineActor,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        try validateIdentifierValue(actor.actorID, limits: limits)
        try validateIdentifierValue(actor.kind, limits: limits)
    }

    private static func validateAgentHandleEventEvidence(
        _ proof: WorkAgentHandleEventEvidence,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        try validateReference(proof.event, source: source, limits: limits)
        guard proof.sequence > 0, proof.sequence <= source.cursor.sequence,
              proof.hostSequence.map({ $0 >= 0 }) ?? true,
              proof.hostRecordedAt.timeIntervalSince1970.isFinite,
              proof.provenance == .native else {
            throw BoundedTimelineReducerProjectionError.invalidCursor
        }
        if proof.sequence == 1 {
            guard proof.previousEventID == nil else {
                throw BoundedTimelineReducerProjectionError.invalidCursor
            }
        } else {
            guard let previous = proof.previousEventID else {
                throw BoundedTimelineReducerProjectionError.invalidCursor
            }
            try validateIdentifierValue(previous, limits: limits)
        }
        if let cause = proof.causedByEventID {
            try validateReference(cause, source: source, limits: limits)
        }
        try validateActor(proof.actor, limits: limits)
    }

    private static func validateAgentHandleEvidence(
        _ handle: BoundedWorkAgentHandleIndexRecord,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        try handle.providerAccounting.validate(
            origin: handle.origin, handle: handle.handle, execution: handle.startedEvent,
            journal: source.journal, lastSequence: source.cursor.sequence)
        try handle.providerAccounting.validateLifecycleOrder(
            executionSequence: nil,
            cancellationSequence: handle.cancellationEvidence?.event.sequence,
            terminalSequence: handle.terminalEvidence?.event.sequence)
        for evidence in handle.providerAccounting.evidence {
            try validateAgentHandleEventEvidence(evidence, source: source, limits: limits)
        }
        if let cancellation = handle.cancellationEvidence {
            try validateAgentHandleEventEvidence(
                cancellation.event, source: source, limits: limits)
            guard cancellation.event.work == handle.origin.work,
                  cancellation.event.workHost == handle.origin.workHost,
                  cancellation.event.session == handle.origin.session,
                  cancellation.event.sessionAttachment == handle.origin.sessionAttachment,
                  cancellation.event.run == handle.origin.run,
                  cancellation.event.handle == handle.handle,
                  cancellation.event.causedByEventID
                    == (handle.startedEvent ?? handle.queuedEvent) else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
            if cancellation.cause == .deadline {
                guard let deadline = handle.deadline,
                      deadline.timeIntervalSince1970.isFinite,
                      cancellation.event.hostRecordedAt >= deadline else {
                    throw BoundedTimelineReducerProjectionError.invalidIdentity
                }
            }
            if cancellation.cause == .client {
                guard let command = cancellation.command,
                      let client = command.client,
                      cancellation.event.client == client,
                      let attachment = command.sessionAttachment,
                      let cursor = command.causalCursor,
                      cursor.journal == source.journal,
                      cursor.eventID == cancellation.event.previousEventID,
                      cursor.sequence == cancellation.event.sequence - 1 else {
                    throw BoundedTimelineReducerProjectionError.invalidCursor
                }
                try validateIdentifierValue(command.commandID, limits: limits)
                try validateIdentifierValue(client.clientID, limits: limits)
                try validateIdentifierValue(attachment.attachmentID, limits: limits)
                try validateCursor(cursor, limits: limits)
            } else if cancellation.command != nil || cancellation.event.client != nil {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        }
        if let terminal = handle.terminalEvidence {
            try validateAgentHandleEventEvidence(
                terminal.event, source: source, limits: limits)
            guard terminal.event.work == handle.origin.work,
                  terminal.event.workHost == handle.origin.workHost,
                  terminal.event.session == handle.origin.session,
                  terminal.event.sessionAttachment == handle.origin.sessionAttachment,
                  terminal.event.run == handle.origin.run,
                  terminal.event.handle == handle.handle,
                  terminal.event.client == nil,
                  terminal.event.causedByEventID
                    == (handle.cancellationEvent ?? handle.startedEvent ?? handle.queuedEvent),
                  terminal.outcome != .succeeded || terminal.resultBody != nil else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
            if terminal.outcome == .expired {
                guard let deadline = handle.deadline,
                      deadline.timeIntervalSince1970.isFinite,
                      terminal.event.hostRecordedAt >= deadline else {
                    throw BoundedTimelineReducerProjectionError.invalidIdentity
                }
            }
            if let cancellation = handle.cancellationEvidence {
                guard cancellation.event.sequence < terminal.event.sequence else {
                    throw BoundedTimelineReducerProjectionError.invalidCursor
                }
            }
            if handle.startedEvent == nil {
                guard terminal.cleanup.state == .notStarted,
                      [.failed, .canceled, .expired].contains(terminal.outcome) else {
                    throw BoundedTimelineReducerProjectionError.invalidIdentity
                }
            } else if terminal.outcome == .indeterminate {
                guard terminal.cleanup.state == .indeterminate else {
                    throw BoundedTimelineReducerProjectionError.invalidIdentity
                }
            } else if terminal.cleanup.state != .quiesced {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
            if handle.cancellationEvidence != nil,
               !cancellationAllowsTerminalOutcome(
                   handle.cancellationCause, outcome: terminal.outcome) {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
            if let cleanupEvidence = terminal.cleanup.evidence {
                try validateReference(cleanupEvidence, source: source, limits: limits)
            }
        }
        switch handle.state {
        case .queued:
            guard handle.cancellationEvidence == nil, handle.terminalEvidence == nil else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
            guard handle.startedEvent == nil,
                  handle.latestLifecycleEvent == handle.queuedEvent else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        case .running:
            guard handle.cancellationEvidence == nil, handle.terminalEvidence == nil,
                  handle.startedEvent != nil,
                  handle.latestLifecycleEvent == handle.startedEvent else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        case .cancelRequested:
            guard handle.cancellationEvidence != nil, handle.terminalEvidence == nil,
                  handle.latestLifecycleEvent == handle.cancellationEvent else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        case .terminal:
            guard handle.terminalEvidence != nil,
                  handle.latestLifecycleEvent == handle.terminalEvent else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        case .reaped:
            guard handle.terminalEvidence != nil, handle.reapedEvent != nil,
                  handle.reapReason != nil,
                  handle.latestLifecycleEvent == handle.reapedEvent,
                  handle.cleanup?.state != .indeterminate else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        }
    }

    private static func cancellationAllowsTerminalOutcome(
        _ cause: WorkAgentHandleCancellationCause?,
        outcome: WorkAgentHandleTerminalOutcome
    ) -> Bool {
        switch cause {
        case .deadline:
            return [.expired, .indeterminate].contains(outcome)
        case .client, .workDestruction, .hostShutdown:
            return [.canceled, .indeterminate].contains(outcome)
        case nil:
            return true
        }
    }

    private static func validateStringList(
        _ values: [String], limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard values == values.sorted(), Set(values).count == values.count else {
            throw BoundedTimelineReducerProjectionError.invalidOrdering
        }
        for value in values { try validateIdentifierValue(value, limits: limits) }
    }

    private static func validateProjectionRows(
        _ head: BoundedWorkReducerHead,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        if let work = head.work {
            try validateIdentifierValue(work.workID, limits: limits)
            try validateIdentifierValue(work.workHostID, limits: limits)
        }
        if let workHost = head.workHost {
            try validateIdentifierValue(workHost.workHostID, limits: limits)
            if let work = head.work, work.workHostID != workHost.workHostID {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        }
        if let run = head.currentRun {
            try validateIdentifierValue(run.run.runID, limits: limits)
            try validateProjectionEvent(run.sourceEvent, source: head.source, limits: limits)
        }
        guard (head.activeRunSession == nil) == (head.activeRunSessionAttachment == nil),
              (head.currentRun == nil) == (head.activeRunSession == nil) else {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
        if let session = head.activeRunSession {
            try validateIdentifierValue(session.sessionID, limits: limits)
        }
        if let attachment = head.activeRunSessionAttachment {
            try validateIdentifierValue(attachment.attachmentID, limits: limits)
        }
        if let ownerSession = head.activeRunSession,
           let ownerAttachment = head.activeRunSessionAttachment {
            // A projected owner is actionable only when its exact attached relationship is in
            // the bounded index. If the row was omitted or detached, callers must treat the
            // head as invalid rather than infer ownership from a Run or template alone.
            guard head.attachments.contains(where: {
                $0.session == ownerSession
                    && $0.attachment == ownerAttachment
                    && $0.isAttached
            }) else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
        }
        if let turn = head.currentTurn {
            try validateIdentifierValue(turn.turn.turnID, limits: limits)
            try validateProjectionEvent(turn.sourceEvent, source: head.source, limits: limits)
        }
        if let modelID = head.modelID { try validateIdentifierValue(modelID, limits: limits) }
        for action in head.actions {
            try validateIdentifierValue(action.action.actionID, limits: limits)
            try validateOptionalDigest(action.intent, limits: limits)
            try validateOptionalDigest(action.target, limits: limits)
            try validateOptionalDigest(action.scope, limits: limits)
            try validateOptionalDigest(action.metadata, limits: limits)
            try validateProjectionEvent(action.intentEvent, source: head.source, limits: limits)
            try validateProjectionEvent(action.startedEvent, source: head.source, limits: limits)
            try validateProjectionEvent(action.outcomeEvent, source: head.source, limits: limits)
        }
        for handle in head.handles {
            try validateIdentifierValue(handle.handle.handleID, limits: limits)
            try validateDigestValue(handle.stateDigest, limits: limits)
            guard handle.stateDigest.byteCount > 0 else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
            try validateProjectionEvent(handle.sourceEvent, source: head.source, limits: limits)
        }
        for handle in head.agentHandles {
            try validateIdentifierValue(handle.handle.handleID, limits: limits)
            try validateIdentifierValue(handle.origin.work.workID, limits: limits)
            try validateIdentifierValue(handle.origin.work.workHostID, limits: limits)
            try validateIdentifierValue(handle.origin.workHost.workHostID, limits: limits)
            try validateIdentifierValue(handle.origin.session.sessionID, limits: limits)
            try validateIdentifierValue(handle.origin.sessionAttachment.attachmentID, limits: limits)
            try validateIdentifierValue(handle.origin.run.runID, limits: limits)
            guard handle.origin.work == head.work,
                  handle.origin.workHost == head.workHost,
                  handle.deadline.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  handle.label == handle.label.trimmingCharacters(in: .whitespacesAndNewlines),
                  !handle.label.isEmpty,
                  handle.label.utf8.count <= WorkAgentHandleSnapshot.maximumLabelBytes,
                  handle.requestBody.authority == head.source.journal,
                  handle.requestBody.referenceID == handle.requestBody.digest,
                  handle.requestBody.digest.map(validDigest) == true,
                  handle.requestBody.byteCount.map({
                      (0...WorkAgentHandleSnapshot.maximumBodyBytes).contains($0)
                  }) == true else {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
            if let result = handle.resultBody {
                guard result.authority == head.source.journal,
                      result.referenceID == result.digest,
                      result.digest.map(validDigest) == true,
                      result.byteCount.map({
                          (0...WorkAgentHandleSnapshot.maximumBodyBytes).contains($0)
                      }) == true else {
                    throw BoundedTimelineReducerProjectionError.invalidIdentity
                }
            }
            for reference in [handle.queuedEvent, handle.latestLifecycleEvent,
                              handle.startedEvent, handle.terminalEvent, handle.reapedEvent]
                .compactMap({ $0 }) {
                guard reference.journal == head.source.journal,
                      !reference.eventID.isEmpty else {
                    throw BoundedTimelineReducerProjectionError.invalidIdentity
                }
            }
            try validateAgentHandleEvidence(
                handle, source: head.source, limits: limits)
        }
        for attachment in head.attachments {
            try validateIdentifierValue(attachment.attachment.attachmentID, limits: limits)
            try validateIdentifierValue(attachment.session.sessionID, limits: limits)
            try validateStringList(attachment.capabilities, limits: limits)
            try validateProjectionEvent(attachment.sourceEvent, source: head.source, limits: limits)
        }
        for command in head.commands {
            try validateIdentifierValue(command.command.commandID, limits: limits)
            if let client = command.command.client {
                try validateIdentifierValue(client.clientID, limits: limits)
            }
            if let attachment = command.command.sessionAttachment {
                try validateIdentifierValue(attachment.attachmentID, limits: limits)
            }
            if let cursor = command.command.causalCursor { try validateCursor(cursor, limits: limits) }
            try validateActor(command.acceptanceActor, limits: limits)
            guard command.acceptanceHostSequence >= 0 else {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
            try validateOptionalDigest(command.acceptanceIdempotencyKey, limits: limits)
            try validateProjectionEvent(command.acceptanceEvent, source: head.source, limits: limits)
            if let actor = command.deliveryActor { try validateActor(actor, limits: limits) }
            if let sequence = command.deliveryHostSequence {
                guard sequence >= 0 else { throw BoundedTimelineReducerProjectionError.invalidOffsets }
            }
            try validateOptionalDigest(command.deliveryIdempotencyKey, limits: limits)
            try validateProjectionEvent(command.deliveryEvent, source: head.source, limits: limits)
        }
        for child in head.children {
            try validateIdentifierValue(child.childID, limits: limits)
            try validateDigestValue(child.stateDigest, limits: limits)
            try validateProjectionEvent(child.sourceEvent, source: head.source, limits: limits)
        }
        try validateStringList(head.activeActionIDs, limits: limits)
        for recovery in head.recovery {
            try validateRecovery(recovery, source: head.source, limits: limits)
        }
        for unknown in head.unknowns {
            try validateUnknown(unknown, source: head.source, limits: limits)
        }
        for corruption in head.corruption {
            try validateProjectionEvent(corruption.event, source: head.source, limits: limits)
            try validateDigestValue(corruption.reason, limits: limits)
        }
        if let lastHostSequence = head.lastHostSequence, lastHostSequence < 0 {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
    }

    private static func validateProjectionRows(
        _ head: BoundedSessionReducerHead,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        if let session = head.session {
            try validateIdentifierValue(session.sessionID, limits: limits)
        }
        if let run = head.currentRun {
            try validateIdentifierValue(run.run.runID, limits: limits)
            try validateProjectionEvent(run.sourceEvent, source: head.source, limits: limits)
        }
        if let turn = head.currentTurn {
            try validateIdentifierValue(turn.turn.turnID, limits: limits)
            try validateProjectionEvent(turn.sourceEvent, source: head.source, limits: limits)
        }
        if let modelID = head.modelID { try validateIdentifierValue(modelID, limits: limits) }
        for attachment in head.attachments {
            try validateIdentifierValue(attachment.attachment.attachmentID, limits: limits)
            try validateIdentifierValue(attachment.work.workID, limits: limits)
            try validateIdentifierValue(attachment.work.workHostID, limits: limits)
            try validateStringList(attachment.capabilities, limits: limits)
            if let cursor = attachment.cursor { try validateCursor(cursor, limits: limits) }
            try validateProjectionEvent(attachment.sourceEvent, source: head.source, limits: limits)
        }
        for message in head.messageHistory + head.visibleMessages {
            try validateIdentifierValue(message.event.reference.eventID, limits: limits)
            try validateIdentifierValue(message.role, limits: limits)
            try validateDigestValue(message.text, limits: limits)
            if let parent = message.conversationParent {
                try validateReference(parent, source: head.source, limits: limits)
            }
            if let run = message.run { try validateIdentifierValue(run.runID, limits: limits) }
            if let turn = message.turn { try validateIdentifierValue(turn.turnID, limits: limits) }
        }
        for component in head.context {
            try validateIdentifierValue(component.componentID, limits: limits)
            try validateIdentifierValue(component.inclusionID, limits: limits)
            try validateIdentifierValue(component.sourceID, limits: limits)
            if let provenance = component.sourceProvenance {
                try validateReference(provenance, source: head.source, limits: limits)
            }
            for byteCount in [component.measuredBytes, component.includedBytes,
                              component.deliveredBytes, component.fullByteCount] {
                if let byteCount, (byteCount < 0 || byteCount > Int.max / 4) {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
            }
            if let digest = component.digest, !validDigest(digest) {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
            if let tokenCount = component.tokenCount {
                guard tokenCount >= 0 else {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
                if let tokenizer = component.tokenizer, tokenizer.isEmpty {
                    throw BoundedTimelineReducerProjectionError.invalidIdentity
                }
            } else if component.tokenizer != nil {
                throw BoundedTimelineReducerProjectionError.invalidIdentity
            }
            if let measured = component.measuredBytes, let full = component.fullByteCount {
                guard measured == full else {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
            }
            if let included = component.includedBytes, let delivered = component.deliveredBytes {
                guard included == delivered else {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
            }
            if let delivered = component.deliveredBytes, let full = component.fullByteCount {
                guard delivered <= full else {
                    throw BoundedTimelineReducerProjectionError.invalidOffsets
                }
            }
            if let tokenizer = component.tokenizer {
                try validateIdentifierValue(tokenizer, limits: limits)
            }
            try validateBodyReference(component.bodyReference, source: head.source, limits: limits)
            if let body = component.bodyReference {
                guard body.digest == component.digest, body.byteCount == component.fullByteCount else {
                    throw BoundedTimelineReducerProjectionError.invalidDigest
                }
            }
        }
        for prompt in head.promptSources {
            try validatePromptSource(prompt, source: head.source, limits: limits)
        }
        if let promptAssemblyID = head.promptAssemblyID {
            try validateIdentifierValue(promptAssemblyID, limits: limits)
            if !head.promptSources.isEmpty, !validDigest(promptAssemblyID) {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        } else if !head.promptSources.isEmpty {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
        for child in head.childStates {
            try validateIdentifierValue(child.childID, limits: limits)
            try validateDigestValue(child.stateDigest, limits: limits)
            try validateProjectionEvent(child.sourceEvent, source: head.source, limits: limits)
        }
        for recovery in head.recovery {
            try validateRecovery(recovery, source: head.source, limits: limits)
        }
        for unknown in head.unknowns {
            try validateUnknown(unknown, source: head.source, limits: limits)
        }
        for corruption in head.corruption {
            try validateProjectionEvent(corruption.event, source: head.source, limits: limits)
            try validateDigestValue(corruption.reason, limits: limits)
        }
        if let semanticTip = head.semanticTip {
            try validateReference(semanticTip, source: head.source, limits: limits)
        }
        for value in [head.contextMeasuredBytes, head.contextDeliveredBytes,
                      head.contextCumulativeDeliveredBytes] {
            if let value, (value < 0 || value > Int.max / 4) {
                throw BoundedTimelineReducerProjectionError.invalidOffsets
            }
        }
        guard head.contextOmissionCount >= 0 else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        if let manifestID = head.contextManifestID {
            try validateIdentifierValue(manifestID, limits: limits)
        }
        if let requestID = head.contextRequestID {
            try validateIdentifierValue(requestID, limits: limits)
        }
        if let modelID = head.contextModelID {
            try validateIdentifierValue(modelID, limits: limits)
        }
    }

    private static func validateRecovery(
        _ value: BoundedRecoveryIndexRecord,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        let expectedPlanes = RecoveryPlane.allCases.sorted { $0.rawValue < $1.rawValue }
        guard value.planes.map(\.plane) == expectedPlanes,
              value.caveatCount >= 0, value.caveatCount <= Int.max / 4 else {
            throw BoundedTimelineReducerProjectionError.invalidOrdering
        }
        if let digest = value.caveatDigest {
            guard validDigest(digest) else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        }
        if let evidence = value.evidence { try validateReference(evidence, source: source, limits: limits) }
        if let cursor = value.evidenceCursor { try validateCursor(cursor, limits: limits) }
        try validateProjectionEvent(value.sourceEvent, source: source, limits: limits)
        if let run = value.run { try validateIdentifierValue(run.runID, limits: limits) }
    }

    private static func validateUnknown(
        _ value: BoundedUnknownIndexRecord,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        try validateProjectionEvent(value.event, source: source, limits: limits)
        guard value.journalOffset >= 0, value.journalOffset <= source.sourceByteCount else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        try validateIdentifierValue(value.type, limits: limits)
        guard value.affectedDomains == value.affectedDomains.sorted(by: { $0.rawValue < $1.rawValue }),
              Set(value.affectedDomains).count == value.affectedDomains.count else {
            throw BoundedTimelineReducerProjectionError.invalidOrdering
        }
        try validateDigestValue(value.payload, limits: limits)
    }

    private static func validatePromptSource(
        _ value: BoundedPromptSourceIndexRecord,
        source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        try validateIdentifierValue(value.sourceID, limits: limits)
        try validateIdentifierValue(value.inclusionID, limits: limits)
        guard value.label == "source:\(value.kind.rawValue)",
              value.labelByteCount >= 0, value.labelByteCount <= Int.max / 4,
              value.deliveredByteCount >= 0, value.deliveredByteCount <= Int.max / 4,
              value.deliveredByteOffsetInRendered >= 0,
              value.renderedByteCount >= 0, value.renderedByteCount <= Int.max / 4,
              validDigest(value.deliveredDigest), validDigest(value.renderedDigest) else {
            throw BoundedTimelineReducerProjectionError.invalidDigest
        }
        if let fullCount = value.fullByteCount {
            guard fullCount >= 0, fullCount <= Int.max / 4,
                  let fullDigest = value.fullDigest, validDigest(fullDigest),
                  value.deliveredByteCount <= fullCount else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        } else {
            guard value.fullDigest == nil, value.status == .missing || value.status == .unreadable
                    || value.status == .disabled, value.deliveredByteCount == 0,
                    value.renderedByteCount == 0, value.deliveredByteOffsetInRendered == 0 else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        }
        let end = value.deliveredByteOffsetInRendered.addingReportingOverflow(value.deliveredByteCount)
        guard !end.overflow, end.partialValue <= value.renderedByteCount else {
            throw BoundedTimelineReducerProjectionError.invalidOffsets
        }
        try validateBodyReference(value.fullBodyReference, source: source, limits: limits)
        try validateBodyReference(value.deliveredBodyReference, source: source, limits: limits)
        try validateBodyReference(value.renderedBodyReference, source: source, limits: limits)
        if let full = value.fullBodyReference {
            guard full.byteCount == value.fullByteCount, full.digest == value.fullDigest else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        }
        if let delivered = value.deliveredBodyReference {
            guard delivered.byteCount == value.deliveredByteCount,
                  delivered.digest == value.deliveredDigest else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        }
        if let rendered = value.renderedBodyReference {
            guard rendered.byteCount == value.renderedByteCount,
                  rendered.digest == value.renderedDigest else {
                throw BoundedTimelineReducerProjectionError.invalidDigest
            }
        }
        if let provenance = value.provenance {
            try validateReference(provenance, source: source, limits: limits)
        }
    }

    fileprivate static func validateSource(
        _ source: BoundedReducerProjectionSource,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        try validateJournal(source.journal, limits: limits)
        guard source.schemaVersion == BoundedReducerProjectionSource.schemaVersion,
              source.cursor.journal == source.journal,
              source.cursor.sequence >= 0, source.cursor.sequence < Int.max,
              source.cursor.sequence == 0
                ? source.cursor.eventID == nil
                : source.cursor.eventID.map({ validIdentifier($0, maxBytes: limits.maximumIdentifierBytes) }) == true,
              validIdentifier(source.sourceID, maxBytes: limits.maximumIdentifierBytes),
              validDigest(source.sourceGeneration), validDigest(source.sourceFingerprint),
              validDigest(source.prefixDigest), source.sourceByteCount >= 0,
              source.prefixByteCount >= 0, source.prefixByteCount <= source.sourceByteCount,
              source.sourceByteCount <= Int.max / 4 else {
            throw BoundedTimelineReducerProjectionError.invalidSource
        }
    }

    fileprivate static func validateWorkSnapshotCursor(
        _ snapshot: WorkSnapshot,
        source: BoundedReducerProjectionSource
    ) throws {
        guard snapshot.journal == nil || snapshot.journal == source.journal,
              snapshot.lastSequence == source.cursor.sequence,
              snapshot.lastEventID == source.cursor.eventID else {
            throw BoundedTimelineReducerProjectionError.sourceMismatch
        }
    }

    fileprivate static func validateSessionSnapshotCursor(
        _ snapshot: SessionSnapshot,
        source: BoundedReducerProjectionSource
    ) throws {
        guard snapshot.journal == nil || snapshot.journal == source.journal,
              snapshot.lastSequence == source.cursor.sequence,
              snapshot.lastEventID == source.cursor.eventID else {
            throw BoundedTimelineReducerProjectionError.sourceMismatch
        }
    }

    private static func validateEvents(
        _ source: BoundedReducerProjectionSource,
        _ event: BoundedReducerProjectionEvent?,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard let event else { return }
        guard event.reference.journal == source.journal,
              event.reference.eventID.utf8.count <= limits.maximumIdentifierBytes,
              event.sequence.map({ $0 >= 0 && $0 <= source.cursor.sequence }) ?? true,
              event.type.map({ $0.utf8.count <= limits.maximumIdentifierBytes }) ?? true,
              event.canonicalDigest.map(validDigest) ?? true else {
            throw BoundedTimelineReducerProjectionError.invalidSource
        }
    }

    private static func validateRows(
        _ source: BoundedReducerProjectionSource,
        _ rows: [BoundedReducerProjectionEvent],
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        for row in rows { try validateEvents(source, row, limits: limits) }
    }

    private static func validateSortedUnique(_ values: [String]) throws {
        guard values == values.sorted(), Set(values).count == values.count else {
            throw BoundedTimelineReducerProjectionError.invalidOrdering
        }
    }

    private static func validateUnique(_ values: [String]) throws {
        guard Set(values).count == values.count else {
            throw BoundedTimelineReducerProjectionError.duplicateIdentity
        }
    }

    private static func validateUniquePairs(_ values: [(String, String)]) throws {
        let keys = values.map { $0.0 + "\u{0}" + $0.1 }
        try validateUnique(keys)
    }

    private static func enforceHeadSize<T: Encodable>(
        _ head: T,
        limits: BoundedTimelineReducerProjectionLimits
    ) throws {
        guard try canonicalJSON(head).count <= limits.maximumHeadBytes else {
            throw BoundedTimelineReducerProjectionError.oversize
        }
    }

    private static func actionEvent(_ row: BoundedWorkActionIndexRecord) -> [BoundedReducerProjectionEvent] {
        [row.intentEvent, row.startedEvent, row.outcomeEvent].compactMap { $0 }
    }

    fileprivate static func appendOmission(
        _ result: inout [BoundedReducerProjectionOmission],
        _ index: BoundedReducerProjectionIndex,
        _ total: Int,
        _ retained: Int
    ) {
        guard total > retained else { return }
        result.append(.init(index: index, omittedCount: total - retained))
    }

    private static func makeMessageRows(
        _ messages: [SessionMessageSnapshot],
        trace: Trace,
        max: Int
    ) -> [BoundedMessageIndexRecord] {
        let rows = messages.compactMap { message -> BoundedMessageIndexRecord? in
            guard let sourceEvent = message.sourceEvent else { return nil }
            let event = trace.messageEvents[message.eventID]
                ?? projectionEvent(sourceEvent)
            guard let text = digestTextValue(message.text) else { return nil }
            return BoundedMessageIndexRecord(
                event: event, role: bounded(message.role, maxBytes: 256), text: text,
                conversationParent: message.conversationParent, run: message.run,
                turn: message.turn, provenance: message.provenance,
                visible: message.role != ChatRole.assistant.rawValue || !message.text.isEmpty)
        }.sorted(by: messageLess)
        return Array(rows.suffix(max))
    }

    private static func makeChildRows(
        _ children: [String: String],
        sourceEvents: [String: BoundedReducerProjectionEvent] = [:],
        max: Int
    ) -> [BoundedChildIndexRecord] {
        let rows = children.keys.map {
            BoundedChildIndexRecord(
                childID: bounded($0, maxBytes: 512), state: children[$0] ?? "",
                sourceEvent: sourceEvents[$0])
        }.sorted(by: childLess)
        return Array(rows.prefix(max))
    }

    private static func makeRecoveryRows(
        coverage: [RecoveryCoverage],
        recorded: [RecordedRecoveryCoverage],
        sourceEvents: [String: BoundedReducerProjectionEvent],
        max: Int
    ) -> [BoundedRecoveryIndexRecord] {
        if !recorded.isEmpty {
            return Array(recorded.suffix(max)).map {
                BoundedRecoveryIndexRecord(
                    coverage: $0.coverage,
                    sourceEvent: sourceEvents[$0.sourceEvent.eventID]
                        ?? projectionEvent($0.sourceEvent), run: $0.run)
            }
        }
        return Array(coverage.suffix(max)).map { BoundedRecoveryIndexRecord(coverage: $0) }
    }

    private static func makeUnknownRows(
        _ values: [UnknownTimelineEvent], max: Int
    ) -> [BoundedUnknownIndexRecord] {
        values.suffix(max).compactMap { value -> BoundedUnknownIndexRecord? in
            let event = projectionEvent(value.event)
            guard let payload = digestJSON(value.rawPayload) else { return nil }
            return BoundedUnknownIndexRecord(
                event: event, journalOffset: Swift.max(0, value.journalOffset),
                type: bounded(value.event.type, maxBytes: 512),
                affectedDomains: Array(value.affectedDomains), payload: payload)
        }
    }

    private static func makeCorruptionRows(
        reasons: [String], events: [TimelineEvent], max limit: Int
    ) -> [BoundedCorruptionIndexRecord] {
        let count = Swift.min(limit, Swift.max(reasons.count, events.count))
        return (0..<count).compactMap { index -> BoundedCorruptionIndexRecord? in
            let digest = digestText(index < reasons.count ? reasons[index] : "unknown")
            guard let digest else { return nil }
            let event = index < events.count ? projectionEvent(events[index]) : nil
            return BoundedCorruptionIndexRecord(event: event, reason: digest)
        }
    }

    private static func makeDiagnostics(
        snapshot: WorkSnapshot,
        max: Int
    ) -> [BoundedReducerProjectionDiagnostic] {
        makeDiagnostics(
            reasons: snapshot.corruptionReasons,
            events: snapshot.quarantinedEvents,
            max: max)
    }

    private static func makeDiagnostics(
        snapshot: SessionSnapshot,
        max: Int
    ) -> [BoundedReducerProjectionDiagnostic] {
        makeDiagnostics(
            reasons: snapshot.corruptionReasons,
            events: snapshot.quarantinedEvents,
            max: max)
    }

    private static func makeDiagnostics(
        reasons: [String], events: [TimelineEvent], max limit: Int
    ) -> [BoundedReducerProjectionDiagnostic] {
        let count = Swift.min(limit, Swift.max(reasons.count, events.count))
        return (0..<count).compactMap { index -> BoundedReducerProjectionDiagnostic? in
            guard let digest = digestText(index < reasons.count ? reasons[index] : "unknown") else {
                return nil
            }
            let source = index < events.count ? projectionEvent(events[index]) : nil
            return BoundedReducerProjectionDiagnostic(
                code: "reducer_corruption", reasonDigest: digest.digest, sourceEvent: source)
        }
    }

    fileprivate static func projectionEvent(
        _ event: TimelineEvent
    ) -> BoundedReducerProjectionEvent {
        let canonicalDigest: String?
        if let data = try? canonicalJSON(event), let digest = digestData(data) {
            canonicalDigest = digest.digest
        } else {
            canonicalDigest = nil
        }
        return BoundedReducerProjectionEvent(
            reference: EventRef(journal: event.journal, eventID: event.eventID),
            sequence: event.sequence, type: event.type,
            canonicalDigest: canonicalDigest)
    }

    private static func projectionEvent(
        _ event: EventRef
    ) -> BoundedReducerProjectionEvent {
        BoundedReducerProjectionEvent(reference: event)
    }

    private static func projectionEvent(
        _ observation: WorkActionObservation?
    ) -> BoundedReducerProjectionEvent? {
        observation.map {
            BoundedReducerProjectionEvent(
                reference: $0.sourceEvent, sequence: $0.sequence)
        }
    }

    fileprivate static func digestText(_ value: String?) -> BoundedReducerProjectionDigest? {
        value.flatMap(digestTextValue)
    }

    private static func digestTextValue(_ value: String) -> BoundedReducerProjectionDigest? {
        digestData(Data(value.utf8))
    }

    fileprivate static func digestTextValueForRecord(_ value: String) -> BoundedReducerProjectionDigest {
        // UTF-8 Data and SHA-256 are infallible here; keeping this wrapper non-optional prevents a
        // metadata row from silently losing its state evidence.
        digestData(Data(value.utf8))!
    }

    fileprivate static func digestTextArray(_ values: [String]) -> String? {
        let sorted = values.sorted()
        guard let data = try? canonicalJSON(sorted) else { return nil }
        return digestData(data)?.digest
    }

    private static func digestJSON(_ value: [String: JSONValue]) -> BoundedReducerProjectionDigest? {
        guard let data = try? canonicalJSON(value) else { return nil }
        return digestData(data)
    }

    private static func digestJSON(_ value: JSONValue) -> BoundedReducerProjectionDigest? {
        guard let data = try? canonicalJSON(value) else { return nil }
        return digestData(data)
    }

    private static func digestData(_ data: Data) -> BoundedReducerProjectionDigest? {
        BoundedReducerProjectionDigest(
            byteCount: data.count,
            digest: "sha256:" + AviarySHA256.hash(data: data).description)
    }

    fileprivate static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 || (value.hasPrefix("sha256:") && value.dropFirst(7).utf8.count == 64)
            ? value.dropFirst(value.hasPrefix("sha256:") ? 7 : 0).unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 65 && $0.value <= 70)
                    || ($0.value >= 97 && $0.value <= 102)
            } : false
    }

    private static func validIdentifier(
        _ value: String, maxBytes: Int = 512
    ) -> Bool {
        value.utf8.count > 0 && value.utf8.count <= maxBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    fileprivate static func bounded(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= maxBytes else { break }
            result.append(character)
            bytes += count
        }
        return result
    }

    private static func boundedOptional(_ value: String?, maxBytes: Int) -> String? {
        value.map { bounded($0, maxBytes: maxBytes) }
    }

    private static func validateWorkIdentity(
        _ value: String, maxBytes: Int
    ) -> Bool { validIdentifier(value, maxBytes: maxBytes) }
}

private extension BoundedWorkReducerHead {
    init(
        projectionMarker: Void,
        schemaVersion: Int,
        source: BoundedReducerProjectionSource,
        coverage: BoundedReducerProjectionCoverage,
        work: WorkRef?,
        workHost: WorkHostRef?,
        lifecycle: WorkLifecycle,
        lifecycleEvent: BoundedReducerProjectionEvent?,
        execution: WorkExecution,
        executionEvent: BoundedReducerProjectionEvent?,
        currentRun: BoundedReducerProjectionRun?,
        activeRunSession: SessionRef?,
        activeRunSessionAttachment: SessionAttachmentRef?,
        currentTurn: BoundedReducerProjectionTurn?,
        modelID: String?,
        modelEvent: BoundedReducerProjectionEvent?,
        activeActionIDs: [String],
        actions: [BoundedWorkActionIndexRecord],
        providerUsage: ProviderUsageAggregate,
        handles: [BoundedWorkHandleIndexRecord],
        agentHandles: [BoundedWorkAgentHandleIndexRecord],
        liveAgentHandleCount: Int,
        unreapedAgentHandleCount: Int,
        retainedAgentHandleCount: Int,
        attachments: [BoundedWorkAttachmentIndexRecord],
        commands: [BoundedCommandIndexRecord],
        children: [BoundedChildIndexRecord],
        recovery: [BoundedRecoveryIndexRecord],
        unknowns: [BoundedUnknownIndexRecord],
        corruption: [BoundedCorruptionIndexRecord],
        lastHostSequence: Int?,
        lastEventID: String?,
        lastSequence: Int,
        causalOrderValid: Bool,
        structuralIntegrityValid: Bool,
        semanticProjectionValid: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.coverage = coverage
        self.work = work
        self.workHost = workHost
        self.lifecycle = lifecycle
        self.lifecycleEvent = lifecycleEvent
        self.execution = execution
        self.executionEvent = executionEvent
        self.currentRun = currentRun
        self.activeRunSession = activeRunSession
        self.activeRunSessionAttachment = activeRunSessionAttachment
        self.currentTurn = currentTurn
        self.modelID = modelID
        self.modelEvent = modelEvent
        self.activeActionIDs = activeActionIDs.sorted()
        self.actions = actions.sorted(by: BoundedTimelineReducerProjection.actionLess)
        self.providerUsage = providerUsage
        self.handles = handles.sorted(by: BoundedTimelineReducerProjection.handleLess)
        self.agentHandles = agentHandles.sorted {
            if $0.blocksWorkCompletion != $1.blocksWorkCompletion {
                return $0.blocksWorkCompletion
            }
            return $0.handle.handleID < $1.handle.handleID
        }
        self.liveAgentHandleCount = liveAgentHandleCount
        self.unreapedAgentHandleCount = unreapedAgentHandleCount
        self.retainedAgentHandleCount = retainedAgentHandleCount
        self.attachments = attachments.sorted(by: BoundedTimelineReducerProjection.attachmentLess)
        self.commands = commands.sorted(by: BoundedTimelineReducerProjection.commandLess)
        self.children = children.sorted(by: BoundedTimelineReducerProjection.childLess)
        self.recovery = recovery
        self.unknowns = unknowns.sorted { lhs, rhs in
            (lhs.event.sequence ?? Int.max, lhs.event.reference.eventID)
                < (rhs.event.sequence ?? Int.max, rhs.event.reference.eventID)
        }
        self.corruption = corruption
        self.lastHostSequence = lastHostSequence
        self.lastEventID = lastEventID
        self.lastSequence = lastSequence
        self.causalOrderValid = causalOrderValid
        self.structuralIntegrityValid = structuralIntegrityValid
        self.semanticProjectionValid = semanticProjectionValid
    }
}

private extension BoundedSessionReducerHead {
    init(
        projectionMarker: Void,
        schemaVersion: Int,
        source: BoundedReducerProjectionSource,
        coverage: BoundedReducerProjectionCoverage,
        session: SessionRef?,
        lifecycle: SessionLifecycle,
        lifecycleEvent: BoundedReducerProjectionEvent?,
        execution: WorkExecution,
        attention: SessionAttention,
        attentionEvent: BoundedReducerProjectionEvent?,
        currentRun: BoundedReducerProjectionRun?,
        currentTurn: BoundedReducerProjectionTurn?,
        modelID: String?,
        modelEvent: BoundedReducerProjectionEvent?,
        attachments: [BoundedSessionAttachmentIndexRecord],
        messageHistory: [BoundedMessageIndexRecord],
        visibleMessages: [BoundedMessageIndexRecord],
        context: [BoundedContextIndexRecord],
        contextManifestID: String?,
        contextRequestID: String?,
        contextModelID: String?,
        contextMeasuredBytes: Int?,
        contextDeliveredBytes: Int?,
        contextCumulativeDeliveredBytes: Int?,
        contextOmissionCount: Int,
        promptAssemblyID: String?,
        promptSources: [BoundedPromptSourceIndexRecord],
        compaction: BoundedReducerProjectionDigest?,
        compactionEvent: BoundedReducerProjectionEvent?,
        childStates: [BoundedChildIndexRecord],
        recovery: [BoundedRecoveryIndexRecord],
        unknowns: [BoundedUnknownIndexRecord],
        corruption: [BoundedCorruptionIndexRecord],
        semanticTip: EventRef?,
        lastEventID: String?,
        lastSequence: Int,
        causalOrderValid: Bool,
        structuralIntegrityValid: Bool,
        semanticProjectionValid: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.coverage = coverage
        self.session = session
        self.lifecycle = lifecycle
        self.lifecycleEvent = lifecycleEvent
        self.execution = execution
        self.attention = attention
        self.attentionEvent = attentionEvent
        self.currentRun = currentRun
        self.currentTurn = currentTurn
        self.modelID = modelID
        self.modelEvent = modelEvent
        self.attachments = attachments.sorted {
            if $0.isAttached != $1.isAttached { return $0.isAttached }
            let lhsSequence = $0.sourceEvent?.sequence ?? -1
            let rhsSequence = $1.sourceEvent?.sequence ?? -1
            if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
            return $0.attachment.attachmentID < $1.attachment.attachmentID
        }
        self.messageHistory = messageHistory.sorted(by: BoundedTimelineReducerProjection.messageLess)
        self.visibleMessages = visibleMessages.sorted(by: BoundedTimelineReducerProjection.messageLess)
        self.context = context.sorted { ($0.inclusionID, $0.componentID) < ($1.inclusionID, $1.componentID) }
        self.contextManifestID = contextManifestID
        self.contextRequestID = contextRequestID
        self.contextModelID = contextModelID
        self.contextMeasuredBytes = contextMeasuredBytes
        self.contextDeliveredBytes = contextDeliveredBytes
        self.contextCumulativeDeliveredBytes = contextCumulativeDeliveredBytes
        self.contextOmissionCount = max(0, contextOmissionCount)
        self.promptAssemblyID = promptAssemblyID
        self.promptSources = promptSources.sorted { lhs, rhs in
            (lhs.inclusionID, lhs.sourceID) < (rhs.inclusionID, rhs.sourceID)
        }
        self.compaction = compaction
        self.compactionEvent = compactionEvent
        self.childStates = childStates.sorted(by: BoundedTimelineReducerProjection.childLess)
        self.recovery = recovery
        self.unknowns = unknowns.sorted { lhs, rhs in
            (lhs.event.sequence ?? Int.max, lhs.event.reference.eventID)
                < (rhs.event.sequence ?? Int.max, rhs.event.reference.eventID)
        }
        self.corruption = corruption
        self.semanticTip = semanticTip
        self.lastEventID = lastEventID
        self.lastSequence = lastSequence
        self.causalOrderValid = causalOrderValid
        self.structuralIntegrityValid = structuralIntegrityValid
        self.semanticProjectionValid = semanticProjectionValid
    }
}

private extension BoundedTimelineReducerProjection {
    static func projectionEvent(
        _ event: EventRef?
    ) -> BoundedReducerProjectionEvent? {
        event.map { BoundedReducerProjectionEvent(reference: $0) }
    }
}

/// Incremental, zero-based Work reduction for readers that cannot materialize the complete
/// canonical journal in an array. The accumulator owns only the same pure reducer and bounded
/// provenance trace used by ``BoundedTimelineReducerProjection.buildWork``; callers must provide
/// the exact source cursor when finalizing so an incomplete stream cannot be promoted.
public struct BoundedWorkReducerAccumulator: Sendable {
    private var reducer: WorkReducer
    private var trace: BoundedTimelineReducerProjection.Trace
    private let limits: BoundedTimelineReducerProjectionLimits

    public init(limits: BoundedTimelineReducerProjectionLimits = .default) {
        self.reducer = WorkReducer()
        self.trace = BoundedTimelineReducerProjection.Trace()
        self.limits = limits
    }

    /// The exact scalar reducer state produced by the same events as `finalize`. This is exposed
    /// for canonical writer-owned reads so service adapters do not need a second unlocked replay.
    public var snapshot: WorkSnapshot { reducer.snapshot }

    public mutating func append(_ event: TimelineEvent) {
        BoundedTimelineReducerProjection.consumeWorkEvent(
            event, reducer: &reducer, trace: &trace, limits: limits)
    }

    public func finalize(source: BoundedReducerProjectionSource) throws -> BoundedWorkReducerHead {
        try BoundedTimelineReducerProjection.validateSource(source, limits: limits)
        try BoundedTimelineReducerProjection.validateWorkSnapshotCursor(
            reducer.snapshot, source: source)
        let head = try BoundedTimelineReducerProjection.makeWorkHead(
            snapshot: reducer.snapshot, source: source, limits: limits, trace: trace)
        try head.validate(limits: limits)
        return head
    }
}

/// Incremental, zero-based Session reduction with the same exact-source finalization contract as
/// ``BoundedWorkReducerAccumulator``.
public struct BoundedSessionReducerAccumulator: Sendable {
    private var reducer: SessionReducer
    private var trace: BoundedTimelineReducerProjection.Trace
    private let limits: BoundedTimelineReducerProjectionLimits

    public init(limits: BoundedTimelineReducerProjectionLimits = .default) {
        self.reducer = SessionReducer()
        self.trace = BoundedTimelineReducerProjection.Trace()
        self.limits = limits
    }

    /// The exact scalar reducer state produced by the same events as `finalize`. This is exposed
    /// for canonical writer-owned reads so service adapters do not need a second unlocked replay.
    public var snapshot: SessionSnapshot { reducer.snapshot }

    public mutating func append(_ event: TimelineEvent) {
        BoundedTimelineReducerProjection.consumeSessionEvent(
            event, reducer: &reducer, trace: &trace, limits: limits)
    }

    public func finalize(source: BoundedReducerProjectionSource) throws -> BoundedSessionReducerHead {
        try BoundedTimelineReducerProjection.validateSource(source, limits: limits)
        try BoundedTimelineReducerProjection.validateSessionSnapshotCursor(
            reducer.snapshot, source: source)
        let head = try BoundedTimelineReducerProjection.makeSessionHead(
            snapshot: reducer.snapshot, source: source, limits: limits, trace: trace)
        try head.validate(limits: limits)
        return head
    }
}

/// The LocalTimelineProjectionReader's Session presentation lane. It consumes the exact-state
/// event-local result, not ``SessionReducer``. Only bounded metadata rows and digests are retained;
/// the exact map owns continuation and the source stream remains the body authority.
internal struct BoundedSessionExactHeadAccumulator: Sendable {
    private let limits: BoundedTimelineReducerProjectionLimits

    private var session: SessionRef?
    private var lifecycle: SessionLifecycle = .unknown
    private var execution: WorkExecution = .idle
    private var attention: SessionAttention = .none
    private var attentionEvent: BoundedReducerProjectionEvent?
    private var activeRun: RunRef?
    private var activeTurn: TurnRef?
    private var modelID: String?
    private var semanticTip: EventRef?
    private var causalOrderValid = true
    private var structuralIntegrityValid = true
    private var semanticProjectionValid = true
    private var semanticSequence = 0

    private var lifecycleEvent: BoundedReducerProjectionEvent?
    private var currentRunEvent: BoundedReducerProjectionEvent?
    private var currentTurnEvent: BoundedReducerProjectionEvent?
    private var modelEvent: BoundedReducerProjectionEvent?
    private var compactionEvent: BoundedReducerProjectionEvent?

    private var attachments: [String: BoundedSessionAttachmentIndexRecord] = [:]
    private var messageHistory: [BoundedMessageIndexRecord] = []
    private var visibleMessages: [BoundedMessageIndexRecord] = []
    private var context: [BoundedContextIndexRecord] = []
    private var promptSources: [BoundedPromptSourceIndexRecord] = []
    private var childStates: [String: BoundedChildIndexRecord] = [:]
    private var recovery: [BoundedRecoveryIndexRecord] = []
    private var unknowns: [BoundedUnknownIndexRecord] = []
    private var corruption: [BoundedCorruptionIndexRecord] = []

    private var contextManifestID: String?
    private var contextRequestID: String?
    private var contextModelID: String?
    private var contextMeasuredBytes: Int?
    private var contextDeliveredBytes: Int?
    private var contextCumulativeDeliveredBytes: Int?
    private var contextOmissionCount = 0
    private var promptAssemblyID: String?
    private var compaction: BoundedReducerProjectionDigest?
    /// Tip selection never reconstructs a lifetime branch in this lane. Keep that omission
    /// explicit even when the selected node itself remains in the bounded history window.
    private var visibleBranchIncomplete = false

    /// These totals are independent of retained rows. They make the omission contract truthful
    /// when the suffix grows past an index cap without preserving a lifetime-sized dictionary.
    private var messageTotal = 0
    private var attachmentTotal = 0
    private var contextTotal = 0
    private var childTotal = 0
    private var recoveryTotal = 0
    private var unknownTotal = 0
    private var corruptionTotal = 0
    private var activeItemCount = 0
    private var physicalEventID: String?
    private var physicalSequence = 0

    init(limits: BoundedTimelineReducerProjectionLimits) {
        self.limits = limits
    }

    init(
        head: BoundedSessionReducerHead,
        limits: BoundedTimelineReducerProjectionLimits
    ) {
        self.limits = limits
        session = head.session
        lifecycle = head.lifecycle
        execution = head.execution
        attention = head.attention
        attentionEvent = head.attentionEvent
        activeRun = head.currentRun?.run
        activeTurn = head.currentTurn?.turn
        modelID = head.modelID
        semanticTip = head.semanticTip
        causalOrderValid = head.causalOrderValid
        structuralIntegrityValid = head.structuralIntegrityValid
        semanticProjectionValid = head.semanticProjectionValid
        semanticSequence = head.source.cursor.sequence
        lifecycleEvent = head.lifecycleEvent
        currentRunEvent = head.currentRun?.sourceEvent
        currentTurnEvent = head.currentTurn?.sourceEvent
        modelEvent = head.modelEvent
        compactionEvent = head.compactionEvent
        attachments = Dictionary(uniqueKeysWithValues: head.attachments.map {
            ($0.attachment.attachmentID, $0)
        })
        messageHistory = head.messageHistory
        visibleMessages = head.visibleMessages
        context = head.context
        promptSources = head.promptSources
        childStates = Dictionary(uniqueKeysWithValues: head.childStates.map { ($0.childID, $0) })
        recovery = head.recovery
        unknowns = head.unknowns
        corruption = head.corruption
        contextManifestID = head.contextManifestID
        contextRequestID = head.contextRequestID
        contextModelID = head.contextModelID
        contextMeasuredBytes = head.contextMeasuredBytes
        contextDeliveredBytes = head.contextDeliveredBytes
        contextCumulativeDeliveredBytes = head.contextCumulativeDeliveredBytes
        contextOmissionCount = head.contextOmissionCount
        promptAssemblyID = head.promptAssemblyID
        compaction = head.compaction
        visibleBranchIncomplete = head.coverage.coverage(for: .messages)?.state == .sourceIncomplete
        messageTotal = head.coverage.coverage(for: .messages)?.totalCount ??
            head.messageHistory.count + head.visibleMessages.count
        attachmentTotal = head.coverage.coverage(for: .attachments)?.totalCount ?? head.attachments.count
        contextTotal = head.coverage.coverage(for: .context)?.totalCount ??
            head.context.count + head.promptSources.count
        childTotal = head.coverage.coverage(for: .children)?.totalCount ?? head.childStates.count
        recoveryTotal = head.coverage.coverage(for: .recovery)?.totalCount ?? head.recovery.count
        unknownTotal = head.coverage.unknownEventCount
        corruptionTotal = head.coverage.corruptionCount
        activeItemCount = head.coverage.activeItemCount
        physicalEventID = head.source.cursor.eventID
        physicalSequence = head.source.cursor.sequence
    }

    mutating func setPhysicalCursor(_ cursor: JournalCursor) {
        physicalEventID = cursor.eventID
        physicalSequence = cursor.sequence
    }

    mutating func append(
        event: TimelineEvent,
        result: PersistentSessionExactState.ApplyResult
    ) throws {
        physicalEventID = event.eventID
        physicalSequence = event.sequence
        let before = scalarSnapshot()
        let after = result.eventLocalSnapshot
        let source = BoundedTimelineReducerProjection.projectionEvent(event)
        let quarantined = result.changedSlots.contains { $0.contains("/quarantine/") }
        let accepted = after.lastSequence > semanticSequence

        session = after.session
        lifecycle = after.lifecycle
        execution = after.execution
        attention = after.attention
        activeRun = after.activeRun
        activeTurn = after.activeTurn
        modelID = after.modelID
        semanticTip = after.semanticTip
        causalOrderValid = after.causalOrderValid
        structuralIntegrityValid = after.structuralIntegrityValid
        semanticProjectionValid = after.semanticProjectionValid
        semanticSequence = after.lastSequence

        if accepted && !quarantined {
            if before.lifecycle != after.lifecycle { lifecycleEvent = source }
            if before.activeRun != after.activeRun { currentRunEvent = source }
            if before.activeTurn != after.activeTurn { currentTurnEvent = source }
            if before.modelID != after.modelID { modelEvent = source }
            if before.attention != after.attention { attentionEvent = source }
        }

        if result.changedSlots.contains(where: { $0.contains("/message/") }) {
            try appendMessage(event: event, source: source)
        }
        if result.changedSlots.contains(where: { $0.contains("/attachment/") }) {
            try appendAttachment(event: event, source: source)
        }
        if result.changedSlots.contains(where: { $0.hasSuffix("/context") }) {
            try replaceContext(from: after, runID: event.run?.runID)
        }
        if result.changedSlots.contains(where: { $0.contains("/child/") }) {
            try appendChild(event: event, source: source)
        }
        if result.changedSlots.contains(where: { $0.contains("/recovery/") }) {
            try appendRecovery(event: event, source: source)
        }
        if result.changedSlots.contains(where: { $0.contains("/unknown/") }) {
            try appendUnknown(event: event, source: source, snapshot: after)
        }
        if result.changedSlots.contains(where: { $0.contains("/quarantine/") }) {
            // A pre-seen rejection leaves the semantic cursor unchanged. The exact scalar keeps
            // that distinction, while this presentation row records the same structural fact.
            appendCorruption(
                event: event, source: source,
                structural: !accepted || !after.structuralIntegrityValid)
        }
        if accepted && !quarantined, event.type == TimelineEventType.sessionTipSelected {
            // The exact continuation intentionally does not reconstruct an old branch. Do not
            // publish a lone target (or duplicate a row already in messageHistory) as though it
            // were the complete visible branch; the canonical bounded head owns that richer
            // presentation. An empty, explicitly incomplete view is safer than a misleading
            // partial branch and keeps coverage counts stable across tip changes.
            visibleMessages = []
            visibleBranchIncomplete = true
        }
        if accepted && !quarantined, event.type == TimelineEventType.compaction {
            compaction = BoundedTimelineReducerProjection.digestText(after.compactionSummary)
            compactionEvent = source
        }
    }

    func finalize(source: BoundedReducerProjectionSource) throws -> BoundedSessionReducerHead {
        try BoundedTimelineReducerProjection.validateSource(source, limits: limits)
        guard source.cursor.eventID == physicalEventID,
              source.cursor.sequence == physicalSequence else {
            throw BoundedTimelineReducerProjectionError.invalidCursor
        }
        let retainedAttachments = Array(attachments.values).sorted {
            if $0.isAttached != $1.isAttached { return $0.isAttached }
            let lhs = $0.sourceEvent?.sequence ?? -1
            let rhs = $1.sourceEvent?.sequence ?? -1
            return lhs == rhs ? $0.attachment.attachmentID < $1.attachment.attachmentID : lhs > rhs
        }
        let retainedChildren = Array(childStates.values).sorted { lhs, rhs in
            let l = BoundedTimelineReducerProjection.classifyChildState(lhs.state.rawValue)
            let r = BoundedTimelineReducerProjection.classifyChildState(rhs.state.rawValue)
            if l != r { return l.rawValue < r.rawValue }
            return lhs.childID < rhs.childID
        }
        let retainedRecovery = Array(recovery.suffix(limits.maximumRecoveryClaims))
        let retainedUnknowns = Array(unknowns.suffix(limits.maximumUnknowns))
        let retainedCorruption = Array(corruption.suffix(limits.maximumCorruptionRecords))
        let retainedActive = retainedAttachments.filter(\.isAttached).count
            + retainedChildren.filter {
                BoundedTimelineReducerProjection.classifyChildState($0.state.rawValue) == .running
                    || BoundedTimelineReducerProjection.classifyChildState($0.state.rawValue) == .unknown
            }.count
        let activeOmitted = retainedActive < activeItemCount
        let missingSource = missingSourceEvidence(
            attachments: retainedAttachments, history: messageHistory, visible: visibleMessages,
            context: context, promptSources: promptSources, children: retainedChildren,
            recovery: retainedRecovery, corruption: retainedCorruption)
        var omissions: [BoundedReducerProjectionOmission] = []
        BoundedTimelineReducerProjection.appendOmission(
            &omissions, .attachments, attachmentTotal, retainedAttachments.count)
        BoundedTimelineReducerProjection.appendOmission(
            &omissions, .messages, messageTotal, messageHistory.count + visibleMessages.count)
        BoundedTimelineReducerProjection.appendOmission(
            &omissions, .context, contextTotal, context.count + promptSources.count)
        BoundedTimelineReducerProjection.appendOmission(
            &omissions, .children, childTotal, retainedChildren.count)
        BoundedTimelineReducerProjection.appendOmission(
            &omissions, .recovery, recoveryTotal, retainedRecovery.count)
        BoundedTimelineReducerProjection.appendOmission(
            &omissions, .unknowns, unknownTotal, retainedUnknowns.count)
        BoundedTimelineReducerProjection.appendOmission(
            &omissions, .corruption, corruptionTotal, retainedCorruption.count)
        let indexes = [
            BoundedTimelineReducerProjection.makeIndexCoverage(
                .attachments, total: attachmentTotal, retained: retainedAttachments.count,
                state: retainedAttachments.contains(where: { $0.sourceEvent == nil }) ? .sourceIncomplete : nil),
            BoundedTimelineReducerProjection.makeIndexCoverage(
                .messages, total: messageTotal,
                retained: messageHistory.count + visibleMessages.count,
                state: (visibleBranchIncomplete
                    || (visibleMessages.isEmpty && semanticTip != nil)) ? .sourceIncomplete : nil),
            BoundedTimelineReducerProjection.makeIndexCoverage(
                .context, total: contextTotal, retained: context.count + promptSources.count,
                state: context.contains(where: { $0.sourceProvenance == nil })
                    || promptSources.contains(where: { $0.provenance == nil }) ? .sourceIncomplete : nil),
            BoundedTimelineReducerProjection.makeIndexCoverage(
                .children, total: childTotal, retained: retainedChildren.count),
            BoundedTimelineReducerProjection.makeIndexCoverage(
                .recovery, total: recoveryTotal, retained: retainedRecovery.count),
            BoundedTimelineReducerProjection.makeIndexCoverage(
                .unknowns, total: unknownTotal, retained: retainedUnknowns.count,
                state: unknownTotal > 0 ? .sourceIncomplete : nil),
            BoundedTimelineReducerProjection.makeIndexCoverage(
                .corruption, total: corruptionTotal, retained: retainedCorruption.count,
                state: corruptionTotal > 0 ? .requiresRebuild : nil),
        ]
        let scalarState = BoundedTimelineReducerProjection.scalarState(
            snapshotCausalOrderValid: causalOrderValid,
            snapshotStructuralIntegrityValid: structuralIntegrityValid,
            snapshotSemanticProjectionValid: semanticProjectionValid,
            corruptionCount: corruptionTotal, unknownCount: unknownTotal,
            missingSourceEvidence: missingSource, activeItemsOmitted: activeOmitted)
        let state = BoundedTimelineReducerProjection.overallState(scalar: scalarState, indexes: indexes)
        let coverage = BoundedReducerProjectionCoverage(
            state: state, scalarState: scalarState, indexCoverage: indexes, omissions: omissions,
            unknownEventCount: unknownTotal, corruptionCount: corruptionTotal,
            missingSourceEvidenceCount: missingSource, activeItemsOmitted: activeOmitted,
            activeItemCount: max(activeItemCount, retainedActive),
            retainedActiveItemCount: retainedActive, diagnostics: retainedCorruption.prefix(limits.maximumDiagnostics).map {
                BoundedReducerProjectionDiagnostic(
                    code: "reducer_corruption", reasonDigest: $0.reason.digest, sourceEvent: $0.event)
            })
        let currentRun = activeRun.map { BoundedReducerProjectionRun(run: $0, sourceEvent: currentRunEvent) }
        let currentTurn = activeTurn.map { BoundedReducerProjectionTurn(turn: $0, sourceEvent: currentTurnEvent) }
        let head = BoundedSessionReducerHead(
            schemaVersion: BoundedSessionReducerHead.schemaVersion, source: source, coverage: coverage,
            session: session, lifecycle: lifecycle, lifecycleEvent: lifecycleEvent,
            execution: execution, attention: attention, attentionEvent: attentionEvent,
            currentRun: currentRun, currentTurn: currentTurn,
            modelID: modelID.map { BoundedTimelineReducerProjection.bounded(
                $0, maxBytes: limits.maximumIdentifierBytes) }, modelEvent: modelEvent,
            attachments: retainedAttachments, messageHistory: messageHistory,
            visibleMessages: visibleMessages, context: Array(context.prefix(limits.maximumContextComponents)),
            contextManifestID: contextManifestID, contextRequestID: contextRequestID,
            contextModelID: contextModelID, contextMeasuredBytes: contextMeasuredBytes,
            contextDeliveredBytes: contextDeliveredBytes,
            contextCumulativeDeliveredBytes: contextCumulativeDeliveredBytes,
            contextOmissionCount: contextOmissionCount, promptAssemblyID: promptAssemblyID,
            promptSources: Array(promptSources.prefix(limits.maximumPromptSources)), compaction: compaction,
            compactionEvent: compactionEvent, childStates: retainedChildren,
            recovery: retainedRecovery, unknowns: retainedUnknowns, corruption: retainedCorruption,
            semanticTip: semanticTip, lastEventID: source.cursor.eventID,
            lastSequence: source.cursor.sequence, causalOrderValid: causalOrderValid,
            structuralIntegrityValid: structuralIntegrityValid,
            semanticProjectionValid: semanticProjectionValid)
        try head.validate(limits: limits)
        return head
    }

    private func scalarSnapshot() -> SessionSnapshot {
        var result = SessionSnapshot()
        result.session = session; result.lifecycle = lifecycle; result.execution = execution
        result.attention = attention; result.activeRun = activeRun; result.activeTurn = activeTurn
        result.modelID = modelID; result.semanticTip = semanticTip
        result.lastSequence = semanticSequence
        result.causalOrderValid = causalOrderValid
        result.structuralIntegrityValid = structuralIntegrityValid
        result.semanticProjectionValid = semanticProjectionValid
        return result
    }

    private mutating func appendMessage(
        event: TimelineEvent, source: BoundedReducerProjectionEvent
    ) throws {
        let role = event.type == TimelineEventType.inputAccepted
            ? ChatRole.user.rawValue : event.payload["role"]?.stringValue ?? ChatRole.assistant.rawValue
        guard let text = event.payload["text"]?.stringValue else { throw BoundedTimelineReducerProjectionError.invalidDigest }
        let parent = event.conversationParent
            ?? event.payload["conversation_parent"].flatMap { decodeTimelineValue($0) }
        let visible = role != ChatRole.assistant.rawValue || !text.isEmpty
        let row = BoundedMessageIndexRecord(
            event: source, role: BoundedTimelineReducerProjection.bounded(role, maxBytes: 256),
            text: BoundedTimelineReducerProjection.digestTextValueForRecord(text),
            conversationParent: parent, run: event.run, turn: event.turn,
            provenance: event.provenance, visible: visible)
        messageHistory.append(row)
        if messageHistory.count > limits.maximumMessages {
            messageHistory.removeFirst(messageHistory.count - limits.maximumMessages)
        }
        messageTotal += 1
        if visible {
            visibleMessages.append(row)
            if visibleMessages.count > limits.maximumMessages {
                visibleMessages.removeFirst(visibleMessages.count - limits.maximumMessages)
            }
            messageTotal += 1
        }
    }

    private mutating func appendAttachment(
        event: TimelineEvent, source: BoundedReducerProjectionEvent
    ) throws {
        guard let attachment = event.sessionAttachment else { throw BoundedTimelineReducerProjectionError.invalidIdentity }
        var value = attachments[attachment.attachmentID]
        if event.type == TimelineEventType.sessionAttached {
            guard let work = event.work else { throw BoundedTimelineReducerProjectionError.invalidIdentity }
            value = BoundedSessionAttachmentIndexRecord(
                attachment: attachment, work: work,
                capabilities: event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                isAttached: true, sourceEvent: source)
        } else {
            // An attachment may have been evicted from the bounded presentation index. Exact
            // continuation still has the authoritative typed slot, so omission here is evidence
            // of a bounded view rather than a reducer failure.
            guard let prior = value else { return }
            var cursor = prior.cursor
            var capabilities = Set(prior.capabilities)
            var attached = prior.isAttached
            switch event.type {
            case TimelineEventType.sessionDetached:
                attached = false
            case TimelineEventType.sessionAttachmentCapabilityChanged:
                guard let values = event.payload["capabilities"]?.arrayValue?.compactMap(\.stringValue)
                else { throw BoundedTimelineReducerProjectionError.invalidDigest }
                capabilities = Set(values)
            case TimelineEventType.sessionAttachmentCursorAdvanced:
                guard let decoded: JournalCursor = event.payload["cursor"].flatMap({ decodeTimelineValue($0) })
                else { throw BoundedTimelineReducerProjectionError.invalidDigest }
                cursor = decoded
            default: break
            }
            value = BoundedSessionAttachmentIndexRecord(
                attachment: prior.attachment, work: prior.work, cursor: cursor,
                capabilities: Array(capabilities), isAttached: attached, sourceEvent: source)
        }
        guard let value else { throw BoundedTimelineReducerProjectionError.invalidIdentity }
        if attachments[value.attachment.attachmentID] == nil {
            attachmentTotal += 1
            if attachments.count >= limits.maximumAttachments {
                if value.isAttached { activeItemCount += 1 }
                return
            }
        }
        attachments[value.attachment.attachmentID] = value
        activeItemCount = max(activeItemCount, attachments.values.filter(\.isAttached).count)
    }

    private mutating func replaceContext(from snapshot: SessionSnapshot, runID: String?) throws {
        context = snapshot.contextComponents.map {
            BoundedContextIndexRecord(component: $0,
                                      maximumIdentifierBytes: limits.maximumIdentifierBytes,
                                      maximumTextBytes: limits.maximumTextBytes)
        }.sorted { ($0.inclusionID, $0.componentID) < ($1.inclusionID, $1.componentID) }
        promptSources = (snapshot.contextPromptSources ?? []).map {
            BoundedPromptSourceIndexRecord(source: $0,
                                           maximumIdentifierBytes: limits.maximumIdentifierBytes,
                                           maximumTextBytes: limits.maximumTextBytes)
        }.sorted { ($0.inclusionID, $0.sourceID) < ($1.inclusionID, $1.sourceID) }
        contextTotal = context.count + promptSources.count
        if let manifest = snapshot.contextManifest {
            contextManifestID = manifest.manifestID; contextRequestID = manifest.requestID
            contextModelID = manifest.modelID; contextMeasuredBytes = manifest.measuredBytes
            contextDeliveredBytes = manifest.deliveredBytes
            contextOmissionCount = manifest.omissions.count
            // The cumulative counter is scoped by Run. Never select an arbitrary dictionary
            // value when the event does not carry that identity; doing so would make a bounded
            // presentation depend on map iteration order across independent Runs.
            contextCumulativeDeliveredBytes = runID.flatMap {
                snapshot.contextCumulativeDeliveredBytesByRun?[$0]
            }
        } else {
            contextManifestID = nil; contextRequestID = nil; contextModelID = nil
            contextMeasuredBytes = nil; contextDeliveredBytes = nil
            contextCumulativeDeliveredBytes = nil; contextOmissionCount = 0
        }
        promptAssemblyID = snapshot.contextPromptAssemblyID
    }

    private mutating func appendChild(
        event: TimelineEvent, source: BoundedReducerProjectionEvent
    ) throws {
        guard let id = event.payload["child_id"]?.stringValue,
              let state = event.payload["state"]?.stringValue else {
            throw BoundedTimelineReducerProjectionError.invalidIdentity
        }
        let row = BoundedChildIndexRecord(childID: id, state: state, sourceEvent: source)
        if childStates[id] == nil {
            childTotal += 1
            if row.state == .running || row.state == .unknown { activeItemCount += 1 }
            guard childStates.count < limits.maximumChildren else { return }
        }
        childStates[id] = row
    }

    private mutating func appendRecovery(
        event: TimelineEvent, source: BoundedReducerProjectionEvent
    ) throws {
        guard let coverage = decodeRecoveryCoverage(event.payload) else {
            throw BoundedTimelineReducerProjectionError.invalidDigest
        }
        recovery.append(BoundedRecoveryIndexRecord(coverage: coverage, sourceEvent: source, run: event.run))
        recoveryTotal += 1
        if recovery.count > limits.maximumRecoveryClaims {
            recovery.removeFirst(recovery.count - limits.maximumRecoveryClaims)
        }
    }

    private mutating func appendUnknown(
        event: TimelineEvent, source: BoundedReducerProjectionEvent, snapshot: SessionSnapshot
    ) throws {
        guard let data = try? BoundedTimelineReducerProjection.canonicalJSON(event.payload) else {
            throw BoundedTimelineReducerProjectionError.invalidDigest
        }
        let payload = BoundedReducerProjectionDigest(
            byteCount: data.count,
            digest: "sha256:" + AviarySHA256.hash(data: data).description)
        unknowns.append(BoundedUnknownIndexRecord(
            event: source, journalOffset: max(0, snapshot.lastSequence - 1), type: "unknown",
            affectedDomains: Array(event.declaredDomains.isEmpty ? Set(TimelineDomain.allCases) : event.declaredDomains),
            payload: payload))
        unknownTotal += 1
        if unknowns.count > limits.maximumUnknowns {
            unknowns.removeFirst(unknowns.count - limits.maximumUnknowns)
        }
    }

    private mutating func appendCorruption(
        event: TimelineEvent, source: BoundedReducerProjectionEvent, structural: Bool
    ) {
        let eventEvidence = event.journal == source.reference.journal ? source : nil
        let reason = BoundedTimelineReducerProjection.digestTextValueForRecord(
            structural ? "structural" : "semantic")
        corruption.append(BoundedCorruptionIndexRecord(event: eventEvidence, reason: reason))
        corruptionTotal += 1
        if corruption.count > limits.maximumCorruptionRecords {
            corruption.removeFirst(corruption.count - limits.maximumCorruptionRecords)
        }
    }

    private func missingSourceEvidence(
        attachments: [BoundedSessionAttachmentIndexRecord],
        history: [BoundedMessageIndexRecord], visible: [BoundedMessageIndexRecord],
        context: [BoundedContextIndexRecord], promptSources: [BoundedPromptSourceIndexRecord],
        children: [BoundedChildIndexRecord], recovery: [BoundedRecoveryIndexRecord],
        corruption: [BoundedCorruptionIndexRecord]
    ) -> Int {
        var count = 0
        if lifecycle != .unknown && lifecycleEvent == nil { count += 1 }
        if activeRun != nil && currentRunEvent == nil { count += 1 }
        if activeTurn != nil && currentTurnEvent == nil { count += 1 }
        if modelID != nil && modelEvent == nil { count += 1 }
        if attention != .none && attentionEvent == nil { count += 1 }
        count += attachments.filter { $0.sourceEvent == nil }.count
        count += history.filter { $0.event.reference.eventID.isEmpty }.count
        count += visible.filter { $0.event.reference.eventID.isEmpty }.count
        count += context.filter { $0.sourceProvenance == nil }.count
        count += promptSources.filter { $0.provenance == nil }.count
        count += children.filter { $0.sourceEvent == nil }.count
        count += recovery.filter { $0.sourceEvent == nil }.count
        count += corruption.filter { $0.event == nil }.count
        return count
    }
}
