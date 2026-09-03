import CryptoKit
import Foundation

// MARK: - Transport-neutral Work service contract

/// The protocol spoken by a GUI and a Work Host.  The first implementation below is an
/// in-memory reference service; a Unix-domain socket and a remote transport can encode these
/// values without changing their meaning.
public enum WorkServiceProtocol {
    public static let currentVersion = 1
    public static let minimumSupportedVersion = 1
    public static let maximumSupportedVersion = 1
}

/// A bounded surface is intentional: protocol values must be safe to render even when a remote
/// host or an agent supplied an unexpectedly large identity or diagnostic.
public enum WorkServiceBounds {
    public static let maxIdentityCharacters = 256
    public static let maxDiagnosticCharacters = 512
    public static let maxCommandValueCharacters = 8_192
    public static let maxPageSize = 64
    public static let maxEventsPerPage = 128
    public static let maxBodyChunkBytes = 64 * 1024
    public static let maxTerminalProofHandles = 128
    public static let maxArtifactsPerWork = 128
    public static let maxAttachmentsPerWork = 64
    public static let maxOmissions = 32
}

public enum WorkServiceProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidRequest(String)
    case hostUnavailable(WorkHostRef)
    case workNotFound(WorkRef)
    case journalMismatch
    case attachmentNotFound
    case capabilityDenied(WorkServiceCapability)
    case artifactNotFound
    case staleCursor(expected: JournalCursor, actual: JournalCursor)
    case sourceIncomplete
}

public struct WorkServiceHandshakeRequest: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let client: ClientRef
    public let build: String?

    public init(protocolVersion: Int = WorkServiceProtocol.currentVersion,
                client: ClientRef, build: String? = nil) {
        self.protocolVersion = protocolVersion
        self.client = client
        self.build = build
    }
}

public struct WorkServiceHandshakeResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let negotiatedVersion: Int?
    public let supportedRange: ClosedRange<Int>
    public let host: WorkHostRef
    public let hostInstance: WorkHostInstanceRef
    public let capabilities: Set<WorkServiceCapability>
    public let diagnostic: String?

    public init(accepted: Bool, negotiatedVersion: Int?, supportedRange: ClosedRange<Int>,
                host: WorkHostRef, hostInstance: WorkHostInstanceRef,
                capabilities: Set<WorkServiceCapability>, diagnostic: String? = nil) {
        self.accepted = accepted
        self.negotiatedVersion = negotiatedVersion
        self.supportedRange = supportedRange
        self.host = host
        self.hostInstance = hostInstance
        self.capabilities = capabilities
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

/// A host instance/start identity is deliberately opaque and device-independent.  It is not a
/// PID, path, mtime, or bearer credential, and it is not a substitute for durable Work state.
public struct WorkHostInstanceRef: Codable, Hashable, Sendable {
    public let host: WorkHostRef
    public let instanceID: String
    public let startIdentity: String

    public init(host: WorkHostRef, instanceID: String, startIdentity: String) {
        self.host = host
        self.instanceID = instanceID
        self.startIdentity = startIdentity
    }
}

public enum WorkServiceHostReachability: String, Codable, Hashable, Sendable {
    case observedReachable = "observed_reachable"
    case unavailable
    case recovering
}

public enum WorkServiceSourceCompleteness: String, Codable, Hashable, Sendable {
    case complete
    case incomplete
    case unknown
}

/// Ephemeral evidence from a particular Work Host instance.  A durable `running` record does
/// not imply `.observedReachable`; a service may return no observation after it disappears.
public struct WorkServiceHostObservation: Codable, Hashable, Sendable {
    public let instance: WorkHostInstanceRef
    public let reachability: WorkServiceHostReachability
    public let currentRun: RunRef?
    public let servedCursor: JournalCursor?
    public let sourceCompleteness: WorkServiceSourceCompleteness

    public init(instance: WorkHostInstanceRef, reachability: WorkServiceHostReachability,
                currentRun: RunRef?, servedCursor: JournalCursor?,
                sourceCompleteness: WorkServiceSourceCompleteness) {
        self.instance = instance
        self.reachability = reachability
        self.currentRun = currentRun
        self.servedCursor = servedCursor
        self.sourceCompleteness = sourceCompleteness
    }
}

public enum WorkServiceRecordedDisposition: String, Codable, Hashable, Sendable {
    /// `run.finished` leaves Work reusable. It does not mean the host process is alive.
    case reusable
    /// `work.completed` is an immutable terminal outcome.
    case completed
    /// Destruction is separate from completion and is explicitly destructive.
    case destroyed
}

public enum WorkServiceExecutionState: String, Codable, Hashable, Sendable {
    case idle
    case running
    case held
    case canceling
    /// Explicit End is terminalizing execution. It is not the same thing as destroying Work.
    case ending
}

public struct WorkServiceOmission: Codable, Hashable, Sendable {
    public let category: String
    public let count: Int
    public let diagnostic: String?

    public init(category: String, count: Int, diagnostic: String? = nil) {
        self.category = WorkServiceText.bound(category) ?? "unknown"
        self.count = max(0, count)
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

public enum WorkServiceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case observe
    case control
    case start
    case send
    case steer
    case queue
    case hold
    case cancel
    case end
    case destroy
    case complete
    case inspectArtifacts = "inspect_artifacts"
}

/// Authorization is injected at the host boundary. A transport may authenticate a principal
/// and then pass the resulting ``ClientRef`` here; the reference service never treats a
/// self-claimed Work ID or a host-wide capability set as proof of authorization.
public protocol WorkServiceAuthorizer: Sendable {
    func authorization(for client: ClientRef,
                       requested: Set<WorkServiceCapability>) -> WorkServiceAuthorizationOutcome
}

/// Deterministic policy used by the executable reference service and tests. Production hosts
/// can replace it with a principal-backed decision without changing the value contract.
public struct WorkServiceCapabilityPolicy: WorkServiceAuthorizer, Sendable {
    public let grantsByClient: [ClientRef: Set<WorkServiceCapability>]

    public init(grantsByClient: [ClientRef: Set<WorkServiceCapability>] = [:]) {
        self.grantsByClient = grantsByClient
    }

    public func authorization(
        for client: ClientRef, requested: Set<WorkServiceCapability>
    ) -> WorkServiceAuthorizationOutcome {
        let granted = requested.intersection(grantsByClient[client] ?? [])
        let denied = requested.subtracting(granted)
        return WorkServiceAuthorizationOutcome(
            requested: requested, granted: granted, denied: denied,
            diagnostic: denied.isEmpty ? nil : "principal is not authorized for one or more capabilities")
    }
}

/// Authorization is a separate result from Work identity.  Possessing a `WorkRef` never grants
/// control, and the reference in this value contains no secret or transport token.
public struct WorkServiceAuthorizationOutcome: Codable, Hashable, Sendable {
    public let requested: Set<WorkServiceCapability>
    public let granted: Set<WorkServiceCapability>
    public let denied: Set<WorkServiceCapability>
    public let diagnostic: String?

    public init(requested: Set<WorkServiceCapability>, granted: Set<WorkServiceCapability>,
                denied: Set<WorkServiceCapability>, diagnostic: String? = nil) {
        self.requested = requested
        self.granted = granted
        self.denied = denied
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }

    public func allows(_ capability: WorkServiceCapability) -> Bool {
        granted.contains(capability)
    }
}

public struct WorkServiceClientAttachment: Codable, Hashable, Sendable {
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let session: SessionRef?
    public let sessionJournal: JournalRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let authorization: WorkServiceAuthorizationOutcome
    public let cursor: JournalCursor?

    public init(attachment: ClientAttachmentRef, client: ClientRef, session: SessionRef?,
                sessionJournal: JournalRef?, sessionAttachment: SessionAttachmentRef?,
                authorization: WorkServiceAuthorizationOutcome, cursor: JournalCursor?) {
        self.attachment = attachment
        self.client = client
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.authorization = authorization
        self.cursor = cursor
    }
}

public struct WorkServiceWorkDescriptor: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let recordedDisposition: WorkServiceRecordedDisposition
    public let execution: WorkServiceExecutionState
    public let currentRun: RunRef?
    public let configuration: WorkServiceWorkConfiguration
    public let hostObservation: WorkServiceHostObservation?
    public let attachments: [WorkServiceClientAttachment]
    public let artifacts: [WorkServiceArtifactDescriptor]
    public let omissions: [WorkServiceOmission]

    public init(work: WorkRef, journal: JournalRef,
                recordedDisposition: WorkServiceRecordedDisposition,
                execution: WorkServiceExecutionState, currentRun: RunRef?,
                configuration: WorkServiceWorkConfiguration = .init(),
                hostObservation: WorkServiceHostObservation?,
                attachments: [WorkServiceClientAttachment] = [],
                artifacts: [WorkServiceArtifactDescriptor] = [],
                omissions: [WorkServiceOmission] = []) {
        self.work = work
        self.journal = journal
        self.recordedDisposition = recordedDisposition
        self.execution = execution
        self.currentRun = currentRun
        self.configuration = configuration
        self.hostObservation = hostObservation
        self.attachments = attachments
        self.artifacts = artifacts
        self.omissions = omissions
    }
}

public struct WorkServiceListRequest: Codable, Hashable, Sendable {
    public let client: ClientRef
    public let pageSize: Int
    public let pageToken: String?

    public init(client: ClientRef, pageSize: Int = WorkServiceBounds.maxPageSize,
                pageToken: String? = nil) {
        self.client = client
        self.pageSize = pageSize
        self.pageToken = pageToken
    }
}

public struct WorkServiceWorkPage: Codable, Hashable, Sendable {
    public let works: [WorkServiceWorkDescriptor]
    public let nextPageToken: String?
    public let omissions: [WorkServiceOmission]

    public init(works: [WorkServiceWorkDescriptor], nextPageToken: String?,
                omissions: [WorkServiceOmission] = []) {
        self.works = works
        self.nextPageToken = nextPageToken
        self.omissions = omissions
    }
}

public struct WorkServiceDescribeRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let client: ClientRef

    public init(work: WorkRef, journal: JournalRef, client: ClientRef) {
        self.work = work
        self.journal = journal
        self.client = client
    }
}

public struct WorkServiceAttachRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let client: ClientRef
    public let session: SessionRef?
    public let sessionJournal: JournalRef?
    public let sessionAttachment: SessionAttachmentRef?
    /// Stable caller identity for retries. It is scoped to the client and Work.
    public let commandID: String
    /// Exact Work cursor observed before the attach event is appended.
    public let causalCursor: JournalCursor
    public let requestedCapabilities: Set<WorkServiceCapability>

    public init(work: WorkRef, journal: JournalRef, client: ClientRef,
                session: SessionRef? = nil, sessionJournal: JournalRef? = nil,
                sessionAttachment: SessionAttachmentRef? = nil,
                commandID: String, causalCursor: JournalCursor,
                requestedCapabilities: Set<WorkServiceCapability> = [.observe]) {
        self.work = work
        self.journal = journal
        self.client = client
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.commandID = commandID
        self.causalCursor = causalCursor
        self.requestedCapabilities = requestedCapabilities
    }
}

