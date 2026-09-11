import Foundation

/// The fixture manifest is intentionally data-only. It is useful to external readers and
/// self-tests, but it does not make a claim that every consumer in the application has migrated
/// to Timeline v2.
public struct ReaderCensusManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let projectionRulesVersion: Int
    public let fixtureID: String
    public let sessionJournal: String
    public let workJournal: String
    public let controlJournal: String
    public let legacyJournal: String
    public let retainedBodies: [String]
    public let malformedVariants: [String]
    public let registeredConsumers: [String]
    public let intentionallyUnwiredConsumers: [String]

    public init(
        schemaVersion: Int = 2,
        projectionRulesVersion: Int = 2,
        fixtureID: String,
        sessionJournal: String,
        workJournal: String,
        controlJournal: String,
        legacyJournal: String,
        retainedBodies: [String] = [],
        malformedVariants: [String] = [],
        registeredConsumers: [String] = [],
        intentionallyUnwiredConsumers: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.projectionRulesVersion = projectionRulesVersion
        self.fixtureID = fixtureID
        self.sessionJournal = sessionJournal
        self.workJournal = workJournal
        self.controlJournal = controlJournal
        self.legacyJournal = legacyJournal
        self.retainedBodies = retainedBodies
        self.malformedVariants = malformedVariants
        self.registeredConsumers = registeredConsumers
        self.intentionallyUnwiredConsumers = intentionallyUnwiredConsumers
    }
}

public enum ReaderCensusAttachmentKind: String, Codable, Hashable, Sendable {
    case session
    case client
}

public struct ReaderCensusAttachment: Codable, Hashable, Sendable {
    public let journal: JournalRef
    public let id: String
    public let kind: ReaderCensusAttachmentKind
    public let sessionAttachment: SessionAttachmentRef?
    public let clientAttachment: ClientAttachmentRef?
    public let work: WorkRef?
    public let client: ClientRef?
    public let capabilities: [String]
    public let isAttached: Bool

    /// A display/index convenience derived from the typed identity. It is intentionally not a
    /// second Codable field that could disagree with `work` or `client` at a remote boundary.
    public var target: String {
        if let work { return work.workID }
        if let client { return client.clientID }
        return id
    }

    public init(
        journal: JournalRef, id: String, kind: ReaderCensusAttachmentKind,
        sessionAttachment: SessionAttachmentRef? = nil,
        clientAttachment: ClientAttachmentRef? = nil,
        work: WorkRef? = nil, client: ClientRef? = nil,
        capabilities: [String], isAttached: Bool
    ) {
        self.journal = journal
        self.id = id
        self.kind = kind
        self.sessionAttachment = sessionAttachment
        self.clientAttachment = clientAttachment
        self.work = work
        self.client = client
        self.capabilities = capabilities
        self.isAttached = isAttached
    }
}

public struct ReaderCensusContextComponent: Codable, Hashable, Sendable {
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

    public init(component: ContextComponent) {
        componentID = component.componentID
        inclusionID = component.inclusionID
        sourceID = component.sourceID
        sourceProvenance = component.source.provenance
        mode = component.mode
        deliveryMode = component.deliveryMode
        measuredBytes = component.measuredBytes
        includedBytes = component.includedBytes
        deliveredBytes = component.deliveredBytes
        fullByteCount = component.fullByteCount
        bodyReference = component.bodyReference
        digest = component.digest
        tokenCount = component.tokenCount
        tokenizer = component.tokenizer
        omitted = component.omitted
    }
}

public struct ReaderCensusRecovery: Codable, Hashable, Sendable {
    public let journal: JournalRef
    public let coverage: RecoveryCoverage

    public init(journal: JournalRef, coverage: RecoveryCoverage) {
        self.journal = journal
        self.coverage = coverage
    }
}


