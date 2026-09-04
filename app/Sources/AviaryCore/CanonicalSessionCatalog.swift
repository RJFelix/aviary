import Foundation

/// A bounded, source-qualified catalog row derived from canonical Timeline projections.
///
/// This is deliberately not `SessionSummary`: that type is the legacy on-disk JSONL scanner's
/// compatibility row and carries filesystem metadata, usage counters, and display heuristics.
/// Canonical rows contain only facts projected by the Session/Work reducers. In particular, they
/// carry independent cursors rather than inventing an updated-at ordering across journals.
public struct CanonicalWorkCatalogSummary: Codable, Hashable, Sendable, Identifiable {
    public enum CursorAlignment: String, Codable, Hashable, Sendable {
        case exact
        case requestedAhead
        case observedAhead
        case divergent
        case requestedUnavailable
        case unavailable
    }

    /// Alignment of the optional byte read supplied alongside a reducer snapshot. This is
    /// deliberately separate from `cursorAlignment`, which compares the attachment request
    /// with the Work reducer's observed tip.
    public enum WorkReadAlignment: String, Codable, Hashable, Sendable {
        case notSupplied
        case exact
        case stale
        case ahead
        case foreign
        case divergent
        case invalid
    }

    public let attachment: SessionAttachmentRef
    public let work: WorkRef
    public let workHost: WorkHostRef
    public let journal: JournalRef?
    public let requestedCursor: JournalCursor?
    public let observedCursor: JournalCursor?
    public let workReadCursor: JournalCursor?
    public let cursorAlignment: CursorAlignment
    public let workReadAlignment: WorkReadAlignment
    public let isAttached: Bool
    /// False when an unknown Session-journal event may have changed attachment semantics.
    public let attachmentProjectionKnown: Bool
    /// Capabilities declared by this Session attachment. Multiple Session attachments may point
    /// at one Work; no GUI is treated as the Work owner.
    public let attachmentCapabilities: [String]
    public let isAvailable: Bool
    public let lifecycle: WorkLifecycle
    public let execution: WorkExecution
    public let modelID: String?
    public let activeRun: RunRef?
    public let activeTurn: TurnRef?
    public let outstandingActionIDs: [String]
    public let indeterminateActionIDs: [String]
    public let outstandingHandleIDs: [String]
    public let outstandingCommandIDs: [String]
    public let structuralIntegrityValid: Bool
    public let semanticProjectionValid: Bool
    /// Nil means no journal read was supplied. A supplied read is always true or false: false
    /// covers foreign, stale/ahead/divergent, broken, duplicate, and tailed reads, as well as an
    /// exact read paired with an invalid reducer snapshot.
    public let journalIntegrityValid: Bool?
    public let tailBytes: Int?
    public let unknownEventRefs: [EventRef]
    public let unknownDomains: [TimelineDomain]
    public let corruptionReasons: [String]

    public var id: String { attachment.attachmentID }
    /// Compatibility alias for callers that have not yet split requested/observed cursors.
    public var cursor: JournalCursor? { requestedCursor }
    public var alignment: CursorAlignment { cursorAlignment }

    /// The only condition under which Work execution facts may drive UI or Session assembly.
    /// Attachment, cursor, and both reducer validity planes are all required; availability or a
    /// matching identity alone is not evidence that the state is safe to project.
    public var canProjectExecution: Bool {
        isAttached && cursorAlignment == .exact
            && structuralIntegrityValid && semanticProjectionValid
            && !unknownDomains.contains(.work)
            && attachmentProjectionKnown && journalIntegrityValid == true
    }

