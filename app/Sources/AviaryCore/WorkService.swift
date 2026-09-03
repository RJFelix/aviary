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
    /// A page is bounded by encoded canonical envelope bytes as well as event count. This keeps a
    /// single large payload from consuming the entire response budget.
    public static let maxEventPageBytes = 256 * 1024
    public static let maxBodyChunkBytes = 64 * 1024
    public static let maxTerminalProofHandles = 128
    public static let maxArtifactsPerWork = 128
    public static let maxAttachmentsPerWork = 64
    /// One client attachment currently has at most a Work target and its bound Session target.
    /// Keep this independently bounded so descriptor reconstruction cannot grow without limit.
    public static let maxReadAcknowledgementsPerAttachment = 2
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
    case eventPageCannotProgress(requiredBytes: Int, maximumBytes: Int)
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
    /// The separate Work Host control journal orders attachment, capability, and read
    /// acknowledgement mutations. It is never the Work journal and never a host sequence
    /// projected from a Work event.
    public let controlJournal: JournalRef
    public let controlCursor: JournalCursor
    public let capabilities: Set<WorkServiceCapability>
    public let diagnostic: String?

    public init(accepted: Bool, negotiatedVersion: Int?, supportedRange: ClosedRange<Int>,
                host: WorkHostRef, hostInstance: WorkHostInstanceRef,
                controlJournal: JournalRef, controlCursor: JournalCursor,
                capabilities: Set<WorkServiceCapability>, diagnostic: String? = nil) {
        self.accepted = accepted
        self.negotiatedVersion = negotiatedVersion
        self.supportedRange = supportedRange
        self.host = host
        self.hostInstance = hostInstance
        self.controlJournal = controlJournal
        self.controlCursor = controlCursor
        self.capabilities = capabilities
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

/// The target journal of a bounded snapshot or event-page read. A Work Host client must name
/// the Work that owns the attachment separately on every request; a Session target is accepted
/// only when that Session tuple is the one durably attached to that Work.
public enum WorkServiceReadTarget: Codable, Hashable, Sendable {
    case work(journal: JournalRef)
    case session(session: SessionRef, journal: JournalRef)

    public var journal: JournalRef {
        switch self {
        case .work(let journal), .session(_, let journal): return journal
        }
    }

    public var session: SessionRef? {
        switch self {
        case .work: return nil
        case .session(let session, _): return session
        }
    }
}

public enum WorkServiceControlOperation: String, Codable, Hashable, Sendable {
    case createWork = "create_work"
    case attach
    case detach
    case updateCapabilities = "update_capabilities"
    case acknowledgeRead = "acknowledge_read"
}

public enum WorkServiceControlOutcome: String, Codable, Hashable, Sendable {
    case created
    case attached
    case detached
    case capabilitiesUpdated = "capabilities_updated"
    case readAcknowledged = "read_acknowledged"
}

/// Receipt for a mutation in the Work Host control journal. Control commits do not have a Work
/// host sequence: only execution events in the Work journal may carry that ordering evidence.
public struct WorkServiceControlReceipt: Codable, Hashable, Sendable {
    public let operation: WorkServiceControlOperation
    public let work: WorkRef
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let causalControlCursor: JournalCursor
    public let resultingControlCursor: JournalCursor
    public let authorization: WorkServiceAuthorizationOutcome
    public let outcome: WorkServiceControlOutcome?
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(operation: WorkServiceControlOperation, work: WorkRef, commandID: String,
                state: WorkServiceCommandReceiptState, host: WorkHostInstanceRef,
                causalControlCursor: JournalCursor, resultingControlCursor: JournalCursor,
                authorization: WorkServiceAuthorizationOutcome,
                outcome: WorkServiceControlOutcome? = nil,
                rejection: WorkServiceCommandRejection? = nil, diagnostic: String? = nil) {
        self.operation = operation
        self.work = work
        self.commandID = commandID
        self.state = state
        self.host = host
        self.causalControlCursor = causalControlCursor
        self.resultingControlCursor = resultingControlCursor
        self.authorization = authorization
        self.outcome = outcome
        self.rejection = rejection
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

/// One durable read position for one exact target-journal generation. A Work cursor and a Session
/// cursor are independent; neither is an alias for the Work Host control cursor.
public struct WorkServiceReadAcknowledgement: Codable, Hashable, Sendable {
    public let target: WorkServiceReadTarget
    public let cursor: JournalCursor

    public init(target: WorkServiceReadTarget, cursor: JournalCursor) {
        self.target = target
        self.cursor = cursor
    }
}

public struct WorkServiceClientAttachment: Codable, Hashable, Sendable {
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let session: SessionRef?
    public let sessionJournal: JournalRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let authorization: WorkServiceAuthorizationOutcome
    public let readAcknowledgements: [WorkServiceReadAcknowledgement]

    public init(attachment: ClientAttachmentRef, client: ClientRef, session: SessionRef?,
                sessionJournal: JournalRef?, sessionAttachment: SessionAttachmentRef?,
                authorization: WorkServiceAuthorizationOutcome,
                readAcknowledgements: [WorkServiceReadAcknowledgement] = []) {
        self.attachment = attachment
        self.client = client
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.authorization = authorization
        self.readAcknowledgements = Array(readAcknowledgements.prefix(
            WorkServiceBounds.maxReadAcknowledgementsPerAttachment))
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
    /// Exact Work Host control cursor observed before the attach event is appended.
    public let causalControlCursor: JournalCursor
    public let requestedCapabilities: Set<WorkServiceCapability>

    public init(work: WorkRef, journal: JournalRef, client: ClientRef,
                session: SessionRef? = nil, sessionJournal: JournalRef? = nil,
                sessionAttachment: SessionAttachmentRef? = nil,
                commandID: String, causalControlCursor: JournalCursor,
                requestedCapabilities: Set<WorkServiceCapability> = [.observe]) {
        self.work = work
        self.journal = journal
        self.client = client
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
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
    public let causalControlCursor: JournalCursor
    public let resultingControlCursor: JournalCursor
    public let receipt: WorkServiceControlReceipt
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(work: WorkServiceWorkDescriptor, attachment: WorkServiceClientAttachment?,
                authorization: WorkServiceAuthorizationOutcome, commandID: String,
                state: WorkServiceCommandReceiptState = .accepted,
                host: WorkHostInstanceRef, causalControlCursor: JournalCursor,
                resultingControlCursor: JournalCursor,
                receipt: WorkServiceControlReceipt? = nil,
                rejection: WorkServiceCommandRejection? = nil, diagnostic: String? = nil) {
        self.work = work
        self.attachment = attachment
        self.authorization = authorization
        self.commandID = commandID
        self.state = state
        self.host = host
        self.causalControlCursor = causalControlCursor
        self.resultingControlCursor = resultingControlCursor
        self.receipt = receipt ?? WorkServiceControlReceipt(
            operation: .attach, work: work.work, commandID: commandID, state: state,
            host: host, causalControlCursor: causalControlCursor,
            resultingControlCursor: resultingControlCursor, authorization: authorization,
            outcome: state == .accepted ? .attached : nil, rejection: rejection,
            diagnostic: diagnostic)
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
            .contains { ($0?.utf8.count ?? 0) > WorkServiceBounds.maxCommandValueCharacters }
    }

    /// The host retains the initial prompt for execution and exact retry comparison, but Work
    /// descriptors are inventory/projection data and must not echo retained request bodies.
    fileprivate var observableDescriptorConfiguration: WorkServiceWorkConfiguration {
        WorkServiceWorkConfiguration(
            providerID: providerID,
            modelID: modelID,
            thinkingLevel: thinkingLevel,
            contextPolicy: contextPolicy,
            workingDirectoryPolicy: workingDirectoryPolicy,
            includeContextFiles: includeContextFiles,
            recordPayloads: recordPayloads,
            resumePolicy: resumePolicy,
            initialPrompt: nil)
    }
}

public struct WorkServiceCreateWorkRequest: Codable, Hashable, Sendable {
    public let client: ClientRef
    public let commandID: String
    /// Creation is a Work Host control mutation. The host mints the Work and Session identities;
    /// callers cannot select an identity or smuggle in an execution-journal cursor.
    public let causalControlCursor: JournalCursor
    public let configuration: WorkServiceWorkConfiguration
    public let requestedCapabilities: Set<WorkServiceCapability>

    public init(client: ClientRef, commandID: String, causalControlCursor: JournalCursor,
                configuration: WorkServiceWorkConfiguration = .init(),
                requestedCapabilities: Set<WorkServiceCapability> = [.observe, .control]) {
        self.client = client
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
        self.configuration = configuration
        self.requestedCapabilities = requestedCapabilities
    }
}

public struct WorkServiceCreateWorkResponse: Codable, Hashable, Sendable {
    public let work: WorkServiceWorkDescriptor
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let attachment: WorkServiceClientAttachment
    public let workCursor: JournalCursor
    public let sessionCursor: JournalCursor
    public let controlCursor: JournalCursor
    public let authorization: WorkServiceAuthorizationOutcome
    public let receipt: WorkServiceControlReceipt

    public init(work: WorkServiceWorkDescriptor, authorization: WorkServiceAuthorizationOutcome,
                session: SessionRef, sessionJournal: JournalRef,
                sessionAttachment: SessionAttachmentRef,
                attachment: WorkServiceClientAttachment,
                workCursor: JournalCursor, sessionCursor: JournalCursor,
                controlCursor: JournalCursor, receipt: WorkServiceControlReceipt) {
        self.work = work
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.attachment = attachment
        self.workCursor = workCursor
        self.sessionCursor = sessionCursor
        self.controlCursor = controlCursor
        self.authorization = authorization
        self.receipt = receipt
    }

    public var resultingWorkCursor: JournalCursor { workCursor }
    public var resultingSessionCursor: JournalCursor { sessionCursor }
    public var resultingControlCursor: JournalCursor { controlCursor }
    public var clientAttachment: WorkServiceClientAttachment { attachment }
}

public struct WorkServiceCompleteWorkRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let command: CommandRef
    public let causalWorkCursor: JournalCursor

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                commandID: String, client: ClientRef,
                sessionAttachment: SessionAttachmentRef? = nil,
                causalWorkCursor: JournalCursor) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.causalWorkCursor = causalWorkCursor
        self.command = CommandRef(commandID: commandID, client: client,
                                  sessionAttachment: sessionAttachment,
                                  causalCursor: causalWorkCursor)
    }
}

public struct WorkServiceDetachRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    /// Stable caller identity for retries. It is scoped to the client and Work.
    public let commandID: String
    /// Exact Work Host control cursor observed before the detach event is appended.
    public let causalControlCursor: JournalCursor

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef, commandID: String, causalControlCursor: JournalCursor) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
    }
}