public struct WorkServiceAttachResponse: Codable, Hashable, Sendable {
    public let work: WorkServiceWorkDescriptor
    /// Nil for a structured rejection (for example a stale causal cursor).
    public let attachment: WorkServiceClientAttachment?
    public let authorization: WorkServiceAuthorizationOutcome
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let hostSequence: Int
    public let resultingCursor: JournalCursor?
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(work: WorkServiceWorkDescriptor, attachment: WorkServiceClientAttachment?,
                authorization: WorkServiceAuthorizationOutcome, commandID: String,
                state: WorkServiceCommandReceiptState = .accepted,
                host: WorkHostInstanceRef, hostSequence: Int,
                resultingCursor: JournalCursor? = nil,
                rejection: WorkServiceCommandRejection? = nil, diagnostic: String? = nil) {
        self.work = work
        self.attachment = attachment
        self.authorization = authorization
        self.commandID = commandID
        self.state = state
        self.host = host
        self.hostSequence = hostSequence
        self.resultingCursor = resultingCursor
        self.rejection = rejection
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

/// Creation carries policy/configuration only. Provider credentials, Python objects, and local
/// paths stay on the Work Host and never cross this contract.
public struct WorkServiceWorkConfiguration: Codable, Hashable, Sendable {
    public let providerID: String?
    public let modelID: String?
    public let thinkingLevel: String?
    public let contextPolicy: String?
    public let workingDirectoryPolicy: String?
    public let includeContextFiles: Bool
    public let recordPayloads: Bool
    public let resumePolicy: String?
    public let initialPrompt: String?
    public let wasTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case providerID, modelID, thinkingLevel, contextPolicy, workingDirectoryPolicy
        case includeContextFiles, recordPayloads, resumePolicy, initialPrompt, wasTruncated
    }

    public init(providerID: String? = nil, modelID: String? = nil,
                thinkingLevel: String? = nil, contextPolicy: String? = nil,
                workingDirectoryPolicy: String? = nil, includeContextFiles: Bool = true,
                recordPayloads: Bool = false, resumePolicy: String? = nil,
                initialPrompt: String? = nil) {
        let boundedProvider = WorkServiceText.boundCommand(providerID)
        let boundedModel = WorkServiceText.boundCommand(modelID)
        let boundedThinking = WorkServiceText.boundCommand(thinkingLevel)
        let boundedPolicy = WorkServiceText.boundCommand(contextPolicy)
        let boundedDirectory = WorkServiceText.boundCommand(workingDirectoryPolicy)
        let boundedResume = WorkServiceText.boundCommand(resumePolicy)
        let boundedPrompt = WorkServiceText.boundCommand(initialPrompt)
        self.providerID = boundedProvider.value
        self.modelID = boundedModel.value
        self.thinkingLevel = boundedThinking.value
        self.contextPolicy = boundedPolicy.value
        self.workingDirectoryPolicy = boundedDirectory.value
        self.includeContextFiles = includeContextFiles
        self.recordPayloads = recordPayloads
        self.resumePolicy = boundedResume.value
        self.initialPrompt = boundedPrompt.value
        self.wasTruncated = boundedProvider.wasTruncated || boundedModel.wasTruncated
            || boundedThinking.wasTruncated || boundedPolicy.wasTruncated
            || boundedDirectory.wasTruncated || boundedResume.wasTruncated
            || boundedPrompt.wasTruncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve decoded bytes exactly. The host validates these values before any effect;
        // decoding must not silently truncate an adversarial transport payload.
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        contextPolicy = try container.decodeIfPresent(String.self, forKey: .contextPolicy)
        workingDirectoryPolicy = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPolicy)
        includeContextFiles = try container.decodeIfPresent(Bool.self, forKey: .includeContextFiles) ?? true
        recordPayloads = try container.decodeIfPresent(Bool.self, forKey: .recordPayloads) ?? false
        resumePolicy = try container.decodeIfPresent(String.self, forKey: .resumePolicy)
        initialPrompt = try container.decodeIfPresent(String.self, forKey: .initialPrompt)
        wasTruncated = try container.decodeIfPresent(Bool.self, forKey: .wasTruncated) ?? false
    }

    /// Decoding is intentionally checked at the effect boundary. Synthesized Codable can
    /// construct a value whose strings exceed the bound while claiming `wasTruncated == false`.
    fileprivate var hasInvalidBodyBounds: Bool {
        wasTruncated || [providerID, modelID, thinkingLevel, contextPolicy,
                         workingDirectoryPolicy, resumePolicy, initialPrompt]
            .contains { ($0?.count ?? 0) > WorkServiceBounds.maxCommandValueCharacters }
    }
}

public struct WorkServiceCreateWorkRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let client: ClientRef
    public let commandID: String
    /// Fresh Work starts from an explicit, exact empty-journal cursor. Keeping this required
    /// makes creation subject to the same causal discipline as every other mutation while
    /// still allowing a host to mint the initial Work identity.
    public let causalCursor: JournalCursor
    public let configuration: WorkServiceWorkConfiguration
    public let requestedCapabilities: Set<WorkServiceCapability>

    public init(work: WorkRef, journal: JournalRef, client: ClientRef,
                commandID: String, causalCursor: JournalCursor,
                configuration: WorkServiceWorkConfiguration = .init(),
                requestedCapabilities: Set<WorkServiceCapability> = [.observe, .control]) {
        self.work = work
        self.journal = journal
        self.client = client
        self.commandID = commandID
        self.causalCursor = causalCursor
        self.configuration = configuration
        self.requestedCapabilities = requestedCapabilities
    }
}

public struct WorkServiceCreateWorkResponse: Codable, Hashable, Sendable {
    public let work: WorkServiceWorkDescriptor
    public let authorization: WorkServiceAuthorizationOutcome
    /// Creation is a host-ordered mutation too; its receipt carries the exact empty-journal
    /// cause and the cursor of the canonical `work.created` event.
    public let receipt: WorkServiceCommandReceipt

    public init(work: WorkServiceWorkDescriptor, authorization: WorkServiceAuthorizationOutcome,
                receipt: WorkServiceCommandReceipt) {
        self.work = work
        self.authorization = authorization
        self.receipt = receipt
    }
}

public struct WorkServiceCompleteWorkRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let command: CommandRef
    public let causalCursor: JournalCursor

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                commandID: String, client: ClientRef,
                sessionAttachment: SessionAttachmentRef? = nil,
                causalCursor: JournalCursor) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.causalCursor = causalCursor
        self.command = CommandRef(commandID: commandID, client: client,
                                  sessionAttachment: sessionAttachment,
                                  causalCursor: causalCursor)
    }
}

public struct WorkServiceDetachRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    /// Stable caller identity for retries. It is scoped to the client and Work.
    public let commandID: String
    /// Exact cursor observed before the detach event is appended.
    public let causalCursor: JournalCursor

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef, commandID: String, causalCursor: JournalCursor) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.commandID = commandID
        self.causalCursor = causalCursor
    }
}

public struct WorkServiceDetachResponse: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let hostSequence: Int
    public let causalCursor: JournalCursor
    public let resultingCursor: JournalCursor?
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(work: WorkRef, commandID: String, state: WorkServiceCommandReceiptState,
                host: WorkHostInstanceRef, hostSequence: Int,
                causalCursor: JournalCursor, resultingCursor: JournalCursor?,
                rejection: WorkServiceCommandRejection? = nil, diagnostic: String? = nil) {
        self.work = work
        self.commandID = commandID
        self.state = state
        self.host = host
        self.hostSequence = hostSequence
        self.causalCursor = causalCursor
        self.resultingCursor = resultingCursor
        self.rejection = rejection
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

public struct WorkServiceSnapshotRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let afterCursor: JournalCursor?
    public let limit: Int

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef,
                afterCursor: JournalCursor? = nil,
                limit: Int = WorkServiceBounds.maxEventsPerPage) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.afterCursor = afterCursor
        self.limit = limit
    }
}

public struct WorkServiceSnapshot: Codable, Hashable, Sendable {
    public let work: WorkServiceWorkDescriptor
    public let events: [WorkServiceEventDescriptor]
    public let servedCursor: JournalCursor?
    public let omissions: [WorkServiceOmission]

    public init(work: WorkServiceWorkDescriptor, events: [WorkServiceEventDescriptor],
                servedCursor: JournalCursor?, omissions: [WorkServiceOmission] = []) {
        self.work = work
        self.events = events
        self.servedCursor = servedCursor
        self.omissions = omissions
    }
}

public struct WorkServiceEventsRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let afterCursor: JournalCursor
    public let limit: Int

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef,
                afterCursor: JournalCursor, limit: Int = WorkServiceBounds.maxEventsPerPage) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.afterCursor = afterCursor
        self.limit = limit
    }
}

public struct WorkServiceEventDescriptor: Codable, Hashable, Sendable {
    public enum BodyStatus: String, Codable, Hashable, Sendable {
        // The event is a bounded manifest; bodyReference is the optional retained-body address.
        case manifest
        case retainedBody = "retained_body"
        case unavailable
    }

    public let eventID: String
    public let kind: String
    public let cursor: JournalCursor
    public let commandID: String?
    public let run: RunRef?
    public let provenance: EventRef?
    public let bodyReference: TimelineBodyReference?
    public let bodyStatus: BodyStatus

    public init(eventID: String, kind: String, cursor: JournalCursor,
                commandID: String? = nil, run: RunRef? = nil,
                provenance: EventRef? = nil, bodyReference: TimelineBodyReference? = nil,
                bodyStatus: BodyStatus = .manifest) {
        self.eventID = eventID
        self.kind = kind
        self.cursor = cursor
        self.commandID = commandID
        self.run = run
        self.provenance = provenance
        self.bodyReference = bodyReference
        self.bodyStatus = bodyStatus
    }
}

public struct WorkServiceEventPage: Codable, Hashable, Sendable {
    public let events: [WorkServiceEventDescriptor]
    public let servedCursor: JournalCursor?
    public let nextCursor: JournalCursor?
    public let omissions: [WorkServiceOmission]

    public init(events: [WorkServiceEventDescriptor], servedCursor: JournalCursor?,
                nextCursor: JournalCursor?, omissions: [WorkServiceOmission] = []) {
        self.events = events
        self.servedCursor = servedCursor
        self.nextCursor = nextCursor
        self.omissions = omissions
    }
}

public struct WorkServiceArtifactDescriptor: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case artifactID, work, label, mediaType, byteCount, digest, available
        case bodyReference, metadataWasTruncated
    }

    public let artifactID: String
    public let work: WorkRef
    public let label: String
    public let mediaType: String?
    public let byteCount: Int?
    public let digest: String?
    public let available: Bool
    /// A device-independent address that can be resolved through ``fetchBody``.
    public let bodyReference: TimelineBodyReference?
    /// Display metadata may be shortened, but the loss is never implicit.
    public let metadataWasTruncated: Bool

    public init(artifactID: String, work: WorkRef, label: String,
                mediaType: String? = nil, byteCount: Int? = nil, digest: String? = nil,
                available: Bool = true, bodyReference: TimelineBodyReference? = nil) {
        self.artifactID = artifactID
        self.work = work
        self.metadataWasTruncated = [label, mediaType, digest]
            .contains { ($0?.count ?? 0) > WorkServiceBounds.maxDiagnosticCharacters }
        self.label = WorkServiceText.bound(label) ?? "artifact"
        self.mediaType = WorkServiceText.bound(mediaType)
        self.byteCount = byteCount.map { max(0, $0) }
        self.digest = WorkServiceText.bound(digest)
        self.available = available
        self.bodyReference = bodyReference
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            artifactID: try values.decode(String.self, forKey: .artifactID),
            work: try values.decode(WorkRef.self, forKey: .work),
            label: try values.decode(String.self, forKey: .label),
            mediaType: try values.decodeIfPresent(String.self, forKey: .mediaType),
            byteCount: try values.decodeIfPresent(Int.self, forKey: .byteCount),
            digest: try values.decodeIfPresent(String.self, forKey: .digest),
            available: try values.decodeIfPresent(Bool.self, forKey: .available) ?? true,
            bodyReference: try values.decodeIfPresent(
                TimelineBodyReference.self, forKey: .bodyReference))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(artifactID, forKey: .artifactID)
        try values.encode(work, forKey: .work)
        try values.encode(label, forKey: .label)
        try values.encodeIfPresent(mediaType, forKey: .mediaType)
        try values.encodeIfPresent(byteCount, forKey: .byteCount)
        try values.encodeIfPresent(digest, forKey: .digest)
        try values.encode(available, forKey: .available)
        try values.encodeIfPresent(bodyReference, forKey: .bodyReference)
        try values.encode(metadataWasTruncated, forKey: .metadataWasTruncated)
    }
}