    fileprivate init(
        attachment: SessionAttachmentSnapshot,
        work: WorkSnapshot?,
        cursor: JournalCursor?,
        workRead: TimelineJournalReadResult?,
        attachmentProjectionKnown: Bool
    ) {
        self.attachment = attachment.attachment
        self.work = attachment.work
        self.workHost = WorkHostRef(attachment.work.workHostID)
        // Matching the attachment's WorkRef alone is not enough to establish authority. A
        // malformed/foreign journal or Work Host must not make its state look available here.
        let trustedWork = canonicalWorkSnapshot(work, for: attachment.work)
        self.journal = trustedWork?.journal
        self.requestedCursor = cursor
        let observedCursor: JournalCursor?
        if let snapshot = trustedWork, let journal = snapshot.journal, let eventID = snapshot.lastEventID {
            observedCursor = JournalCursor(journal: journal, eventID: eventID, sequence: snapshot.lastSequence)
        } else {
            observedCursor = nil
        }
        self.observedCursor = observedCursor
        let readCursor = Self.readCursor(workRead)
        self.workReadCursor = readCursor
        self.workReadAlignment = Self.workReadAlignment(
            read: workRead, snapshot: trustedWork, cursor: readCursor, observed: observedCursor)
        self.cursorAlignment = Self.alignment(
            requested: cursor, observed: observedCursor,
            observedEventSequences: trustedWork?.eventSequences,
            workRead: workRead,
            workReadIsCanonical: Self.workReadIsCanonical(workRead, for: trustedWork))
        self.isAttached = attachment.isAttached
        self.attachmentProjectionKnown = attachmentProjectionKnown
        self.attachmentCapabilities = attachment.capabilities.sorted()
        self.isAvailable = trustedWork != nil
        let aligned = self.cursorAlignment == .exact
        self.structuralIntegrityValid = trustedWork?.structuralIntegrityValid ?? false
        self.semanticProjectionValid = trustedWork?.semanticProjectionValid ?? false
        let workFactsKnown = trustedWork?.unknownDomains.contains(.work) == false
        let suppliedReadIsUsable = workRead != nil && (
            self.workReadAlignment == .exact
                && workRead?.quarantinedSuffix == nil
                && workRead?.truncatedTail == nil)
        let projectable = attachment.isAttached && aligned
            && self.structuralIntegrityValid && self.semanticProjectionValid
            && workFactsKnown && suppliedReadIsUsable && attachmentProjectionKnown
        self.lifecycle = projectable ? (trustedWork?.lifecycle ?? .unknown) : .unknown
        self.execution = projectable ? (trustedWork?.execution ?? .unknown) : .unknown
        self.modelID = projectable ? trustedWork?.modelID : nil
        self.activeRun = projectable ? trustedWork?.activeRun : nil
        self.activeTurn = projectable ? trustedWork?.activeTurn : nil
        let actionFactsKnown = projectable
            && trustedWork?.unknownDomains.contains(.externalEffects) == false
        let runtimeFactsKnown = projectable
            && trustedWork?.unknownDomains.contains(.runtime) == false
        self.outstandingActionIDs = actionFactsKnown
            ? (trustedWork?.activeActionIDs.sorted() ?? []) : []
        self.indeterminateActionIDs = actionFactsKnown ? trustedWork?.actions.values
            .filter { $0.state == .indeterminateEffect }
            .map { $0.action.actionID }
            .sorted() ?? [] : []
        self.outstandingHandleIDs = runtimeFactsKnown ? trustedWork?.handles.values
            .filter { !["succeeded", "failed", "canceled", "completed"].contains($0.state) }
            .map { $0.handle.handleID }
            .sorted() ?? [] : []
        self.outstandingCommandIDs = projectable ? trustedWork?.commands.values
            .filter { $0.state == .accepted }
            .map { $0.command.commandID }
            .sorted() ?? [] : []
        self.journalIntegrityValid = workRead == nil ? nil : (
            self.workReadAlignment == .exact
                && self.structuralIntegrityValid && self.semanticProjectionValid
                && workRead?.quarantinedSuffix == nil
                && workRead?.truncatedTail == nil)
        self.unknownEventRefs = trustedWork?.unknownEvents.map {
            EventRef(journal: $0.event.journal, eventID: $0.event.eventID)
        }.sorted(by: CanonicalSessionCatalogSummary.sortEventRefs) ?? []
        self.unknownDomains = trustedWork?.unknownDomains.sorted { $0.rawValue < $1.rawValue } ?? []
        var reasons = trustedWork?.corruptionReasons ?? []
        if work != nil && trustedWork == nil {
            reasons.append("Work snapshot identity does not match attachment, journal owner, or Work Host")
        }
        if !attachmentProjectionKnown {
            reasons.append("Session attachment projection is affected by an unknown event domain")
        }
        if let workRead, !Self.workReadIsCanonical(workRead, for: trustedWork) {
            reasons.append("Work journal read contains a foreign or mismatched journal record")
        }
        if let workRead, !Self.readHasUniqueEventIDs(workRead) {
            reasons.append("Work journal read contains duplicate event IDs")
        }
        if let workRead, !Self.readHasValidChain(workRead) {
            reasons.append("Work journal read has a broken append chain")
        }
        if let workRead {
            if workRead.quarantinedSuffix != nil { reasons.append("journal has a quarantined suffix") }
            if workRead.truncatedTail != nil { reasons.append("journal has an uncommitted truncated tail") }
        }
        self.tailBytes = workRead.map {
            ($0.quarantinedSuffix?.rawBytes.count ?? 0) + ($0.truncatedTail?.rawBytes.count ?? 0)
        }
        self.corruptionReasons = reasons
    }

