import Foundation

// MARK: - Transport-neutral Work service contract

/// The protocol spoken by a GUI and a Work Host.  The first implementation below is an
/// in-memory reference service; a Unix-domain socket and a remote transport can encode these
/// values without changing their meaning.
public enum WorkServiceProtocol {
    // Version 5 requires canonical provider admission and terminal settlement evidence. There is
    // deliberately no v4 compatibility path: an older daemon must fail discovery/handshake
    // negotiation instead of accepting a GUI whose provider records it cannot produce.
    public static let currentVersion = 5
    public static let minimumSupportedVersion = 5
    public static let maximumSupportedVersion = 5
}

/// A bounded surface is intentional: protocol values must be safe to render even when a remote
/// host or an agent supplied an unexpectedly large identity or diagnostic.
public enum WorkServiceBounds {
    public static let maxIdentityCharacters = 256
    public static let maxDiagnosticCharacters = 512
    public static let maxCommandValueCharacters = 8_192
    public static let maxPageSize = 64
    public static let maxEventsPerPage = 128
    /// A page is bounded by the sum of its standalone canonical event-envelope encodings as well
    /// as event count. Array delimiters, transport framing, and journal newlines are deliberately
    /// excluded so every service, transport, and reader can enforce the same limit.
    public static let maxEventPageBytes = 256 * 1024
    public static let maxBodyChunkBytes = 64 * 1024
    public static let maxTerminalProofHandles = 128
    public static let maxArtifactsPerWork = 128
    public static let maxAttachmentsPerWork = 64
    public static let maxSessionAttachmentsPerWork = 64
    /// One client attachment currently has at most a Work target and its bound Session target.
    /// Keep this independently bounded so descriptor reconstruction cannot grow without limit.
    public static let maxReadAcknowledgementsPerAttachment = 2
    public static let maxOmissions = 32
    public static let maxOmissionCount = 1_000_000
}

/// The single protocol byte metric for a Work event page. Keeping this outside any transport or
/// journal implementation prevents a valid exact-boundary page from changing size as it crosses
/// from durable JSONL, through a response envelope, into a controller.
public enum WorkServiceEventPageSizing {
    public static func encodedByteCount(of event: TimelineEvent) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(event).count
    }

    public static func encodedByteCount(of events: [TimelineEvent]) throws -> Int {
        var total = 0
        for event in events {
            let count = try encodedByteCount(of: event)
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else {
                throw WorkServiceProtocolError.invalidRequest(
                    "event page encoded byte count overflowed")
            }
            total = next
        }
        return total
    }
}

/// Maps a caller-local command identity into the single canonical Work-ledger namespace shared by
/// every attached client. External requests and receipts retain the caller's original ID; only
/// Timeline command records use this bounded, client-qualified identity.
public enum WorkServiceCommandLedgerIdentity {
    public static func commandID(client: ClientRef, commandID: String) -> String {
        var material = Data("work-command-ledger-v1\u{0}".utf8)
        material.append(Data("\(client.clientID.utf8.count):".utf8))
        material.append(Data(client.clientID.utf8))
        material.append(0)
        material.append(Data("\(commandID.utf8.count):".utf8))
        material.append(Data(commandID.utf8))
        let digest = AviarySHA256.hash(data: material).map {
            String(format: "%02x", $0)
        }.joined()
        return "work-command-v1." + digest
    }

    public static func command(from external: CommandRef, client: ClientRef) -> CommandRef {
        CommandRef(
            commandID: commandID(client: client, commandID: external.commandID),
            client: client,
            sessionAttachment: external.sessionAttachment,
            causalCursor: external.causalCursor)
    }
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
    /// A bounded, path-free inventory of workspaces this Host is willing to resolve. The host
    /// mints each identity; clients may select only one of these opaque IDs in Create.
    public let workspaceCatalog: WorkHostWorkspaceCatalog
    public let diagnostic: String?

    public init(accepted: Bool, negotiatedVersion: Int?, supportedRange: ClosedRange<Int>,
                host: WorkHostRef, hostInstance: WorkHostInstanceRef,
                controlJournal: JournalRef, controlCursor: JournalCursor,
                capabilities: Set<WorkServiceCapability>,
                workspaceCatalog: WorkHostWorkspaceCatalog = .empty,
                diagnostic: String? = nil) {
        self.accepted = accepted
        self.negotiatedVersion = negotiatedVersion
        self.supportedRange = supportedRange
        self.host = host
        self.hostInstance = hostInstance
        self.controlJournal = controlJournal
        self.controlCursor = controlCursor
        self.capabilities = capabilities
        self.workspaceCatalog = workspaceCatalog
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
    case createSession = "create_session"
    case attach
    case detach
    case updateCapabilities = "update_capabilities"
    case acknowledgeRead = "acknowledge_read"
}

public enum WorkServiceControlOutcome: String, Codable, Hashable, Sendable {
    case created
    case sessionCreated = "session_created"
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
    /// Exact Session/attachment that owns ``currentRun`` in the canonical Work journal.  A
    /// host observation may omit all three values when its source is incomplete; it must never
    /// substitute the Work's creation Session.
    public let currentRunSession: SessionRef?
    public let currentRunSessionAttachment: SessionAttachmentRef?
    public let servedCursor: JournalCursor?
    public let sourceCompleteness: WorkServiceSourceCompleteness

    public init(instance: WorkHostInstanceRef, reachability: WorkServiceHostReachability,
                currentRun: RunRef?, currentRunSession: SessionRef?,
                currentRunSessionAttachment: SessionAttachmentRef?,
                servedCursor: JournalCursor?,
                sourceCompleteness: WorkServiceSourceCompleteness) throws {
        guard (currentRun == nil) == (currentRunSession == nil),
              (currentRun == nil) == (currentRunSessionAttachment == nil) else {
            throw WorkServiceProtocolError.invalidRequest(
                "an observed Run must have exactly one Session/attachment owner envelope")
        }
        self.instance = instance
        self.reachability = reachability
        self.currentRun = currentRun
        self.currentRunSession = currentRunSession
        self.currentRunSessionAttachment = currentRunSessionAttachment
        self.servedCursor = servedCursor
        self.sourceCompleteness = sourceCompleteness
    }

    private enum CodingKeys: String, CodingKey {
        case instance, reachability, currentRun, currentRunSession,
             currentRunSessionAttachment, servedCursor, sourceCompleteness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currentRun = try container.decodeIfPresent(RunRef.self, forKey: .currentRun)
        let currentRunSession = try container.decodeIfPresent(
            SessionRef.self, forKey: .currentRunSession)
        let currentRunSessionAttachment = try container.decodeIfPresent(
            SessionAttachmentRef.self, forKey: .currentRunSessionAttachment)
        guard (currentRun == nil) == (currentRunSession == nil),
              (currentRun == nil) == (currentRunSessionAttachment == nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .currentRun, in: container,
                debugDescription: "observed Run owner must be an all-nil or all-present tuple")
        }
        self.instance = try container.decode(WorkHostInstanceRef.self, forKey: .instance)
        self.reachability = try container.decode(
            WorkServiceHostReachability.self, forKey: .reachability)
        self.currentRun = currentRun
        self.currentRunSession = currentRunSession
        self.currentRunSessionAttachment = currentRunSessionAttachment
        self.servedCursor = try container.decodeIfPresent(JournalCursor.self, forKey: .servedCursor)
        self.sourceCompleteness = try container.decode(
            WorkServiceSourceCompleteness.self, forKey: .sourceCompleteness)
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
    /// Durable execution evidence exists, but this service has not proved that a live actor can
    /// safely continue it. This is deliberately non-actionable: it must never be treated as idle.
    case recoveryRequired = "recovery_required"
    /// The durable reducer/source could not project an execution state that this protocol knows.
    /// Unknown state is also non-actionable and must not be guessed into idle.
    case unknown
}

public struct WorkServiceOmission: Codable, Hashable, Sendable {
    public let category: String
    public let count: Int
    public let diagnostic: String?

    public init(category: String, count: Int, diagnostic: String? = nil) {
        self.category = WorkServiceText.bound(category) ?? "unknown"
        self.count = min(WorkServiceBounds.maxOmissionCount, max(0, count))
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }

    private enum CodingKeys: String, CodingKey { case category, count, diagnostic }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let count = try container.decode(Int.self, forKey: .count)
        guard count >= 0, count <= WorkServiceBounds.maxOmissionCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .count, in: container,
                debugDescription: "Work service omission count exceeds the protocol bound")
        }
        self.init(
            category: try container.decode(String.self, forKey: .category), count: count,
            diagnostic: try container.decodeIfPresent(String.self, forKey: .diagnostic))
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
    /// The host can advertise and resolve opaque workspace identities.
    case workspaceCatalog = "workspace_catalog"
    /// The host captures its local recording-folder preference in each retained Work template.
    /// This advertises behavior, never a path or authority to modify remote filesystem settings.
    case recordingDirectorySelection = "recording_directory_selection"
    /// The client may ask the Work Host to mint and durably attach another Session to existing Work.
    case createSession = "create_session"
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

/// The durable semantic relationship between an existing Work and one Session. This is separate
/// from ``WorkServiceClientAttachment``: several GUI/device attachments may observe the same
/// Session relationship, while the relationship itself remains owned by the Work/Session
/// journals. A descriptor never grants authority; its cursors and publication describe exactly
/// which journal evidence was recorded by the host.
public enum WorkServiceSessionAttachmentPublication: String, Codable, Hashable, Sendable {
    /// The Work journal contains the corresponding ``session.attached`` mirror.
    case mirrored
    /// Work is terminal and cannot be changed; the relationship is a read-only reference to the
    /// already durable Session journal evidence.
    case terminalReference = "terminal_reference"
}

public struct WorkServiceSessionAttachmentDescriptor: Codable, Hashable, Sendable {
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let publication: WorkServiceSessionAttachmentPublication
    /// The exact Session cursor before the Session relationship events.
    public let causalSessionCursor: JournalCursor
    /// The exact Session cursor after ``session.attachment_cursor_advanced``.
    public let sessionCursor: JournalCursor
    /// The exact Work cursor observed before publication. For a terminal reference this equals
    /// ``resultingWorkCursor`` because no Work event may be appended.
    public let causalWorkCursor: JournalCursor
    /// The exact Work cursor after the mirror, or the unchanged cursor for a terminal reference.
    public let resultingWorkCursor: JournalCursor
    public let capabilities: Set<WorkServiceCapability>
    public let isAttached: Bool

    public init(session: SessionRef, sessionJournal: JournalRef,
                sessionAttachment: SessionAttachmentRef,
                publication: WorkServiceSessionAttachmentPublication,
                causalSessionCursor: JournalCursor, sessionCursor: JournalCursor,
                causalWorkCursor: JournalCursor, resultingWorkCursor: JournalCursor,
                capabilities: Set<WorkServiceCapability>, isAttached: Bool = true) {
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.publication = publication
        self.causalSessionCursor = causalSessionCursor
        self.sessionCursor = sessionCursor
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.capabilities = capabilities
        self.isAttached = isAttached
    }

    public var resultingSessionCursor: JournalCursor { sessionCursor }
}