public enum WorkServiceBodyStatus: String, Codable, Hashable, Sendable {
    case retained
    case unavailable
}

public struct WorkServiceArtifactRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let artifactID: String

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef, artifactID: String) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.artifactID = artifactID
    }
}

public struct WorkServiceBodyRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let reference: TimelineBodyReference
    public let offset: Int
    public let limit: Int

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef,
                reference: TimelineBodyReference, offset: Int = 0,
                limit: Int = WorkServiceBounds.maxBodyChunkBytes) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.reference = reference
        self.offset = offset
        self.limit = limit
    }
}

public struct WorkServiceBodyResponse: Codable, Hashable, Sendable {
    public let reference: TimelineBodyReference
    public let status: WorkServiceBodyStatus
    public let offset: Int
    public let data: Data?
    public let nextOffset: Int?
    public let diagnostic: String?

    public init(reference: TimelineBodyReference, status: WorkServiceBodyStatus,
                offset: Int, data: Data? = nil, nextOffset: Int? = nil,
                diagnostic: String? = nil) {
        self.reference = reference
        self.status = status
        self.offset = offset
        self.data = data
        self.nextOffset = nextOffset
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

public enum WorkServiceTerminalOperation: String, Codable, Hashable, Sendable {
    case complete
    case destroy
}

/// Proof returned by the host's terminal transaction. The committer is the seam where a
/// production RunJournalBundle can verify canonical Handle quiescence and the paired Session
/// cursor; the reference service does not invent either fact locally.
public struct WorkServiceTerminalCommitProof: Codable, Hashable, Sendable {
    public let operation: WorkServiceTerminalOperation
    public let work: WorkRef
    public let journal: JournalRef
    /// The exact caller command admitted by the Work service. A proof cannot be replayed for a
    /// different command ID, client, Session attachment, or causal cursor.
    public let command: CommandRef
    public let causalWorkCursor: JournalCursor
    /// The canonical Work cursor written by the terminal transaction. The service projects this
    /// cursor; it must not fabricate a second terminal event after the committer returns.
    public let resultingWorkCursor: JournalCursor
    public let terminalEvent: WorkServiceEventDescriptor
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let pairedSessionCursor: JournalCursor?
    /// The committer sets this only after verifying that the paired Session cursor causally
    /// covers this exact terminal Work result (not merely that a Session ID exists).
    public let sessionPairingVerified: Bool
    public let outstandingHandleIDs: [HandleRef]
    public let commitID: String

    public init(operation: WorkServiceTerminalOperation, work: WorkRef, journal: JournalRef,
                command: CommandRef, causalWorkCursor: JournalCursor,
                resultingWorkCursor: JournalCursor,
                terminalEvent: WorkServiceEventDescriptor,
                session: SessionRef, sessionJournal: JournalRef,
                sessionAttachment: SessionAttachmentRef,
                pairedSessionCursor: JournalCursor?, sessionPairingVerified: Bool,
                outstandingHandleIDs: [HandleRef] = [], commitID: String) {
        self.operation = operation
        self.work = work
        self.journal = journal
        self.command = command
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.terminalEvent = terminalEvent
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.pairedSessionCursor = pairedSessionCursor
        self.sessionPairingVerified = sessionPairingVerified
        self.outstandingHandleIDs = Array(outstandingHandleIDs.prefix(WorkServiceBounds.maxTerminalProofHandles))
        self.commitID = WorkServiceText.bound(commitID) ?? "unknown"
    }
}

public struct WorkServiceTerminalCommitRequest: Codable, Hashable, Sendable {
    public let operation: WorkServiceTerminalOperation
    public let work: WorkRef
    public let journal: JournalRef
    public let client: ClientRef
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let causalWorkCursor: JournalCursor
    public let detail: String?
    /// The exact command envelope, including caller/session/cursor identity, is part of the
    /// terminal transaction's durable idempotency key.
    public let command: CommandRef

    public init(operation: WorkServiceTerminalOperation, work: WorkRef, journal: JournalRef,
                client: ClientRef, session: SessionRef, sessionJournal: JournalRef,
                sessionAttachment: SessionAttachmentRef,
                causalWorkCursor: JournalCursor, detail: String?, command: CommandRef) {
        self.operation = operation
        self.work = work
        self.journal = journal
        self.client = client
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.causalWorkCursor = causalWorkCursor
        self.detail = detail
        self.command = command
    }
}

/// Production supplies this with a RunJournalBundle-backed transaction. No committer means the
/// executable reference service cannot claim that Handles and Session pairing were verified.
public protocol WorkServiceTerminalCommitter: Sendable {
    func commit(_ request: WorkServiceTerminalCommitRequest) async throws -> WorkServiceTerminalCommitProof
    /// Resolve an ambiguous prior attempt from canonical storage without appending another event.
    func committedProof(
        for request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof?
}

public extension WorkServiceTerminalCommitter {
    func committedProof(
        for request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof? { nil }
}

/// Canonical terminal adapter for a live or recently closed native journal bundle. Its lookup is
/// deliberately separate from commit so an exact retry can recover after the response was lost.
public actor RunJournalBundleWorkServiceTerminalCommitter: WorkServiceTerminalCommitter {
    private let bundle: RunJournalBundle
    private let destroyResourcesAreQuiesced: @Sendable () async -> Bool

    public init(
        bundle: RunJournalBundle,
        destroyResourcesAreQuiesced: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.bundle = bundle
        self.destroyResourcesAreQuiesced = destroyResourcesAreQuiesced
    }

    public func commit(
        _ request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof {
        if let proof = try await committedProof(for: request) { return proof }
        try validateBundleIdentity(request)
        switch request.operation {
        case .complete:
            _ = try await bundle.completeWork(detail: request.detail, command: request.command)
        case .destroy:
            let quiesced = await destroyResourcesAreQuiesced()
            _ = try await bundle.destroyWork(
                resourcesQuiesced: quiesced, reason: request.detail,
                command: request.command)
        }
        guard let proof = try await committedProof(for: request) else {
            throw WorkServiceProtocolError.invalidRequest(
                "terminal journal transaction did not produce canonical proof")
        }
        return proof
    }

    public func committedProof(
        for request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof? {
        try validateBundleIdentity(request)
        guard let record = try await bundle.terminalCommit(
            for: request.command, detail: request.detail) else { return nil }
        guard record.workEvent.type == request.operation.eventKind else {
            throw WorkServiceProtocolError.invalidRequest(
                "terminal command was already used for another operation")
        }
        let event = record.workEvent
        return WorkServiceTerminalCommitProof(
            operation: request.operation, work: request.work, journal: request.journal,
            command: request.command, causalWorkCursor: request.causalWorkCursor,
            resultingWorkCursor: record.workCommit.cursor,
            terminalEvent: WorkServiceEventDescriptor(
                eventID: event.eventID, kind: event.type, cursor: record.workCommit.cursor,
                commandID: event.command?.commandID, run: event.run,
                provenance: record.workCommit.eventRef, bodyStatus: .manifest),
            session: request.session, sessionJournal: request.sessionJournal,
            sessionAttachment: request.sessionAttachment,
            pairedSessionCursor: record.pairedSessionCommit?.cursor,
            sessionPairingVerified: record.sessionPairingVerified,
            outstandingHandleIDs: record.outstandingHandleIDs,
            commitID: event.eventID)
    }

    private func validateBundleIdentity(
        _ request: WorkServiceTerminalCommitRequest
    ) throws {
        guard request.work == bundle.work,
              request.journal == bundle.workJournal,
              request.session == bundle.session,
              request.sessionJournal == bundle.sessionJournal,
              request.sessionAttachment == bundle.sessionAttachment,
              request.command.client == request.client,
              request.command.sessionAttachment == request.sessionAttachment,
              request.command.causalCursor == request.causalWorkCursor else {
            throw WorkServiceProtocolError.invalidRequest(
                "terminal request does not name this canonical Session/Work journal pair")
        }
    }
}

private extension WorkServiceTerminalOperation {
    var eventKind: String {
        switch self {
        case .complete: return TimelineEventType.workCompleted
        case .destroy: return TimelineEventType.workDestroyed
        }
    }
}

public enum WorkServiceCommandKind: String, Codable, Hashable, Sendable {
    case start
    case send
    case steer
    case queue
    case hold
    case cancel
    case end
    case destroy
    case complete

    fileprivate var capability: WorkServiceCapability {
        switch self {
        case .start: return .start
        case .send: return .send
        case .steer: return .steer
        case .queue: return .queue
        case .hold: return .hold
        case .cancel: return .cancel
        case .end: return .end
        case .destroy: return .destroy
        case .complete: return .complete
        }
    }
}

public struct WorkServiceCommandRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let command: CommandRef
    /// Required duplicate of the command envelope's causal cursor so decoding cannot silently
    /// turn a terminal or lifecycle mutation into an unconditional operation.
    public let causalCursor: JournalCursor
    public let kind: WorkServiceCommandKind
    public let value: String?
    public let valueWasTruncated: Bool

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                commandID: String, client: ClientRef,
                sessionAttachment: SessionAttachmentRef? = nil,
                causalCursor: JournalCursor,
                kind: WorkServiceCommandKind, value: String? = nil) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.causalCursor = causalCursor
        self.command = CommandRef(commandID: commandID, client: client,
                                  sessionAttachment: sessionAttachment,
                                  causalCursor: causalCursor)
        self.kind = kind
        if let value, value.count > WorkServiceBounds.maxCommandValueCharacters {
            // Keep the caller's exact value so command identity and retries cannot collapse two
            // distinct oversized payloads onto the same prefix. The effect boundary rejects it
            // using this explicit marker and the actual count.
            self.value = value
            self.valueWasTruncated = true
        } else {
            self.value = value
            self.valueWasTruncated = false
        }
    }
}

public enum WorkServiceCommandReceiptState: String, Codable, Hashable, Sendable {
    case accepted
    case duplicate
    case rejected
}

public enum WorkServiceCommandOutcome: String, Codable, Hashable, Sendable {
    case created
    case started
    case inputAccepted = "input_accepted"
    case steeringAccepted = "steering_accepted"
    case queued
    case holdRequested = "hold_requested"
    case cancellationRequested = "cancellation_requested"
    case endRequested = "end_requested"
    case destroyed
    case completed
}

public enum WorkServiceCommandRejection: String, Codable, Hashable, Sendable {
    case malformedRequest = "malformed_request"
    case authorizationDenied = "authorization_denied"
    case staleCursor = "stale_cursor"
    case conflictingCommand = "conflicting_command"
    case sourceIncomplete = "source_incomplete"
    case invalidState = "invalid_state"
    case terminalWork = "terminal_work"
    case terminalProofUnavailable = "terminal_proof_unavailable"
}

public struct WorkServiceCommandReceipt: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let hostSequence: Int
    public let causalCursor: JournalCursor
    public let resultingCursor: JournalCursor?
    public let authorization: WorkServiceAuthorizationOutcome
    public let outcome: WorkServiceCommandOutcome?
    public let rejection: WorkServiceCommandRejection?
    public let terminalProof: WorkServiceTerminalCommitProof?
    public let diagnostic: String?

    public init(work: WorkRef, commandID: String, state: WorkServiceCommandReceiptState,
                host: WorkHostInstanceRef, hostSequence: Int,
                causalCursor: JournalCursor, resultingCursor: JournalCursor?,
                authorization: WorkServiceAuthorizationOutcome,
                outcome: WorkServiceCommandOutcome? = nil,
                rejection: WorkServiceCommandRejection? = nil,
                terminalProof: WorkServiceTerminalCommitProof? = nil,
                diagnostic: String? = nil) {
        self.work = work
        self.commandID = commandID
        self.state = state
        self.host = host
        self.hostSequence = hostSequence
        self.causalCursor = causalCursor
        self.resultingCursor = resultingCursor
        self.authorization = authorization
        self.outcome = outcome
        self.rejection = rejection
        self.terminalProof = terminalProof
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

/// A transport implementation only needs to implement this contract. Reads are cursor-based and
/// bounded; they are not a lossy push stream. Successful attach/detach operations promise that
/// the host has durably recorded the corresponding canonical client-attachment event before the
/// response is returned. ``InMemoryWorkService`` below is explicitly a conformance double: its
/// in-memory manifest models that promise but is not a durable journal implementation.
/// A local file reader may implement the same interface as an optimization, while a socket
/// implementation can use exactly these messages.
public protocol WorkServiceClient: Sendable {
    func handshake(_ request: WorkServiceHandshakeRequest) async throws -> WorkServiceHandshakeResponse
    func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage
    func describeWork(_ request: WorkServiceDescribeRequest) async throws -> WorkServiceWorkDescriptor
    func createWork(_ request: WorkServiceCreateWorkRequest) async throws -> WorkServiceCreateWorkResponse
    func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws -> WorkServiceCommandReceipt
    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse
    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse
    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot
    func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws -> WorkServiceEventPage
    func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws
        -> WorkServiceArtifactDescriptor
    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse
    func command(_ request: WorkServiceCommandRequest) async throws -> WorkServiceCommandReceipt
}

// MARK: - Deterministic reference service

/// A pure in-memory service used both as the protocol's executable specification and as a
/// loopback conformance seam.  It intentionally has no Process, PID, path, clock, or filesystem
/// dependency.  Each instance represents one Work Host; multiple clients attach to its Work
/// independently, and multiple instances can coexist in a registry.
public actor InMemoryWorkService: WorkServiceClient {
    public struct Seed: Sendable {
        public let work: WorkRef
        public let journal: JournalRef
        public let disposition: WorkServiceRecordedDisposition
        public let execution: WorkServiceExecutionState
        public let currentRun: RunRef?
        public let configuration: WorkServiceWorkConfiguration
        public let cursor: JournalCursor?
        public let sourceCompleteness: WorkServiceSourceCompleteness
        public let artifacts: [WorkServiceArtifactDescriptor]
        public let bodies: [TimelineBodyReference: Data]

        public init(work: WorkRef, journal: JournalRef,
                    disposition: WorkServiceRecordedDisposition = .reusable,
                    execution: WorkServiceExecutionState = .idle,
                    currentRun: RunRef? = nil, cursor: JournalCursor? = nil,
                    configuration: WorkServiceWorkConfiguration = .init(),
                    sourceCompleteness: WorkServiceSourceCompleteness = .complete,
                    artifacts: [WorkServiceArtifactDescriptor] = [],
                    bodies: [TimelineBodyReference: Data] = [:]) {
            self.work = work
            self.journal = journal
            self.disposition = disposition
            self.execution = execution
            self.currentRun = currentRun
            self.configuration = configuration
            self.cursor = cursor
            self.sourceCompleteness = sourceCompleteness
            self.artifacts = artifacts
            self.bodies = bodies
        }
    }

    private struct ClientState: Sendable {
        var attachment: WorkServiceClientAttachment
    }

    private struct CommandKey: Hashable, Sendable {
        let work: WorkRef
        let client: ClientRef
        let commandID: String
    }

    private struct CreateCommandKey: Hashable, Sendable {
        let work: WorkRef
        let client: ClientRef
        let commandID: String
    }

    private struct AttachmentCommandKey: Hashable, Sendable {
        let work: WorkRef
        let client: ClientRef
        let commandID: String
    }

    private struct StoredCommand: Sendable {
        let request: WorkServiceCommandRequest
        let receipt: WorkServiceCommandReceipt
    }

    private struct StoredCreate: Sendable {
        let request: WorkServiceCreateWorkRequest
        let response: WorkServiceCreateWorkResponse
    }

    private struct StoredAttach: Sendable {
        let request: WorkServiceAttachRequest
        let response: WorkServiceAttachResponse
    }

    private struct StoredDetach: Sendable {
        let request: WorkServiceDetachRequest
        let response: WorkServiceDetachResponse
    }

    private enum TerminalAttempt: Sendable {
        case proof(WorkServiceTerminalCommitProof)
        case unavailable
    }

    private enum TerminalReservationPhase: Sendable {
        case committing
        case uncertain
    }

    private struct TerminalReservation: Sendable {
        let key: CommandKey
        let request: WorkServiceCommandRequest
        let proofRequest: WorkServiceTerminalCommitRequest
        var phase: TerminalReservationPhase
        var unavailableReceipt: WorkServiceCommandReceipt?
    }

    public let host: WorkHostRef
    public let hostInstance: WorkHostInstanceRef
    private let authorizer: any WorkServiceAuthorizer
    private let terminalCommitter: (any WorkServiceTerminalCommitter)?
    private var reachable = true
    private var works: [WorkRef: WorkState] = [:]
    private var createCommands: [CreateCommandKey: StoredCreate] = [:]
    private var attachCommands: [AttachmentCommandKey: StoredAttach] = [:]
    private var detachCommands: [AttachmentCommandKey: StoredDetach] = [:]
    private var terminalTasks: [WorkRef: Task<TerminalAttempt, Never>] = [:]
    private var nextAttachmentOrdinal = 1

    private struct WorkState: Sendable {
        let work: WorkRef
        let journal: JournalRef
        var disposition: WorkServiceRecordedDisposition
        var execution: WorkServiceExecutionState
        var currentRun: RunRef?
        var configuration: WorkServiceWorkConfiguration
        var cursor: JournalCursor?
        var sourceCompleteness: WorkServiceSourceCompleteness
        var artifacts: [WorkServiceArtifactDescriptor]
        var bodies: [TimelineBodyReference: Data]
        var omissions: [WorkServiceOmission]
        var attachments: [ClientAttachmentRef: ClientState]
        var events: [WorkServiceEventDescriptor]
        var nextEventSequence: Int
        var nextRunOrdinal: Int
        var nextHostSequence: Int
        var commands: [CommandKey: StoredCommand]
        var terminalReservation: TerminalReservation?
    }

    public init(host: WorkHostRef, instanceID: String = "instance-1",
                startIdentity: String = "start-1",
                authorizer: any WorkServiceAuthorizer,
                terminalCommitter: (any WorkServiceTerminalCommitter)? = nil) {
        self.host = host
        self.hostInstance = WorkHostInstanceRef(host: host, instanceID: instanceID,
                                                startIdentity: startIdentity)
        self.authorizer = authorizer
        self.terminalCommitter = terminalCommitter
    }

    public func register(_ seed: Seed) throws {
        guard seed.work.workHostID == host.workHostID,
              seed.journal.owner == .work(seed.work),
              seed.journal.authority.authorityID == host.workHostID,
              seed.journal.kind == .work else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard WorkServiceText.valid(seed.work.workHostID), seed.work.workHostID.count <= WorkServiceBounds.maxIdentityCharacters,
              WorkServiceText.valid(seed.work.workID), seed.work.workID.count <= WorkServiceBounds.maxIdentityCharacters,
              WorkServiceText.valid(seed.journal.journalID), seed.journal.journalID.count <= WorkServiceBounds.maxIdentityCharacters,
              seed.journal.authority.authorityID.count <= WorkServiceBounds.maxIdentityCharacters,
              (seed.cursor?.journal == nil || seed.cursor?.journal == seed.journal),
              (seed.cursor?.sequence ?? 0) >= 0, (seed.cursor?.sequence ?? 0) < Int.max,
              (seed.cursor?.sequence ?? 0) != 0 || seed.cursor?.eventID == nil,
              (seed.cursor?.sequence ?? 0) == 0 || (seed.cursor?.eventID.map(validIdentity) ?? false),
              (seed.artifacts.allSatisfy {
                  validIdentity($0.artifactID)
                      && ($0.bodyReference.map { validBodyReference($0, journal: seed.journal) } ?? true)
              }),
              (seed.bodies.keys.allSatisfy { validBodyReference($0, journal: seed.journal) }),
              !seed.configuration.hasInvalidBodyBounds else {
            throw WorkServiceProtocolError.invalidRequest("invalid Work or cursor identity")
        }
        let cursor = seed.cursor ?? JournalCursor(journal: seed.journal, sequence: 0)
        guard cursor.sequence == 0 || seed.sourceCompleteness != .complete else {
            throw WorkServiceProtocolError.invalidRequest(
                "a complete nonzero seed requires retained event history")
        }
        guard seed.disposition == .reusable
                || (seed.execution == .idle && seed.currentRun == nil) else {
            throw WorkServiceProtocolError.invalidRequest("invalid execution/run combination")
        }
        guard Set(seed.artifacts.map { $0.artifactID }).count == seed.artifacts.count else {
            throw WorkServiceProtocolError.invalidRequest("duplicate artifact identity")
        }
        guard !works.keys.contains(seed.work) else {
            throw WorkServiceProtocolError.invalidRequest("duplicate Work identity")
        }
        let artifacts = Array(seed.artifacts.prefix(WorkServiceBounds.maxArtifactsPerWork))
        var omissions: [WorkServiceOmission] = []
        if cursor.sequence > 0 {
            omissions.append(WorkServiceOmission(
                category: "event_history", count: cursor.sequence,
                diagnostic: "events before the retained seed cursor are not available from this host"))
        }
        if seed.artifacts.count > artifacts.count {
            omissions.append(WorkServiceOmission(category: "artifacts", count: seed.artifacts.count - artifacts.count))
        }
        let truncatedMetadata = artifacts.filter(\.metadataWasTruncated).count
        if truncatedMetadata > 0 {
            omissions.append(WorkServiceOmission(
                category: "artifact_metadata", count: truncatedMetadata,
                diagnostic: "artifact display metadata was shortened to the protocol bound"))
        }
        works[seed.work] = WorkState(
            work: seed.work, journal: seed.journal, disposition: seed.disposition,
            execution: seed.execution, currentRun: seed.currentRun, configuration: seed.configuration, cursor: cursor,
            sourceCompleteness: seed.sourceCompleteness, artifacts: artifacts, bodies: seed.bodies,
            omissions: omissions,
            attachments: [:],
            events: [], nextEventSequence: cursor.sequence + 1,
            nextRunOrdinal: 1, nextHostSequence: 1, commands: [:], terminalReservation: nil)
    }

    public func setReachable(_ value: Bool) {
        reachable = value
    }

    public func handshake(_ request: WorkServiceHandshakeRequest) async throws -> WorkServiceHandshakeResponse {
        guard WorkServiceText.valid(request.client.clientID), request.client.clientID.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceProtocolError.invalidRequest("invalid client identity")
        }
        let accepted = (WorkServiceProtocol.minimumSupportedVersion...WorkServiceProtocol.maximumSupportedVersion)
            .contains(request.protocolVersion)
        if !accepted { throw WorkServiceProtocolError.unsupportedVersion(request.protocolVersion) }
        return WorkServiceHandshakeResponse(
            accepted: true, negotiatedVersion: request.protocolVersion,
            supportedRange: WorkServiceProtocol.minimumSupportedVersion...WorkServiceProtocol.maximumSupportedVersion,
            host: host, hostInstance: hostInstance,
            capabilities: supportedCapabilities())
    }

    public func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        try requireReachable()
        guard validIdentity(request.client.clientID) else {
            throw WorkServiceProtocolError.invalidRequest("invalid client identity")
        }
        guard authorization(for: request.client, requested: [.observe]).allows(.observe) else {
            throw WorkServiceProtocolError.capabilityDenied(.observe)
        }
        let pageSize = try boundedPageSize(request.pageSize, max: WorkServiceBounds.maxPageSize)
        let start = try pageOffset(request.pageToken)
        let ordered = works.keys.sorted { Self.precedes($0, $1) }
        let pageKeys = Array(ordered.dropFirst(start).prefix(pageSize))
        let next = start + pageKeys.count < ordered.count ? String(start + pageKeys.count) : nil
        let rows = pageKeys.compactMap { descriptor(for: $0, includeObservation: true) }
        var omissions: [WorkServiceOmission] = []
        if rows.count < pageKeys.count {
            omissions.append(WorkServiceOmission(category: "work_rows", count: pageKeys.count - rows.count))
        }
        return WorkServiceWorkPage(works: rows, nextPageToken: next, omissions: omissions)
    }

    public func describeWork(_ request: WorkServiceDescribeRequest) async throws -> WorkServiceWorkDescriptor {
        try requireReachable()
        guard validIdentity(request.client.clientID) else {
            throw WorkServiceProtocolError.invalidRequest("invalid client identity")
        }
        guard authorization(for: request.client, requested: [.observe]).allows(.observe) else {
            throw WorkServiceProtocolError.capabilityDenied(.observe)
        }
        guard let state = works[request.work] else { throw WorkServiceProtocolError.workNotFound(request.work) }
        guard request.journal == state.journal else { throw WorkServiceProtocolError.journalMismatch }
        return descriptor(for: state.work, includeObservation: true)!
    }

    public func createWork(_ request: WorkServiceCreateWorkRequest) async throws -> WorkServiceCreateWorkResponse {
        try requireReachable()
        guard validIdentity(request.client.clientID) else {
            throw WorkServiceProtocolError.invalidRequest("invalid client identity")
        }
        guard validIdentity(request.commandID), request.commandID.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceProtocolError.invalidRequest("invalid create command identity")
        }
        guard !request.configuration.hasInvalidBodyBounds else {
            throw WorkServiceProtocolError.invalidRequest("Work configuration exceeds a bounded body limit")
        }
        guard request.work.workHostID == host.workHostID,
              request.journal.owner == .work(request.work),
              request.journal.authority.authorityID == host.workHostID else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard request.causalCursor.journal == request.journal,
              request.causalCursor.sequence == 0,
              request.causalCursor.eventID == nil else {
            throw WorkServiceProtocolError.invalidRequest(
                "create must carry the exact empty-journal causal cursor")
        }
        let authorization = authorization(
            for: request.client, requested: request.requestedCapabilities)
        guard authorization.allows(.control) else {
            throw WorkServiceProtocolError.capabilityDenied(.control)
        }
        let createKey = CreateCommandKey(
            work: request.work, client: request.client, commandID: request.commandID)
        if let prior = createCommands[createKey] {
            guard prior.request == request else {
                throw WorkServiceProtocolError.invalidRequest("create command ID was already used with different contents")
            }
            return prior.response
        }
        try register(.init(work: request.work, journal: request.journal,
                           configuration: request.configuration))
        guard var state = works[request.work] else {
            throw WorkServiceProtocolError.workNotFound(request.work)
        }
        _ = appendEvent(kind: "work.created", commandID: request.commandID, state: &state)
        let resultingCursor = state.cursor
        let hostSequence = state.nextHostSequence
        state.nextHostSequence += 1
        let receipt = WorkServiceCommandReceipt(
            work: state.work, commandID: request.commandID, state: .accepted,
            host: hostInstance, hostSequence: hostSequence,
            causalCursor: request.causalCursor, resultingCursor: resultingCursor,
            authorization: authorization, outcome: .created)
        works[request.work] = state
        let response = WorkServiceCreateWorkResponse(
            work: try await describeWork(.init(
                work: request.work, journal: request.journal, client: request.client)),
            authorization: authorization, receipt: receipt)
        createCommands[createKey] = StoredCreate(request: request, response: response)
        return response
    }

    public func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws -> WorkServiceCommandReceipt {
        guard let client = request.command.client else {
            throw WorkServiceProtocolError.invalidRequest("completion must carry a client identity")
        }
        guard request.command.causalCursor == request.causalCursor else {
            throw WorkServiceProtocolError.invalidRequest("completion causal cursor is inconsistent")
        }
        let command = WorkServiceCommandRequest(
            work: request.work, journal: request.journal, attachment: request.attachment,
            commandID: request.command.commandID, client: client,
            sessionAttachment: request.command.sessionAttachment,
            causalCursor: request.causalCursor, kind: .complete)
        return try await self.command(command)
    }

    public func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        try requireReachable()
        guard var state = works[request.work] else { throw WorkServiceProtocolError.workNotFound(request.work) }
        guard request.journal == state.journal else { throw WorkServiceProtocolError.journalMismatch }
        guard validIdentity(request.client.clientID), validIdentity(request.commandID) else {
            throw WorkServiceProtocolError.invalidRequest("invalid client identity")
        }
        let key = AttachmentCommandKey(work: request.work, client: request.client,
                                       commandID: request.commandID)
        if let prior = attachCommands[key] {
            guard prior.request == request else {
                return WorkServiceAttachResponse(
                    work: prior.response.work, attachment: nil,
                    authorization: prior.response.authorization, commandID: request.commandID,
                    state: .rejected, host: prior.response.host,
                    hostSequence: prior.response.hostSequence,
                    resultingCursor: prior.response.resultingCursor,
                    rejection: .conflictingCommand,
                    diagnostic: "attachment command ID was already used with different contents")
            }
            return WorkServiceAttachResponse(
                work: prior.response.work, attachment: prior.response.attachment,
                authorization: prior.response.authorization, commandID: request.commandID,
                state: prior.response.state == .rejected ? .rejected : .duplicate,
                host: prior.response.host,
                hostSequence: prior.response.hostSequence,
                resultingCursor: prior.response.resultingCursor,
                rejection: prior.response.rejection,
                diagnostic: prior.response.state == .rejected
                    ? prior.response.diagnostic : "idempotent duplicate")
        }
        guard (request.session == nil) == (request.sessionAttachment == nil),
              (request.session == nil) == (request.sessionJournal == nil),
              (request.session.map { validIdentity($0.sessionID) } ?? true),
              (request.sessionJournal.map {
                  $0.kind == .session && $0.owner == .session(request.session!)
              } ?? true),
              (request.sessionAttachment.map { validIdentity($0.attachmentID) } ?? true) else {
            throw WorkServiceProtocolError.invalidRequest(
                "Session, Session journal, and attachment identity must be complete and bounded")
        }
        let authorization = authorization(
            for: request.client, requested: request.requestedCapabilities)
        if state.terminalReservation != nil {
            let response = WorkServiceAttachResponse(
                work: descriptor(for: state.work, includeObservation: true)!, attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, hostSequence: max(0, state.nextHostSequence - 1),
                resultingCursor: state.cursor, rejection: .terminalProofUnavailable,
                diagnostic: "a terminal Work transaction is already in progress")
            attachCommands[key] = StoredAttach(request: request, response: response)
            works[state.work] = state
            return response
        }
        guard state.sourceCompleteness == .complete else {
            let response = WorkServiceAttachResponse(
                work: descriptor(for: state.work, includeObservation: true)!, attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, hostSequence: max(0, state.nextHostSequence - 1),
                resultingCursor: state.cursor, rejection: .sourceIncomplete,
                diagnostic: "host source is not complete enough to attach canonically")
            attachCommands[key] = StoredAttach(request: request, response: response)
            // No attachment, event, cursor, or host-order mutation is claimed.
            works[state.work] = state
            return response
        }
        if request.causalCursor != state.cursor {
            let hostSequence = state.nextHostSequence
            state.nextHostSequence += 1
            let response = WorkServiceAttachResponse(
                work: descriptor(for: state.work, includeObservation: true)!, attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, hostSequence: hostSequence, resultingCursor: state.cursor,
                rejection: .staleCursor, diagnostic: "attach causal cursor is not current")
            attachCommands[key] = StoredAttach(request: request, response: response)
            works[state.work] = state
            return response
        }
        let id = ClientAttachmentRef("attachment-\(nextAttachmentOrdinal)")
        nextAttachmentOrdinal += 1
        var attachment = WorkServiceClientAttachment(
            attachment: id, client: request.client, session: request.session,
            sessionJournal: request.sessionJournal,
            sessionAttachment: request.sessionAttachment, authorization: authorization,
            cursor: state.cursor)
        state.attachments[id] = ClientState(attachment: attachment)
        // A production service must append the canonical attachment event before returning.
        // The reference service models that event in its cursor-based manifest.
        let eventCursor = appendEvent(kind: "client_attachment.attached",
                                      commandID: request.commandID, state: &state)
        let hostSequence = state.nextHostSequence
        state.nextHostSequence += 1
        attachment = WorkServiceClientAttachment(
            attachment: id, client: request.client, session: request.session,
            sessionJournal: request.sessionJournal,
            sessionAttachment: request.sessionAttachment, authorization: authorization,
            cursor: state.cursor)
        state.attachments[id] = ClientState(attachment: attachment)
        works[request.work] = state
        let response = WorkServiceAttachResponse(
            work: descriptor(for: state.work, includeObservation: true)!,
            attachment: attachment, authorization: authorization,
            commandID: request.commandID, host: hostInstance, hostSequence: hostSequence,
            resultingCursor: eventCursor)
        attachCommands[key] = StoredAttach(request: request, response: response)
        return response
    }

