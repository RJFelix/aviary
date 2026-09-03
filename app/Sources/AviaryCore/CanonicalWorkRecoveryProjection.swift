import CryptoKit
import Foundation

/// A presentation state explicitly reported by an in-process Work observer. A filesystem row,
/// PID, or timestamp never creates one of these observations.
public enum CanonicalWorkRecoveryObservationPresentation: String, Codable, Hashable, Sendable {
    case attached
    case detached
    case ended
}

/// One explicit client's Work/session attachment observation. This is deliberately not a Work
/// Host liveness claim: the current in-process producer can describe its own presentation, while
/// a future Work service will supply a separate, generation-qualified host observation.
public struct CanonicalWorkRecoveryObservation: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let workJournal: JournalRef
    public let session: SessionRef
    public let sessionAttachment: SessionAttachmentRef
    public let run: RunRef
    public let client: ClientRef
    public let clientAttachment: ClientAttachmentRef
    public let presentation: CanonicalWorkRecoveryObservationPresentation
    public let canReattach: Bool
    public let canControl: Bool

    public init(
        work: WorkRef, workJournal: JournalRef, session: SessionRef,
        sessionAttachment: SessionAttachmentRef, run: RunRef,
        client: ClientRef, clientAttachment: ClientAttachmentRef,
        presentation: CanonicalWorkRecoveryObservationPresentation,
        canReattach: Bool, canControl: Bool
    ) {
        self.work = work
        self.workJournal = workJournal
        self.session = session
        self.sessionAttachment = sessionAttachment
        self.run = run
        self.client = client
        self.clientAttachment = clientAttachment
        self.presentation = presentation
        self.canReattach = canReattach
        self.canControl = canControl
    }

    fileprivate var observerKey: String {
        [
            workJournal.stableKey, session.sessionID, sessionAttachment.attachmentID,
            run.runID, client.clientID, clientAttachment.attachmentID
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "/")
    }

    fileprivate func identityIsValid(maxCharacters: Int) -> Bool {
        guard !work.workHostID.isEmpty, !work.workID.isEmpty,
              !workJournal.journalID.isEmpty, !workJournal.authority.authorityID.isEmpty,
              !session.sessionID.isEmpty, !sessionAttachment.attachmentID.isEmpty,
              !run.runID.isEmpty,
              case .work(let owner) = workJournal.owner, owner == work,
              workJournal.authority.authorityID == work.workHostID
        else { return false }
        guard !client.clientID.isEmpty, !clientAttachment.attachmentID.isEmpty else { return false }
        let fields = [work.workHostID, work.workID, workJournal.journalID,
                      workJournal.authority.authorityID, session.sessionID,
                      sessionAttachment.attachmentID, run.runID,
                      client.clientID, clientAttachment.attachmentID]
        return fields.allSatisfy { $0.utf8.count <= maxCharacters }
    }
}

/// The fail-closed durable disposition for one authority-qualified Work journal. `recordedActive`
/// means exactly that the last canonical record left the Work active; it is not proof that a Work
/// Host is currently reachable or even alive.
public enum CanonicalWorkRecoveryDisposition: String, Codable, Hashable, Sendable {
    case recordedActive = "recorded_active"
    case completedEvidence = "completed_evidence"
    case uncertain
    case corrupt
    case ambiguous
}

/// The current observing client's presentation state, kept orthogonal to durable Work state so
/// several GUIs can attach and detach independently.
public enum CanonicalWorkRecoveryClientDisposition: String, Codable, Hashable, Sendable {
    case notRequested = "not_requested"
    case unobserved
    case observedAttached = "observed_attached"
    case observedReattachable = "observed_reattachable"
    case observedDetached = "observed_detached"
    case observedEnded = "observed_ended"
    case unverified
    case ambiguous
}

/// A bounded, source-qualified Session attachment fact joined to one Work.
public struct CanonicalWorkRecoverySessionAttachment: Codable, Hashable, Sendable, Identifiable {
    public let session: SessionRef
    /// Nil for a Work-side attachment that has not yet been enriched by a Session catalog row.
    public let sessionJournal: JournalRef?
    public let attachment: SessionAttachmentRef
    public let requestedCursor: JournalCursor?
    public let observedCursor: JournalCursor?
    public let workReadCursor: JournalCursor?
    public let sessionCursor: JournalCursor?
    /// Cursor facts omitted because an identity exceeded this projection's configured bound.
    public let omittedCursorCount: Int
    public let attentionSourceEvent: EventRef?
    public let capabilities: [String]
    public let omittedCapabilityCount: Int
    public let recoveryCoverage: [RecordedRecoveryCoverage]
    public let omittedRecoveryCoverageCount: Int
    public let omittedRecoveryCaveatCount: Int
    public let isAttached: Bool
    public let isExact: Bool
    public let unknownDomains: [TimelineDomain]
    public let reasons: [String]
    public let omittedReasonCount: Int

    public var id: String {
        let raw = "session:\(session.sessionID)|journal:\(sessionJournal?.stableKey ?? "")|attachment:\(attachment.attachmentID)"
        return "session-attachment:v1/" + CanonicalWorkRecoveryProjection.digest(raw)
    }
}

/// A bounded Work-side client attachment fact. It does not assign ownership to that client.
public struct CanonicalWorkRecoveryClientAttachment: Codable, Hashable, Sendable, Identifiable {
    public let client: ClientRef
    public let attachment: ClientAttachmentRef
    public let cursor: JournalCursor?
    public let omittedCursorCount: Int
    public let capabilities: [String]
    public let omittedCapabilityCount: Int
    public let isAttached: Bool

    public var id: String { attachment.attachmentID }
}

/// Result of reconciling a notification route against the current Work catalog. This is a
/// read-only seam for callers that need to ensure action/cursor evidence is still current.
public struct CanonicalWorkRecoveryNotificationReconciliation: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let workJournal: JournalRef
    public let disposition: CanonicalWorkRecoveryDisposition
    public let workCursor: JournalCursor?
    public let action: LocalTimelineCatalog.ActionFact?
    public let matchesWorkCursor: Bool
    public let matchesSessionEvidence: Bool
    public let exact: Bool
    public let reason: String?
}

/// Canonical recovery projection for Work independent of any one Session or GUI.
public struct CanonicalWorkRecoveryProjection: Codable, Hashable, Sendable {
    public struct Limits: Codable, Hashable, Sendable {
        public let maxRows: Int
        public let maxAttachmentsPerRow: Int
        public let maxReasonsPerRow: Int
        public let maxObservationsPerRow: Int
        public let maxRecoveryCoveragePerRow: Int
        public let maxRunFactsPerRow: Int
        public let maxActionFactsPerRow: Int
        public let maxHandleFactsPerRow: Int
        public let maxCommandFactsPerRow: Int
        public let maxUnknownRefsPerRow: Int
        public let maxCapabilitiesPerAttachment: Int
        public let maxIdentityCharacters: Int