public struct WorkServiceWorkDescriptor: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let recordedDisposition: WorkServiceRecordedDisposition
    public let execution: WorkServiceExecutionState
    public let currentRun: RunRef?
    /// Canonical owner envelope for ``currentRun``. Clients must use this pair for text control
    /// authorization rather than inferring ownership from the first attached Session.
    public let currentRunSession: SessionRef?
    public let currentRunSessionAttachment: SessionAttachmentRef?
    public let configuration: WorkServiceWorkConfiguration
    public let hostObservation: WorkServiceHostObservation?
    public let attachments: [WorkServiceClientAttachment]
    public let sessionAttachments: [WorkServiceSessionAttachmentDescriptor]
    public let artifacts: [WorkServiceArtifactDescriptor]
    public let omissions: [WorkServiceOmission]

    public init(work: WorkRef, journal: JournalRef,
                recordedDisposition: WorkServiceRecordedDisposition,
                execution: WorkServiceExecutionState, currentRun: RunRef?,
                currentRunSession: SessionRef?,
                currentRunSessionAttachment: SessionAttachmentRef?,
                configuration: WorkServiceWorkConfiguration = .init(),
                hostObservation: WorkServiceHostObservation?,
                attachments: [WorkServiceClientAttachment] = [],
                sessionAttachments: [WorkServiceSessionAttachmentDescriptor] = [],
                artifacts: [WorkServiceArtifactDescriptor] = [],
                omissions: [WorkServiceOmission] = []) throws {
        guard artifacts.allSatisfy({ $0.work == work }) else {
            throw WorkServiceProtocolError.invalidRequest(
                "every artifact must belong to the descriptor's Work")
        }
        guard artifacts.allSatisfy({
            WorkServiceText.valid($0.artifactID)
                && $0.artifactID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
        }) else {
            throw WorkServiceProtocolError.invalidRequest(
                "artifact identities must be nonblank and bounded")
        }
        guard artifacts.allSatisfy({ Self.validArtifactFields($0, journal: journal) }) else {
            throw WorkServiceProtocolError.invalidRequest(
                "artifact metadata and body references must be canonical and bounded")
        }
        guard Set(artifacts.map(\.artifactID)).count == artifacts.count else {
            throw WorkServiceProtocolError.invalidRequest(
                "artifact identities must be unique within a Work descriptor")
        }
        guard (currentRun == nil) == (currentRunSession == nil),
              (currentRun == nil) == (currentRunSessionAttachment == nil) else {
            throw WorkServiceProtocolError.invalidRequest(
                "a current Run must have exactly one Session/attachment owner envelope")
        }
        if currentRun != nil {
            let ownerRelationships = sessionAttachments.filter {
                $0.session == currentRunSession
                    && $0.sessionAttachment == currentRunSessionAttachment
                    && $0.isAttached
            }
            guard ownerRelationships.count == 1 else {
                throw WorkServiceProtocolError.invalidRequest(
                    "a current Run owner must be exactly one attached Session relationship")
            }
        }
        if let hostObservation, hostObservation.sourceCompleteness == .complete {
            guard hostObservation.currentRun == currentRun,
                  hostObservation.currentRunSession == currentRunSession,
                  hostObservation.currentRunSessionAttachment == currentRunSessionAttachment else {
                throw WorkServiceProtocolError.invalidRequest(
                    "complete host observation must name the descriptor's exact Run owner")
            }
        }
        self.work = work
        self.journal = journal
        self.recordedDisposition = recordedDisposition
        self.execution = execution
        self.currentRun = currentRun
        self.currentRunSession = currentRunSession
        self.currentRunSessionAttachment = currentRunSessionAttachment
        self.configuration = configuration
        self.hostObservation = hostObservation
        self.attachments = attachments
        // Semantic relationships are not a best-effort display list.  The InMemory service
        // admits them under the protocol bound before minting anything; silently dropping a
        // relationship here would make a successful response unverifiable.
        self.sessionAttachments = sessionAttachments
        self.artifacts = artifacts
        self.omissions = omissions
    }

    private enum CodingKeys: String, CodingKey {
        case work, journal, recordedDisposition, execution, currentRun,
             currentRunSession, currentRunSessionAttachment, configuration,
             hostObservation, attachments, sessionAttachments
        case artifacts, omissions
    }

    private static func validArtifactFields(
        _ artifact: WorkServiceArtifactDescriptor, journal: JournalRef
    ) -> Bool {
        guard WorkServiceText.valid(artifact.sourceEvent.eventID),
              artifact.sourceEvent.eventID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              artifact.sourceEvent.journal == journal,
              WorkServiceText.valid(artifact.session.sessionID),
              artifact.session.sessionID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              WorkServiceText.valid(artifact.sessionAttachment.attachmentID),
              artifact.sessionAttachment.attachmentID.utf8.count
                <= WorkServiceBounds.maxIdentityCharacters,
              WorkServiceText.valid(artifact.run.runID),
              artifact.run.runID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              artifact.turn.map({
                  WorkServiceText.valid($0.turnID)
                      && $0.turnID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
              }) ?? true,
              artifact.action.map({
                  WorkServiceText.valid($0.actionID)
                      && $0.actionID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
              }) ?? true,
              artifact.causedByEventID.map({
                  WorkServiceText.valid($0.eventID)
                      && $0.eventID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
                      && ($0.journal == journal
                          || ($0.journal.kind == .session
                              && $0.journal.owner == .session(artifact.session)
                              && $0.journal.authority.authorityID == journal.authority.authorityID))
              }) ?? true,
              artifact.available == (artifact.bodyReference != nil) else { return false }
        if artifact.action != nil {
            guard let cause = artifact.causedByEventID, cause.journal == journal else {
                return false
            }
        }
        if artifact.mediaType == ObservedRepositoryReviewFormat.mediaType {
            guard artifact.turn != nil, artifact.action != nil,
                  let cause = artifact.causedByEventID, cause.journal == journal else {
                return false
            }
        }
        guard let reference = artifact.bodyReference else {
            return artifact.byteCount == nil && artifact.digest == nil
        }
        return reference.authority == journal
            && WorkServiceText.valid(reference.referenceID)
            && reference.referenceID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && (reference.mediaType?.utf8.count ?? 0)
                <= WorkServiceBounds.maxDiagnosticCharacters
            && artifact.mediaType == reference.mediaType
            && artifact.byteCount == reference.byteCount
            && artifact.digest == reference.digest
            && (reference.byteCount.map { $0 >= 0 } ?? false)
            && (reference.digest.map(ContextBodyStore.isValidDigest) ?? false)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currentRun = try container.decodeIfPresent(RunRef.self, forKey: .currentRun)
        let currentRunSession = try container.decodeIfPresent(
            SessionRef.self, forKey: .currentRunSession)
        let currentRunSessionAttachment = try container.decodeIfPresent(
            SessionAttachmentRef.self, forKey: .currentRunSessionAttachment)
        guard (currentRun == nil) == (currentRunSession == nil),
              (currentRun == nil) == (currentRunSessionAttachment == nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .currentRun, in: container,
                debugDescription: "descriptor Run owner must be an all-nil or all-present tuple")
        }
        let hostObservation = try container.decodeIfPresent(
            WorkServiceHostObservation.self, forKey: .hostObservation)
        if let hostObservation, hostObservation.sourceCompleteness == .complete,
           (hostObservation.currentRun != currentRun
                || hostObservation.currentRunSession != currentRunSession
                || hostObservation.currentRunSessionAttachment != currentRunSessionAttachment) {
            throw DecodingError.dataCorruptedError(
                forKey: .hostObservation, in: container,
                debugDescription: "complete host observation owner differs from descriptor owner")
        }
        let work = try container.decode(WorkRef.self, forKey: .work)
        let journal = try container.decode(JournalRef.self, forKey: .journal)
        self.work = work
        self.journal = journal
        self.recordedDisposition = try container.decode(
            WorkServiceRecordedDisposition.self, forKey: .recordedDisposition)
        self.execution = try container.decode(WorkServiceExecutionState.self, forKey: .execution)
        self.currentRun = currentRun
        self.currentRunSession = currentRunSession
        self.currentRunSessionAttachment = currentRunSessionAttachment
        self.configuration = try container.decode(
            WorkServiceWorkConfiguration.self, forKey: .configuration)
        self.hostObservation = hostObservation
        self.attachments = try container.decode(
            [WorkServiceClientAttachment].self, forKey: .attachments)
        self.sessionAttachments = try container.decode(
            [WorkServiceSessionAttachmentDescriptor].self, forKey: .sessionAttachments)
        if currentRun != nil {
            let ownerRelationships = self.sessionAttachments.filter {
                $0.session == currentRunSession
                    && $0.sessionAttachment == currentRunSessionAttachment
                    && $0.isAttached
            }
            guard ownerRelationships.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sessionAttachments, in: container,
                    debugDescription:
                        "a current Run owner must be exactly one attached Session relationship")
            }
        }
        let artifacts = try container.decode(
            [WorkServiceArtifactDescriptor].self, forKey: .artifacts)
        guard artifacts.allSatisfy({ $0.work == work }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .artifacts, in: container,
                debugDescription: "every artifact must belong to the descriptor's Work")
        }
        guard artifacts.allSatisfy({
            WorkServiceText.valid($0.artifactID)
                && $0.artifactID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .artifacts, in: container,
                debugDescription: "artifact identities must be nonblank and bounded")
        }
        guard artifacts.allSatisfy({ Self.validArtifactFields($0, journal: journal) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .artifacts, in: container,
                debugDescription:
                    "artifact metadata and body references must be canonical and bounded")
        }
        guard Set(artifacts.map(\.artifactID)).count == artifacts.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .artifacts, in: container,
                debugDescription: "artifact identities must be unique within a Work descriptor")
        }
        self.artifacts = artifacts
        self.omissions = try container.decode([WorkServiceOmission].self, forKey: .omissions)
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
    /// Stable caller identity for one logical Attach epoch. Callers must bind it to the exact
    /// causal control cursor, Session tuple, and requested capability envelope. Repeating the
    /// identical request aliases a lost response; a later Attach after a durable Detach has a
    /// different control cursor and therefore a different identity.
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
    /// A host-minted identity from the handshake catalog. It is intentionally not a path or a
    /// policy string. A nil value is permitted in value fixtures/inventory records, but a
    /// Create/Start-capable host must reject it at its effect boundary.
    public let workspaceID: WorkHostWorkspaceID?
    public let includeContextFiles: Bool
    public let recordPayloads: Bool
    public let resumePolicy: String?
    public let wasTruncated: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case providerID, modelID, thinkingLevel, contextPolicy, workspaceID
        case includeContextFiles, recordPayloads, resumePolicy, wasTruncated
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(providerID: String? = nil, modelID: String? = nil,
                thinkingLevel: String? = nil, contextPolicy: String? = nil,
                workspaceID: WorkHostWorkspaceID? = nil, includeContextFiles: Bool = true,
                recordPayloads: Bool = false, resumePolicy: String? = nil) {
        let boundedProvider = WorkServiceText.boundCommand(providerID)
        let boundedModel = WorkServiceText.boundCommand(modelID)
        let boundedThinking = WorkServiceText.boundCommand(thinkingLevel)
        let boundedPolicy = WorkServiceText.boundCommand(contextPolicy)
        let boundedResume = WorkServiceText.boundCommand(resumePolicy)
        self.providerID = boundedProvider.value
        self.modelID = boundedModel.value
        self.thinkingLevel = boundedThinking.value
        self.contextPolicy = boundedPolicy.value
        self.workspaceID = workspaceID
        self.includeContextFiles = includeContextFiles
        self.recordPayloads = recordPayloads
        self.resumePolicy = boundedResume.value
        self.wasTruncated = boundedProvider.wasTruncated || boundedModel.wasTruncated
            || boundedThinking.wasTruncated || boundedPolicy.wasTruncated
            || boundedResume.wasTruncated
    }

    public init(from decoder: Decoder) throws {
        // A keyed container constrained to CodingKeys silently discards unknown JSON members.
        // Inspect a dynamic container first so a peer cannot send a path-shaped field (or any
        // future host-private field) alongside a valid workspaceID and have it accepted by an
        // older client. This is a deliberately closed, early-stage protocol surface.
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let unknown = dynamic.allKeys.first(where: {
            CodingKeys(rawValue: $0.stringValue) == nil
        }) else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Preserve decoded bytes exactly. The host validates these values before any effect;
            // decoding must not silently truncate an adversarial transport payload.
            providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
            modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
            thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
            contextPolicy = try container.decodeIfPresent(String.self, forKey: .contextPolicy)
            workspaceID = try container.decodeIfPresent(WorkHostWorkspaceID.self, forKey: .workspaceID)
            includeContextFiles = try container.decodeIfPresent(Bool.self, forKey: .includeContextFiles) ?? true
            recordPayloads = try container.decodeIfPresent(Bool.self, forKey: .recordPayloads) ?? false
            resumePolicy = try container.decodeIfPresent(String.self, forKey: .resumePolicy)
            wasTruncated = try container.decodeIfPresent(Bool.self, forKey: .wasTruncated) ?? false
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: unknown, in: dynamic,
            debugDescription: "Work configuration contains an unknown field")
    }

    /// Decoding is intentionally checked at the effect boundary. Synthesized Codable can
    /// construct a value whose strings exceed the bound while claiming `wasTruncated == false`.
    fileprivate var hasInvalidBodyBounds: Bool {
        wasTruncated || [providerID, modelID, thinkingLevel, contextPolicy, resumePolicy]
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
            workspaceID: workspaceID,
            includeContextFiles: includeContextFiles,
            recordPayloads: recordPayloads,
            resumePolicy: resumePolicy)
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

/// Requests that an already-authorized client have the Work Host mint a new Session and its
/// client attachment. No Session, SessionAttachment, or ClientAttachment identity is accepted
/// from the caller; all three are host-owned outputs.
public struct WorkServiceCreateSessionRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    /// The existing Work/client attachment authorizing this operation.
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let commandID: String
    public let causalControlCursor: JournalCursor
    public let causalWorkCursor: JournalCursor
    /// Capabilities requested for the newly-created Session relationship/Client attachment.
    public let requestedCapabilities: Set<WorkServiceCapability>

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef, commandID: String,
                causalControlCursor: JournalCursor, causalWorkCursor: JournalCursor,
                requestedCapabilities: Set<WorkServiceCapability> = [.observe]) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
        self.causalWorkCursor = causalWorkCursor
        self.requestedCapabilities = requestedCapabilities
    }
}

public struct WorkServiceCreateSessionResponse: Codable, Hashable, Sendable {
    public let work: WorkServiceWorkDescriptor
    /// Nil on a structured rejection. Existing Work facts remain available in ``work``;
    /// no newly-minted identity is placed in a rejected response.
    public let session: SessionRef?
    public let sessionJournal: JournalRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let attachment: WorkServiceClientAttachment?
    public let relationship: WorkServiceSessionAttachmentDescriptor?
    public let workCursor: JournalCursor
    public let sessionCursor: JournalCursor?
    public let controlCursor: JournalCursor
    public let authorization: WorkServiceAuthorizationOutcome
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let causalControlCursor: JournalCursor
    public let causalWorkCursor: JournalCursor
    public let receipt: WorkServiceControlReceipt
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(work: WorkServiceWorkDescriptor,
                session: SessionRef? = nil, sessionJournal: JournalRef? = nil,
                sessionAttachment: SessionAttachmentRef? = nil,
                attachment: WorkServiceClientAttachment? = nil,
                relationship: WorkServiceSessionAttachmentDescriptor? = nil,
                workCursor: JournalCursor,
                sessionCursor: JournalCursor? = nil,
                controlCursor: JournalCursor,
                authorization: WorkServiceAuthorizationOutcome,
                commandID: String, state: WorkServiceCommandReceiptState = .accepted,
                host: WorkHostInstanceRef,
                causalControlCursor: JournalCursor,
                causalWorkCursor: JournalCursor,
                receipt: WorkServiceControlReceipt,
                rejection: WorkServiceCommandRejection? = nil,
                diagnostic: String? = nil) {
        self.work = work
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.attachment = attachment
        self.relationship = relationship
        self.workCursor = workCursor
        self.sessionCursor = sessionCursor
        self.controlCursor = controlCursor
        self.authorization = authorization
        self.commandID = commandID
        self.state = state
        self.host = host
        self.causalControlCursor = causalControlCursor
        self.causalWorkCursor = causalWorkCursor
        self.receipt = receipt
        self.rejection = rejection
        self.diagnostic = WorkServiceText.bound(diagnostic)
    }

    public var resultingWorkCursor: JournalCursor { workCursor }
    public var resultingSessionCursor: JournalCursor? { sessionCursor }
    public var resultingControlCursor: JournalCursor { controlCursor }
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
    /// Service-issued digest of the canonical prefix at `afterCursor` and at `servedCursor`.
    /// A client may use a durable reducer checkpoint to skip history only when the next read's
    /// base digest matches the checkpoint's result digest.
    public let basePrefixDigest: String?
    public let prefixDigest: String?
    public let omissions: [WorkServiceOmission]

    public init(work: WorkServiceWorkDescriptor, events: [TimelineEvent],
                target: WorkServiceReadTarget, servedCursor: JournalCursor?,
                basePrefixDigest: String? = nil, prefixDigest: String? = nil,
                omissions: [WorkServiceOmission] = []) {
        self.work = work
        self.events = events
        self.target = target
        self.servedCursor = servedCursor
        self.basePrefixDigest = basePrefixDigest
        self.prefixDigest = prefixDigest
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

/// A bounded reverse read for conversation history. It is deliberately separate from the
/// reducer/read cursor: `beforeCursor` is an exclusive display-history boundary and may be
/// advanced independently by several GUIs observing the same Session.
public struct WorkServiceHistoryRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let target: WorkServiceReadTarget
    /// Exclusive upper boundary. Nil means the current canonical tip on the first request.
    public let beforeCursor: JournalCursor?
    /// Once established, continuation is pinned to this tip. Within the Work Host's cooperating
    /// owner-lock append contract, appends after it are allowed while replacement, truncation, or
    /// mutation of the frozen prefix fails closed. This is an integrity contract between Aviary
    /// writers, not a sandbox boundary against a process directly rewriting journal bytes.
    public let frozenTipCursor: JournalCursor?
    public let frozenTipDigest: String?
    /// Semantic branch identity from the Session reducer. A continuation must remain on this
    /// branch; physical journal events outside it are never exposed as chat history.
    public let branchTip: EventRef?
    public let limit: Int
    public let maxBytes: Int

    public init(work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
                client: ClientRef, target: WorkServiceReadTarget,
                beforeCursor: JournalCursor? = nil,
                frozenTipCursor: JournalCursor? = nil, frozenTipDigest: String? = nil,
                branchTip: EventRef? = nil,
                limit: Int = WorkServiceBounds.maxEventsPerPage,
                maxBytes: Int = WorkServiceBounds.maxEventPageBytes) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.client = client
        self.target = target
        self.beforeCursor = beforeCursor
        self.frozenTipCursor = frozenTipCursor
        self.frozenTipDigest = frozenTipDigest
        self.branchTip = branchTip
        self.limit = limit
        self.maxBytes = maxBytes
    }
}