    private static func workReadAlignment(
        read: TimelineJournalReadResult?, snapshot: WorkSnapshot?, cursor: JournalCursor?,
        observed: JournalCursor?
    ) -> WorkReadAlignment {
        guard let read else { return .notSupplied }
        guard !read.records.isEmpty else { return .invalid }
        guard workReadIsCanonical(read, for: snapshot) else {
            return .foreign
        }
        guard readHasValidChain(read) else { return .invalid }
        guard let cursor, let observed else { return .invalid }
        guard cursor.journal == observed.journal else { return .foreign }
        if cursor.eventID == observed.eventID, cursor.sequence == observed.sequence {
            return .exact
        }
        if cursor.sequence < observed.sequence {
            guard let readEventID = cursor.eventID,
                  snapshot?.eventSequences[readEventID] == cursor.sequence,
                  let observedEventID = observed.eventID,
                  snapshot?.eventSequences[observedEventID] == observed.sequence
            else { return .divergent }
            return .stale
        }
        if cursor.sequence > observed.sequence {
            guard let observedEventID = observed.eventID,
                  read.records.contains(where: {
                      $0.event.eventID == observedEventID
                          && $0.event.sequence == observed.sequence
                  })
            else { return .divergent }
            return .ahead
        }
        return .divergent
    }

    private static func alignment(
        requested: JournalCursor?, observed: JournalCursor?,
        observedEventSequences: [String: Int]?,
        workRead: TimelineJournalReadResult?,
        workReadIsCanonical: Bool
    ) -> CursorAlignment {
        guard let observed else { return .unavailable }
        guard let requested else { return .requestedUnavailable }
        guard requested.journal == observed.journal else { return .divergent }
        guard requested.eventID == observed.eventID else {
            if requested.sequence < observed.sequence {
                guard let eventID = requested.eventID,
                      observedEventSequences?[eventID] == requested.sequence,
                      let observedEventID = observed.eventID,
                      observedEventSequences?[observedEventID] == observed.sequence
                else { return .divergent }
                return .observedAhead
            }
            guard requested.sequence > observed.sequence,
                  Self.provesAncestry(
                      from: observed, to: requested, read: workRead,
                      isCanonical: workReadIsCanonical)
            else { return .divergent }
            return .requestedAhead
        }
        if requested.sequence == observed.sequence { return .exact }
        // An event ID is a position in the append chain. Seeing the same ID at two sequence
        // positions is structural disagreement, not evidence of either cursor being ahead.
        return .divergent
    }

    private static func readCursor(_ read: TimelineJournalReadResult?) -> JournalCursor? {
        guard let record = read?.records.last else { return nil }
        return JournalCursor(
            journal: record.event.journal, eventID: record.event.eventID, sequence: record.event.sequence)
    }

    fileprivate static func readHasUniqueEventIDs(_ read: TimelineJournalReadResult?) -> Bool {
        guard let read else { return true }
        return Set(read.records.map { $0.event.eventID }).count == read.records.count
    }

    fileprivate static func readHasValidChain(_ read: TimelineJournalReadResult?) -> Bool {
        guard let read else { return false }
        guard readHasUniqueEventIDs(read) else { return false }
        guard read.records.count > 1 else { return true }
        for index in 1..<read.records.count {
            let previous = read.records[index - 1].event
            let current = read.records[index].event
            guard current.sequence == previous.sequence + 1,
                  current.previousEventID == previous.eventID
            else { return false }
        }
        return true
    }