/// A deliberately boring, serializable account of what a core reader can prove.
///
/// This is a diagnostic projection, not a second source of truth. In particular, an
/// `assemblerReady` result says only that the current SessionAssembler accepted the supplied
/// cursors; it does not mean Catalog, Flock, notifications, search, or a service have consumed
/// the same journals.
public struct ReaderCensusReport: Codable, Hashable, Sendable {
    public static let currentProjectionRulesVersion = 2

    public let projectionRulesVersion: Int
    public let sessionCursor: JournalCursor?
    public let workCursor: JournalCursor?
    public let sessionCommittedEventIDs: [String]
    public let workCommittedEventIDs: [String]
    public let sessionIntegrityValid: Bool
    public let workIntegrityValid: Bool
    public let sessionStructuralIntegrityValid: Bool
    public let workStructuralIntegrityValid: Bool
    public let sessionSemanticProjectionValid: Bool
    public let workSemanticProjectionValid: Bool
    public let sessionTailBytes: Int
    public let workTailBytes: Int
    public let visibleMessageIDs: [String]
    public let contextInclusionIDs: [String]
    public let omittedContextIDs: [String]
    public let contextComponents: [ReaderCensusContextComponent]
    /// Latest complete production crossing metadata. Nil is allowed for older fixtures that
    /// predate the provider-bound manifest fields while still carrying components.
    public let contextManifest: ContextManifest?
    public let contextBoundaryEventID: String?
    public let compactionBoundaryEventID: String?
    public let compactionSummary: String?
    public let recovery: [ReaderCensusRecovery]
    public let authoredAttention: SessionAttention
    public let attention: SessionAttention
    public let outstandingActionIDs: [String]
    public let indeterminateActionIDs: [String]
    public let outstandingHandleIDs: [String]
    /// Recorded Work-owned agents, never process-liveness evidence. Empty is not a claim of
    /// quiescence when Work integrity or the work/runtime/external-effects domains are unknown.
    public let agentHandles: [LocalTimelineCatalog.AgentHandleFact]
    public let completionBlockingAgentHandleIDs: [String]
    public let outstandingCommandIDs: [String]
    public let childStates: [String: String]
    public let modelIDs: [String]
    public let runIDs: [String]
    public let activeTip: EventRef?
    public let attachments: [ReaderCensusAttachment]
    /// Canonical source-qualified identity for events this reducer did not project.
    public let unknownEventRefs: [EventRef]
    public let unknownDomains: [TimelineDomain]
    public let unknownReferenceIDs: [String]
    public let unknownReferences: [EventRef]
    public let assemblerReady: Bool
    /// Canonical SessionCatalog-shaped projection.
    public let canonicalSessionCatalog: CanonicalSessionCatalogSummary?
    /// Canonical Flock child projection. It is nil when no Work page was supplied; a supplied
    /// stale, foreign, divergent, tailed, or corrupt page remains an unavailable projection and
    /// cannot contribute lifecycle rows.
    public let canonicalFlock: CanonicalFlockProjection?
    /// Flock's production-facing catalog projection, retained so Census fixtures exercise the
    /// same unknown-domain and authority rules as the UI.
    public let canonicalFlockCatalog: [CanonicalFlockCatalogProjection]
    /// Bounded client-neutral attention rows. This does not claim that the observing client has
    /// control capability.
    public let canonicalAttentionInbox: CanonicalAttentionInboxProjection
    /// The native delivery consumer's bounded projection. Retaining it in the Codable report
    /// makes notification behavior part of the fixture receipt rather than a test-only computed
    /// convenience that disappears when the census is serialized.
    public let canonicalNotifications: CanonicalNotificationProjection
    /// Canonical Work recovery rows built from the same reduced native Work/Session prefixes as
    /// the other Census consumers. This is deliberately retained in the report so current Run,
    /// attachment, recovery, unknown-domain, and omission evidence cannot drift between tests
    /// and the production projection boundary.
    public let canonicalWorkRecovery: CanonicalWorkRecoveryProjection
    public let registeredConsumers: [String]
    public let intentionallyUnwiredConsumers: [String]