/// The minimal authority returned with a bounded conversation-history page. History consumers
/// must not receive the full Work descriptor: constructing one can require replaying mutable Work
/// state that is unrelated to the selected Session journal. This authority binds the page to the
/// exact Work/journal and to the Work Host instance that negotiated the read. Completeness is
/// carried explicitly so a sparse or otherwise incomplete source cannot be mistaken for an
/// authenticated complete history prefix.
public struct WorkServiceHistoryAuthority: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let hostInstance: WorkHostInstanceRef
    public let sourceCompleteness: WorkServiceSourceCompleteness

    public init(work: WorkRef, journal: JournalRef,
                hostInstance: WorkHostInstanceRef,
                sourceCompleteness: WorkServiceSourceCompleteness) throws {
        guard journal.owner == .work(work),
              journal.authority.authorityID == work.workHostID,
              hostInstance.host == WorkHostRef(work.workHostID) else {
            throw WorkServiceProtocolError.invalidRequest(
                "history authority must bind the exact Work journal and Work Host")
        }
        self.work = work
        self.journal = journal
        self.hostInstance = hostInstance
        self.sourceCompleteness = sourceCompleteness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let work = try container.decode(WorkRef.self, forKey: .work)
        let journal = try container.decode(JournalRef.self, forKey: .journal)
        let hostInstance = try container.decode(WorkHostInstanceRef.self, forKey: .hostInstance)
        let sourceCompleteness = try container.decode(
            WorkServiceSourceCompleteness.self, forKey: .sourceCompleteness)
        guard journal.owner == .work(work),
              journal.authority.authorityID == work.workHostID,
              hostInstance.host == WorkHostRef(work.workHostID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .journal, in: container,
                debugDescription: "history authority identities do not agree")
        }
        self.work = work
        self.journal = journal
        self.hostInstance = hostInstance
        self.sourceCompleteness = sourceCompleteness
    }

    private enum CodingKeys: String, CodingKey {
        case work, journal, hostInstance, sourceCompleteness
    }
}

public struct WorkServiceHistoryPage: Codable, Hashable, Sendable {
    public let authority: WorkServiceHistoryAuthority
    public let events: [TimelineEvent]
    public let target: WorkServiceReadTarget
    public let lowerBoundaryCursor: JournalCursor?
    public let upperBoundaryCursor: JournalCursor?
    public let nextBeforeCursor: JournalCursor?
    public let hasOlder: Bool
    public let frozenTipCursor: JournalCursor
    public let frozenTipDigest: String
    public let branchTip: EventRef?
    /// Digest of the selected message sequence ending at the returned upper boundary. Physical
    /// Session events can occur between messages, so this is intentionally not described as a
    /// digest of the complete journal prefix; frozenTipDigest carries that separate evidence.
    public let prefixDigest: String
    public let omissions: [WorkServiceOmission]

    public init(authority: WorkServiceHistoryAuthority, events: [TimelineEvent], target: WorkServiceReadTarget,
                lowerBoundaryCursor: JournalCursor?, upperBoundaryCursor: JournalCursor?,
                nextBeforeCursor: JournalCursor?, hasOlder: Bool,
                frozenTipCursor: JournalCursor, frozenTipDigest: String,
                prefixDigest: String, branchTip: EventRef? = nil,
                omissions: [WorkServiceOmission] = []) {
        self.authority = authority
        self.events = events
        self.target = target
        self.lowerBoundaryCursor = lowerBoundaryCursor
        self.upperBoundaryCursor = upperBoundaryCursor
        self.nextBeforeCursor = nextBeforeCursor
        self.hasOlder = hasOlder
        self.frozenTipCursor = frozenTipCursor
        self.frozenTipDigest = frozenTipDigest
        self.branchTip = branchTip
        self.prefixDigest = prefixDigest
        self.omissions = omissions
    }
}

/// Deterministic, page-local evidence for reverse conversation history. This is intentionally
/// distinct from ``frozenTipDigest``: the latter authenticates the complete physical journal
/// prefix, while this digest is recomputable from the response's selected message envelopes.
/// Including the target journal and exact page cursor prevents the same event bytes from being
/// replayed as evidence for another Session or boundary.
internal enum WorkServiceHistoryPageEvidence {
    private static let version = "aviary-history-page-v1"

    static func digest(
        events: [TimelineEvent], target: WorkServiceReadTarget, cursor: JournalCursor
    ) throws -> String {
        guard cursor.journal == target.journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        var data = Data()
        data.append(Data((version + "\u{0}" + target.journal.stableKey + "\u{0}").utf8))
        switch target {
        case .work:
            data.append(Data("work\u{0}".utf8))
        case .session(let session, _):
            data.append(Data(("session\u{0}" + session.sessionID + "\u{0}").utf8))
        }
        data.append(Data((String(cursor.sequence) + "\u{0}" +
                          (cursor.eventID ?? "") + "\u{0}").utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for event in events {
            guard event.journal == target.journal else {
                throw WorkServiceProtocolError.journalMismatch
            }
            data.append(try encoder.encode(event))
            data.append(0)
        }
        return WorkServiceText.digest(data)
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
    /// Service-issued digest of the canonical prefix before and after this page. The controller
    /// validates the base against its checkpoint/previous page before reducing the events.
    public let basePrefixDigest: String?
    public let prefixDigest: String?
    public let omissions: [WorkServiceOmission]

    public init(events: [TimelineEvent], target: WorkServiceReadTarget,
                servedCursor: JournalCursor?,
                nextCursor: JournalCursor?, basePrefixDigest: String? = nil,
                prefixDigest: String? = nil, omissions: [WorkServiceOmission] = []) {
        self.events = events
        self.target = target
        self.servedCursor = servedCursor
        self.nextCursor = nextCursor
        self.basePrefixDigest = basePrefixDigest
        self.prefixDigest = prefixDigest
        self.omissions = omissions
    }
}

public struct WorkServiceArtifactDescriptor: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case artifactID, work, label, mediaType, byteCount, digest, available
        case bodyReference, metadataWasTruncated
        case sourceEvent, session, sessionAttachment, run, turn, action, causedByEventID
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
    /// The exact Work-journal event that published this artifact descriptor.
    public let sourceEvent: EventRef
    /// The Session and Session attachment carried by the publishing event envelope.
    public let session: SessionRef
    public let sessionAttachment: SessionAttachmentRef
    /// The exact Run carried by the publishing event envelope.
    public let run: RunRef
    /// Optional turn/action envelope identities. Repository reviews require both.
    public let turn: TurnRef?
    public let action: ActionRef?
    /// The exact causal event carried by the publishing event envelope, if any.
    public let causedByEventID: EventRef?

    public init(artifactID: String, work: WorkRef, label: String,
                mediaType: String? = nil, byteCount: Int? = nil, digest: String? = nil,
                available: Bool = false, bodyReference: TimelineBodyReference? = nil,
                metadataWasTruncated: Bool = false,
                sourceEvent: EventRef,
                session: SessionRef,
                sessionAttachment: SessionAttachmentRef,
                run: RunRef,
                turn: TurnRef? = nil,
                action: ActionRef? = nil,
                causedByEventID: EventRef? = nil) throws {
        func valid(_ value: String, maximumBytes: Int) -> Bool {
            WorkServiceText.valid(value)
                && value.utf8.count <= maximumBytes
                && value.unicodeScalars.allSatisfy { scalar in
                    scalar.value > 0x1F
                        && !(0x7F...0x9F).contains(scalar.value)
                        && scalar.value != 0x2028
                        && scalar.value != 0x2029
                }
        }
        let validCause = causedByEventID.map { cause in
            guard valid(cause.eventID, maximumBytes: WorkServiceBounds.maxIdentityCharacters)
            else { return false }
            if cause.journal == sourceEvent.journal { return true }
            return cause.journal.kind == .session
                && cause.journal.owner == .session(session)
                && cause.journal.authority.authorityID == work.workHostID
        } ?? true
        var invalidReasons: [String] = []
        if !valid(artifactID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) {
            invalidReasons.append("artifactID")
        }
        if !valid(work.workHostID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) {
            invalidReasons.append("workHostID")
        }
        if !valid(work.workID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) {
            invalidReasons.append("workID")
        }
        if !valid(label, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters) {
            invalidReasons.append("label")
        }
        if mediaType.map({ valid($0, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters) }) == false {
            invalidReasons.append("mediaType")
        }
        if digest.map(ContextBodyStore.isValidDigest) == false {
            invalidReasons.append("digest")
        }
        if !valid(sourceEvent.eventID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) {
            invalidReasons.append("sourceEvent")
        }
        if sourceEvent.journal.owner != .work(work) {
            invalidReasons.append("sourceEvent.work")
        }
        if sourceEvent.journal.authority.authorityID != work.workHostID {
            invalidReasons.append("sourceEvent.authority")
        }
        if !valid(session.sessionID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) {
            invalidReasons.append("session")
        }
        if !valid(sessionAttachment.attachmentID,
                  maximumBytes: WorkServiceBounds.maxIdentityCharacters) {
            invalidReasons.append("sessionAttachment")
        }
        if !valid(run.runID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) {
            invalidReasons.append("run")
        }
        if turn.map({ valid($0.turnID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) }) == false {
            invalidReasons.append("turn")
        }
        if action.map({ valid($0.actionID, maximumBytes: WorkServiceBounds.maxIdentityCharacters) }) == false {
            invalidReasons.append("action")
        }
        if !validCause { invalidReasons.append("cause") }
        if available != (bodyReference != nil) { invalidReasons.append("availability") }
        guard invalidReasons.isEmpty else {
            throw WorkServiceProtocolError.invalidRequest(
                "artifact provenance, identity, and availability must be canonical: "
                    + invalidReasons.joined(separator: ","))
        }
        if let bodyReference {
            guard bodyReference.authority == sourceEvent.journal,
                  valid(bodyReference.referenceID,
                        maximumBytes: WorkServiceBounds.maxIdentityCharacters),
                  bodyReference.mediaType == mediaType,
                  bodyReference.byteCount == byteCount,
                  bodyReference.digest == digest,
                  let bodyByteCount = bodyReference.byteCount,
                  bodyByteCount >= 0,
                  let bodyDigest = bodyReference.digest,
                  ContextBodyStore.isValidDigest(bodyDigest) else {
                throw WorkServiceProtocolError.invalidRequest(
                    "artifact body metadata must exactly match bodyReference")
            }
        } else {
            guard byteCount == nil, digest == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "unavailable artifacts cannot carry byteCount or digest")
            }
        }
        if action != nil {
            guard let cause = causedByEventID, cause.journal == sourceEvent.journal else {
                throw WorkServiceProtocolError.invalidRequest(
                    "an artifact Action requires an exact Work causedByEventID")
            }
        }
        if mediaType == ObservedRepositoryReviewFormat.mediaType {
            guard turn != nil, action != nil,
                  let cause = causedByEventID, cause.journal == sourceEvent.journal else {
                throw WorkServiceProtocolError.invalidRequest(
                    "repository-review artifacts require Turn, Action, and Work cause")
            }
        }
        self.artifactID = artifactID
        self.work = work
        self.metadataWasTruncated = metadataWasTruncated
        self.label = label
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.digest = digest
        self.available = available
        self.bodyReference = bodyReference
        self.sourceEvent = sourceEvent
        self.session = session
        self.sessionAttachment = sessionAttachment
        self.run = run
        self.turn = turn
        self.action = action
        self.causedByEventID = causedByEventID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let available = try values.decode(Bool.self, forKey: .available)
        let bodyReference = try values.decodeIfPresent(
            TimelineBodyReference.self, forKey: .bodyReference)
        guard available == (bodyReference != nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .available, in: values,
                debugDescription: "artifact availability must exactly match bodyReference")
        }
        let byteCount = try values.decodeIfPresent(Int.self, forKey: .byteCount)
        let digest = try values.decodeIfPresent(String.self, forKey: .digest)
        let mediaType = try values.decodeIfPresent(String.self, forKey: .mediaType)
        if let bodyReference {
            guard mediaType == bodyReference.mediaType,
                  byteCount == bodyReference.byteCount,
                  digest == bodyReference.digest else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bodyReference, in: values,
                    debugDescription: "artifact metadata must exactly match bodyReference")
            }
        } else {
            guard byteCount == nil, digest == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bodyReference, in: values,
                    debugDescription: "unavailable artifacts cannot carry byteCount or digest")
            }
        }
        do {
            try self.init(
                artifactID: try values.decode(String.self, forKey: .artifactID),
                work: try values.decode(WorkRef.self, forKey: .work),
                label: try values.decode(String.self, forKey: .label),
                mediaType: mediaType,
                byteCount: byteCount,
                digest: digest,
                available: available,
                bodyReference: bodyReference,
                metadataWasTruncated: try values.decodeIfPresent(
                    Bool.self, forKey: .metadataWasTruncated) ?? false,
                sourceEvent: try values.decode(EventRef.self, forKey: .sourceEvent),
                session: try values.decode(SessionRef.self, forKey: .session),
                sessionAttachment: try values.decode(
                    SessionAttachmentRef.self, forKey: .sessionAttachment),
                run: try values.decode(RunRef.self, forKey: .run),
                turn: try values.decodeIfPresent(TurnRef.self, forKey: .turn),
                action: try values.decodeIfPresent(ActionRef.self, forKey: .action),
                causedByEventID: try values.decodeIfPresent(
                    EventRef.self, forKey: .causedByEventID))
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .artifactID, in: values,
                debugDescription: "artifact descriptor failed canonical provenance validation")
        }
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
        try values.encode(sourceEvent, forKey: .sourceEvent)
        try values.encode(session, forKey: .session)
        try values.encode(sessionAttachment, forKey: .sessionAttachment)
        try values.encode(run, forKey: .run)
        try values.encodeIfPresent(turn, forKey: .turn)
        try values.encodeIfPresent(action, forKey: .action)
        try values.encodeIfPresent(causedByEventID, forKey: .causedByEventID)
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
    /// The exact client-qualified command written to the canonical Work ledger. The external
    /// receipt retains the caller-local ID; this proof cannot collide with another client's same
    /// local ID or be replayed across client, Session attachment, or causal cursor.
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
    /// The exact client-qualified canonical command envelope, including caller/session/cursor
    /// identity, is part of the terminal transaction's durable idempotency key.
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

/// A Work-owned agent Handle cancellation is not a Run cancellation. Its authority is the
/// caller's canonical Work attachment, and its effect remains addressable after the origin Run
/// ends. Keeping the Handle typed also prevents a generic command value from becoming an
/// unvalidated identity channel.
public struct WorkServiceAgentHandleCancelRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let handle: HandleRef
    public let command: CommandRef
    /// Required duplicate of the command envelope cursor. A decoder or adapter may not turn the
    /// mutation into an unconditional cancellation by dropping either copy.
    public let causalWorkCursor: JournalCursor

    public init(
        work: WorkRef, journal: JournalRef, attachment: ClientAttachmentRef,
        handle: HandleRef, commandID: String, client: ClientRef,
        sessionAttachment: SessionAttachmentRef, causalWorkCursor: JournalCursor
    ) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.handle = handle
        self.causalWorkCursor = causalWorkCursor
        self.command = CommandRef(
            commandID: commandID, client: client, sessionAttachment: sessionAttachment,
            causalCursor: causalWorkCursor)
    }
}