    public func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        try requireReachable()
        guard var state = works[request.work] else { throw WorkServiceProtocolError.workNotFound(request.work) }
        guard request.journal == state.journal else { throw WorkServiceProtocolError.journalMismatch }
        guard validIdentity(request.client.clientID), validIdentity(request.commandID) else {
            throw WorkServiceProtocolError.invalidRequest("invalid detach client or command identity")
        }
        let key = AttachmentCommandKey(work: request.work, client: request.client,
                                       commandID: request.commandID)
        if let prior = detachCommands[key] {
            guard prior.request == request else {
                return WorkServiceDetachResponse(
                    work: prior.response.work, commandID: request.commandID, state: .rejected,
                    host: prior.response.host, hostSequence: prior.response.hostSequence,
                    causalCursor: prior.response.causalCursor,
                    resultingCursor: prior.response.resultingCursor,
                    rejection: .conflictingCommand,
                    diagnostic: "detach command ID was already used with different contents")
            }
            return WorkServiceDetachResponse(
                work: prior.response.work, commandID: request.commandID,
                state: prior.response.state == .rejected ? .rejected : .duplicate,
                host: prior.response.host, hostSequence: prior.response.hostSequence,
                causalCursor: prior.response.causalCursor,
                resultingCursor: prior.response.resultingCursor,
                rejection: prior.response.rejection,
                diagnostic: prior.response.state == .rejected
                    ? prior.response.diagnostic : "idempotent duplicate")
        }
        guard let client = state.attachments[request.attachment], client.attachment.client == request.client else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        if state.terminalReservation != nil {
            let response = WorkServiceDetachResponse(
                work: request.work, commandID: request.commandID, state: .rejected,
                host: hostInstance, hostSequence: max(0, state.nextHostSequence - 1),
                causalCursor: request.causalCursor, resultingCursor: state.cursor,
                rejection: .terminalProofUnavailable,
                diagnostic: "a terminal Work transaction is already in progress")
            detachCommands[key] = StoredDetach(request: request, response: response)
            works[state.work] = state
            return response
        }
        guard state.sourceCompleteness == .complete else {
            let response = WorkServiceDetachResponse(
                work: request.work, commandID: request.commandID, state: .rejected,
                host: hostInstance, hostSequence: max(0, state.nextHostSequence - 1),
                causalCursor: request.causalCursor, resultingCursor: state.cursor,
                rejection: .sourceIncomplete,
                diagnostic: "host source is not complete enough to detach canonically")
            detachCommands[key] = StoredDetach(request: request, response: response)
            // No event, attachment, cursor, or host-order mutation is claimed.
            works[state.work] = state
            return response
        }
        if request.causalCursor != state.cursor {
            let hostSequence = state.nextHostSequence
            state.nextHostSequence += 1
            let response = WorkServiceDetachResponse(
                work: request.work, commandID: request.commandID, state: .rejected,
                host: hostInstance, hostSequence: hostSequence,
                causalCursor: request.causalCursor, resultingCursor: state.cursor,
                rejection: .staleCursor, diagnostic: "detach causal cursor is not current")
            detachCommands[key] = StoredDetach(request: request, response: response)
            works[state.work] = state
            return response
        }
        // A production service must append the canonical detach event before acknowledging.
        let eventCursor = appendEvent(kind: "client_attachment.detached",
                                      commandID: request.commandID, state: &state)
        let hostSequence = state.nextHostSequence
        state.nextHostSequence += 1
        state.attachments.removeValue(forKey: request.attachment)
        works[request.work] = state
        let response = WorkServiceDetachResponse(
            work: request.work, commandID: request.commandID, state: .accepted,
            host: hostInstance, hostSequence: hostSequence,
            causalCursor: request.causalCursor, resultingCursor: eventCursor)
        detachCommands[key] = StoredDetach(request: request, response: response)
        return response
    }

    public func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        try requireReachable()
        var state = try attachedState(work: request.work, journal: request.journal,
                                      attachment: request.attachment, client: request.client,
                                      requiring: .observe)
        let after = try validatedAfter(request.afterCursor, state: state)
        let limit = try boundedPageSize(request.limit, max: WorkServiceBounds.maxEventsPerPage)
        let events = Array(state.events.filter { $0.cursor.sequence > after }.prefix(limit))
        let next = events.last?.cursor
        var omissions: [WorkServiceOmission] = []
        if state.events.contains(where: { $0.cursor.sequence > (next?.sequence ?? after) }) {
            omissions.append(WorkServiceOmission(category: "events", count: 1, diagnostic: "more events available"))
        }
        let servedCursor = events.last?.cursor
            ?? state.attachments[request.attachment]?.attachment.cursor
        updateClientCursor(request.attachment, to: servedCursor, state: &state)
        let deliveredCursor = state.attachments[request.attachment]?.attachment.cursor
        works[state.work] = state
        return WorkServiceSnapshot(work: descriptor(for: state.work, includeObservation: true)!,
                                   events: events, servedCursor: deliveredCursor, omissions: omissions)
    }

    public func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws -> WorkServiceEventPage {
        try requireReachable()
        var state = try attachedState(work: request.work, journal: request.journal,
                                      attachment: request.attachment, client: request.client,
                                      requiring: .observe)
        let after = try validatedAfter(request.afterCursor, state: state)
        let limit = try boundedPageSize(request.limit, max: WorkServiceBounds.maxEventsPerPage)
        let available = state.events.filter { $0.cursor.sequence > after }
        let events = Array(available.prefix(limit))
        let next = events.last?.cursor
        let hasMore = available.count > events.count
        let servedCursor = events.last?.cursor
            ?? state.attachments[request.attachment]?.attachment.cursor
        updateClientCursor(request.attachment, to: servedCursor, state: &state)
        let deliveredCursor = state.attachments[request.attachment]?.attachment.cursor
        works[state.work] = state
        return WorkServiceEventPage(
            events: events, servedCursor: deliveredCursor, nextCursor: hasMore ? next : nil,
            omissions: hasMore ? [WorkServiceOmission(category: "events", count: available.count - events.count)] : [])
    }

    public func fetchArtifact(
        _ request: WorkServiceArtifactRequest
    ) async throws -> WorkServiceArtifactDescriptor {
        try requireReachable()
        guard validIdentity(request.artifactID) else {
            throw WorkServiceProtocolError.invalidRequest("artifact identity is not bounded")
        }
        let state = try attachedState(work: request.work, journal: request.journal,
                                      attachment: request.attachment, client: request.client,
                                      requiring: .inspectArtifacts)
        guard let artifact = state.artifacts.first(where: { $0.artifactID == request.artifactID }) else {
            throw WorkServiceProtocolError.artifactNotFound
        }
        return artifact
    }

    public func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        try requireReachable()
        // Conversation event bodies are observable so a remote GUI can reconstruct the timeline.
        // Artifact bodies are sensitive and are therefore covered by the artifact inspection
        // capability, even though their references may be visible in an observe-only descriptor.
        let state = try attachedState(work: request.work, journal: request.journal,
                                      attachment: request.attachment, client: request.client,
                                      requiring: .observe)
        guard request.reference.authority == state.journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard validBodyReference(request.reference, journal: state.journal) else {
            throw WorkServiceProtocolError.invalidRequest("body reference identity is not bounded")
        }
        if state.artifacts.contains(where: { $0.bodyReference == request.reference }),
           !(state.attachments[request.attachment]?.attachment.authorization.allows(.inspectArtifacts) ?? false) {
            throw WorkServiceProtocolError.capabilityDenied(.inspectArtifacts)
        }
        guard request.offset >= 0, request.limit > 0 else {
            throw WorkServiceProtocolError.invalidRequest("body offset and limit must be positive")
        }
        if let digest = request.reference.digest, !ContextBodyStore.isValidDigest(digest) {
            return WorkServiceBodyResponse(reference: request.reference, status: .unavailable,
                                           offset: request.offset,
                                           diagnostic: "body digest is not a valid SHA-256 identity")
        }
        let limit = min(request.limit, WorkServiceBounds.maxBodyChunkBytes)
        guard let body = state.bodies[request.reference] else {
            return WorkServiceBodyResponse(reference: request.reference, status: .unavailable,
                                           offset: request.offset,
                                           diagnostic: "body is not retained by this Work Host")
        }
        guard request.reference.byteCount == nil || request.reference.byteCount == body.count else {
            return WorkServiceBodyResponse(reference: request.reference, status: .unavailable,
                                           offset: request.offset,
                                           diagnostic: "retained body metadata does not match")
        }
        if let digest = request.reference.digest, WorkServiceText.digest(body) != digest {
            return WorkServiceBodyResponse(reference: request.reference, status: .unavailable,
                                           offset: request.offset,
                                           diagnostic: "retained body digest does not match")
        }
        guard request.offset <= body.count else {
            throw WorkServiceProtocolError.invalidRequest("body offset is beyond retained body")
        }
        // Bound the addition by the remaining body length so a hostile offset/limit pair cannot
        // overflow an integer before the chunk is capped.
        let end = request.offset + min(limit, body.count - request.offset)
        let chunk = body.subdata(in: request.offset..<end)
        return WorkServiceBodyResponse(
            reference: request.reference, status: .retained, offset: request.offset,
            data: chunk, nextOffset: end < body.count ? end : nil)
    }

    public func command(_ request: WorkServiceCommandRequest) async throws -> WorkServiceCommandReceipt {
        try requireReachable()
        guard var state = works[request.work] else { throw WorkServiceProtocolError.workNotFound(request.work) }
        guard request.journal == state.journal else { throw WorkServiceProtocolError.journalMismatch }
        guard validIdentity(request.command.commandID), request.command.commandID.count <= WorkServiceBounds.maxIdentityCharacters,
              let clientID = request.command.client,
              request.command.causalCursor == request.causalCursor else {
            throw WorkServiceProtocolError.invalidRequest("command must carry a bounded client and command identity")
        }
        guard let clientState = state.attachments[request.attachment], clientState.attachment.client == clientID else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        let key = CommandKey(work: request.work, client: clientID,
                             commandID: request.command.commandID)
        if let prior = state.commands[key] {
            if prior.request == request { return WorkServiceCommandReceipt(
                work: prior.receipt.work, commandID: prior.receipt.commandID,
                state: prior.receipt.state == .rejected ? .rejected : .duplicate,
                host: prior.receipt.host, hostSequence: prior.receipt.hostSequence,
                causalCursor: prior.receipt.causalCursor, resultingCursor: prior.receipt.resultingCursor,
                authorization: prior.receipt.authorization, outcome: prior.receipt.outcome,
                rejection: prior.receipt.rejection, terminalProof: prior.receipt.terminalProof,
                diagnostic: prior.receipt.state == .rejected
                    ? prior.receipt.diagnostic : "idempotent duplicate") }
            let auth = prior.receipt.authorization
            let receipt = makeReceipt(state: &state, request: request, authorization: auth,
                                      state: .rejected, rejection: .conflictingCommand,
                                      diagnostic: "command ID was already used with different contents")
            works[state.work] = state
            return receipt
        }
        if let reservation = state.terminalReservation {
            if reservation.key == key && reservation.request == request {
                return await awaitTerminalReservation(
                    work: state.work, key: key,
                    authorization: clientState.attachment.authorization)
            }
            let receipt = makeReceipt(
                state: &state, request: request,
                authorization: clientState.attachment.authorization,
                state: .rejected, rejection: .terminalProofUnavailable,
                diagnostic: "a terminal Work transaction is already in progress")
            if reservation.key != key {
                state.commands[key] = StoredCommand(request: request, receipt: receipt)
            }
            works[state.work] = state
            return receipt
        }
        if request.valueWasTruncated
            || (request.value?.count ?? 0) > WorkServiceBounds.maxCommandValueCharacters {
            let authorization = clientState.attachment.authorization
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: .malformedRequest,
                                      diagnostic: "command value exceeds the bounded command body limit")
            state.commands[CommandKey(work: request.work, client: clientID,
                                      commandID: request.command.commandID)] =
                StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }

        let authorization = clientState.attachment.authorization
        let required = request.kind.capability
        if !authorization.allows(.control) {
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: .authorizationDenied,
                                      diagnostic: "client authorization does not grant this command")
            state.commands[key] = StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }
        if !authorization.allows(required) {
            let rejection: WorkServiceCommandRejection =
                (request.kind == .complete || request.kind == .destroy) && terminalCommitter == nil
                    ? .terminalProofUnavailable : .authorizationDenied
            let diagnostic = rejection == .terminalProofUnavailable
                ? "terminal Work requires a canonical commit proof"
                : "client authorization does not grant this command"
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: rejection, diagnostic: diagnostic)
            state.commands[key] = StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }
        if state.sourceCompleteness != .complete {
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: .sourceIncomplete,
                                      diagnostic: "host source is not complete enough to control Work")
            state.commands[key] = StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }
        let causal = request.causalCursor
        guard causal.journal == state.journal, causal == state.cursor else {
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: .staleCursor,
                                      diagnostic: "command causal cursor is not the current Work cursor")
            state.commands[key] = StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }
        guard state.disposition == .reusable else {
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: .terminalWork,
                                      diagnostic: "terminal Work refuses mutation")
            state.commands[key] = StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }
        guard request.kind != .complete && request.kind != .destroy
            || state.execution == .idle else {
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: .invalidState,
                                      diagnostic: "command is not valid for the current execution state")
            state.commands[key] = StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }
        if request.kind == .complete || request.kind == .destroy {
            guard let committer = terminalCommitter else {
                let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                          state: .rejected, rejection: .terminalProofUnavailable,
                                          diagnostic: "terminal Work requires a canonical commit proof")
                state.commands[key] = StoredCommand(request: request, receipt: receipt)
                works[state.work] = state
                return receipt
            }
            guard let session = clientState.attachment.session,
                  let sessionJournal = clientState.attachment.sessionJournal,
                  let sessionAttachment = request.command.sessionAttachment else {
                let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                          state: .rejected, rejection: .terminalProofUnavailable,
                                          diagnostic: "terminal Work requires a paired Session attachment")
                state.commands[key] = StoredCommand(request: request, receipt: receipt)
                works[state.work] = state
                return receipt
            }
            // A terminal proof must belong to the durable Session relationship represented by
            // this client attachment. A command cannot self-claim a different Session merely by
            // putting another attachment ID in its envelope.
            guard clientState.attachment.sessionAttachment == sessionAttachment else {
                let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                          state: .rejected, rejection: .terminalProofUnavailable,
                                          diagnostic: "terminal proof Session attachment does not match client attachment")
                state.commands[key] = StoredCommand(request: request, receipt: receipt)
                works[state.work] = state
                return receipt
            }
            let operation: WorkServiceTerminalOperation = request.kind == .complete ? .complete : .destroy
            let proofRequest = WorkServiceTerminalCommitRequest(
                operation: operation, work: state.work, journal: state.journal,
                client: clientID, session: session, sessionJournal: sessionJournal,
                sessionAttachment: sessionAttachment,
                causalWorkCursor: causal, detail: request.value, command: request.command)
            state.terminalReservation = TerminalReservation(
                key: key, request: request, proofRequest: proofRequest,
                phase: .committing, unavailableReceipt: nil)
            works[state.work] = state
            let task = makeTerminalTask(committer: committer, request: proofRequest, commit: true)
            terminalTasks[state.work] = task
            return await awaitTerminalReservation(
                work: state.work, key: key, authorization: authorization)
        }
        guard let outcome = apply(request.kind, to: &state, value: request.value) else {
            let receipt = makeReceipt(state: &state, request: request, authorization: authorization,
                                      state: .rejected, rejection: .invalidState,
                                      diagnostic: "command is not valid for the current execution state")
            state.commands[key] = StoredCommand(request: request, receipt: receipt)
            works[state.work] = state
            return receipt
        }
        let eventCursor = appendEvent(
            kind: request.kind.rawValue, commandID: request.command.commandID,
            body: request.value, state: &state)
        let hostSequence = state.nextHostSequence
        state.nextHostSequence += 1
        let receipt = WorkServiceCommandReceipt(
            work: state.work, commandID: request.command.commandID, state: .accepted,
            host: hostInstance, hostSequence: hostSequence,
            causalCursor: request.causalCursor, resultingCursor: eventCursor,
            authorization: authorization, outcome: outcome)
        state.commands[key] = StoredCommand(request: request, receipt: receipt)
        works[state.work] = state
        return receipt
    }

    /// Models the durable `run.finished` event.  Finished runs return Work to idle/reusable; the
    /// Work object remains addressable and can be started again. This is distinct from the
    /// authenticated completeWork operation, which models explicit work.completed.
    public func finishRun(_ run: RunRef, for work: WorkRef) throws {
        try requireReachable()
        guard var state = works[work] else { throw WorkServiceProtocolError.workNotFound(work) }
        guard state.sourceCompleteness == .complete else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        guard state.currentRun == run else { throw WorkServiceProtocolError.invalidRequest("run is not current") }
        guard state.execution == .running || state.execution == .held || state.execution == .canceling || state.execution == .ending else {
            throw WorkServiceProtocolError.invalidRequest("run is not finishable")
        }
        state.execution = .idle
        state.currentRun = nil
        _ = appendEvent(kind: "run.finished", commandID: nil, state: &state)
        works[work] = state
    }

    /// Models explicit `work.completed`. Completion is immutable and cannot later be destroyed;
    /// destruction is an alternative terminal transition for reusable Work.
    private func requireReachable() throws {
        guard reachable else { throw WorkServiceProtocolError.hostUnavailable(host) }
    }

    private func supportedCapabilities() -> Set<WorkServiceCapability> {
        var capabilities = Set(WorkServiceCapability.allCases)
        // Complete/destroy are only executable when a host can prove canonical Handle
        // quiescence and paired-Session cursor success. The absence is observable at handshake,
        // while a committer can still reject an individual proof later.
        if terminalCommitter == nil {
            capabilities.remove(.complete)
            capabilities.remove(.destroy)
        }
        return capabilities
    }

    private func authorization(
        for client: ClientRef, requested: Set<WorkServiceCapability>
    ) -> WorkServiceAuthorizationOutcome {
        let policy = authorizer.authorization(for: client, requested: requested)
        let granted = policy.granted
            .intersection(requested)
            .intersection(supportedCapabilities())
        let denied = requested.subtracting(granted)
        return WorkServiceAuthorizationOutcome(
            requested: requested, granted: granted, denied: denied,
            diagnostic: denied.isEmpty ? nil : "principal or host is not authorized for one or more capabilities")
    }

    private func validIdentity(_ value: String) -> Bool {
        WorkServiceText.valid(value) && value.count <= WorkServiceBounds.maxIdentityCharacters
    }

    private func validBodyReference(_ reference: TimelineBodyReference, journal: JournalRef) -> Bool {
        reference.authority == journal
            && validIdentity(reference.referenceID)
            && (reference.mediaType?.count ?? 0) <= WorkServiceBounds.maxDiagnosticCharacters
            && (reference.byteCount == nil || (reference.byteCount ?? -1) >= 0)
            && (reference.digest == nil || ContextBodyStore.isValidDigest(reference.digest ?? ""))
    }

    private func boundedPageSize(_ requested: Int, max: Int) throws -> Int {
        guard requested > 0 else { throw WorkServiceProtocolError.invalidRequest("page size must be positive") }
        return min(requested, max)
    }

    private func pageOffset(_ token: String?) throws -> Int {
        guard let token else { return 0 }
        guard let offset = Int(token), offset >= 0, offset <= works.count else {
            throw WorkServiceProtocolError.invalidRequest("invalid page token")
        }
        return offset
    }

    private func validatedAfter(_ after: JournalCursor?, state: WorkState) throws -> Int {
        guard let after else { return 0 }
        guard after.journal == state.journal, after.sequence >= 0,
              after.sequence <= (state.cursor?.sequence ?? 0) else {
            throw WorkServiceProtocolError.invalidRequest("cursor is foreign or ahead")
        }
        // Sequence alone is not an event identity. The zero baseline is the only cursor that
        // may omit an event ID; every non-baseline cursor must name an event, even when the host
        // has compacted the event body and can only continue from its exact tip.
        if after.sequence == 0 {
            guard after.eventID == nil else {
                throw WorkServiceProtocolError.invalidRequest("baseline cursor must not carry an event identity")
            }
            return 0
        }
        guard let eventID = after.eventID, validIdentity(eventID) else {
            throw WorkServiceProtocolError.invalidRequest("non-baseline cursor must carry an event identity")
        }
        if after == state.cursor { return after.sequence }
        guard let event = state.events.first(where: { $0.cursor.sequence == after.sequence }),
              event.cursor == after else {
            throw WorkServiceProtocolError.invalidRequest("cursor event identity is unknown")
        }
        return after.sequence
    }

    private func attachedState(work: WorkRef, journal: JournalRef,
                               attachment: ClientAttachmentRef,
                               client: ClientRef,
                               requiring capability: WorkServiceCapability) throws -> WorkState {
        guard let state = works[work] else { throw WorkServiceProtocolError.workNotFound(work) }
        guard state.journal == journal else { throw WorkServiceProtocolError.journalMismatch }
        guard let attachmentState = state.attachments[attachment],
              attachmentState.attachment.client == client else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        guard attachmentState.attachment.authorization.allows(capability) else {
            throw WorkServiceProtocolError.capabilityDenied(capability)
        }
        return state
    }

    private func updateClientCursor(_ attachment: ClientAttachmentRef, to cursor: JournalCursor?,
                                    state: inout WorkState) {
        guard let cursor, let current = state.attachments[attachment] else { return }
        let observed = current.attachment.cursor.map { $0.sequence >= cursor.sequence ? $0 : cursor } ?? cursor
        state.attachments[attachment] = ClientState(attachment: WorkServiceClientAttachment(
            attachment: current.attachment.attachment, client: current.attachment.client,
            session: current.attachment.session, sessionJournal: current.attachment.sessionJournal,
            sessionAttachment: current.attachment.sessionAttachment,
            authorization: current.attachment.authorization, cursor: observed))
    }

    private func descriptor(for work: WorkRef, includeObservation: Bool) -> WorkServiceWorkDescriptor? {
        guard let state = works[work] else { return nil }
        let observation = includeObservation ? WorkServiceHostObservation(
            instance: hostInstance, reachability: reachable ? .observedReachable : .unavailable,
            currentRun: state.currentRun, servedCursor: state.cursor,
            sourceCompleteness: state.sourceCompleteness) : nil
        let clients = Array(state.attachments.values.map(\.attachment)
            .sorted { $0.attachment.attachmentID < $1.attachment.attachmentID }
            .prefix(WorkServiceBounds.maxAttachmentsPerWork))
        var omissions: [WorkServiceOmission] = state.omissions
        if state.attachments.count > clients.count {
            omissions.append(WorkServiceOmission(category: "attachments", count: state.attachments.count - clients.count))
        }
        let artifacts = Array(state.artifacts.prefix(WorkServiceBounds.maxArtifactsPerWork))
        if state.artifacts.count > artifacts.count {
            omissions.append(WorkServiceOmission(category: "artifacts", count: state.artifacts.count - artifacts.count))
        }
        return WorkServiceWorkDescriptor(
            work: state.work, journal: state.journal, recordedDisposition: state.disposition,
            execution: state.execution, currentRun: state.currentRun,
            configuration: state.configuration,
            hostObservation: observation, attachments: clients, artifacts: artifacts,
            omissions: WorkServiceText.boundedOmissions(omissions))
    }

    private func apply(_ kind: WorkServiceCommandKind, to state: inout WorkState,
                       value: String?) -> WorkServiceCommandOutcome? {
        switch kind {
        case .start:
            guard state.execution == .idle, state.currentRun == nil else { return nil }
            state.currentRun = RunRef("run-" + String(state.nextRunOrdinal))
            state.nextRunOrdinal += 1
            state.execution = .running
            return .started
        case .send:
            guard state.execution == .running, state.currentRun != nil else { return nil }
            return .inputAccepted
        case .steer:
            guard state.execution == .running, state.currentRun != nil else { return nil }
            return .steeringAccepted
        case .queue:
            guard state.execution == .running, state.currentRun != nil else { return nil }
            return .queued
        case .hold:
            guard state.execution == .running, state.currentRun != nil else { return nil }
            state.execution = .held
            return .holdRequested
        case .cancel:
            guard state.execution == .running || state.execution == .held else { return nil }
            state.execution = .canceling
            return .cancellationRequested
        case .end:
            guard state.execution == .running || state.execution == .held || state.execution == .canceling else { return nil }
            state.execution = .ending
            return .endRequested
        case .destroy:
            guard state.execution == .idle, state.disposition == .reusable else { return nil }
            state.disposition = .destroyed
            return .destroyed
        case .complete:
            guard state.execution == .idle, state.disposition == .reusable else { return nil }
            state.disposition = .completed
            return .completed
        }
    }

    private func validTerminalProof(
        _ proof: WorkServiceTerminalCommitProof,
        request: WorkServiceTerminalCommitRequest,
        state: WorkState
    ) -> Bool {
        let expectedProvenance = proof.resultingWorkCursor.eventID.map {
            EventRef(journal: request.journal, eventID: $0)
        }
        guard proof.operation == request.operation,
              proof.work == request.work,
              proof.journal == request.journal,
              proof.command == request.command,
              proof.causalWorkCursor == request.causalWorkCursor,
              proof.causalWorkCursor == state.cursor,
              proof.causalWorkCursor.sequence < Int.max,
              proof.resultingWorkCursor.journal == request.journal,
              proof.resultingWorkCursor.sequence == request.causalWorkCursor.sequence + 1,
              proof.resultingWorkCursor.sequence < Int.max,
              validIdentity(proof.resultingWorkCursor.eventID ?? ""),
              proof.terminalEvent.cursor == proof.resultingWorkCursor,
              proof.terminalEvent.eventID == proof.resultingWorkCursor.eventID,
              proof.terminalEvent.kind == request.operation.eventKind,
              proof.terminalEvent.commandID == request.command.commandID,
              proof.terminalEvent.provenance == expectedProvenance,
              proof.session == request.session,
              proof.sessionJournal == request.sessionJournal,
              proof.sessionJournal.owner == .session(request.session),
              proof.sessionAttachment == request.sessionAttachment,
              proof.sessionPairingVerified,
              let paired = proof.pairedSessionCursor,
              paired.journal == request.sessionJournal,
              paired.sequence >= 0,
              validIdentity(paired.eventID ?? ""),
              proof.outstandingHandleIDs.isEmpty,
              validIdentity(proof.commitID) else {
            return false
        }
        return true
    }

    private func makeTerminalTask(
        committer: any WorkServiceTerminalCommitter,
        request: WorkServiceTerminalCommitRequest,
        commit: Bool
    ) -> Task<TerminalAttempt, Never> {
        Task {
            do {
                if commit {
                    return .proof(try await committer.commit(request))
                }
                if let proof = try await committer.committedProof(for: request) {
                    return .proof(proof)
                }
            } catch {
                // A thrown terminal operation is ambiguous until canonical storage is checked.
            }
            if commit,
               let recovered = try? await committer.committedProof(for: request) {
                return .proof(recovered)
            }
            return .unavailable
        }
    }

    private func awaitTerminalReservation(
        work: WorkRef, key: CommandKey,
        authorization: WorkServiceAuthorizationOutcome
    ) async -> WorkServiceCommandReceipt {
        guard let state = works[work], let reservation = state.terminalReservation,
              reservation.key == key else {
            return WorkServiceCommandReceipt(
                work: work, commandID: key.commandID, state: .rejected,
                host: hostInstance, hostSequence: 0,
                causalCursor: JournalCursor(journal: .work(work), sequence: 0),
                resultingCursor: nil, authorization: authorization,
                rejection: .terminalProofUnavailable,
                diagnostic: "terminal reservation disappeared before reconciliation")
        }
        if let prior = state.commands[key] {
            return duplicate(of: prior.receipt)
        }
        let task: Task<TerminalAttempt, Never>
        if let active = terminalTasks[work] {
            task = active
        } else if let committer = terminalCommitter {
            task = makeTerminalTask(
                committer: committer, request: reservation.proofRequest, commit: false)
            terminalTasks[work] = task
        } else {
            task = Task { .unavailable }
            terminalTasks[work] = task
        }
        let attempt = await task.value
        terminalTasks.removeValue(forKey: work)

        guard var latest = works[work],
              var latestReservation = latest.terminalReservation,
              latestReservation.key == key else {
            if let prior = works[work]?.commands[key] {
                return duplicate(of: prior.receipt)
            }
            return reservation.unavailableReceipt ?? WorkServiceCommandReceipt(
                work: work, commandID: key.commandID, state: .rejected,
                host: hostInstance, hostSequence: 0,
                causalCursor: reservation.request.causalCursor,
                resultingCursor: state.cursor, authorization: authorization,
                rejection: .terminalProofUnavailable,
                diagnostic: "terminal reservation could not be reconciled")
        }
        if let prior = latest.commands[key] { return duplicate(of: prior.receipt) }
        if case .proof(let proof) = attempt,
           validTerminalProof(
               proof, request: latestReservation.proofRequest, state: latest),
           let outcome = apply(
               latestReservation.request.kind, to: &latest,
               value: latestReservation.request.value) {
            latest.cursor = proof.resultingWorkCursor
            latest.nextEventSequence = proof.resultingWorkCursor.sequence + 1
            latest.events.append(proof.terminalEvent)
            latest.sourceCompleteness = .complete
            latest.terminalReservation = nil
            let hostSequence = latest.nextHostSequence
            latest.nextHostSequence += 1
            let receipt = WorkServiceCommandReceipt(
                work: latest.work,
                commandID: latestReservation.request.command.commandID,
                state: .accepted, host: hostInstance, hostSequence: hostSequence,
                causalCursor: latestReservation.request.causalCursor,
                resultingCursor: proof.resultingWorkCursor,
                authorization: authorization, outcome: outcome, terminalProof: proof)
            latest.commands[key] = StoredCommand(
                request: latestReservation.request, receipt: receipt)
            works[work] = latest
            return receipt
        }

        latest.sourceCompleteness = .unknown
        latestReservation.phase = .uncertain
        if latestReservation.unavailableReceipt == nil {
            latestReservation.unavailableReceipt = makeReceipt(
                state: &latest, request: latestReservation.request,
                authorization: authorization, state: .rejected,
                rejection: .terminalProofUnavailable,
                diagnostic: "terminal commit is ambiguous; exact retry will reconcile canonical storage")
        }
        latest.terminalReservation = latestReservation
        works[work] = latest
        return latestReservation.unavailableReceipt!
    }

    private func duplicate(of receipt: WorkServiceCommandReceipt) -> WorkServiceCommandReceipt {
        WorkServiceCommandReceipt(
            work: receipt.work, commandID: receipt.commandID,
            state: receipt.state == .rejected ? .rejected : .duplicate,
            host: receipt.host, hostSequence: receipt.hostSequence,
            causalCursor: receipt.causalCursor, resultingCursor: receipt.resultingCursor,
            authorization: receipt.authorization, outcome: receipt.outcome,
            rejection: receipt.rejection, terminalProof: receipt.terminalProof,
            diagnostic: receipt.state == .rejected ? receipt.diagnostic : "idempotent duplicate")
    }

    private func appendEvent(kind: String, commandID: String?, body: String? = nil,
                             state: inout WorkState) -> JournalCursor {
        let sequence = state.nextEventSequence
        state.nextEventSequence += 1
        let eventID = "service-event-" + String(sequence)
        let cursor = JournalCursor(journal: state.journal, eventID: eventID, sequence: sequence)
        let bodyReference: TimelineBodyReference?
        if let body {
            let data = Data(body.utf8)
            let digest = WorkServiceText.digest(data)
            let reference = TimelineBodyReference(
                authority: state.journal, referenceID: digest, mediaType: "text/plain",
                byteCount: data.count, digest: digest)
            state.bodies[reference] = data
            bodyReference = reference
        } else {
            bodyReference = nil
        }
        state.cursor = cursor
        state.events.append(WorkServiceEventDescriptor(
            eventID: eventID, kind: WorkServiceText.bound(kind) ?? "unknown",
            cursor: cursor, commandID: commandID, run: state.currentRun,
            provenance: EventRef(journal: state.journal, eventID: eventID),
            bodyReference: bodyReference,
            bodyStatus: bodyReference == nil ? .manifest : .retainedBody))
        return cursor
    }

    private func makeReceipt(state: inout WorkState, request: WorkServiceCommandRequest,
                             authorization: WorkServiceAuthorizationOutcome,
                             state receiptState: WorkServiceCommandReceiptState,
                             rejection: WorkServiceCommandRejection,
                             diagnostic: String) -> WorkServiceCommandReceipt {
        let hostSequence = state.nextHostSequence
        state.nextHostSequence += 1
        return WorkServiceCommandReceipt(
            work: state.work, commandID: request.command.commandID, state: receiptState,
            host: hostInstance, hostSequence: hostSequence,
            causalCursor: request.causalCursor, resultingCursor: state.cursor,
            authorization: authorization, rejection: rejection, diagnostic: diagnostic)
    }

    private static func precedes(_ lhs: WorkRef, _ rhs: WorkRef) -> Bool {
        if lhs.workHostID != rhs.workHostID { return lhs.workHostID < rhs.workHostID }
        return lhs.workID < rhs.workID
    }
}