    private static func workReadIsCanonical(
        _ read: TimelineJournalReadResult?, for snapshot: WorkSnapshot?
    ) -> Bool {
        guard let read, let snapshot, let journal = snapshot.journal, let work = snapshot.work else {
            return false
        }
        let host = WorkHostRef(work.workHostID)
        return read.records.allSatisfy {
            $0.event.journal == journal
                && ($0.event.work == nil || $0.event.work == work)
                && ($0.event.workHost == nil || $0.event.workHost == host)
        }
    }

    /// A requested-ahead cursor is a claim about the future part of this same append chain. A
    /// sequence number and journal identity alone cannot distinguish that from another branch;
    /// require the supplied read to contain both tips and their contiguous physical links.
    private static func provesAncestry(
        from ancestor: JournalCursor,
        to descendant: JournalCursor,
        read: TimelineJournalReadResult?,
        isCanonical: Bool
    ) -> Bool {
        guard isCanonical, readHasValidChain(read), let records = read?.records,
              let ancestorID = ancestor.eventID, let descendantID = descendant.eventID,
              let ancestorIndex = records.firstIndex(where: {
                  $0.event.eventID == ancestorID && $0.event.sequence == ancestor.sequence
              }),
              let descendantIndex = records.firstIndex(where: {
                  $0.event.eventID == descendantID && $0.event.sequence == descendant.sequence
              }),
              ancestorIndex < descendantIndex
        else { return false }
        var previous = records[ancestorIndex].event
        for record in records[(ancestorIndex + 1)...descendantIndex] {
            guard record.event.sequence == previous.sequence + 1,
                  record.event.previousEventID == previous.eventID
            else { return false }
            previous = record.event
        }
        return true
    }
}

/// Validate a supplied Work projection before it can participate in a Session projection. The
/// same WorkRef must be present in the attachment, snapshot, and journal owner; its host must be
/// present in both the WorkRef and snapshot, and a Work journal's authority must be that host.
private func canonicalWorkSnapshot(_ snapshot: WorkSnapshot?, for attachedWork: WorkRef) -> WorkSnapshot? {
    guard let snapshot,
          let snapshotWork = snapshot.work,
          snapshotWork == attachedWork,
          let journal = snapshot.journal,
          case .work(let journalWork) = journal.owner,
          journalWork == attachedWork,
          journal.authority.authorityID == attachedWork.workHostID,
          let workHost = snapshot.workHost,
          workHost.workHostID == attachedWork.workHostID
    else { return nil }
    return snapshot
}

/// The canonical replacement shape for a legacy `SessionSummary` when a caller has Timeline v2
/// snapshots. It is intentionally a projection, not a second source of truth or an assertion
/// that every existing catalog consumer has migrated.
public struct CanonicalSessionCatalogSummary: Codable, Hashable, Sendable, Identifiable {
    public let session: SessionRef
    public let journal: JournalRef
    public let id: String
    public let title: String
    public let lifecycle: SessionLifecycle
    public let authoredAttention: SessionAttention
    public let attentionSourceEvent: EventRef?
    /// Compatibility field retaining the authored Session attention. Consumers needing an
    /// effective answer must use `effectiveAttention`, which is nil until every active Work
    /// attachment is available and exactly aligned at its requested cursor.
    public let attention: SessionAttention
    public let effectiveAttention: SessionAttention?
    public let activeTip: EventRef?
    public let visibleMessages: [SessionMessageSnapshot]
    public let contextInclusionIDs: [String]
    public let omittedContextIDs: [String]
    /// The model selected by the Session journal itself, separate from models observed on Work.
    public let sessionModelID: String?
    public let modelIDs: [String]
    public let childStates: [String: String]
    /// The cursor of the reducer snapshot. This is never inferred from a read result.
    public let sessionSnapshotCursor: JournalCursor?
    /// The cursor of the supplied journal read, retaining the read event's actual authority.
    public let sessionReadCursor: JournalCursor?
    /// Correlation between the reducer snapshot and the supplied read. Integrity is false for
    /// any supplied non-exact read, while tail bytes remain visible as evidence; an unaligned
    /// read is never relabeled as the Session journal or combined with snapshot validity.
    public let sessionCursorAlignment: CanonicalWorkCatalogSummary.CursorAlignment
    /// Compatibility cursor for legacy callers. This is the actual read cursor, if any.
    public let sessionCursor: JournalCursor?
    /// Recovery claims retain their recording event and Work/Run envelope. The coverage's
    /// evidence cursor is the recovered prefix, not the claim event itself.
    public let recordedRecoveryCoverage: [RecordedRecoveryCoverage]?
    public let work: [CanonicalWorkCatalogSummary]
    public let assemblyReady: Bool
    public let sessionStructuralIntegrityValid: Bool
    public let sessionSemanticProjectionValid: Bool
    /// Nil means no Session journal read result was supplied.
    public let sessionIntegrityValid: Bool?
    public let sessionTailBytes: Int?
    public let unknownEventRefs: [EventRef]
    public let unknownDomains: [TimelineDomain]
    public let corruptionReasons: [String]