    /// Rebuild the production lexical search projection from the retained canonical catalog row.
    /// The ephemeral document itself is intentionally excluded from the Codable report surface.
    public var canonicalSessionSearch: CanonicalSessionSearchIndex {
        CanonicalSessionSearchIndex(entries: canonicalSessionCatalog.map {
            [SessionCatalogProjection.canonical($0)]
        } ?? [])
    }

    /// Bounded metadata-only view of the latest provider-bound context the journal accepted.
    /// This does not claim that an unchanged context will be sent on the next request: later
    /// messages, compaction, attachments, or runtime decisions may alter that future crossing.
    public var recordedModelContext: RecordedModelContextProjection {
        RecordedModelContextProjection(
            manifest: contextManifest,
            contextBoundaryEventID: contextBoundaryEventID,
            unknowns: RecordedModelContextUnknowns(
                eventCount: unknownEventRefs.count, domains: unknownDomains,
                referenceCount: unknownReferenceIDs.count),
            projectionValid: sessionStructuralIntegrityValid
                && sessionSemanticProjectionValid)
    }

    /// Naming useful to callers that treat this as a general report projection.
    public var contextProjection: RecordedModelContextProjection { recordedModelContext }

    public init(
        projectionRulesVersion: Int = ReaderCensusReport.currentProjectionRulesVersion,
        sessionCursor: JournalCursor?, workCursor: JournalCursor?,
        sessionCommittedEventIDs: [String], workCommittedEventIDs: [String],
        sessionIntegrityValid: Bool, workIntegrityValid: Bool,
        sessionStructuralIntegrityValid: Bool, workStructuralIntegrityValid: Bool,
        sessionSemanticProjectionValid: Bool, workSemanticProjectionValid: Bool,
        sessionTailBytes: Int, workTailBytes: Int,
        visibleMessageIDs: [String], contextInclusionIDs: [String], omittedContextIDs: [String],
        contextComponents: [ReaderCensusContextComponent],
        contextManifest: ContextManifest? = nil,
        contextBoundaryEventID: String? = nil, compactionBoundaryEventID: String? = nil,
        compactionSummary: String?,
        recovery: [ReaderCensusRecovery], authoredAttention: SessionAttention,
        attention: SessionAttention,
        outstandingActionIDs: [String], indeterminateActionIDs: [String],
        outstandingHandleIDs: [String],
        agentHandles: [LocalTimelineCatalog.AgentHandleFact],
        completionBlockingAgentHandleIDs: [String],
        outstandingCommandIDs: [String], childStates: [String: String],
        modelIDs: [String], runIDs: [String],
        activeTip: EventRef?, attachments: [ReaderCensusAttachment],
        unknownEventRefs: [EventRef], unknownDomains: [TimelineDomain], unknownReferenceIDs: [String],
        unknownReferences: [EventRef],
        assemblerReady: Bool, canonicalSessionCatalog: CanonicalSessionCatalogSummary? = nil,
        canonicalFlock: CanonicalFlockProjection? = nil,
        canonicalFlockCatalog: [CanonicalFlockCatalogProjection] = [],
        canonicalAttentionInbox: CanonicalAttentionInboxProjection = .init(summaries: []),
        canonicalNotifications: CanonicalNotificationProjection = .init(summaries: []),
        canonicalWorkRecovery: CanonicalWorkRecoveryProjection = .init(works: []),
        registeredConsumers: [String] = [],
        intentionallyUnwiredConsumers: [String]
    ) {
        self.projectionRulesVersion = projectionRulesVersion
        self.sessionCursor = sessionCursor
        self.workCursor = workCursor
        self.sessionCommittedEventIDs = sessionCommittedEventIDs
        self.workCommittedEventIDs = workCommittedEventIDs
        self.sessionIntegrityValid = sessionIntegrityValid
        self.workIntegrityValid = workIntegrityValid
        self.sessionStructuralIntegrityValid = sessionStructuralIntegrityValid
        self.workStructuralIntegrityValid = workStructuralIntegrityValid
        self.sessionSemanticProjectionValid = sessionSemanticProjectionValid
        self.workSemanticProjectionValid = workSemanticProjectionValid
        self.sessionTailBytes = sessionTailBytes
        self.workTailBytes = workTailBytes
        self.visibleMessageIDs = visibleMessageIDs
        self.contextInclusionIDs = contextInclusionIDs
        self.omittedContextIDs = omittedContextIDs
        self.contextComponents = contextComponents
        self.contextManifest = contextManifest
        self.contextBoundaryEventID = contextBoundaryEventID
        self.compactionBoundaryEventID = compactionBoundaryEventID
        self.compactionSummary = compactionSummary
        self.recovery = recovery
        self.authoredAttention = authoredAttention
        self.attention = attention
        self.outstandingActionIDs = outstandingActionIDs
        self.indeterminateActionIDs = indeterminateActionIDs
        self.outstandingHandleIDs = outstandingHandleIDs
        self.agentHandles = agentHandles
        self.completionBlockingAgentHandleIDs = completionBlockingAgentHandleIDs
        self.outstandingCommandIDs = outstandingCommandIDs
        self.childStates = childStates
        self.modelIDs = modelIDs
        self.runIDs = runIDs
        self.activeTip = activeTip
        self.attachments = attachments
        self.unknownEventRefs = unknownEventRefs
        self.unknownDomains = unknownDomains
        self.unknownReferenceIDs = unknownReferenceIDs
        self.unknownReferences = unknownReferences
        self.assemblerReady = assemblerReady
        self.canonicalSessionCatalog = canonicalSessionCatalog
        self.canonicalFlock = canonicalFlock
        self.canonicalFlockCatalog = canonicalFlockCatalog
        self.canonicalAttentionInbox = canonicalAttentionInbox
        self.canonicalNotifications = canonicalNotifications
        self.canonicalWorkRecovery = canonicalWorkRecovery
        self.registeredConsumers = registeredConsumers
        self.intentionallyUnwiredConsumers = intentionallyUnwiredConsumers
    }
}

