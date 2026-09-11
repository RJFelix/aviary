import Foundation

/// The availability of the most recent provider-bound context evidence.
///
/// This is deliberately not a prediction.  `observed` means a canonical context manifest was
/// accepted for a model crossing; it does not promise that a later request will have the same
/// history, tools, or prompt sources.
public enum RecordedModelContextAvailability: String, Codable, Hashable, Sendable {
    case observed
    case unavailable
    case invalid
}

private func opaqueProjectionID(_ value: String, namespace: String) -> String {
    "\(namespace)-sha256:" + AviarySHA256.hash(data: Data(value.utf8)).description
}

/// A bounded metadata view of one model-context component.  Bodies remain in the separately
/// addressable body store; this value never carries prompt or message text.
public struct RecordedModelContextComponent: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let inclusionID: String
    public let sourceID: String
    public let sourceProvenance: EventRef?
    public let mode: ContextComponentMode
    public let deliveryMode: ContextDeliveryMode
    public let measuredBytes: Int?
    public let includedBytes: Int?
    public let deliveredBytes: Int?
    public let fullByteCount: Int?
    public let digest: String?
    public let bodyReference: TimelineBodyReference?
    public let omitted: Bool

    public init(_ component: ContextComponent) {
        id = opaqueProjectionID(component.componentID, namespace: "context-component")
        inclusionID = opaqueProjectionID(component.inclusionID, namespace: "context-inclusion")
        sourceID = opaqueProjectionID(component.sourceID, namespace: "context-source")
        sourceProvenance = component.source.provenance
        mode = component.mode
        deliveryMode = component.deliveryMode
        measuredBytes = component.measuredBytes
        includedBytes = component.includedBytes
        deliveredBytes = component.deliveredBytes
        fullByteCount = component.fullByteCount
        digest = component.digest
        bodyReference = component.bodyReference
        omitted = component.omitted
    }

}

/// A bounded metadata view of one producer-side system-prompt source.  Labels and source IDs
/// are intentionally replaced with fixed kind labels and digests: a source description or path
/// is not automatically safe to display merely because it came from a prompt builder.
public struct RecordedModelContextSource: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let inclusionID: String
    public let kind: PromptSourceKind
    public let status: PromptSourceStatus
    public let label: String
    public let fullByteCount: Int?
    public let deliveredByteCount: Int
    public let renderedByteCount: Int
    public let deliveredByteOffsetInRendered: Int
    public let fullDigest: String?
    public let deliveredDigest: String
    public let renderedDigest: String
    public let fullBodyReference: TimelineBodyReference?
    public let deliveredBodyReference: TimelineBodyReference?
    public let renderedBodyReference: TimelineBodyReference?
    public let provenance: EventRef?

    public init(_ source: ContextManifestSource) {
        id = opaqueProjectionID(source.sourceID, namespace: "prompt-source")
        inclusionID = opaqueProjectionID(source.inclusionID, namespace: "prompt-inclusion")
        kind = source.kind
        status = source.status
        label = Self.safeLabel(for: source.kind)
        fullByteCount = source.fullByteCount
        deliveredByteCount = source.deliveredByteCount
        renderedByteCount = source.renderedByteCount
        deliveredByteOffsetInRendered = source.deliveredByteOffsetInRendered
        fullDigest = source.fullDigest
        deliveredDigest = source.deliveredDigest
        renderedDigest = source.renderedDigest
        fullBodyReference = source.fullBodyReference
        deliveredBodyReference = source.deliveredBodyReference
        renderedBodyReference = source.renderedBodyReference
        provenance = source.provenance
    }

    private static func safeLabel(for kind: PromptSourceKind) -> String {
        switch kind {
        case .baseInstruction: "Base instructions"
        case .workingDirectory: "Working directory"
        case .contextFile: "Context file"
        case .skill: "Skill"
        case .memory: "Memory"
        case .generated: "Generated context"
        }
    }
}

/// An omission without producer-controlled source names or prose.  The full reason remains
/// available through explicit journal inspection when needed.
public struct RecordedModelContextOmission: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let reasonDigest: String
    public let measuredBytes: Int?

    public init(_ omission: ContextManifestOmission) {
        id = opaqueProjectionID(omission.omissionID, namespace: "context-omission")
        sourceID = opaqueProjectionID(omission.sourceID, namespace: "context-source")
        reasonDigest = opaqueProjectionID(omission.reason, namespace: "context-omission-reason")
        measuredBytes = omission.measuredBytes
    }
}

/// Bounded facts about context evidence that the current reader cannot interpret. Unknown
/// event/reference identities may themselves contain user-controlled material, so this
/// projection retains counts and typed domains rather than copying those identities.
public struct RecordedModelContextUnknowns: Codable, Hashable, Sendable {
    public static let maximumCount = 1_000_000

