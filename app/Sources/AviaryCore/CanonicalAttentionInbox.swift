import Foundation

/// An injective, source-qualified identity for canonical Timeline objects.
///
/// Each component is length-prefixed, so delimiters and user-controlled IDs cannot alias one
/// another. Journal identity delegates to the same structural contract as `JournalRef.stableKey`.
public enum CanonicalAttentionIdentity {
    public static func journal(_ journal: JournalRef) -> String {
        journal.stableKey
    }

    public static func work(_ work: WorkRef) -> String {
        "work|" + field("workHost", work.workHostID) + field("work", work.workID)
    }

    public static func attachment(_ attachment: SessionAttachmentRef) -> String {
        "attachment|" + field("attachment", attachment.attachmentID)
    }

    public static func sessionRow(
        journal: JournalRef, attachment: SessionAttachmentRef? = nil
    ) -> String {
        var identity = "session-row|" + field("journal", self.journal(journal))
        if let attachment {
            identity += field("attachment", self.attachment(attachment))
        }
        return identity
    }

    private static func field(_ name: String, _ value: String) -> String {
        "\(name):\(value.utf8.count):\(value)"
    }
}

public enum CanonicalAttentionRequirement: String, Codable, Hashable, Sendable {
    case unknown
    case none
    case required
}

private enum CanonicalAttentionBounds {
    static let unknownEventRefs = 128
    static let corruptionReasons = 32
    static let reasonCharacters = 512

    static func refs(_ values: [EventRef]) -> (values: [EventRef], omitted: Int) {
        let unique = Array(Set(values)).sorted {
            if $0.journal.stableKey != $1.journal.stableKey {
                return $0.journal.stableKey < $1.journal.stableKey
            }
            return $0.eventID < $1.eventID
        }
        let kept = Array(unique.prefix(unknownEventRefs))
        return (kept, unique.count - kept.count)
    }

    static func reasons(_ values: [String]) -> (
        values: [String], omitted: Int, truncated: Int
    ) {
        let unique = Array(Set(values)).sorted()
        let truncated = unique.filter {
            $0.count > reasonCharacters
        }.count
        let normalized = unique.map { String($0.prefix(reasonCharacters)) }
        let kept = Array(normalized.prefix(corruptionReasons))
        return (kept, normalized.count - kept.count, truncated)
    }
}

/// Evidence for one attached Work. Work evidence is retained even when it cannot prove
/// execution or attention, so an unavailable projection is visible rather than silently omitted.
public struct CanonicalAttentionAttachmentEvidence: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let attachment: SessionAttachmentRef
    public let work: WorkRef
    public let workHost: WorkHostRef
    public let workJournal: JournalRef?
    public let qualifiedWorkID: String
    public let requestedCursor: JournalCursor?
    public let observedCursor: JournalCursor?
    public let sourceCursor: JournalCursor?
    public let cursorAlignment: CanonicalWorkCatalogSummary.CursorAlignment
    public let readAlignment: CanonicalWorkCatalogSummary.WorkReadAlignment
    public let integrityValid: Bool?
    public let structuralIntegrityValid: Bool
    public let semanticProjectionValid: Bool
    public let tailBytes: Int?
    public let unknownDomains: [TimelineDomain]
    public let unknownEventRefs: [EventRef]
    public let omittedUnknownEventRefCount: Int
    public let corruptionReasons: [String]
    public let omittedCorruptionReasonCount: Int
    public let truncatedCorruptionReasonCount: Int

    fileprivate init(
        sessionJournal: JournalRef, work: CanonicalWorkCatalogSummary
    ) {
        self.attachment = work.attachment
        self.work = work.work
        self.workHost = work.workHost
        self.workJournal = work.journal
        self.qualifiedWorkID = CanonicalAttentionIdentity.work(work.work)
        self.id = CanonicalAttentionIdentity.sessionRow(
            journal: sessionJournal, attachment: work.attachment)
        self.requestedCursor = work.requestedCursor
        self.observedCursor = work.observedCursor
        self.sourceCursor = work.workReadCursor
        self.cursorAlignment = work.cursorAlignment
        self.readAlignment = work.workReadAlignment
        self.integrityValid = work.journalIntegrityValid
        self.structuralIntegrityValid = work.structuralIntegrityValid
        self.semanticProjectionValid = work.semanticProjectionValid
        self.tailBytes = work.tailBytes
        self.unknownDomains = work.unknownDomains
        let refs = CanonicalAttentionBounds.refs(work.unknownEventRefs)
        self.unknownEventRefs = refs.values
        self.omittedUnknownEventRefCount = refs.omitted
        let reasons = CanonicalAttentionBounds.reasons(work.corruptionReasons)
        self.corruptionReasons = reasons.values
        self.omittedCorruptionReasonCount = reasons.omitted
        self.truncatedCorruptionReasonCount = reasons.truncated
    }
}

