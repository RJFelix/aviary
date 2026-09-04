import Foundation

/// The small set of transitions for which Aviary currently has enough canonical evidence to
/// notify a person. This is deliberately narrower than the full attention vocabulary: a
/// notification is an external side effect and must never be inferred from an unavailable row.
public enum CanonicalNotificationKind: String, Codable, Hashable, Sendable {
    case needsYou = "needs_you"
    case failedRecovery = "failed_recovery"
    case readyForReview = "ready_for_review"
}

/// The state observed for a canonical Session during delivery. `none` is retained even when
/// there is no candidate, allowing a later return to attention to be recognized as a transition.
public enum CanonicalNotificationState: String, Codable, Hashable, Sendable {
    case none
    case needsYou = "needs_you"
    case failedRecovery = "failed_recovery"
    case readyForReview = "ready_for_review"
}

/// The identity a notification action can hand back to the Session workspace. It is a typed
/// identity rather than a path or a filename, so arbitrary local IDs cannot alias one another.
public struct CanonicalNotificationActionIdentity: Codable, Hashable, Sendable {
    public let session: SessionRef
    public let sessionJournal: JournalRef
    /// The Work-qualified recovery target. An ActionRef by itself is not globally unique.
    public let work: WorkRef?
    public let workJournal: JournalRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let action: ActionRef?
    public let outcome: ActionExecutionState?

    public init(session: SessionRef, sessionJournal: JournalRef, work: WorkRef? = nil,
                workJournal: JournalRef? = nil, sessionAttachment: SessionAttachmentRef? = nil,
                action: ActionRef? = nil, outcome: ActionExecutionState? = nil) {
        self.session = session
        self.sessionJournal = sessionJournal
        self.work = work
        self.workJournal = workJournal
        self.sessionAttachment = sessionAttachment
        self.action = action
        self.outcome = outcome
    }

    public var stableKey: String {
        var value = "notification-action|journal:\(Self.field(sessionJournal.stableKey))"
            + "|session:\(Self.field(session.sessionID))"
        if let work {
            value += "|work-host:\(Self.field(work.workHostID))|work:\(Self.field(work.workID))"
        }
        if let workJournal { value += "|work-journal:\(Self.field(workJournal.stableKey))" }
        if let sessionAttachment { value += "|attachment:\(Self.field(sessionAttachment.attachmentID))" }
        if let action { value += "|action:\(Self.field(action.actionID))" }
        if let outcome { value += "|outcome:\(Self.field(outcome.rawValue))" }
        return value
    }

    private static func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
}

/// One canonical notification candidate. `sourceCursor` is the exact Session read cursor used
/// to establish the candidate, and is retained so a delivery can deep-link to evidence without
/// pretending that a legacy transcript or current filesystem state is its source.
public struct CanonicalNotificationCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: CanonicalNotificationKind
    public let title: String
    public let body: String
    public let actionIdentity: CanonicalNotificationActionIdentity
    public let sourceCursor: JournalCursor
    public let sourceEvent: EventRef?
    /// The exact Work read cursor used for the action evidence, when the candidate is Work-backed.
    public let workCursor: JournalCursor?
    /// Stable source identity prevents repeated `.review` (or another same-kind) transitions
    /// from being mistaken for the same notification after a new canonical event is appended.
    public let transitionFingerprint: String

    public init(
        kind: CanonicalNotificationKind, title: String, body: String,
        actionIdentity: CanonicalNotificationActionIdentity, sourceCursor: JournalCursor,
        sourceEvent: EventRef? = nil, workCursor: JournalCursor? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.actionIdentity = actionIdentity
        self.sourceCursor = sourceCursor
        self.sourceEvent = sourceEvent
        self.workCursor = workCursor
        let source = sourceEvent.map { "event:\($0.journal.stableKey):\($0.eventID)" }
            ?? "cursor:\(sourceCursor.journal.stableKey):\(sourceCursor.sequence):\(sourceCursor.eventID ?? "")"
        self.transitionFingerprint = "\(kind.rawValue)|\(source)|\(actionIdentity.stableKey)"
        let digest = AviarySHA256.hash(data: Data(self.transitionFingerprint.utf8))
            .map { String(format: "%02x", $0) }.joined()
        // Keep the OS request identifier fixed-size and free of user-controlled path/ID bytes.
        self.id = "notification:v2|\(kind.rawValue)|\(digest)"
    }

    /// The only payload sent to UserNotifications. The route is intentionally one bounded,
    /// base64-encoded JSON value: adding another identity key here would make click routing
    /// vulnerable to partially-updated/ad-hoc fields.
    public var route: CanonicalNotificationRoute {
        CanonicalNotificationRoute(
            kind: kind, session: actionIdentity.session,
            sessionJournal: actionIdentity.sessionJournal, work: actionIdentity.work,
            workJournal: actionIdentity.workJournal,
            sessionAttachment: actionIdentity.sessionAttachment, action: actionIdentity.action,
            outcome: actionIdentity.outcome, sourceSessionCursor: sourceCursor,
            sourceSessionEvent: sourceEvent, workCursor: workCursor)
    }

    public var routeUserInfo: [AnyHashable: Any]? { route.userInfo }

}

