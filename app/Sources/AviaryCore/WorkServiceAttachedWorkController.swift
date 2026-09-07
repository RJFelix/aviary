import Foundation

// MARK: - Attached Work controller

/// The durable identities a GUI must already possess before it can observe one Work.
///
/// The `created` form is intentionally made from the complete host response: Work, Session,
/// and both attachment identities are host minted. The `existing` form requires the caller to
/// provide the exact client attachment it received from the host. Neither form permits a caller
/// to guess a Session from a Work id or to derive a new attachment locally.
public enum WorkServiceAttachedWorkSeed: Sendable, Hashable {
    case created(WorkServiceCreateWorkResponse)
    case existing(work: WorkServiceWorkDescriptor, attachment: WorkServiceClientAttachment)

    public var work: WorkServiceWorkDescriptor {
        switch self {
        case .created(let response): return response.work
        case .existing(let work, _): return work
        }
    }

    public var attachment: WorkServiceClientAttachment {
        switch self {
        case .created(let response): return response.attachment
        case .existing(_, let attachment): return attachment
        }
    }

    public var client: ClientRef { attachment.client }

    public var session: SessionRef? { attachment.session }
    public var sessionJournal: JournalRef? { attachment.sessionJournal }
    public var sessionAttachment: SessionAttachmentRef? { attachment.sessionAttachment }
}

/// A connection can be healthy while its canonical read is incomplete. Keeping those facts in
/// separate fields prevents a GUI from treating “socket connected” as “state recovered.”
public enum WorkServiceAttachedWorkConnectivity: Equatable, Hashable, Sendable {
    case disconnected
    case discovering
    case connecting(WorkHostRef)
    case connected(WorkHostInstanceRef?)
    case reconnecting(WorkHostRef?)
    case unavailable(WorkHostRef?)
    case incompatible(WorkHostRef?)
}

public enum WorkServiceAttachedWorkPendingState: String, Codable, Hashable, Sendable {
    case stale
    case indeterminate
    /// The Work Host returned a correlated acceptance receipt, but the controller has not yet
    /// reduced the exact canonical command event named by that receipt. This is a read-only
    /// catch-up obligation: retrying the command would risk duplicating an already-owned effect.
    case awaitingCanonicalEvidence = "awaiting_canonical_evidence"
}

/// The only command record retained after a stale cursor or transport uncertainty. The request
/// itself remains private to the local client store; the projection exposes only the exact
/// identity, digest, and cursor needed for UI reconciliation without echoing command text.
public struct WorkServiceAttachedWorkPendingCommand: Codable, Hashable, Sendable {
    public let state: WorkServiceAttachedWorkPendingState
    public let kind: WorkServiceCommandKind
    public let commandID: String
    public let client: ClientRef
    public let attachment: ClientAttachmentRef
    public let sessionAttachment: SessionAttachmentRef?
    public let causalWorkCursor: JournalCursor
    public let expectedResultingWorkCursor: JournalCursor?
    public let expectedHostSequence: Int?
    public let valueDigest: String?

    public init(state: WorkServiceAttachedWorkPendingState,
                kind: WorkServiceCommandKind, commandID: String, client: ClientRef,
                attachment: ClientAttachmentRef,
                sessionAttachment: SessionAttachmentRef?,
                causalWorkCursor: JournalCursor,
                expectedResultingWorkCursor: JournalCursor? = nil,
                expectedHostSequence: Int? = nil,
                valueDigest: String?) {
        self.state = state
        self.kind = kind
        self.commandID = commandID
        self.client = client
        self.attachment = attachment
        self.sessionAttachment = sessionAttachment
        self.causalWorkCursor = causalWorkCursor
        self.expectedResultingWorkCursor = expectedResultingWorkCursor
        self.expectedHostSequence = expectedHostSequence
        self.valueDigest = valueDigest
    }
}

/// The immutable/read-only view consumed by a GUI. A source marked incomplete or a snapshot
/// carrying unknown/corrupt projection state is still visible as evidence, but `isCanonical` is
/// false and command admission will refuse to act on it.
public struct WorkServiceAttachedWorkProjection: Sendable, Hashable {
    public let descriptor: WorkServiceWorkDescriptor
    public let attachment: WorkServiceClientAttachment
    public let capabilities: Set<WorkServiceCapability>
    public let workSnapshot: WorkSnapshot
    public let sessionSnapshot: SessionSnapshot
    public let visibleMessages: [SessionMessageSnapshot]
    /// Bounded, deterministic activity projection. The reducer retains the full validated action
    /// map for incremental continuation; this array is the GUI-facing view and never exposes raw
    /// event pages or an unbounded activity list.
    public let activities: [WorkActionSnapshot]
    /// Explicit local projection omissions. A non-empty list makes `projectionComplete` false;
    /// source canonicality remains independent because omitted UI rows are still in the validated
    /// reducer/journal projection.
    public let projectionOmissions: [WorkServiceOmission]
    public let projectionComplete: Bool
    public let workCursor: JournalCursor
    public let sessionCursor: JournalCursor
    public let workSourceCompleteness: WorkServiceSourceCompleteness
    public let sessionSourceCompleteness: WorkServiceSourceCompleteness
    public let workOmissions: [WorkServiceOmission]
    public let sessionOmissions: [WorkServiceOmission]
    public let workUnknownEvents: [UnknownTimelineEvent]
    public let sessionUnknownEvents: [UnknownTimelineEvent]
    public let workCorruptionReasons: [String]
    public let sessionCorruptionReasons: [String]
    /// Bounded controller-level validation/read failures. These are deliberately generic and do
    /// not echo remote error descriptions, paths, credentials, or command bodies.
    public let readDiagnostics: [String]
    public let connectivity: WorkServiceAttachedWorkConnectivity
    public let pendingCommand: WorkServiceAttachedWorkPendingCommand?
    public let lastReceipt: WorkServiceCommandReceipt?
    /// A correlated command receipt names canonical Work state this projection has not reduced
    /// yet. This is ordinary catch-up, not a recovery failure, but mutation must wait for refresh.
    public let requiresRefresh: Bool
    public let isCanonical: Bool
    public let needsRecovery: Bool

    public init(
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        capabilities: Set<WorkServiceCapability>,
        workSnapshot: WorkSnapshot,
        sessionSnapshot: SessionSnapshot,
        workCursor: JournalCursor,
        sessionCursor: JournalCursor,
        workSourceCompleteness: WorkServiceSourceCompleteness,
        sessionSourceCompleteness: WorkServiceSourceCompleteness,
        workOmissions: [WorkServiceOmission] = [],
        sessionOmissions: [WorkServiceOmission] = [],
        readDiagnostics: [String] = [],
        connectivity: WorkServiceAttachedWorkConnectivity = .disconnected,
        pendingCommand: WorkServiceAttachedWorkPendingCommand? = nil,
        lastReceipt: WorkServiceCommandReceipt? = nil,
        requiresRefresh: Bool = false
    ) {
        self.descriptor = descriptor
        self.attachment = attachment
        self.capabilities = capabilities
        self.workSnapshot = workSnapshot
        self.sessionSnapshot = sessionSnapshot
        let orderedActivities = workSnapshot.actions.values.sorted { lhs, rhs in
            let lhsSequence = lhs.intentEvent?.sequence ?? lhs.startedEvent?.sequence
                ?? lhs.outcomeEvent?.sequence ?? Int.max
            let rhsSequence = rhs.intentEvent?.sequence ?? rhs.startedEvent?.sequence
                ?? rhs.outcomeEvent?.sequence ?? Int.max
            if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
            return lhs.action.actionID < rhs.action.actionID
        }
        let activityProjection = WorkActionPresentation.projectWithOmissions(orderedActivities)
        let activityLimit = Self.maxActivities
        let messageLimit = Self.maxMessages
        self.activities = WorkActionPresentation.retainedSnapshots(
            orderedActivities, limit: activityLimit)
        var retainedMessages: [SessionMessageSnapshot] = []
        var retainedMessageBytes = 0
        for message in sessionSnapshot.messages.reversed() {
            let messageBytes = message.text.utf8.count
            guard retainedMessages.count < messageLimit,
                  messageBytes <= Self.maxMessageBytes - retainedMessageBytes else {
                break
            }
            retainedMessages.insert(message, at: 0)
            retainedMessageBytes += messageBytes
        }
        self.visibleMessages = retainedMessages
        var localOmissions: [WorkServiceOmission] = []
        if activityProjection.omittedUnsettledCount > 0 {
            localOmissions.append(WorkServiceOmission(
                category: "active_activities", count: activityProjection.omittedUnsettledCount,
                diagnostic: "active activity count exceeded the display bound; omitted activities remain addressable through the canonical journal"))
        }
        if activityProjection.omittedTerminalCount > 0 {
            localOmissions.append(WorkServiceOmission(
                category: "activities", count: activityProjection.omittedTerminalCount,
                diagnostic: "resolved activity history is bounded; omitted activities remain addressable through the canonical journal"))
        }
        let truncatedActivities = orderedActivities.filter(\.metadataWasTruncated).count
        if truncatedActivities > 0 {
            localOmissions.append(WorkServiceOmission(
                category: "activity_metadata", count: truncatedActivities,
                diagnostic: "activity metadata exceeded the UTF-8 projection bound"))
        }
        let totalMessageBytes = sessionSnapshot.messages.reduce(into: 0) { total, message in
            let remaining = Int.max - total
            total += min(remaining, message.text.utf8.count)
        }
        if sessionSnapshot.messages.count > retainedMessages.count {
            let omittedBytes = max(0, totalMessageBytes - retainedMessageBytes)
            localOmissions.append(WorkServiceOmission(
                category: "messages", count: sessionSnapshot.messages.count - retainedMessages.count,
                diagnostic: "message projection is bounded; omitted \(omittedBytes) UTF-8 bytes remain addressable through the canonical journal"))
        }
        self.projectionOmissions = Array(localOmissions.prefix(Self.maxOmissions))
        self.projectionComplete = localOmissions.isEmpty
        self.workCursor = workCursor
        self.sessionCursor = sessionCursor
        self.workSourceCompleteness = workSourceCompleteness
        self.sessionSourceCompleteness = sessionSourceCompleteness
        self.workOmissions = Array(workOmissions.prefix(Self.maxOmissions))
        self.sessionOmissions = Array(sessionOmissions.prefix(Self.maxOmissions))
        self.workUnknownEvents = Array(workSnapshot.unknownEvents.prefix(Self.maxUnknownEvents))
        self.sessionUnknownEvents = Array(sessionSnapshot.unknownEvents.prefix(Self.maxUnknownEvents))
        self.workCorruptionReasons = Array(workSnapshot.corruptionReasons.prefix(Self.maxDiagnostics))
        self.sessionCorruptionReasons = Array(sessionSnapshot.corruptionReasons.prefix(Self.maxDiagnostics))
        self.readDiagnostics = Array(readDiagnostics.prefix(Self.maxDiagnostics))
        self.connectivity = connectivity
        self.pendingCommand = pendingCommand
        self.lastReceipt = lastReceipt
        self.requiresRefresh = requiresRefresh
        let healthySnapshots = workSnapshot.structuralIntegrityValid
            && workSnapshot.semanticProjectionValid
            && sessionSnapshot.structuralIntegrityValid
            && sessionSnapshot.semanticProjectionValid
            && workSnapshot.lifecycle != .unknown
            && sessionSnapshot.lifecycle != .unknown
            && workSnapshot.quarantinedEvents.isEmpty
            && sessionSnapshot.quarantinedEvents.isEmpty
        self.isCanonical = workSourceCompleteness == .complete
            && sessionSourceCompleteness == .complete
            && !requiresRefresh
            && healthySnapshots
        self.needsRecovery = descriptor.execution == .recoveryRequired
            || descriptor.execution == .unknown
            || workSourceCompleteness != .complete
            || sessionSourceCompleteness != .complete
            || !healthySnapshots
    }

    private static let maxMessages = 512
    private static let maxMessageBytes = 256 * 1024
    private static let maxActivities = 256
    private static let maxOmissions = 32
    private static let maxUnknownEvents = 128
    private static let maxDiagnostics = 32
}

public enum WorkServiceConversationHistoryStatus: String, Codable, Hashable, Sendable {
    case ready
    case loading
    /// The last bounded page failed. Previously authenticated rows remain visible and retryable.
    case unavailable
    /// The Session selected another branch while this GUI was reading an older frozen window.
    case staleBranch
}

/// Identity-only change classification for a bounded conversation window. Text mutations from
/// streaming do not masquerade as new output, and a history prepend is disjoint from a tail
/// append even when both arrive in one observable update.
public enum WorkServiceConversationIdentityChange: Equatable, Sendable {
    case unchanged
    case prepended(count: Int, anchorID: String?)
    case appended(count: Int)
    case prependedAndAppended(prepended: Int, appended: Int, anchorID: String?)
    case replaced

    public static func classify(old: [String], new: [String]) -> Self {
        guard old != new else { return .unchanged }
        guard !old.isEmpty else { return new.isEmpty ? .unchanged : .appended(count: new.count) }
        if let start = contiguousStart(of: old, in: new) {
            let prepended = start
            let appended = new.count - start - old.count
            switch (prepended, appended) {
            case (0, 0): return .unchanged
            case (0, let tail): return .appended(count: tail)
            case (let prefix, 0): return .prepended(count: prefix, anchorID: old.first)
            case (let prefix, let tail):
                return .prependedAndAppended(
                    prepended: prefix, appended: tail, anchorID: old.first)
            }
        }
        // A bounded window can release rows from the opposite edge in the same update. Preserve
        // prepend/append semantics when the remaining rows form one exact contiguous overlap;
        // otherwise a branch or Session replacement remains `.replaced`.
        let maximumOverlap = min(old.count, new.count)
        let oldIDs = Set(old)
        if maximumOverlap > 0 {
            for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
                if new.suffix(overlap).elementsEqual(old.prefix(overlap)),
                   new.dropLast(overlap).allSatisfy({ !oldIDs.contains($0) }) {
                    let prepended = new.count - overlap
                    if prepended > 0 {
                        return .prepended(count: prepended, anchorID: old.first)
                    }
                }
                if old.suffix(overlap).elementsEqual(new.prefix(overlap)),
                   new.dropFirst(overlap).allSatisfy({ !oldIDs.contains($0) }) {
                    let appended = new.count - overlap
                    if appended > 0 { return .appended(count: appended) }
                }
            }
        }
        return .replaced
    }

    private static func contiguousStart(of old: [String], in new: [String]) -> Int? {
        guard old.count <= new.count else { return nil }
        for start in 0...(new.count - old.count) {
            if new[start..<(start + old.count)].elementsEqual(old) { return start }
        }
        return nil
    }
}

/// One GUI's bounded, read-only window over the canonical selected Session conversation.
///
/// This cursor state is intentionally disjoint from reducer, acknowledgement, and command
/// cursors. Loading or discarding presentation history cannot advance shared Work state, and two
/// GUIs may hold different windows over the same durable Session without coordinating.
public struct WorkServiceConversationHistoryWindow: Codable, Hashable, Sendable {
    public let messages: [SessionMessageSnapshot]
    public let frozenTipCursor: JournalCursor?
    public let frozenTipDigest: String?
    public let branchTip: EventRef?
    public let nextBeforeCursor: JournalCursor?
    public let hasEarlier: Bool
    public let hasNewer: Bool
    public let status: WorkServiceConversationHistoryStatus
    public let omissions: [WorkServiceOmission]
    public let generation: Int

    public init(
        messages: [SessionMessageSnapshot] = [],
        frozenTipCursor: JournalCursor? = nil,
        frozenTipDigest: String? = nil,
        branchTip: EventRef? = nil,
        nextBeforeCursor: JournalCursor? = nil,
        hasEarlier: Bool = false,
        hasNewer: Bool = false,
        status: WorkServiceConversationHistoryStatus = .ready,
        omissions: [WorkServiceOmission] = [],
        generation: Int = 0
    ) {
        self.messages = messages
        self.frozenTipCursor = frozenTipCursor
        self.frozenTipDigest = frozenTipDigest
        self.branchTip = branchTip
        self.nextBeforeCursor = nextBeforeCursor
        self.hasEarlier = hasEarlier
        self.hasNewer = hasNewer
        self.status = status
        self.omissions = Array(omissions.prefix(WorkServiceAttachedWorkControllerBounds.maxOmissions))
        self.generation = max(0, generation)
    }
}

public enum WorkServiceAttachedWorkControllerError: Error, Equatable, Sendable {
    case invalidSeed
    case invalidOptions
    case hostMismatch
    case notConnected
    case malformedResponse
    case sourceIncomplete
    case pendingCommandExists
    case noPendingCommand
    case commandNotAdmissible
    case capabilityDenied(WorkServiceCapability)
    case terminalWork
    case recoveryRequired
    case staleCursor
    case transportFailure
}