        public init(
            maxRows: Int = 512, maxAttachmentsPerRow: Int = 256,
            maxReasonsPerRow: Int = 16, maxObservationsPerRow: Int = 16,
            maxRecoveryCoveragePerRow: Int = 64, maxActionFactsPerRow: Int = 128,
            maxRunFactsPerRow: Int = 256,
            maxHandleFactsPerRow: Int = 128, maxCommandFactsPerRow: Int = 128,
            maxUnknownRefsPerRow: Int = 64, maxCapabilitiesPerAttachment: Int = 16,
            maxIdentityCharacters: Int = 512
        ) {
            self.maxRows = max(1, maxRows)
            self.maxAttachmentsPerRow = max(1, maxAttachmentsPerRow)
            self.maxReasonsPerRow = max(1, maxReasonsPerRow)
            self.maxObservationsPerRow = max(1, maxObservationsPerRow)
            self.maxRecoveryCoveragePerRow = max(1, maxRecoveryCoveragePerRow)
            self.maxRunFactsPerRow = max(1, maxRunFactsPerRow)
            self.maxActionFactsPerRow = max(1, maxActionFactsPerRow)
            self.maxHandleFactsPerRow = max(1, maxHandleFactsPerRow)
            self.maxCommandFactsPerRow = max(1, maxCommandFactsPerRow)
            self.maxUnknownRefsPerRow = max(1, maxUnknownRefsPerRow)
            self.maxCapabilitiesPerAttachment = max(1, maxCapabilitiesPerAttachment)
            self.maxIdentityCharacters = max(1, maxIdentityCharacters)
        }
    }

    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let work: WorkRef?
        public let journal: JournalRef?
        public let workHost: WorkHostRef?
        public let disposition: CanonicalWorkRecoveryDisposition
        public let observingClient: ClientRef?
        public let clientDisposition: CanonicalWorkRecoveryClientDisposition
        public let clientCanControl: Bool
        public let lifecycle: WorkLifecycle?
        public let execution: WorkExecution?
        public let modelID: String?
        public let activeRun: RunRef?
        public let runHistory: [RunRef]
        public let omittedRunCount: Int
        public let activeTurn: TurnRef?
        /// The exact Work tip supplied by LocalTimelineCatalog, never a Session cursor substitute.
        public let cursor: JournalCursor?
        public let committedPrefixCursor: JournalCursor?
        public let omittedCursorCount: Int
        public let recoveryCoverage: [RecordedRecoveryCoverage]
        public let omittedRecoveryCoverageCount: Int
        public let omittedRecoveryCaveatCount: Int
        public let sessionAttachments: [CanonicalWorkRecoverySessionAttachment]
        public let omittedSessionAttachmentCount: Int
        public let clientAttachments: [CanonicalWorkRecoveryClientAttachment]
        public let omittedClientAttachmentCount: Int
        public let observations: [CanonicalWorkRecoveryObservation]
        public let omittedObservationCount: Int
        public let observationReasons: [String]
        public let omittedObservationReasonCount: Int
        public let actions: [LocalTimelineCatalog.ActionFact]
        public let omittedActionCount: Int
        public let handles: [LocalTimelineCatalog.HandleFact]
        public let omittedHandleCount: Int
        public let commands: [LocalTimelineCatalog.CommandFact]
        public let omittedCommandCount: Int
        public let outstandingActionIDs: [String]
        public let omittedOutstandingActionCount: Int
        public let outstandingHandleIDs: [String]
        public let omittedOutstandingHandleCount: Int
        public let outstandingCommandIDs: [String]
        public let omittedOutstandingCommandCount: Int
        public let unknownEventRefs: [EventRef]
        public let omittedUnknownEventRefCount: Int
        public let unknownDomains: [TimelineDomain]
        public let corruptionReasons: [String]
        public let omittedCorruptionReasonCount: Int