/// A complete, typed cold-click route for a canonical notification.
///
/// This is deliberately owned by AviaryCore so the app delegate, AppModel, and self-tests all
/// use the same validation boundary. JSON is wrapped in base64 because UserNotifications accepts
/// property-list values, not arbitrary `Data`; the encoded value is capped before it reaches the
/// OS or a cold-click queue.
public struct CanonicalNotificationRoute: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public static let userInfoKey = "aviary.notification.route"
    public static let maximumEncodedBytes = 8 * 1024

    public let version: Int
    public let kind: CanonicalNotificationKind
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let work: WorkRef?
    public let workJournal: JournalRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let action: ActionRef?
    public let outcome: ActionExecutionState?
    public let sourceSessionCursor: JournalCursor
    public let sourceSessionEvent: EventRef?
    public let workCursor: JournalCursor?

    public init(
        kind: CanonicalNotificationKind, session: SessionRef, sessionJournal: JournalRef,
        work: WorkRef? = nil, workJournal: JournalRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil, action: ActionRef? = nil,
        outcome: ActionExecutionState? = nil, sourceSessionCursor: JournalCursor,
        sourceSessionEvent: EventRef? = nil, workCursor: JournalCursor? = nil
    ) {
        self.version = Self.schemaVersion
        self.kind = kind
        self.session = session
        self.sessionJournal = sessionJournal
        self.work = work
        self.workJournal = workJournal
        self.sessionAttachment = sessionAttachment
        self.action = action
        self.outcome = outcome
        self.sourceSessionCursor = sourceSessionCursor
        self.sourceSessionEvent = sourceSessionEvent
        self.workCursor = workCursor
    }

    /// A stable in-memory/dictionary key. It is not persisted in the route, and length-prefixing
    /// ensures user-controlled IDs cannot collide.
    public var sessionIdentityKey: String {
        CanonicalAttentionIdentity.sessionRow(journal: sessionJournal)
    }

    /// Bounded route identity for queue deduplication. The raw typed references remain in the
    /// route itself, while queue bookkeeping never retains an attacker-sized identity string.
    public var deduplicationKey: String {
        let value = encodedValue ?? "invalid"
        return AviarySHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var encodedValue: String? {
        guard identityFieldsWithinBounds else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        let encoded = data.base64EncodedString()
        guard encoded.utf8.count <= Self.maximumEncodedBytes else { return nil }
        return encoded
    }

    public var userInfo: [AnyHashable: Any]? {
        guard isValid, let encodedValue else { return nil }
        return [Self.userInfoKey: encodedValue]
    }

    /// Decode only the canonical route field and reject oversized, malformed, or identity
    /// inconsistent payloads. Extra keys are ignored so OS metadata cannot break a valid click,
    /// but Aviary never emits them.
    public static func decode(userInfo: [AnyHashable: Any]) -> CanonicalNotificationRoute? {
        guard let encoded = userInfo[Self.userInfoKey] as? String,
              encoded.utf8.count <= Self.maximumEncodedBytes,
              let data = Data(base64Encoded: encoded),
              let route = try? JSONDecoder().decode(Self.self, from: data),
              route.version == Self.schemaVersion,
              route.isValid
        else { return nil }
        return route
    }

    /// Validate journal ownership and cursor provenance before a route is allowed to select a
    /// Session. A cursor from a Work journal must never be mistaken for Session evidence.
    public var isValid: Bool {
        guard identityFieldsWithinBounds,
              sourceSessionCursor.sequence > 0,
              let sourceEventID = sourceSessionCursor.eventID,
              !sourceEventID.isEmpty,
              sourceSessionEvent.map({ !$0.eventID.isEmpty }) ?? true,
              workCursor.map({ $0.sequence > 0 && ($0.eventID?.isEmpty == false) }) ?? true,
              case .session(let owner) = sessionJournal.owner, owner == session,
              sourceSessionCursor.journal == sessionJournal,
              sourceSessionEvent.map({ $0.journal == sessionJournal }) ?? true
        else { return false }
        if let work {
            guard let workJournal,
                  case .work(let journalWork) = workJournal.owner,
                  journalWork == work,
                  workJournal.authority.authorityID == work.workHostID
            else { return false }
            if let workCursor, workCursor.journal != workJournal { return false }
        } else if workJournal != nil || workCursor != nil || sessionAttachment != nil || action != nil {
            return false
        }
        switch kind {
        case .failedRecovery:
            return work != nil && sessionAttachment != nil && action != nil
                && outcome == .indeterminateEffect && workCursor != nil
        case .needsYou, .readyForReview:
            return work == nil && workJournal == nil && sessionAttachment == nil
                && action == nil && outcome == nil && workCursor == nil
        }
    }

    private var identityFieldsWithinBounds: Bool {
        let values: [String] = [
            session.sessionID, sessionJournal.journalID, sessionJournal.authority.authorityID,
            work?.workHostID, work?.workID, workJournal?.journalID,
            workJournal?.authority.authorityID, sessionAttachment?.attachmentID,
            action?.actionID, outcome?.rawValue, sourceSessionCursor.eventID,
            sourceSessionEvent?.eventID, workCursor?.eventID
        ].compactMap { $0 }
        return values.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
    }
}

