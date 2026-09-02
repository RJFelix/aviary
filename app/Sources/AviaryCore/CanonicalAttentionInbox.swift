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

    fileprivate init(
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
        let sorted = grouped.values.sorted {
            CanonicalAttentionIdentity.journal($0[0].journal)
                < CanonicalAttentionIdentity.journal($1[0].journal)
        }
        let boundedCount = min(max(0, maxRows), Self.maximumRowCount)
        let kept = Array(sorted.prefix(boundedCount))
        self.omittedRowCount = sorted.count - kept.count
        self.rows = kept.map {
            if $0.count == 1 {
                return CanonicalAttentionInboxRow(
                    summary: $0[0], maxAttachments: maxAttachments)
            }
            return CanonicalAttentionInboxRow(conflictingSummaries: $0)
        }
    }
}