/// A small host directory proves that a GUI can aggregate local and remote Work without making an
/// unavailable host poison rows from another host.  A production implementation can replace the
/// value lookup with discovery and a Unix/remote transport without changing the page contract.
public actor InMemoryWorkServiceRegistry {
    private var services: [WorkHostRef: InMemoryWorkService] = [:]

    public init() {}

    public func register(_ service: InMemoryWorkService) async {
        let host = service.host
        services[host] = service
    }

    public func listWorks(_ request: WorkServiceListRequest) async -> WorkServiceWorkPage {
        let orderedHosts = services.keys.sorted { $0.workHostID < $1.workHostID }
        let pageSize = min(max(request.pageSize, 1), WorkServiceBounds.maxPageSize)
        var allRows: [WorkServiceWorkDescriptor] = []
        var omissions: [WorkServiceOmission] = []
        for host in orderedHosts {
            guard let service = services[host] else {
                continue
            }
            do {
                var token: String?
                repeat {
                    let page = try await service.listWorks(
                        WorkServiceListRequest(
                            client: request.client,
                            pageSize: WorkServiceBounds.maxPageSize, pageToken: token))
                    allRows.append(contentsOf: page.works)
                    omissions.append(contentsOf: page.omissions)
                    token = page.nextPageToken
                } while token != nil
            } catch WorkServiceProtocolError.hostUnavailable {
                omissions.append(WorkServiceOmission(category: "host_unavailable", count: 1,
                                                      diagnostic: "one Work Host could not be read"))
            } catch {
                omissions.append(WorkServiceOmission(category: "host_unavailable", count: 1,
                                                      diagnostic: "one Work Host returned an unavailable result"))
            }
        }
        allRows.sort { WorkServiceText.precedes($0.work, $1.work) }
        let start: Int
        if let token = request.pageToken, let parsed = Int(token), parsed >= 0, parsed <= allRows.count {
            start = parsed
        } else if request.pageToken == nil {
            start = 0
        } else {
            omissions.append(WorkServiceOmission(category: "invalid_page_token", count: 1,
                                                  diagnostic: "registry page token was not an aggregate row offset"))
            start = 0
        }
        let end = min(allRows.count, start + pageSize)
        let rows = Array(allRows[start..<end])
        let next = end < allRows.count ? String(end) : nil
        return WorkServiceWorkPage(works: rows, nextPageToken: next,
                                   omissions: WorkServiceText.boundedOmissions(omissions))
    }
}