/// The notification-facing projection of canonical Session/Work summaries.
///
/// This performs its own complete conflict grouping rather than consuming the attention inbox's
/// display cap. A bounded result is explicit: delivery must withhold all candidates when the
/// source was truncated, so a notification is never silently missed because a UI page was full.
public struct CanonicalNotificationProjection: Codable, Hashable, Sendable {
    public static let maximumCandidateCount = 512
    public let candidates: [CanonicalNotificationCandidate]
    public let omittedCandidateCount: Int
    public let conflictingSessionCount: Int
    public let omittedStateCount: Int
    public let sourceComplete: Bool
    public let observedFingerprints: [String: String]
    /// Exact, known Session states including `.none`; keys are authority-qualified identities.
    public let observedStates: [String: CanonicalNotificationState]

    public var isComplete: Bool {
        // Conflicts are row-local: conflicting facts are omitted while unrelated exact Sessions
        // remain safe to transition. Only source truncation/omission blocks the whole projection.
        sourceComplete && omittedCandidateCount == 0 && omittedStateCount == 0
    }

    /// Resolve the exact route currently supported by this projection. Equality intentionally
    /// includes Session/Work/action identity plus both evidence cursors, so a stale click cannot
    /// be treated as the same transition merely because it names the same Session.
    public func candidate(matching route: CanonicalNotificationRoute)
        -> CanonicalNotificationCandidate? {
        guard route.isValid else { return nil }
        return candidates.first { $0.route == route }
    }