/// Core-only census operations. Callers supply journal identities because paths and host
/// locations are not part of the protocol and must not leak into a report.
public enum ReaderCensus {
    private static let defaultIntentionallyUnwiredConsumers = [
        "service recovery",
    ]
    private static let defaultRegisteredConsumers = [
        "production local Timeline catalog", "canonical SessionCatalog projection",
        "canonical Flock adapter", "canonical Flock catalog projection", "canonical attention adapter",
        "canonical Session search", "canonical notification projection",
        "canonical Work recovery projection",
    ]
    public static func read(
        _ data: Data,
        journal: JournalRef,
        actor: TimelineActor = TimelineActor(actorID: "reader-census", kind: "self-test"),
        at date: Date = Date(timeIntervalSince1970: 0)
    ) -> TimelineJournalReadResult {
        TimelineJournalReader.read(data, journal: journal, actor: actor, hostRecordedAt: date)
    }

    /// Read the same bytes through the real incremental reader. `chunkSizes` may be any positive
    /// sequence; the last append is marked final so an unterminated tail remains visible.
    public static func readIncrementally(
        _ data: Data,
        journal: JournalRef,
        chunkSizes: [Int],
        actor: TimelineActor = TimelineActor(actorID: "reader-census", kind: "self-test"),
        at date: Date = Date(timeIntervalSince1970: 0)
    ) -> TimelineJournalReadResult {
        guard !data.isEmpty else {
            var state = TimelineJournalReaderState(
                journal: journal, actor: actor, hostRecordedAt: date)
            return state.append(Data(), final: true)
        }
        var state = TimelineJournalReaderState(
            journal: journal, actor: actor, hostRecordedAt: date)
        var offset = 0
        var committed: [TimelineJournalRecord] = []
        var tail: TimelineJournalTail?
        var truncated: TimelineJournalTail?
        var sizes = chunkSizes.filter { $0 > 0 }
        if sizes.isEmpty { sizes = [data.count] }
        var index = 0
        while offset < data.count {
            let size = sizes[index % sizes.count]
            let end = min(data.count, offset + size)
            let result = state.append(data.subdata(in: offset..<end), final: end == data.count)
            committed.append(contentsOf: result.records)
            tail = result.quarantinedSuffix
            truncated = result.truncatedTail
            offset = end
            index += 1
        }
        return TimelineJournalReadResult(
            records: committed, quarantinedSuffix: tail, truncatedTail: truncated)
    }

