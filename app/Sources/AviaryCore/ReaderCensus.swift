import CryptoKit
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
    public let legacyJournal: String
    public let retainedBodies: [String]
    public let malformedVariants: [String]
    public let registeredConsumers: [String]
    public let intentionallyUnwiredConsumers: [String]

    public init(
        schemaVersion: Int = 1,
        projectionRulesVersion: Int = 1,
        fixtureID: String,
        sessionJournal: String,
        workJournal: String,
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

/// Whether a context projection has a provider-bound manifest, only a legacy component
/// projection, or no context evidence at all. `unknown` is intentionally different from an
/// empty context: an older reader cannot prove that no context was sent.
public enum ReaderCensusContextProjectionState: String, Codable, Hashable, Sendable {
    case observed
    case legacy
    case unknown
}

/// The addressability of a retained body. An address is a content-addressed reference, not a
/// claim that the body is present on this device; this projection never contains a filesystem
/// path or any body bytes.
public enum ReaderCensusBodyAddressStatus: String, Codable, Hashable, Sendable {
    case addressed
    case notAddressed = "not_addressed"
}

/// The bounded metadata view of one context component. It deliberately does not carry the
/// component's body reference: the UI only needs to know whether an address was recorded.
public struct ReaderCensusContextComponentProjection: Codable, Hashable, Sendable {
    public let componentID: String
    public let inclusionID: String
    public let sourceID: String
    public let mode: ContextComponentMode
    public let deliveryMode: ContextDeliveryMode
    public let measuredBytes: Int?
    public let includedBytes: Int?
    public let deliveredBytes: Int?
    public let fullByteCount: Int?
    public let digest: String?
    public let bodyAddressStatus: ReaderCensusBodyAddressStatus
    public let omitted: Bool

    public var deliveryStatus: ContextDeliveryMode { deliveryMode }
    public var bodyAddressAvailable: Bool { bodyAddressStatus == .addressed }
    public var measuredSize: Int? { measuredBytes }
    public var deliveredSize: Int? { deliveredBytes }

    public init(_ component: ContextComponent) {
        componentID = component.componentID
        inclusionID = component.inclusionID
        sourceID = component.sourceID
        mode = component.mode
        deliveryMode = component.deliveryMode
        measuredBytes = component.measuredBytes
        includedBytes = component.includedBytes
        deliveredBytes = component.deliveredBytes
        fullByteCount = component.fullByteCount
        digest = component.digest
        bodyAddressStatus = component.bodyReference == nil ? .notAddressed : .addressed
        omitted = component.omitted
    }

    public init(_ component: ReaderCensusContextComponent) {
        self.init(ContextComponent(
            componentID: component.componentID, inclusionID: component.inclusionID,
            sourceID: component.sourceID, mode: component.mode,
            deliveryMode: component.deliveryMode, measuredBytes: component.measuredBytes,
            includedBytes: component.includedBytes, deliveredBytes: component.deliveredBytes,
            fullByteCount: component.fullByteCount, bodyReference: component.bodyReference,
            digest: component.digest, omitted: component.omitted))
    }
}

/// The bounded metadata view of one producer-side system-prompt source. Source identities are
/// intentionally excluded because they may be paths. Display labels are derived from the typed
/// kind instead of accepting producer-controlled text, which can itself contain paths or
/// credentials. Digests, sizes, typed provenance, and addressability are sufficient for a future
/// UI to explain what was measured without displaying source material.
public struct ReaderCensusPromptSourceProjection: Codable, Hashable, Sendable {
    public let sourceID: String
    public let inclusionID: String
    public let kind: PromptSourceKind
    public let status: PromptSourceStatus
    /// Non-sensitive display text derived from the source kind at this boundary.
    public let label: String
    public let fullByteCount: Int?
    public let deliveredByteCount: Int
    public let renderedByteCount: Int
    public let fullDigest: String?
    public let deliveredDigest: String
    public let renderedDigest: String
    public let fullBodyAddressStatus: ReaderCensusBodyAddressStatus
    public let deliveredBodyAddressStatus: ReaderCensusBodyAddressStatus
    public let renderedBodyAddressStatus: ReaderCensusBodyAddressStatus
    public let provenance: EventRef?

    public var fullSize: Int? { fullByteCount }
    public var deliveredSize: Int { deliveredByteCount }
    public var renderedSize: Int { renderedByteCount }
    public var fullBodyAddressAvailable: Bool {
        fullBodyAddressStatus == .addressed
    }
    public var deliveredBodyAddressAvailable: Bool {
        deliveredBodyAddressStatus == .addressed
    }
    public var renderedBodyAddressAvailable: Bool {
        renderedBodyAddressStatus == .addressed
    }
    public var bodyAddressAvailable: Bool {
        fullBodyAddressAvailable || deliveredBodyAddressAvailable || renderedBodyAddressAvailable
    }
    public var bodyAddressStatus: ReaderCensusBodyAddressStatus {
        bodyAddressAvailable ? .addressed : .notAddressed
    }

    public init(_ source: ContextManifestSource) {
        sourceID = Self.opaqueID(source.sourceID, namespace: "source")
        inclusionID = Self.opaqueID(source.inclusionID, namespace: "inclusion")
        kind = source.kind
        status = source.status
        label = Self.safeLabel(for: source.kind)
        fullByteCount = source.fullByteCount
        deliveredByteCount = source.deliveredByteCount
        renderedByteCount = source.renderedByteCount
        fullDigest = source.fullDigest
        deliveredDigest = source.deliveredDigest
        renderedDigest = source.renderedDigest
        fullBodyAddressStatus = source.fullBodyReference == nil ? .notAddressed : .addressed
        deliveredBodyAddressStatus = source.deliveredBodyReference == nil
            ? .notAddressed : .addressed
        renderedBodyAddressStatus = source.renderedBodyReference == nil
            ? .notAddressed : .addressed
        provenance = source.provenance
    }

    private static func safeLabel(for kind: PromptSourceKind) -> String {
        switch kind {
        case .baseInstruction: "Base instructions"
        case .workingDirectory: "Working directory"
        case .contextFile: "Context file"
        case .skill: "Skills"
        case .memory: "Memory"
        case .generated: "Generated context"
        }
    }

    private static func opaqueID(_ value: String, namespace: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(namespace)-sha256:\(digest)"
    }
}

/// A bounded, source-qualified account of what is unknown in the context plane. Counts retain
/// the distinction between "there were no unknowns" and "the bounded list omitted some".
public struct ReaderCensusContextUnknowns: Codable, Hashable, Sendable {
    public let eventRefs: [EventRef]
    public let eventRefOmittedCount: Int
    public let domains: [TimelineDomain]
    public let referenceIDs: [String]
    public let referenceIDOmittedCount: Int

    public init(
        eventRefs: [EventRef], eventRefOmittedCount: Int,
        domains: [TimelineDomain], referenceIDs: [String], referenceIDOmittedCount: Int
    ) {
        self.eventRefs = eventRefs
        self.eventRefOmittedCount = eventRefOmittedCount
        self.domains = domains
        self.referenceIDs = referenceIDs
        self.referenceIDOmittedCount = referenceIDOmittedCount
    }
}

/// Metadata-only projection of the latest recorded provider-bound model context.
///
/// This is a reader projection, not a runtime working-state claim. A manifest-backed state is
/// the only state that can identify a provider-bound crossing; legacy state preserves its known
/// components but leaves manifest and source identity unknown. Arrays preserve canonical
/// producer order where order is semantic and are bounded with explicit omitted counts, so a
/// future UI cannot mistake a prefix for complete context.
public struct ReaderCensusContextProjection: Codable, Hashable, Sendable {
    public static let maxComponents = 64
    public static let maxPromptSources = 32
    public static let maxOmissions = 64
    public static let maxUnknowns = 32

    public let state: ReaderCensusContextProjectionState
    public let manifestID: String?
    public let requestID: String?
    public let modelID: String?
    public let assemblyID: String?
    public let components: [ReaderCensusContextComponentProjection]
    public let componentCount: Int
    public let omittedComponentCount: Int
    public let omissions: [ContextManifestOmission]
    public let omissionCount: Int
    public let omittedOmissionCount: Int
    /// Nil means no source list was observed. It does not mean that zero sources were sent.
    public let promptSources: [ReaderCensusPromptSourceProjection]?
    public let promptSourceCount: Int?
    public let omittedPromptSourceCount: Int
    public let contextBoundaryEventID: String?
    public let compactionBoundaryEventID: String?
    /// Raw compaction text is conversation content, not metadata. It may contain paths,
    /// credentials, or identifiers and therefore stays behind explicit journal inspection.
    public let compactionSummaryByteCount: Int?
    public let compactionSummaryDigest: String?
    public let compactionSummaryInspectionRequired: Bool
    public let unknowns: ReaderCensusContextUnknowns

    public var sourceProjectionKnown: Bool { promptSources != nil }
    public var hasOmittedRecords: Bool {
        omittedComponentCount > 0 || omittedOmissionCount > 0 || omittedPromptSourceCount > 0
            || unknowns.eventRefOmittedCount > 0 || unknowns.referenceIDOmittedCount > 0
    }

    init(
        manifest: ContextManifest?, legacyComponents: [ReaderCensusContextComponent],
        contextBoundaryEventID: String?, compactionBoundaryEventID: String?,
        compactionSummary: String?, unknownEventRefs: [EventRef], unknownDomains: [TimelineDomain],
        unknownReferenceIDs: [String]
    ) {
        // Reducer order is the producer's canonical request order. It is meaningful for
        // components (and remains deterministic for a given journal prefix), so do not sort it
        // lexicographically: `include-10` must not move ahead of `include-2`.
        let manifestComponents = manifest?.components
        let componentCount = manifestComponents?.count ?? legacyComponents.count
        self.componentCount = componentCount
        if let manifestComponents {
            components = Array(manifestComponents.prefix(Self.maxComponents)).map {
                ReaderCensusContextComponentProjection($0)
            }
        } else {
            components = legacyComponents.prefix(Self.maxComponents).map {
                ReaderCensusContextComponentProjection($0)
            }
        }
        omittedComponentCount = max(0, componentCount - components.count)

        let allOmissions = manifest?.omissions ?? []
        omissionCount = allOmissions.count
        omissions = Array(allOmissions.prefix(Self.maxOmissions))
        omittedOmissionCount = max(0, allOmissions.count - omissions.count)

        // A standalone source observation can be immediately followed by a failed or
        // quarantined crossing. It is evidence about a producer observation, not evidence that
        // those sources reached a model request. The recorded-crossing projection therefore
        // takes source identity only from the provider-bound manifest.
        let sourceRecords = manifest?.systemPromptSources
        if let sourceRecords {
            promptSources = Array(sourceRecords.prefix(Self.maxPromptSources)).map {
                ReaderCensusPromptSourceProjection($0)
            }
            promptSourceCount = sourceRecords.count
            omittedPromptSourceCount = max(0, sourceRecords.count - (promptSources?.count ?? 0))
        } else {
            promptSources = nil
            promptSourceCount = nil
            omittedPromptSourceCount = 0
        }

        if manifest != nil {
            state = .observed
        } else if !legacyComponents.isEmpty {
            state = .legacy
        } else {
            state = .unknown
        }
        manifestID = manifest?.manifestID
        requestID = manifest?.requestID
        modelID = manifest?.modelID
        assemblyID = manifest?.systemPromptAssemblyID
        self.contextBoundaryEventID = contextBoundaryEventID
        self.compactionBoundaryEventID = compactionBoundaryEventID

        if let compactionSummary {
            let bytes = Data(compactionSummary.utf8)
            compactionSummaryByteCount = bytes.count
            compactionSummaryDigest = "sha256:" + SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined()
            compactionSummaryInspectionRequired = true
        } else {
            compactionSummaryByteCount = nil
            compactionSummaryDigest = nil
            compactionSummaryInspectionRequired = false
        }

        let sortedEvents = unknownEventRefs.sorted {
            if $0.journal.stableKey != $1.journal.stableKey {
                return $0.journal.stableKey < $1.journal.stableKey
            }
            return $0.eventID < $1.eventID
        }
        let boundedEvents = Array(sortedEvents.prefix(Self.maxUnknowns))
        let sortedReferences = Array(Set(unknownReferenceIDs)).sorted()
        let boundedReferences = Array(sortedReferences.prefix(Self.maxUnknowns))
        unknowns = ReaderCensusContextUnknowns(
            eventRefs: boundedEvents, eventRefOmittedCount: max(0, sortedEvents.count - boundedEvents.count),
            domains: Array(Set(unknownDomains).sorted { $0.rawValue < $1.rawValue }),
            referenceIDs: boundedReferences,
            referenceIDOmittedCount: max(0, sortedReferences.count - boundedReferences.count))
    }
}

/// A deliberately boring, serializable account of what a core reader can prove.
///
/// This is a diagnostic projection, not a second source of truth. In particular, an
/// `assemblerReady` result says only that the current SessionAssembler accepted the supplied
/// cursors; it does not mean Catalog, Flock, notifications, search, or a service have consumed
/// the same journals.
public struct ReaderCensusReport: Codable, Hashable, Sendable {
    public static let currentProjectionRulesVersion = 1

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
    /// Canonical SessionCatalog-shaped projection. The legacy disk scanner remains separately
    /// listed in `intentionallyUnwiredConsumers` until its callers move to this value.
    public let canonicalSessionCatalog: CanonicalSessionCatalogSummary?
    /// Canonical Flock child projection. It is nil when no Work page was supplied; a supplied
    /// stale, foreign, divergent, tailed, or corrupt page remains an unavailable projection and
    /// cannot contribute lifecycle rows.
    public let canonicalFlock: CanonicalFlockProjection?
    /// Flock's production-facing catalog projection, retained so Census fixtures exercise the
    /// same unknown-domain and authority rules as the UI.
    public let canonicalFlockCatalog: [CanonicalFlockCatalogProjection]
    /// Bounded client-neutral attention rows. This is not an OS-notification projection and
    /// does not claim that the observing client has control capability.
    public let canonicalAttentionInbox: CanonicalAttentionInboxProjection
    public let registeredConsumers: [String]
    public let intentionallyUnwiredConsumers: [String]

    /// Bounded metadata-only view of the latest provider-bound context the journal accepted.
    /// This does not claim that an unchanged context will be sent on the next request: later
    /// messages, compaction, attachments, or runtime decisions may alter that future crossing.
    public var recordedModelContext: ReaderCensusContextProjection {
        ReaderCensusContextProjection(
            manifest: contextManifest, legacyComponents: contextComponents,
            contextBoundaryEventID: contextBoundaryEventID,
            compactionBoundaryEventID: compactionBoundaryEventID,
            compactionSummary: compactionSummary, unknownEventRefs: unknownEventRefs,
            unknownDomains: unknownDomains, unknownReferenceIDs: unknownReferenceIDs)
    }

    /// Compatibility alias retained for callers built before the projection's temporal basis
    /// was named precisely. Prefer `recordedModelContext` in new code.
    public var nextModelContext: ReaderCensusContextProjection { recordedModelContext }

    /// Naming useful to callers that treat this as a general report projection.
    public var contextProjection: ReaderCensusContextProjection { recordedModelContext }

    /// Compatibility projection for older consumers. Equal event IDs from different journals
    /// intentionally collapse here; use `unknownEventRefs` when provenance matters.
    public var unknownEventIDs: [String] {
        Array(Set(unknownEventRefs.map(\.eventID))).sorted()
    }

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
        outstandingCommandIDs: [String], childStates: [String: String],
        modelIDs: [String], runIDs: [String],
        activeTip: EventRef?, attachments: [ReaderCensusAttachment],
        unknownEventRefs: [EventRef], unknownDomains: [TimelineDomain], unknownReferenceIDs: [String],
        unknownReferences: [EventRef],
        assemblerReady: Bool, canonicalSessionCatalog: CanonicalSessionCatalogSummary? = nil,
        canonicalFlock: CanonicalFlockProjection? = nil,
        canonicalFlockCatalog: [CanonicalFlockCatalogProjection] = [],
        canonicalAttentionInbox: CanonicalAttentionInboxProjection = .init(summaries: []),
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
        self.registeredConsumers = registeredConsumers
        self.intentionallyUnwiredConsumers = intentionallyUnwiredConsumers
    }
}