/// One row per canonical Session. Effective attention is Session-level; attached Works are
/// evidence within the row, never duplicate attention rows.
public struct CanonicalAttentionInboxRow: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let session: SessionRef
    /// The Session journal carries the authority that qualifies an otherwise-bare Session ID.
    public let sessionJournal: JournalRef
    public let qualifiedSessionID: String
    /// Nil means the Session domain was not known well enough to report authored attention.
    public let authoredAttention: SessionAttention?
    /// Nil means attention was not proven from an exact, known Session/Work projection.
    public let effectiveAttention: SessionAttention?
    /// Client-neutral tri-state requirement. No GUI/control capability is implied.
    public let attentionRequirement: CanonicalAttentionRequirement
    public let attachments: [CanonicalAttentionAttachmentEvidence]
    public let omittedAttachmentCount: Int

    public let sessionSourceCursor: JournalCursor?
    public let sessionSnapshotCursor: JournalCursor?
    public let sessionCursorAlignment: CanonicalWorkCatalogSummary.CursorAlignment
    public let sessionIntegrityValid: Bool?
    public let sessionStructuralIntegrityValid: Bool
    public let sessionSemanticProjectionValid: Bool
    public let sessionTailBytes: Int?
    public let sessionUnknownDomains: [TimelineDomain]
    public let sessionUnknownEventRefs: [EventRef]
    public let omittedSessionUnknownEventRefCount: Int
    public let corruptionReasons: [String]
    public let omittedCorruptionReasonCount: Int
    public let truncatedCorruptionReasonCount: Int
    /// Greater than one means duplicate canonical summaries were coalesced into a conflict row;
    /// no Session/Work facts are selected from any of the conflicting summaries.
    public let duplicateSummaryCount: Int

    init(
        summary: CanonicalSessionCatalogSummary,
        maxAttachments: Int
    ) {
        self.duplicateSummaryCount = 1
        self.session = summary.session
        self.sessionJournal = summary.journal
        self.qualifiedSessionID = CanonicalAttentionIdentity.journal(summary.journal)
        self.id = CanonicalAttentionIdentity.sessionRow(journal: summary.journal)

        let sessionUnknown = Set(summary.unknownDomains)
        let attentionKnown = !sessionUnknown.contains(.session)
        self.authoredAttention = attentionKnown ? summary.authoredAttention : nil
        self.sessionSourceCursor = summary.sessionReadCursor
        self.sessionSnapshotCursor = summary.sessionSnapshotCursor
        self.sessionCursorAlignment = summary.sessionCursorAlignment
        self.sessionIntegrityValid = summary.sessionIntegrityValid
        self.sessionStructuralIntegrityValid = summary.sessionStructuralIntegrityValid
        self.sessionSemanticProjectionValid = summary.sessionSemanticProjectionValid
        self.sessionTailBytes = summary.sessionTailBytes
        self.sessionUnknownDomains = summary.unknownDomains
        let sessionRefs = CanonicalAttentionBounds.refs(summary.unknownEventRefs)
        self.sessionUnknownEventRefs = sessionRefs.values
        self.omittedSessionUnknownEventRefCount = sessionRefs.omitted

        let attached = summary.work.filter(\.isAttached).sorted { lhs, rhs in
            let lhsKey = CanonicalAttentionIdentity.sessionRow(
                journal: summary.journal, attachment: lhs.attachment)
                + CanonicalAttentionIdentity.work(lhs.work)
            let rhsKey = CanonicalAttentionIdentity.sessionRow(
                journal: summary.journal, attachment: rhs.attachment)
                + CanonicalAttentionIdentity.work(rhs.work)
            return lhsKey < rhsKey
        }
        let boundedCount = min(max(0, maxAttachments), CanonicalAttentionInboxProjection.maximumAttachmentCount)
        let kept = Array(attached.prefix(boundedCount))
        self.omittedAttachmentCount = attached.count - kept.count
        self.attachments = kept.map {
            CanonicalAttentionAttachmentEvidence(sessionJournal: summary.journal, work: $0)
        }

        let blockedDomains: Set<TimelineDomain> = [.session, .runtime, .externalEffects]
        let allAttachedEvidenceKnown = attached.allSatisfy { row in
            row.canProjectExecution
                && row.cursorAlignment == .exact
                && row.workReadAlignment == .exact
                && row.journalIntegrityValid == true
                && row.structuralIntegrityValid
                && row.semanticProjectionValid
                && Set(row.unknownDomains).isDisjoint(with: blockedDomains)
        }
        let sessionProjectionKnown = summary.sessionCursorAlignment == .exact
            && summary.sessionIntegrityValid == true
            && summary.sessionStructuralIntegrityValid
            && summary.sessionSemanticProjectionValid
            && summary.assemblyReady
            && sessionUnknown.isDisjoint(with: blockedDomains)
        let effective = sessionProjectionKnown && allAttachedEvidenceKnown
            ? summary.effectiveAttention : nil
        self.effectiveAttention = effective
        if let effective {
            self.attentionRequirement = effective == .none ? .none : .required
        } else {
            self.attentionRequirement = .unknown
        }

        var reasons = summary.corruptionReasons
        if !sessionProjectionKnown {
            reasons.append("Session attention projection is not exact and fully known")
        }
        if !allAttachedEvidenceKnown {
            reasons.append("Attached Work attention evidence is not exact and fully known")
        }
        let boundedReasons = CanonicalAttentionBounds.reasons(reasons)
        self.corruptionReasons = boundedReasons.values
        self.omittedCorruptionReasonCount = boundedReasons.omitted
        self.truncatedCorruptionReasonCount = boundedReasons.truncated
    }

    fileprivate init(conflictingSummaries: [CanonicalSessionCatalogSummary]) {
        let first = conflictingSummaries[0]
        self.id = CanonicalAttentionIdentity.sessionRow(journal: first.journal)
        self.session = first.session
        self.sessionJournal = first.journal
        self.qualifiedSessionID = CanonicalAttentionIdentity.journal(first.journal)
        self.authoredAttention = nil
        self.effectiveAttention = nil
        self.attentionRequirement = .unknown
        self.attachments = []
        self.omittedAttachmentCount = 0
        self.sessionSourceCursor = nil
        self.sessionSnapshotCursor = nil
        self.sessionCursorAlignment = .divergent
        self.sessionIntegrityValid = nil
        self.sessionStructuralIntegrityValid = false
        self.sessionSemanticProjectionValid = false
        self.sessionTailBytes = nil
        self.sessionUnknownDomains = []
        self.sessionUnknownEventRefs = []
        let discardedRefs = Set(conflictingSummaries.flatMap { $0.unknownEventRefs })
        self.omittedSessionUnknownEventRefCount = discardedRefs.count
        let duplicateReason = "duplicate canonical Session summaries for \(first.journal.stableKey)"
        let reasons = CanonicalAttentionBounds.reasons(
            conflictingSummaries.flatMap { $0.corruptionReasons } + [duplicateReason])
        self.corruptionReasons = reasons.values
        self.omittedCorruptionReasonCount = reasons.omitted
        self.truncatedCorruptionReasonCount = reasons.truncated
        self.duplicateSummaryCount = conflictingSummaries.count
    }
}