    public init(
        summaries: [CanonicalSessionCatalogSummary],
        maxCandidates: Int = CanonicalNotificationProjection.maximumCandidateCount,
        sourceComplete: Bool = true
    ) {
        let grouped = Dictionary(grouping: summaries, by: \.journal)
        var conflicts = 0
        var candidates: [CanonicalNotificationCandidate] = []
        var observedStates: [String: CanonicalNotificationState] = [:]
        var observedFingerprints: [String: String] = [:]
        for group in grouped.values {
            guard let summary = group.first else { continue }
            guard group.count == 1 else {
                conflicts += 1
                continue
            }
            let row = CanonicalAttentionInboxRow(
                summary: summary,
                maxAttachments: CanonicalAttentionInboxProjection.maximumAttachmentCount)
            let key = CanonicalAttentionIdentity.sessionRow(journal: summary.journal)
            let rowKnown = row.sessionCursorAlignment == .exact
                && row.sessionIntegrityValid == true
                && row.sessionStructuralIntegrityValid
                && row.sessionSemanticProjectionValid
                && row.duplicateSummaryCount == 1
            guard rowKnown else { continue }
            // A missing effective attention is an incomplete Work/attachment projection, not
            // evidence for `.none`. Treating it as none would create a false transition when
            // the exact Work prefix becomes readable again.
            guard let attention = row.effectiveAttention,
                  let cursor = row.sessionSourceCursor,
                  row.attentionRequirement != .unknown else {
                continue
            }

            let kind: CanonicalNotificationKind
            let action: ActionRef?
            let actionWork: CanonicalWorkCatalogSummary?
            switch attention {
            case .error:
                // An indeterminate effect is a recovery boundary, not an ordinary error. Keep
                // the action identity when one exists so a click can land on the right card.
                let indeterminateActions = summary.work.flatMap { work in
                    guard work.canProjectExecution, let journal = work.journal else {
                        return [(work: CanonicalWorkCatalogSummary, actionID: String, key: String)]()
                    }
                    return work.indeterminateActionIDs.map { actionID in
                        (work: work, actionID: actionID,
                         key: journal.stableKey
                            + "|attachment:\(work.attachment.attachmentID.utf8.count):"
                            + work.attachment.attachmentID
                            + "|action:\(actionID.utf8.count):" + actionID)
                    }
                }.sorted { lhs, rhs in
                    lhs.key < rhs.key
                }
                if let selected = indeterminateActions.first {
                    kind = .failedRecovery
                    action = ActionRef(selected.actionID)
                    actionWork = selected.work
                } else {
                    kind = .needsYou
                    action = nil
                    actionWork = nil
                }
            case .input, .confirmation:
                kind = .needsYou
                action = nil
                actionWork = nil
            case .review:
                kind = .readyForReview
                action = nil
                actionWork = nil
            case .none:
                observedStates[key] = CanonicalNotificationState.none
                observedFingerprints[key] = Self.fingerprint(
                    state: .none, cursor: cursor, sourceEvent: summary.attentionSourceEvent)
                continue
            }
            let title: String
            switch kind {
            case .needsYou: title = "Aviary needs your attention"
            case .failedRecovery: title = "Aviary needs recovery review"
            case .readyForReview: title = "Aviary work is ready for review"
            }
            let body: String
            switch kind {
            case .failedRecovery:
                body = "An action has an uncertain external effect and needs your review."
            case .needsYou:
                body = attention == .confirmation
                    ? "A confirmation is waiting for you."
                    : "This session needs your attention."
            case .readyForReview:
                body = "The run is ready for review."
            }
            let candidate = CanonicalNotificationCandidate(
                kind: kind, title: title, body: body,
                actionIdentity: CanonicalNotificationActionIdentity(
                    session: summary.session, sessionJournal: summary.journal,
                    work: actionWork?.work, workJournal: actionWork?.journal,
                    sessionAttachment: actionWork?.attachment,
                    action: action, outcome: action == nil ? nil : .indeterminateEffect),
                sourceCursor: cursor, sourceEvent: summary.attentionSourceEvent,
                workCursor: actionWork?.workReadCursor ?? actionWork?.observedCursor)
            candidates.append(candidate)
            observedStates[key] = CanonicalNotificationState(kind: kind)
            observedFingerprints[key] = candidate.transitionFingerprint
        }
        candidates.sort { $0.id < $1.id }
        let bounded = min(max(0, maxCandidates), Self.maximumCandidateCount)
        self.omittedCandidateCount = max(0, candidates.count - bounded)
        self.conflictingSessionCount = conflicts
        let stateKeys = observedStates.keys.sorted()
        let stateLimit = Self.maximumCandidateCount
        self.omittedStateCount = max(0, stateKeys.count - stateLimit)
        self.sourceComplete = sourceComplete
        self.observedStates = Dictionary(uniqueKeysWithValues: stateKeys.prefix(stateLimit).compactMap {
            guard let value = observedStates[$0] else { return nil }
            return ($0, value)
        })
        self.observedFingerprints = Dictionary(uniqueKeysWithValues: stateKeys.prefix(stateLimit).compactMap {
            guard let value = observedFingerprints[$0] else { return nil }
            return ($0, value)
        })
        self.candidates = Array(candidates.prefix(bounded))
    }