    /// Produce one report from the Session and Work byte streams. The reducer and assembler are
    /// the same code used by live and cold paths; no UI projection is consulted here.
    public static func report(
        sessionData: Data,
        sessionJournal: JournalRef,
        workData: Data,
        workJournal: JournalRef,
        controlData: Data? = nil,
        controlJournal: JournalRef? = nil,
        manifest: ReaderCensusManifest? = nil,
        actor: TimelineActor = TimelineActor(actorID: "reader-census", kind: "self-test"),
        at date: Date = Date(timeIntervalSince1970: 0)
    ) -> ReaderCensusReport {
        let sessionRead = read(sessionData, journal: sessionJournal, actor: actor, at: date)
        let workRead = read(workData, journal: workJournal, actor: actor, at: date)
        let controlRead: TimelineJournalReadResult?
        if let controlData, let controlJournal {
            controlRead = read(controlData, journal: controlJournal, actor: actor, at: date)
        } else {
            controlRead = nil
        }
        return report(
            sessionRead: sessionRead, workRead: workRead,
            sessionJournal: sessionJournal, workJournal: workJournal,
            controlRead: controlRead, controlJournal: controlJournal,
            registeredConsumers: manifest?.registeredConsumers ?? defaultRegisteredConsumers,
            intentionallyUnwiredConsumers: manifest?.intentionallyUnwiredConsumers
                ?? defaultIntentionallyUnwiredConsumers)
    }