    public let eventCount: Int
    public let domains: [TimelineDomain]
    public let referenceCount: Int

    public init(eventCount: Int = 0, domains: [TimelineDomain] = [], referenceCount: Int = 0) {
        self.eventCount = min(Self.maximumCount, max(0, eventCount))
        self.domains = Array(Set(domains).sorted { $0.rawValue < $1.rawValue })
        self.referenceCount = min(Self.maximumCount, max(0, referenceCount))
    }
}

/// The metadata-only projection of the last context crossing accepted by the Session reducer.
/// Constructing this from a snapshot makes it usable by local and service-backed readers alike.
public struct RecordedModelContextProjection: Codable, Hashable, Sendable {
    public static let maximumComponents = 64
    public static let maximumSources = 32
    public static let maximumOmissions = 64

    public let availability: RecordedModelContextAvailability
    public let manifestID: String?
    public let requestID: String?
    public let modelID: String?
    public let assemblyID: String?
    public let components: [RecordedModelContextComponent]
    public let componentCount: Int
    public let omittedComponentCount: Int
    public let omissions: [RecordedModelContextOmission]
    public let omissionCount: Int
    public let omittedOmissionCount: Int
    /// Nil means no source decomposition was recorded, not that the prompt had no sources.
    public let sources: [RecordedModelContextSource]?
    public let sourceCount: Int?
    public let omittedSourceCount: Int
    public let contextBoundaryEventID: String?
    public let compactionBoundaryEventID: String?
    public let compactionSummaryByteCount: Int?
    public let compactionSummaryDigest: String?
    public let compactionSummaryInspectionRequired: Bool
    public let cumulativeDeliveredBytes: Int?
    public let measuredBytes: Int?
    public let deliveredBytes: Int?
    public let measurementBasis: String?
    public let unknowns: RecordedModelContextUnknowns

    public var isObserved: Bool { availability == .observed }
    public var hasOmissions: Bool {
        omissionCount > 0 || omittedComponentCount > 0 || omittedOmissionCount > 0
            || omittedSourceCount > 0 || components.contains(where: { $0.omitted })
            || unknowns.eventCount > 0 || unknowns.referenceCount > 0
    }

    public init(
        _ snapshot: SessionSnapshot,
        sourceCompleteness: WorkServiceSourceCompleteness = .complete
    ) {
        self.init(
            manifest: snapshot.contextManifest,
            contextBoundaryEventID: snapshot.contextBoundaryEventID,
            unknowns: RecordedModelContextUnknowns(
                eventCount: snapshot.unknownEvents.count,
                domains: Array(snapshot.unknownDomains)),
            projectionValid: sourceCompleteness == .complete
                && snapshot.structuralIntegrityValid
                && snapshot.semanticProjectionValid)
    }

    public init(
        manifest: ContextManifest?,
        contextBoundaryEventID: String? = nil,
        unknowns: RecordedModelContextUnknowns = .init(),
        projectionValid: Bool = true
    ) {
        // Invalid reducer state may contain attacker- or corruption-controlled references. Keep
        // only fixed availability/unknown counts until the Session projection is canonical.
        let trustedManifest = projectionValid ? manifest : nil
        let allComponents = trustedManifest?.components ?? []
        componentCount = allComponents.count
        components = Array(allComponents.prefix(Self.maximumComponents)).map {
            RecordedModelContextComponent($0)
        }
        omittedComponentCount = max(0, allComponents.count - components.count)

        let allOmissions = trustedManifest?.omissions ?? []
        omissionCount = allOmissions.count
        omissions = Array(allOmissions.prefix(Self.maximumOmissions)).map {
            RecordedModelContextOmission($0)
        }
        omittedOmissionCount = max(0, allOmissions.count - omissions.count)

        if let sourceRecords = trustedManifest?.systemPromptSources {
            sources = Array(sourceRecords.prefix(Self.maximumSources)).map {
                RecordedModelContextSource($0)
            }
            sourceCount = sourceRecords.count
            omittedSourceCount = max(0, sourceRecords.count - (sources?.count ?? 0))
        } else {
            sources = nil
            sourceCount = nil
            omittedSourceCount = 0
        }

        if !projectionValid {
            availability = .invalid
        } else if trustedManifest != nil {
            availability = .observed
        } else {
            availability = .unavailable
        }
        manifestID = trustedManifest.map {
            opaqueProjectionID($0.manifestID, namespace: "context-manifest")
        }
        requestID = trustedManifest.map {
            opaqueProjectionID($0.requestID, namespace: "context-request")
        }
        modelID = trustedManifest.map { String($0.modelID.prefix(256)) }
        assemblyID = trustedManifest?.systemPromptAssemblyID.map {
            opaqueProjectionID($0, namespace: "prompt-assembly")
        }
        measuredBytes = trustedManifest?.measuredBytes
        deliveredBytes = trustedManifest?.deliveredBytes
        measurementBasis = trustedManifest?.measuredBy
        self.contextBoundaryEventID = projectionValid ? contextBoundaryEventID.map {
            opaqueProjectionID($0, namespace: "context-boundary")
        } : nil
        self.cumulativeDeliveredBytes = trustedManifest?.cumulativeDeliveredBytes
        self.unknowns = unknowns

        // SessionSnapshot also carries the latest compaction transition, but it is independent of
        // the latest provider crossing. Only a component recorded in this exact manifest proves
        // that a summary crossed in this request.
        if let compaction = trustedManifest?.components.last(where: {
            $0.mode == .compactionSummary
        }) {
            compactionBoundaryEventID = compaction.source.provenance.map {
                opaqueProjectionID($0.eventID, namespace: "compaction-boundary")
            }
            compactionSummaryByteCount = compaction.fullByteCount
                ?? compaction.measuredBytes ?? compaction.deliveredBytes
            compactionSummaryDigest = compaction.digest.flatMap {
                ContextBodyStore.isValidDigest($0) ? $0 : nil
            }
            compactionSummaryInspectionRequired = compaction.bodyReference != nil
        } else {
            compactionBoundaryEventID = nil
            compactionSummaryByteCount = nil
            compactionSummaryDigest = nil
            compactionSummaryInspectionRequired = false
        }
    }
}