/// A deterministic, globally bounded canonical attention projection. The row cap applies across
/// all Sessions, while each row independently bounds attached-Work evidence.
public struct CanonicalAttentionInboxProjection: Codable, Hashable, Sendable {
    public static let maximumRowCount = 128
    public static let maximumAttachmentCount = 128
    public static let maximumUnknownEventRefs = CanonicalAttentionBounds.unknownEventRefs
    public static let maximumCorruptionReasons = CanonicalAttentionBounds.corruptionReasons
    public static let maximumReasonCharacters = CanonicalAttentionBounds.reasonCharacters
    public let rows: [CanonicalAttentionInboxRow]
    public let omittedRowCount: Int

    public var isTruncated: Bool { omittedRowCount > 0 }

    public init(
        summary: CanonicalSessionCatalogSummary,
        maxRows: Int = CanonicalAttentionInboxProjection.maximumRowCount,
        maxAttachments: Int = CanonicalAttentionInboxProjection.maximumAttachmentCount
    ) {
        self.init(summaries: [summary], maxRows: maxRows, maxAttachments: maxAttachments)
    }

    public init(
        summaries: [CanonicalSessionCatalogSummary],
        maxRows: Int = CanonicalAttentionInboxProjection.maximumRowCount,
        maxAttachments: Int = CanonicalAttentionInboxProjection.maximumAttachmentCount
    ) {
        let grouped = Dictionary(grouping: summaries, by: \.journal)
        // Build the truthful row before applying the global bound. Otherwise a lexically late
        // failure or request for input can disappear behind 128 earlier idle Sessions.
        let projected = grouped.values.map { summaries in
            if summaries.count == 1 {
                return CanonicalAttentionInboxRow(
                    summary: summaries[0], maxAttachments: maxAttachments)
            }
            return CanonicalAttentionInboxRow(conflictingSummaries: summaries)
        }
        let sorted = projected.sorted {
            let lhsPriority = Self.priority($0)
            let rhsPriority = Self.priority($1)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return $0.id < $1.id
        }
        let boundedCount = min(max(0, maxRows), Self.maximumRowCount)
        let kept = Array(sorted.prefix(boundedCount))
        self.omittedRowCount = sorted.count - kept.count
        self.rows = kept
    }