        public var omittedAttachmentCount: Int {
            omittedSessionAttachmentCount + omittedClientAttachmentCount
        }
    }

    public static let defaultLimits = Limits()
    public let rows: [Row]
    public let omittedRowCount: Int
    public let omittedAttachmentCount: Int
    public let omittedObservationCount: Int
    public let ambiguousWorkCount: Int
    public let sourceComplete: Bool

    /// Build recovery rows from the current local catalog and explicit in-process observations.
    /// Session summaries are many-to-many joins: every exact attachment remains visible.
    public init(
        works: [LocalTimelineCatalog.WorkRow],
        sessions: [CanonicalSessionCatalogSummary] = [],
        observations: [CanonicalWorkRecoveryObservation] = [],
        sourceComplete: Bool = true,
        limits: Limits = Limits(),
        observingClient: ClientRef? = nil
    ) {
        let safeObservingClient = observingClient.flatMap { client in
            Self.boundedOptional(client.clientID, maxCharacters: limits.maxIdentityCharacters)
                .map(ClientRef.init)
        }
        let observingClientWasInvalid = observingClient != nil && safeObservingClient == nil
        let grouped = Dictionary(grouping: works) { row in
            Self.groupingKey(row, maxCharacters: limits.maxIdentityCharacters)
        }
        let observationsByWork = Dictionary(grouping: observations) { observation in
            Self.identityKey(work: observation.work, journal: observation.workJournal)
        }
        // LocalTimelineCatalog normally removes these facts from projection, but callers can
        // combine bounded catalogs. Never choose one journal's facts when the same Work identity
        // appears under more than one authority-qualified journal.
        let workRefCounts = Dictionary(grouping: works.compactMap(\LocalTimelineCatalog.WorkRow.work), by: { $0 })
        let duplicateWorkRefs = Set(workRefCounts.compactMap { $0.value.count > 1 ? $0.key : nil })
        var built: [Row] = []
        var ambiguousCount = 0
        for (identity, group) in grouped {
            let representative = group.sorted {
                ($0.locatorID ?? $0.id) < ($1.locatorID ?? $1.id)
            }.first
            let validIdentity = group.allSatisfy {
                Self.validWorkIdentity(
                    work: $0.work, journal: $0.journal,
                    maxCharacters: limits.maxIdentityCharacters)
            }
            let duplicateFacts = group.count > 1 || group.contains { row in
                row.work.map { duplicateWorkRefs.contains($0) } == true
            }
            let row = Self.makeRow(
                identity: identity, group: group, representative: representative,
                sessions: sessions, observations: observationsByWork[identity] ?? [],
                duplicateFacts: duplicateFacts,
                validIdentity: validIdentity, limits: limits,
                observingClient: safeObservingClient,
                observingClientWasInvalid: observingClientWasInvalid)
            if row.disposition == .ambiguous { ambiguousCount += 1 }
            built.append(row)
        }
        // A Work observation without a discoverable catalog row is not proof of Work facts. Keep
        // the identity visible as uncertain rather than manufacturing lifecycle or cursor data.
        let knownIDs = Set(grouped.keys)
        for (identity, values) in observationsByWork where !knownIDs.contains(identity) {
            let valid = values.allSatisfy {
                $0.identityIsValid(maxCharacters: limits.maxIdentityCharacters)
            }
            let reason = valid
                ? "explicit observation has no current canonical Work row"
                : "explicit observation has invalid Work identity"
            let deduplicated = Self.deduplicatedObservations(values)
            let uniqueValues = deduplicated.values.filter {
                $0.identityIsValid(maxCharacters: limits.maxIdentityCharacters)
            }
            let limited = Array(uniqueValues.prefix(limits.maxObservationsPerRow))
            let hasScopedObservation = safeObservingClient.map { client in
                uniqueValues.contains { $0.client == client }
            } ?? false
            let clientDisposition: CanonicalWorkRecoveryClientDisposition
            if observingClientWasInvalid {
                clientDisposition = .unverified
            } else if safeObservingClient == nil {
                clientDisposition = .notRequested
            } else {
                clientDisposition = hasScopedObservation ? .unverified : .unobserved
            }
            let safeObservation = valid ? uniqueValues.first : nil
            let invalidClientReason = observingClientWasInvalid
                ? ["invalid observing client"] : []
            let row = Row(
                id: identity, work: safeObservation?.work, journal: safeObservation?.workJournal,
                workHost: safeObservation.map { WorkHostRef($0.work.workHostID) },
                disposition: .uncertain, observingClient: safeObservingClient,
                clientDisposition: clientDisposition, clientCanControl: false,
                lifecycle: nil, execution: nil, modelID: nil, activeRun: nil,
                runHistory: [], omittedRunCount: 0, activeTurn: nil,
                cursor: nil, committedPrefixCursor: nil, omittedCursorCount: 0,
                recoveryCoverage: [],
                omittedRecoveryCoverageCount: 0, omittedRecoveryCaveatCount: 0,
                sessionAttachments: [],
                omittedSessionAttachmentCount: 0, clientAttachments: [],
                omittedClientAttachmentCount: 0, observations: limited,
                omittedObservationCount: max(0, values.count - limited.count),
                observationReasons: [reason] + invalidClientReason
                    + (deduplicated.hasConflict ? ["conflicting observations lack a canonical Work join"] : []),
                omittedObservationReasonCount: 0, actions: [],
                omittedActionCount: 0, handles: [], omittedHandleCount: 0, commands: [],
                omittedCommandCount: 0, outstandingActionIDs: [],
                omittedOutstandingActionCount: 0, outstandingHandleIDs: [],
                omittedOutstandingHandleCount: 0, outstandingCommandIDs: [],
                omittedOutstandingCommandCount: 0, unknownEventRefs: [],
                omittedUnknownEventRefCount: 0, unknownDomains: [],
                corruptionReasons: [reason], omittedCorruptionReasonCount: 0)
            built.append(row)
        }
        built.sort { $0.id < $1.id }
        omittedRowCount = max(0, built.count - limits.maxRows)
        rows = Array(built.prefix(limits.maxRows))
        let omittedRows = built.dropFirst(limits.maxRows)
        omittedAttachmentCount = rows.reduce(0) { $0 + $1.omittedAttachmentCount }
            + omittedRows.reduce(0) {
                $0 + $1.sessionAttachments.count + $1.clientAttachments.count
                    + $1.omittedAttachmentCount
            }
        omittedObservationCount = rows.reduce(0) { $0 + $1.omittedObservationCount }
            + omittedRows.reduce(0) { $0 + $1.observations.count + $1.omittedObservationCount }
        ambiguousWorkCount = ambiguousCount
        self.sourceComplete = sourceComplete
    }

    /// Convenience boundary retaining the catalog's global discovery completeness.
    public init(
        catalog: LocalTimelineCatalog.Snapshot,
        sessions: [CanonicalSessionCatalogSummary]? = nil,
        observations: [CanonicalWorkRecoveryObservation] = [],
        limits: Limits = Limits(), observingClient: ClientRef? = nil
    ) {
        self.init(
            works: catalog.works,
            sessions: sessions ?? catalog.sessionSummaries,
            observations: observations,
            sourceComplete: catalog.canonicalNotificationSourceComplete,
            limits: limits, observingClient: observingClient)
    }

    public var isComplete: Bool {
        sourceComplete && omittedRowCount == 0
    }

    /// Reconcile the Work/action/cursor portion of a canonical notification route.
    public func reconcile(
        notificationRoute route: CanonicalNotificationRoute
    ) -> CanonicalWorkRecoveryNotificationReconciliation? {
        guard route.isValid, let work = route.work, let journal = route.workJournal,
              let row = rows.first(where: { $0.work == work && $0.journal == journal })
        else { return nil }
        let action = route.action.flatMap { action in
            row.actions.first { $0.actionID == action.actionID }
        }
        let cursorMatches = route.workCursor == nil || route.workCursor == row.cursor
        let sessionMatches = row.sessionAttachments.contains {
            $0.session == route.session && $0.sessionJournal == route.sessionJournal
                && (route.sessionAttachment == nil || $0.attachment == route.sessionAttachment)
                && $0.isExact
                && route.sourceSessionCursor == $0.sessionCursor
                && (route.sourceSessionEvent == nil
                    || route.sourceSessionEvent == $0.attentionSourceEvent)
        }
        var reasons: [String] = []
        if !isComplete {
            reasons.append("Work recovery discovery is incomplete")
        }
        if row.disposition == .ambiguous { reasons.append("Work identity is ambiguous") }
        if row.disposition == .corrupt { reasons.append("Work facts are corrupt") }
        if route.action != nil && action == nil { reasons.append("action evidence is unavailable") }
        if !cursorMatches { reasons.append("Work cursor no longer matches the route") }
        if !sessionMatches { reasons.append("Session attachment evidence no longer matches the route") }
        if route.kind == .failedRecovery {
            if route.action == nil || action?.state != .indeterminateEffect {
                reasons.append("failed-recovery action is no longer indeterminate")
            }
            if route.outcome != .indeterminateEffect {
                reasons.append("failed-recovery outcome no longer matches the route")
            }
            if route.workCursor == nil { reasons.append("failed-recovery route has no Work cursor") }
        }
        let exact = isComplete && row.disposition != .ambiguous && row.disposition != .corrupt
            && (route.action == nil || action != nil) && cursorMatches && sessionMatches
            && (route.kind != .failedRecovery || (
                action?.state == .indeterminateEffect
                    && route.outcome == .indeterminateEffect && route.workCursor != nil))
        return CanonicalWorkRecoveryNotificationReconciliation(
            work: work, workJournal: journal, disposition: row.disposition,
            workCursor: row.cursor, action: action, matchesWorkCursor: cursorMatches,
            matchesSessionEvidence: sessionMatches, exact: exact,
            reason: reasons.isEmpty ? nil : reasons.joined(separator: "; "))
    }

    public static func identityKey(work: WorkRef?, journal: JournalRef?) -> String {
        guard let work, let journal else {
            return "work:v1/unavailable:" + digest("\(work?.workHostID ?? "")/\(work?.workID ?? "")/\(journal?.journalID ?? "")")
        }
        return "work:v1/" + digest(journal.stableKey + "|" + work.workHostID + "|" + work.workID)
    }

    private static func validWorkIdentity(
        work: WorkRef?, journal: JournalRef?, maxCharacters: Int
    ) -> Bool {
        guard let work, let journal,
              case .work(let owner) = journal.owner, owner == work,
              journal.authority.authorityID == work.workHostID,
              !work.workHostID.isEmpty, !work.workID.isEmpty,
              !journal.journalID.isEmpty, !journal.authority.authorityID.isEmpty
        else { return false }
        return [work.workHostID, work.workID, journal.journalID,
                journal.authority.authorityID].allSatisfy {
            $0.utf8.count <= maxCharacters
        }
    }

    private static func makeRow(
        identity: String, group: [LocalTimelineCatalog.WorkRow],
        representative: LocalTimelineCatalog.WorkRow?, sessions: [CanonicalSessionCatalogSummary],
        observations: [CanonicalWorkRecoveryObservation], duplicateFacts: Bool,
        validIdentity: Bool, limits: Limits, observingClient: ClientRef?,
        observingClientWasInvalid: Bool
    ) -> Row {
        let row = representative
        let work = row?.work
        let journal = row?.journal
        let exact = row?.isAvailable == true && validIdentity
        let safeWork = validIdentity ? work : nil
        let safeJournal = validIdentity ? journal : nil
        var sessionFactsByKey: [String: [CanonicalWorkRecoverySessionAttachment]] = [:]
        var omittedSessionIdentityCount = 0
        // The Work journal is the first source of an attachment fact. A Session summary is an
        // enrichment, not a prerequisite: a Work can remain recoverable while no Session row is
        // currently readable or while several GUIs attach to it.
        for attachment in row?.sessionAttachments ?? [] {
            guard !attachment.session.sessionID.isEmpty,
                  attachment.session.sessionID.utf8.count <= limits.maxIdentityCharacters,
                  !attachment.attachment.attachmentID.isEmpty,
                  attachment.attachment.attachmentID.utf8.count <= limits.maxIdentityCharacters
            else {
                omittedSessionIdentityCount += 1
                continue
            }
            let (capabilities, omittedCapabilities) = boundedStrings(
                attachment.capabilities.sorted(), limit: limits.maxCapabilitiesPerAttachment,
                maxCharacters: limits.maxIdentityCharacters)
            let fact = CanonicalWorkRecoverySessionAttachment(
                session: attachment.session, sessionJournal: nil,
                attachment: attachment.attachment, requestedCursor: nil,
                observedCursor: nil, workReadCursor: nil, sessionCursor: nil,
                omittedCursorCount: 0,
                attentionSourceEvent: nil, capabilities: capabilities,
                omittedCapabilityCount: omittedCapabilities, recoveryCoverage: [],
                omittedRecoveryCoverageCount: 0, omittedRecoveryCaveatCount: 0,
                isAttached: attachment.isAttached,
                isExact: false, unknownDomains: [],
                reasons: ["Session journal summary unavailable"], omittedReasonCount: 0)
            sessionFactsByKey[Self.sessionAttachmentKey(
                session: attachment.session, attachment: attachment.attachment), default: []].append(fact)
        }
        for summary in sessions {
            for attachment in summary.work where attachment.work == work {
                guard !attachment.attachment.attachmentID.isEmpty,
                      attachment.attachment.attachmentID.utf8.count <= limits.maxIdentityCharacters else {
                    omittedSessionIdentityCount += 1
                    continue
                }
                var reasons = attachment.corruptionReasons
                if !attachment.isAttached { reasons.append("Session attachment is detached") }
                if !attachment.attachmentProjectionKnown { reasons.append("Session attachment facts are unknown") }
                let (capabilities, omittedCapabilities) = boundedStrings(
                    attachment.attachmentCapabilities, limit: limits.maxCapabilitiesPerAttachment,
                    maxCharacters: limits.maxIdentityCharacters)
                // A Session catalog row is not enough to establish a recoverable relationship:
                // the exact Work journal must reciprocate the same Session/attachment identity.
                // A missing or detached Work-side fact is deliberately non-exact, even when the
                // Session has a perfectly aligned cursor and recorded recovery claim.
                let hasReciprocalWorkAttachment = row?.sessionAttachments.contains {
                    $0.session == summary.session
                        && $0.attachment == attachment.attachment
                        && $0.isAttached
                } == true
                if !hasReciprocalWorkAttachment {
                    reasons.append("Session attachment has no reciprocal Work session attachment")
                }
                guard !summary.session.sessionID.isEmpty,
                      summary.session.sessionID.utf8.count <= limits.maxIdentityCharacters,
                      !summary.journal.journalID.isEmpty,
                      summary.journal.journalID.utf8.count <= limits.maxIdentityCharacters,
                      !summary.journal.authority.authorityID.isEmpty,
                      summary.journal.authority.authorityID.utf8.count <= limits.maxIdentityCharacters
                else {
                    omittedSessionIdentityCount += 1
                    continue
                }
                let attachmentRecoveryClaims = (summary.recordedRecoveryCoverage ?? []).filter {
                    record in
                    record.session == summary.session
                        && record.sessionAttachment == attachment.attachment
                        && record.sourceEvent.journal == summary.journal
                }
                let recorded = hasReciprocalWorkAttachment
                    ? attachmentRecoveryClaims.filter { record in
                        record.work == attachment.work
                            && record.workJournal == journal
                            && record.workHost.workHostID == attachment.work.workHostID
                            && (row?.observedRunIDs.contains(record.run.runID) == true)
                    }
                    : []
                let unjoinedRecoveryCount = hasReciprocalWorkAttachment
                    ? attachmentRecoveryClaims.count - recorded.count
                    : attachmentRecoveryClaims.count
                if unjoinedRecoveryCount > 0 {
                    reasons.append(
                        "\(unjoinedRecoveryCount) recovery claim(s) target another Work generation or Run")
                }
                let boundedRecorded = boundedRecordedCoverage(
                    recorded, limit: limits.maxRecoveryCoveragePerRow,
                    maxCharacters: limits.maxIdentityCharacters)
                let (limitedAttachmentReasons, omittedAttachmentReasons) = boundedStrings(
                    Self.unique(reasons), limit: limits.maxReasonsPerRow,
                    maxCharacters: limits.maxIdentityCharacters)
                let requestedCursor = boundedCursor(
                    attachment.requestedCursor, maxCharacters: limits.maxIdentityCharacters)
                let observedCursor = boundedCursor(
                    attachment.observedCursor, maxCharacters: limits.maxIdentityCharacters)
                let workReadCursor = boundedCursor(
                    attachment.workReadCursor, maxCharacters: limits.maxIdentityCharacters)
                let sessionCursor = boundedCursor(
                    summary.sessionCursor, maxCharacters: limits.maxIdentityCharacters)
                let omittedCursorCount = [
                    (attachment.requestedCursor, requestedCursor),
                    (attachment.observedCursor, observedCursor),
                    (attachment.workReadCursor, workReadCursor),
                    (summary.sessionCursor, sessionCursor),
                ].reduce(0) { count, pair in
                    count + (pair.0 != nil && pair.1 == nil ? 1 : 0)
                }
                let fact = CanonicalWorkRecoverySessionAttachment(
                    session: summary.session, sessionJournal: summary.journal,
                    attachment: attachment.attachment,
                    requestedCursor: requestedCursor,
                    observedCursor: observedCursor,
                    workReadCursor: workReadCursor,
                    sessionCursor: sessionCursor,
                    omittedCursorCount: omittedCursorCount,
                    attentionSourceEvent: boundedEventRef(
                        summary.attentionSourceEvent,
                        maxCharacters: limits.maxIdentityCharacters),
                    capabilities: capabilities,
                    omittedCapabilityCount: omittedCapabilities,
                    recoveryCoverage: boundedRecorded.values,
                    omittedRecoveryCoverageCount: boundedRecorded.omittedRecords
                        + unjoinedRecoveryCount,
                    omittedRecoveryCaveatCount: boundedRecorded.omittedCaveats,
                    isAttached: attachment.isAttached,
                    isExact: omittedCursorCount == 0 && attachment.canProjectExecution
                        && hasReciprocalWorkAttachment
                        && summary.sessionIntegrityValid == true
                        && summary.sessionCursorAlignment == .exact,
                    unknownDomains: Array(Set(summary.unknownDomains + attachment.unknownDomains))
                        .sorted { $0.rawValue < $1.rawValue },
                    reasons: limitedAttachmentReasons,
                    omittedReasonCount: omittedAttachmentReasons)
                let key = Self.sessionAttachmentKey(
                    session: summary.session, attachment: attachment.attachment)
                // A Session summary enriches the Work-side row. Two distinct canonical summaries
                // for that same relationship remain visible to conflict detection below.
                if sessionFactsByKey[key]?.allSatisfy({ $0.sessionJournal == nil }) == true {
                    sessionFactsByKey[key] = [fact]
                } else {
                    sessionFactsByKey[key, default: []].append(fact)
                }
            }
        }
        let sessionGroups = sessionFactsByKey.values.map { values in
            let first = values[0]
            let duplicate = values.dropFirst().contains { $0 != first }
            return (first, duplicate)
        }
        let duplicateSessionJoin = sessionGroups.contains { $0.1 }
        let sessionFacts = sessionGroups.map { $0.0 }
            .sorted { $0.id < $1.id }
        let limitedSessions = Array(sessionFacts.prefix(limits.maxAttachmentsPerRow))
        let rawWorkClients = row?.clientAttachments ?? []
        let workClients: [CanonicalWorkRecoveryClientAttachment] = rawWorkClients.compactMap {
            (value: ClientAttachmentSnapshot) -> CanonicalWorkRecoveryClientAttachment? in
            guard !value.client.clientID.isEmpty,
                  value.client.clientID.utf8.count <= limits.maxIdentityCharacters,
                  !value.attachment.attachmentID.isEmpty,
                  value.attachment.attachmentID.utf8.count <= limits.maxIdentityCharacters else {
                return nil
            }
            let (capabilities, omittedCapabilities) = boundedStrings(
                Array(value.capabilities), limit: limits.maxCapabilitiesPerAttachment,
                maxCharacters: limits.maxIdentityCharacters)
            let cursor = boundedCursor(value.cursor, maxCharacters: limits.maxIdentityCharacters)
            return CanonicalWorkRecoveryClientAttachment(
                client: value.client, attachment: value.attachment, cursor: cursor,
                omittedCursorCount: value.cursor != nil && cursor == nil ? 1 : 0,
                capabilities: capabilities, omittedCapabilityCount: omittedCapabilities,
                isAttached: value.isAttached)
        }
        let limitedClients = Array(workClients.prefix(limits.maxAttachmentsPerRow))
        let deduplication = deduplicatedObservations(observations)
        let values = deduplication.values.sorted { $0.observerKey < $1.observerKey }
        let displayableObservations = values.filter {
            observationFits($0, maxCharacters: limits.maxIdentityCharacters)
        }
        let limitedObservations = Array(
            displayableObservations.prefix(limits.maxObservationsPerRow))
        func observationJoins(_ observation: CanonicalWorkRecoveryObservation) -> Bool {
            guard observation.identityIsValid(maxCharacters: limits.maxIdentityCharacters),
                  observation.work == work,
                  observation.workJournal == journal,
                  let activeRun = row?.activeRun, observation.run == activeRun,
                  sessionFacts.contains(where: {
                      $0.session == observation.session
                          && $0.attachment == observation.sessionAttachment
                          && $0.isAttached
                  }),
                  let clientFact = workClients.first(where: {
                      $0.client == observation.client
                          && $0.attachment == observation.clientAttachment
                  })
            else { return false }
            switch observation.presentation {
            case .attached:
                return clientFact.isAttached
            case .detached, .ended:
                return !clientFact.isAttached
            }
        }
        let invalidObservations = values.filter { !observationJoins($0) }
        let scopedValues = observingClient.map { client in
            values.filter { $0.client == client }
        } ?? []
        let scopedConflict = !Set(scopedValues.map(\.observerKey))
            .isDisjoint(with: deduplication.conflictingKeys)
        let scopedInvalid = scopedValues.contains { !observationJoins($0) }

        let disposition: CanonicalWorkRecoveryDisposition
        var reasons = row?.corruptionReasons ?? []
        if duplicateFacts || duplicateSessionJoin {
            disposition = .ambiguous
            if duplicateFacts { reasons.append("duplicate Work fact") }
            if duplicateSessionJoin { reasons.append("duplicate Session attachment join") }
        } else if !validIdentity || !exact {
            disposition = row?.isAvailable == false ? .corrupt : .uncertain
            if !validIdentity { reasons.append("Work journal identity is invalid") }
        } else if row?.unknownDomains.contains(where: {
            [.work, .runtime, .externalEffects].contains($0)
        }) == true {
            disposition = .uncertain
            reasons.append("Work/runtime/external-effects facts are unknown")
        } else {
            disposition = Self.durableDisposition(row)
        }
        if disposition == .ambiguous { reasons.append("recovery facts cannot be selected safely") }

        let clientDisposition: CanonicalWorkRecoveryClientDisposition
        let clientCanControl: Bool
        if observingClient == nil {
            clientDisposition = observingClientWasInvalid ? .unverified : .notRequested
            clientCanControl = false
        } else if scopedValues.isEmpty {
            clientDisposition = .unobserved
            clientCanControl = false
        } else if disposition == .corrupt || disposition == .ambiguous
                    || scopedInvalid || scopedConflict {
            clientDisposition = scopedConflict ? .ambiguous : .unverified
            clientCanControl = false
        } else if scopedValues.contains(where: { $0.presentation == .attached }) {
            clientDisposition = .observedAttached
            clientCanControl = scopedValues.contains {
                observation in
                observationJoins(observation) && observation.presentation == .attached
                    && observation.canControl
                    && workClients.contains(where: {
                        $0.client == observation.client
                            && $0.attachment == observation.clientAttachment
                            && $0.capabilities.contains("control")
                    })
            }
        } else if scopedValues.contains(where: {
            $0.presentation == .detached && $0.canReattach
        }) {
            clientDisposition = .observedReattachable
            clientCanControl = scopedValues.contains {
                observation in
                observationJoins(observation) && observation.presentation == .detached
                    && observation.canReattach && observation.canControl
                    && workClients.contains(where: {
                        $0.client == observation.client
                            && $0.attachment == observation.clientAttachment
                            && $0.capabilities.contains("control")
                    })
            }
        } else if scopedValues.contains(where: { $0.presentation == .detached }) {
            clientDisposition = .observedDetached
            clientCanControl = false
        } else {
            clientDisposition = .observedEnded
            clientCanControl = false
        }

        let (limitedReasons, omittedReasons) = boundedStrings(
            Self.unique(reasons), limit: limits.maxReasonsPerRow,
            maxCharacters: limits.maxIdentityCharacters)
        var observationReasons: [String] = []
        if !invalidObservations.isEmpty {
            observationReasons.append(
                "\(invalidObservations.count) observation(s) do not match the exact Work, Run, Session, or client attachment")
        }
        if !deduplication.conflictingKeys.isEmpty {
            observationReasons.append(
                "\(deduplication.conflictingKeys.count) observer identity claim(s) conflict")
        }
        if observingClientWasInvalid {
            observationReasons.append("invalid observing client")
        }
        let (limitedObservationReasons, omittedObservationReasons) = boundedStrings(
            observationReasons, limit: limits.maxReasonsPerRow,
            maxCharacters: limits.maxIdentityCharacters)
        let boundedCoverage = boundedRecordedCoverage(
            row?.recoveryCoverage ?? [], limit: limits.maxRecoveryCoveragePerRow,
            maxCharacters: limits.maxIdentityCharacters)
        let (actions, omittedActions) = boundedFacts(
            row?.actions ?? [], limit: limits.maxActionFactsPerRow,
            maxCharacters: limits.maxIdentityCharacters) { $0.actionID }
        let handleInput = row?.handles ?? []
        let validHandles = handleInput.filter {
            !$0.handleID.isEmpty && $0.handleID.utf8.count <= limits.maxIdentityCharacters
                && !$0.state.isEmpty && $0.state.utf8.count <= limits.maxIdentityCharacters
        }.sorted { $0.handleID < $1.handleID }
        let handles = Array(validHandles.prefix(limits.maxHandleFactsPerRow))
        let omittedHandles = handleInput.count - handles.count
        let (commands, omittedCommands) = boundedFacts(
            row?.commands ?? [], limit: limits.maxCommandFactsPerRow,
            maxCharacters: limits.maxIdentityCharacters) { $0.commandID }
        let (runHistory, omittedRuns) = boundedFacts(
            row?.runHistory ?? [], limit: limits.maxRunFactsPerRow,
            maxCharacters: limits.maxIdentityCharacters) { $0.runID }
        let (outstandingActions, omittedOutstandingActions) = boundedStrings(
            row?.actions.filter { !$0.state.isTerminal }.map(\.actionID) ?? [],
            limit: limits.maxActionFactsPerRow, maxCharacters: limits.maxIdentityCharacters)
        let (outstandingHandles, omittedOutstandingHandles) = boundedStrings(
            row?.handles.filter { !Self.isTerminalHandleState($0.state) }.map(\.handleID) ?? [],
            limit: limits.maxHandleFactsPerRow, maxCharacters: limits.maxIdentityCharacters)
        let (outstandingCommands, omittedOutstandingCommands) = boundedStrings(
            row?.commands.filter { $0.state == .accepted }.map(\.commandID) ?? [],
            limit: limits.maxCommandFactsPerRow, maxCharacters: limits.maxIdentityCharacters)
        let (unknownRefs, omittedUnknownRefs) = boundedEventRefs(
            row?.unknownEventRefs ?? [], limit: limits.maxUnknownRefsPerRow,
            maxCharacters: limits.maxIdentityCharacters)
        let workCursor = boundedCursor(row?.cursor, maxCharacters: limits.maxIdentityCharacters)
        let committedPrefixCursor = boundedCursor(
            row?.committedPrefixCursor, maxCharacters: limits.maxIdentityCharacters)
        let omittedCursorCount = [
            (row?.cursor, workCursor), (row?.committedPrefixCursor, committedPrefixCursor),
        ].reduce(0) { count, pair in
            count + (pair.0 != nil && pair.1 == nil ? 1 : 0)
        }
        let operationalFactsProjectable = disposition != .ambiguous && disposition != .corrupt
        let sessionOmissions = max(0, sessionFacts.count - limitedSessions.count)
            + omittedSessionIdentityCount + (row?.omittedSessionAttachmentCount ?? 0)
        let clientOmissions = max(0, workClients.count - limitedClients.count)
            + max(0, rawWorkClients.count - workClients.count)
            + (row?.omittedClientAttachmentCount ?? 0)
        return Row(
            id: identity, work: safeWork, journal: safeJournal,
            workHost: safeWork.map { WorkHostRef($0.workHostID) }, disposition: disposition,
            observingClient: observingClient, clientDisposition: clientDisposition,
            clientCanControl: clientCanControl,
            lifecycle: operationalFactsProjectable ? row?.lifecycle : nil,
            execution: operationalFactsProjectable ? row?.execution : nil,
            modelID: operationalFactsProjectable
                ? boundedOptional(row?.modelID, maxCharacters: limits.maxIdentityCharacters) : nil,
            activeRun: operationalFactsProjectable
                ? boundedRun(row?.activeRun, maxCharacters: limits.maxIdentityCharacters) : nil,
            runHistory: operationalFactsProjectable ? runHistory : [],
            omittedRunCount: omittedRuns + (row?.omittedRunCount ?? 0)
                + (operationalFactsProjectable ? 0 : runHistory.count),
            activeTurn: operationalFactsProjectable
                ? boundedTurn(row?.activeTurn, maxCharacters: limits.maxIdentityCharacters) : nil,
            cursor: operationalFactsProjectable ? workCursor : nil,
            committedPrefixCursor: committedPrefixCursor,
            omittedCursorCount: omittedCursorCount,
            recoveryCoverage: operationalFactsProjectable ? boundedCoverage.values : [],
            omittedRecoveryCoverageCount: boundedCoverage.omittedRecords
                + (row?.omittedRecoveryCoverageCount ?? 0)
                + (operationalFactsProjectable ? 0 : boundedCoverage.values.count),
            omittedRecoveryCaveatCount: boundedCoverage.omittedCaveats,
            sessionAttachments: operationalFactsProjectable ? limitedSessions : [],
            omittedSessionAttachmentCount: sessionOmissions
                + (operationalFactsProjectable ? 0 : limitedSessions.count),
            clientAttachments: operationalFactsProjectable ? limitedClients : [],
            omittedClientAttachmentCount: clientOmissions
                + (operationalFactsProjectable ? 0 : limitedClients.count),
            observations: limitedObservations,
            // Count every input fact that was not retained, including identical duplicates and
            // conflicting claims collapsed by observer identity. Conflict reasons explain why;
            // the omission count makes the bounded projection honest about lost cardinality.
            omittedObservationCount: max(0, observations.count - limitedObservations.count),
            observationReasons: limitedObservationReasons,
            omittedObservationReasonCount: omittedObservationReasons,
            actions: operationalFactsProjectable ? actions : [],
            omittedActionCount: omittedActions + (operationalFactsProjectable ? 0 : actions.count),
            handles: operationalFactsProjectable ? handles : [],
            omittedHandleCount: omittedHandles + (operationalFactsProjectable ? 0 : handles.count),
            commands: operationalFactsProjectable ? commands : [],
            omittedCommandCount: omittedCommands + (operationalFactsProjectable ? 0 : commands.count),
            outstandingActionIDs: operationalFactsProjectable ? outstandingActions : [],
            omittedOutstandingActionCount: omittedOutstandingActions
                + (operationalFactsProjectable ? 0 : outstandingActions.count),
            outstandingHandleIDs: operationalFactsProjectable ? outstandingHandles : [],
            omittedOutstandingHandleCount: omittedOutstandingHandles
                + (operationalFactsProjectable ? 0 : outstandingHandles.count),
            outstandingCommandIDs: operationalFactsProjectable ? outstandingCommands : [],
            omittedOutstandingCommandCount: omittedOutstandingCommands
                + (operationalFactsProjectable ? 0 : outstandingCommands.count),
            unknownEventRefs: unknownRefs, omittedUnknownEventRefCount: omittedUnknownRefs,
            unknownDomains: Array((row?.unknownDomains ?? []).prefix(limits.maxUnknownRefsPerRow)),
            corruptionReasons: limitedReasons, omittedCorruptionReasonCount: omittedReasons)
    }

    private static func durableDisposition(
        _ row: LocalTimelineCatalog.WorkRow?
    ) -> CanonicalWorkRecoveryDisposition {
        guard let row, row.isAvailable else { return .corrupt }
        guard let lifecycle = row.lifecycle, let execution = row.execution else {
            return .uncertain
        }
        let hasOutstanding = row.activeRun != nil || row.activeTurn != nil
            || row.actions.contains { $0.state.isTerminal == false }
            || row.handles.contains { !isTerminalHandleState($0.state) }
            || row.commands.contains { $0.state == .accepted }
        if [.completed, .destroyed].contains(lifecycle), execution == .idle, !hasOutstanding {
            return .completedEvidence
        }
        if lifecycle == .active {
            return .recordedActive
        }
        return .uncertain
    }

    fileprivate static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func groupingKey(
        _ row: LocalTimelineCatalog.WorkRow, maxCharacters: Int
    ) -> String {
        guard validWorkIdentity(
            work: row.work, journal: row.journal, maxCharacters: maxCharacters)
        else {
            return "work:v1/locator:"
                + digest(String((row.locatorID ?? row.id).prefix(maxCharacters)))
        }
        return identityKey(work: row.work, journal: row.journal)
    }

    private struct ObservationDeduplication {
        let values: [CanonicalWorkRecoveryObservation]
        let conflictingKeys: Set<String>

        var hasConflict: Bool { !conflictingKeys.isEmpty }
    }

    private static func deduplicatedObservations(
        _ observations: [CanonicalWorkRecoveryObservation]
    ) -> ObservationDeduplication {
        let groups = Dictionary(grouping: observations, by: \.observerKey)
        var values: [CanonicalWorkRecoveryObservation] = []
        var conflictingKeys: Set<String> = []
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            values.append(first)
            if group.dropFirst().contains(where: { $0 != first }) {
                conflictingKeys.insert(key)
            }
        }
        return ObservationDeduplication(values: values, conflictingKeys: conflictingKeys)
    }

    private static func observationFits(
        _ value: CanonicalWorkRecoveryObservation, maxCharacters: Int
    ) -> Bool {
        [
            value.work.workHostID, value.work.workID, value.workJournal.journalID,
            value.workJournal.authority.authorityID, value.session.sessionID,
            value.sessionAttachment.attachmentID, value.run.runID, value.client.clientID,
            value.clientAttachment.attachmentID
        ].allSatisfy { !$0.isEmpty && $0.utf8.count <= maxCharacters }
    }

    private static func sessionAttachmentKey(
        session: SessionRef, attachment: SessionAttachmentRef
    ) -> String {
        digest("session:\(session.sessionID)|attachment:\(attachment.attachmentID)")
    }

    private static func isTerminalHandleState(_ state: String) -> Bool {
        ["succeeded", "failed", "canceled", "completed"].contains(state.lowercased())
    }

    private static func boundedOptional(_ value: String?, maxCharacters: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maxCharacters else { return nil }
        return value
    }

    private static func boundedStrings(
        _ input: [String], limit: Int, maxCharacters: Int
    ) -> ([String], Int) {
        let values = input
            .filter { !$0.isEmpty && $0.utf8.count <= maxCharacters }
            .sorted()
        var result: [String] = []
        var seen = Set<String>()
        var omitted = 0
        for value in values {
            guard seen.insert(value).inserted else { continue }
            if result.count < limit { result.append(value) } else { omitted += 1 }
        }
        omitted += input.filter { $0.isEmpty || $0.utf8.count > maxCharacters }.count
        return (result, omitted)
    }

    private static func boundedEventRefs(
        _ input: [EventRef], limit: Int, maxCharacters: Int
    ) -> ([EventRef], Int) {
        let valid = input.filter {
            !$0.eventID.isEmpty && $0.eventID.utf8.count <= maxCharacters
                && $0.journal.journalID.utf8.count <= maxCharacters
                && $0.journal.authority.authorityID.utf8.count <= maxCharacters
        }.sorted { a, b in
            a.journal.stableKey == b.journal.stableKey
                ? a.eventID < b.eventID : a.journal.stableKey < b.journal.stableKey
        }
        let retained = Array(valid.prefix(limit))
        return (retained, max(0, valid.count - retained.count)
            + input.filter {
                $0.eventID.isEmpty || $0.eventID.utf8.count > maxCharacters
                    || $0.journal.journalID.utf8.count > maxCharacters
                    || $0.journal.authority.authorityID.utf8.count > maxCharacters
            }.count)
    }

    private static func boundedEventRef(_ value: EventRef?, maxCharacters: Int) -> EventRef? {
        guard let value, !value.eventID.isEmpty,
              value.eventID.utf8.count <= maxCharacters,
              value.journal.journalID.utf8.count <= maxCharacters,
              value.journal.authority.authorityID.utf8.count <= maxCharacters else { return nil }
        return value
    }

    private static func boundedCursor(
        _ value: JournalCursor?, maxCharacters: Int
    ) -> JournalCursor? {
        guard let value, value.sequence > 0,
              value.journal.journalID.utf8.count <= maxCharacters,
              value.journal.authority.authorityID.utf8.count <= maxCharacters,
              value.eventID.map({ !$0.isEmpty && $0.utf8.count <= maxCharacters }) ?? false
        else { return nil }
        return value
    }

    private static func boundedRun(_ value: RunRef?, maxCharacters: Int) -> RunRef? {
        guard let value, !value.runID.isEmpty, value.runID.utf8.count <= maxCharacters else { return nil }
        return value
    }

    private static func boundedTurn(_ value: TurnRef?, maxCharacters: Int) -> TurnRef? {
        guard let value, !value.turnID.isEmpty, value.turnID.utf8.count <= maxCharacters else { return nil }
        return value
    }

    private static func boundedRecordedCoverage(
        _ input: [RecordedRecoveryCoverage], limit: Int, maxCharacters: Int
    ) -> (values: [RecordedRecoveryCoverage], omittedRecords: Int, omittedCaveats: Int) {
        let valid = input.filter { value in
            let identities = [
                value.sourceEvent.eventID, value.sourceEvent.journal.journalID,
                value.sourceEvent.journal.authority.authorityID,
                value.session.sessionID, value.work.workHostID, value.work.workID,
                value.workJournal.journalID, value.workJournal.authority.authorityID,
                value.workHost.workHostID, value.sessionAttachment.attachmentID,
                value.run.runID
            ]
            let evidenceFits = value.coverage.evidence.map {
                boundedEventRef($0, maxCharacters: maxCharacters) != nil
            } ?? true
            let cursorFits = value.coverage.evidenceCursor.map {
                boundedCursor($0, maxCharacters: maxCharacters) != nil
            } ?? true
            let workJournalFits: Bool
            if case .work(let owner) = value.workJournal.owner {
                workJournalFits = owner == value.work
                    && value.workJournal.authority.authorityID == value.work.workHostID
            } else {
                workJournalFits = false
            }
            let sourceJournalFits: Bool
            if case .session(let owner) = value.sourceEvent.journal.owner {
                sourceJournalFits = owner == value.session
            } else {
                sourceJournalFits = value.sourceEvent.journal == value.workJournal
            }
            return evidenceFits && cursorFits && workJournalFits && sourceJournalFits
                && identities.allSatisfy { !$0.isEmpty && $0.utf8.count <= maxCharacters }
        }
        var omittedCaveats = 0
        let normalized = valid.map { value -> RecordedRecoveryCoverage in
            var coverage = value.coverage
            let bounded = boundedStrings(
                coverage.caveats, limit: 16, maxCharacters: maxCharacters)
            coverage.caveats = bounded.0
            omittedCaveats += bounded.1
            return RecordedRecoveryCoverage(
                coverage: coverage, sourceEvent: value.sourceEvent, session: value.session,
                work: value.work, workJournal: value.workJournal, workHost: value.workHost,
                sessionAttachment: value.sessionAttachment, run: value.run)
        }
        return (
            Array(normalized.prefix(limit)),
            input.count - normalized.count + max(0, normalized.count - limit),
            omittedCaveats)
    }

    private static func boundedFacts<T>(
        _ input: [T], limit: Int, maxCharacters: Int, identity: (T) -> String
    ) -> ([T], Int) {
        let valid = input.filter {
            !identity($0).isEmpty && identity($0).utf8.count <= maxCharacters
        }
            .sorted { identity($0) < identity($1) }
        return (Array(valid.prefix(limit)), max(0, valid.count - limit)
            + input.filter {
                identity($0).isEmpty || identity($0).utf8.count > maxCharacters
            }.count)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