private enum WorkServiceText {
    struct BoundedCommandValue {
        let value: String?
        let wasTruncated: Bool
    }

    static func valid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func bound(_ value: String?) -> String? {
        guard let value else { return nil }
        guard value.count > WorkServiceBounds.maxDiagnosticCharacters else { return value }
        return String(value.prefix(WorkServiceBounds.maxDiagnosticCharacters))
    }

    static func boundCommand(_ value: String?) -> BoundedCommandValue {
        guard let value else { return BoundedCommandValue(value: nil, wasTruncated: false) }
        guard value.count > WorkServiceBounds.maxCommandValueCharacters else {
            return BoundedCommandValue(value: value, wasTruncated: false)
        }
        // Do not mutate command/configuration bodies merely to make them fit a diagnostic bound.
        // The exact value is retained for deterministic idempotency comparison and rejected at
        // the host effect boundary, with `wasTruncated` making the rejection explicit.
        return BoundedCommandValue(value: value, wasTruncated: true)
    }

    static func boundedOmissions(_ omissions: [WorkServiceOmission]) -> [WorkServiceOmission] {
        guard omissions.count > WorkServiceBounds.maxOmissions else { return omissions }
        let retainedCount = max(0, WorkServiceBounds.maxOmissions - 1)
        return Array(omissions.prefix(retainedCount)) + [WorkServiceOmission(
            category: "omission_records", count: omissions.count - retainedCount,
            diagnostic: "additional omission records were not included")]
    }

    static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func precedes(_ lhs: WorkRef, _ rhs: WorkRef) -> Bool {
        if lhs.workHostID != rhs.workHostID { return lhs.workHostID < rhs.workHostID }
        return lhs.workID < rhs.workID
    }
}