    private static func priority(_ row: CanonicalAttentionInboxRow) -> Int {
        switch row.effectiveAttention {
        case .some(.error): return 0
        case .some(.confirmation): return 1
        case .some(.input): return 2
        case .some(.review): return 3
        case .some(.none): return 4
        case nil: return 5
        }
    }
}

/// The state a Session occupies in the canonical workspace rail.
///
/// The ordering is presentation priority, not recency. In particular, no timestamp from one
/// journal is compared with a timestamp from another journal. `unknown` is deliberately a real
/// state: an unavailable or conflicting row remains selectable for diagnosis without becoming a
/// falsely idle Session.
public enum CanonicalSessionWorkspaceRailState: String, Codable, Hashable, Sendable {
    case needsInput = "needs_input"
    case needsConfirmation = "needs_confirmation"
    case failed
    case working
    case readyForReview = "ready_for_review"
    case idle
    case completed
    case archived
    case unknown

    /// Lower values are shown first. Attention is more actionable than ordinary work; unknown
    /// state is last because it cannot safely be treated as either active or settled.
    public var priority: Int {
        switch self {
        case .failed: return 0
        case .needsConfirmation: return 1
        case .needsInput: return 2
        case .readyForReview: return 3
        case .working: return 4
        case .idle: return 5
        case .completed: return 6
        case .archived: return 7
        case .unknown: return 8
        }
    }
}

/// Why a rail entry is or is not backed by exactly one catalog summary.
public enum CanonicalSessionWorkspaceRailJoin: String, Codable, Hashable, Sendable {
    case exact
    case missingSummary = "missing_summary"
    case duplicateSummary = "duplicate_summary"
    case incomplete
}

/// One bounded, authority-qualified entry in the Session workspace rail.
public struct CanonicalSessionWorkspaceRailEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let authorityID: String
    public let title: String
    public let modelID: String?
    public let state: CanonicalSessionWorkspaceRailState
    public let priority: Int
    public let workEvidence: [CanonicalAttentionAttachmentEvidence]
    public let omittedWorkEvidenceCount: Int
    public let join: CanonicalSessionWorkspaceRailJoin
    public let isKnown: Bool

    /// Short name for consumers that render a model column; this is the Session-selected model,
    /// never a model inferred from an attached Work or from a GUI capability.
    public var model: String? { modelID }

    fileprivate init(
        row: CanonicalAttentionInboxRow,
        summary: CanonicalSessionCatalogSummary?,
        join: CanonicalSessionWorkspaceRailJoin,
        workEvidence: [CanonicalAttentionAttachmentEvidence],
        omittedWorkEvidenceCount: Int,
        state: CanonicalSessionWorkspaceRailState,
        isKnown: Bool
    ) {
        self.id = CanonicalAttentionIdentity.sessionRow(journal: row.sessionJournal)
        self.session = row.session
        self.sessionJournal = row.sessionJournal
        self.authorityID = row.sessionJournal.authority.authorityID
        let summaryTitle = summary?.title ?? ""
        self.title = isKnown
            ? (summaryTitle.isEmpty ? "Untitled session" : summaryTitle)
            : "Session unavailable"
        self.modelID = isKnown ? summary?.sessionModelID : nil
        self.state = state
        self.priority = state.priority
        self.workEvidence = workEvidence
        self.omittedWorkEvidenceCount = max(0, omittedWorkEvidenceCount)
        self.join = join
        self.isKnown = isKnown
    }
}