    private static func fingerprint(
        state: CanonicalNotificationState, cursor: JournalCursor, sourceEvent: EventRef?
    ) -> String {
        let source = sourceEvent.map { "event:\($0.journal.stableKey):\($0.eventID)" }
            ?? "cursor:\(cursor.journal.stableKey):\(cursor.sequence):\(cursor.eventID ?? "")"
        return "\(state.rawValue)|\(source)"
    }
}

/// Stateful transition gate for notification delivery. The first complete observation is a
/// baseline; only later transitions into a notification state emit candidates. Unknown or
/// incomplete scans do not mutate the baseline, which prevents a partial read from causing a
/// duplicate when the exact state returns.
public struct CanonicalNotificationDelivery: Sendable {
    public static let maximumCheckpointSessions = 1_024

    private struct State: Codable, Hashable, Sendable {
        let state: CanonicalNotificationState
        let fingerprint: String?
    }

    public struct Plan: Sendable {
        public let candidates: [CanonicalNotificationCandidate]
        fileprivate init(candidates: [CanonicalNotificationCandidate]) { self.candidates = candidates }
    }

    private var stateBySession: [String: State] = [:]
    private var pendingBySession: [String: State] = [:]
    private var initialized = false

    public init() {}

    /// Restore the last acknowledged canonical observation for this local client. Pending
    /// platform requests are intentionally not restored: the next exact scan will retry any
    /// request whose acknowledgement was never committed.
    public init(checkpoint: Data?) {
        guard let checkpoint,
              let value = try? JSONDecoder().decode(Checkpoint.self, from: checkpoint)
        else { return }
        stateBySession = value.stateBySession
        initialized = value.initialized
        pruneState()
    }

    public var checkpointData: Data? {
        let bounded = boundedState()
        return try? JSONEncoder().encode(
            Checkpoint(stateBySession: bounded, initialized: initialized))
    }

    private struct Checkpoint: Codable, Sendable {
        let stateBySession: [String: State]
        let initialized: Bool
    }

    /// Plan external requests without advancing the durable observation. A caller must commit
    /// only after its platform add operation succeeds; rollback leaves the candidate retryable.
    public mutating func plan(_ projection: CanonicalNotificationProjection) -> Plan {
        guard projection.isComplete else { return Plan(candidates: []) }
        let current = Dictionary(uniqueKeysWithValues: projection.observedStates.map { key, state in
            (Self.key(for: key), State(
                state: state,
                fingerprint: projection.observedFingerprints[key].map(Self.fingerprint)))
        })
        guard initialized else {
            stateBySession = current
            initialized = true
            pruneState(retaining: Set(current.keys))
            return Plan(candidates: [])
        }
        var emitted: [CanonicalNotificationCandidate] = []
        for candidate in projection.candidates {
            let key = Self.key(for: candidate)
            let previous = stateBySession[key]
            let next = State(
                state: Self.state(for: candidate.kind),
                fingerprint: Self.fingerprint(candidate.transitionFingerprint))
            // The first complete projection establishes the no-notify baseline above. Once
            // initialized, a newly discovered Session entering attention is itself a new
            // transition; requiring an older per-Session state would permanently suppress the
            // ordinary "start Work, finish first turn" path.
            if pendingBySession[key] == nil, previous != next {
                pendingBySession[key] = next
                emitted.append(candidate)
            }
        }
        // Known `.none` rows are safe to advance immediately; candidate states await commit.
        for (key, state) in current where Self.isNone(state.state) {
            stateBySession[key] = state
        }
        pruneState(retaining: Set(current.keys))
        return Plan(candidates: emitted)
    }