public enum CanonicalNamespaceAvailability: String, Codable, Hashable, Sendable {
    case live
    case reconnectable
    case unavailable
    case notReconstructed = "not_reconstructed"
    case notExposed = "not_exposed"
}

/// Namespace metadata safe for a UI or durable handoff.  In particular, it has no Python
/// `repr`; callers must perform an explicit, capability-controlled inspection to view a value.
public struct CanonicalNamespaceMetadata: Codable, Hashable, Sendable {
    public let availability: CanonicalNamespaceAvailability
    public let cwdIdentityDigest: String?
    public let bindings: [Binding]
    public let totalBindingCount: Int
    public let omittedBindingCount: Int

    public struct Binding: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let typeCategory: String
        public let typeIdentityDigest: String
        public let length: Int?

        public init(name: String, type: String, length: Int?) {
            id = "namespace-name-sha256:" + AviarySHA256.hash(data: Data(name.utf8)).description
            typeCategory = Self.category(type)
            typeIdentityDigest = "sha256:" + AviarySHA256.hash(data: Data(type.utf8)).description
            self.length = length.map { max(0, $0) }
        }

        private static func category(_ value: String) -> String {
            switch value {
            case "NoneType": return "none"
            case "bool": return "boolean"
            case "int", "float", "complex": return "number"
            case "str": return "string"
            case "bytes", "bytearray", "memoryview": return "bytes"
            case "list", "tuple", "range": return "sequence"
            case "dict": return "mapping"
            case "set", "frozenset": return "set"
            case "function", "builtin_function_or_method", "method": return "callable"
            case "module": return "module"
            case "type": return "type"
            default: return "object"
            }
        }
    }

    public init(
        availability: CanonicalNamespaceAvailability = .notExposed,
        cwd: String? = nil, bindings: [Binding] = [], maximumBindings: Int = 256
    ) {
        let limit = max(1, min(maximumBindings, 1_024))
        self.availability = availability
        if let cwd {
            cwdIdentityDigest = "sha256:" + AviarySHA256.hash(data: Data(cwd.utf8)).description
        } else {
            cwdIdentityDigest = nil
        }
        totalBindingCount = bindings.count
        self.bindings = Array(bindings.prefix(limit))
        omittedBindingCount = max(0, bindings.count - self.bindings.count)
    }

    /// Adapt the non-perturbing RuntimeHost inspection result without retaining or displaying
    /// its raw `repr` values.
    public init(_ namespace: RuntimeHost.Namespace,
                availability: CanonicalNamespaceAvailability = .live,
                maximumBindings: Int = 256) {
        self.init(
            availability: availability, cwd: namespace.cwd,
            bindings: namespace.bindings.map { Binding(name: $0.name, type: $0.type, length: $0.length) },
            maximumBindings: maximumBindings)
    }
}

public struct CanonicalWorkingHandle: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let state: BoundedHandleState

    public init(_ handle: WorkHandleSnapshot) {
        id = opaqueProjectionID(handle.handle.handleID, namespace: "handle")
        state = Self.state(handle.state)
    }

    private static func state(_ value: String) -> BoundedHandleState {
        switch value {
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "canceled": return .canceled
        case "completed": return .completed
        default: return .active
        }
    }

}