/// Only `accepted` and `duplicate` prove this caller's command. The remaining successful reads
/// describe canonical Handle state without pretending that a new command was recorded.
public enum WorkServiceAgentHandleCancelDisposition: String, Codable, Hashable, Sendable {
    case accepted
    case duplicate
    case alreadyRequested = "already_requested"
    case alreadyTerminal = "already_terminal"
    case unavailable
    case ambiguous
    case rejected
}

public struct WorkServiceAgentHandleCancelResponse: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let handle: HandleRef
    /// The caller-local identity. Canonical evidence carries the client-qualified ledger ID.
    public let commandID: String
    public let disposition: WorkServiceAgentHandleCancelDisposition
    /// The daemon answering now, not necessarily the process generation which wrote the proof.
    public let responder: WorkHostInstanceRef
    public let causalWorkCursor: JournalCursor
    /// Present only when canonical evidence proves this exact caller command.
    public let resultingWorkCursor: JournalCursor?
    public let authorization: WorkServiceAuthorizationOutcome
    public let cancellationEvidence: WorkAgentHandleCancellationEvidence?
    public let terminalEvidence: WorkAgentHandleTerminalEvidence?
    public let rejection: WorkServiceCommandRejection?
    public let diagnostic: String?

    public init(
        work: WorkRef, handle: HandleRef, commandID: String,
        disposition: WorkServiceAgentHandleCancelDisposition,
        responder: WorkHostInstanceRef, causalWorkCursor: JournalCursor,
        resultingWorkCursor: JournalCursor? = nil,
        authorization: WorkServiceAuthorizationOutcome,
        cancellationEvidence: WorkAgentHandleCancellationEvidence? = nil,
        terminalEvidence: WorkAgentHandleTerminalEvidence? = nil,
        rejection: WorkServiceCommandRejection? = nil,
        diagnostic: String? = nil
    ) throws {
        self.work = work
        self.handle = handle
        self.commandID = commandID
        self.disposition = disposition
        self.responder = responder
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.authorization = authorization
        self.cancellationEvidence = cancellationEvidence
        self.terminalEvidence = terminalEvidence
        self.rejection = rejection
        let boundedDiagnostic = WorkServiceText.bound(diagnostic)
        guard boundedDiagnostic == diagnostic else {
            throw WorkServiceProtocolError.invalidRequest(
                "agent Handle cancellation diagnostic exceeds its protocol bound")
        }
        self.diagnostic = boundedDiagnostic
        try validateShape()
    }

    private enum CodingKeys: String, CodingKey {
        case work, handle, commandID, disposition, responder, causalWorkCursor
        case resultingWorkCursor, authorization, cancellationEvidence, terminalEvidence
        case rejection, diagnostic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            work: container.decode(WorkRef.self, forKey: .work),
            handle: container.decode(HandleRef.self, forKey: .handle),
            commandID: container.decode(String.self, forKey: .commandID),
            disposition: container.decode(
                WorkServiceAgentHandleCancelDisposition.self, forKey: .disposition),
            responder: container.decode(WorkHostInstanceRef.self, forKey: .responder),
            causalWorkCursor: container.decode(JournalCursor.self, forKey: .causalWorkCursor),
            resultingWorkCursor: container.decodeIfPresent(
                JournalCursor.self, forKey: .resultingWorkCursor),
            authorization: container.decode(
                WorkServiceAuthorizationOutcome.self, forKey: .authorization),
            cancellationEvidence: container.decodeIfPresent(
                WorkAgentHandleCancellationEvidence.self, forKey: .cancellationEvidence),
            terminalEvidence: container.decodeIfPresent(
                WorkAgentHandleTerminalEvidence.self, forKey: .terminalEvidence),
            rejection: container.decodeIfPresent(
                WorkServiceCommandRejection.self, forKey: .rejection),
            diagnostic: container.decodeIfPresent(String.self, forKey: .diagnostic))
    }

    public func encode(to encoder: Encoder) throws {
        try validateShape()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(work, forKey: .work)
        try container.encode(handle, forKey: .handle)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(responder, forKey: .responder)
        try container.encode(causalWorkCursor, forKey: .causalWorkCursor)
        try container.encodeIfPresent(resultingWorkCursor, forKey: .resultingWorkCursor)
        try container.encode(authorization, forKey: .authorization)
        try container.encodeIfPresent(cancellationEvidence, forKey: .cancellationEvidence)
        try container.encodeIfPresent(terminalEvidence, forKey: .terminalEvidence)
        try container.encodeIfPresent(rejection, forKey: .rejection)
        try container.encodeIfPresent(diagnostic, forKey: .diagnostic)
    }

    /// Correlate an untrusted wire response to the exact request. The transport separately binds
    /// `responder` to its negotiated host-instance generation.
    public func validate() throws {
        try validateShape()
    }

    public func validate(for request: WorkServiceAgentHandleCancelRequest) throws {
        try validateShape()
        let (expectedEvidenceSequence, overflow) = request.causalWorkCursor.sequence
            .addingReportingOverflow(1)
        guard work == request.work, handle == request.handle,
              commandID == request.command.commandID,
              causalWorkCursor == request.causalWorkCursor,
              causalWorkCursor.journal == request.journal,
              let client = request.command.client,
              request.command.causalCursor == request.causalWorkCursor,
              responder.host == WorkHostRef(request.work.workHostID), !overflow else {
            throw WorkServiceProtocolError.invalidRequest(
                "agent Handle cancellation response does not match its request")
        }
        if disposition == .accepted || disposition == .duplicate {
            let expected = WorkServiceCommandLedgerIdentity.command(
                from: request.command, client: client)
            guard cancellationEvidence?.cause == .client,
                  cancellationEvidence?.command == expected,
                  let evidence = cancellationEvidence?.event,
                  evidence.event.journal == request.journal,
                  evidence.sequence == expectedEvidenceSequence,
                  evidence.previousEventID == request.causalWorkCursor.eventID,
                  evidence.event.eventID == resultingWorkCursor?.eventID,
                  evidence.sequence == resultingWorkCursor?.sequence else {
                throw WorkServiceProtocolError.invalidRequest(
                    "agent Handle cancellation response lacks exact command evidence")
            }
        }
    }

    private func validateShape() throws {
        let requested: Set<WorkServiceCapability> = [.control, .cancel]
        guard Self.validIdentity(commandID), Self.validIdentity(handle.handleID),
              Self.validIdentity(work.workHostID), Self.validIdentity(work.workID),
              Self.validIdentity(causalWorkCursor.journal.journalID),
              Self.validIdentity(causalWorkCursor.journal.authority.authorityID),
              Self.validIdentity(responder.host.workHostID),
              Self.validIdentity(responder.instanceID),
              Self.validIdentity(responder.startIdentity),
              responder.host == WorkHostRef(work.workHostID),
              causalWorkCursor.sequence >= 0,
              (causalWorkCursor.eventID.map(Self.validIdentity)
                    ?? (causalWorkCursor.sequence == 0)),
              causalWorkCursor.journal.owner == .work(work),
              authorization.requested == requested,
              authorization.granted == requested,
              authorization.denied.isEmpty,
              authorization.diagnostic.map({
                  $0.utf8.count <= WorkServiceBounds.maxDiagnosticCharacters
              }) ?? true else {
            throw WorkServiceProtocolError.invalidRequest(
                "agent Handle cancellation response is malformed")
        }
        if let cancellationEvidence {
            let event = cancellationEvidence.event
            let (priorSequence, underflow) = event.sequence.subtractingReportingOverflow(1)
            guard try Self.validAgentHandleEvidence(
                    event, work: work, handle: handle, journal: causalWorkCursor.journal),
                  event.work == work, event.workHost == WorkHostRef(work.workHostID),
                  event.handle == handle,
                  event.sequence > 0, !underflow,
                  !event.event.eventID.isEmpty,
                  event.previousEventID != nil,
                  event.causedByEventID != nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "agent Handle cancellation evidence is malformed")
            }
            if cancellationEvidence.cause == .client {
                guard let command = cancellationEvidence.command,
                      let commandClient = command.client, event.client == command.client,
                      Self.validIdentity(command.commandID),
                      Self.validIdentity(commandClient.clientID),
                      let commandAttachment = command.sessionAttachment,
                      Self.validIdentity(commandAttachment.attachmentID),
                      let cursor = command.causalCursor,
                      cursor.journal == event.event.journal,
                      cursor.sequence >= 0,
                      (cursor.eventID.map(Self.validIdentity)
                        ?? (cursor.sequence == 0)),
                      cursor.eventID == event.previousEventID,
                      cursor.sequence == priorSequence else {
                    throw WorkServiceProtocolError.invalidRequest(
                        "client cancellation evidence lacks its exact command")
                }
            } else if cancellationEvidence.command != nil || event.client != nil {
                throw WorkServiceProtocolError.invalidRequest(
                    "host cancellation evidence carries a client command")
            }
        }
        if let terminalEvidence {
            let event = terminalEvidence.event
            guard try Self.validAgentHandleEvidence(
                    event, work: work, handle: handle, journal: causalWorkCursor.journal),
                  event.work == work, event.workHost == WorkHostRef(work.workHostID),
                  event.handle == handle, event.client == nil,
                  event.sequence > 0, !event.event.eventID.isEmpty,
                  event.previousEventID != nil, event.causedByEventID != nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "agent Handle terminal evidence is malformed")
            }
            if let body = terminalEvidence.resultBody {
                guard Self.validAgentHandleBody(body, journal: causalWorkCursor.journal) else {
                    throw WorkServiceProtocolError.invalidRequest(
                        "agent Handle terminal body reference is malformed")
                }
            }
            if terminalEvidence.outcome == .succeeded && terminalEvidence.resultBody == nil {
                throw WorkServiceProtocolError.invalidRequest(
                    "a successful agent Handle terminal proof lacks its result body")
            }
            let cleanup = terminalEvidence.cleanup
            guard (terminalEvidence.outcome == .indeterminate)
                    == (cleanup.state == .indeterminate),
                  cleanup.state != .notStarted
                    || [.failed, .canceled, .expired].contains(terminalEvidence.outcome),
                  cleanup.evidence.map({
                      $0.journal == causalWorkCursor.journal
                          && Self.validIdentity($0.eventID)
                          && $0 != event.event
                  }) ?? true else {
                throw WorkServiceProtocolError.invalidRequest(
                    "agent Handle terminal cleanup evidence is malformed")
            }
        }
        if let cancellationEvidence, let terminalEvidence {
            let cancellation = cancellationEvidence.event
            let terminal = terminalEvidence.event
            guard [.canceled, .expired, .indeterminate].contains(terminalEvidence.outcome),
                  terminal.sequence > cancellation.sequence,
                  terminal.causedByEventID == cancellation.event,
                  terminal.work == cancellation.work,
                  terminal.workHost == cancellation.workHost,
                  terminal.session == cancellation.session,
                  terminal.sessionAttachment == cancellation.sessionAttachment,
                  terminal.run == cancellation.run,
                  terminal.handle == cancellation.handle else {
                throw WorkServiceProtocolError.invalidRequest(
                    "agent Handle cancellation and terminal proofs conflict")
            }
            if let canceledAt = cancellation.hostSequence,
               let terminalAt = terminal.hostSequence, terminalAt <= canceledAt {
                throw WorkServiceProtocolError.invalidRequest(
                    "agent Handle proof host ordering is inconsistent")
            }
        }
        switch disposition {
        case .accepted, .duplicate:
            guard let cancellationEvidence, cancellationEvidence.cause == .client,
                  cancellationEvidence.command != nil,
                  let resultingWorkCursor,
                  resultingWorkCursor.journal == causalWorkCursor.journal,
                  resultingWorkCursor.eventID == cancellationEvidence.event.event.eventID,
                  resultingWorkCursor.sequence == cancellationEvidence.event.sequence,
                  rejection == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "agent Handle command proof is incomplete")
            }
        case .alreadyRequested:
            guard cancellationEvidence != nil, resultingWorkCursor == nil,
                  terminalEvidence == nil, rejection == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "already-requested Handle cancellation has invalid proof")
            }
        case .alreadyTerminal:
            guard terminalEvidence != nil, resultingWorkCursor == nil,
                  rejection == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "terminal Handle cancellation has invalid proof")
            }
        case .unavailable, .ambiguous:
            guard resultingWorkCursor == nil, cancellationEvidence == nil,
                  terminalEvidence == nil, rejection == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "unproven Handle cancellation carries a fabricated receipt")
            }
        case .rejected:
            guard resultingWorkCursor == nil, rejection != nil,
                  cancellationEvidence == nil, terminalEvidence == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "rejected Handle cancellation carries canonical success evidence")
            }
        }
    }

    private static func validAgentHandleEvidence(
        _ evidence: WorkAgentHandleEventEvidence,
        work: WorkRef,
        handle: HandleRef,
        journal: JournalRef
    ) throws -> Bool {
        guard evidence.event.journal == journal,
              evidence.provenance == .native,
              evidence.work == work, evidence.workHost == WorkHostRef(work.workHostID),
              evidence.handle == handle,
              evidence.sequence > 0,
              evidence.hostSequence.map({ $0 >= 0 }) ?? true,
              evidence.hostRecordedAt.timeIntervalSince1970.isFinite,
              validIdentity(evidence.event.eventID),
              evidence.previousEventID.map(validIdentity) ?? false,
              evidence.previousEventID != evidence.event.eventID,
              evidence.causedByEventID.map({
                  $0.journal == journal && validIdentity($0.eventID)
                      && $0 != evidence.event
              }) ?? false,
              let session = evidence.session, validIdentity(session.sessionID),
              let attachment = evidence.sessionAttachment,
              validIdentity(attachment.attachmentID),
              let run = evidence.run, validIdentity(run.runID),
              validIdentity(evidence.actor.actorID),
              validText(evidence.actor.kind, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters)
        else { return false }
        return true
    }

    private static func validAgentHandleBody(
        _ reference: TimelineBodyReference, journal: JournalRef
    ) -> Bool {
        reference.authority == journal
            && validIdentity(reference.referenceID)
            && (reference.mediaType.map {
                validText($0, maximumBytes: WorkServiceBounds.maxDiagnosticCharacters)
            } ?? true)
            && (reference.byteCount.map {
                (0...WorkAgentHandleSnapshot.maximumBodyBytes).contains($0)
            } ?? false)
            && (reference.digest.map(ContextBodyStore.isValidDigest) ?? false)
            && (reference.digest.map { reference.referenceID == $0 } ?? false)
    }

    private static func validIdentity(_ value: String) -> Bool {
        validText(value, maximumBytes: WorkServiceBounds.maxIdentityCharacters)
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value > 0x1F
                    && !(0x7F...0x9F).contains(scalar.value)
                    && scalar.value != 0x2028 && scalar.value != 0x2029
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
    /// The command has a durable acceptance/delivery record, but no fresh runtime liveness proof
    /// exists after a host restart. Clients must surface recovery rather than redispatching it.
    case startRecoveryRequired = "start_recovery_required"
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

/// Provenance of the host-instance value carried by a command receipt. A cold duplicate can
/// replay the canonical acceptance cursor and host sequence, but older journal schemas do not
/// carry the accepting Work Host instance. Such a receipt must not present a new daemon instance
/// as the original author.
public enum WorkServiceReceiptHostProvenance: String, Codable, Hashable, Sendable {
    case current
    case unknown
}

public struct WorkServiceCommandReceipt: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let commandID: String
    public let state: WorkServiceCommandReceiptState
    public let host: WorkHostInstanceRef
    public let hostProvenance: WorkServiceReceiptHostProvenance
    /// Work host order exists only for an accepted execution-journal commit. Rejections have no
    /// Work event and therefore carry no synthetic host sequence.
    public let hostSequence: Int?
    public let causalWorkCursor: JournalCursor
    public let resultingWorkCursor: JournalCursor?
    public let authorization: WorkServiceAuthorizationOutcome
    public let outcome: WorkServiceCommandOutcome?
    public let rejection: WorkServiceCommandRejection?
    /// Durable command delivery state when a duplicate Start cannot safely claim a live actor.
    public let recoveryState: CommandDeliveryState?
    public let terminalProof: WorkServiceTerminalCommitProof?
    public let diagnostic: String?

    public init(work: WorkRef, commandID: String, state: WorkServiceCommandReceiptState,
                host: WorkHostInstanceRef, hostSequence: Int? = nil,
                hostProvenance: WorkServiceReceiptHostProvenance = .current,
                causalWorkCursor: JournalCursor, resultingWorkCursor: JournalCursor?,
                authorization: WorkServiceAuthorizationOutcome,
                outcome: WorkServiceCommandOutcome? = nil,
                rejection: WorkServiceCommandRejection? = nil,
                recoveryState: CommandDeliveryState? = nil,
                terminalProof: WorkServiceTerminalCommitProof? = nil,
                diagnostic: String? = nil) {
        self.work = work
        self.commandID = commandID
        self.state = state
        self.host = host
        self.hostProvenance = hostProvenance
        self.hostSequence = hostSequence
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.authorization = authorization
        self.outcome = outcome
        self.rejection = rejection
        self.recoveryState = recoveryState
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
    func createSession(_ request: WorkServiceCreateSessionRequest) async throws
        -> WorkServiceCreateSessionResponse
    func completeWork(_ request: WorkServiceCompleteWorkRequest) async throws -> WorkServiceCommandReceipt
    func attach(_ request: WorkServiceAttachRequest) async throws -> WorkServiceAttachResponse
    func detach(_ request: WorkServiceDetachRequest) async throws -> WorkServiceDetachResponse
    func updateCapabilities(_ request: WorkServiceUpdateCapabilitiesRequest) async throws
        -> WorkServiceUpdateCapabilitiesResponse
    func acknowledgeRead(_ request: WorkServiceAcknowledgeReadRequest) async throws
        -> WorkServiceAcknowledgeReadResponse
    func snapshot(_ request: WorkServiceSnapshotRequest) async throws -> WorkServiceSnapshot
    func eventsAfterCursor(_ request: WorkServiceEventsRequest) async throws -> WorkServiceEventPage
    func historyBeforeCursor(_ request: WorkServiceHistoryRequest) async throws
        -> WorkServiceHistoryPage
    func fetchArtifact(_ request: WorkServiceArtifactRequest) async throws
        -> WorkServiceArtifactDescriptor
    func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse
    func cancelAgentHandle(_ request: WorkServiceAgentHandleCancelRequest) async throws
        -> WorkServiceAgentHandleCancelResponse
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

    private struct StoredCreateSession: Sendable {
        let request: WorkServiceCreateSessionRequest
        let response: WorkServiceCreateSessionResponse
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

    private struct SessionRecord: Sendable {
        let session: SessionRef
        let journal: JournalRef
        var cursor: JournalCursor
        var events: [TimelineEvent]
        var nextEventSequence: Int
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
    /// The path-free workspace projection advertised to clients. InMemory hosts default to an
    /// empty catalog because they do not own a host-local filesystem registry.
    public let workspaceCatalog: WorkHostWorkspaceCatalog
    private var reachable = true
    private var works: [WorkRef: WorkState] = [:]
    private var createCommands: [CreateCommandKey: StoredCreate] = [:]
    private var createSessionCommands: [CreateCommandKey: StoredCreateSession] = [:]
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
        /// Session identity that admitted the active Run. This remains stable until the Run
        /// finishes so run-level events never fall back to the Work's original Session when a
        /// later Session starts the Run.
        var currentRunSession: SessionRef?
        var currentRunSessionAttachment: SessionAttachmentRef?
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
        /// Session journals are independent of the Work journal. The primary Session fields
        /// above remain as the original launch projection; this bounded map carries additional
        /// Sessions created against the same Work.
        var sessionRecords: [SessionRef: SessionRecord]
        var sessionRelationships: [SessionAttachmentRef: WorkServiceSessionAttachmentDescriptor]
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
                terminalCommitter: (any WorkServiceTerminalCommitter)? = nil,
                workspaceCatalog: WorkHostWorkspaceCatalog = .empty) {
        self.host = host
        self.hostInstance = WorkHostInstanceRef(host: host, instanceID: instanceID,
                                                startIdentity: startIdentity)
        self.authorizer = authorizer
        self.terminalCommitter = terminalCommitter
        self.workspaceCatalog = workspaceCatalog
        self.controlJournal = JournalRef.workHost(host)
        self.controlCursor = JournalCursor(journal: JournalRef.workHost(host), sequence: 0)
    }

    /// Reconstruct the relationship that makes an active seeded Run representable. A Work-side
    /// ``session.attached`` mirror is not enough: the Session journal must contain the reciprocal
    /// publication and its cursor must point back to that exact mirror.
    private static func seededSessionRelationship(
        work: WorkRef, workJournal: JournalRef, workHost: WorkHostRef,
        session: SessionRef, sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef,
        workEvents: [TimelineEvent], sessionEvents: [TimelineEvent]
    ) -> WorkServiceSessionAttachmentDescriptor? {
        guard sessionEvents.count >= 3 else { return nil }
        let publication = Array(sessionEvents.prefix(3))
        guard publication.enumerated().allSatisfy({ index, event in
            event.journal == sessionJournal
                && event.sequence == index + 1
                && (index == 0 || event.previousEventID == publication[index - 1].eventID)
        }) else { return nil }
        let created = publication[0]
        let attached = publication[1]
        let advanced = publication[2]
        let mirrors = workEvents.filter {
            $0.type == TimelineEventType.sessionAttached
                && $0.journal == workJournal
                && $0.session == session
                && $0.work == work
                && $0.workHost == workHost
                && $0.sessionAttachment == sessionAttachment
                && $0.causedByEventID == EventRef(
                    journal: sessionJournal, eventID: attached.eventID)
        }
        guard created.type == TimelineEventType.sessionCreated,
              created.session == session, created.work == nil,
              created.workHost == nil, created.client == nil,
              created.sessionAttachment == nil, created.causedByEventID == nil,
              attached.type == TimelineEventType.sessionAttached,
              attached.session == session, attached.work == work,
              attached.workHost == workHost, attached.sessionAttachment == sessionAttachment,
              attached.causedByEventID == EventRef(
                  journal: sessionJournal, eventID: created.eventID),
              advanced.type == TimelineEventType.sessionAttachmentCursorAdvanced,
              advanced.session == session, advanced.work == work,
              advanced.workHost == workHost, advanced.sessionAttachment == sessionAttachment,
              mirrors.count == 1,
              let mirror = mirrors.first,
              advanced.causedByEventID == EventRef(
                  journal: workJournal, eventID: mirror.eventID),
              let advancedCursor: JournalCursor? = advanced.payload["cursor"].flatMap({
                  decodeTimelineValue($0)
              }),
              let advancedCursor,
              advancedCursor == JournalCursor(
                  journal: workJournal, eventID: mirror.eventID, sequence: mirror.sequence),
              let capabilities = attached.payload["capabilities"]?.arrayValue,
              let advancedCapabilities = advanced.payload["capabilities"]?.arrayValue,
              capabilities == advancedCapabilities,
              capabilities.allSatisfy({ value in
                  value.stringValue.flatMap(WorkServiceCapability.init(rawValue:)) != nil
              }) else { return nil }

        let causalWorkCursor: JournalCursor
        if mirror.sequence == 1 {
            causalWorkCursor = JournalCursor(journal: workJournal, sequence: 0)
        } else {
            guard let predecessor = workEvents.first(where: {
                $0.journal == workJournal && $0.sequence == mirror.sequence - 1
            }), predecessor.eventID == mirror.previousEventID else { return nil }
            causalWorkCursor = JournalCursor(
                journal: workJournal, eventID: predecessor.eventID,
                sequence: predecessor.sequence)
        }
        let parsedCapabilities = Set(capabilities.compactMap {
            $0.stringValue.flatMap(WorkServiceCapability.init(rawValue:))
        })
        return WorkServiceSessionAttachmentDescriptor(
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, publication: .mirrored,
            causalSessionCursor: JournalCursor(journal: sessionJournal, sequence: 0),
            sessionCursor: JournalCursor(
                journal: sessionJournal, eventID: advanced.eventID, sequence: advanced.sequence),
            causalWorkCursor: causalWorkCursor,
            resultingWorkCursor: JournalCursor(
                journal: workJournal, eventID: mirror.eventID, sequence: mirror.sequence),
            capabilities: parsedCapabilities)
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
        var sessionRecords: [SessionRef: SessionRecord] = [:]
        if let session = seed.session, let sessionJournal = seed.sessionJournal,
           let sessionCursor {
            sessionRecords[session] = SessionRecord(
                session: session, journal: sessionJournal, cursor: sessionCursor,
                events: seed.sessionEvents, nextEventSequence: sessionCursor.sequence + 1)
        }
        guard cursor.sequence == 0 || !seed.events.isEmpty
                || seed.sourceCompleteness != .complete else {
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
        let validExecutionRunCombination: Bool
        switch seed.execution {
        case .idle:
            validExecutionRunCombination = seed.currentRun == nil
        case .running, .held, .canceling, .ending:
            validExecutionRunCombination = seed.currentRun != nil
        case .recoveryRequired, .unknown:
            // These states are intentionally seedable so a conformance test can verify their
            // non-actionable projection. They never become commandable through any apply guard.
            validExecutionRunCombination = true
        }
        guard validExecutionRunCombination,
              seed.disposition == .reusable
                || (seed.execution == .idle && seed.currentRun == nil) else {
            throw WorkServiceProtocolError.invalidRequest("invalid execution/run combination")
        }
        let currentRunBinding: (session: SessionRef, attachment: SessionAttachmentRef)?
        var seededRelationships: [SessionAttachmentRef: WorkServiceSessionAttachmentDescriptor] = [:]
        if let currentRun = seed.currentRun, seed.sourceCompleteness == .complete {
            let starts = seed.events.filter {
                $0.type == TimelineEventType.runStarted && $0.run == currentRun
            }
            guard starts.count == 1,
                  let start = starts.first,
                  start.work == seed.work,
                  start.workHost == host,
                  let session = start.session,
                  let attachment = start.sessionAttachment,
                  seed.events.contains(where: {
                      $0.sequence < start.sequence
                          && $0.type == TimelineEventType.sessionAttached
                          && $0.session == session
                          && $0.sessionAttachment == attachment
                  }) else {
                throw WorkServiceProtocolError.invalidRequest(
                    "a complete active Run seed requires exact Session attachment provenance")
            }
            guard seed.session == session,
                  let sessionJournal = seed.sessionJournal,
                  seed.sessionAttachment == attachment else {
                throw WorkServiceProtocolError.invalidRequest(
                    "a complete active Run seed requires its reciprocal Session relationship")
            }
            guard let relationship = Self.seededSessionRelationship(
                work: seed.work, workJournal: seed.journal, workHost: host,
                session: session, sessionJournal: sessionJournal,
                sessionAttachment: attachment, workEvents: seed.events,
                sessionEvents: seed.sessionEvents) else {
                throw WorkServiceProtocolError.invalidRequest(
                    "a complete active Run seed requires exact reciprocal Session evidence")
            }
            seededRelationships[attachment] = relationship
            currentRunBinding = (session, attachment)
        } else {
            // An incomplete source cannot prove who started its active Run. It is deliberately
            // non-mutable, so retain unknown provenance rather than borrowing the launch Session.
            currentRunBinding = nil
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
            execution: seed.execution, currentRun: seed.currentRun,
            currentRunSession: currentRunBinding?.session,
            currentRunSessionAttachment: currentRunBinding?.attachment,
            configuration: seed.configuration, cursor: cursor,
            session: seed.session, sessionJournal: seed.sessionJournal,
            sessionAttachment: seed.sessionAttachment, sessionCursor: sessionCursor,
            sourceCompleteness: seed.sourceCompleteness, artifacts: artifacts, bodies: seed.bodies,
            omissions: omissions,
            attachments: [:],
            events: seed.events, sessionEvents: seed.sessionEvents,
            sessionRecords: sessionRecords, sessionRelationships: seededRelationships,
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
            capabilities: supportedCapabilities(), workspaceCatalog: workspaceCatalog)
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
        return try requiredDescriptor(for: state.work, includeObservation: true)
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
            guard let state = works[prior.response.work.work] else {
                throw WorkServiceProtocolError.sourceIncomplete
            }
            // The Work response is an exact retry of the publication, but its descriptor and
            // client attachment are mutable control state. Reconstruct them from the current
            // state so capability reductions are not resurrected by a stale cached response.
            let replayWork = try requiredDescriptor(for: state.work, includeObservation: true)
            let replayAttachment = state.attachments[prior.response.attachment.attachment]?.attachment
                ?? prior.response.attachment
            let replayReceipt = duplicateControl(of: prior.response.receipt)
            return WorkServiceCreateWorkResponse(
                work: replayWork, authorization: prior.response.authorization,
                session: prior.response.session, sessionJournal: prior.response.sessionJournal,
                sessionAttachment: prior.response.sessionAttachment,
                attachment: replayAttachment, workCursor: prior.response.workCursor,
                sessionCursor: prior.response.sessionCursor,
                controlCursor: prior.response.controlCursor, receipt: replayReceipt)
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
        try validateWorkspaceSelection(request.configuration)
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
            currentRun: nil, currentRunSession: nil, currentRunSessionAttachment: nil,
            configuration: request.configuration,
            cursor: JournalCursor(journal: workJournal, sequence: 0),
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment,
            sessionCursor: JournalCursor(journal: sessionJournal, sequence: 0),
            sourceCompleteness: .complete, artifacts: [], bodies: [:], omissions: [],
            attachments: [:], events: [], sessionEvents: [],
            sessionRecords: [session: SessionRecord(
                session: session, journal: sessionJournal,
                cursor: JournalCursor(journal: sessionJournal, sequence: 0),
                events: [], nextEventSequence: 1)], sessionRelationships: [:],
            readAcknowledgements: [:],
            nextEventSequence: 1, nextSessionEventSequence: 1, nextRunOrdinal: 1,
            nextHostSequence: 1, commands: [:], terminalReservation: nil)
        let createCommand = CommandRef(
            commandID: request.commandID, client: request.client,
            sessionAttachment: sessionAttachment,
            causalCursor: state.cursor)
        _ = appendEvent(kind: TimelineEventType.workCreated,
                        commandID: request.commandID, command: createCommand,
                        session: session, sessionAttachment: sessionAttachment,
                        state: &state)
        let sessionCreated = appendSessionRecordEvent(
            kind: TimelineEventType.sessionCreated, session: session,
            journal: sessionJournal, sessionAttachment: nil, work: nil,
            client: nil, command: createCommand, causedBy: nil,
            capabilities: [], state: &state)
        let relationshipCapabilities = authorization.granted.subtracting([.createSession])
        let sessionAttached = appendSessionRecordEvent(
            kind: TimelineEventType.sessionAttached, session: session,
            journal: sessionJournal, sessionAttachment: sessionAttachment,
            work: work, client: request.client, command: createCommand,
            causedBy: EventRef(journal: sessionJournal, eventID: sessionCreated.eventID!),
            capabilities: relationshipCapabilities, state: &state)
        let causalWorkCursor = state.cursor!
        let mirroredWorkCursor = appendWorkSessionAttachmentEvent(
            session: session, sessionAttachment: sessionAttachment,
            client: request.client,
            command: CommandRef(
                commandID: request.commandID, client: request.client,
                sessionAttachment: sessionAttachment, causalCursor: causalWorkCursor),
            causedBy: EventRef(journal: sessionJournal, eventID: sessionAttached.eventID!),
            capabilities: relationshipCapabilities, state: &state)
        let sessionCursor = appendSessionRecordEvent(
            kind: TimelineEventType.sessionAttachmentCursorAdvanced, session: session,
            journal: sessionJournal, sessionAttachment: sessionAttachment,
            work: work, client: request.client, command: createCommand,
            causedBy: EventRef(journal: workJournal, eventID: mirroredWorkCursor.eventID!),
            capabilities: relationshipCapabilities,
            cursorForPayload: mirroredWorkCursor, state: &state)
        state.sessionRelationships[sessionAttachment] = WorkServiceSessionAttachmentDescriptor(
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, publication: .mirrored,
            causalSessionCursor: JournalCursor(journal: sessionJournal, sequence: 0),
            sessionCursor: sessionCursor, causalWorkCursor: causalWorkCursor,
            resultingWorkCursor: mirroredWorkCursor,
            capabilities: relationshipCapabilities)
        let workCursor = state.cursor!
        let attachment = WorkServiceClientAttachment(
            attachment: attachmentID, client: request.client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            authorization: authorization)
        state.attachments[attachmentID] = ClientState(attachment: attachment)
        works[work] = state
        // Canonical Create is a three-fact control transaction: identity reservation, source
        // registration, and the initial client attachment. The in-memory reference service
        // advances the same span as the journal-backed implementation so transport correlation
        // can distinguish a complete transaction from a skipped cursor.
        _ = appendControlEvent()
        _ = appendControlEvent()
        let resultingControlCursor = appendControlEvent()
        let receipt = WorkServiceControlReceipt(
            operation: .createWork, work: work, commandID: request.commandID,
            state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor,
            authorization: authorization, outcome: .created)
        let response = WorkServiceCreateWorkResponse(
            work: try requiredDescriptor(for: work, includeObservation: true), authorization: authorization,
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, attachment: attachment,
            workCursor: workCursor,
            sessionCursor: state.sessionCursor
                ?? JournalCursor(journal: sessionJournal, sequence: 0),
            controlCursor: resultingControlCursor, receipt: receipt)
        createCommands[createKey] = StoredCreate(request: request, response: response)
        return response
    }

    public func createSession(
        _ request: WorkServiceCreateSessionRequest
    ) async throws -> WorkServiceCreateSessionResponse {
        try requireReachable()
        guard var state = works[request.work] else {
            throw WorkServiceProtocolError.workNotFound(request.work)
        }
        guard request.journal == state.journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard validIdentity(request.client.clientID), validIdentity(request.commandID),
              validCursor(request.causalControlCursor, journal: controlJournal),
              validCursor(request.causalWorkCursor, journal: state.journal) else {
            throw WorkServiceProtocolError.invalidRequest(
                "invalid create Session client, command, or cursor identity")
        }
        let key = CreateCommandKey(client: request.client, commandID: request.commandID)

        // Reconcile an exact retry before looking at either causal cursor or the current
        // attachment. A response can be lost after the host has durably minted all identities;
        // replay must return those identities rather than accidentally becoming a stale reject.
        if let prior = createSessionCommands[key] {
            if prior.request == request {
                let replayWork = try requiredDescriptor(for: state.work, includeObservation: true)
                let replayAttachment: WorkServiceClientAttachment?
                if let original = prior.response.attachment,
                   let current = state.attachments[original.attachment] {
                    // The control attachment is mutable after publication. Replay the current
                    // grant when the row remains attached; publication authorization and the
                    // Session relationship stay bound to the original result below.
                    replayAttachment = current.attachment
                } else {
                    // Detach removes the live row, but the exact historical duplicate still
                    // returns the originally minted identity without resurrecting authority.
                    replayAttachment = prior.response.attachment
                }
                let duplicateReceipt = duplicateControl(of: prior.response.receipt)
                let replayState: WorkServiceCommandReceiptState =
                    prior.response.state == .rejected ? .rejected : .duplicate
                return WorkServiceCreateSessionResponse(
                    work: replayWork, session: prior.response.session,
                    sessionJournal: prior.response.sessionJournal,
                    sessionAttachment: prior.response.sessionAttachment,
                    attachment: replayAttachment,
                    relationship: prior.response.relationship,
                    workCursor: prior.response.workCursor,
                    sessionCursor: prior.response.sessionCursor,
                    controlCursor: prior.response.controlCursor,
                    authorization: prior.response.authorization,
                    commandID: prior.response.commandID, state: replayState,
                    host: prior.response.host,
                    causalControlCursor: prior.response.causalControlCursor,
                    causalWorkCursor: prior.response.causalWorkCursor,
                    receipt: duplicateReceipt, rejection: prior.response.rejection,
                    diagnostic: prior.response.state == .rejected
                        ? prior.response.diagnostic : "idempotent duplicate")
            }
            // This is a rejection of the current, conflicting request. Its authorization tuple
            // must describe that request rather than replaying the differently-shaped prior
            // request's capability set.
            let authorization = WorkServiceAuthorizationOutcome(
                requested: request.requestedCapabilities,
                granted: [], denied: request.requestedCapabilities,
                diagnostic: "command identity conflicts with a prior request")
            let currentCursor = state.cursor
                ?? JournalCursor(journal: state.journal, sequence: 0)
            let receipt = controlReceipt(
                operation: .createSession, work: state.work,
                commandID: request.commandID, state: .rejected,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                authorization: authorization, rejection: .conflictingCommand,
                diagnostic: "create Session command ID was already used with different contents")
            return WorkServiceCreateSessionResponse(
                work: try requiredDescriptor(for: state.work, includeObservation: true),
                workCursor: currentCursor, controlCursor: controlCursor,
                authorization: authorization, commandID: request.commandID,
                state: .rejected, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                causalWorkCursor: request.causalWorkCursor, receipt: receipt,
                rejection: .conflictingCommand,
                diagnostic: "create Session command ID was already used with different contents")
        }

        guard let authorizing = state.attachments[request.attachment],
              authorizing.attachment.client == request.client else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        let terminal = state.disposition != .reusable
        let semanticCapabilities: Set<WorkServiceCapability> = terminal
            ? [.observe]
            : Set(WorkServiceCapability.allCases).subtracting([.createSession])
        let principalSessionAuthorization = authorization(
            for: request.client, requested: request.requestedCapabilities)
        let effectiveCapabilities = request.requestedCapabilities
            .intersection(principalSessionAuthorization.granted)
            .intersection(authorizing.attachment.authorization.granted)
            .intersection(semanticCapabilities)
        let effectiveAuthorization = WorkServiceAuthorizationOutcome(
            requested: request.requestedCapabilities,
            granted: effectiveCapabilities,
            denied: request.requestedCapabilities.subtracting(effectiveCapabilities),
            diagnostic: effectiveCapabilities == request.requestedCapabilities
                ? nil : "capabilities were limited by the authorizing attachment or Work state")
        let operationAuthorization = authorization(
            for: request.client, requested: [.createSession])

        func rejected(
            _ rejection: WorkServiceCommandRejection,
            _ diagnostic: String,
            authorization: WorkServiceAuthorizationOutcome
        ) throws -> WorkServiceCreateSessionResponse {
            let currentWorkCursor = state.cursor
                ?? JournalCursor(journal: state.journal, sequence: 0)
            let receipt = controlReceipt(
                operation: .createSession, work: state.work,
                commandID: request.commandID, state: .rejected,
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                authorization: authorization, rejection: rejection,
                diagnostic: diagnostic)
            let response = WorkServiceCreateSessionResponse(
                work: try requiredDescriptor(for: state.work, includeObservation: true),
                workCursor: currentWorkCursor, controlCursor: controlCursor,
                authorization: authorization, commandID: request.commandID,
                state: .rejected, host: hostInstance,
                causalControlCursor: request.causalControlCursor,
                causalWorkCursor: request.causalWorkCursor, receipt: receipt,
                rejection: rejection, diagnostic: diagnostic)
            createSessionCommands[key] = StoredCreateSession(
                request: request, response: response)
            works[state.work] = state
            return response
        }
        guard operationAuthorization.allows(.createSession),
              authorizing.attachment.authorization.allows(.createSession) else {
            return try rejected(
                .authorizationDenied,
                "client attachment is not authorized to create a Session",
                authorization: effectiveAuthorization)
        }
        guard state.sourceCompleteness == .complete else {
            return try rejected(
                .sourceIncomplete,
                "host source is not complete enough to create a Session",
                authorization: effectiveAuthorization)
        }
        guard request.causalControlCursor == controlCursor else {
            return try rejected(
                .staleCursor,
                "create Session causal control cursor is not current",
                authorization: effectiveAuthorization)
        }
        guard request.causalWorkCursor == state.cursor else {
            return try rejected(
                .staleCursor,
                "create Session causal Work cursor is not current",
                authorization: effectiveAuthorization)
        }
        guard state.terminalReservation == nil else {
            return try rejected(
                .terminalProofUnavailable,
                "a terminal Work transaction is already in progress",
                authorization: effectiveAuthorization)
        }
        guard state.attachments.count < WorkServiceBounds.maxAttachmentsPerWork else {
            return try rejected(
                .invalidState,
                "Work client attachment bound reached",
                authorization: effectiveAuthorization)
        }
        if terminal {
            guard request.requestedCapabilities.contains(.observe),
                  effectiveCapabilities == [.observe] else {
                return try rejected(
                    .authorizationDenied,
                    "terminal Session references require an effective observe grant",
                    authorization: effectiveAuthorization)
            }
        }

        let terminalEvent: TimelineEvent?
        if terminal {
            guard let canonical = canonicalTerminalEvent(for: state) else {
                return try rejected(
                    .invalidState,
                    "terminal Work lacks an exact canonical terminal event at its advertised cursor",
                    authorization: effectiveAuthorization)
            }
            terminalEvent = canonical
        } else {
            terminalEvent = nil
        }

        // The descriptor carries semantic relationships, so this is an admission bound rather
        // than a presentation limit.  Include the original Session relationship when present;
        // the next operation must fail before minting or writing if all slots are occupied.
        let hasPrimaryRelationship = state.session != nil && state.sessionAttachment != nil
            && !state.sessionRelationships.values.contains {
                $0.sessionAttachment == state.sessionAttachment
            }
        let semanticRelationshipCount = state.sessionRelationships.count
            + (hasPrimaryRelationship ? 1 : 0)
        guard semanticRelationshipCount < WorkServiceBounds.maxSessionAttachmentsPerWork else {
            return try rejected(
                .invalidState,
                "Work Session attachment bound reached",
                authorization: effectiveAuthorization)
        }

        // All new identities are host-minted only after every rejection condition above has
        // passed. The generated values are bounded and monotonic within this host instance.
        let session = SessionRef("session-\(nextSessionOrdinal)")
        nextSessionOrdinal += 1
        let sessionJournal = JournalRef.session(
            session, authority: TimelineAuthorityRef(host.workHostID))
        let sessionAttachment = SessionAttachmentRef(
            "session-attachment-\(nextAttachmentOrdinal)")
        let clientAttachment = ClientAttachmentRef("attachment-\(nextAttachmentOrdinal)")
        nextAttachmentOrdinal += 1
        let causalWorkCursor = state.cursor
            ?? JournalCursor(journal: state.journal, sequence: 0)
        let causalSessionCursor = JournalCursor(journal: sessionJournal, sequence: 0)
        state.sessionRecords[session] = SessionRecord(
            session: session, journal: sessionJournal,
            cursor: causalSessionCursor, events: [], nextEventSequence: 1)

        let sessionCommand = WorkServiceCommandLedgerIdentity.command(
            from: CommandRef(
                commandID: request.commandID, client: request.client,
                sessionAttachment: sessionAttachment, causalCursor: causalWorkCursor),
            client: request.client)
        let sessionCreated = appendSessionRecordEvent(
            kind: TimelineEventType.sessionCreated, session: session,
            journal: sessionJournal, sessionAttachment: nil, work: nil,
            client: nil, command: sessionCommand, causedBy: nil,
            capabilities: [], state: &state)
        let sessionAttached = appendSessionRecordEvent(
            kind: TimelineEventType.sessionAttached, session: session,
            journal: sessionJournal, sessionAttachment: sessionAttachment,
            work: state.work, client: request.client, command: sessionCommand,
            causedBy: EventRef(journal: sessionJournal, eventID: sessionCreated.eventID!),
            capabilities: effectiveCapabilities, state: &state)
        let resultingWorkCursor: JournalCursor
        if terminal {
            // Terminal Work is immutable. The Session reference is independently durable, but
            // this operation may not append a Work event, advance its cursor, or alter bodies.
            resultingWorkCursor = causalWorkCursor
        } else {
            resultingWorkCursor = appendWorkSessionAttachmentEvent(
                session: session, sessionAttachment: sessionAttachment,
                client: request.client, command: sessionCommand,
                causedBy: EventRef(journal: sessionJournal, eventID: sessionAttached.eventID!),
                capabilities: effectiveCapabilities, state: &state)
        }
        let workEvidence = terminal
            ? terminalEvent.map { EventRef(journal: $0.journal, eventID: $0.eventID) }
            : EventRef(journal: state.journal, eventID: resultingWorkCursor.eventID!)
        let cursorAdvanced = appendSessionRecordEvent(
            kind: TimelineEventType.sessionAttachmentCursorAdvanced, session: session,
            journal: sessionJournal, sessionAttachment: sessionAttachment,
            work: state.work, client: request.client, command: sessionCommand,
            causedBy: workEvidence, capabilities: effectiveCapabilities,
            cursorForPayload: resultingWorkCursor, state: &state)
        let resultingSessionCursor = cursorAdvanced
        let publication: WorkServiceSessionAttachmentPublication = terminal
            ? .terminalReference : .mirrored
        let relationship = WorkServiceSessionAttachmentDescriptor(
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, publication: publication,
            causalSessionCursor: causalSessionCursor,
            sessionCursor: resultingSessionCursor,
            causalWorkCursor: causalWorkCursor,
            resultingWorkCursor: resultingWorkCursor,
            capabilities: effectiveCapabilities)
        state.sessionRelationships[sessionAttachment] = relationship
        let attachment = WorkServiceClientAttachment(
            attachment: clientAttachment, client: request.client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            authorization: effectiveAuthorization)
        state.attachments[clientAttachment] = ClientState(attachment: attachment)
        works[state.work] = state
        // Existing-Work Session creation has a durable reservation and a source-publication
        // result. Model both control facts even in-memory so every implementation exposes the
        // same exact cursor advance.
        _ = appendControlEvent()
        let resultingControlCursor = appendControlEvent()
        let receipt = controlReceipt(
            operation: .createSession, work: state.work, commandID: request.commandID,
            state: .accepted, causalControlCursor: request.causalControlCursor,
            resultingControlCursor: resultingControlCursor,
            authorization: effectiveAuthorization, outcome: .sessionCreated)
        let response = WorkServiceCreateSessionResponse(
            work: try requiredDescriptor(for: state.work, includeObservation: true),
            session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment, attachment: attachment,
            relationship: relationship, workCursor: resultingWorkCursor,
            sessionCursor: resultingSessionCursor, controlCursor: resultingControlCursor,
            authorization: effectiveAuthorization, commandID: request.commandID,
            state: .accepted, host: hostInstance,
            causalControlCursor: request.causalControlCursor,
            causalWorkCursor: request.causalWorkCursor, receipt: receipt)
        createSessionCommands[key] = StoredCreateSession(request: request, response: response)
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
        if let requestedAttachment = request.sessionAttachment {
            guard let relationship = state.sessionRelationships[requestedAttachment],
                  relationship.isAttached,
                  relationship.session == request.session,
                  relationship.sessionJournal == request.sessionJournal else {
                throw WorkServiceProtocolError.invalidRequest(
                    "attach Session tuple does not match the Work's canonical Session relationship")
            }
        }
        let authorization = authorization(
            for: request.client, requested: request.requestedCapabilities)
        if state.terminalReservation != nil {
            let response = WorkServiceAttachResponse(
                work: try requiredDescriptor(for: state.work, includeObservation: true), attachment: nil,
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
                work: try requiredDescriptor(for: state.work, includeObservation: true), attachment: nil,
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
                work: try requiredDescriptor(for: state.work, includeObservation: true), attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                rejection: .staleCursor, diagnostic: "attach causal cursor is not current")
            attachCommands[key] = StoredAttach(request: request, response: response)
            works[state.work] = state
            return response
        }
        if state.attachments.count >= WorkServiceBounds.maxAttachmentsPerWork {
            let response = WorkServiceAttachResponse(
                work: try requiredDescriptor(for: state.work, includeObservation: true), attachment: nil,
                authorization: authorization, commandID: request.commandID, state: .rejected,
                host: hostInstance, causalControlCursor: request.causalControlCursor,
                resultingControlCursor: controlCursor,
                rejection: .invalidState,
                diagnostic: "Work client attachment bound reached")
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
            work: try requiredDescriptor(for: state.work, includeObservation: true),
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
        let servedCursor = events.last.map {
            JournalCursor(journal: target.journal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? baselineCursor
        return WorkServiceSnapshot(work: try requiredDescriptor(for: state.work, includeObservation: true),
                                   events: events, target: request.target,
                                   servedCursor: servedCursor,
                                   basePrefixDigest: prefixDigest(target.events, cursor: baselineCursor),
                                   prefixDigest: prefixDigest(target.events, cursor: servedCursor),
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
        let baselineCursor = request.afterCursor
        let servedCursor = events.last.map {
            JournalCursor(journal: target.journal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? baselineCursor
        return WorkServiceEventPage(
            events: events, target: request.target,
            servedCursor: servedCursor,
            nextCursor: hasMore ? next : nil,
            basePrefixDigest: prefixDigest(target.events, cursor: baselineCursor),
            prefixDigest: prefixDigest(target.events, cursor: servedCursor),
            omissions: hasMore
                ? [WorkServiceOmission(
                    category: bytesLimited ? "event_bytes" : "events",
                    count: bytesLimited ? 1 : availableCount - events.count,
                    diagnostic: bytesLimited
                        ? "event page byte limit stopped the page" : nil)]
                : [])
    }

    public func historyBeforeCursor(
        _ request: WorkServiceHistoryRequest
    ) async throws -> WorkServiceHistoryPage {
        try requireReachable()
        let state = try attachedState(work: request.work, journal: request.journal,
                                      attachment: request.attachment, client: request.client,
                                      requiring: .observe)
        let target = try readTarget(request.target, for: state, attachment: request.attachment)
        guard target.journal.kind == .session, request.target.session != nil else {
            throw WorkServiceProtocolError.invalidRequest(
                "history paging requires a Session target")
        }
        var reducer = SessionReducer()
        for event in target.events { reducer.apply(event) }
        let projected = reducer.snapshot
        let visibleIDs: Set<String> = Set(projected.messages.compactMap {
            guard let source = $0.sourceEvent, source.journal == target.journal else { return nil }
            return source.eventID
        })
        let all = target.events.filter { visibleIDs.contains($0.eventID) }
        if let requestedBranchTip = request.branchTip,
           requestedBranchTip != projected.semanticTip {
            throw WorkServiceProtocolError.staleCursor(
                expected: request.frozenTipCursor
                    ?? JournalCursor(journal: target.journal, sequence: 0),
                actual: target.cursor)
        }
        let effectiveBranchTip = request.branchTip ?? projected.semanticTip
        return try historyPage(
            events: target.events, visibleEvents: all, journal: target.journal, target: request.target,
            before: request.beforeCursor, frozenTip: request.frozenTipCursor,
            frozenDigest: request.frozenTipDigest, branchTip: effectiveBranchTip,
            authority: try WorkServiceHistoryAuthority(
                work: state.work, journal: state.journal, hostInstance: hostInstance,
                sourceCompleteness: state.sourceCompleteness),
            limit: request.limit, maxBytes: request.maxBytes)
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
        let requestingAttachment = state.attachments[request.attachment]?.attachment
        let ownsRequestedSessionJournal = requestingAttachment?.sessionJournal == bodyJournal
            && requestingAttachment?.session != nil
            && requestingAttachment?.sessionAttachment != nil
        guard bodyJournal == state.journal || ownsRequestedSessionJournal else {
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

    public func cancelAgentHandle(
        _ request: WorkServiceAgentHandleCancelRequest
    ) async throws -> WorkServiceAgentHandleCancelResponse {
        try requireReachable()
        guard let client = request.command.client,
              request.command.sessionAttachment != nil,
              request.command.causalCursor == request.causalWorkCursor,
              request.causalWorkCursor.journal == request.journal,
              request.journal.owner == .work(request.work),
              validIdentity(request.handle.handleID),
              request.handle.handleID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              validIdentity(request.command.commandID),
              request.command.commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceProtocolError.invalidRequest(
                "agent Handle cancellation request is malformed")
        }
        guard let state = works[request.work] else {
            throw WorkServiceProtocolError.workNotFound(request.work)
        }
        guard state.journal == request.journal else {
            throw WorkServiceProtocolError.journalMismatch
        }
        guard let stored = state.attachments[request.attachment],
              stored.attachment.client == client,
              stored.attachment.sessionAttachment == request.command.sessionAttachment else {
            throw WorkServiceProtocolError.attachmentNotFound
        }
        guard stored.attachment.authorization.allows(.control) else {
            throw WorkServiceProtocolError.capabilityDenied(.control)
        }
        guard stored.attachment.authorization.allows(.cancel) else {
            throw WorkServiceProtocolError.capabilityDenied(.cancel)
        }
        // This reference service has no child execution model. A refusal is not a receipt and
        // does not advance the Work journal or claim that an execution was canceled.
        return try WorkServiceAgentHandleCancelResponse(
            work: request.work, handle: request.handle, commandID: request.command.commandID,
            disposition: .rejected, responder: hostInstance,
            causalWorkCursor: request.causalWorkCursor,
            authorization: WorkServiceAuthorizationOutcome(
                requested: [.control, .cancel], granted: [.control, .cancel], denied: []),
            rejection: .invalidState,
            diagnostic: "the reference service does not model this agent Handle")
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
        guard request.command.sessionAttachment == clientState.attachment.sessionAttachment else {
            throw WorkServiceProtocolError.invalidRequest(
                "command Session attachment does not match the authorizing client attachment")
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
        if request.kind == .start {
            // A live Run cannot be admitted from a Work-only client attachment.  Requiring the
            // complete canonical Session tuple here keeps the in-memory conformance service from
            // constructing an unrepresentable active descriptor (and mirrors the durable
            // run.started transition's exact relationship requirement).
            guard let session = clientState.attachment.session,
                  let sessionJournal = clientState.attachment.sessionJournal,
                  let sessionAttachment = clientState.attachment.sessionAttachment,
                  let relationship = state.sessionRelationships[sessionAttachment],
                  relationship.isAttached,
                  relationship.session == session,
                  relationship.sessionJournal == sessionJournal else {
                let receipt = makeReceipt(
                    state: &state, request: request, authorization: authorization,
                    state: .rejected, rejection: .malformedRequest,
                    diagnostic: "Start requires an exact attached Session relationship")
                state.commands[key] = StoredCommand(request: request, receipt: receipt)
                works[state.work] = state
                return receipt
            }
        }
        // A live Run is owned by the exact canonical Session attachment which admitted its
        // run.started marker. Reject another Session before changing the in-memory command
        // projection; this mirrors the durable service's fail-closed routing and guarantees no
        // cross-Session transcript or command-acceptance event is produced.
        if let activeRun = state.currentRun,
           (clientState.attachment.session != state.currentRunSession
                || clientState.attachment.sessionAttachment
                    != state.currentRunSessionAttachment),
           request.kind == .start || request.kind == .send || request.kind == .steer
                || request.kind == .queue || request.kind == .cancel || request.kind == .end {
            let receipt = makeReceipt(
                state: &state, request: request, authorization: authorization,
                state: .rejected, rejection: .invalidState,
                diagnostic: "active Run \(activeRun.runID) belongs to a different Session attachment")
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
            let canonicalCommand = WorkServiceCommandLedgerIdentity.command(
                from: request.command, client: clientID)
            let proofRequest = WorkServiceTerminalCommitRequest(
                operation: operation, work: state.work, journal: state.journal,
                client: clientID, session: session, sessionJournal: sessionJournal,
                sessionAttachment: sessionAttachment,
                causalWorkCursor: causal, detail: request.value, command: canonicalCommand)
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
        let canonicalCommand = WorkServiceCommandLedgerIdentity.command(
            from: request.command, client: clientID)
        let commandSession = clientState.attachment.session
        let commandSessionAttachment = clientState.attachment.sessionAttachment
        if request.kind == .start {
            state.currentRunSession = commandSession
            state.currentRunSessionAttachment = commandSessionAttachment
        }
        if request.kind == .start {
            _ = appendEvent(
                kind: TimelineEventType.runStarted, commandID: nil,
                command: nil, body: nil, hostSequence: nil,
                session: commandSession,
                sessionAttachment: commandSessionAttachment,
                state: &state)
        }
        let eventCursor = appendEvent(
            kind: TimelineEventType.commandAccepted, commandID: canonicalCommand.commandID,
            command: canonicalCommand, body: request.value, hostSequence: hostSequence,
            session: commandSession,
            sessionAttachment: commandSessionAttachment,
            commandKind: CanonicalCommandKind(rawValue: request.kind.rawValue),
            deliveryMode: .queued,
            carriesSessionInput: Self.commandCarriesSessionInput(request.kind, value: request.value),
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
        // The terminal Run identity belongs on the canonical event. Clear the live projection
        // only after appending it; otherwise a cold reducer sees `run.finished` with no Run and
        // correctly quarantines the Work.
        _ = appendEvent(
            kind: TimelineEventType.runFinished, commandID: nil,
            session: state.currentRunSession,
            sessionAttachment: state.currentRunSessionAttachment,
            state: &state)
        state.execution = .idle
        state.currentRun = nil
        state.currentRunSession = nil
        state.currentRunSessionAttachment = nil
        works[work] = state
    }

    /// Models explicit `work.completed`. Completion is immutable and cannot later be destroyed;
    /// destruction is an alternative terminal transition for reusable Work.
    private func requireReachable() throws {
        guard reachable else { throw WorkServiceProtocolError.hostUnavailable(host) }
    }

    private func supportedCapabilities() -> Set<WorkServiceCapability> {
        var capabilities = Set(WorkServiceCapability.allCases)
        capabilities.remove(.recordingDirectorySelection)
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
            let record = state.sessionRecords[session]
            let cursor = record?.journal == journal
                ? (record?.cursor ?? JournalCursor(journal: journal, sequence: 0))
                : JournalCursor(journal: journal, sequence: 0)
            let events = record?.journal == journal ? (record?.events ?? []) : []
            return (journal, cursor, events)
        }
    }

    private func historyPage(
        events: [TimelineEvent], visibleEvents: [TimelineEvent]? = nil,
        journal: JournalRef, target: WorkServiceReadTarget,
        before: JournalCursor?, frozenTip: JournalCursor?, frozenDigest: String?,
        branchTip: EventRef?, authority: WorkServiceHistoryAuthority,
        limit: Int, maxBytes: Int
    ) throws -> WorkServiceHistoryPage {
        guard limit > 0, limit <= WorkServiceBounds.maxEventsPerPage,
              maxBytes > 0, maxBytes <= WorkServiceBounds.maxEventPageBytes else {
            throw WorkServiceProtocolError.invalidRequest("history page bounds are invalid")
        }
        let allEvents: [TimelineEvent]
        switch target {
        case .work: allEvents = events
        case .session: allEvents = events
        }
        guard allEvents.allSatisfy({ $0.journal == journal }) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        let currentTip = allEvents.last.map {
            JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? JournalCursor(journal: journal, sequence: 0)
        let frozen = frozenTip ?? currentTip
        guard frozen.journal == journal, frozen.sequence >= 0,
              frozen.sequence <= currentTip.sequence else {
            throw WorkServiceProtocolError.invalidRequest("history frozen tip is foreign or ahead")
        }
        if frozen.sequence > 0 {
            guard allEvents.contains(where: {
                $0.sequence == frozen.sequence && $0.eventID == frozen.eventID
            }) else { throw WorkServiceProtocolError.staleCursor(expected: frozen, actual: currentTip) }
        } else if frozen.eventID != nil {
            throw WorkServiceProtocolError.invalidRequest("history baseline tip has an event ID")
        }
        let actualFrozenDigest = prefixDigest(allEvents, cursor: frozen)
        if let frozenDigest {
            guard frozenDigest == actualFrozenDigest else {
                throw WorkServiceProtocolError.staleCursor(expected: frozen, actual: currentTip)
            }
        }
        let effectiveDigest = frozenDigest ?? actualFrozenDigest
        guard effectiveDigest == actualFrozenDigest else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        if let branchTip {
            guard branchTip.journal == journal,
                  allEvents.contains(where: { $0.eventID == branchTip.eventID }) else {
                throw WorkServiceProtocolError.staleCursor(expected: frozen, actual: currentTip)
            }
        }
        let visible = (visibleEvents ?? allEvents).filter { $0.sequence <= frozen.sequence }
        let cutoff: Int
        if let before {
            guard before.journal == journal, before.sequence >= 0,
                  before.sequence <= frozen.sequence else {
                throw WorkServiceProtocolError.invalidRequest("history boundary is foreign or ahead")
            }
            if before.sequence > 0 {
                guard visible.contains(where: {
                    $0.sequence == before.sequence && $0.eventID == before.eventID
                }) else {
                    throw WorkServiceProtocolError.invalidRequest(
                        "history boundary must identify a visible message")
                }
            } else if before.eventID != nil {
                throw WorkServiceProtocolError.invalidRequest("history baseline has an event ID")
            }
            cutoff = before.sequence
        } else {
            cutoff = Int.max
        }
        let candidates = visible.filter { $0.sequence < cutoff }
        var selected: [TimelineEvent] = []
        var bytes = 0
        for event in candidates.reversed() {
            guard selected.count < limit else { break }
            let size = try WorkServiceEventPageSizing.encodedByteCount(of: event)
            guard size <= maxBytes else {
                if selected.isEmpty {
                    throw WorkServiceProtocolError.eventPageCannotProgress(
                        requiredBytes: size, maximumBytes: maxBytes)
                }
                break
            }
            guard bytes + size <= maxBytes else { break }
            selected.append(event)
            bytes += size
        }
        selected.reverse()
        let lower = selected.first.map { JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence) }
        let upper = selected.last.map { JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence) }
        let hasOlder = candidates.count > selected.count
        let nextBefore = hasOlder ? lower : nil
        // The page contains only selected conversation messages, not physical control events.
        // Hashing the selected sequence keeps this field recomputable from the response and does
        // not imply that omitted physical events were delivered to the caller.
        let pageDigest = try WorkServiceHistoryPageEvidence.digest(
            events: selected, target: target, cursor: upper ?? frozen)
        var omissions: [WorkServiceOmission] = []
        if hasOlder {
            omissions.append(WorkServiceOmission(
                category: "history", count: min(candidates.count - selected.count,
                                                  WorkServiceBounds.maxOmissionCount),
                diagnostic: "older visible messages remain"))
        }
        return WorkServiceHistoryPage(
            authority: authority,
            events: selected, target: target, lowerBoundaryCursor: lower,
            upperBoundaryCursor: upper, nextBeforeCursor: nextBefore,
            hasOlder: hasOlder, frozenTipCursor: frozen,
            frozenTipDigest: effectiveDigest, prefixDigest: pageDigest,
            branchTip: branchTip, omissions: omissions)
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
            let eventBytes = try WorkServiceEventPageSizing.encodedByteCount(of: event)
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

    /// Digest the canonical event prefix, including the exact journal and cursor identity. This
    /// is service-issued evidence for a local reducer checkpoint; it is not a client-computed
    /// substitute for reading and validating the events during the current refresh.
    private func prefixDigest(_ events: [TimelineEvent], cursor: JournalCursor) -> String {
        var data = Data()
        data.append(Data((cursor.journal.stableKey + "\u{0}" + String(cursor.sequence)
            + "\u{0}" + (cursor.eventID ?? "") + "\u{0}").utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for event in events where event.sequence <= cursor.sequence {
            if let encoded = try? encoder.encode(event) {
                data.append(encoded)
                data.append(0)
            }
        }
        return WorkServiceText.digest(data)
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

    /// Descriptor construction is a validation boundary: an internally inconsistent Work (for
    /// example an active Run without its exact Session owner) cannot be represented by the
    /// protocol DTO. Public operations must surface that condition as a typed unavailable
    /// source, never trap while force-unwrapping the optional projection.
    private func requiredDescriptor(
        for work: WorkRef, includeObservation: Bool
    ) throws -> WorkServiceWorkDescriptor {
        guard let descriptor = descriptor(for: work, includeObservation: includeObservation) else {
            throw WorkServiceProtocolError.sourceIncomplete
        }
        return descriptor
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
        // An incomplete source may retain a durable Run identity without proving its exact
        // Session/attachment owner. Never expose that unqualified Run through the DTO; callers
        // must observe the recovery-required state and wait for a complete canonical projection.
        let exposeOwner = state.sourceCompleteness == .complete
        let exposedCurrentRun = exposeOwner ? state.currentRun : nil
        let exposedCurrentRunSession = exposeOwner ? state.currentRunSession : nil
        let exposedCurrentRunSessionAttachment = exposeOwner
            ? state.currentRunSessionAttachment : nil
        let observation = includeObservation ? (try? WorkServiceHostObservation(
            instance: hostInstance, reachability: reachable ? .observedReachable : .unavailable,
            currentRun: exposedCurrentRun,
            currentRunSession: exposedCurrentRunSession,
            currentRunSessionAttachment: exposedCurrentRunSessionAttachment,
            servedCursor: state.cursor,
            sourceCompleteness: state.sourceCompleteness)) : nil
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
        let relationships = sessionAttachmentProjections(for: state)
        guard let descriptor = try? WorkServiceWorkDescriptor(
            work: state.work, journal: state.journal, recordedDisposition: state.disposition,
            execution: state.execution, currentRun: exposedCurrentRun,
            currentRunSession: exposedCurrentRunSession,
            currentRunSessionAttachment: exposedCurrentRunSessionAttachment,
            configuration: state.configuration.observableDescriptorConfiguration,
            hostObservation: observation, attachments: clients,
            sessionAttachments: relationships, artifacts: artifacts,
            omissions: WorkServiceText.boundedOmissions(omissions)) else { return nil }
        return descriptor
    }

    private func sessionAttachmentProjections(
        for state: WorkState
    ) -> [WorkServiceSessionAttachmentDescriptor] {
        // Only relationships backed by the exact reciprocal publication path are projected.
        // Seed metadata without retained Work/Session evidence is deliberately not upgraded into
        // a fabricated mirror; callers must create or register canonical relationship evidence.
        return state.sessionRelationships.values.sorted {
            if $0.session.sessionID != $1.session.sessionID {
                return $0.session.sessionID < $1.session.sessionID
            }
            return $0.sessionAttachment.attachmentID < $1.sessionAttachment.attachmentID
        }
    }

    /// Return the terminal event that exactly proves the immutable disposition. A terminal enum
    /// alone is not enough: a seed with a claimed disposition but no canonical event must not
    /// be exposed as a terminal reference to a newly-created Session.
    private func canonicalTerminalEvent(for state: WorkState) -> TimelineEvent? {
        let expectedType: String
        switch state.disposition {
        case .completed:
            expectedType = TimelineEventType.workCompleted
        case .destroyed:
            expectedType = TimelineEventType.workDestroyed
        case .reusable:
            return nil
        }
        guard let cursor = state.cursor, cursor.sequence > 0,
              let eventID = cursor.eventID,
              state.events.count == cursor.sequence,
              state.events.enumerated().allSatisfy({ index, event in
                  let expectedSequence = index + 1
                  let expectedPrevious = index == 0 ? nil : state.events[index - 1].eventID
                  return event.journal == state.journal
                      && event.sequence == expectedSequence
                      && event.previousEventID == expectedPrevious
              }),
              let event = state.events.last,
              event.eventID == eventID,
              event.journal == state.journal,
              event.sequence == cursor.sequence,
              event.type == expectedType,
              event.work == state.work,
              event.workHost == host else {
            return nil
        }
        let reduced = WorkReducer.reduce(state.events)
        guard reduced.journal == state.journal,
              reduced.work == state.work,
              reduced.workHost == host,
              reduced.lastEventID == eventID,
              reduced.lastSequence == cursor.sequence,
              reduced.causalOrderValid,
              reduced.structuralIntegrityValid,
              reduced.semanticProjectionValid,
              reduced.lifecycle == (state.disposition == .completed ? .completed : .destroyed)
        else { return nil }
        return event
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
            guard (state.execution == .running || state.execution == .idle),
                  state.currentRun != nil else { return nil }
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
            guard state.execution == .running || state.execution == .held
                    || state.execution == .canceling
                    || (state.execution == .idle && state.currentRun != nil) else { return nil }
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

    /// In-memory hosts with a catalog model the same opaque-ID admission rule as the durable
    /// host. An empty catalog is an explicit conformance-host choice and remains permissive; once
    /// a host advertises entries, Create must name one currently resolvable entry and may not
    /// smuggle a path-shaped selector through an untyped field.
    private func validateWorkspaceSelection(
        _ configuration: WorkServiceWorkConfiguration
    ) throws {
        guard !workspaceCatalog.entries.isEmpty else { return }
        guard let workspaceID = configuration.workspaceID,
              let descriptor = workspaceCatalog.entries.first(where: {
                  $0.workspaceID == workspaceID
              }),
              descriptor.availability == .available,
              descriptor.capabilities.contains(.resolve) else {
            throw WorkServiceProtocolError.invalidRequest(
                "Create requires an available workspaceID advertised by this Work Host")
        }
    }

    private func appendSessionRecordEvent(
        kind: String, session: SessionRef, journal: JournalRef,
        sessionAttachment: SessionAttachmentRef?, work: WorkRef?, client: ClientRef?,
        command: CommandRef?, causedBy: EventRef?,
        capabilities: Set<WorkServiceCapability>, cursorForPayload: JournalCursor? = nil,
        state: inout WorkState
    ) -> JournalCursor {
        var record = state.sessionRecords[session] ?? SessionRecord(
            session: session, journal: journal,
            cursor: JournalCursor(journal: journal, sequence: 0),
            events: [], nextEventSequence: 1)
        let sequence = record.nextEventSequence
        record.nextEventSequence += 1
        let eventID = "service-session-event-\(session.sessionID)-\(sequence)"
        let cursor = JournalCursor(journal: journal, eventID: eventID, sequence: sequence)
        var payloadFields: [String: JSONValue] = [
            "capabilities": .array(capabilities.sorted { $0.rawValue < $1.rawValue }
                .map { .string($0.rawValue) })
        ]
        if let cursorForPayload,
           let encoded = try? JSONEncoder().encode(cursorForPayload),
           let value = JSONValue.parse(encoded) {
            payloadFields["cursor"] = value
        }
        let payload = JSONValue.object(payloadFields)
        let event = TimelineEvent(
            eventID: eventID, journal: journal, sequence: sequence,
            idempotencyKey: command?.commandID, command: command,
            previousEventID: record.events.last?.eventID, causedByEventID: causedBy,
            session: session, work: work, workHost: work.map { WorkHostRef($0.workHostID) },
            client: client, sessionAttachment: sessionAttachment,
            actor: TimelineActor(actorID: hostInstance.instanceID, kind: "work-service"),
            hostRecordedAt: Date(), type: WorkServiceText.bound(kind) ?? "unknown",
            payload: payload)
        record.cursor = cursor
        record.events.append(event)
        state.sessionRecords[session] = record
        if state.session == session {
            state.sessionCursor = cursor
            state.sessionEvents = record.events
            state.nextSessionEventSequence = record.nextEventSequence
        }
        return cursor
    }

    private func appendWorkSessionAttachmentEvent(
        session: SessionRef, sessionAttachment: SessionAttachmentRef,
        client: ClientRef, command: CommandRef, causedBy: EventRef,
        capabilities: Set<WorkServiceCapability>, state: inout WorkState
    ) -> JournalCursor {
        let sequence = state.nextEventSequence
        state.nextEventSequence += 1
        let eventID = "service-event-\(sequence)"
        let cursor = JournalCursor(journal: state.journal, eventID: eventID, sequence: sequence)
        let payload = JSONValue.object([
            "capabilities": .array(capabilities.sorted { $0.rawValue < $1.rawValue }
                .map { .string($0.rawValue) })
        ])
        state.cursor = cursor
        state.events.append(TimelineEvent(
            eventID: eventID, journal: state.journal, sequence: sequence,
            hostSequence: state.nextHostSequence, idempotencyKey: command.commandID,
            command: command, previousEventID: state.events.last?.eventID,
            causedByEventID: causedBy, session: session, work: state.work,
            workHost: host, client: client, sessionAttachment: sessionAttachment,
            run: state.currentRun,
            actor: TimelineActor(actorID: hostInstance.instanceID, kind: "work-service"),
            hostRecordedAt: Date(), type: TimelineEventType.sessionAttached,
            payload: payload))
        state.nextHostSequence += 1
        return cursor
    }

    private func appendEvent(kind: String, commandID: String?, command: CommandRef? = nil,
                             body: String? = nil, hostSequence: Int? = nil,
                             session: SessionRef? = nil,
                             sessionAttachment: SessionAttachmentRef? = nil,
                             commandKind: CanonicalCommandKind? = nil,
                             deliveryMode: RunInputDeliveryMode? = nil,
                             carriesSessionInput: Bool? = nil,
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
        var payloadFields: [String: JSONValue] = [:]
        if let commandKind { payloadFields["command_kind"] = .string(commandKind.rawValue) }
        if let deliveryMode { payloadFields["delivery_mode"] = .string(deliveryMode.rawValue) }
        if let carriesSessionInput { payloadFields["carries_session_input"] = .bool(carriesSessionInput) }
        if let bodyReference,
           let encoded = try? JSONEncoder().encode(bodyReference),
           let referenceValue = JSONValue.parse(encoded) {
            // Keep sensitive/large command text in the retained body store only. The canonical
            // event envelope carries the authority-bearing reference so a reader can fetch the
            // exact bytes without retaining a second raw copy in the timeline page.
            payloadFields["body_reference"] = referenceValue
            payload = .object(payloadFields)
        } else {
            // Never copy the body into the event as a serialization fallback.  The body store
            // remains the only place where command text is retained; an unexpected reference
            // encoding failure is represented by a bounded marker instead of leaking raw text.
            if body != nil { payloadFields["body_reference_unavailable"] = .bool(true) }
            payload = .object(payloadFields)
        }
        state.events.append(TimelineEvent(
            eventID: eventID, journal: state.journal, sequence: sequence,
            hostSequence: hostSequence, idempotencyKey: commandID, command: command,
            previousEventID: state.events.last?.eventID,
            causedByEventID: command?.causalCursor?.eventID.map {
                EventRef(journal: state.journal, eventID: $0)
            },
            session: session, work: state.work, workHost: host,
            client: command?.client, sessionAttachment: sessionAttachment,
            run: state.currentRun,
            actor: TimelineActor(actorID: hostInstance.instanceID, kind: "work-service"),
            hostRecordedAt: Date(), type: WorkServiceText.bound(kind) ?? "unknown",
            payload: payload))
        return cursor
    }

    private static func commandCarriesSessionInput(
        _ kind: WorkServiceCommandKind, value: String?
    ) -> Bool {
        guard let value, !value.isEmpty else { return false }
        switch kind {
        case .start, .send, .steer, .queue: return true
        case .hold, .cancel, .end, .destroy, .complete: return false
        }
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
        if let sessionRecord = state.sessionRecords[session] {
            state.sessionRecords[session] = SessionRecord(
                session: sessionRecord.session, journal: sessionRecord.journal,
                cursor: cursor, events: state.sessionEvents,
                nextEventSequence: state.nextSessionEventSequence)
        } else {
            state.sessionRecords[session] = SessionRecord(
                session: session, journal: journal, cursor: cursor,
                events: state.sessionEvents, nextEventSequence: state.nextSessionEventSequence)
        }
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
        "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func precedes(_ lhs: WorkRef, _ rhs: WorkRef) -> Bool {
        if lhs.workHostID != rhs.workHostID { return lhs.workHostID < rhs.workHostID }
        return lhs.workID < rhs.workID
    }
}