    fileprivate init?(
        session: SessionSnapshot,
        works: [WorkSnapshot],
        cursors: [String: JournalCursor],
        sessionRead: TimelineJournalReadResult?,
        workReads: [JournalRef: TimelineJournalReadResult],
        allowLegacyCompatibilityFacts: Bool = false
    ) {
        // SessionReducer establishes this identity from its journal. A missing identity is not a
        // valid canonical catalog row and is surfaced by the failable public adapter below.
        guard let canonicalSession = session.session, let canonicalJournal = session.journal else {
            return nil
        }
        self.session = canonicalSession
        self.journal = canonicalJournal
        guard case .session(let owner) = canonicalJournal.owner, owner == canonicalSession else {
            return nil
        }
        // The legacy bridge has a deliberately tiny, explicitly mapped fact set. Preserve those
        // title/model/lifecycle values for compatibility, but never let that exception project
        // native attachments, context, attention, or execution truth.
        let sessionFactsKnown = allowLegacyCompatibilityFacts
            || !session.unknownDomains.contains(.session)
        let attachmentFactsKnown = !allowLegacyCompatibilityFacts && sessionFactsKnown
            && !session.unknownDomains.contains(.work)
        let contextFactsKnown = !allowLegacyCompatibilityFacts && sessionFactsKnown
            && !session.unknownDomains.contains(.context)
        self.id = canonicalJournal.stableKey
        let firstUser = session.messages.first(where: { $0.role == "user" })?.text ?? ""
        let flattenedTitle = firstUser.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.title = sessionFactsKnown ? String(flattenedTitle.prefix(120)) : ""
        self.lifecycle = sessionFactsKnown ? session.lifecycle : .unknown
        self.authoredAttention = sessionFactsKnown ? session.attention : .none
        self.attentionSourceEvent = sessionFactsKnown ? session.attentionEvent : nil
        self.sessionModelID = sessionFactsKnown ? session.modelID : nil
        let orderedWorks = works.sorted { lhs, rhs in
            let lhsKey = lhs.journal?.stableKey ?? ""
            let rhsKey = rhs.journal?.stableKey ?? ""
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            if lhs.lastSequence != rhs.lastSequence { return lhs.lastSequence > rhs.lastSequence }
            return (lhs.lastEventID ?? "") > (rhs.lastEventID ?? "")
        }
        // Do not let an identity-inconsistent snapshot satisfy the assembler's cursor checks.
        // It remains visible below as an unavailable Work row, but cannot contribute effective
        // attention, model, child, or assembly-ready facts.
        let attachedWorkIDs = Set(session.attachments.values.compactMap {
            attachmentFactsKnown && $0.isAttached ? $0.work : nil
        })
        let trustedWorks = orderedWorks.filter { snapshot in
            guard let attachedWork = snapshot.work,
                  attachedWorkIDs.contains(attachedWork),
                  let trusted = canonicalWorkSnapshot(snapshot, for: attachedWork)
            else { return false }
            return trusted.structuralIntegrityValid && trusted.semanticProjectionValid
        }
        let assembly = sessionFactsKnown && attachmentFactsKnown
            && session.structuralIntegrityValid && session.semanticProjectionValid
            ? SessionAssembler.assemble(session: session, works: trustedWorks, at: cursors)
            : nil
        self.attention = sessionFactsKnown ? session.attention : .none
        self.activeTip = sessionFactsKnown ? session.semanticTip : nil
        self.visibleMessages = sessionFactsKnown ? session.messages : []
        self.contextInclusionIDs = contextFactsKnown ? session.contextComponents
            .filter { !$0.omitted && $0.mode != .omitted }.map(\.inclusionID) : []
        self.omittedContextIDs = contextFactsKnown ? session.contextComponents
            .filter { $0.omitted || $0.mode == .omitted }.map(\.inclusionID) : []
        let snapshotCursor: JournalCursor?
        if let eventID = session.lastEventID, session.lastSequence > 0 {
            snapshotCursor = JournalCursor(
                journal: canonicalJournal, eventID: eventID, sequence: session.lastSequence)
        } else {
            snapshotCursor = nil
        }
        let readCursor = sessionRead?.records.last.map {
            // Keep the event's real journal authority. In particular, never turn a foreign
            // read into an apparently valid cursor by substituting `canonicalJournal`.
            JournalCursor(
                journal: $0.event.journal, eventID: $0.event.eventID, sequence: $0.event.sequence)
        }
        let readHasOnlyCanonicalJournal = sessionRead?.records.allSatisfy {
            $0.event.journal == canonicalJournal
        } ?? false
        // A hostile or partially-corrupt read can repeat an event ID. Do not use
        // Dictionary(uniqueKeysWithValues:) here: duplicate IDs must remain an explicit
        // unproven read rather than trapping the catalog process.
        var readEventSequences: [String: Int] = [:]
        var duplicateReadEventIDs = false
        for record in sessionRead?.records ?? [] {
            if readEventSequences[record.event.eventID] != nil {
                duplicateReadEventIDs = true
            } else {
                readEventSequences[record.event.eventID] = record.event.sequence
            }
        }
        self.sessionSnapshotCursor = snapshotCursor
        self.sessionReadCursor = readCursor
        self.sessionCursorAlignment = Self.sessionAlignment(
            snapshot: snapshotCursor, read: readCursor,
            readHasOnlyCanonicalJournal: readHasOnlyCanonicalJournal,
            snapshotEventIDs: session.seenEventIDs,
            readEventSequences: readEventSequences,
            duplicateReadEventIDs: duplicateReadEventIDs,
            readHasValidChain: CanonicalWorkCatalogSummary.readHasValidChain(sessionRead))
        self.sessionCursor = readCursor
        self.recordedRecoveryCoverage = sessionFactsKnown ? session.recordedRecovery : nil
        self.sessionStructuralIntegrityValid = session.structuralIntegrityValid
        self.sessionSemanticProjectionValid = session.semanticProjectionValid
        let readIsExact = self.sessionCursorAlignment == .exact
        self.sessionTailBytes = sessionRead.map {
            ($0.truncatedTail?.rawBytes.count ?? 0) + ($0.quarantinedSuffix?.rawBytes.count ?? 0)
        }
        self.sessionIntegrityValid = sessionRead == nil ? nil : (
            readIsExact && session.structuralIntegrityValid && session.semanticProjectionValid
                && sessionRead?.truncatedTail == nil && sessionRead?.quarantinedSuffix == nil)
        self.unknownEventRefs = session.unknownEvents.map {
            EventRef(journal: $0.event.journal, eventID: $0.event.eventID)
        }.sorted(by: Self.sortEventRefs)
        self.unknownDomains = session.unknownDomains.sorted { $0.rawValue < $1.rawValue }
        var reasons = session.corruptionReasons
        if duplicateReadEventIDs {
            reasons.append("Session journal read contains duplicate event IDs")
        }
        if let sessionRead, !CanonicalWorkCatalogSummary.readHasValidChain(sessionRead) {
            reasons.append("Session journal read has a broken append chain")
        }
        if let sessionRead {
            if sessionRead.quarantinedSuffix != nil { reasons.append("journal has a quarantined suffix") }
            if sessionRead.truncatedTail != nil { reasons.append("journal has an uncommitted truncated tail") }
        }
        self.corruptionReasons = reasons

        let workRows = session.attachments.values.sorted {
            $0.attachment.attachmentID < $1.attachment.attachmentID
        }.map { attachment in
            let cursor = cursors[attachment.attachment.attachmentID] ?? attachment.cursor
            // Pass the untrusted matching snapshot as well: CanonicalWorkCatalogSummary turns it
            // into an unavailable row and retains the identity mismatch reason, instead of
            // silently dropping an attached Work from the catalog.
            let suppliedSnapshot = trustedWorks.first { $0.work == attachment.work }
                ?? orderedWorks.first { candidate in
                guard let journal = candidate.journal else { return false }
                guard case .work(let journalWork) = journal.owner else {
                    return candidate.work == attachment.work
                }
                return journalWork == attachment.work
            }
            // Even an integrity-invalid reducer snapshot can have a canonical identity and a
            // supplied byte read. Keep that read visible so recovery distinguishes invalid data
            // from a genuinely absent read.
            let read: TimelineJournalReadResult?
            if let snapshot = suppliedSnapshot,
               canonicalWorkSnapshot(snapshot, for: attachment.work) != nil,
               let journal = snapshot.journal
            {
                read = workReads[journal]
            } else {
                read = nil
            }
            return CanonicalWorkCatalogSummary(
                attachment: attachment, work: suppliedSnapshot, cursor: cursor, workRead: read,
                attachmentProjectionKnown: attachmentFactsKnown)
        }
        self.work = workRows
        let attachedIDs = Set(session.attachments.values.filter(\.isAttached).map { $0.attachment.attachmentID })
        let projectableIDs = Set(workRows.filter(\.canProjectExecution).map { $0.attachment.attachmentID })
        self.assemblyReady = assembly != nil && attachedIDs.isSubset(of: projectableIDs)
        // A legacy adapter marks all semantic domains unknown. An empty attachment set is not
        // evidence that no Work or attention exists, so do not project the assembler's default
        // `.none` as an effective answer in that case.
        self.effectiveAttention = session.unknownDomains.isEmpty && self.assemblyReady
            ? assembly?.effectiveAttention : nil
        let alignedWorks = workRows.filter(\.canProjectExecution)
        self.modelIDs = Array(Set([self.sessionModelID].compactMap { $0 }
            + alignedWorks.compactMap(\.modelID))).sorted()
        var alignedChildren = sessionFactsKnown ? session.childStates : [:]
        for row in alignedWorks {
            if let snapshot = trustedWorks.first(where: { $0.work == row.work }) {
                alignedChildren.merge(snapshot.childStates) { _, workState in workState }
            }
        }
        self.childStates = alignedChildren
    }