public struct CanonicalWorkingChild: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let state: BoundedChildState

    public init(id: String, state: String) {
        self.id = "child-sha256:" + AviarySHA256.hash(data: Data(id.utf8)).description
        switch state {
        case "running": self.state = .running
        case "done": self.state = .done
        case "failed": self.state = .failed
        case "canceled": self.state = .canceled
        default: self.state = .unknown
        }
    }
}

public struct CanonicalWorkingArtifact: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let mediaTypeCategory: String
    public let byteCount: Int?
    public let contentDigest: String?
    public let available: Bool
    public let bodyReferenceRecorded: Bool

    public init(_ artifact: WorkServiceArtifactDescriptor) {
        id = "artifact-sha256:" + AviarySHA256.hash(data: Data(artifact.artifactID.utf8)).description
        mediaTypeCategory = Self.mediaTypeCategory(artifact.mediaType)
        byteCount = artifact.byteCount
        contentDigest = artifact.digest.flatMap {
            ContextBodyStore.isValidDigest($0) ? $0 : nil
        }
        available = artifact.available
        bodyReferenceRecorded = artifact.bodyReference != nil
    }

    private static func mediaTypeCategory(_ value: String?) -> String {
        guard let topLevel = value?.split(separator: "/", maxSplits: 1).first?.lowercased()
        else { return "unknown" }
        switch topLevel {
        case "text", "image", "audio", "video", "application", "font", "model":
            return topLevel
        default:
            return "other"
        }
    }
}

/// Safe action metadata for a working-state view. Action prose and targets can contain user
/// content or paths, so this view retains digests and lifecycle facts rather than raw strings.
public struct CanonicalWorkingAction: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: ActionKind
    public let kindTitle: String
    public let state: ActionExecutionState
    public let stateTitle: String
    public let intentDigest: String?
    public let targetDigest: String?
    public let scopeDigest: String?
    public let metadataEntryCount: Int
    public let metadataWasTruncated: Bool
    public let failureKind: ActionFailureKind?
    public let retrySafety: ActionRetrySafety?

    public init(_ action: WorkActionSnapshot) {
        id = "action-sha256:" + AviarySHA256.hash(
            data: Data(action.action.actionID.utf8)).description
        kind = action.kind
        kindTitle = String(describing: action.kind)
        state = action.state
        stateTitle = String(describing: action.state)
        intentDigest = Self.digest(action.intent)
        targetDigest = Self.digest(action.target)
        scopeDigest = Self.digest(action.scope)
        metadataEntryCount = action.metadata.count
        metadataWasTruncated = action.metadataWasTruncated
        failureKind = action.failureKind
        retrySafety = action.retrySafety
    }

    private static func digest(_ value: String?) -> String? {
        guard let value else { return nil }
        return "sha256:" + AviarySHA256.hash(data: Data(value.utf8)).description
    }
}

/// A privacy-safe recovery claim. Caveat text is conversation-adjacent material, so only its
/// count and digest cross this projection boundary.
public struct CanonicalWorkingRecovery: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case workJournal = "work_journal"
        case sessionJournal = "session_journal"
    }

    public let operation: RecoveryOperation
    public let planes: [RecoveryPlane: RecoveryCoverageStatus]
    public let evidence: EventRef?
    public let evidenceCursor: JournalCursor?
    public let source: Source
    public let sourceEvent: EventRef
    public let sessionID: String
    public let sessionAttachmentID: String
    public let runID: String
    public let caveatCount: Int
    public let caveatDigest: String?

    public init(_ recorded: RecordedRecoveryCoverage, source: Source) {
        let coverage = recorded.coverage
        operation = coverage.operation
        planes = coverage.planes
        evidence = coverage.evidence
        evidenceCursor = coverage.evidenceCursor
        self.source = source
        sourceEvent = recorded.sourceEvent
        sessionID = opaqueProjectionID(recorded.session.sessionID, namespace: "recovery-session")
        sessionAttachmentID = opaqueProjectionID(
            recorded.sessionAttachment.attachmentID, namespace: "recovery-session-attachment")
        runID = opaqueProjectionID(recorded.run.runID, namespace: "recovery-run")
        caveatCount = coverage.caveats.count
        if coverage.caveats.isEmpty {
            caveatDigest = nil
        } else {
            let data = Data(coverage.caveats.joined(separator: "\n").utf8)
            caveatDigest = "sha256:" + AviarySHA256.hash(data: data).description
        }
    }
}