/// Core-only census operations. Callers supply journal identities because paths and host
/// locations are not part of the protocol and must not leak into a report.
public enum ReaderCensus {
    private static let defaultIntentionallyUnwiredConsumers = [
        "notifications", "search", "service recovery",
    ]
    private static let defaultRegisteredConsumers = [
        "production local Timeline catalog", "canonical SessionCatalog projection",
        "canonical Flock adapter", "canonical Flock catalog projection", "canonical attention adapter",
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
        manifest: ReaderCensusManifest? = nil,
        actor: TimelineActor = TimelineActor(actorID: "reader-census", kind: "self-test"),
        at date: Date = Date(timeIntervalSince1970: 0)
    ) -> ReaderCensusReport {
        let sessionRead = read(sessionData, journal: sessionJournal, actor: actor, at: date)
        let workRead = read(workData, journal: workJournal, actor: actor, at: date)
        return report(
            sessionRead: sessionRead, workRead: workRead,
            sessionJournal: sessionJournal, workJournal: workJournal,
            registeredConsumers: manifest?.registeredConsumers ?? defaultRegisteredConsumers,
            intentionallyUnwiredConsumers: manifest?.intentionallyUnwiredConsumers
                ?? defaultIntentionallyUnwiredConsumers)
    }

    public static func report(
        sessionRead: TimelineJournalReadResult,
        workRead: TimelineJournalReadResult,
        sessionJournal: JournalRef,
        workJournal: JournalRef,
        registeredConsumers: [String] = [
            "production local Timeline catalog", "canonical SessionCatalog projection",
            "canonical Flock adapter", "canonical Flock catalog projection", "canonical attention adapter",
        ],
        intentionallyUnwiredConsumers: [String] = []
    ) -> ReaderCensusReport {
        let sessionEvents = sessionRead.records.map(\.event)
        let workEvents = workRead.records.map(\.event)
        let session = SessionReducer.reduce(sessionEvents)
        let work = WorkReducer.reduce(workEvents)
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

        let allEvents = sessionEvents + workEvents
        let allEventRefs = Set(allEvents.map { EventRef(journal: $0.journal, eventID: $0.eventID) })
        let unknownEventRefs = (session.unknownEvents.map {
            EventRef(journal: sessionJournal, eventID: $0.event.eventID)
        } + work.unknownEvents.map {
            EventRef(journal: workJournal, eventID: $0.event.eventID)
        }).sorted {
            if $0.journal.stableKey != $1.journal.stableKey {
                return $0.journal.stableKey < $1.journal.stableKey
            }
            return $0.eventID < $1.eventID
        }
        let unknownDomains = Set(session.unknownDomains).union(work.unknownDomains)
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
        attachments += session.clientAttachments.values.map {
            ReaderCensusAttachment(
                journal: sessionJournal, id: $0.attachment.attachmentID, kind: .client,
                clientAttachment: $0.attachment, client: $0.client,
                capabilities: $0.capabilities.sorted(), isAttached: $0.isAttached)
        }
        attachments += work.clientAttachments.values.map {
            ReaderCensusAttachment(
                journal: workJournal, id: $0.attachment.attachmentID, kind: .client,
                clientAttachment: $0.attachment, client: $0.client,
                capabilities: $0.capabilities.sorted(), isAttached: $0.isAttached)
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
            registeredConsumers: registeredConsumers,
            intentionallyUnwiredConsumers: intentionallyUnwiredConsumers)
    }
}