    fileprivate static func sortEventRefs(_ lhs: EventRef, _ rhs: EventRef) -> Bool {
        if lhs.journal.stableKey != rhs.journal.stableKey {
            return lhs.journal.stableKey < rhs.journal.stableKey
        }
        return lhs.eventID < rhs.eventID
    }

    private static func sessionAlignment(
        snapshot: JournalCursor?, read: JournalCursor?, readHasOnlyCanonicalJournal: Bool,
        snapshotEventIDs: Set<String>, readEventSequences: [String: Int],
        duplicateReadEventIDs: Bool, readHasValidChain: Bool
    ) -> CanonicalWorkCatalogSummary.CursorAlignment {
        guard let read else {
            return snapshot == nil ? .unavailable : .requestedUnavailable
        }
        guard readHasOnlyCanonicalJournal, !duplicateReadEventIDs, readHasValidChain,
              let snapshot else {
            return .divergent
        }
        guard snapshot.journal == read.journal else { return .divergent }
        if snapshot.eventID == read.eventID {
            return snapshot.sequence == read.sequence ? .exact : .divergent
        }
        if snapshot.sequence > read.sequence {
            // The read is a stale prefix only when its tip is known to the snapshot.
            return read.eventID.map { snapshotEventIDs.contains($0) } == true
                ? .requestedAhead : .divergent
        }
        if snapshot.sequence < read.sequence {
            // The read is ahead only when it explicitly contains the snapshot tip at the
            // snapshot's sequence; a larger sequence number alone may describe another branch.
            return snapshot.eventID.flatMap { readEventSequences[$0] } == snapshot.sequence
                ? .observedAhead : .divergent
        }
        return .divergent
    }
}