public enum CanonicalWorkingStateFailure: String, Codable, Hashable, Sendable {
    case controllerProofMissing = "controller_proof_missing"
    case attachmentTupleIncomplete = "attachment_tuple_incomplete"
    case journalAuthorityMismatch = "journal_authority_mismatch"
    case workIdentityMismatch = "work_identity_mismatch"
    case sessionIdentityMismatch = "session_identity_mismatch"
    case reciprocalAttachmentMissing = "reciprocal_attachment_missing"
    case runOwnerMismatch = "run_owner_mismatch"
    case foreignArtifact = "foreign_artifact"
    case sourceIncomplete = "source_incomplete"
    case reducerIntegrityInvalid = "reducer_integrity_invalid"
}

/// Canonical durable Work/Session state suitable for a GUI handoff.  It describes evidence at
/// exact cursors, not every object currently resident in Python.  Namespace and background-work
/// availability remain explicit instead of being inferred from a connected socket.
public struct CanonicalWorkingStateProjection: Codable, Hashable, Sendable {
    public static let maximumActions = 256
    public static let maximumHandles = 256
    public static let maximumAgentHandles = 256
    public static let maximumChildren = 256
    public static let maximumArtifacts = 256
    public static let maximumRecoveryClaims = 32

    public let work: WorkRef?
    public let session: SessionRef?
    public let workCursor: JournalCursor
    public let sessionCursor: JournalCursor
    public let workspaceID: WorkHostWorkspaceID?
    public let lifecycle: WorkLifecycle
    public let execution: WorkExecution
    public let currentRun: RunRef?
    public let activeTurn: TurnRef?
    public let modelID: String?
    public let activeActionIDs: [String]
    public let actions: [CanonicalWorkingAction]
    public let handles: [CanonicalWorkingHandle]
    public let agentHandles: [LocalTimelineCatalog.AgentHandleFact]
    public let agentHandleFactsAvailable: Bool
    public let children: [CanonicalWorkingChild]
    public let artifacts: [CanonicalWorkingArtifact]
    public let recovery: [CanonicalWorkingRecovery]
    public let namespace: CanonicalNamespaceMetadata
    public let workSourceCompleteness: WorkServiceSourceCompleteness
    public let sessionSourceCompleteness: WorkServiceSourceCompleteness
    public let isCanonical: Bool
    public let canonicalityFailures: [CanonicalWorkingStateFailure]
    public let omittedActionCount: Int
    public let omittedHandleCount: Int
    public let omittedAgentHandleCount: Int
    public let omittedChildCount: Int
    public let omittedArtifactCount: Int
    public let omittedRecoveryCount: Int
    public let omittedWorkRecoveryCount: Int
    public let omittedSessionRecoveryCount: Int
    public let artifactIndexCompleteness: WorkServiceSourceCompleteness
    public let attachmentIndexCompleteness: WorkServiceSourceCompleteness
    public let unclassifiedDescriptorCompleteness: WorkServiceSourceCompleteness
    public let omittedArtifactMetadataCount: Int
    public let omittedAttachmentCount: Int
    public let unclassifiedDescriptorOmissionCount: Int
    public let descriptorOmissionCount: Int

    public init(projection: WorkServiceAttachedWorkProjection) {
        self.init(
            descriptor: projection.descriptor, attachment: projection.attachment,
            workSnapshot: projection.workSnapshot, sessionSnapshot: projection.sessionSnapshot,
            workCursor: projection.workCursor, sessionCursor: projection.sessionCursor,
            workSourceCompleteness: projection.workSourceCompleteness,
            sessionSourceCompleteness: projection.sessionSourceCompleteness,
            controllerCanonical: projection.isCanonical)
    }

    public init(
        descriptor: WorkServiceWorkDescriptor, attachment: WorkServiceClientAttachment,
        workSnapshot: WorkSnapshot, sessionSnapshot: SessionSnapshot,
        workCursor: JournalCursor, sessionCursor: JournalCursor,
        workSourceCompleteness: WorkServiceSourceCompleteness,
        sessionSourceCompleteness: WorkServiceSourceCompleteness
    ) {
        self.init(
            descriptor: descriptor, attachment: attachment, workSnapshot: workSnapshot,
            sessionSnapshot: sessionSnapshot, workCursor: workCursor, sessionCursor: sessionCursor,
            workSourceCompleteness: workSourceCompleteness,
            sessionSourceCompleteness: sessionSourceCompleteness,
            controllerCanonical: true)
    }