    public static func report(
        sessionRead: TimelineJournalReadResult,
        workRead: TimelineJournalReadResult,
        sessionJournal: JournalRef,
        workJournal: JournalRef,
        controlRead: TimelineJournalReadResult? = nil,
        controlJournal: JournalRef? = nil,
        registeredConsumers: [String] = [
            "production local Timeline catalog", "canonical SessionCatalog projection",
            "canonical Flock adapter", "canonical Flock catalog projection", "canonical attention adapter",
            "canonical Session search", "canonical notification projection",
            "canonical Work recovery projection",
        ],
        intentionallyUnwiredConsumers: [String] = []
    ) -> ReaderCensusReport {
        let sessionEvents = sessionRead.records.map(\.event)
        let workEvents = workRead.records.map(\.event)
        let session = SessionReducer.reduce(sessionEvents)
        let work = WorkReducer.reduce(workEvents)
        let control: WorkHostControlSnapshot?
        if let controlRead, let controlJournal {
            control = WorkHostControlReducer.reduce(
                controlRead.records.map(\.event),
                initial: WorkHostControlSnapshot(journal: controlJournal))
        } else {
            control = nil
        }
        let workCursor = workRead.records.last.map {
            JournalCursor(journal: workJournal, eventID: $0.event.eventID, sequence: $0.event.sequence)
        }
        let sessionCursor = sessionRead.records.last.map {
            JournalCursor(journal: sessionJournal, eventID: $0.event.eventID, sequence: $0.event.sequence)
        }
        // Assembly is meaningful even before a Session has attached any Work.  For an active
        // attachment, use its durable cursor when available, falling back to the current Work
        // page only for legacy/no-cursor attachments.  Never substitute that page for a missing
        // Work journal: a delayed remote page must remain not-ready instead of looking aligned.
        let assemblyCursors = Dictionary(uniqueKeysWithValues: session.attachments.values
            .filter(\.isAttached)
            .compactMap { attachment -> (String, JournalCursor)? in
                guard let cursor = attachment.cursor ?? workCursor else { return nil }
                return (attachment.attachment.attachmentID, cursor)
            })
        let assemblerReady = SessionAssembler.assemble(
            session: session,
            works: workCursor == nil ? [] : [work],
            at: assemblyCursors) != nil

        let sessionTail = (sessionRead.truncatedTail?.rawBytes.count ?? 0)
            + (sessionRead.quarantinedSuffix?.rawBytes.count ?? 0)
        let workTail = (workRead.truncatedTail?.rawBytes.count ?? 0)
            + (workRead.quarantinedSuffix?.rawBytes.count ?? 0)
        let sessionIntegrity = sessionRead.truncatedTail == nil
            && sessionRead.quarantinedSuffix == nil
            && session.structuralIntegrityValid
            && session.semanticProjectionValid
        let workIntegrity = workRead.truncatedTail == nil
            && workRead.quarantinedSuffix == nil
            && work.structuralIntegrityValid
            && work.semanticProjectionValid
        let controlIntegrity: Bool?
        if let controlRead, let control {
            controlIntegrity = controlRead.truncatedTail == nil
                && controlRead.quarantinedSuffix == nil
                && control.structuralIntegrityValid
                && control.semanticProjectionValid
                && control.unknownEvents.isEmpty
        } else {
            controlIntegrity = nil
        }

        let contextInclusions = session.contextComponents
            .filter { !$0.omitted && $0.mode != .omitted }
            .map(\.inclusionID)
        let omittedContext = session.contextComponents
            .filter { $0.omitted || $0.mode == .omitted }
            .map(\.inclusionID)
        let contextComponents = session.contextComponents.map(ReaderCensusContextComponent.init)
        let outstandingHandles = work.handles.values
            .filter { !["succeeded", "failed", "canceled", "completed"].contains($0.state) }
            .map { $0.handle.handleID }
        let agentFactsKnown = workIntegrity
            && work.unknownDomains.isDisjoint(with: [.work, .runtime, .externalEffects])
        let agentHandles = agentFactsKnown
            ? work.agentHandles.values.map(LocalTimelineCatalog.AgentHandleFact.init)
                .sorted(by: LocalTimelineCatalog.agentHandleLess) : []
        let outstandingCommands = work.commands.values
            .filter { $0.state == .accepted }
            .map { $0.command.commandID }
        let indeterminateActions = work.actions.values
            .filter { $0.state == .indeterminateEffect }
            .map { $0.action.actionID }
        var childStates = session.childStates
        childStates.merge(work.childStates) { _, workState in workState }
        let effectiveAttention = SessionAssembler.assemble(
            session: session,
            works: workCursor == nil ? [] : [work],
            at: assemblyCursors)?.effectiveAttention ?? session.attention
        var workReads: [JournalRef: TimelineJournalReadResult] = [:]
        if let workJournal = work.journal { workReads[workJournal] = workRead }
        let canonicalSessionCatalog = SessionCatalog.summarizeCanonical(
            session: session, works: workCursor == nil ? [] : [work], cursors: assemblyCursors,
            sessionRead: sessionRead, workReads: workReads)
        let canonicalFlock = workRead.records.isEmpty
            ? nil
            : AgentTreeReader.canonicalProjection(work: work, read: workRead)
        let canonicalFlockCatalog = canonicalFlock.map {
            CanonicalFlockCatalogProjection.project(
                sessions: canonicalSessionCatalog.map { [$0] } ?? [], flock: $0,
                unknownDomains: work.unknownDomains.sorted { $0.rawValue < $1.rawValue })
        }.map { [$0] } ?? []
        let canonicalAttentionInbox = CanonicalAttentionInboxProjection(
            summaries: canonicalSessionCatalog.map { [$0] } ?? [])
        let canonicalNotifications = CanonicalNotificationProjection(
            summaries: canonicalSessionCatalog.map { [$0] } ?? [])
        // Reader Census has no filesystem discovery layer, so its explicit source-completeness
        // boundary is the pair of supplied native reads. Unknown domains remain row evidence and
        // do not make discovery incomplete; tails, quarantine, or reducer integrity failures do.
        let canonicalWorkRecovery: CanonicalWorkRecoveryProjection
        if workRead.records.isEmpty {
            // An absent Work page is an incomplete source, not an identity-less Work row. Keep
            // the Session-side report useful while withholding every recovery disposition.
            canonicalWorkRecovery = CanonicalWorkRecoveryProjection(
                works: [], sessions: canonicalSessionCatalog.map { [$0] } ?? [],
                controls: [], sourceComplete: false)
        } else {
            let canonicalControlRow: LocalTimelineCatalog.WorkHostControlRow?
            if let controlRead, let controlJournal, let control {
                let controlHost: WorkHostRef?
                if case .workHost(let host) = controlJournal.owner {
                    controlHost = host
                } else {
                    controlHost = nil
                }
                canonicalControlRow = LocalTimelineCatalog.WorkHostControlRow(
                    locatorID: "reader-census-control", workHost: controlHost,
                    journal: controlJournal, snapshot: control, read: controlRead,
                    available: controlIntegrity == true, reasons: controlIntegrity == true
                        ? [] : ["Reader Census Work Host control source is incomplete"],
                    limits: LocalTimelineCatalog.Limits())
            } else {
                canonicalControlRow = nil
            }
            let canonicalWorkRow = LocalTimelineCatalog.WorkRow(
                locatorID: "reader-census-work",
                work: work.work,
                journal: work.journal,
                snapshot: work,
                read: workRead,
                available: workIntegrity,
                reasons: workIntegrity ? [] : ["Reader Census Work source is incomplete"],
                limit: 16,
                controlClientAttachments: canonicalControlRow?.clientAttachments ?? [])
            canonicalWorkRecovery = CanonicalWorkRecoveryProjection(
                works: [canonicalWorkRow],
                sessions: canonicalSessionCatalog.map { [$0] } ?? [],
                controls: canonicalControlRow.map { [$0] } ?? [],
                sourceComplete: sessionIntegrity && workIntegrity && controlIntegrity == true)
        }

        let controlEvents = controlRead?.records.map(\.event) ?? []
        let allEvents = sessionEvents + workEvents + controlEvents
        let allEventRefs = Set(allEvents.map { EventRef(journal: $0.journal, eventID: $0.eventID) })
        let unknownEventRefs = (session.unknownEvents.map {
            EventRef(journal: sessionJournal, eventID: $0.event.eventID)
        } + work.unknownEvents.map {
            EventRef(journal: workJournal, eventID: $0.event.eventID)
        } + (control?.unknownEvents.map {
            EventRef(journal: controlJournal ?? $0.event.journal, eventID: $0.event.eventID)
        } ?? [])).sorted {
            if $0.journal.stableKey != $1.journal.stableKey {
                return $0.journal.stableKey < $1.journal.stableKey
            }
            return $0.eventID < $1.eventID
        }
        let controlUnknownDomains = Set(control?.unknownEvents.flatMap { $0.affectedDomains } ?? [])
        let unknownDomains = Set(session.unknownDomains)
            .union(work.unknownDomains)
            .union(controlUnknownDomains)
        let references = allEvents.flatMap { event -> [EventRef] in
            let primary = [event.causedByEventID, event.parentActivityID, event.conversationParent]
                .compactMap { $0 }
            let linked = event.links.compactMap { link -> EventRef? in
                switch link.target {
                case .event(let ref), .claim(let ref): return ref
                case .artifact: return nil
                }
            }
            return primary + linked
        }
        let unknownReferenceRefs = references.filter { !allEventRefs.contains($0) }
        let unknownReferenceIDs = Set(unknownReferenceRefs.map(\.eventID))
        let modelIDs = Set([session.modelID, work.modelID].compactMap { $0 })
        let runIDs = Set([session.activeRun?.runID, work.activeRun?.runID].compactMap { $0 })

        var attachments: [ReaderCensusAttachment] = []
        attachments += session.attachments.values.map {
            ReaderCensusAttachment(
                journal: sessionJournal, id: $0.attachment.attachmentID, kind: .session,
                sessionAttachment: $0.attachment, work: $0.work,
                capabilities: $0.capabilities.sorted(), isAttached: $0.isAttached)
        }
        if let control, let controlJournal, controlIntegrity == true {
            attachments += control.clientAttachments.values.filter {
                $0.work == work.work && $0.workJournal == workJournal
            }.map {
                ReaderCensusAttachment(
                    journal: controlJournal, id: $0.attachment.attachmentID, kind: .client,
                    clientAttachment: $0.attachment, work: $0.work, client: $0.client,
                    capabilities: $0.capabilities.sorted(),
                    isAttached: $0.isAttached)
            }
        }
        attachments.sort {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.journal.stableKey != $1.journal.stableKey {
                return $0.journal.stableKey < $1.journal.stableKey
            }
            return $0.target < $1.target
        }

        return ReaderCensusReport(
            sessionCursor: sessionCursor, workCursor: workCursor,
            sessionCommittedEventIDs: sessionRead.records.map { $0.event.eventID },
            workCommittedEventIDs: workRead.records.map { $0.event.eventID },
            sessionIntegrityValid: sessionIntegrity, workIntegrityValid: workIntegrity,
            sessionStructuralIntegrityValid: session.structuralIntegrityValid,
            workStructuralIntegrityValid: work.structuralIntegrityValid,
            sessionSemanticProjectionValid: session.semanticProjectionValid,
            workSemanticProjectionValid: work.semanticProjectionValid,
            sessionTailBytes: sessionTail, workTailBytes: workTail,
            visibleMessageIDs: session.messages.map(\.eventID),
            contextInclusionIDs: contextInclusions,
            omittedContextIDs: omittedContext,
            contextComponents: contextComponents,
            contextManifest: session.contextManifest,
            contextBoundaryEventID: session.contextBoundaryEventID,
            compactionBoundaryEventID: session.compactionBoundaryEventID,
            compactionSummary: session.compactionSummary,
            recovery: session.recovery.map {
                ReaderCensusRecovery(journal: sessionJournal, coverage: $0)
            } + work.recovery.map {
                ReaderCensusRecovery(journal: workJournal, coverage: $0)
            },
            authoredAttention: session.attention,
            attention: effectiveAttention,
            outstandingActionIDs: work.activeActionIDs.sorted(),
            indeterminateActionIDs: indeterminateActions.sorted(),
            outstandingHandleIDs: outstandingHandles.sorted(),
            agentHandles: agentHandles,
            completionBlockingAgentHandleIDs: agentHandles.filter(\.blocksWorkCompletion).map(\.handleID),
            outstandingCommandIDs: outstandingCommands.sorted(),
            childStates: childStates,
            modelIDs: modelIDs.sorted(), runIDs: runIDs.sorted(),
            activeTip: session.semanticTip,
            attachments: attachments,
            unknownEventRefs: unknownEventRefs,
            unknownDomains: unknownDomains.sorted { $0.rawValue < $1.rawValue },
            unknownReferenceIDs: unknownReferenceIDs.sorted(),
            unknownReferences: unknownReferenceRefs
                .sorted {
                    if $0.journal.stableKey != $1.journal.stableKey {
                        return $0.journal.stableKey < $1.journal.stableKey
                    }
                    return $0.eventID < $1.eventID
            },
            assemblerReady: assemblerReady,
            canonicalSessionCatalog: canonicalSessionCatalog,
            canonicalFlock: canonicalFlock,
            canonicalFlockCatalog: canonicalFlockCatalog,
            canonicalAttentionInbox: canonicalAttentionInbox,
            canonicalNotifications: canonicalNotifications,
            canonicalWorkRecovery: canonicalWorkRecovery,
            registeredConsumers: registeredConsumers,
            intentionallyUnwiredConsumers: intentionallyUnwiredConsumers)
    }
}