public enum SessionCatalogCanonicalAdapter {
    /// Summarize canonical snapshots without merging journals by timestamp. Returns nil when the
    /// Session snapshot has no authoritative identity; missing attached Work remains visible as an
    /// unavailable row and makes `assemblyReady` false rather than being silently omitted.
    public static func summarize(
        session: SessionSnapshot,
        works: [WorkSnapshot],
        cursors: [String: JournalCursor] = [:],
        sessionRead: TimelineJournalReadResult? = nil,
        workReads: [JournalRef: TimelineJournalReadResult] = [:]
    ) -> CanonicalSessionCatalogSummary? {
        guard session.session != nil, session.journal != nil else { return nil }
        return CanonicalSessionCatalogSummary(
            session: session, works: works, cursors: cursors,
            sessionRead: sessionRead, workReads: workReads)
    }
}

public extension CanonicalSessionCatalogSummary {
    /// Destructive or duplicate-start actions must fail closed when native attachment truth is
    /// incomplete. Callers should use this only for structurally/semantically valid native rows;
    /// legacy compatibility rows deliberately mark every domain unknown.
    var hasOngoingOrUncertainAttachedWork: Bool {
        if unknownDomains.contains(.session) || unknownDomains.contains(.work) {
            return true
        }
        return work.contains {
            $0.isAttached && (!$0.canProjectExecution || $0.lifecycle == .active)
        }
    }