    private init(
        descriptor: WorkServiceWorkDescriptor, attachment: WorkServiceClientAttachment,
        workSnapshot: WorkSnapshot, sessionSnapshot: SessionSnapshot,
        workCursor: JournalCursor, sessionCursor: JournalCursor,
        workSourceCompleteness: WorkServiceSourceCompleteness,
        sessionSourceCompleteness: WorkServiceSourceCompleteness,
        controllerCanonical: Bool
    ) {
        work = descriptor.work
        session = attachment.session
        self.workCursor = workCursor
        self.sessionCursor = sessionCursor
        self.workSourceCompleteness = workSourceCompleteness
        self.sessionSourceCompleteness = sessionSourceCompleteness
        descriptorOmissionCount = descriptor.omissions.count
        let descriptorArtifactOmissionCount = Self.omissionCount(
            descriptor.omissions, categories: ["artifacts"])
        let locallyBoundedArtifactCount = max(
            0, descriptor.artifacts.count - Self.maximumArtifacts)
        let aggregateArtifactMetadataOmissionCount = Self.omissionCount(
            descriptor.omissions, categories: ["artifact_metadata"])
        let retainedArtifactMetadataOmissionCount = descriptor.artifacts.reduce(into: 0) {
            count, artifact in
            if artifact.metadataWasTruncated { count += 1 }
        }
        // A producer may report loss on each retained row, through the aggregate omission, or
        // through both.  Preserve the strongest truthful count without double-counting the same
        // shortened rows.
        omittedArtifactMetadataCount = max(
            aggregateArtifactMetadataOmissionCount,
            retainedArtifactMetadataOmissionCount)
        omittedAttachmentCount = Self.omissionCount(
            descriptor.omissions, categories: ["attachments"])
        unclassifiedDescriptorOmissionCount = Self.omissionCount(
            descriptor.omissions,
            excluding: ["artifacts", "artifact_metadata", "artifact_index", "attachments"])
        let artifactIndexIsUnknown = descriptor.omissions.contains {
            $0.category == "artifact_index"
        }
        artifactIndexCompleteness = artifactIndexIsUnknown ? .unknown
            : descriptorArtifactOmissionCount == 0
                && omittedArtifactMetadataCount == 0
                && locallyBoundedArtifactCount == 0 ? .complete : .incomplete
        attachmentIndexCompleteness = omittedAttachmentCount == 0 ? .complete : .incomplete
        unclassifiedDescriptorCompleteness = unclassifiedDescriptorOmissionCount == 0
            ? .complete : .unknown
        let descriptorClientRowsWithID = descriptor.attachments.filter {
            $0.attachment == attachment.attachment
        }
        let descriptorClientAttachments = descriptor.attachments.filter {
            $0.attachment == attachment.attachment
                && $0.client == attachment.client
                && $0.session == attachment.session
                && $0.sessionJournal == attachment.sessionJournal
                && $0.sessionAttachment == attachment.sessionAttachment
        }
        let descriptorSessionRowsWithID = descriptor.sessionAttachments.filter {
            $0.sessionAttachment == attachment.sessionAttachment
        }
        let descriptorSessionRelationships = descriptor.sessionAttachments.filter {
            $0.session == attachment.session
                && $0.sessionJournal == attachment.sessionJournal
                && $0.sessionAttachment == attachment.sessionAttachment
                && $0.isAttached
        }
        let workAttachment = attachment.sessionAttachment.flatMap {
            workSnapshot.sessionAttachments[$0.attachmentID]
        }
        let sessionAttachment = attachment.sessionAttachment.flatMap {
            sessionSnapshot.attachments[$0.attachmentID]
        }
        let attachmentTupleIsComplete = attachment.session != nil
            && attachment.sessionJournal != nil && attachment.sessionAttachment != nil
        let journalAuthorityValid = descriptor.journal.owner == .work(descriptor.work)
            && descriptor.journal.authority.authorityID == descriptor.work.workHostID
            && attachment.sessionJournal?.owner == attachment.session.map(TimelineJournalOwner.session)
            && attachment.sessionJournal?.authority.authorityID == descriptor.work.workHostID
        let workIdentityValid = workSnapshot.work == descriptor.work
            && workSnapshot.workHost == WorkHostRef(descriptor.work.workHostID)
            && workCursor.journal == descriptor.journal
            && workCursor.sequence == workSnapshot.lastSequence
            && workCursor.eventID == workSnapshot.lastEventID
        let sessionIdentityValid = sessionSnapshot.session == attachment.session
            && sessionCursor.journal == attachment.sessionJournal
            && sessionCursor.sequence == sessionSnapshot.lastSequence
            && sessionCursor.eventID == sessionSnapshot.lastEventID
        let reciprocalAttachmentValid = descriptorClientAttachments.count == 1
            && descriptorClientRowsWithID.count == 1
            && descriptorSessionRelationships.count == 1
            && descriptorSessionRowsWithID.count == 1
            && workAttachment?.session == attachment.session
            && workAttachment?.attachment == attachment.sessionAttachment
            && workAttachment?.isAttached == true
            && sessionAttachment?.work == descriptor.work
            && sessionAttachment?.attachment == attachment.sessionAttachment
            && sessionAttachment?.isAttached == true
        let runOwnerValid = workSnapshot.activeRun == descriptor.currentRun
            && workSnapshot.activeRunSession == descriptor.currentRunSession
            && workSnapshot.activeRunSessionAttachment == descriptor.currentRunSessionAttachment
        let sourceComplete = workSourceCompleteness == .complete
            && sessionSourceCompleteness == .complete
        let reducerIntegrityValid = workSnapshot.structuralIntegrityValid
            && workSnapshot.semanticProjectionValid
            && sessionSnapshot.structuralIntegrityValid
            && sessionSnapshot.semanticProjectionValid
        var failures: [CanonicalWorkingStateFailure] = []
        if !controllerCanonical { failures.append(.controllerProofMissing) }
        if !attachmentTupleIsComplete { failures.append(.attachmentTupleIncomplete) }
        if !journalAuthorityValid { failures.append(.journalAuthorityMismatch) }
        if !workIdentityValid { failures.append(.workIdentityMismatch) }
        if !sessionIdentityValid { failures.append(.sessionIdentityMismatch) }
        if !reciprocalAttachmentValid { failures.append(.reciprocalAttachmentMissing) }
        if !runOwnerValid { failures.append(.runOwnerMismatch) }
        if !descriptor.artifacts.allSatisfy({ $0.work == descriptor.work }) {
            failures.append(.foreignArtifact)
        }
        if !sourceComplete { failures.append(.sourceIncomplete) }
        if !reducerIntegrityValid { failures.append(.reducerIntegrityInvalid) }
        canonicalityFailures = failures
        let canonical = failures.isEmpty
        self.isCanonical = canonical

        guard canonical else {
            workspaceID = nil
            lifecycle = .unknown
            execution = .unknown
            currentRun = nil
            activeTurn = nil
            modelID = nil
            activeActionIDs = []
            actions = []
            handles = []
            agentHandles = []
            agentHandleFactsAvailable = false
            children = []
            artifacts = []
            recovery = []
            self.namespace = CanonicalNamespaceMetadata(availability: .unavailable)
            omittedActionCount = 0
            omittedHandleCount = 0
            omittedAgentHandleCount = 0
            omittedChildCount = 0
            omittedArtifactCount = 0
            omittedRecoveryCount = 0
            omittedWorkRecoveryCount = 0
            omittedSessionRecoveryCount = 0
            return
        }

        workspaceID = descriptor.configuration.workspaceID
        lifecycle = workSnapshot.lifecycle
        execution = workSnapshot.execution
        currentRun = workSnapshot.activeRun ?? descriptor.currentRun
        activeTurn = workSnapshot.activeTurn ?? sessionSnapshot.activeTurn
        modelID = workSnapshot.modelID ?? sessionSnapshot.modelID ?? descriptor.configuration.modelID
        let actionValues = workSnapshot.actions.values.sorted { lhs, rhs in
            if lhs.state.isTerminal != rhs.state.isTerminal {
                return !lhs.state.isTerminal
            }
            let l = lhs.intentEvent?.sequence ?? lhs.startedEvent?.sequence
                ?? lhs.outcomeEvent?.sequence ?? Int.max
            let r = rhs.intentEvent?.sequence ?? rhs.startedEvent?.sequence
                ?? rhs.outcomeEvent?.sequence ?? Int.max
            return l == r ? lhs.action.actionID < rhs.action.actionID : l < r
        }
        activeActionIDs = Array(workSnapshot.activeActionIDs.sorted().prefix(Self.maximumActions)).map {
            "action-sha256:" + AviarySHA256.hash(data: Data($0.utf8)).description
        }
        actions = Array(actionValues.prefix(Self.maximumActions)).map(CanonicalWorkingAction.init)
        omittedActionCount = max(0, actionValues.count - actions.count)
        let handleValues = workSnapshot.handles.values.sorted { $0.handle.handleID < $1.handle.handleID }
        handles = Array(handleValues.prefix(Self.maximumHandles)).map(CanonicalWorkingHandle.init)
        omittedHandleCount = max(0, handleValues.count - handles.count)
        let agentHandleFactsKnown = !workSnapshot.unknownDomains.contains(.work)
            && !workSnapshot.unknownDomains.contains(.session)
            && !workSnapshot.unknownDomains.contains(.runtime)
            && !workSnapshot.unknownDomains.contains(.externalEffects)
            && sessionSnapshot.unknownDomains.isDisjoint(with: [.work, .session])
        agentHandleFactsAvailable = agentHandleFactsKnown
        let agentHandleValues = agentHandleFactsKnown
            ? workSnapshot.agentHandles.values.map(LocalTimelineCatalog.AgentHandleFact.init)
                .sorted(by: LocalTimelineCatalog.agentHandleLess)
            : []
        agentHandles = Array(agentHandleValues.prefix(Self.maximumAgentHandles))
        omittedAgentHandleCount = max(0, agentHandleValues.count - agentHandles.count)
        let childValues = workSnapshot.childStates.sorted { $0.key < $1.key }
        children = Array(childValues.prefix(Self.maximumChildren)).map {
            CanonicalWorkingChild(id: $0.key, state: $0.value)
        }
        omittedChildCount = max(0, childValues.count - children.count)
        let artifactValues = descriptor.artifacts.sorted { $0.artifactID < $1.artifactID }
        artifacts = Array(artifactValues.prefix(Self.maximumArtifacts)).map(CanonicalWorkingArtifact.init)
        omittedArtifactCount = Self.saturatingAdd(
            locallyBoundedArtifactCount, descriptorArtifactOmissionCount)
        let matching: (RecordedRecoveryCoverage) -> Bool = { recorded in
            recorded.work == descriptor.work
                && recorded.workJournal == descriptor.journal
                && recorded.workHost == WorkHostRef(descriptor.work.workHostID)
                && recorded.session == attachment.session
                && recorded.sessionAttachment == attachment.sessionAttachment
                && workSnapshot.observedRunIDs.contains(recorded.run.runID)
        }
        let workRecovery = Self.prioritizedRecovery(
            workSnapshot.recordedRecovery.filter {
            matching($0) && $0.sourceEvent.journal == descriptor.journal
            }, currentRun: workSnapshot.activeRun)
        let sessionRecovery = Self.prioritizedRecovery(
            sessionSnapshot.recordedRecovery.filter {
            matching($0) && $0.sourceEvent.journal == attachment.sessionJournal
            }, currentRun: workSnapshot.activeRun)
        // Reserve half the bounded view for each journal when both have evidence, then lend any
        // unused capacity to the other side. A long Work history must not starve the selected
        // Session's own recovery claims (or vice versa).
        let reserved = Self.maximumRecoveryClaims / 2
        var workLimit = min(workRecovery.count, reserved)
        var sessionLimit = min(sessionRecovery.count, reserved)
        var remaining = Self.maximumRecoveryClaims - workLimit - sessionLimit
        let additionalWork = min(remaining, workRecovery.count - workLimit)
        workLimit += additionalWork
        remaining -= additionalWork
        sessionLimit += min(remaining, sessionRecovery.count - sessionLimit)
        let boundedWork = Array(workRecovery.prefix(workLimit))
        let boundedSession = Array(sessionRecovery.prefix(sessionLimit))
        recovery = boundedWork.map { CanonicalWorkingRecovery($0, source: .workJournal) }
            + boundedSession.map { CanonicalWorkingRecovery($0, source: .sessionJournal) }
        omittedWorkRecoveryCount = max(0, workRecovery.count - boundedWork.count)
        omittedSessionRecoveryCount = max(0, sessionRecovery.count - boundedSession.count)
        omittedRecoveryCount = omittedWorkRecoveryCount + omittedSessionRecoveryCount
        self.namespace = CanonicalNamespaceMetadata()
    }