public struct WorkServiceDetachResponse: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let causalControlCursor: JournalCursor
    public let resultingControlCursor: JournalCursor
    public let receipt: WorkServiceControlReceipt
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(work: WorkRef, commandID: String, state: WorkServiceCommandReceiptState,
                host: WorkHostInstanceRef, causalControlCursor: JournalCursor,
                resultingControlCursor: JournalCursor,
                receipt: WorkServiceControlReceipt? = nil,
                rejection: WorkServiceCommandRejection? = nil, diagnostic: String? = nil) {
        self.work = work
        self.commandID = commandID
        self.state = state
        self.host = host
        self.causalControlCursor = causalControlCursor
        self.resultingControlCursor = resultingControlCursor
        self.receipt = receipt ?? WorkServiceControlReceipt(
            operation: .detach, work: work, commandID: commandID, state: state,
            host: host, causalControlCursor: causalControlCursor,
            resultingControlCursor: resultingControlCursor,
            authorization: WorkServiceAuthorizationOutcome(
                requested: [], granted: [], denied: []), outcome: state == .accepted ? .detached : nil,
            rejection: rejection, diagnostic: diagnostic)
        self.rejection = rejection
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

public struct WorkServiceSnapshotRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let target: WorkServiceReadTarget
    public let afterCursor: JournalCursor?
    public let limit: Int
    public let maxBytes: Int

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef,
                target: WorkServiceReadTarget,
                afterCursor: JournalCursor? = nil,
                limit: Int = WorkServiceBounds.maxEventsPerPage,
                maxBytes: Int = WorkServiceBounds.maxEventPageBytes) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.target = target
        self.afterCursor = afterCursor
        self.limit = limit
        self.maxBytes = maxBytes
    }
}

public struct WorkServiceSnapshot: Codable, Hashable, Sendable {
    public let work: WorkServiceWorkDescriptor
    public let target: WorkServiceReadTarget
    /// Canonical timeline envelopes are returned intact. The service may bound the page, but it
    /// must not reduce an event to a lossy display descriptor before the caller can inspect it.
    public let events: [TimelineEvent]
    public let servedCursor: JournalCursor?
    public let omissions: [WorkServiceOmission]

    public init(work: WorkServiceWorkDescriptor, events: [TimelineEvent],
                target: WorkServiceReadTarget, servedCursor: JournalCursor?,
                omissions: [WorkServiceOmission] = []) {
        self.work = work
        self.events = events
        self.target = target
        self.servedCursor = servedCursor
        self.omissions = omissions
    }
}

public struct WorkServiceEventsRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let target: WorkServiceReadTarget
    public let afterCursor: JournalCursor
    public let limit: Int
    public let maxBytes: Int

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef,
                target: WorkServiceReadTarget,
                afterCursor: JournalCursor, limit: Int = WorkServiceBounds.maxEventsPerPage,
                maxBytes: Int = WorkServiceBounds.maxEventPageBytes) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.target = target
        self.afterCursor = afterCursor
        self.limit = limit
        self.maxBytes = maxBytes
    }
}

public struct WorkServiceUpdateCapabilitiesRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let requestedCapabilities: Set<WorkServiceCapability>
    public let commandID: String
    public let causalControlCursor: JournalCursor

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef, requestedCapabilities: Set<WorkServiceCapability>,
                commandID: String, causalControlCursor: JournalCursor) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.requestedCapabilities = requestedCapabilities
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
    }
}

public struct WorkServiceUpdateCapabilitiesResponse: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let attachment: WorkServiceClientAttachment?
    public let authorization: WorkServiceAuthorizationOutcome
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let causalControlCursor: JournalCursor
    public let resultingControlCursor: JournalCursor
    public let receipt: WorkServiceControlReceipt
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(work: WorkRef, attachment: WorkServiceClientAttachment?,
                authorization: WorkServiceAuthorizationOutcome, commandID: String,
                state: WorkServiceCommandReceiptState, host: WorkHostInstanceRef,
                causalControlCursor: JournalCursor, resultingControlCursor: JournalCursor,
                receipt: WorkServiceControlReceipt? = nil,
                rejection: WorkServiceCommandRejection? = nil, diagnostic: String? = nil) {
        self.work = work
        self.attachment = attachment
        self.authorization = authorization
        self.commandID = commandID
        self.state = state
        self.host = host
        self.causalControlCursor = causalControlCursor
        self.resultingControlCursor = resultingControlCursor
        self.receipt = receipt ?? WorkServiceControlReceipt(
            operation: .updateCapabilities, work: work, commandID: commandID, state: state,
            host: host, causalControlCursor: causalControlCursor,
            resultingControlCursor: resultingControlCursor, authorization: authorization,
            outcome: state == .accepted ? .capabilitiesUpdated : nil, rejection: rejection,
            diagnostic: diagnostic)
        self.rejection = rejection
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }
}

public struct WorkServiceAcknowledgeReadRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let target: WorkServiceReadTarget
    public let cursor: JournalCursor
    public let commandID: String
    public let causalControlCursor: JournalCursor

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef, target: WorkServiceReadTarget, cursor: JournalCursor,
                commandID: String, causalControlCursor: JournalCursor) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.target = target
        self.cursor = cursor
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
    }
}