    /// Build the bounded compatibility projection used while the catalog still reads legacy
    /// transcripts. This is an explicit mapping of the scanner's title/model/lifecycle facts,
    /// not semantic parity with a native Session journal: context, Work, runtime, and external
    /// effects remain unknown and semantic validity is false.
    static func legacyCompatibility(
        summary: SessionSummary,
        authorityID: String
    ) -> CanonicalSessionCatalogSummary {
        let session = SessionRef(summary.id)
        let journal = JournalRef.session(
            session, journalID: "legacy-session",
            authority: TimelineAuthorityRef(authorityID))
        var snapshot = SessionSnapshot()
        snapshot.session = session
        snapshot.journal = journal
        switch summary.sessionState?.lowercased() {
        case "active", "running": snapshot.lifecycle = .active
        case "completed", "complete", "succeeded", "success": snapshot.lifecycle = .completed
        case "archived": snapshot.lifecycle = .archived
        default: snapshot.lifecycle = .unknown
        }
        snapshot.modelID = summary.model
        if !summary.title.isEmpty, summary.title != "Untitled session" {
            let message = SessionMessageSnapshot(
                eventID: "legacy-summary:\(summary.id)", role: "user", text: summary.title)
            snapshot.messages = [message]
            snapshot.messageHistory = [message]
        }
        snapshot.unknownDomains = Set(TimelineDomain.allCases)
        snapshot.semanticProjectionValid = false
        snapshot.corruptionReasons = [
            "legacy SessionSummary mapped; native Session/Work semantics unavailable"
        ]
        return CanonicalSessionCatalogSummary(
            session: snapshot, works: [], cursors: [:], sessionRead: nil, workReads: [:],
            allowLegacyCompatibilityFacts: true)!
    }
}

#if !os(Linux)
public extension SessionCatalog {
    /// Canonical snapshot adapter. The existing `scan()` and `summarize(fileURL:)` remain the
    /// legacy JSONL compatibility path until each catalog consumer is migrated explicitly.
    static func summarizeCanonical(
        session: SessionSnapshot,
        works: [WorkSnapshot],
        cursors: [String: JournalCursor] = [:],
        sessionRead: TimelineJournalReadResult? = nil,
        workReads: [JournalRef: TimelineJournalReadResult] = [:]
    ) -> CanonicalSessionCatalogSummary? {
        SessionCatalogCanonicalAdapter.summarize(
            session: session, works: works, cursors: cursors,
            sessionRead: sessionRead, workReads: workReads)
    }
}
#endif