    private static func prioritizedRecovery(
        _ values: [RecordedRecoveryCoverage], currentRun: RunRef?
    ) -> [RecordedRecoveryCoverage] {
        values.enumerated().sorted { lhs, rhs in
            let lhsIsCurrent = currentRun != nil && lhs.element.run == currentRun
            let rhsIsCurrent = currentRun != nil && rhs.element.run == currentRun
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            // Reducers append recovery records in canonical journal order. Prefer the newest
            // source event within each priority class; the source identity is a deterministic
            // final tie-break if an externally constructed snapshot repeats an array position.
            if lhs.offset != rhs.offset { return lhs.offset > rhs.offset }
            if lhs.element.sourceEvent.journal.stableKey
                != rhs.element.sourceEvent.journal.stableKey {
                return lhs.element.sourceEvent.journal.stableKey
                    < rhs.element.sourceEvent.journal.stableKey
            }
            return lhs.element.sourceEvent.eventID < rhs.element.sourceEvent.eventID
        }.map(\.element)
    }

    private static func omissionCount(
        _ omissions: [WorkServiceOmission], categories: Set<String>
    ) -> Int {
        omissions.reduce(0) { count, omission in
            categories.contains(omission.category)
                ? saturatingAdd(count, omission.count) : count
        }
    }

    private static func omissionCount(
        _ omissions: [WorkServiceOmission], excluding categories: Set<String>
    ) -> Int {
        omissions.reduce(0) { count, omission in
            categories.contains(omission.category)
                ? count : saturatingAdd(count, omission.count)
        }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