/// One GUI-side object for one Work and its durably bound Session.
///
/// The controller owns no Work process, host filesystem path, runtime host, or agent. Its local
/// durable state is limited to pending command/ack identities and reducer checkpoints needed to
/// survive GUI death. It can therefore be recreated by another GUI/device and disconnected
/// without changing Work lifecycle.
public actor WorkServiceAttachedWorkController {
    public typealias Connect = @Sendable () async throws -> WorkServiceHandshakeResponse
    public typealias Connectivity = @Sendable () async -> WorkServiceAttachedWorkConnectivity

    private struct ReadResult: Sendable {
        let cursor: JournalCursor
        let events: [TimelineEvent]
        let descriptor: WorkServiceWorkDescriptor
        let sourceCompleteness: WorkServiceSourceCompleteness
        let omissions: [WorkServiceOmission]
        let basePrefixDigest: String?
        let prefixDigest: String?
    }

    private enum StagedSnapshot: Sendable {
        case work(WorkSnapshot)
        case session(SessionSnapshot)
    }

    /// Pages beyond the per-refresh budget are retained as a controller-owned continuation.
    /// The committed reducer/cursors never move until both targets have a complete, validated
    /// prefix.  Only the incrementally reduced snapshot is retained; raw event history is never
    /// accumulated in memory or in the durable checkpoint.
    private struct StagedRead: Sendable {
        let cursor: JournalCursor
        let snapshot: StagedSnapshot
        let descriptor: WorkServiceWorkDescriptor
        let omissions: [WorkServiceOmission]
        let prefixDigest: String?
    }

    private struct ReadAcknowledgementKey: Hashable, Sendable {
        let targetJournal: JournalRef
        let cursor: JournalCursor
    }

    /// An acknowledgement that crossed the transport boundary but whose response was not
    /// correlated.  A later descriptor read can prove it committed; until then it is never
    /// replayed automatically.  This protects a lost response from becoming a duplicate control
    /// mutation after reconnect/restart.
    private struct PendingReadAcknowledgement: Sendable {
        let request: WorkServiceAcknowledgeReadRequest
        var stale: Bool

        var key: ReadAcknowledgementKey {
            ReadAcknowledgementKey(targetJournal: request.target.journal, cursor: request.cursor)
        }
    }

    private enum ReadKind: Sendable, Equatable {
        case work
        case session
    }

    private struct PendingInternal: Sendable {
        let request: WorkServiceCommandRequest
        var state: WorkServiceAttachedWorkPendingState
        var expectedResultingWorkCursor: JournalCursor?
        var expectedHostSequence: Int?

        var projection: WorkServiceAttachedWorkPendingCommand {
            WorkServiceAttachedWorkPendingCommand(
                state: state, kind: request.kind, commandID: request.command.commandID,
                client: request.command.client!, attachment: request.attachment,
                sessionAttachment: request.command.sessionAttachment,
                causalWorkCursor: request.causalWorkCursor,
                expectedResultingWorkCursor: expectedResultingWorkCursor,
                expectedHostSequence: expectedHostSequence,
                valueDigest: WorkServiceAttachedWorkController.valueDigest(request.value))
        }
    }

    public let client: ClientRef
    public let work: WorkRef
    /// Stable identity of this GUI's exact client attachment to the Work/Session relationship.
    public let serviceAttachmentKey: ServiceAttachmentKey

    private let service: any WorkServiceClient
    private let connectIfNeeded: Connect?
    private let connectivityProvider: Connectivity?
    private let pageLimit: Int
    private let pageBytes: Int
    private let journal: JournalRef
    private let session: SessionRef
    private let sessionJournal: JournalRef
    private let sessionAttachment: SessionAttachmentRef
    private let intentStore: WorkServiceAttachedWorkIntentStore
    private let checkpointStore: any WorkServiceAttachedWorkCheckpointStoring

    private var descriptorStorage: WorkServiceWorkDescriptor
    private var attachmentStorage: WorkServiceClientAttachment
    /// The last canonical attachment projection may remain visible when a later bounded catalog
    /// omits the row, but it must not retain mutation authority until the exact row is observed
    /// again.
    private var attachmentActionableStorage = true
    private var workSnapshotStorage = WorkSnapshot()
    private var sessionSnapshotStorage = SessionSnapshot()
    private var workCursorStorage: JournalCursor
    private var sessionCursorStorage: JournalCursor
    private var workCompletenessStorage: WorkServiceSourceCompleteness = .unknown
    private var sessionCompletenessStorage: WorkServiceSourceCompleteness = .unknown
    private var workOmissionsStorage: [WorkServiceOmission] = []
    private var sessionOmissionsStorage: [WorkServiceOmission] = []
    private var readDiagnosticsStorage: [String] = []
    private var connectivityStorage: WorkServiceAttachedWorkConnectivity = .disconnected
    private var pendingStorage: PendingInternal?
    /// The Work Host control cursor is independent from both read cursors. It is advanced only
    /// from a validated handshake or acknowledgement receipt, then chained into the next
    /// acknowledgement request.
    private var controlCursorStorage: JournalCursor?
    private var workPrefixDigestStorage: String?
    private var sessionPrefixDigestStorage: String?
    private var stagedWorkReadStorage: StagedRead?
    private var stagedSessionReadStorage: StagedRead?
    private var pendingReadAcknowledgementsStorage: [ReadAcknowledgementKey: PendingReadAcknowledgement] = [:]
    /// A restored reducer checkpoint is kept out of all public projection fields until the host
    /// has returned matching base-prefix digests for both journals.  Once the first validated
    /// read starts, its reduced state moves into the in-memory staging slots below.
    private var restoredCheckpointStorage: WorkServiceAttachedWorkCheckpointStore.Record?
    private var lastCheckpointRecordStorage: WorkServiceAttachedWorkCheckpointStore.Record?
    private var checkpointPersistenceAvailableStorage = true
    /// A disk checkpoint is useful only as a reducer starting point.  Until the first host read
    /// proves both exact base-prefix digests, its bytes remain diagnostic cache content and are
    /// forced noncanonical even when the serialized reducer is internally consistent.
    private var checkpointAwaitingHostValidationStorage = false
    private var lastReceiptStorage: WorkServiceCommandReceipt?
    private var requiredWorkCursorStorage: JournalCursor?
    private var requiresRefreshStorage = false
    private var refreshInProgress = false
    private var historyStorage = WorkServiceConversationHistoryWindow()
    private var historyReadInProgress = false
    private var historyBrowsingOlderStorage = false

    /// Construct from any transport implementation. For a ``WorkServiceClientSession``, use the
    /// convenience initializer below so refresh can explicitly establish/re-establish its socket.
    public init(
        service: any WorkServiceClient,
        seed: WorkServiceAttachedWorkSeed,
        intentStore: WorkServiceAttachedWorkIntentStore,
        pageLimit: Int = WorkServiceBounds.maxEventsPerPage,
        pageBytes: Int = WorkServiceBounds.maxEventPageBytes,
        connect: Connect? = nil,
        connectivity: Connectivity? = nil,
        checkpointStore: (any WorkServiceAttachedWorkCheckpointStoring)? = nil
    ) throws {
        try Self.validateSeed(seed)
        guard pageLimit > 0, pageLimit <= WorkServiceBounds.maxEventsPerPage,
              pageBytes > 0, pageBytes <= WorkServiceBounds.maxEventPageBytes else {
            throw WorkServiceAttachedWorkControllerError.invalidOptions
        }
        let descriptor = seed.work
        let attachment = seed.attachment
        let initiallyListed = descriptor.attachments.contains {
            $0.attachment == attachment.attachment
        }
        guard let session = attachment.session,
              let sessionJournal = attachment.sessionJournal,
              let sessionAttachment = attachment.sessionAttachment else {
            throw WorkServiceAttachedWorkControllerError.invalidSeed
        }
        guard let serviceAttachmentKey = ServiceAttachmentKey(
            client: attachment.client, clientAttachment: attachment.attachment,
            work: descriptor.work, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment) else {
            throw WorkServiceAttachedWorkControllerError.invalidSeed
        }
        if let storeKey = intentStore.serviceAttachmentKey, storeKey != serviceAttachmentKey {
            throw WorkServiceAttachedWorkControllerError.invalidSeed
        }
        let restored: PendingInternal?
        do {
            restored = try intentStore.load().map {
                try Self.validateRestoredPending(
                    $0, descriptor: descriptor, attachment: attachment,
                    sessionAttachment: sessionAttachment)
                return PendingInternal(
                    request: $0.request, state: $0.state,
                    expectedResultingWorkCursor: $0.expectedResultingWorkCursor,
                    expectedHostSequence: $0.expectedHostSequence)
            }
        } catch let error as WorkServiceAttachedWorkControllerError {
            throw error
        } catch {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        let resolvedCheckpointStore: any WorkServiceAttachedWorkCheckpointStoring
        if let checkpointStore {
            resolvedCheckpointStore = checkpointStore
        } else if intentStore.serviceAttachmentKey != nil {
            resolvedCheckpointStore = try WorkServiceAttachedWorkCheckpointStore(
                url: intentStore.checkpointURL, key: serviceAttachmentKey)
        } else {
            // The unkeyed constructor is internal test injection only. All production-created
            // intent stores carry serviceAttachmentKey and take the keyed branch above.
            resolvedCheckpointStore = try WorkServiceAttachedWorkCheckpointStore(
                url: intentStore.checkpointURL)
        }
        let persistedCheckpoint: WorkServiceAttachedWorkCheckpointStore.Record?
        let checkpointReadFailed: Bool
        do {
            persistedCheckpoint = try resolvedCheckpointStore.load()
            checkpointReadFailed = false
        } catch {
            persistedCheckpoint = nil
            checkpointReadFailed = true
        }
        let usableCheckpoint: WorkServiceAttachedWorkCheckpointStore.Record?
        if let persistedCheckpoint,
           Self.validCheckpoint(
               persistedCheckpoint, descriptor: descriptor, attachment: attachment,
               session: session, sessionJournal: sessionJournal,
               sessionAttachment: sessionAttachment) {
            usableCheckpoint = persistedCheckpoint
        } else {
            usableCheckpoint = nil
        }
        // Pending acknowledgement requests may be retained by a compact checkpoint even when it
        // deliberately omits reducer snapshots.  They are safe to restore because the request
        // identity is validated below; the missing reducer state merely forces a source replay.
        let checkpointWithValidMetadata = persistedCheckpoint.flatMap {
            Self.validCheckpointMetadata(
                $0, descriptor: descriptor, attachment: attachment,
                session: session, sessionJournal: sessionJournal,
                sessionAttachment: sessionAttachment) ? $0 : nil
        }
        var restoredPendingReadAcknowledgements: [ReadAcknowledgementKey: PendingReadAcknowledgement] = [:]
        if let checkpoint = checkpointWithValidMetadata {
            for pending in checkpoint.pendingAcknowledgements {
                let key = ReadAcknowledgementKey(
                    targetJournal: pending.request.target.journal,
                    cursor: pending.request.cursor)
                guard restoredPendingReadAcknowledgements[key] == nil else {
                    // Treat duplicate keys as a corrupt cache. The durable source remains
                    // authoritative and the controller will safely reread from its seed.
                    restoredPendingReadAcknowledgements.removeAll()
                    break
                }
                restoredPendingReadAcknowledgements[key] = PendingReadAcknowledgement(
                    request: pending.request, stale: pending.stale)
            }
        }
        let initialControlCursor = checkpointWithValidMetadata?.controlCursor ?? {
            switch seed {
            case .created(let response): return response.controlCursor
            case .existing: return nil
            }
        }()
        self.service = service
        self.client = attachment.client
        self.work = descriptor.work
        self.serviceAttachmentKey = serviceAttachmentKey
        self.connectIfNeeded = connect
        self.connectivityProvider = connectivity
        self.pageLimit = pageLimit
        self.pageBytes = pageBytes
        self.journal = descriptor.journal
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.intentStore = intentStore
        self.checkpointStore = resolvedCheckpointStore
        // Never expose restored reducer bytes through the initial projection.  The seed is the
        // caller-provided identity envelope, while reducer state starts at the safe baseline until
        // a fresh host read proves each checkpoint cursor/prefix pair.
        self.descriptorStorage = descriptor
        self.attachmentStorage = attachment
        self.attachmentActionableStorage = initiallyListed
        self.workCursorStorage = JournalCursor(journal: descriptor.journal, sequence: 0)
        self.sessionCursorStorage = JournalCursor(journal: sessionJournal, sequence: 0)
        self.workSnapshotStorage = WorkSnapshot()
        self.workSnapshotStorage.journal = descriptor.journal
        self.workSnapshotStorage.work = descriptor.work
        self.workSnapshotStorage.workHost = WorkHostRef(descriptor.work.workHostID)
        self.sessionSnapshotStorage = SessionSnapshot()
        self.sessionSnapshotStorage.journal = sessionJournal
        self.sessionSnapshotStorage.session = session
        self.pendingStorage = restored
        self.controlCursorStorage = initialControlCursor
        self.workPrefixDigestStorage = nil
        self.sessionPrefixDigestStorage = nil
        self.restoredCheckpointStorage = usableCheckpoint
        self.lastCheckpointRecordStorage = checkpointWithValidMetadata
        self.checkpointPersistenceAvailableStorage = true
        self.checkpointAwaitingHostValidationStorage = usableCheckpoint != nil
        self.pendingReadAcknowledgementsStorage = restoredPendingReadAcknowledgements
        if let restored,
           restored.state == .awaitingCanonicalEvidence,
           let expected = restored.expectedResultingWorkCursor {
            self.requiredWorkCursorStorage = expected
            self.requiresRefreshStorage = true
        }
        if checkpointReadFailed || (persistedCheckpoint != nil && checkpointWithValidMetadata == nil) {
            self.readDiagnosticsStorage = [
                "The local reducer checkpoint was unavailable; journal history will be revalidated from its seed cursor."
            ]
        }
    }

    /// Convenience constructor for the normal GUI path. The client id comes from the exact
    /// attachment rather than from a separately supplied or guessed identity.
    public init(
        session: WorkServiceClientSession,
        seed: WorkServiceAttachedWorkSeed,
        intentStore: WorkServiceAttachedWorkIntentStore,
        pageLimit: Int = WorkServiceBounds.maxEventsPerPage,
        pageBytes: Int = WorkServiceBounds.maxEventPageBytes
    ) throws {
        try self.init(
            service: session, seed: seed, intentStore: intentStore,
            pageLimit: pageLimit, pageBytes: pageBytes,
            connect: { try await session.refreshHandshake() },
            connectivity: { Self.map(await session.state) })
    }

    /// Return the current immutable projection. Reads are actor-isolated and safe to hand to a
    /// SwiftUI task without exposing mutable reducer state.
    public func projection() -> WorkServiceAttachedWorkProjection {
        WorkServiceAttachedWorkProjection(
            descriptor: descriptorStorage, attachment: attachmentStorage,
            capabilities: attachmentActionableStorage
                ? attachmentStorage.authorization.granted : [],
            workSnapshot: workSnapshotStorage, sessionSnapshot: sessionSnapshotStorage,
            workCursor: workCursorStorage, sessionCursor: sessionCursorStorage,
            workSourceCompleteness: !attachmentActionableStorage
                ? .incomplete : (checkpointAwaitingHostValidationStorage ? .unknown
                    : workCompletenessStorage),
            sessionSourceCompleteness: !attachmentActionableStorage
                ? .incomplete : (checkpointAwaitingHostValidationStorage ? .unknown
                    : sessionCompletenessStorage),
            workOmissions: workOmissionsStorage, sessionOmissions: sessionOmissionsStorage,
            readDiagnostics: readDiagnosticsStorage,
            connectivity: connectivityStorage,
            pendingCommand: pendingStorage?.projection, lastReceipt: lastReceiptStorage,
            requiresRefresh: requiresRefreshStorage)
    }

    /// Read and atomically publish the newest complete pair of Work and Session projections.
    /// A source error leaves the prior pair/cursors untouched and marks its source incomplete.
    @discardableResult
    public func refresh() async throws -> WorkServiceAttachedWorkProjection {
        guard !refreshInProgress else { return projection() }
        refreshInProgress = true
        defer { refreshInProgress = false }

        do {
            let handshake = try await establishConnectionIfNeeded()
            if let handshake {
                guard Self.validHandshake(
                    handshake, expectedHost: WorkHostRef(work.workHostID)) else {
                    throw WorkServiceAttachedWorkControllerError.hostMismatch
                }
                controlCursorStorage = handshake.controlCursor
                connectivityStorage = .connected(handshake.hostInstance)
            } else {
                connectivityStorage = .connected(descriptorStorage.hostObservation?.instance)
                // Existing seeds do not carry a control cursor. A direct loopback service can
                // still provide one through handshake; failure here is nonfatal because reads
                // remain useful even when this transport does not expose control-plane state.
                if controlCursorStorage == nil {
                    await discoverControlCursor()
                }
            }

            let service = self.service
            // A restored record is an internal reducer seed only.  It is never read through
            // `projection()`; the first successful pair of host reads must prove its exact base
            // prefix digests before this state can be published.
            let restoredCheckpoint = self.restoredCheckpointStorage
            let restoredWorkStage = restoredCheckpoint.flatMap { checkpoint -> StagedRead? in
                guard let cursor = checkpoint.stagedWorkCursor,
                      let snapshot = checkpoint.stagedWorkSnapshot else { return nil }
                return StagedRead(
                    cursor: cursor, snapshot: .work(snapshot), descriptor: checkpoint.descriptor,
                    omissions: checkpoint.stagedWorkOmissions,
                    prefixDigest: checkpoint.stagedWorkPrefixDigest)
            }
            let restoredSessionStage = restoredCheckpoint.flatMap { checkpoint -> StagedRead? in
                guard let cursor = checkpoint.stagedSessionCursor,
                      let snapshot = checkpoint.stagedSessionSnapshot else { return nil }
                return StagedRead(
                    cursor: cursor, snapshot: .session(snapshot), descriptor: checkpoint.descriptor,
                    omissions: checkpoint.stagedSessionOmissions,
                    prefixDigest: checkpoint.stagedSessionPrefixDigest)
            }
            let descriptor = restoredCheckpoint?.descriptor ?? self.descriptorStorage
            let attachment = restoredCheckpoint?.attachmentProjection ?? self.attachmentStorage
            let client = self.client
            let committedWorkCursor = restoredCheckpoint?.committedWorkCursor
                ?? self.workCursorStorage
            let committedSessionCursor = restoredCheckpoint?.committedSessionCursor
                ?? self.sessionCursorStorage
            let activeWorkStage = self.stagedWorkReadStorage ?? restoredWorkStage
            let activeSessionStage = self.stagedSessionReadStorage ?? restoredSessionStage
            let workCursor = activeWorkStage?.cursor ?? committedWorkCursor
            let sessionCursor = activeSessionStage?.cursor ?? committedSessionCursor
            let workPrefixDigest = activeWorkStage?.prefixDigest
                ?? restoredCheckpoint?.committedWorkPrefixDigest
                ?? self.workPrefixDigestStorage
            let sessionPrefixDigest = activeSessionStage?.prefixDigest
                ?? restoredCheckpoint?.committedSessionPrefixDigest
                ?? self.sessionPrefixDigestStorage
            let workSnapshot = Self.stagedWorkSnapshot(activeWorkStage)
                ?? restoredCheckpoint?.committedWorkSnapshot
                ?? self.workSnapshotStorage
            let sessionSnapshot = Self.stagedSessionSnapshot(activeSessionStage)
                ?? restoredCheckpoint?.committedSessionSnapshot
                ?? self.sessionSnapshotStorage
            let pageLimit = self.pageLimit
            let pageBytes = self.pageBytes
            // A live handshake is the transport-generation fence.  Host instance identity is
            // deliberately not persisted as part of a reducer checkpoint: a normal daemon
            // restart may mint a new instance while preserving the same journal prefixes.  A
            // direct loopback without a handshake still verifies the stable Work Host identity
            // in `validDescriptor`, but does not impose an obsolete instance from the seed.
            let expectedHostInstance = handshake?.hostInstance
            let journal = self.journal
            let session = self.session
            let sessionJournal = self.sessionJournal
            let sessionAttachment = self.sessionAttachment

            async let workRead = Self.readJournal(
                kind: .work, service: service, descriptor: descriptor, attachment: attachment,
                client: client, journal: journal, session: session,
                sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
                after: workCursor, pageLimit: pageLimit, pageBytes: pageBytes,
                expectedHostInstance: expectedHostInstance,
                expectedBasePrefixDigest: workPrefixDigest)
            async let sessionRead = Self.readJournal(
                kind: .session, service: service, descriptor: descriptor, attachment: attachment,
                client: client, journal: journal, session: session,
                sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
                after: sessionCursor, pageLimit: pageLimit, pageBytes: pageBytes,
                expectedHostInstance: expectedHostInstance,
                expectedBasePrefixDigest: sessionPrefixDigest)
            let (workDelta, sessionDelta) = try await (workRead, sessionRead)
            // Both reads returned a validated base (possibly with a page-budget continuation), so
            // the restored disk record is no longer needed as a seed.  Keep the newly reduced
            // continuation private until the paired projection commits below.
            if restoredCheckpoint != nil {
                restoredCheckpointStorage = nil
            }
            let reducedWork = try Self.reduceRead(
                workDelta, initial: workSnapshot, kind: .work, expectedCursor: workCursor)
            let reducedSession = try Self.reduceRead(
                sessionDelta, initial: sessionSnapshot, kind: .session,
                expectedCursor: sessionCursor)
            let newWork = workDelta
            let newSession = sessionDelta
            let stagedWork = StagedRead(
                cursor: newWork.cursor, snapshot: .work(reducedWork),
                descriptor: newWork.descriptor, omissions: newWork.omissions,
                prefixDigest: newWork.prefixDigest)
            let stagedSession = StagedRead(
                cursor: newSession.cursor, snapshot: .session(reducedSession),
                descriptor: newSession.descriptor, omissions: newSession.omissions,
                prefixDigest: newSession.prefixDigest)

            // A page-budget stop is a valid, validated continuation, not a permanent source
            // failure. Retain each prefix and leave the last committed pair untouched. The next
            // refresh starts at these exact cursors and can eventually publish both together.
            if newWork.sourceCompleteness != .complete
                || newSession.sourceCompleteness != .complete {
                stagedWorkReadStorage = stagedWork
                stagedSessionReadStorage = stagedSession
                workCompletenessStorage = .incomplete
                sessionCompletenessStorage = .incomplete
                workOmissionsStorage = newWork.omissions
                sessionOmissionsStorage = newSession.omissions
                appendReadDiagnostic(
                    "Work service catch-up is bounded; the next refresh will continue from the retained journal cursors.")
                _ = persistCheckpointIfPossible()
                return projection()
            }

            guard reducedWork.structuralIntegrityValid,
                  reducedWork.semanticProjectionValid,
                  reducedWork.quarantinedEvents.isEmpty,
                  reducedSession.structuralIntegrityValid,
                  reducedSession.semanticProjectionValid,
                  reducedSession.quarantinedEvents.isEmpty else {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            // Keep a complete, validated candidate durable until both read acknowledgements and
            // the paired projection commit finish. A crash at either point can then resume from
            // reducer truth rather than using a bare host acknowledgement as a skip marker.
            let descriptorsChanged = try !Self.descriptorsEquivalent(newWork.descriptor, descriptor)
            let candidateChanged = stagedWorkReadStorage != nil
                || stagedSessionReadStorage != nil
                || newWork.cursor != committedWorkCursor
                || newSession.cursor != committedSessionCursor
                || reducedWork != self.workSnapshotStorage
                || reducedSession != self.sessionSnapshotStorage
                || descriptorsChanged
            stagedWorkReadStorage = stagedWork
            stagedSessionReadStorage = stagedSession
            // A failed cache write is noncanonical and must not hide a valid remote projection,
            // but it also must not strand read acknowledgement forever. Retry the same exact
            // record on a later refresh once the local filesystem is healthy again; this remains
            // byte-identical no-op suppression when the prior save succeeded.
            if candidateChanged || !checkpointPersistenceAvailableStorage {
                _ = persistCheckpointIfPossible()
            }
            guard let initialRefreshedAttachment = try Self.attachmentProjection(
                in: newWork.descriptor, expected: attachment)
            else {
                // Keep the previously published reducer/transcript available for inspection,
                // but fence all capabilities when the exact client row disappears.  This is
                // deliberately non-throwing so the UI can explain the source omission.
                attachmentActionableStorage = false
                workCompletenessStorage = .incomplete
                sessionCompletenessStorage = .incomplete
                appendReadDiagnostic(
                    "The Work Host omitted this exact client attachment; controls are disabled until it reappears.")
                return projection()
            }
            var refreshedAttachment = initialRefreshedAttachment
            try Self.validateReadAcknowledgements(
                in: refreshedAttachment, workJournal: journal, session: session,
                sessionJournal: sessionJournal)
            try Self.validateAcknowledgementCursors(
                in: refreshedAttachment, workCursor: newWork.cursor,
                sessionCursor: newSession.cursor)
            try Self.validateReducedBinding(
                work: reducedWork, sessionSnapshot: reducedSession, descriptor: newWork.descriptor,
                attachment: refreshedAttachment, journal: journal, sessionJournal: sessionJournal,
                session: session, sessionAttachment: sessionAttachment)
            if let required = requiredWorkCursorStorage {
                guard Self.cursor(newWork.cursor, reaches: required) else {
                    throw WorkServiceAttachedWorkControllerError.sourceIncomplete
                }
            }
            try reconcilePendingCommand(in: reducedWork, through: newWork.cursor)

            // Ack only after both reads and both reducers have validated. Acknowledgements are
            // control-journal mutations, so they never stand in for a half-published pair.
            refreshedAttachment = await acknowledgeAdvancedReads(
                attachment: refreshedAttachment, workCursor: newWork.cursor,
                sessionCursor: newSession.cursor)

            // The event pages are now validated and the two reducers agree on the exact bound
            // relationship. Publish both together; no journal can expose a half-updated pair.
            descriptorStorage = try Self.descriptorByUpdatingAttachment(
                newWork.descriptor, attachment: refreshedAttachment)
            attachmentStorage = refreshedAttachment
            attachmentActionableStorage = true
            workSnapshotStorage = reducedWork
            sessionSnapshotStorage = reducedSession
            workCursorStorage = newWork.cursor
            sessionCursorStorage = newSession.cursor
            workPrefixDigestStorage = newWork.prefixDigest
            sessionPrefixDigestStorage = newSession.prefixDigest
            workCompletenessStorage = newWork.sourceCompleteness
            sessionCompletenessStorage = newSession.sourceCompleteness
            if !reducedWork.unknownEvents.isEmpty {
                workCompletenessStorage = .incomplete
            }
            if !reducedSession.unknownEvents.isEmpty {
                sessionCompletenessStorage = .incomplete
            }
            workOmissionsStorage = newWork.omissions
            sessionOmissionsStorage = newSession.omissions
            stagedWorkReadStorage = nil
            stagedSessionReadStorage = nil
            checkpointAwaitingHostValidationStorage = false
            requiredWorkCursorStorage = nil
            requiresRefreshStorage = false
            reconcileConversationHistoryAfterRefresh(
                snapshot: reducedSession, cursor: newSession.cursor,
                prefixDigest: newSession.prefixDigest)
            _ = persistCheckpointIfPossible()
            return projection()
        } catch let error as WorkServiceAttachedWorkControllerError {
            if restoredCheckpointStorage != nil {
                // A checkpoint that cannot be reconciled against the host's exact prefix is only
                // a failed cache hint.  Drop that hint so the next refresh safely replays from
                // the baseline instead of retrying a mismatched cursor forever.
                restoredCheckpointStorage = nil
                stagedWorkReadStorage = nil
                stagedSessionReadStorage = nil
            }
            markReadFailure(error)
            throw error
        } catch {
            if restoredCheckpointStorage != nil {
                restoredCheckpointStorage = nil
                stagedWorkReadStorage = nil
                stagedSessionReadStorage = nil
            }
            markReadFailure(.transportFailure)
            throw WorkServiceAttachedWorkControllerError.transportFailure
        }
    }

    /// Return this controller's presentation window. It is never persisted as canonical state;
    /// another GUI reconstructs and pages its own independent window from the Work Host.
    public func conversationHistory() -> WorkServiceConversationHistoryWindow {
        historyStorage
    }

    /// Prepend one bounded page from the canonical selected Session branch.
    ///
    /// A failed read preserves all previously authenticated rows. This method never acknowledges
    /// a read, changes a command cursor, or retries a mutation.
    @discardableResult
    public func loadEarlierConversationHistory(
        limit: Int = 128,
        maxBytes: Int = 128 * 1024
    ) async throws -> WorkServiceConversationHistoryWindow {
        guard !historyReadInProgress else { return historyStorage }
        guard attachmentActionableStorage,
              attachmentStorage.authorization.granted.contains(.observe),
              workCompletenessStorage == .complete,
              sessionCompletenessStorage == .complete,
              !checkpointAwaitingHostValidationStorage else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard historyStorage.status != .staleBranch else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard historyStorage.hasEarlier else { return historyStorage }
        guard limit > 0, limit <= WorkServiceBounds.maxEventsPerPage,
              maxBytes > 0, maxBytes <= WorkServiceBounds.maxEventPageBytes else {
            throw WorkServiceAttachedWorkControllerError.invalidOptions
        }
        guard let frozenTip = historyStorage.frozenTipCursor,
              let frozenDigest = historyStorage.frozenTipDigest else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        // Enter historical-browsing mode before the transport suspension. A concurrent refresh
        // may then mark newer output or a branch change, but it cannot replace the reader's
        // window while this page is in flight.
        historyBrowsingOlderStorage = true
        historyReadInProgress = true
        historyStorage = historyWindow(
            messages: historyStorage.messages,
            frozenTipCursor: frozenTip, frozenTipDigest: frozenDigest,
            branchTip: historyStorage.branchTip,
            nextBeforeCursor: historyStorage.nextBeforeCursor,
            hasEarlier: historyStorage.hasEarlier, hasNewer: historyStorage.hasNewer,
            status: .loading, omissions: historyStorage.omissions)
        defer { historyReadInProgress = false }
        let request = WorkServiceHistoryRequest(
            work: work, journal: journal, attachment: attachmentStorage.attachment,
            client: client, target: .session(session: session, journal: sessionJournal),
            beforeCursor: historyStorage.nextBeforeCursor,
            frozenTipCursor: frozenTip, frozenTipDigest: frozenDigest,
            branchTip: historyStorage.branchTip, limit: limit, maxBytes: maxBytes)
        do {
            let page = try await service.historyBeforeCursor(request)
            // Jump-to-latest explicitly supersedes an in-flight page. A branch change similarly
            // leaves its truthful stale projection in place rather than merging an older result.
            guard historyBrowsingOlderStorage,
                  historyStorage.status != .staleBranch,
                  historyStorage.frozenTipCursor == frozenTip,
                  historyStorage.frozenTipDigest == frozenDigest else {
                return historyStorage
            }
            let candidate = try mergeHistoryPage(page, request: request)
            historyStorage = candidate
            return candidate
        } catch let error as WorkServiceAttachedWorkControllerError {
            guard historyBrowsingOlderStorage,
                  historyStorage.status != .staleBranch,
                  historyStorage.frozenTipCursor == frozenTip,
                  historyStorage.frozenTipDigest == frozenDigest else {
                return historyStorage
            }
            historyStorage = historyWindow(
                messages: historyStorage.messages,
                frozenTipCursor: frozenTip, frozenTipDigest: frozenDigest,
                branchTip: historyStorage.branchTip,
                nextBeforeCursor: historyStorage.nextBeforeCursor,
                hasEarlier: historyStorage.hasEarlier, hasNewer: historyStorage.hasNewer,
                status: .unavailable, omissions: historyStorage.omissions)
            throw error
        } catch {
            guard historyBrowsingOlderStorage,
                  historyStorage.status != .staleBranch,
                  historyStorage.frozenTipCursor == frozenTip,
                  historyStorage.frozenTipDigest == frozenDigest else {
                return historyStorage
            }
            historyStorage = historyWindow(
                messages: historyStorage.messages,
                frozenTipCursor: frozenTip, frozenTipDigest: frozenDigest,
                branchTip: historyStorage.branchTip,
                nextBeforeCursor: historyStorage.nextBeforeCursor,
                hasEarlier: historyStorage.hasEarlier, hasNewer: historyStorage.hasNewer,
                status: .unavailable, omissions: historyStorage.omissions)
            throw Self.mapReadError(error)
        }
    }

    /// Leave historical browsing and rebuild the newest bounded window from the already
    /// authenticated reducer projection. No network or Work mutation is required.
    public func jumpConversationHistoryToLatest() -> WorkServiceConversationHistoryWindow {
        historyBrowsingOlderStorage = false
        historyStorage = latestHistoryWindow(
            snapshot: sessionSnapshotStorage, cursor: sessionCursorStorage,
            prefixDigest: sessionPrefixDigestStorage,
            generation: historyStorage.generation + 1)
        return historyStorage
    }

    private func reconcileConversationHistoryAfterRefresh(
        snapshot: SessionSnapshot,
        cursor: JournalCursor,
        prefixDigest: String?
    ) {
        guard historyBrowsingOlderStorage else {
            historyStorage = latestHistoryWindow(
                snapshot: snapshot, cursor: cursor, prefixDigest: prefixDigest,
                generation: historyStorage.generation + 1)
            return
        }
        let currentBranchTip = historyStorage.branchTip
        var branchExtended = false
        if currentBranchTip != snapshot.semanticTip {
            guard Self.selectedBranch(snapshot.messages, contains: historyStorage.messages),
                  Self.semanticTipDescends(
                      from: currentBranchTip, to: snapshot.semanticTip,
                      messages: snapshot.messageHistory) else {
                historyStorage = historyWindow(
                    messages: historyStorage.messages,
                    frozenTipCursor: historyStorage.frozenTipCursor,
                    frozenTipDigest: historyStorage.frozenTipDigest,
                    branchTip: historyStorage.branchTip,
                    nextBeforeCursor: nil, hasEarlier: false, hasNewer: true,
                    status: .staleBranch,
                    omissions: historyStorage.omissions + [WorkServiceOmission(
                        category: "history_branch", count: 1,
                        diagnostic: "the canonical Session selected another conversation branch")])
                return
            }
            // The selected branch only extended (or made its existing implicit tip explicit).
            // Keep the original branch identity for the frozen window: the next reverse page
            // must continue proving the same branch, while newly appended tail rows are merely
            // reported as newer content until the user explicitly returns to latest.
            branchExtended = true
        }
        let hasNewer = historyStorage.hasNewer || historyStorage.frozenTipCursor != cursor
            || branchExtended
        historyStorage = historyWindow(
            messages: historyStorage.messages,
            frozenTipCursor: historyStorage.frozenTipCursor,
            frozenTipDigest: historyStorage.frozenTipDigest,
            branchTip: currentBranchTip,
            nextBeforeCursor: historyStorage.nextBeforeCursor,
            hasEarlier: historyStorage.hasEarlier, hasNewer: hasNewer,
            status: historyStorage.status == .loading ? .ready : historyStorage.status,
            omissions: historyStorage.omissions)
    }

    private static func selectedBranch(
        _ selected: [SessionMessageSnapshot], contains retained: [SessionMessageSnapshot]
    ) -> Bool {
        guard !retained.isEmpty else { return false }
        var selectedIndex = 0
        for message in retained {
            guard let eventID = message.sourceEvent?.eventID else { return false }
            while selectedIndex < selected.count,
                  selected[selectedIndex].sourceEvent?.eventID != eventID {
                selectedIndex += 1
            }
            guard selectedIndex < selected.count else { return false }
            selectedIndex += 1
        }
        return true
    }

    /// Return whether `to` extends the exact semantic branch identified by `from`. A nil tip is
    /// the implicit root branch and therefore precedes an explicit tip; a non-nil tip must walk
    /// through canonical conversation parents rather than merely sharing a visible prefix.
    private static func semanticTipDescends(
        from ancestor: EventRef?, to descendant: EventRef?,
        messages: [SessionMessageSnapshot]
    ) -> Bool {
        guard ancestor != descendant else { return true }
        guard let descendant else { return false }
        guard let ancestor else { return true }
        var messagesByID: [String: SessionMessageSnapshot] = [:]
        for message in messages {
            guard let source = message.sourceEvent else { continue }
            guard messagesByID.updateValue(message, forKey: source.eventID) == nil else {
                return false
            }
        }
        var current: EventRef? = descendant
        var visited: Set<String> = []
        while let tip = current {
            guard tip.journal == ancestor.journal,
                  visited.insert(tip.eventID).inserted,
                  let message = messagesByID[tip.eventID] else {
                return false
            }
            guard let parent = message.conversationParent else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    private func latestHistoryWindow(
        snapshot: SessionSnapshot,
        cursor: JournalCursor,
        prefixDigest: String?,
        generation: Int
    ) -> WorkServiceConversationHistoryWindow {
        var retained: [SessionMessageSnapshot] = []
        var bytes = 0
        for message in snapshot.messages.reversed() {
            let count = message.text.utf8.count
            guard retained.count < WorkServiceAttachedWorkControllerBounds.historyWindowMessages,
                  count <= WorkServiceAttachedWorkControllerBounds.historyWindowBytes - bytes else {
                break
            }
            retained.insert(message, at: 0)
            bytes += count
        }
        let hasEarlier = retained.count < snapshot.messages.count
        let boundary = hasEarlier ? retained.first?.sourceCursor : nil
        var omissions: [WorkServiceOmission] = []
        var status: WorkServiceConversationHistoryStatus = .ready
        if hasEarlier {
            omissions.append(WorkServiceOmission(
                category: "history", count: snapshot.messages.count - retained.count,
                diagnostic: "earlier selected-branch messages are outside this GUI window"))
            if boundary == nil {
                status = .unavailable
                omissions.append(WorkServiceOmission(
                    category: "history_boundary", count: 1,
                    diagnostic: "the oldest displayed message has no exact source cursor"))
            }
        }
        if !Self.validPrefixDigest(prefixDigest) || prefixDigest == nil {
            status = hasEarlier ? .unavailable : status
        }
        return WorkServiceConversationHistoryWindow(
            messages: retained, frozenTipCursor: cursor, frozenTipDigest: prefixDigest,
            branchTip: snapshot.semanticTip, nextBeforeCursor: boundary,
            hasEarlier: hasEarlier && boundary != nil, hasNewer: false,
            status: status, omissions: Self.boundedOmissions(omissions),
            generation: generation)
    }

    private func mergeHistoryPage(
        _ page: WorkServiceHistoryPage,
        request: WorkServiceHistoryRequest
    ) throws -> WorkServiceConversationHistoryWindow {
        let expectedHostInstance: WorkHostInstanceRef?
        if case .connected(let instance) = connectivityStorage {
            expectedHostInstance = instance
        } else {
            expectedHostInstance = descriptorStorage.hostObservation?.instance
        }
        guard Self.validHistoryAuthority(
                  page.authority, expected: work, expectedJournal: journal,
                  expectedHostInstance: expectedHostInstance),
              page.authority.sourceCompleteness == .complete,
              page.target == request.target,
              page.frozenTipCursor == request.frozenTipCursor,
              page.frozenTipDigest == request.frozenTipDigest,
              page.branchTip == request.branchTip,
              Self.validPrefixDigest(page.frozenTipDigest),
              Self.validPrefixDigest(page.prefixDigest),
              page.events.count <= request.limit,
              page.hasOlder == (page.nextBeforeCursor != nil) else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        var encodedBytes = 0
        var pageMessages: [SessionMessageSnapshot] = []
        var eventIDs: Set<String> = []
        var priorSequence: Int?
        for event in page.events {
            guard event.journal == sessionJournal,
                  event.session == session,
                  event.sequence > 0,
                  priorSequence.map({ event.sequence > $0 }) ?? true,
                  eventIDs.insert(event.eventID).inserted,
                  let message = SessionMessageSnapshot.canonicalMessage(from: event),
                  message.isPresentationVisible,
                  message.sourceCursor == JournalCursor(
                    journal: sessionJournal, eventID: event.eventID,
                    sequence: event.sequence) else {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            if let before = request.beforeCursor, event.sequence >= before.sequence {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            let size = try WorkServiceEventPageSizing.encodedByteCount(of: event)
            guard size <= request.maxBytes - encodedBytes else {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            encodedBytes += size
            priorSequence = event.sequence
            pageMessages.append(message)
        }
        let lower = page.events.first.map {
            JournalCursor(journal: sessionJournal, eventID: $0.eventID, sequence: $0.sequence)
        }
        let upper = page.events.last.map {
            JournalCursor(journal: sessionJournal, eventID: $0.eventID, sequence: $0.sequence)
        }
        let evidenceCursor = upper ?? page.frozenTipCursor
        let expectedPageDigest: String
        do {
            expectedPageDigest = try WorkServiceHistoryPageEvidence.digest(
                events: page.events, target: page.target, cursor: evidenceCursor)
        } catch {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        guard page.prefixDigest == expectedPageDigest else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        guard page.lowerBoundaryCursor == lower,
              page.upperBoundaryCursor == upper,
              (!page.hasOlder || page.nextBeforeCursor == lower),
              (page.hasOlder || page.nextBeforeCursor == nil) else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        let existingIDs = Set(historyStorage.messages.compactMap { $0.sourceEvent?.eventID })
        guard pageMessages.allSatisfy({ message in
            guard let id = message.sourceEvent?.eventID else { return false }
            return !existingIDs.contains(id)
        }) else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        var combined = pageMessages + historyStorage.messages
        var combinedBytes = combined.reduce(into: 0) { total, message in
            total += min(Int.max - total, message.text.utf8.count)
        }
        var droppedNewer = 0
        while combined.count > WorkServiceAttachedWorkControllerBounds.historyWindowMessages
            || combinedBytes > WorkServiceAttachedWorkControllerBounds.historyWindowBytes {
            guard let removed = combined.popLast() else { break }
            combinedBytes -= removed.text.utf8.count
            droppedNewer += 1
        }
        var omissions = page.omissions
        if droppedNewer > 0 {
            omissions.append(WorkServiceOmission(
                category: "history_window_newer", count: droppedNewer,
                diagnostic: "newer rows were released to keep this GUI history window bounded"))
        }
        return WorkServiceConversationHistoryWindow(
            messages: combined,
            frozenTipCursor: page.frozenTipCursor,
            frozenTipDigest: page.frozenTipDigest,
            // A concurrent refresh may have proven that the selected branch only extended after
            // the frozen physical tip. Preserve the original branch identity for the next page;
            // the extension is represented by hasNewer above.
            branchTip: historyStorage.branchTip,
            nextBeforeCursor: page.nextBeforeCursor,
            hasEarlier: page.hasOlder,
            hasNewer: historyStorage.hasNewer || droppedNewer > 0,
            status: .ready,
            omissions: Self.boundedOmissions(omissions),
            generation: historyStorage.generation + 1)
    }

    private func historyWindow(
        messages: [SessionMessageSnapshot],
        frozenTipCursor: JournalCursor?, frozenTipDigest: String?,
        branchTip: EventRef?, nextBeforeCursor: JournalCursor?,
        hasEarlier: Bool, hasNewer: Bool,
        status: WorkServiceConversationHistoryStatus,
        omissions: [WorkServiceOmission]
    ) -> WorkServiceConversationHistoryWindow {
        WorkServiceConversationHistoryWindow(
            messages: messages, frozenTipCursor: frozenTipCursor,
            frozenTipDigest: frozenTipDigest, branchTip: branchTip,
            nextBeforeCursor: nextBeforeCursor, hasEarlier: hasEarlier,
            hasNewer: hasNewer, status: status,
            omissions: Self.boundedOmissions(omissions),
            generation: historyStorage.generation + 1)
    }

    /// Construct and admit Start using the latest canonical Work cursor and exact Session
    /// attachment. The returned receipt is the durable Work-service boundary; a successful
    /// command does not fabricate a local event or advance a cursor before refresh observes it.
    public func start(_ prompt: String, commandID: String = UUID().uuidString.lowercased()) async throws
        -> WorkServiceCommandReceipt {
        try await issue(kind: .start, commandID: commandID, value: prompt)
    }

    public func send(_ prompt: String, commandID: String = UUID().uuidString.lowercased()) async throws
        -> WorkServiceCommandReceipt {
        try await issue(kind: .send, commandID: commandID, value: prompt)
    }

    public func steer(_ text: String, commandID: String = UUID().uuidString.lowercased()) async throws
        -> WorkServiceCommandReceipt {
        try await issue(kind: .steer, commandID: commandID, value: text)
    }

    public func queue(_ text: String, commandID: String = UUID().uuidString.lowercased()) async throws
        -> WorkServiceCommandReceipt {
        try await issue(kind: .queue, commandID: commandID, value: text)
    }

    public func cancel(
        scope: SessionCancellationScope = .agentLoop,
        commandID: String = UUID().uuidString.lowercased()
    ) async throws
        -> WorkServiceCommandReceipt {
        try await issue(kind: .cancel, commandID: commandID, value: scope.rawValue)
    }

    public func end(commandID: String = UUID().uuidString.lowercased()) async throws
        -> WorkServiceCommandReceipt {
        try await issue(kind: .end, commandID: commandID, value: nil)
    }

    /// Explicitly retry exactly the one retained request. No refresh or transport reconnect
    /// calls this method implicitly, and the original cursor/value/command id are unchanged.
    public func retryPendingCommand() async throws -> WorkServiceCommandReceipt {
        guard let pending = pendingStorage else {
            throw WorkServiceAttachedWorkControllerError.noPendingCommand
        }
        guard pending.state != .awaitingCanonicalEvidence else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        // Re-admit the retained envelope against the latest reduced owner tuple before
        // touching the intent store or dispatching.  In particular, a refresh may have
        // transferred this Work's active Run to another Session since the original attempt.
        try validateCommandAdmission(
            kind: pending.request.kind, commandID: pending.request.command.commandID)
        return try await submit(pending.request, retainingState: pending.state)
    }

    /// Reconciliation is intentionally read-only. Callers can inspect the pending record and
    /// refresh canonical pages; dispatch requires an explicit `retryPendingCommand()` call.
    public func pendingCommand() -> WorkServiceAttachedWorkPendingCommand? {
        pendingStorage?.projection
    }

    /// Discard a command only after the host proved its causal cursor stale. The caller must
    /// refresh first and supply a new command id for any reissue. An indeterminate command may
    /// have taken effect and therefore cannot be abandoned or rebased through this API.
    public func abandonStaleCommand() throws {
        guard let pending = pendingStorage else {
            throw WorkServiceAttachedWorkControllerError.noPendingCommand
        }
        guard pending.state == .stale else {
            throw WorkServiceAttachedWorkControllerError.commandNotAdmissible
        }
        try intentStore.clear(expecting: pending.request)
        pendingStorage = nil
    }

    private func issue(
        kind: WorkServiceCommandKind, commandID: String, value: String?
    ) async throws -> WorkServiceCommandReceipt {
        guard pendingStorage == nil else {
            throw WorkServiceAttachedWorkControllerError.pendingCommandExists
        }
        guard (value?.utf8.count ?? 0) <= WorkServiceBounds.maxCommandValueCharacters else {
            throw WorkServiceAttachedWorkControllerError.commandNotAdmissible
        }
        try validateCommandAdmission(kind: kind, commandID: commandID)
        let command = CommandRef(
            commandID: commandID, client: client, sessionAttachment: sessionAttachment,
            causalCursor: workCursorStorage)
        let request = WorkServiceCommandRequest(
            work: work, journal: journal, attachment: attachmentStorage.attachment,
            commandID: commandID, client: client, sessionAttachment: sessionAttachment,
            causalWorkCursor: workCursorStorage, kind: kind, value: value)
        // Ensure the request's exact command envelope is the one we intended. This also keeps a
        // future protocol revision from silently dropping the Session attachment.
        guard request.command == command else {
            throw WorkServiceAttachedWorkControllerError.commandNotAdmissible
        }
        return try await submit(request, retainingState: nil)
    }

    private func submit(
        _ request: WorkServiceCommandRequest,
        retainingState requestedState: WorkServiceAttachedWorkPendingState?
    ) async throws -> WorkServiceCommandReceipt {
        let state = requestedState ?? .indeterminate
        if pendingStorage == nil {
            do {
                try intentStore.retain(request, state: state)
            } catch let error as WorkServiceAttachedWorkControllerError {
                throw error
            } catch {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
            pendingStorage = PendingInternal(
                request: request, state: state,
                expectedResultingWorkCursor: nil, expectedHostSequence: nil)
        } else if pendingStorage?.request != request {
            throw WorkServiceAttachedWorkControllerError.pendingCommandExists
        }
        do {
            let receipt = try await service.command(request)
            guard receipt.work == work,
                  receipt.commandID == request.command.commandID,
                  receipt.host.host == WorkHostRef(work.workHostID),
                  receipt.causalWorkCursor == request.causalWorkCursor,
                  Self.validCursor(receipt.causalWorkCursor, journal: journal),
                  (receipt.resultingWorkCursor.map {
                      Self.validCursor($0, journal: journal)
                  } ?? true) else {
                pendingStorage?.state = .indeterminate
                throw WorkServiceAttachedWorkControllerError.transportFailure
            }
            switch receipt.state {
            case .accepted, .duplicate:
                guard Self.validAcceptedReceipt(receipt, for: request, journal: journal) else {
                    pendingStorage?.state = .indeterminate
                    throw WorkServiceAttachedWorkControllerError.transportFailure
                }
            case .rejected:
                guard receipt.rejection != nil,
                      receipt.outcome == nil,
                      receipt.hostSequence == nil,
                      receipt.terminalProof == nil else {
                    pendingStorage?.state = .indeterminate
                    throw WorkServiceAttachedWorkControllerError.transportFailure
                }
            }
            if receipt.state == .rejected && receipt.rejection == .staleCursor {
                pendingStorage?.state = .stale
                pendingStorage?.expectedResultingWorkCursor = nil
                pendingStorage?.expectedHostSequence = nil
                try intentStore.retain(request, state: .stale)
                markKnownBehind(receipt.resultingWorkCursor)
            } else if receipt.state == .rejected {
                // A durable rejection is a final command outcome, not an indeterminate effect.
                try intentStore.clear(expecting: request)
                pendingStorage = nil
            } else {
                let resultingCursor = receipt.resultingWorkCursor!
                let hostSequence = receipt.hostSequence!
                // The receipt proves host admission, not that the exact canonical event has
                // reached this controller. Persist the evidence obligation before returning so
                // a GUI crash cannot turn a success response into an untracked mutation.
                try intentStore.retain(
                    request, state: .awaitingCanonicalEvidence,
                    expectedResultingWorkCursor: resultingCursor,
                    expectedHostSequence: hostSequence)
                pendingStorage?.state = .awaitingCanonicalEvidence
                pendingStorage?.expectedResultingWorkCursor = resultingCursor
                pendingStorage?.expectedHostSequence = hostSequence
                markKnownBehind(resultingCursor)
            }
            lastReceiptStorage = receipt
            return receipt
        } catch let error as WorkServiceAttachedWorkControllerError {
            let pendingState: WorkServiceAttachedWorkPendingState = error == .staleCursor
                ? .stale : .indeterminate
            pendingStorage?.state = pendingState
            pendingStorage?.expectedResultingWorkCursor = nil
            pendingStorage?.expectedHostSequence = nil
            try? intentStore.retain(request, state: pendingState)
            connectivityStorage = await currentConnectivity(after: error)
            throw error
        } catch WorkServiceProtocolError.staleCursor {
            do {
                try intentStore.retain(request, state: .stale)
                pendingStorage?.state = .stale
                pendingStorage?.expectedResultingWorkCursor = nil
                pendingStorage?.expectedHostSequence = nil
            } catch {
                pendingStorage?.state = .indeterminate
                throw WorkServiceAttachedWorkControllerError.transportFailure
            }
            markKnownBehind(nil)
            connectivityStorage = await currentConnectivity(after: .staleCursor)
            throw WorkServiceAttachedWorkControllerError.staleCursor
        } catch WorkServiceTransportError.remote(let code, _) where code == .staleCursor {
            do {
                try intentStore.retain(request, state: .stale)
                pendingStorage?.state = .stale
                pendingStorage?.expectedResultingWorkCursor = nil
                pendingStorage?.expectedHostSequence = nil
            } catch {
                pendingStorage?.state = .indeterminate
                throw WorkServiceAttachedWorkControllerError.transportFailure
            }
            markKnownBehind(nil)
            connectivityStorage = await currentConnectivity(after: .staleCursor)
            throw WorkServiceAttachedWorkControllerError.staleCursor
        } catch {
            pendingStorage?.state = .indeterminate
            pendingStorage?.expectedResultingWorkCursor = nil
            pendingStorage?.expectedHostSequence = nil
            connectivityStorage = await currentConnectivity(after: .transportFailure)
            throw WorkServiceAttachedWorkControllerError.transportFailure
        }
    }

    private static func validAcceptedReceipt(
        _ receipt: WorkServiceCommandReceipt,
        for request: WorkServiceCommandRequest,
        journal: JournalRef
    ) -> Bool {
        guard let resulting = receipt.resultingWorkCursor,
              let hostSequence = receipt.hostSequence,
              hostSequence > 0,
              validCursor(resulting, journal: journal),
              resulting.sequence > request.causalWorkCursor.sequence,
              resulting.eventID?.isEmpty == false,
              receipt.rejection == nil else { return false }
        let validOutcome: Bool = switch request.kind {
        case .start:
            receipt.outcome == .started || receipt.outcome == .startRecoveryRequired
        case .send: receipt.outcome == .inputAccepted
        case .steer: receipt.outcome == .steeringAccepted
        case .queue: receipt.outcome == .queued
        case .cancel: receipt.outcome == .cancellationRequested
        case .end: receipt.outcome == .endRequested
        case .hold: receipt.outcome == .holdRequested
        case .destroy: receipt.outcome == .destroyed
        case .complete: receipt.outcome == .completed
        }
        guard validOutcome else { return false }
        if request.kind == .complete || request.kind == .destroy {
            return receipt.terminalProof != nil
        }
        return receipt.terminalProof == nil
    }

    private func reconcilePendingCommand(
        in snapshot: WorkSnapshot, through cursor: JournalCursor
    ) throws {
        guard let pending = pendingStorage else { return }
        guard pending.state != .stale else { return }
        let canonicalID = WorkServiceCommandLedgerIdentity.commandID(
            client: client, commandID: pending.request.command.commandID)
        guard let recorded = snapshot.commands[canonicalID] else {
            if pending.state == .awaitingCanonicalEvidence,
               let expected = pending.expectedResultingWorkCursor,
               Self.cursor(cursor, reaches: expected) {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
            return
        }
        let expectedCommand = WorkServiceCommandLedgerIdentity.command(
            from: pending.request.command, client: client)
        guard recorded.command == expectedCommand else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        if pending.state == .awaitingCanonicalEvidence {
            guard let expectedCursor = pending.expectedResultingWorkCursor,
                  let expectedHostSequence = pending.expectedHostSequence,
                  Self.cursor(cursor, reaches: expectedCursor),
                  recorded.acceptanceEventRef == EventRef(
                      journal: expectedCursor.journal, eventID: expectedCursor.eventID!),
                  recorded.acceptanceHostSequence == expectedHostSequence,
                  recorded.state != .rejected else {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
        }
        // An exact canonical acceptance/delivery/rejection resolves both an indeterminate send
        // and an acknowledged receipt. Clear disk first; if that fails, leave the in-memory
        // obligation intact and fail the projection rather than claiming recovery.
        try intentStore.clear(expecting: pending.request)
        pendingStorage = nil
    }

    private func validateCommandAdmission(
        kind: WorkServiceCommandKind, commandID: String
    ) throws {
        guard Self.validIdentity(commandID) else {
            throw WorkServiceAttachedWorkControllerError.commandNotAdmissible
        }
        guard attachmentStorage.authorization.allows(.control) else {
            throw WorkServiceAttachedWorkControllerError.capabilityDenied(.control)
        }
        guard attachmentActionableStorage else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        let capability: WorkServiceCapability
        switch kind {
        case .start: capability = .start
        case .send: capability = .send
        case .steer: capability = .steer
        case .queue: capability = .queue
        case .cancel: capability = .cancel
        case .end: capability = .end
        case .hold: capability = .hold
        case .destroy: capability = .destroy
        case .complete: capability = .complete
        }
        guard attachmentStorage.authorization.allows(capability) else {
            throw WorkServiceAttachedWorkControllerError.capabilityDenied(capability)
        }
        guard workCompletenessStorage == .complete,
              sessionCompletenessStorage == .complete,
              !requiresRefreshStorage,
              workSnapshotStorage.structuralIntegrityValid,
              workSnapshotStorage.semanticProjectionValid,
              sessionSnapshotStorage.structuralIntegrityValid,
              sessionSnapshotStorage.semanticProjectionValid,
              workSnapshotStorage.quarantinedEvents.isEmpty,
              sessionSnapshotStorage.quarantinedEvents.isEmpty else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard descriptorStorage.recordedDisposition == .reusable else {
            throw WorkServiceAttachedWorkControllerError.terminalWork
        }
        switch workSnapshotStorage.lifecycle {
        case .completed, .destroyed:
            throw WorkServiceAttachedWorkControllerError.terminalWork
        case .unknown:
            throw WorkServiceAttachedWorkControllerError.recoveryRequired
        case .active:
            break
        }
        guard descriptorStorage.execution != .recoveryRequired,
              descriptorStorage.execution != .unknown,
              let reducedExecution = Self.serviceExecution(workSnapshotStorage.execution),
              descriptorStorage.execution == reducedExecution,
              workSnapshotStorage.unknownEvents.isEmpty,
              sessionSnapshotStorage.unknownEvents.isEmpty,
              sessionSnapshotStorage.lifecycle == .active else {
            throw WorkServiceAttachedWorkControllerError.recoveryRequired
        }
        if kind != .start {
            // Every non-Start operation is scoped to the exact Session relationship that owns
            // the active Run.  This check deliberately compares both the reconstructed Work
            // reducer and the descriptor's reduced owner envelope; a stale descriptor must not
            // be allowed to write a new intent or reach the host service.
            guard let activeRun = descriptorStorage.currentRun,
                  descriptorStorage.currentRunSession == session,
                  descriptorStorage.currentRunSessionAttachment == sessionAttachment,
                  workSnapshotStorage.activeRun == activeRun,
                  workSnapshotStorage.activeRunSession == session,
                  workSnapshotStorage.activeRunSessionAttachment == sessionAttachment else {
                throw WorkServiceAttachedWorkControllerError.recoveryRequired
            }
        }
        switch (kind, reducedExecution) {
        // An idle Work with no current Run is the only valid Start boundary. Once a Run has
        // settled between turns, the reducer may report .idle while activeRun remains
        // present; that is still the same live conversation and must accept Send/End.
        case (.start, .idle) where descriptorStorage.currentRun == nil: break
        case (.send, .running): break
        case (.send, .idle) where descriptorStorage.currentRun != nil: break
        case (.steer, .running), (.queue, .running): break
        case (.cancel, .running), (.cancel, .held), (.end, .running),
             (.end, .held), (.end, .canceling),
             (.end, .idle) where descriptorStorage.currentRun != nil: break
        default: throw WorkServiceAttachedWorkControllerError.commandNotAdmissible
        }
    }

    private func markKnownBehind(_ resultingCursor: JournalCursor?) {
        requiresRefreshStorage = true
        guard let resultingCursor,
              Self.validCursor(resultingCursor, journal: journal) else { return }
        if let requiredWorkCursorStorage,
           Self.cursor(requiredWorkCursorStorage, reaches: resultingCursor) {
            return
        }
        requiredWorkCursorStorage = resultingCursor
    }

    private func establishConnectionIfNeeded() async throws -> WorkServiceHandshakeResponse? {
        guard let connectIfNeeded else { return nil }
        do {
            return try await connectIfNeeded()
        } catch WorkServiceClientSessionError.notConnected {
            throw WorkServiceAttachedWorkControllerError.notConnected
        } catch WorkServiceClientSessionError.unavailable {
            throw WorkServiceAttachedWorkControllerError.transportFailure
        } catch WorkServiceClientSessionError.incompatibleProtocol {
            throw WorkServiceAttachedWorkControllerError.hostMismatch
        } catch WorkServiceClientSessionError.hostInstanceMismatch {
            throw WorkServiceAttachedWorkControllerError.hostMismatch
        } catch {
            throw WorkServiceAttachedWorkControllerError.transportFailure
        }
    }

    private func currentConnectivity(
        after error: WorkServiceAttachedWorkControllerError
    ) async -> WorkServiceAttachedWorkConnectivity {
        if let provider = connectivityProvider { return await provider() }
        switch error {
        case .hostMismatch: return .incompatible(WorkHostRef(work.workHostID))
        case .notConnected, .transportFailure: return .unavailable(WorkHostRef(work.workHostID))
        default: return connectivityStorage
        }
    }

    private func markReadFailure(_ error: WorkServiceAttachedWorkControllerError) {
        switch error {
        case .hostMismatch: connectivityStorage = .incompatible(WorkHostRef(work.workHostID))
        case .notConnected, .transportFailure: connectivityStorage = .unavailable(WorkHostRef(work.workHostID))
        default: break
        }
        // Keep canonical snapshots/cursors exactly as they were. The source state is the only
        // mutable truth changed by this failed transaction.
        workCompletenessStorage = .incomplete
        sessionCompletenessStorage = .incomplete
        let diagnostic: String
        switch error {
        case .malformedResponse: diagnostic = "Work service returned a malformed journal read."
        case .sourceIncomplete: diagnostic = "Work service journal read was incomplete."
        case .hostMismatch: diagnostic = "Work service host identity did not match the attachment."
        case .notConnected, .transportFailure: diagnostic = "Work service journal read was unavailable."
        default: diagnostic = "Work service journal read failed."
        }
        if !readDiagnosticsStorage.contains(diagnostic) {
            readDiagnosticsStorage = Array((readDiagnosticsStorage + [diagnostic]).suffix(
                WorkServiceAttachedWorkControllerBounds.maxDiagnostics))
        }
    }

    // MARK: - Read validation

    private static func readJournal(
        kind: ReadKind,
        service: any WorkServiceClient,
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        client: ClientRef,
        journal: JournalRef,
        session: SessionRef,
        sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef,
        after: JournalCursor,
        pageLimit: Int,
        pageBytes: Int,
        expectedHostInstance: WorkHostInstanceRef?,
        expectedBasePrefixDigest: String?
    ) async throws -> ReadResult {
        let target: WorkServiceReadTarget
        let targetJournal: JournalRef
        switch kind {
        case .work:
            target = .work(journal: journal)
            targetJournal = journal
        case .session:
            target = .session(session: session, journal: sessionJournal)
            targetJournal = sessionJournal
        }
        let first: WorkServiceSnapshot
        do {
            first = try await service.snapshot(WorkServiceSnapshotRequest(
                work: descriptor.work, journal: descriptor.journal,
                attachment: attachment.attachment, client: client, target: target,
                afterCursor: after, limit: pageLimit, maxBytes: pageBytes))
        } catch {
            throw mapReadError(error)
        }
        guard first.target == target,
              validDescriptor(
                  first.work, expected: descriptor.work, expectedJournal: journal,
                  expectedHostInstance: expectedHostInstance) else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        guard Self.validPrefixDigest(first.basePrefixDigest),
              Self.validPrefixDigest(first.prefixDigest),
              expectedBasePrefixDigest == nil || first.basePrefixDigest == expectedBasePrefixDigest else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        if first.work.hostObservation?.sourceCompleteness == .incomplete
            || first.work.hostObservation?.sourceCompleteness == .unknown {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        var cursor = try validateSnapshot(
            first, target: target, targetJournal: targetJournal, expectedWork: descriptor.work,
            expectedSession: session, expectedSessionAttachment: sessionAttachment,
            after: after, pageLimit: pageLimit, pageBytes: pageBytes)
        var events = first.events
        var prefixDigest = first.prefixDigest
        var omissions: [WorkServiceOmission] = []
        let hasMoreInSnapshot = hasPagingOmission(first.omissions)
        if !hasMoreInSnapshot {
            if kind == .work,
               let advertised = first.work.hostObservation?.servedCursor,
               advertised != cursor {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
        }
        var needsPage = hasMoreInSnapshot
        var pageCount = 0
        var seenCursors: Set<JournalCursor> = [cursor]
        while needsPage {
            guard pageCount < WorkServiceAttachedWorkControllerBounds.maxPages else {
                // The prefix and its exact continuation cursor are valid. Returning it as an
                // incomplete result lets the controller retain a resumable checkpoint instead of
                // re-reading from zero or latching permanently into sourceIncomplete.
                omissions.append(WorkServiceOmission(
                    category: "controller_page_budget", count: 1,
                    diagnostic: "per-refresh page budget reached; continue from this cursor"))
                omissions.append(contentsOf: first.omissions.filter { !hasPagingOmission([$0]) })
                return ReadResult(
                    cursor: cursor, events: events, descriptor: first.work,
                    sourceCompleteness: .incomplete, omissions: boundedOmissions(omissions),
                    basePrefixDigest: first.basePrefixDigest, prefixDigest: prefixDigest)
            }
            pageCount += 1
            let page: WorkServiceEventPage
            do {
                page = try await service.eventsAfterCursor(WorkServiceEventsRequest(
                    work: descriptor.work, journal: descriptor.journal,
                    attachment: attachment.attachment, client: client, target: target,
                    afterCursor: cursor, limit: pageLimit, maxBytes: pageBytes))
            } catch {
                throw mapReadError(error)
            }
            guard page.target == target else {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            guard Self.validPrefixDigest(page.basePrefixDigest),
                  Self.validPrefixDigest(page.prefixDigest),
                  page.basePrefixDigest == prefixDigest else {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
            let pageCursor = try validateEventPage(
                page, target: target, targetJournal: targetJournal, expectedWork: descriptor.work,
                expectedSession: session, expectedSessionAttachment: sessionAttachment,
                after: cursor, pageLimit: pageLimit, pageBytes: pageBytes)
            guard pageCursor != cursor, seenCursors.insert(pageCursor).inserted else {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            events.append(contentsOf: page.events)
            prefixDigest = page.prefixDigest
            // Event-count/byte omissions are resolved by the bounded continuation loop. Keep
            // any other omission category as explicit bounded evidence instead of dropping it
            // merely because it arrived on a later page.
            omissions.append(contentsOf: page.omissions.filter { !hasPagingOmission([$0]) })
            cursor = pageCursor
            if let next = page.nextCursor {
                guard next == pageCursor else {
                    throw WorkServiceAttachedWorkControllerError.malformedResponse
                }
                needsPage = true
            } else if hasPagingOmission(page.omissions) {
                // A server that admits more data but does not provide a progressing cursor has
                // exposed an incomplete source. Do not reduce or publish this candidate.
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            } else {
                needsPage = false
            }
        }
        // Event/page omissions are consumed by the bounded loop above. Non-event omissions
        // (typically artifact metadata) remain visible but do not make the Work/Session journal
        // itself incomplete.
        omissions.append(contentsOf: first.omissions.filter { !hasPagingOmission([$0]) })
        return ReadResult(
            cursor: cursor, events: events, descriptor: first.work,
            sourceCompleteness: .complete, omissions: boundedOmissions(omissions),
            basePrefixDigest: first.basePrefixDigest, prefixDigest: prefixDigest)
    }

    private static func stagedWorkSnapshot(_ staged: StagedRead?) -> WorkSnapshot? {
        guard let staged, case .work(let snapshot) = staged.snapshot else { return nil }
        return snapshot
    }

    private static func stagedSessionSnapshot(_ staged: StagedRead?) -> SessionSnapshot? {
        guard let staged, case .session(let snapshot) = staged.snapshot else { return nil }
        return snapshot
    }

    private static func reduceRead(
        _ delta: ReadResult,
        initial: WorkSnapshot,
        kind: ReadKind,
        expectedCursor: JournalCursor
    ) throws -> WorkSnapshot {
        guard kind == .work,
              delta.cursor.journal == expectedCursor.journal,
              validCursor(delta.cursor, journal: expectedCursor.journal) else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        let reduced = WorkReducer.reduce(delta.events, initial: initial)
        guard reduced.journal == expectedCursor.journal,
              reduced.lastSequence == delta.cursor.sequence,
              reduced.lastEventID == delta.cursor.eventID,
              reduced.structuralIntegrityValid,
              reduced.semanticProjectionValid,
              reduced.quarantinedEvents.isEmpty else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        return reduced
    }

    private static func reduceRead(
        _ delta: ReadResult,
        initial: SessionSnapshot,
        kind: ReadKind,
        expectedCursor: JournalCursor
    ) throws -> SessionSnapshot {
        guard kind == .session,
              delta.cursor.journal == expectedCursor.journal,
              validCursor(delta.cursor, journal: expectedCursor.journal) else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        let reduced = SessionReducer.reduce(delta.events, initial: initial)
        guard reduced.journal == expectedCursor.journal,
              reduced.lastSequence == delta.cursor.sequence,
              reduced.lastEventID == delta.cursor.eventID,
              reduced.structuralIntegrityValid,
              reduced.semanticProjectionValid,
              reduced.quarantinedEvents.isEmpty else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        return reduced
    }

    /// A direct service fixture may not be wrapped by WorkServiceClientSession. Probe its control
    /// plane opportunistically so an existing seed can still acknowledge reads; a transport that
    /// intentionally omits handshake support remains read-only.
    private func discoverControlCursor() async {
        let request = WorkServiceHandshakeRequest(client: client)
        do {
            let handshake = try await service.handshake(request)
            guard Self.validHandshake(
                handshake, expectedHost: WorkHostRef(work.workHostID)) else { return }
            controlCursorStorage = handshake.controlCursor
            if case .disconnected = connectivityStorage {
                connectivityStorage = .connected(handshake.hostInstance)
            }
        } catch {
            // Reads are still useful for a deliberately minimal loopback test double. Mutation
            // admission below will simply record that the control cursor was unavailable.
        }
    }

    private func appendReadDiagnostic(_ diagnostic: String) {
        guard !readDiagnosticsStorage.contains(diagnostic) else { return }
        readDiagnosticsStorage = Array(
            (readDiagnosticsStorage + [diagnostic]).suffix(
                WorkServiceAttachedWorkControllerBounds.maxDiagnostics))
    }

    private func acknowledgeAdvancedReads(
        attachment: WorkServiceClientAttachment,
        workCursor: JournalCursor,
        sessionCursor: JournalCursor
    ) async -> WorkServiceClientAttachment {
        let workTarget = WorkServiceReadTarget.work(journal: journal)
        let sessionTarget = WorkServiceReadTarget.session(
            session: session, journal: sessionJournal)
        var projected = attachment
        for (target, cursor) in [(workTarget, workCursor), (sessionTarget, sessionCursor)] {
            if let pending = pendingReadAcknowledgementsStorage.values.first(where: {
                $0.request.target == target
            }) {
                if let durable = Self.acknowledgedCursor(for: target, in: projected),
                   Self.cursor(durable, reaches: pending.request.cursor) {
                    pendingReadAcknowledgementsStorage.removeValue(forKey: pending.key)
                    _ = persistCheckpointIfPossible(attachmentOverride: projected)
                } else if Self.cursor(cursor, reaches: pending.request.cursor) {
                    // Descriptor reconciliation has completed for this refresh.  Replay the
                    // exact retained request within this refresh before asking for a newer cursor.
                    // The command ID, target, cursor, and causal control cursor are unchanged, so
                    // the host's idempotency record decides whether this is an admission or a
                    // duplicate. A later refresh gets a fresh bounded attempt; no lifetime retry
                    // counter can strand an otherwise valid idempotent request.
                    await acknowledge(
                        target: target, cursor: pending.request.cursor, attachment: &projected)
                    if pendingReadAcknowledgementsStorage.values.contains(where: {
                        $0.request.target == target
                    }) {
                        continue
                    }
                } else {
                    appendReadDiagnostic(
                        "A pending read acknowledgement is ahead of the validated journal prefix.")
                    continue
                }
            }
            guard let durable = Self.acknowledgedCursor(for: target, in: projected) else {
                await acknowledge(target: target, cursor: cursor, attachment: &projected)
                continue
            }
            guard Self.cursor(cursor, reaches: durable) else {
                // An acknowledgement ahead of the fully read candidate means this controller
                // cannot prove the missing history. Do not send a second mutation; the next
                // refresh will re-read from its committed/checkpoint cursor.
                appendReadDiagnostic(
                    "Work service returned a read acknowledgement ahead of the validated journal prefix.")
                continue
            }
            if cursor != durable {
                await acknowledge(target: target, cursor: cursor, attachment: &projected)
            }
        }
        return projected
    }

    private func acknowledge(
        target: WorkServiceReadTarget,
        cursor: JournalCursor,
        attachment: inout WorkServiceClientAttachment
    ) async {
        guard cursor.journal == target.journal,
              Self.validCursor(cursor, journal: target.journal) else {
            appendReadDiagnostic("Work service returned an invalid read cursor.")
            return
        }
        let key = ReadAcknowledgementKey(targetJournal: target.journal, cursor: cursor)
        var retainedRequest: WorkServiceAcknowledgeReadRequest?
        if let pending = pendingReadAcknowledgementsStorage[key] {
            if let durable = Self.acknowledgedCursor(for: target, in: attachment),
               Self.cursor(durable, reaches: cursor) {
                pendingReadAcknowledgementsStorage.removeValue(forKey: key)
            } else if !pending.stale {
                // The bound is per refresh (`attempts` below), not a durable lifetime counter.
                // A response can be lost repeatedly before admission; every later descriptor
                // reconciliation may safely retry this same idempotent request until the host
                // proves admission or returns a correlated no-effect rejection.
                retainedRequest = pending.request
            } else {
                // A stale response is proof of no effect. It is safe to mint a fresh causal
                // request for the same target/cursor on the next attempt.
                pendingReadAcknowledgementsStorage.removeValue(forKey: key)
            }
        }
        guard attachment.authorization.allows(.observe) else {
            appendReadDiagnostic(
                "The attached client cannot durably acknowledge its read cursor.")
            return
        }
        guard checkpointPersistenceAvailableStorage else {
            appendReadDiagnostic(
                "Read acknowledgement is withheld until the local reducer checkpoint is durable.")
            return
        }
        var control: JournalCursor
        if let retainedRequest {
            // An exact replay must not be rewritten to the current handshake cursor.  If that
            // causal cursor is stale, the structured stale response below supplies the one safe
            // successor cursor for a fresh attempt of the same logical acknowledgement.
            control = retainedRequest.causalControlCursor
        } else {
            guard let initialControl = await currentControlCursor() else {
                appendReadDiagnostic(
                    "The Work Host control cursor was unavailable; read acknowledgement is pending.")
                return
            }
            control = initialControl
        }
        var attempts = 0
        while attempts < 2 {
            attempts += 1
            let request: WorkServiceAcknowledgeReadRequest
            if let retainedRequest, attempts == 1 {
                request = retainedRequest
            } else {
                let commandID = Self.acknowledgementCommandID(
                    work: work, attachment: attachment.attachment, target: target,
                    cursor: cursor, causalControlCursor: control)
                request = WorkServiceAcknowledgeReadRequest(
                    work: work, journal: journal, attachment: attachment.attachment,
                    client: client, target: target, cursor: cursor,
                    commandID: commandID, causalControlCursor: control)
                pendingReadAcknowledgementsStorage[key] = PendingReadAcknowledgement(
                    request: request, stale: false)
                guard persistCheckpointIfPossible(attachmentOverride: attachment) else { return }
            }
            do {
                let response = try await service.acknowledgeRead(request)
                guard Self.validAcknowledgementResponse(
                    response, request: request, expectedHost: WorkHostRef(work.workHostID)) else {
                    appendReadDiagnostic(
                        "The Work Host returned an uncorrelated read acknowledgement.")
                    return
                }
                controlCursorStorage = response.resultingControlCursor
                switch response.state {
                case .accepted, .duplicate:
                    pendingReadAcknowledgementsStorage.removeValue(forKey: key)
                    attachment = Self.attachmentByAcknowledging(
                        target: target, cursor: cursor, attachment: attachment)
                    _ = persistCheckpointIfPossible(attachmentOverride: attachment)
                    return
                case .rejected:
                    if response.rejection == .staleCursor, attempts < 2 {
                        // This rejection proves no read-ack mutation occurred. Chain the exact
                        // resulting control cursor into one bounded retry; never do this for an
                        // ambiguous transport result.
                        pendingReadAcknowledgementsStorage[key] = PendingReadAcknowledgement(
                            request: request, stale: true)
                        guard persistCheckpointIfPossible(attachmentOverride: attachment) else {
                            return
                        }
                        guard Self.validControlCursor(
                            response.resultingControlCursor,
                            expectedHost: WorkHostRef(work.workHostID)) else { return }
                        control = response.resultingControlCursor
                        controlCursorStorage = response.resultingControlCursor
                        continue
                    }
                    pendingReadAcknowledgementsStorage.removeValue(forKey: key)
                    appendReadDiagnostic(
                        response.rejection == .staleCursor
                            ? "Read acknowledgement remained stale after a bounded control-cursor retry."
                            : "The Work Host rejected a read acknowledgement.")
                    return
                }
            } catch {
                // The request remains retained in memory for descriptor reconciliation, but is
                // deliberately not replayed from this refresh (or a reconnect).
                appendReadDiagnostic(
                    "A read acknowledgement response was unavailable; waiting for descriptor reconciliation.")
                return
            }
        }
    }

    private func currentControlCursor() async -> JournalCursor? {
        if let control = controlCursorStorage,
           Self.validControlCursor(control, expectedHost: WorkHostRef(work.workHostID)) {
            return control
        }
        await discoverControlCursor()
        guard let control = controlCursorStorage,
              Self.validControlCursor(control, expectedHost: WorkHostRef(work.workHostID)) else {
            return nil
        }
        return control
    }

    /// Persist the exact committed reducer pair plus any uncommitted continuation. This is a
    /// local cache: a write failure is diagnostic only and never changes the remote source's
    /// availability or the validated projection that the GUI may display.
    private func persistCheckpoint(
        attachmentOverride: WorkServiceClientAttachment? = nil
    ) throws {
        let stagedWork = stagedWorkReadStorage
        let stagedSession = stagedSessionReadStorage
        let descriptor = stagedWork?.descriptor ?? stagedSession?.descriptor ?? descriptorStorage
        let pending = pendingReadAcknowledgementsStorage.values
            .sorted { lhs, rhs in
                let left = lhs.request.target.journal.journalID + "|" + String(lhs.request.cursor.sequence)
                let right = rhs.request.target.journal.journalID + "|" + String(rhs.request.cursor.sequence)
                return left < right
            }
            .map {
                WorkServiceAttachedWorkCheckpointStore.PendingAcknowledgement(
                    request: $0.request, stale: $0.stale)
            }
        let candidate = WorkServiceAttachedWorkCheckpointStore.Record(
            client: client, work: work, journal: journal, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            attachment: attachmentStorage.attachment,
            hostInstance: descriptor.hostObservation?.instance,
            descriptor: descriptor,
            attachmentProjection: attachmentOverride ?? attachmentStorage,
            controlCursor: controlCursorStorage,
            committedWorkCursor: workCursorStorage,
            committedWorkPrefixDigest: workPrefixDigestStorage,
            committedWorkSnapshot: workSnapshotStorage,
            committedSessionCursor: sessionCursorStorage,
            committedSessionPrefixDigest: sessionPrefixDigestStorage,
            committedSessionSnapshot: sessionSnapshotStorage,
            stagedWorkCursor: stagedWork?.cursor,
            stagedWorkPrefixDigest: stagedWork?.prefixDigest,
            stagedWorkSnapshot: Self.stagedWorkSnapshot(stagedWork),
            stagedWorkOmissions: stagedWork?.omissions ?? [],
            stagedSessionCursor: stagedSession?.cursor,
            stagedSessionPrefixDigest: stagedSession?.prefixDigest,
            stagedSessionSnapshot: Self.stagedSessionSnapshot(stagedSession),
            stagedSessionOmissions: stagedSession?.omissions ?? [],
            pendingAcknowledgements: pending)
        let record = WorkServiceAttachedWorkCheckpointStore.boundedRecord(candidate)
        guard record != lastCheckpointRecordStorage else {
            checkpointPersistenceAvailableStorage = true
            return
        }
        try checkpointStore.save(record)
        lastCheckpointRecordStorage = record
        checkpointPersistenceAvailableStorage = true
    }

    private func persistCheckpointIfPossible(
        attachmentOverride: WorkServiceClientAttachment? = nil
    ) -> Bool {
        do {
            try persistCheckpoint(attachmentOverride: attachmentOverride)
            return true
        } catch {
            checkpointPersistenceAvailableStorage = false
            appendReadDiagnostic(
                "Local reducer checkpoint could not be persisted; reads remain visible and will be revalidated after restart.")
            return false
        }
    }

    private static func validCheckpoint(
        _ record: WorkServiceAttachedWorkCheckpointStore.Record,
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        session: SessionRef,
        sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef
    ) -> Bool {
        guard validCheckpointMetadata(
            record, descriptor: descriptor, attachment: attachment, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment),
              let committedWorkSnapshot = record.committedWorkSnapshot,
              let committedSessionSnapshot = record.committedSessionSnapshot,
              validCommittedWork(committedWorkSnapshot, cursor: record.committedWorkCursor,
                                 work: descriptor.work, journal: descriptor.journal),
              validCommittedSession(committedSessionSnapshot,
                                    cursor: record.committedSessionCursor,
                                    session: session, journal: sessionJournal) else {
            return false
        }
        let validStagedWork: Bool
        if let cursor = record.stagedWorkCursor, let snapshot = record.stagedWorkSnapshot {
            validStagedWork = validCommittedWork(
                snapshot, cursor: cursor, work: descriptor.work, journal: descriptor.journal)
                && cursor.sequence >= record.committedWorkCursor.sequence
                && checkpointDigestUsable(cursor, digest: record.stagedWorkPrefixDigest)
        } else {
            validStagedWork = record.stagedWorkCursor == nil && record.stagedWorkSnapshot == nil
                && record.stagedWorkPrefixDigest == nil
        }
        let validStagedSession: Bool
        if let cursor = record.stagedSessionCursor, let snapshot = record.stagedSessionSnapshot {
            validStagedSession = validCommittedSession(
                snapshot, cursor: cursor, session: session, journal: sessionJournal)
                && cursor.sequence >= record.committedSessionCursor.sequence
                && checkpointDigestUsable(cursor, digest: record.stagedSessionPrefixDigest)
        } else {
            validStagedSession = record.stagedSessionCursor == nil
                && record.stagedSessionSnapshot == nil
                && record.stagedSessionPrefixDigest == nil
        }
        guard validStagedWork, validStagedSession,
              checkpointDigestUsable(
                  record.committedWorkCursor, digest: record.committedWorkPrefixDigest),
              checkpointDigestUsable(
                  record.committedSessionCursor, digest: record.committedSessionPrefixDigest) else {
            return false
        }
        let acknowledgedWorkCursor = record.stagedWorkCursor ?? record.committedWorkCursor
        let acknowledgedSessionCursor = record.stagedSessionCursor ?? record.committedSessionCursor
        for acknowledgement in record.attachmentProjection.readAcknowledgements {
            switch acknowledgement.target {
            case .work:
                guard cursor(acknowledgedWorkCursor, reaches: acknowledgement.cursor) else {
                    return false
                }
            case .session:
                guard cursor(acknowledgedSessionCursor, reaches: acknowledgement.cursor) else {
                    return false
                }
            }
        }
        return true
    }

    /// Validate only the identity/cursor/proof envelope.  A compact checkpoint intentionally has
    /// no reducer snapshots and therefore cannot resume history, but its pending idempotent
    /// acknowledgement requests are still safe to restore after this metadata check.
    private static func validCheckpointMetadata(
        _ record: WorkServiceAttachedWorkCheckpointStore.Record,
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        session: SessionRef,
        sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef
    ) -> Bool {
        guard record.client == attachment.client,
              record.work == descriptor.work,
              record.journal == descriptor.journal,
              record.session == session,
              record.sessionJournal == sessionJournal,
              record.sessionAttachment == sessionAttachment,
              record.attachment == attachment.attachment,
              record.descriptor.work == descriptor.work,
              record.descriptor.journal == descriptor.journal,
              record.descriptor.work.workHostID == descriptor.work.workHostID,
              record.attachmentProjection.attachment == attachment.attachment,
              record.attachmentProjection.client == attachment.client,
              record.attachmentProjection.session == session,
              record.attachmentProjection.sessionJournal == sessionJournal,
              record.attachmentProjection.sessionAttachment == sessionAttachment,
              record.committedWorkCursor.journal == descriptor.journal,
              record.committedSessionCursor.journal == sessionJournal,
              validPrefixDigest(record.committedWorkPrefixDigest),
              validPrefixDigest(record.committedSessionPrefixDigest),
              checkpointDigestUsable(
                  record.committedWorkCursor, digest: record.committedWorkPrefixDigest),
              checkpointDigestUsable(
                  record.committedSessionCursor, digest: record.committedSessionPrefixDigest),
              validControlCheckpointCursor(record.controlCursor, host: descriptor.work.workHostID) else {
            return false
        }
        if let stagedCursor = record.stagedWorkCursor {
            guard stagedCursor.journal == descriptor.journal,
                  stagedCursor.sequence >= record.committedWorkCursor.sequence,
                  checkpointDigestUsable(stagedCursor, digest: record.stagedWorkPrefixDigest) else {
                return false
            }
        } else {
            guard record.stagedWorkSnapshot == nil, record.stagedWorkPrefixDigest == nil else {
                return false
            }
        }
        if let stagedCursor = record.stagedSessionCursor {
            guard stagedCursor.journal == sessionJournal,
                  stagedCursor.sequence >= record.committedSessionCursor.sequence,
                  checkpointDigestUsable(stagedCursor, digest: record.stagedSessionPrefixDigest) else {
                return false
            }
        } else {
            guard record.stagedSessionSnapshot == nil, record.stagedSessionPrefixDigest == nil else {
                return false
            }
        }
        guard (record.stagedWorkCursor == nil) == (record.stagedWorkSnapshot == nil),
              (record.stagedSessionCursor == nil) == (record.stagedSessionSnapshot == nil),
              (try? validateReadAcknowledgements(
                  in: record.attachmentProjection, workJournal: descriptor.journal,
                  session: session, sessionJournal: sessionJournal)) != nil else {
            return false
        }
        var pendingKeys = Set<ReadAcknowledgementKey>()
        for pending in record.pendingAcknowledgements {
            let key = ReadAcknowledgementKey(
                targetJournal: pending.request.target.journal, cursor: pending.request.cursor)
            guard pendingKeys.insert(key).inserted,
                  pending.request.work == descriptor.work,
                  pending.request.journal == descriptor.journal,
                  pending.request.attachment == attachment.attachment,
                  pending.request.client == attachment.client,
                  pending.request.target.journal == key.targetJournal,
                  validCursor(pending.request.cursor, journal: key.targetJournal),
                  validControlCheckpointCursor(
                      pending.request.causalControlCursor, host: descriptor.work.workHostID) else {
                return false
            }
            switch pending.request.target {
            case .work(let targetJournal):
                guard targetJournal == descriptor.journal else { return false }
            case .session(let targetSession, let targetJournal):
                guard targetSession == session, targetJournal == sessionJournal else { return false }
            }
        }
        return true
    }

    private static func validCommittedWork(
        _ snapshot: WorkSnapshot,
        cursor: JournalCursor,
        work: WorkRef,
        journal: JournalRef
    ) -> Bool {
        snapshot.journal == journal
            && snapshot.work == work
            && snapshot.workHost == WorkHostRef(work.workHostID)
            && snapshot.lastSequence == cursor.sequence
            && snapshot.lastEventID == cursor.eventID
            && cursor.journal == journal
            && validCursor(cursor, journal: journal)
            && snapshot.structuralIntegrityValid
            && snapshot.semanticProjectionValid
            && snapshot.quarantinedEvents.isEmpty
            && snapshot.unknownEvents.isEmpty
    }

    private static func validCommittedSession(
        _ snapshot: SessionSnapshot,
        cursor: JournalCursor,
        session: SessionRef,
        journal: JournalRef
    ) -> Bool {
        let exactMessages = snapshot.messageHistory.allSatisfy {
            validCheckpointMessage($0, journal: journal)
        } && snapshot.messages.allSatisfy {
            validCheckpointMessage($0, journal: journal)
        }
        return snapshot.journal == journal
            && snapshot.session == session
            && snapshot.lastSequence == cursor.sequence
            && snapshot.lastEventID == cursor.eventID
            && cursor.journal == journal
            && validCursor(cursor, journal: journal)
            && snapshot.structuralIntegrityValid
            && snapshot.semanticProjectionValid
            && snapshot.quarantinedEvents.isEmpty
            && snapshot.unknownEvents.isEmpty
            && exactMessages
    }

    private static func validCheckpointMessage(
        _ message: SessionMessageSnapshot, journal: JournalRef
    ) -> Bool {
        guard let source = message.sourceEvent,
              let cursor = message.sourceCursor else { return false }
        return message.eventID == source.eventID
            && source.journal == journal
            && cursor.journal == journal
            && cursor.eventID == source.eventID
            && cursor.sequence > 0
    }

    private static func checkpointDigestUsable(
        _ cursor: JournalCursor, digest: String?
    ) -> Bool {
        cursor.sequence == 0 ? validPrefixDigest(digest) : digest != nil && validPrefixDigest(digest)
    }

    private static func validControlCheckpointCursor(
        _ cursor: JournalCursor?, host: String
    ) -> Bool {
        guard let cursor else { return true }
        return validControlCursor(cursor, expectedHost: WorkHostRef(host))
    }

    private static func validateReadAcknowledgements(
        in attachment: WorkServiceClientAttachment,
        workJournal: JournalRef,
        session: SessionRef,
        sessionJournal: JournalRef
    ) throws {
        guard attachment.readAcknowledgements.count <= WorkServiceBounds.maxReadAcknowledgementsPerAttachment else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        var targets = Set<WorkServiceReadTarget>()
        for acknowledgement in attachment.readAcknowledgements {
            guard targets.insert(acknowledgement.target).inserted,
                  acknowledgement.cursor.journal == acknowledgement.target.journal,
                  validCursor(acknowledgement.cursor, journal: acknowledgement.target.journal) else {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            switch acknowledgement.target {
            case .work(let journal):
                guard journal == workJournal else {
                    throw WorkServiceAttachedWorkControllerError.malformedResponse
                }
            case .session(let acknowledgedSession, let journal):
                guard acknowledgedSession == session, journal == sessionJournal else {
                    throw WorkServiceAttachedWorkControllerError.malformedResponse
                }
            }
        }
    }

    private static func validateAcknowledgementCursors(
        in attachment: WorkServiceClientAttachment,
        workCursor: JournalCursor,
        sessionCursor: JournalCursor
    ) throws {
        for acknowledgement in attachment.readAcknowledgements {
            let available: JournalCursor
            switch acknowledgement.target {
            case .work:
                available = workCursor
            case .session:
                available = sessionCursor
            }
            guard cursor(available, reaches: acknowledgement.cursor) else {
                // A host acknowledgement is not a license to skip unseen journal history. If
                // it claims a future cursor, reject this candidate and preserve the last paired
                // projection until a complete read can prove the same prefix.
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
        }
    }

    private static func acknowledgedCursor(
        for target: WorkServiceReadTarget,
        in attachment: WorkServiceClientAttachment
    ) -> JournalCursor? {
        attachment.readAcknowledgements.first(where: { $0.target == target })?.cursor
    }

    private static func validControlCursor(
        _ cursor: JournalCursor,
        expectedHost: WorkHostRef
    ) -> Bool {
        guard cursor.journal.owner == .workHost(expectedHost),
              cursor.journal.kind == .workHost,
              cursor.journal.authority.authorityID == expectedHost.workHostID else {
            return false
        }
        return validCursor(cursor, journal: cursor.journal)
    }

    private static func validPrefixDigest(_ digest: String?) -> Bool {
        guard let digest else { return true }
        let hex = digest.dropFirst("sha256:".count)
        return digest.hasPrefix("sha256:") && hex.count == 64
            && hex.allSatisfy { $0.isHexDigit }
    }

    private static func validAcknowledgementResponse(
        _ response: WorkServiceAcknowledgeReadResponse,
        request: WorkServiceAcknowledgeReadRequest,
        expectedHost: WorkHostRef
    ) -> Bool {
        guard response.work == request.work,
              response.target == request.target,
              response.cursor == request.cursor,
              response.commandID == request.commandID,
              response.causalControlCursor == request.causalControlCursor,
              response.host.host == expectedHost,
              response.receipt.operation == .acknowledgeRead,
              response.receipt.work == request.work,
              response.receipt.commandID == request.commandID,
              response.receipt.state == response.state,
              response.receipt.host == response.host,
              response.receipt.causalControlCursor == request.causalControlCursor,
              response.receipt.resultingControlCursor == response.resultingControlCursor,
              response.receipt.rejection == response.rejection,
              validControlCursor(response.resultingControlCursor, expectedHost: expectedHost) else {
            return false
        }
        switch response.state {
        case .accepted, .duplicate:
            return response.rejection == nil
                && response.receipt.outcome == .readAcknowledged
        case .rejected:
            return response.rejection != nil && response.receipt.outcome == nil
        }
    }

    private static func acknowledgementCommandID(
        work: WorkRef,
        attachment: ClientAttachmentRef,
        target: WorkServiceReadTarget,
        cursor: JournalCursor,
        causalControlCursor: JournalCursor
    ) -> String {
        let targetMaterial: String = switch target {
        case .work(let targetJournal):
            "work|\(targetJournal.journalID)|\(targetJournal.authority.authorityID)"
        case .session(let targetSession, let targetJournal):
            "session|\(targetSession.sessionID)|\(targetJournal.journalID)|\(targetJournal.authority.authorityID)"
        }
        let material = [
            work.workHostID, work.workID, attachment.attachmentID, targetMaterial,
            cursor.journal.journalID, String(cursor.sequence), cursor.eventID ?? "",
            causalControlCursor.journal.journalID, String(causalControlCursor.sequence),
            causalControlCursor.eventID ?? "",
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = AviarySHA256.hash(data: Data(material.utf8))
        return "read-ack-v1-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func attachmentByAcknowledging(
        target: WorkServiceReadTarget,
        cursor: JournalCursor,
        attachment: WorkServiceClientAttachment
    ) -> WorkServiceClientAttachment {
        var acknowledgements = attachment.readAcknowledgements.filter { $0.target != target }
        acknowledgements.append(WorkServiceReadAcknowledgement(target: target, cursor: cursor))
        acknowledgements.sort { lhs, rhs in
            let left = String(describing: lhs.target)
            let right = String(describing: rhs.target)
            if left != right { return left < right }
            return lhs.cursor.sequence < rhs.cursor.sequence
        }
        return WorkServiceClientAttachment(
            attachment: attachment.attachment, client: attachment.client,
            session: attachment.session, sessionJournal: attachment.sessionJournal,
            sessionAttachment: attachment.sessionAttachment,
            authorization: attachment.authorization,
            readAcknowledgements: acknowledgements)
    }

    private static func validateSnapshot(
        _ snapshot: WorkServiceSnapshot,
        target: WorkServiceReadTarget,
        targetJournal: JournalRef,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedSessionAttachment: SessionAttachmentRef,
        after: JournalCursor,
        pageLimit: Int,
        pageBytes: Int
    ) throws -> JournalCursor {
        guard snapshot.target == target else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        let cursor = try validateEvents(
            snapshot.events, target: target, targetJournal: targetJournal,
            expectedWork: expectedWork, expectedSession: expectedSession,
            expectedSessionAttachment: expectedSessionAttachment,
            after: after, pageLimit: pageLimit, pageBytes: pageBytes)
        guard let served = snapshot.servedCursor,
              served.journal == targetJournal,
              served == cursor else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        return cursor
    }

    private static func validateEventPage(
        _ page: WorkServiceEventPage,
        target: WorkServiceReadTarget,
        targetJournal: JournalRef,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedSessionAttachment: SessionAttachmentRef,
        after: JournalCursor,
        pageLimit: Int,
        pageBytes: Int
    ) throws -> JournalCursor {
        guard page.target == target else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        let cursor = try validateEvents(
            page.events, target: target, targetJournal: targetJournal,
            expectedWork: expectedWork, expectedSession: expectedSession,
            expectedSessionAttachment: expectedSessionAttachment,
            after: after, pageLimit: pageLimit, pageBytes: pageBytes)
        guard let served = page.servedCursor,
              served.journal == targetJournal, served == cursor else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        if page.events.isEmpty {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        return cursor
    }

    private static func validateEvents(
        _ events: [TimelineEvent],
        target: WorkServiceReadTarget,
        targetJournal: JournalRef,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedSessionAttachment: SessionAttachmentRef,
        after: JournalCursor,
        pageLimit: Int,
        pageBytes: Int
    ) throws -> JournalCursor {
        guard events.count <= pageLimit,
              events.count <= WorkServiceBounds.maxEventsPerPage,
              let encodedByteCount = try? WorkServiceEventPageSizing.encodedByteCount(of: events),
              encodedByteCount <= pageBytes else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        var sequence = after.sequence
        var previous = after.eventID
        var ids = Set<String>()
        for event in events {
            guard event.journal == targetJournal,
                  event.sequence > sequence,
                  event.sequence == sequence + 1,
                  event.sequence < Int.max,
                  validIdentity(event.eventID), ids.insert(event.eventID).inserted,
                  event.previousEventID == previous else {
                throw WorkServiceAttachedWorkControllerError.malformedResponse
            }
            switch target {
        case .work:
                // A Work-journal envelope must identify the Work and its authoritative host. A
                // missing identity is not a wildcard: accepting it would let a future/foreign
                // event mutate the seeded reducer without proving ownership.
                guard event.work == expectedWork,
                      event.workHost == WorkHostRef(expectedWork.workHostID) else {
                    throw WorkServiceAttachedWorkControllerError.malformedResponse
                }
            case .session:
                // A Session may record observations of multiple Works. Its Session identity and
                // journal are authoritative here; the final binding check decides whether the
                // requested Work/Session attachment is present and valid.
                guard event.session == expectedSession else {
                    throw WorkServiceAttachedWorkControllerError.malformedResponse
                }
                if event.sessionAttachment == expectedSessionAttachment {
                    guard event.work == nil || event.work == expectedWork
                        || event.type == TimelineEventType.sessionCreated else {
                        throw WorkServiceAttachedWorkControllerError.malformedResponse
                    }
                }
            }
            previous = event.eventID
            sequence = event.sequence
        }
        return JournalCursor(journal: targetJournal, eventID: previous, sequence: sequence)
    }

    private static func validateReducedBinding(
        work: WorkSnapshot,
        sessionSnapshot: SessionSnapshot,
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        journal: JournalRef,
        sessionJournal: JournalRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) throws {
        let workAttachmentIsCanonical = work.sessionAttachments[sessionAttachment.attachmentID].map {
            $0.session == session
                && $0.attachment == sessionAttachment
                && $0.isAttached
        } ?? false
        let descriptorRelationshipsWithID = descriptor.sessionAttachments.filter {
            $0.sessionAttachment == sessionAttachment
        }
        let descriptorRelationshipIsCanonical = descriptor.sessionAttachments.filter {
            $0.session == session
                && $0.sessionJournal == sessionJournal
                && $0.sessionAttachment == sessionAttachment
                && $0.isAttached
        }.count == 1
        // A client attachment envelope is not semantic Work/Session evidence. Require the
        // relationship in both the reduced Work state and the descriptor; if a bounded omission
        // makes that fact unknowable, this remains non-actionable rather than being guessed.
        guard descriptor.work == work.work,
              descriptor.journal == journal,
              journal.owner == .work(descriptor.work),
              journal.authority.authorityID == descriptor.work.workHostID,
              work.journal == journal,
              work.work == descriptor.work,
              work.workHost == WorkHostRef(descriptor.work.workHostID),
              work.lifecycle != .unknown,
              sessionSnapshot.journal == sessionJournal,
              sessionSnapshot.session == session,
              sessionSnapshot.lifecycle != .unknown,
              workAttachmentIsCanonical,
              descriptorRelationshipsWithID.count == 1,
              descriptorRelationshipIsCanonical,
              let sessionAttachmentState = sessionSnapshot.attachments[sessionAttachment.attachmentID],
              sessionAttachmentState.work == descriptor.work,
              sessionAttachmentState.attachment == sessionAttachment,
              sessionAttachmentState.isAttached,
              attachment.session == session,
              attachment.sessionJournal == sessionJournal,
              attachment.sessionAttachment == sessionAttachment else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard descriptor.currentRun == work.activeRun,
              descriptor.currentRunSession == work.activeRunSession,
              descriptor.currentRunSessionAttachment == work.activeRunSessionAttachment else {
            throw WorkServiceAttachedWorkControllerError.recoveryRequired
        }
        guard sessionJournal.owner == .session(session) else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
    }

    private static func attachmentProjection(
        in descriptor: WorkServiceWorkDescriptor,
        expected: WorkServiceClientAttachment
    ) throws -> WorkServiceClientAttachment? {
        let matches = descriptor.attachments.filter { $0.attachment == expected.attachment }
        guard matches.count <= 1 else {
            // Duplicate IDs are unsafe because first(where:) would make order matter.  A
            // missing row is allowed only for an existing controller's exact seed; its complete
            // Work/Session relationship is checked independently by validateReducedBinding.
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        guard let listed = matches.first else { return nil }
        guard listed.client == expected.client,
              listed.session == expected.session,
              listed.sessionJournal == expected.sessionJournal,
              listed.sessionAttachment == expected.sessionAttachment else {
            throw WorkServiceAttachedWorkControllerError.malformedResponse
        }
        return normalizedAttachment(listed)
    }

    private static func descriptorByUpdatingAttachment(
        _ descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment
    ) throws -> WorkServiceWorkDescriptor {
        try WorkServiceWorkDescriptor(
            work: descriptor.work, journal: descriptor.journal,
            recordedDisposition: descriptor.recordedDisposition, execution: descriptor.execution,
            currentRun: descriptor.currentRun,
            currentRunSession: descriptor.currentRunSession,
            currentRunSessionAttachment: descriptor.currentRunSessionAttachment,
            configuration: descriptor.configuration,
            hostObservation: descriptor.hostObservation,
            attachments: descriptor.attachments.map {
                $0.attachment == attachment.attachment
                    ? normalizedAttachment(attachment) : normalizedAttachment($0)
            }, sessionAttachments: descriptor.sessionAttachments,
            artifacts: descriptor.artifacts, omissions: descriptor.omissions)
    }

    private static func normalizedAttachment(
        _ attachment: WorkServiceClientAttachment
    ) -> WorkServiceClientAttachment {
        WorkServiceClientAttachment(
            attachment: attachment.attachment, client: attachment.client,
            session: attachment.session, sessionJournal: attachment.sessionJournal,
            sessionAttachment: attachment.sessionAttachment,
            authorization: attachment.authorization,
            readAcknowledgements: attachment.readAcknowledgements.sorted {
                let left = ($0.target.journal.stableKey, $0.cursor.sequence,
                            $0.cursor.eventID ?? "")
                let right = ($1.target.journal.stableKey, $1.cursor.sequence,
                             $1.cursor.eventID ?? "")
                return left < right
            })
    }

    private static func descriptorsEquivalent(
        _ lhs: WorkServiceWorkDescriptor,
        _ rhs: WorkServiceWorkDescriptor
    ) throws -> Bool {
        func normalized(_ descriptor: WorkServiceWorkDescriptor)
            throws -> WorkServiceWorkDescriptor {
            try WorkServiceWorkDescriptor(
                work: descriptor.work, journal: descriptor.journal,
                recordedDisposition: descriptor.recordedDisposition,
                execution: descriptor.execution, currentRun: descriptor.currentRun,
                currentRunSession: descriptor.currentRunSession,
                currentRunSessionAttachment: descriptor.currentRunSessionAttachment,
                configuration: descriptor.configuration,
                hostObservation: descriptor.hostObservation,
                attachments: descriptor.attachments.map(normalizedAttachment).sorted {
                    $0.attachment.attachmentID < $1.attachment.attachmentID
                }, sessionAttachments: descriptor.sessionAttachments,
                artifacts: descriptor.artifacts, omissions: descriptor.omissions)
        }
        return try normalized(lhs) == normalized(rhs)
    }

    private static func validateRestoredPending(
        _ record: WorkServiceAttachedWorkIntentStore.Record,
        descriptor: WorkServiceWorkDescriptor,
        attachment: WorkServiceClientAttachment,
        sessionAttachment: SessionAttachmentRef
    ) throws {
        let request = record.request
        guard request.work == descriptor.work,
              request.journal == descriptor.journal,
              request.attachment == attachment.attachment,
              request.command.client == attachment.client,
              request.command.sessionAttachment == sessionAttachment,
              request.command.causalCursor == request.causalWorkCursor,
              validCursor(request.causalWorkCursor, journal: descriptor.journal),
              validIdentity(request.command.commandID),
              !request.valueWasTruncated,
              (request.value?.utf8.count ?? 0) <= WorkServiceBounds.maxCommandValueCharacters else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
    }

    private static func cursor(_ candidate: JournalCursor, reaches required: JournalCursor) -> Bool {
        guard candidate.journal == required.journal,
              candidate.sequence >= required.sequence else { return false }
        return candidate.sequence > required.sequence || candidate.eventID == required.eventID
    }

    private static func validateSeed(_ seed: WorkServiceAttachedWorkSeed) throws {
        let descriptor = seed.work
        let attachment = seed.attachment
        guard Set(descriptor.attachments.map(\.attachment)).count == descriptor.attachments.count,
              Set(descriptor.sessionAttachments.map(\.sessionAttachment)).count
                  == descriptor.sessionAttachments.count else {
            throw WorkServiceAttachedWorkControllerError.invalidSeed
        }
        guard validIdentity(descriptor.work.workHostID), validIdentity(descriptor.work.workID),
              validIdentity(descriptor.journal.journalID),
              descriptor.journal.owner == .work(descriptor.work),
              descriptor.journal.authority.authorityID == descriptor.work.workHostID,
              validIdentity(descriptor.journal.authority.authorityID),
              descriptor.journal.kind == .work,
              validIdentity(attachment.client.clientID),
              validIdentity(attachment.attachment.attachmentID),
              let session = attachment.session,
              let sessionJournal = attachment.sessionJournal,
              let sessionAttachment = attachment.sessionAttachment,
              validIdentity(session.sessionID),
              validIdentity(sessionJournal.journalID),
              validIdentity(sessionAttachment.attachmentID),
              sessionJournal.owner == .session(session),
              sessionJournal.authority.authorityID == descriptor.work.workHostID,
              validIdentity(sessionJournal.authority.authorityID),
              sessionJournal.kind == .session,
              descriptor.sessionAttachments.filter({
                  $0.session == session
                      && $0.sessionJournal == sessionJournal
                      && $0.sessionAttachment == sessionAttachment
                      && $0.isAttached
              }).count == 1 else {
            throw WorkServiceAttachedWorkControllerError.invalidSeed
        }
        if let observation = descriptor.hostObservation {
            guard observation.instance.host == WorkHostRef(descriptor.work.workHostID) else {
                throw WorkServiceAttachedWorkControllerError.invalidSeed
            }
        }
        switch seed {
        case .created(let response):
            let controlJournal = JournalRef.workHost(WorkHostRef(descriptor.work.workHostID))
            let listedAttachments = descriptor.attachments.filter {
                $0.attachment == attachment.attachment
            }
            let attachmentOmitted = descriptor.omissions.contains { $0.category == "attachments" }
            guard listedAttachments.count == 1
                || (listedAttachments.isEmpty && attachmentOmitted) else {
                throw WorkServiceAttachedWorkControllerError.invalidSeed
            }
            let listedAttachment = listedAttachments.first
            guard response.work == descriptor,
                  response.session == session,
                  response.sessionJournal == sessionJournal,
                  response.sessionAttachment == sessionAttachment,
                  response.attachment == attachment,
                  response.authorization == attachment.authorization,
                  response.workCursor.journal == descriptor.journal,
                  response.sessionCursor.journal == sessionJournal,
                  validCursor(response.workCursor, journal: descriptor.journal),
                  validCursor(response.sessionCursor, journal: sessionJournal),
                  response.controlCursor.journal == controlJournal,
                  validCursor(response.controlCursor, journal: controlJournal),
                  response.receipt.operation == .createWork,
                  response.receipt.work == descriptor.work,
                  validIdentity(response.receipt.commandID),
                  response.receipt.state == .accepted,
                  response.receipt.host.host == WorkHostRef(descriptor.work.workHostID),
                  validIdentity(response.receipt.host.instanceID),
                  validIdentity(response.receipt.host.startIdentity),
                  response.receipt.causalControlCursor.journal == controlJournal,
                  response.receipt.causalControlCursor.sequence
                      <= response.controlCursor.sequence,
                  response.receipt.resultingControlCursor == response.controlCursor,
                  validCursor(response.receipt.causalControlCursor, journal: controlJournal),
                  response.receipt.authorization == response.authorization,
                  response.receipt.outcome == .created,
                  response.receipt.rejection == nil,
                  listedAttachment?.client == attachment.client,
                  listedAttachment?.session == attachment.session,
                  listedAttachment?.sessionJournal == attachment.sessionJournal,
                  listedAttachment?.sessionAttachment == attachment.sessionAttachment else {
                throw WorkServiceAttachedWorkControllerError.invalidSeed
            }
        case .existing(let existingDescriptor, let existingAttachment):
            guard existingDescriptor == descriptor,
                  existingAttachment == attachment else {
                throw WorkServiceAttachedWorkControllerError.invalidSeed
            }
            let listedAttachments = descriptor.attachments.filter {
                $0.attachment == attachment.attachment
            }
            let attachmentOmitted = descriptor.omissions.contains { $0.category == "attachments" }
            guard listedAttachments.count == 1
                || (listedAttachments.isEmpty && attachmentOmitted) else {
                throw WorkServiceAttachedWorkControllerError.invalidSeed
            }
            if let listed = listedAttachments.first {
                guard listed.client == attachment.client,
                      listed.session == attachment.session,
                      listed.sessionJournal == attachment.sessionJournal,
                      listed.sessionAttachment == attachment.sessionAttachment else {
                    throw WorkServiceAttachedWorkControllerError.invalidSeed
                }
            }
        }
    }

    private static func validDescriptor(
        _ descriptor: WorkServiceWorkDescriptor,
        expected: WorkRef,
        expectedJournal: JournalRef,
        expectedHostInstance: WorkHostInstanceRef? = nil
    ) -> Bool {
        guard descriptor.work == expected,
              descriptor.journal == expectedJournal,
              descriptor.journal.owner == .work(expected),
              descriptor.journal.authority.authorityID == expected.workHostID else {
            return false
        }
        guard let expectedHostInstance else {
            return descriptor.hostObservation.map {
                $0.instance.host == WorkHostRef(expected.workHostID)
            } ?? true
        }
        guard let observation = descriptor.hostObservation else { return false }
        return observation.instance == expectedHostInstance
    }

    private static func validHistoryAuthority(
        _ authority: WorkServiceHistoryAuthority,
        expected: WorkRef,
        expectedJournal: JournalRef,
        expectedHostInstance: WorkHostInstanceRef?
    ) -> Bool {
        guard authority.work == expected,
              authority.journal == expectedJournal,
              authority.journal.owner == .work(expected),
              authority.journal.authority.authorityID == expected.workHostID,
              authority.hostInstance.host == WorkHostRef(expected.workHostID),
              validIdentity(authority.hostInstance.instanceID),
              validIdentity(authority.hostInstance.startIdentity) else {
            return false
        }
        return expectedHostInstance.map { authority.hostInstance == $0 } ?? true
    }

    private static func validCursor(_ cursor: JournalCursor, journal: JournalRef) -> Bool {
        cursor.journal == journal && cursor.sequence >= 0 && cursor.sequence < Int.max
            && (cursor.sequence == 0 ? cursor.eventID == nil : cursor.eventID.map(validIdentity) != nil)
    }

    private static func validHandshake(
        _ handshake: WorkServiceHandshakeResponse,
        expectedHost: WorkHostRef
    ) -> Bool {
        let controlJournal = JournalRef.workHost(expectedHost)
        return handshake.accepted
            && validIdentity(expectedHost.workHostID)
            && handshake.host == expectedHost
            && handshake.hostInstance.host == expectedHost
            && validIdentity(handshake.hostInstance.instanceID)
            && validIdentity(handshake.hostInstance.startIdentity)
            && (handshake.negotiatedVersion.map {
                handshake.supportedRange.contains($0)
            } ?? true)
            && handshake.controlJournal == controlJournal
            && validCursor(handshake.controlCursor, journal: controlJournal)
    }

    private static func serviceExecution(_ execution: WorkExecution)
        -> WorkServiceExecutionState? {
        switch execution {
        case .idle: return .idle
        case .running: return .running
        case .canceling: return .canceling
        case .held: return .held
        case .unknown, .preparing, .failed: return nil
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
    }

    private static func hasPagingOmission(_ omissions: [WorkServiceOmission]) -> Bool {
        omissions.contains { $0.category == "events" || $0.category == "event_bytes" }
    }

    private static func boundedOmissions(_ omissions: [WorkServiceOmission]) -> [WorkServiceOmission] {
        guard omissions.count > WorkServiceAttachedWorkControllerBounds.maxOmissions else {
            return omissions
        }
        let retained = WorkServiceAttachedWorkControllerBounds.maxOmissions - 1
        return Array(omissions.prefix(retained)) + [WorkServiceOmission(
            category: "controller_omissions", count: omissions.count - retained,
            diagnostic: "additional read omissions were bounded")]
    }

    private static func mapReadError(_ error: Error) -> WorkServiceAttachedWorkControllerError {
        if let error = error as? WorkServiceAttachedWorkControllerError { return error }
        if case WorkServiceProtocolError.sourceIncomplete = error { return .sourceIncomplete }
        if case WorkServiceTransportError.remote(let code, _) = error {
            switch code {
            case .sourceIncomplete, .eventPageCannotProgress:
                return .sourceIncomplete
            case .staleCursor:
                return .staleCursor
            case .identityMismatch:
                return .hostMismatch
            case .capabilityDenied:
                return .capabilityDenied(.observe)
            default:
                break
            }
        }
        return .transportFailure
    }

    private static func valueDigest(_ value: String?) -> String? {
        guard let value else { return nil }
        let digest = AviarySHA256.hash(data: Data(value.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func map(_ state: WorkServiceClientSessionState)
        -> WorkServiceAttachedWorkConnectivity {
        switch state {
        case .disconnected: return .disconnected
        case .discovering: return .discovering
        case .connecting(let host): return .connecting(host)
        case .connected(let instance): return .connected(instance)
        case .reconnecting(let host): return .reconnecting(host)
        case .unavailable(let host): return .unavailable(host)
        case .incompatible(let host): return .incompatible(host)
        }
    }
}

private enum WorkServiceAttachedWorkControllerBounds {
    static let maxPages = 256
    static let maxOmissions = 32
    static let maxDiagnostics = 32
    static let historyWindowMessages = 768
    static let historyWindowBytes = 512 * 1024
}