/// A deterministic, bounded Session-workspace rail assembled from the attention projection and
/// the canonical Session catalog.
///
/// The inbox is the set of rows to display; the catalog is the authority for title, model,
/// lifecycle, and exact Work evidence. A row is known only when exactly one summary has the same
/// JournalRef and the row's identity agrees with it. This intentionally does not merge summaries
/// by bare SessionRef: two authorities may legitimately host the same Session ID.
public struct CanonicalSessionWorkspaceRailProjection: Codable, Hashable, Sendable {
    public static let maximumEntryCount = CanonicalAttentionInboxProjection.maximumRowCount
    public static let maximumWorkEvidenceCount =
        CanonicalAttentionInboxProjection.maximumAttachmentCount

    public let entries: [CanonicalSessionWorkspaceRailEntry]
    public let omittedEntryCount: Int
    public let sourceComplete: Bool

    public var isComplete: Bool {
        sourceComplete && omittedEntryCount == 0 && entries.allSatisfy { $0.isKnown }
    }

    public init(
        inbox: CanonicalAttentionInboxProjection,
        summaries: [CanonicalSessionCatalogSummary],
        maxEntries: Int = CanonicalSessionWorkspaceRailProjection.maximumEntryCount,
        maxWorkEvidence: Int = CanonicalSessionWorkspaceRailProjection.maximumWorkEvidenceCount,
        sourceComplete: Bool = true
    ) {
        let grouped = Dictionary(grouping: summaries, by: \.journal)
        let entryLimit = min(max(0, maxEntries), Self.maximumEntryCount)
        let evidenceLimit = min(max(0, maxWorkEvidence), Self.maximumWorkEvidenceCount)
        let boundedRows = Array(inbox.rows.prefix(entryLimit))
        self.omittedEntryCount = inbox.rows.count - boundedRows.count + inbox.omittedRowCount
        // Page truncation says only that additional Session rows exist outside this rail. It
        // does not invalidate the exact retained rows. Source-scan incompleteness still does.
        self.sourceComplete = sourceComplete

        var result: [CanonicalSessionWorkspaceRailEntry] = []
        result.reserveCapacity(boundedRows.count)
        for row in boundedRows {
            let matches = grouped[row.sessionJournal] ?? []
            guard matches.count == 1, let summary = matches.first,
                  row.session == summary.session,
                  Self.summaryIdentityIsCanonical(summary),
                  row.id == CanonicalAttentionIdentity.sessionRow(journal: summary.journal),
                  row.qualifiedSessionID == CanonicalAttentionIdentity.journal(summary.journal),
                  row.duplicateSummaryCount == 1,
                  Self.inboxRowMatchesCanonicalSummary(row, summary: summary),
                  sourceComplete
            else {
                let join: CanonicalSessionWorkspaceRailJoin = matches.isEmpty
                    ? .missingSummary : matches.count > 1 ? .duplicateSummary : .incomplete
                let evidence = Array(row.attachments.prefix(evidenceLimit))
                result.append(CanonicalSessionWorkspaceRailEntry(
                    row: row, summary: nil, join: join, workEvidence: evidence,
                    omittedWorkEvidenceCount: row.omittedAttachmentCount
                        + max(0, row.attachments.count - evidence.count), state: .unknown,
                    isKnown: false))
                continue
            }

            // Rebuild the bounded evidence from the joined canonical summary. The inbox row is
            // validated as the selector, while the catalog remains the source of rail facts.
            let canonicalRow = CanonicalAttentionInboxRow(
                summary: summary, maxAttachments: evidenceLimit)
            let evidence = canonicalRow.attachments
            let attachedCount = summary.work.filter(\.isAttached).count
            let state = Self.state(summary: summary, row: canonicalRow)
            result.append(CanonicalSessionWorkspaceRailEntry(
                row: row, summary: summary, join: .exact, workEvidence: evidence,
                omittedWorkEvidenceCount: max(0, attachedCount - evidence.count), state: state,
                isKnown: state != .unknown))
        }
        self.entries = result.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id < $1.id
        }
    }

    public init(
        inbox: CanonicalAttentionInboxProjection,
        catalog: [CanonicalSessionCatalogSummary],
        maxEntries: Int = CanonicalSessionWorkspaceRailProjection.maximumEntryCount,
        maxWorkEvidence: Int = CanonicalSessionWorkspaceRailProjection.maximumWorkEvidenceCount,
        sourceComplete: Bool = true
    ) {
        self.init(
            inbox: inbox, summaries: catalog, maxEntries: maxEntries,
            maxWorkEvidence: maxWorkEvidence, sourceComplete: sourceComplete)
    }

    private static func state(
        summary: CanonicalSessionCatalogSummary,
        row: CanonicalAttentionInboxRow
    ) -> CanonicalSessionWorkspaceRailState {
        guard row.attentionRequirement != .unknown, let attention = row.effectiveAttention else {
            return .unknown
        }
        switch attention {
        case .input: return .needsInput
        case .confirmation: return .needsConfirmation
        case .error: return .failed
        case .review: return .readyForReview
        case .none:
            if summary.work.contains(where: { work in
                work.isAttached && [.preparing, .running, .canceling].contains(work.execution)
            }) {
                return .working
            }
            switch summary.lifecycle {
            case .active: return .idle
            case .completed: return .completed
            case .archived: return .archived
            case .unknown: return .unknown
            }
        }
    }

    private static func summaryIdentityIsCanonical(
        _ summary: CanonicalSessionCatalogSummary
    ) -> Bool {
        guard summary.id == summary.journal.stableKey,
              case .session(let owner) = summary.journal.owner,
              owner == summary.session else { return false }
        return true
    }

    private static func inboxRowMatchesCanonicalSummary(
        _ row: CanonicalAttentionInboxRow,
        summary: CanonicalSessionCatalogSummary
    ) -> Bool {
        let full = CanonicalAttentionInboxRow(
            summary: summary,
            maxAttachments: CanonicalAttentionInboxProjection.maximumAttachmentCount)
        guard row.authoredAttention == full.authoredAttention,
              row.effectiveAttention == full.effectiveAttention,
              row.attentionRequirement == full.attentionRequirement,
              row.sessionSourceCursor == full.sessionSourceCursor,
              row.sessionSnapshotCursor == full.sessionSnapshotCursor,
              row.sessionCursorAlignment == full.sessionCursorAlignment,
              row.sessionIntegrityValid == full.sessionIntegrityValid,
              row.sessionStructuralIntegrityValid == full.sessionStructuralIntegrityValid,
              row.sessionSemanticProjectionValid == full.sessionSemanticProjectionValid,
              row.sessionTailBytes == full.sessionTailBytes,
              row.sessionUnknownDomains == full.sessionUnknownDomains,
              row.sessionUnknownEventRefs == full.sessionUnknownEventRefs,
              row.omittedSessionUnknownEventRefCount == full.omittedSessionUnknownEventRefCount,
              row.corruptionReasons == full.corruptionReasons,
              row.omittedCorruptionReasonCount == full.omittedCorruptionReasonCount,
              row.truncatedCorruptionReasonCount == full.truncatedCorruptionReasonCount
        else { return false }
        let attachedCount = summary.work.filter(\.isAttached).count
        guard row.omittedAttachmentCount + row.attachments.count == attachedCount,
              row.attachments.allSatisfy({ full.attachments.contains($0) })
        else { return false }
        return true
    }
}

public extension CanonicalAttentionInboxProjection {
    /// Assemble the canonical Session workspace rail without giving the rail a second source of
    /// attention truth.
    func workspaceRail(
        summaries: [CanonicalSessionCatalogSummary],
        maxEntries: Int = CanonicalSessionWorkspaceRailProjection.maximumEntryCount,
        maxWorkEvidence: Int = CanonicalSessionWorkspaceRailProjection.maximumWorkEvidenceCount,
        sourceComplete: Bool = true
    ) -> CanonicalSessionWorkspaceRailProjection {
        CanonicalSessionWorkspaceRailProjection(
            inbox: self, summaries: summaries, maxEntries: maxEntries,
            maxWorkEvidence: maxWorkEvidence, sourceComplete: sourceComplete)
    }
}