public struct WorkServiceAcknowledgeReadResponse: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let target: WorkServiceReadTarget
    public let cursor: JournalCursor
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let causalControlCursor: JournalCursor
    public let resultingControlCursor: JournalCursor
    public let receipt: WorkServiceControlReceipt
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(work: WorkRef, target: WorkServiceReadTarget, cursor: JournalCursor,
                commandID: String, state: WorkServiceCommandReceiptState,
                host: WorkHostInstanceRef, causalControlCursor: JournalCursor,
                resultingControlCursor: JournalCursor,
                authorization: WorkServiceAuthorizationOutcome,
                receipt: WorkServiceControlReceipt? = nil,
                rejection: WorkServiceCommandRejection? = nil, diagnostic: String? = nil) {
        self.work = work
        self.target = target
        self.cursor = cursor
        self.commandID = commandID
        self.state = state
        self.host = host
        self.causalControlCursor = causalControlCursor
        self.resultingControlCursor = resultingControlCursor
        self.receipt = receipt ?? WorkServiceControlReceipt(
            operation: .acknowledgeRead, work: work, commandID: commandID, state: state,
            host: host, causalControlCursor: causalControlCursor,
            resultingControlCursor: resultingControlCursor, authorization: authorization,
            outcome: state == .accepted ? .readAcknowledged : nil, rejection: rejection,
            diagnostic: diagnostic)
        self.rejection = rejection
        self.diagnostic = WorkServiceText.bound(diagnostic)
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
    /// Canonical timeline envelopes are returned intact; presentation can derive descriptors
    /// without making the protocol discard causal or payload fields.
    public let events: [TimelineEvent]
    public let target: WorkServiceReadTarget
    public let servedCursor: JournalCursor?
    public let nextCursor: JournalCursor?
    public let omissions: [WorkServiceOmission]

    public init(events: [TimelineEvent], target: WorkServiceReadTarget,
                servedCursor: JournalCursor?,
                nextCursor: JournalCursor?, omissions: [WorkServiceOmission] = []) {
        self.events = events
        self.target = target
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
            .contains { ($0?.utf8.count ?? 0) > WorkServiceBounds.maxDiagnosticCharacters }
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
    public let terminalEvent: TimelineEvent
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
                terminalEvent: TimelineEvent,
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

    /// Project one canonical terminal record into the transport proof without reopening or
    /// mutating the journals. The static reader in ``RunJournalBundle`` and the live bundle
    /// committer both use this exact projection, so a lost-response reconciliation cannot invent
    /// a second event or silently drop the canonical envelope's identity checks.
    public static func makeProof(
        record: RunJournalBundleTerminalCommit,
        request: WorkServiceTerminalCommitRequest
    ) throws -> WorkServiceTerminalCommitProof {
        let event = record.workEvent
        let expectedCausalEvent = request.causalWorkCursor.eventID.map {
            EventRef(journal: request.journal, eventID: $0)
        }
        guard event.type == request.operation.eventKind,
              event.journal == request.journal,
              event.work == request.work,
              event.workHost == WorkHostRef(request.work.workHostID),
              event.session == request.session,
              event.client == request.client,
              event.sessionAttachment == request.sessionAttachment,
              event.command == request.command,
              event.idempotencyKey == terminalIdempotencyKey(
                  type: event.type, command: request.command, detail: request.detail),
              event.causedByEventID == expectedCausalEvent,
              record.workCommit.cursor.journal == request.journal,
              record.workCommit.cursor.eventID == event.eventID,
              record.workCommit.cursor.sequence == event.sequence else {
            throw WorkServiceProtocolError.invalidRequest(
                "canonical terminal record does not match the exact command envelope")
        }
        return WorkServiceTerminalCommitProof(
            operation: request.operation, work: request.work, journal: request.journal,
            command: request.command, causalWorkCursor: request.causalWorkCursor,
            resultingWorkCursor: record.workCommit.cursor,
            terminalEvent: event,
            session: request.session, sessionJournal: request.sessionJournal,
            sessionAttachment: request.sessionAttachment,
            pairedSessionCursor: record.pairedSessionCommit?.cursor,
            sessionPairingVerified: record.sessionPairingVerified,
            outstandingHandleIDs: record.outstandingHandleIDs,
            commitID: event.eventID)
    }

    fileprivate static func terminalIdempotencyKey(
        type: String, command: CommandRef, detail: String?
    ) -> String {
        func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let client = command.client?.clientID ?? ""
        let attachment = command.sessionAttachment?.attachmentID ?? ""
        let cursor = command.causalCursor
        let detailComponent = detail.map { "some:\(component($0))" } ?? "none"
        return "work-terminal:v1/type:\(component(type))"
            + "/command:\(component(command.commandID))"
            + "/client:\(component(client))"
            + "/attachment:\(component(attachment))"
            + "/journal:\(component(cursor?.journal.stableKey ?? ""))"
            + "/sequence:\(cursor?.sequence ?? -1)"
            + "/event:\(component(cursor?.eventID ?? ""))"
            + "/detail:\(detailComponent)"
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
        return try WorkServiceTerminalCommitProof.makeProof(record: record, request: request)
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
    public let causalWorkCursor: JournalCursor
    public let kind: WorkServiceCommandKind
    public let value: String?
    public let valueWasTruncated: Bool

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                commandID: String, client: ClientRef,
                sessionAttachment: SessionAttachmentRef? = nil,
                causalWorkCursor: JournalCursor,
                kind: WorkServiceCommandKind, value: String? = nil) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.causalWorkCursor = causalWorkCursor
        self.command = CommandRef(commandID: commandID, client: client,
                                  sessionAttachment: sessionAttachment,
                                  causalCursor: causalWorkCursor)
        self.kind = kind
        if let value, value.utf8.count > WorkServiceBounds.maxCommandValueCharacters {
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
    /// Work host order exists only for an accepted execution-journal commit. Rejections have no
    /// Work event and therefore carry no synthetic host sequence.
    public let hostSequence: Int?
    public let causalWorkCursor: JournalCursor
    public let resultingWorkCursor: JournalCursor?
    public let authorization: WorkServiceAuthorizationOutcome
    public let outcome: WorkServiceCommandOutcome?
    public let rejection: WorkServiceCommandRejection?
    public let terminalProof: WorkServiceTerminalCommitProof?
    public let diagnostic: String?

    public init(work: WorkRef, commandID: String, state: WorkServiceCommandReceiptState,
                host: WorkHostInstanceRef, hostSequence: Int? = nil,
                causalWorkCursor: JournalCursor, resultingWorkCursor: JournalCursor?,
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
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
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
    func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws
        -> WorkServiceUpdateCapabilitiesResponse
    func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws
        -> WorkServiceAcknowledgeReadResponse
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
        public let session: SessionRef?
        public let sessionJournal: JournalRef?
        public let sessionAttachment: SessionAttachmentRef?
        public let sessionCursor: JournalCursor?
        public let events: [TimelineEvent]
        public let sessionEvents: [TimelineEvent]
        public let sourceCompleteness: WorkServiceSourceCompleteness
        public let artifacts: [WorkServiceArtifactDescriptor]
        public let bodies: [TimelineBodyReference: Data]

        public init(work: WorkRef, journal: JournalRef,
                    disposition: WorkServiceRecordedDisposition = .reusable,
                    execution: WorkServiceExecutionState = .idle,
                    currentRun: RunRef? = nil, cursor: JournalCursor? = nil,
                    session: SessionRef? = nil, sessionJournal: JournalRef? = nil,
                    sessionAttachment: SessionAttachmentRef? = nil,
                    sessionCursor: JournalCursor? = nil,
                    events: [TimelineEvent] = [],
                    sessionEvents: [TimelineEvent] = [],
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
            self.session = session
            self.sessionJournal = sessionJournal
            self.sessionAttachment = sessionAttachment
            self.sessionCursor = sessionCursor
            self.events = events
            self.sessionEvents = sessionEvents
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
        let client: ClientRef
        let commandID: String
    }

    private struct AttachmentCommandKey: Hashable, Sendable {
        let work: WorkRef
        let client: ClientRef
        let commandID: String
    }

    private struct ReadAcknowledgementKey: Hashable, Sendable {
        let attachment: ClientAttachmentRef
        let targetJournal: JournalRef
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

    private struct StoredCapabilities: Sendable {
        let request: WorkServiceUpdateCapabilitiesRequest
        let response: WorkServiceUpdateCapabilitiesResponse
    }

    private struct StoredReadAcknowledgement: Sendable {
        let request: WorkServiceAcknowledgeReadRequest
        let response: WorkServiceAcknowledgeReadResponse
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
    private var capabilityCommands: [AttachmentCommandKey: StoredCapabilities] = [:]
    private var readAcknowledgementCommands: [AttachmentCommandKey: StoredReadAcknowledgement] = [:]
    private var terminalTasks: [WorkRef: Task<TerminalAttempt, Never>] = [:]
    private var nextAttachmentOrdinal = 1
    private var nextWorkOrdinal = 1
    private var nextSessionOrdinal = 1

    private let controlJournal: JournalRef
    private var controlCursor: JournalCursor

    private struct WorkState: Sendable {
        let work: WorkRef
        let journal: JournalRef
        var disposition: WorkServiceRecordedDisposition
        var execution: WorkServiceExecutionState
        var currentRun: RunRef?
        var configuration: WorkServiceWorkConfiguration
        var cursor: JournalCursor?
        var session: SessionRef?
        var sessionJournal: JournalRef?
        var sessionAttachment: SessionAttachmentRef?
        var sessionCursor: JournalCursor?
        var sourceCompleteness: WorkServiceSourceCompleteness
        var artifacts: [WorkServiceArtifactDescriptor]
        var bodies: [TimelineBodyReference: Data]
        var omissions: [WorkServiceOmission]
        var attachments: [ClientAttachmentRef: ClientState]
        var events: [TimelineEvent]
        var sessionEvents: [TimelineEvent]
        var readAcknowledgements: [ReadAcknowledgementKey: JournalCursor]
        var nextEventSequence: Int
        var nextSessionEventSequence: Int
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
        self.controlJournal = JournalRef.workHost(host)
        self.controlCursor = JournalCursor(journal: JournalRef.workHost(host), sequence: 0)
    }

    public func register(_ seed: Seed) throws {
        guard seed.work.workHostID == host.workHostID,
              seed.journal.owner == .work(seed.work),
              seed.journal.authority.authorityID == host.workHostID,
              seed.journal.kind == .work else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard WorkServiceText.valid(seed.work.workHostID), seed.work.workHostID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              WorkServiceText.valid(seed.work.workID), seed.work.workID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              WorkServiceText.valid(seed.journal.journalID), seed.journal.journalID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              seed.journal.authority.authorityID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              (seed.cursor?.journal == nil || seed.cursor?.journal == seed.journal),
              (seed.cursor?.sequence ?? 0) >= 0, (seed.cursor?.sequence ?? 0) < Int.max,
              (seed.cursor?.sequence ?? 0) != 0 || seed.cursor?.eventID == nil,
              (seed.cursor?.sequence ?? 0) == 0 || (seed.cursor?.eventID.map(validIdentity) ?? false),
              (seed.session == nil) == (seed.sessionJournal == nil),
              (seed.session == nil) == (seed.sessionAttachment == nil),
              (seed.session.map { validIdentity($0.sessionID) } ?? true),
              (seed.sessionJournal.map {
                  $0.kind == .session && $0.owner == .session(seed.session!)
                      && $0.authority.authorityID == host.workHostID
              } ?? true),
              (seed.sessionAttachment.map { validIdentity($0.attachmentID) } ?? true),
              (seed.sessionCursor?.journal == nil || seed.sessionCursor?.journal == seed.sessionJournal),
              (seed.sessionCursor?.sequence ?? 0) >= 0,
              (seed.sessionCursor?.sequence ?? 0) < Int.max,
              (seed.sessionCursor?.sequence ?? 0) != 0 || seed.sessionCursor?.eventID == nil,
              (seed.sessionCursor?.sequence ?? 0) == 0
                  || (seed.sessionCursor?.eventID.map(validIdentity) ?? false),
              (seed.events.allSatisfy {
                  $0.journal == seed.journal
                      && $0.sequence > 0
                      && validIdentity($0.eventID)
              }),
              (seed.sessionEvents.allSatisfy {
                  $0.journal == seed.sessionJournal
                      && $0.sequence > 0
                      && validIdentity($0.eventID)
              }),
              (seed.artifacts.allSatisfy {
                  validIdentity($0.artifactID)
                      && ($0.bodyReference.map { validBodyReference($0, journal: seed.journal) } ?? true)
              }),
              (seed.bodies.keys.allSatisfy { reference in
                  validBodyReference(reference, journal: seed.journal)
                      || (seed.sessionJournal.map { sessionJournal in
                          validBodyReference(reference, journal: sessionJournal)
                      } ?? false)
              }),
              (seed.bodies.allSatisfy({ reference, data in
                  reference.byteCount == data.count
              })),
              !seed.configuration.hasInvalidBodyBounds else {
            throw WorkServiceProtocolError.invalidRequest("invalid Work or cursor identity")
        }
        let cursor = seed.cursor ?? JournalCursor(journal: seed.journal, sequence: 0)
        let sessionCursor: JournalCursor? = seed.session == nil
            ? nil
            : (seed.sessionCursor ?? JournalCursor(journal: seed.sessionJournal!, sequence: 0))
        guard cursor.sequence == 0 || seed.sourceCompleteness != .complete else {
            throw WorkServiceProtocolError.invalidRequest(
                "a complete nonzero seed requires retained event history")
        }
        guard cursor.sequence == 0 || seed.events.last.map({
            $0.journal == seed.journal && $0.sequence == cursor.sequence
                && $0.eventID == cursor.eventID
        }) == true || seed.sourceCompleteness != .complete else {
            throw WorkServiceProtocolError.invalidRequest(
                "the complete seed cursor does not match its retained Work event history")
        }
        guard seed.events.isEmpty || seed.events.last.map({
            $0.journal == seed.journal && $0.sequence == cursor.sequence
                && $0.eventID == cursor.eventID
        }) == true else {
            throw WorkServiceProtocolError.invalidRequest(
                "retained Work events must end at the advertised cursor")
        }
        guard sessionCursor == nil || sessionCursor?.sequence == 0 || seed.sessionEvents.last.map({
            $0.journal == seed.sessionJournal && $0.sequence == sessionCursor?.sequence
                && $0.eventID == sessionCursor?.eventID
        }) == true || seed.sourceCompleteness != .complete else {
            throw WorkServiceProtocolError.invalidRequest(
                "the complete seed cursor does not match its retained Session event history")
        }
        guard seed.sessionEvents.isEmpty || sessionCursor == nil || seed.sessionEvents.last.map({
            $0.journal == seed.sessionJournal && $0.sequence == sessionCursor?.sequence
                && $0.eventID == sessionCursor?.eventID
        }) == true else {
            throw WorkServiceProtocolError.invalidRequest(
                "retained Session events must end at the advertised cursor")
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
            session: seed.session, sessionJournal: seed.sessionJournal,
            sessionAttachment: seed.sessionAttachment, sessionCursor: sessionCursor,
            sourceCompleteness: seed.sourceCompleteness, artifacts: artifacts, bodies: seed.bodies,
            omissions: omissions,
            attachments: [:],
            events: seed.events, sessionEvents: seed.sessionEvents,
            readAcknowledgements: [:],
            nextEventSequence: cursor.sequence + 1,
            nextSessionEventSequence: (sessionCursor?.sequence ?? 0) + 1,
            nextRunOrdinal: 1, nextHostSequence: 1, commands: [:], terminalReservation: nil)
        if let workOrdinal = Int(seed.work.workID.split(separator: "-").last ?? ""),
           workOrdinal >= nextWorkOrdinal {
            nextWorkOrdinal = workOrdinal + 1
        }
        if let sessionID = seed.session?.sessionID,
           let sessionOrdinal = Int(sessionID.split(separator: "-").last ?? ""),
           sessionOrdinal >= nextSessionOrdinal {
            nextSessionOrdinal = sessionOrdinal + 1
        }
    }

    public func setReachable(_ value: Bool) {
        reachable = value
    }

    public func handshake(_ request: WorkServiceHandshakeRequest) async throws -> WorkServiceHandshakeResponse {
        guard WorkServiceText.valid(request.client.clientID), request.client.clientID.utf8.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceProtocolError.invalidRequest("invalid client identity")
        }
        let accepted = (WorkServiceProtocol.minimumSupportedVersion...WorkServiceProtocol.maximumSupportedVersion)
            .contains(request.protocolVersion)
        if !accepted { throw WorkServiceProtocolError.unsupportedVersion(request.protocolVersion) }
        return WorkServiceHandshakeResponse(
            accepted: true, negotiatedVersion: request.protocolVersion,
            supportedRange: WorkServiceProtocol.minimumSupportedVersion...WorkServiceProtocol.maximumSupportedVersion,
            host: host, hostInstance: hostInstance,
            controlJournal: controlJournal, controlCursor: controlCursor,
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
        guard validIdentity(request.commandID), request.commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceProtocolError.invalidRequest("invalid create command identity")
        }
        guard !request.configuration.hasInvalidBodyBounds else {
            throw WorkServiceProtocolError.invalidRequest("Work configuration exceeds a bounded body limit")
        }
        let createKey = CreateCommandKey(client: request.client, commandID: request.commandID)
        if let prior = createCommands[createKey] {
            guard prior.request == request else {
                throw WorkServiceProtocolError.invalidRequest("create command ID was already used with different contents")
            }
            return prior.response
        }
        let authorization = authorization(
            for: request.client, requested: request.requestedCapabilities)
        guard authorization.allows(.control) else {
            throw WorkServiceProtocolError.capabilityDenied(.control)
        }
        guard request.causalControlCursor == controlCursor else {
            throw WorkServiceProtocolError.invalidRequest(
                "create causal control cursor is not current")
        }
        var workID: String
        repeat {
            workID = "work-\(nextWorkOrdinal)"
            nextWorkOrdinal += 1
        } while works.keys.contains(WorkRef(workHostID: host.workHostID, workID: workID))
        let work = WorkRef(workHostID: host.workHostID, workID: workID)
        let workJournal = JournalRef.work(work)
        let session = SessionRef("session-\(nextSessionOrdinal)")
        nextSessionOrdinal += 1
        let sessionJournal = JournalRef.session(
            session, authority: TimelineAuthorityRef(host.workHostID))
        let sessionAttachment = SessionAttachmentRef("session-attachment-\(nextAttachmentOrdinal)")
        let attachmentID = ClientAttachmentRef("attachment-\(nextAttachmentOrdinal)")
        nextAttachmentOrdinal += 1
        var state = WorkState(
            work: work, journal: workJournal, disposition: .reusable, execution: .idle,
            currentRun: nil, configuration: request.configuration,
            cursor: JournalCursor(journal: workJournal, sequence: 0),
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment,
            sessionCursor: JournalCursor(journal: sessionJournal, sequence: 0),
            sourceCompleteness: .complete, artifacts: [], bodies: [:], omissions: [],
            attachments: [:], events: [], sessionEvents: [], readAcknowledgements: [:],
            nextEventSequence: 1, nextSessionEventSequence: 1, nextRunOrdinal: 1,
            nextHostSequence: 1, commands: [:], terminalReservation: nil)
        let createCommand = CommandRef(
            commandID: request.commandID, client: request.client,
            sessionAttachment: sessionAttachment,
            causalCursor: state.cursor)
        _ = appendEvent(kind: TimelineEventType.workCreated,
                        commandID: request.commandID, command: createCommand,
                        state: &state)
        _ = appendSessionEvent(kind: TimelineEventType.sessionCreated,
                                commandID: request.commandID, command: createCommand,
                                state: &state)
        _ = appendSessionEvent(kind: TimelineEventType.sessionAttached,
                                commandID: request.commandID, command: createCommand,
                                state: &state)
        let workCursor = state.cursor!
        let attachment = WorkServiceClientAttachment(
            attachment: attachmentID, client: request.client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            authorization: authorization)
        state.attachments[attachmentID] = ClientState(attachment: attachment)
        works[work] = state
        let resultingControlCursor = appendControlEvent()
        let receipt = WorkServiceControlReceipt(
            operation: .createWork, work: work, commandID: request.commandID,
            state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor,
            authorization: authorization, outcome: .created)
        let response = WorkServiceCreateWorkResponse(
            work: descriptor(for: work, includeObservation: true)!, authorization: authorization,
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, attachment: attachment,
            workCursor: workCursor,
            sessionCursor: state.sessionCursor
                ?? JournalCursor(journal: sessionJournal, sequence: 0),
            controlCursor: resultingControlCursor, receipt: receipt)
        createCommands[createKey] = StoredCreate(request: request, response: response)
        return response
    }

    public func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws -> WorkServiceCommandReceipt {
        guard let client = request.command.client else {
            throw WorkServiceProtocolError.invalidRequest("completion must carry a client identity")
        }
        guard request.command.causalCursor == request.causalWorkCursor else {
            throw WorkServiceProtocolError.invalidRequest("completion causal cursor is inconsistent")
        }
        let command = WorkServiceCommandRequest(
            work: request.work, journal: request.journal, attachment: request.attachment,
            commandID: request.command.commandID, client: client,
            sessionAttachment: request.command.sessionAttachment,
            causalWorkCursor: request.causalWorkCursor, kind: .complete)
        return try await self.command(command)
    }

    public func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse {
        try requireReachable()
        guard var state = works[request.work] else { throw WorkServiceProtocolError.workNotFound(request.work) }
        guard request.journal == state.journal else { throw WorkServiceProtocolError.journalMismatch }
        guard validIdentity(request.client.clientID), validIdentity(request.commandID),
              validCursor(request.causalControlCursor, journal: controlJournal) else {
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
                    causalControlCursor: request.causalControlCursor,
                    resultingControlCursor: prior.response.resultingControlCursor,
                    receipt: controlReceipt(
                        operation: .attach, work: prior.response.work.work,
                        commandID: request.commandID, state: .rejected,
                        causalControlCursor: request.causalControlCursor,
                        resultingControlCursor: prior.response.resultingControlCursor,
                        authorization: prior.response.authorization,
                        rejection: .conflictingCommand,
                        diagnostic: "attachment command ID was already used with different contents"),
                    rejection: .conflictingCommand,
                    diagnostic: "attachment command ID was already used with different contents")
            }
            let duplicateReceipt = duplicateControl(of: prior.response.receipt)
            return WorkServiceAttachResponse(
                work: prior.response.work, attachment: prior.response.attachment,
                authorization: prior.response.authorization, commandID: request.commandID,
                state: prior.response.state == .rejected ? .rejected : .duplicate,
                host: prior.response.host,
                causalControlCursor: prior.response.causalControlCursor,
                resultingControlCursor: prior.response.resultingControlCursor,
                receipt: duplicateReceipt,
                rejection: prior.response.rejection,
                diagnostic: prior.response.state == .rejected
                    ? prior.response.diagnostic : "idempotent duplicate")
        }
        guard (request.session == nil) == (request.sessionAttachment == nil),
              (request.session == nil) == (request.sessionJournal == nil),
              (request.session.map { validIdentity($0.sessionID) } ?? true),
              (request.sessionJournal.map {
                  $0.kind == .session && $0.owner == .session(request.session!)
                      && $0.authority.authorityID == host.workHostID
              } ?? true),
              (request.sessionAttachment.map { validIdentity($0.attachmentID) } ?? true) else {
            throw WorkServiceProtocolError.invalidRequest(
                "Session, Session journal, and attachment identity must be complete and bounded")
        }
        if let existingSession = state.session {
            guard request.session == existingSession,
                  request.sessionJournal == state.sessionJournal,
                  request.sessionAttachment == state.sessionAttachment else {
                throw WorkServiceProtocolError.invalidRequest(
                    "attach Session tuple does not match the Work's canonical Session relationship")
            }
        }
        let authorization = authorization(
            for: request.client, requested: request.requestedCapabilities)
        if state.terminalReservation != nil {
            let response = WorkServiceAttachResponse(
                work: descriptor(for: state.work, includeObservation: true)!, attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor, rejection: .terminalProofUnavailable,
                diagnostic: "a terminal Work transaction is already in progress")
            attachCommands[key] = StoredAttach(request: request, response: response)
            works[state.work] = state
            return response
        }
        guard state.sourceCompleteness == .complete else {
            let response = WorkServiceAttachResponse(
                work: descriptor(for: state.work, includeObservation: true)!, attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor, rejection: .sourceIncomplete,
                diagnostic: "host source is not complete enough to attach canonically")
            attachCommands[key] = StoredAttach(request: request, response: response)
            // No attachment, event, cursor, or host-order mutation is claimed.
            works[state.work] = state
            return response
        }
        if request.causalControlCursor != controlCursor {
            let response = WorkServiceAttachResponse(
                work: descriptor(for: state.work, includeObservation: true)!, attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                rejection: .staleCursor, diagnostic: "attach causal cursor is not current")
            attachCommands[key] = StoredAttach(request: request, response: response)
            works[state.work] = state
            return response
        }
        let id = ClientAttachmentRef("attachment-\(nextAttachmentOrdinal)")
        nextAttachmentOrdinal += 1
        let attachment = WorkServiceClientAttachment(
            attachment: id, client: request.client, session: request.session,
            sessionJournal: request.sessionJournal,
            sessionAttachment: request.sessionAttachment, authorization: authorization,
            readAcknowledgements: [])
        state.attachments[id] = ClientState(attachment: attachment)
        works[request.work] = state
        let resultingControlCursor = appendControlEvent()
        let response = WorkServiceAttachResponse(
            work: descriptor(for: state.work, includeObservation: true)!,
            attachment: attachment, authorization: authorization,
            commandID: request.commandID, host: hostInstance,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor)
        attachCommands[key] = StoredAttach(request: request, response: response)
        return response
    }

    public func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse {
        try requireReachable()
        guard var state = works[request.work] else { throw WorkServiceProtocolError.workNotFound(request.work) }
        guard request.journal == state.journal else { throw WorkServiceProtocolError.journalMismatch }
        guard validIdentity(request.client.clientID), validIdentity(request.commandID),
              validCursor(request.causalControlCursor, journal: controlJournal) else {
            throw WorkServiceProtocolError.invalidRequest("invalid detach client or command identity")
        }
        let key = AttachmentCommandKey(work: request.work, client: request.client,
                                       commandID: request.commandID)
        if let prior = detachCommands[key] {
            guard prior.request == request else {
                return WorkServiceDetachResponse(
                    work: prior.response.work, commandID: request.commandID, state: .rejected,
                    host: prior.response.host,
                    causalControlCursor: request.causalControlCursor,
                    resultingControlCursor: prior.response.resultingControlCursor,
                    receipt: controlReceipt(
                        operation: .detach, work: prior.response.work,
                        commandID: request.commandID, state: .rejected,
                        causalControlCursor: request.causalControlCursor,
                        resultingControlCursor: prior.response.resultingControlCursor,
                        authorization: prior.response.receipt.authorization,
                        rejection: .conflictingCommand,
                        diagnostic: "detach command ID was already used with different contents"),
                    rejection: .conflictingCommand,
                    diagnostic: "detach command ID was already used with different contents")
            }
            let duplicateReceipt = duplicateControl(of: prior.response.receipt)
            return WorkServiceDetachResponse(
                work: prior.response.work, commandID: request.commandID,
                state: prior.response.state == .rejected ? .rejected : .duplicate,
                host: prior.response.host,
                causalControlCursor: prior.response.causalControlCursor,
                resultingControlCursor: prior.response.resultingControlCursor,
                receipt: duplicateReceipt,
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
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                rejection: .terminalProofUnavailable,
                diagnostic: "a terminal Work transaction is already in progress")
            detachCommands[key] = StoredDetach(request: request, response: response)
            works[state.work] = state
            return response
        }
        guard state.sourceCompleteness == .complete else {
            let response = WorkServiceDetachResponse(
                work: request.work, commandID: request.commandID, state: .rejected,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                rejection: .sourceIncomplete,
                diagnostic: "host source is not complete enough to detach canonically")
            detachCommands[key] = StoredDetach(request: request, response: response)
            // No event, attachment, cursor, or host-order mutation is claimed.
            works[state.work] = state
            return response
        }
        if request.causalControlCursor != controlCursor {
            let response = WorkServiceDetachResponse(
                work: request.work, commandID: request.commandID, state: .rejected,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                rejection: .staleCursor, diagnostic: "detach causal cursor is not current")
            detachCommands[key] = StoredDetach(request: request, response: response)
            works[state.work] = state
            return response
        }
        state.attachments.removeValue(forKey: request.attachment)
        state.readAcknowledgements = state.readAcknowledgements.filter {
            $0.key.attachment != request.attachment
        }
        works[request.work] = state
        let resultingControlCursor = appendControlEvent()
        let response = WorkServiceDetachResponse(
            work: request.work, commandID: request.commandID, state: .accepted,
            host: hostInstance, causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor)
        detachCommands[key] = StoredDetach(request: request, response: response)
        return response
    }

    public func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot {
        try requireReachable()
        let state = try attachedState(work: request.work, journal: request.journal,
                                      attachment: request.attachment, client: request.client,
                                      requiring: .observe)
        let target = try readTarget(request.target, for: state, attachment: request.attachment)
        let after = try validatedAfter(request.afterCursor, journal: target.journal,
                                       cursor: target.cursor, events: target.events)
        let limit = try boundedPageSize(request.limit, max: WorkServiceBounds.maxEventsPerPage)
        let (events, bytesLimited) = try boundedEventPage(
            target.events, after: after, limit: limit, maxBytes: request.maxBytes)
        let next = events.last.map {
            JournalCursor(journal: target.journal, eventID: $0.eventID, sequence: $0.sequence)
        }
        var omissions: [WorkServiceOmission] = []
        if bytesLimited {
            omissions.append(WorkServiceOmission(
                category: "event_bytes", count: 1,
                diagnostic: "event page byte limit stopped the page"))
        } else if target.events.contains(where: { $0.sequence > (next?.sequence ?? after) }) {
            omissions.append(WorkServiceOmission(
                category: "events", count: 1, diagnostic: "more events available"))
        }
        let baselineCursor = request.afterCursor
            ?? JournalCursor(journal: target.journal, sequence: 0)
        return WorkServiceSnapshot(work: descriptor(for: state.work, includeObservation: true)!,
                                   events: events, target: request.target,
                                   servedCursor: events.last.map {
                                       JournalCursor(journal: target.journal,
                                                     eventID: $0.eventID, sequence: $0.sequence)
                                   } ?? baselineCursor,
                                   omissions: omissions)
    }

    public func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws -> WorkServiceEventPage {
        try requireReachable()
        let state = try attachedState(work: request.work, journal: request.journal,
                                      attachment: request.attachment, client: request.client,
                                      requiring: .observe)
        let target = try readTarget(request.target, for: state, attachment: request.attachment)
        let after = try validatedAfter(request.afterCursor, journal: target.journal,
                                       cursor: target.cursor, events: target.events)
        let limit = try boundedPageSize(request.limit, max: WorkServiceBounds.maxEventsPerPage)
        let (events, bytesLimited) = try boundedEventPage(
            target.events, after: after, limit: limit, maxBytes: request.maxBytes)
        let next = events.last.map {
            JournalCursor(journal: target.journal, eventID: $0.eventID, sequence: $0.sequence)
        }
        let availableCount = target.events.reduce(into: 0) { count, event in
            if event.sequence > after { count += 1 }
        }
        let hasMore = availableCount > events.count
        return WorkServiceEventPage(
            events: events, target: request.target,
            servedCursor: events.last.map {
                JournalCursor(journal: target.journal, eventID: $0.eventID, sequence: $0.sequence)
            } ?? request.afterCursor,
            nextCursor: hasMore ? next : nil,
            omissions: hasMore
                ? [WorkServiceOmission(
                    category: bytesLimited ? "event_bytes" : "events",
                    count: bytesLimited ? 1 : availableCount - events.count,
                    diagnostic: bytesLimited
                        ? "event page byte limit stopped the page" : nil)]
                : [])
    }

    public func updateCapabilities(
        _ request: WorkServiceUpdateCapabilitiesRequest
    ) async throws -> WorkServiceUpdateCapabilitiesResponse {
        try requireReachable()
        guard var state = works[request.work] else {
            throw WorkServiceProtocolError.workNotFound(request.work)
        }
        guard request.journal == state.journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard validIdentity(request.client.clientID), validIdentity(request.commandID),
              validCursor(request.causalControlCursor, journal: controlJournal) else {
            throw WorkServiceProtocolError.invalidRequest(
                "invalid capability mutation identity")
        }
        let key = AttachmentCommandKey(
            work: request.work, client: request.client, commandID: request.commandID)
        if let prior = capabilityCommands[key] {
            guard prior.request == request else {
                let receipt = controlReceipt(
                    operation: .updateCapabilities, work: request.work,
                    commandID: request.commandID, state: .rejected,
                    causalControlCursor: request.causalControlCursor,
                    resultingControlCursor: prior.response.resultingControlCursor,
                    authorization: prior.response.authorization,
                    rejection: .conflictingCommand,
                    diagnostic: "capability command ID was already used with different contents")
                return WorkServiceUpdateCapabilitiesResponse(
                    work: request.work, attachment: nil,
                    authorization: prior.response.authorization, commandID: request.commandID,
                    state: .rejected, host: prior.response.host,
                    causalControlCursor: request.causalControlCursor,
                    resultingControlCursor: prior.response.resultingControlCursor,
                    receipt: receipt, rejection: .conflictingCommand,
                    diagnostic: "capability command ID was already used with different contents")
            }
            let duplicate = duplicateControl(of: prior.response.receipt)
            return WorkServiceUpdateCapabilitiesResponse(
                work: prior.response.work, attachment: prior.response.attachment,
                authorization: prior.response.authorization, commandID: request.commandID,
                state: prior.response.state == .rejected ? .rejected : .duplicate,
                host: prior.response.host,
                causalControlCursor: prior.response.causalControlCursor,
                resultingControlCursor: prior.response.resultingControlCursor,
                receipt: duplicate, rejection: prior.response.rejection,
                diagnostic: prior.response.state == .rejected
                    ? prior.response.diagnostic : "idempotent duplicate")
        }
        guard let current = state.attachments[request.attachment],
              current.attachment.client == request.client else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        let authorization = authorization(
            for: request.client, requested: request.requestedCapabilities)
        func rejected(
            _ rejection: WorkServiceCommandRejection, _ diagnostic: String
        ) -> WorkServiceUpdateCapabilitiesResponse {
            let receipt = controlReceipt(
                operation: .updateCapabilities, work: request.work,
                commandID: request.commandID, state: .rejected,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor, authorization: authorization,
                rejection: rejection, diagnostic: diagnostic)
            let response = WorkServiceUpdateCapabilitiesResponse(
                work: request.work, attachment: nil, authorization: authorization,
                commandID: request.commandID, state: .rejected, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor, receipt: receipt,
                rejection: rejection, diagnostic: diagnostic)
            capabilityCommands[key] = StoredCapabilities(request: request, response: response)
            works[state.work] = state
            return response
        }
        guard current.attachment.authorization.allows(.control) else {
            return rejected(.authorizationDenied,
                            "client attachment does not grant capability control")
        }
        guard request.causalControlCursor == controlCursor else {
            return rejected(.staleCursor,
                            "capability causal control cursor is not current")
        }
        let updated = WorkServiceClientAttachment(
            attachment: current.attachment.attachment, client: current.attachment.client,
            session: current.attachment.session, sessionJournal: current.attachment.sessionJournal,
            sessionAttachment: current.attachment.sessionAttachment,
            authorization: authorization,
            readAcknowledgements: readAcknowledgements(
                for: current.attachment.attachment, state: state))
        state.attachments[request.attachment] = ClientState(attachment: updated)
        works[state.work] = state
        let resultingControlCursor = appendControlEvent()
        let receipt = controlReceipt(
            operation: .updateCapabilities, work: request.work,
            commandID: request.commandID, state: .accepted,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor,
            authorization: authorization, outcome: .capabilitiesUpdated)
        let response = WorkServiceUpdateCapabilitiesResponse(
            work: request.work, attachment: updated, authorization: authorization,
            commandID: request.commandID, state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor, receipt: receipt)
        capabilityCommands[key] = StoredCapabilities(request: request, response: response)
        return response
    }

    public func acknowledgeRead(
        _ request: WorkServiceAcknowledgeReadRequest
    ) async throws -> WorkServiceAcknowledgeReadResponse {
        try requireReachable()
        guard var state = works[request.work] else {
            throw WorkServiceProtocolError.workNotFound(request.work)
        }
        guard request.journal == state.journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard validIdentity(request.client.clientID), validIdentity(request.commandID),
              validCursor(request.causalControlCursor, journal: controlJournal) else {
            throw WorkServiceProtocolError.invalidRequest(
                "invalid read acknowledgement identity")
        }
        let key = AttachmentCommandKey(
            work: request.work, client: request.client, commandID: request.commandID)
        if let prior = readAcknowledgementCommands[key] {
            guard prior.request == request else {
                let receipt = controlReceipt(
                    operation: .acknowledgeRead, work: request.work,
                    commandID: request.commandID, state: .rejected,
                    causalControlCursor: request.causalControlCursor,
                    resultingControlCursor: prior.response.resultingControlCursor,
                    authorization: prior.response.receipt.authorization,
                    rejection: .conflictingCommand,
                    diagnostic: "read acknowledgement ID was already used with different contents")
                return WorkServiceAcknowledgeReadResponse(
                    work: request.work, target: request.target, cursor: request.cursor,
                    commandID: request.commandID, state: .rejected, host: prior.response.host,
                    causalControlCursor: request.causalControlCursor,
                    resultingControlCursor: prior.response.resultingControlCursor,
                    authorization: prior.response.receipt.authorization, receipt: receipt,
                    rejection: .conflictingCommand,
                    diagnostic: "read acknowledgement ID was already used with different contents")
            }
            let duplicate = duplicateControl(of: prior.response.receipt)
            return WorkServiceAcknowledgeReadResponse(
                work: prior.response.work, target: prior.response.target, cursor: prior.response.cursor,
                commandID: request.commandID,
                state: prior.response.state == .rejected ? .rejected : .duplicate,
                host: prior.response.host, causalControlCursor: prior.response.causalControlCursor,
                resultingControlCursor: prior.response.resultingControlCursor,
                authorization: prior.response.receipt.authorization, receipt: duplicate,
                rejection: prior.response.rejection,
                diagnostic: prior.response.state == .rejected
                    ? prior.response.diagnostic : "idempotent duplicate")
        }
        guard let current = state.attachments[request.attachment],
              current.attachment.client == request.client else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        let authorization = current.attachment.authorization
        func rejected(
            _ rejection: WorkServiceCommandRejection, _ diagnostic: String
        ) -> WorkServiceAcknowledgeReadResponse {
            let receipt = controlReceipt(
                operation: .acknowledgeRead, work: request.work,
                commandID: request.commandID, state: .rejected,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor, authorization: authorization,
                rejection: rejection, diagnostic: diagnostic)
            let response = WorkServiceAcknowledgeReadResponse(
                work: request.work, target: request.target, cursor: request.cursor,
                commandID: request.commandID, state: .rejected, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor, authorization: authorization,
                receipt: receipt, rejection: rejection, diagnostic: diagnostic)
            readAcknowledgementCommands[key] = StoredReadAcknowledgement(
                request: request, response: response)
            works[state.work] = state
            return response
        }
        guard current.attachment.authorization.allows(.observe) else {
            return rejected(.authorizationDenied,
                            "client attachment does not grant observation")
        }
        let target = try readTarget(request.target, for: state, attachment: request.attachment)
        guard request.cursor.journal == target.journal else {
            return rejected(.malformedRequest,
                            "read acknowledgement cursor belongs to another journal")
        }
        _ = try validatedAfter(request.cursor, journal: target.journal,
                               cursor: target.cursor, events: target.events)
        let ackKey = ReadAcknowledgementKey(
            attachment: request.attachment, targetJournal: target.journal)
        if let previous = state.readAcknowledgements[ackKey] {
            guard request.cursor.sequence >= previous.sequence else {
                return rejected(.staleCursor, "read acknowledgement moved backwards")
            }
            if request.cursor.sequence == previous.sequence,
               request.cursor.eventID != previous.eventID {
                return rejected(.conflictingCommand,
                                "read acknowledgement conflicts at one sequence")
            }
        }
        guard request.causalControlCursor == controlCursor else {
            return rejected(.staleCursor,
                            "read acknowledgement causal control cursor is not current")
        }
        state.readAcknowledgements[ackKey] = request.cursor
        works[state.work] = state
        let resultingControlCursor = appendControlEvent()
        let receipt = controlReceipt(
            operation: .acknowledgeRead, work: request.work,
            commandID: request.commandID, state: .accepted,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor,
            authorization: authorization, outcome: .readAcknowledged)
        let response = WorkServiceAcknowledgeReadResponse(
            work: request.work, target: request.target, cursor: request.cursor,
            commandID: request.commandID, state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor, authorization: authorization,
            receipt: receipt)
        readAcknowledgementCommands[key] = StoredReadAcknowledgement(
            request: request, response: response)
        return response
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
        let bodyJournal = request.reference.authority
        guard bodyJournal == state.journal || bodyJournal == state.sessionJournal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard validBodyReference(request.reference, journal: bodyJournal) else {
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
        guard validIdentity(request.command.commandID), request.command.commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              let clientID = request.command.client,
              request.command.causalCursor == request.causalWorkCursor else {
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
                causalWorkCursor: prior.receipt.causalWorkCursor,
                resultingWorkCursor: prior.receipt.resultingWorkCursor,
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
            || (request.value?.utf8.count ?? 0) > WorkServiceBounds.maxCommandValueCharacters {
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
        let causal = request.causalWorkCursor
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
        let hostSequence = state.nextHostSequence
        state.nextHostSequence += 1
        let eventCursor = appendEvent(
            kind: request.kind.rawValue, commandID: request.command.commandID,
            command: request.command, body: request.value, hostSequence: hostSequence,
            state: &state)
        let receipt = WorkServiceCommandReceipt(
            work: state.work, commandID: request.command.commandID, state: .accepted,
            host: hostInstance, hostSequence: hostSequence,
            causalWorkCursor: request.causalWorkCursor, resultingWorkCursor: eventCursor,
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
        WorkServiceText.valid(value) && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
    }

    private func validCursor(_ cursor: JournalCursor, journal: JournalRef) -> Bool {
        cursor.journal == journal
            && cursor.sequence >= 0 && cursor.sequence < Int.max
            && (cursor.sequence == 0
                ? cursor.eventID == nil
                : (cursor.eventID.map(validIdentity) ?? false))
    }

    private func validBodyReference(_ reference: TimelineBodyReference, journal: JournalRef) -> Bool {
        reference.authority == journal
            && validIdentity(reference.referenceID)
            && (reference.mediaType?.utf8.count ?? 0) <= WorkServiceBounds.maxDiagnosticCharacters
            && (reference.byteCount ?? -1) >= 0
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

    private func readTarget(
        _ target: WorkServiceReadTarget,
        for state: WorkState,
        attachment: ClientAttachmentRef
    ) throws -> (journal: JournalRef, cursor: JournalCursor, events: [TimelineEvent]) {
        guard let attachmentState = state.attachments[attachment] else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        switch target {
        case .work(let journal):
            guard journal == state.journal else {
                throw WorkServiceProtocolError.journalMismatch
            }
            return (journal, state.cursor ?? JournalCursor(journal: journal, sequence: 0), state.events)
        case .session(let session, let journal):
            guard attachmentState.attachment.session == session,
                  attachmentState.attachment.sessionJournal == journal,
                  journal.owner == .session(session) else {
                throw WorkServiceProtocolError.invalidRequest(
                    "Session read target is not attached to this Work/client attachment")
            }
            let cursor = state.session == session && state.sessionJournal == journal
                ? (state.sessionCursor ?? JournalCursor(journal: journal, sequence: 0))
                : JournalCursor(journal: journal, sequence: 0)
            let events = state.session == session && state.sessionJournal == journal
                ? state.sessionEvents : []
            return (journal, cursor, events)
        }
    }

    private func validatedAfter(
        _ after: JournalCursor?,
        journal: JournalRef,
        cursor: JournalCursor,
        events: [TimelineEvent]
    ) throws -> Int {
        guard let after else { return 0 }
        guard after.journal == journal, after.sequence >= 0,
              after.sequence <= cursor.sequence else {
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
        if after == cursor { return after.sequence }
        guard let event = events.first(where: { $0.sequence == after.sequence }),
              event.journal == after.journal,
              event.eventID == after.eventID else {
            throw WorkServiceProtocolError.invalidRequest("cursor event identity is unknown")
        }
        return after.sequence
    }

    private func boundedEventPage(
        _ events: [TimelineEvent], after: Int, limit: Int, maxBytes: Int
    ) throws -> (events: [TimelineEvent], bytesLimited: Bool) {
        guard maxBytes > 0 else {
            throw WorkServiceProtocolError.invalidRequest("event page byte limit must be positive")
        }
        let byteLimit = min(maxBytes, WorkServiceBounds.maxEventPageBytes)
        var selected: [TimelineEvent] = []
        var encodedBytes = 0
        var bytesLimited = false
        for event in events where event.sequence > after {
            if selected.count >= limit { break }
            let eventBytes = try JSONEncoder().encode(event).count
            guard eventBytes <= byteLimit - encodedBytes else {
                if selected.isEmpty {
                    throw WorkServiceProtocolError.eventPageCannotProgress(
                        requiredBytes: eventBytes, maximumBytes: byteLimit)
                }
                bytesLimited = true
                break
            }
            selected.append(event)
            encodedBytes += eventBytes
        }
        return (selected, bytesLimited)
    }

    private func readAcknowledgements(
        for attachment: ClientAttachmentRef,
        state: WorkState
    ) -> [WorkServiceReadAcknowledgement] {
        guard let clientAttachment = state.attachments[attachment]?.attachment else { return [] }
        return state.readAcknowledgements.compactMap {
            entry -> WorkServiceReadAcknowledgement? in
            let (key, cursor) = entry
            guard key.attachment == attachment else { return nil }
            let target: WorkServiceReadTarget
            if key.targetJournal == state.journal {
                target = .work(journal: state.journal)
            } else if let session = clientAttachment.session,
                      let sessionJournal = clientAttachment.sessionJournal,
                      key.targetJournal == sessionJournal {
                target = .session(session: session, journal: sessionJournal)
            } else {
                return nil
            }
            return WorkServiceReadAcknowledgement(target: target, cursor: cursor)
        }.sorted { lhs, rhs in
            lhs.target.journal.stableKey < rhs.target.journal.stableKey
        }
    }

    private func attachmentProjection(
        _ attachment: WorkServiceClientAttachment,
        state: WorkState
    ) -> WorkServiceClientAttachment {
        WorkServiceClientAttachment(
            attachment: attachment.attachment,
            client: attachment.client,
            session: attachment.session,
            sessionJournal: attachment.sessionJournal,
            sessionAttachment: attachment.sessionAttachment,
            authorization: attachment.authorization,
            readAcknowledgements: readAcknowledgements(
                for: attachment.attachment, state: state))
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

    private func descriptor(for work: WorkRef, includeObservation: Bool) -> WorkServiceWorkDescriptor? {
        guard let state = works[work] else { return nil }
        let observation = includeObservation ? WorkServiceHostObservation(
            instance: hostInstance, reachability: reachable ? .observedReachable : .unavailable,
            currentRun: state.currentRun, servedCursor: state.cursor,
            sourceCompleteness: state.sourceCompleteness) : nil
        let clients = Array(state.attachments.values.map {
            attachmentProjection($0.attachment, state: state)
        }
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
            configuration: state.configuration.observableDescriptorConfiguration,
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
        let expectedCausalEvent = proof.causalWorkCursor.eventID.map {
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
              proof.terminalEvent.journal == proof.resultingWorkCursor.journal,
              proof.terminalEvent.sequence == proof.resultingWorkCursor.sequence,
              proof.terminalEvent.eventID == proof.resultingWorkCursor.eventID,
              proof.terminalEvent.type == request.operation.eventKind,
              proof.terminalEvent.idempotencyKey
                  == WorkServiceTerminalCommitProof.terminalIdempotencyKey(
                      type: proof.terminalEvent.type, command: request.command,
                      detail: request.detail),
              proof.terminalEvent.work == request.work,
              proof.terminalEvent.workHost == WorkHostRef(request.work.workHostID),
              proof.terminalEvent.session == request.session,
              proof.terminalEvent.client == request.client,
              proof.terminalEvent.sessionAttachment == request.sessionAttachment,
              proof.terminalEvent.command == request.command,
              proof.terminalEvent.causedByEventID == expectedCausalEvent,
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
                host: hostInstance,
                causalWorkCursor: JournalCursor(journal: .work(work), sequence: 0),
                resultingWorkCursor: nil, authorization: authorization,
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
                host: hostInstance,
                causalWorkCursor: reservation.request.causalWorkCursor,
                resultingWorkCursor: state.cursor, authorization: authorization,
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
                causalWorkCursor: latestReservation.request.causalWorkCursor,
                resultingWorkCursor: proof.resultingWorkCursor,
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
            causalWorkCursor: receipt.causalWorkCursor,
            resultingWorkCursor: receipt.resultingWorkCursor,
            authorization: receipt.authorization, outcome: receipt.outcome,
            rejection: receipt.rejection, terminalProof: receipt.terminalProof,
            diagnostic: receipt.state == .rejected ? receipt.diagnostic : "idempotent duplicate")
    }

    private func appendEvent(kind: String, commandID: String?, command: CommandRef? = nil,
                             body: String? = nil, hostSequence: Int? = nil,
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
        let payload: JSONValue
        if let bodyReference,
           let encoded = try? JSONEncoder().encode(bodyReference),
           let referenceValue = JSONValue.parse(encoded) {
            // Keep sensitive/large command text in the retained body store only. The canonical
            // event envelope carries the authority-bearing reference so a reader can fetch the
            // exact bytes without retaining a second raw copy in the timeline page.
            payload = .object(["body_reference": referenceValue])
        } else {
            // Never copy the body into the event as a serialization fallback.  The body store
            // remains the only place where command text is retained; an unexpected reference
            // encoding failure is represented by a bounded marker instead of leaking raw text.
            payload = body == nil
                ? .object([:])
                : .object(["body_reference_unavailable": .bool(true)])
        }
        state.events.append(TimelineEvent(
            eventID: eventID, journal: state.journal, sequence: sequence,
            hostSequence: hostSequence, idempotencyKey: commandID, command: command,
            previousEventID: state.events.last?.eventID,
            session: state.session, work: state.work, workHost: host,
            client: command?.client, sessionAttachment: command?.sessionAttachment,
            run: state.currentRun,
            actor: TimelineActor(actorID: hostInstance.instanceID, kind: "work-service"),
            hostRecordedAt: Date(), type: WorkServiceText.bound(kind) ?? "unknown",
            payload: payload))
        return cursor
    }

    private func appendSessionEvent(kind: String, commandID: String?, command: CommandRef? = nil,
                                    body: String? = nil, state: inout WorkState) -> JournalCursor? {
        guard let session = state.session, let journal = state.sessionJournal else { return nil }
        let sequence = state.nextSessionEventSequence
        state.nextSessionEventSequence += 1
        let eventID = "service-session-event-" + String(sequence)
        let cursor = JournalCursor(journal: journal, eventID: eventID, sequence: sequence)
        state.sessionCursor = cursor
        let payload: JSONValue
        if let body, !body.isEmpty {
            payload = .object(["value": .string(body)])
        } else {
            payload = .object([:])
        }
        state.sessionEvents.append(TimelineEvent(
            eventID: eventID, journal: journal, sequence: sequence,
            idempotencyKey: commandID, command: command,
            previousEventID: state.sessionEvents.last?.eventID, session: session,
            work: state.work, workHost: host, client: command?.client,
            sessionAttachment: state.sessionAttachment ?? command?.sessionAttachment,
            actor: TimelineActor(actorID: hostInstance.instanceID, kind: "work-service"),
            hostRecordedAt: Date(), type: WorkServiceText.bound(kind) ?? "unknown",
            payload: payload))
        return cursor
    }

    private func makeReceipt(state: inout WorkState, request: WorkServiceCommandRequest,
                             authorization: WorkServiceAuthorizationOutcome,
                             state receiptState: WorkServiceCommandReceiptState,
                             rejection: WorkServiceCommandRejection,
                             diagnostic: String) -> WorkServiceCommandReceipt {
        return WorkServiceCommandReceipt(
            work: state.work, commandID: request.command.commandID, state: receiptState,
            host: hostInstance,
            causalWorkCursor: request.causalWorkCursor, resultingWorkCursor: state.cursor,
            authorization: authorization, rejection: rejection, diagnostic: diagnostic)
    }

    private func appendControlEvent() -> JournalCursor {
        let next = controlCursor.sequence == Int.max ? Int.max : controlCursor.sequence + 1
        let eventID = "control-event-\(next)"
        controlCursor = JournalCursor(
            journal: controlJournal, eventID: eventID, sequence: next)
        return controlCursor
    }

    private func controlReceipt(
        operation: WorkServiceControlOperation,
        work: WorkRef,
        commandID: String,
        state: WorkServiceCommandReceiptState,
        causalControlCursor: JournalCursor,
        resultingControlCursor: JournalCursor,
        authorization: WorkServiceAuthorizationOutcome,
        outcome: WorkServiceControlOutcome? = nil,
        rejection: WorkServiceCommandRejection? = nil,
        diagnostic: String? = nil
    ) -> WorkServiceControlReceipt {
        WorkServiceControlReceipt(
            operation: operation, work: work, commandID: commandID, state: state,
            host: hostInstance, causalControlCursor: causalControlCursor,
            resultingControlCursor: resultingControlCursor, authorization: authorization,
            outcome: outcome, rejection: rejection, diagnostic: diagnostic)
    }

    private func duplicateControl(
        of receipt: WorkServiceControlReceipt
    ) -> WorkServiceControlReceipt {
        WorkServiceControlReceipt(
            operation: receipt.operation, work: receipt.work, commandID: receipt.commandID,
            state: receipt.state == .rejected ? .rejected : .duplicate,
            host: receipt.host, causalControlCursor: receipt.causalControlCursor,
            resultingControlCursor: receipt.resultingControlCursor,
            authorization: receipt.authorization, outcome: receipt.outcome,
            rejection: receipt.rejection,
            diagnostic: receipt.state == .rejected
                ? receipt.diagnostic : "idempotent duplicate")
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
        guard value.utf8.count > WorkServiceBounds.maxDiagnosticCharacters else { return value }
        return String(decoding: value.utf8.prefix(WorkServiceBounds.maxDiagnosticCharacters), as: UTF8.self)
    }

    static func boundCommand(_ value: String?) -> BoundedCommandValue {
        guard let value else { return BoundedCommandValue(value: nil, wasTruncated: false) }
        guard value.utf8.count > WorkServiceBounds.maxCommandValueCharacters else {
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