    /// Record a complete observation while delivery is unauthorized. This advances the baseline
    /// without submitting requests, so enabling notifications later does not replay old attention.
    public mutating func baseline(_ projection: CanonicalNotificationProjection) {
        guard projection.isComplete else { return }
        let current = Dictionary(uniqueKeysWithValues: projection.observedStates.map { key, state in
            (Self.key(for: key), State(
                state: state,
                fingerprint: projection.observedFingerprints[key].map(Self.fingerprint)))
        })
        guard !current.isEmpty || !initialized else { return }
        if initialized {
            for (key, state) in current { stateBySession[key] = state }
        } else {
            stateBySession = current
            initialized = true
        }
        pruneState(retaining: Set(current.keys))
    }

    public mutating func commit(_ candidate: CanonicalNotificationCandidate) {
        let key = Self.key(for: candidate)
        stateBySession[key] = State(
            state: Self.state(for: candidate.kind),
            fingerprint: Self.fingerprint(candidate.transitionFingerprint))
        pendingBySession.removeValue(forKey: key)
        pruneState(retaining: [key])
    }

    public mutating func rollback(_ candidate: CanonicalNotificationCandidate) {
        pendingBySession.removeValue(forKey: Self.key(for: candidate))
    }

    private static func key(for candidate: CanonicalNotificationCandidate) -> String {
        key(for: CanonicalAttentionIdentity.sessionRow(journal: candidate.actionIdentity.sessionJournal))
    }

    private static func key(for identity: String) -> String { "session:v1:" + digest(identity) }

    private static func fingerprint(_ value: String) -> String { "fingerprint:v1:" + digest(value) }

    private static func digest(_ value: String) -> String {
        AviarySHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func pruneState(retaining requested: Set<String> = []) {
        guard stateBySession.count > Self.maximumCheckpointSessions else { return }
        let pendingKeys = Set(pendingBySession.keys)
        let required = requested.union(pendingKeys)
        let requiredKept = required.sorted().prefix(Self.maximumCheckpointSessions)
        let requiredState = Set(requiredKept).intersection(stateBySession.keys)
        let optional = stateBySession.keys.filter { !requiredState.contains($0) }.sorted()
        let optionalLimit = max(0, Self.maximumCheckpointSessions - requiredKept.count)
        let kept = Array(requiredKept) + optional.prefix(optionalLimit)
        let keys = Set(kept)
        stateBySession = stateBySession.filter { keys.contains($0.key) }
        pendingBySession = pendingBySession.filter { keys.contains($0.key) }
    }

    private func boundedState() -> [String: State] {
        let pendingKeys = Set(pendingBySession.keys)
        let required = pendingKeys.intersection(stateBySession.keys)
        let optional = stateBySession.keys.filter { !required.contains($0) }.sorted()
        let requiredKept = required.sorted().prefix(Self.maximumCheckpointSessions)
        let optionalLimit = max(0, Self.maximumCheckpointSessions - requiredKept.count)
        let kept = Array(requiredKept) + optional.prefix(optionalLimit)
        let keys = Set(kept)
        return stateBySession.filter { keys.contains($0.key) }
    }

    private static func isNone(_ state: CanonicalNotificationState) -> Bool { state == .none }


    private static func state(for kind: CanonicalNotificationKind) -> CanonicalNotificationState {
        switch kind {
        case .failedRecovery: return .failedRecovery
        case .needsYou: return .needsYou
        case .readyForReview: return .readyForReview
        }
    }
}

private extension CanonicalNotificationState {
    init(kind: CanonicalNotificationKind) {
        switch kind {
        case .needsYou: self = .needsYou
        case .failedRecovery: self = .failedRecovery
        case .readyForReview: self = .readyForReview
        }
    }
}
