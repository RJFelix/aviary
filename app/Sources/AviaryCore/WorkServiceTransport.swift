import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Wire values

/// Operations carried by the local Work service transport.  These names are deliberately
/// transport-facing rather than Swift method names: a future remote adapter can use the same
/// envelopes without importing the implementation of ``InMemoryWorkService``.
public enum WorkServiceTransportOperation: String, Codable, Hashable, Sendable {
    case handshake
    case listWorks = "list_works"
    case describeWork = "describe_work"
    case createWork = "create_work"
    case createSession = "create_session"
    case completeWork = "complete_work"
    case attach
    case detach
    case updateCapabilities = "update_capabilities"
    case acknowledgeRead = "acknowledge_read"
    case snapshot
    case eventsAfterCursor = "events_after_cursor"
    case fetchArtifact = "fetch_artifact"
    case fetchBody = "fetch_body"
    case command
}

/// The endpoint is an address only.  The host identity returned by the handshake is the
/// authority-bearing value; a path, inode, or process ID is never sufficient to adopt Work.
public struct WorkServiceTransportEndpoint: Codable, Hashable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

/// A future host deployment can bind a transport's claimed ``ClientRef`` to an operating-system
/// principal, a device key, or a remote session.  The first Unix-domain implementation leaves
/// this nil by design: the filesystem endpoint and the client string are a same-user convenience,
/// not a complete authentication or sandbox boundary.  Callers that need real principal
/// binding should provide an implementation before exposing a socket beyond that trust domain.
public protocol WorkServiceTransportPrincipalBinding: Sendable {
    func accepts(claimedClient: ClientRef) -> Bool
}

public enum WorkServiceTransportErrorCode: String, Codable, Hashable, Sendable {
    case invalidFrame = "invalid_frame"
    case frameTooLarge = "frame_too_large"
    case invalidRequest = "invalid_request"
    case handshakeRequired = "handshake_required"
    case handshakeRejected = "handshake_rejected"
    case identityMismatch = "identity_mismatch"
    case duplicateRequestID = "duplicate_request_id"
    case unsupportedOperation = "unsupported_operation"
    case unsupportedVersion = "unsupported_version"
    case serviceUnavailable = "service_unavailable"
    case workNotFound = "work_not_found"
    case journalMismatch = "journal_mismatch"
    case attachmentNotFound = "attachment_not_found"
    case capabilityDenied = "capability_denied"
    case artifactNotFound = "artifact_not_found"
    case eventPageCannotProgress = "event_page_cannot_progress"
    case staleCursor = "stale_cursor"
    case sourceIncomplete = "source_incomplete"
    case transportClosed = "transport_closed"
    case serverStopping = "server_stopping"
    case internalError = "internal_error"
}

/// Public errors make failures distinguishable without exposing POSIX errno details as a
/// protocol contract.  Diagnostic text is bounded at construction sites and is never required
/// for a caller to classify the result.
public enum WorkServiceTransportError: Error, Equatable, Sendable {
    case invalidEndpoint(String)
    case endpointOccupied
    case notConnected
    case alreadyConnected
    case disconnected
    case frameTooLarge(bytes: Int, limit: Int)
    case invalidFrame
    case invalidResponse
    case remote(code: WorkServiceTransportErrorCode, detail: String?)
    case duplicateResponseID
    case tooManyPendingRequests
    case timedOut(operation: WorkServiceTransportOperation)
    case canceled
    case writeFailed(String)
}

public struct WorkServiceTransportRequestEnvelope: Codable, Hashable, Sendable {
    public let id: String
    public let operation: WorkServiceTransportOperation
    /// A connection's client identity is repeated on each request.  This is not authentication;
    /// it is an identity-consistency fence that prevents one socket from changing principals.
    public let client: ClientRef?
    public let payload: JSONValue?

    public init(id: String, operation: WorkServiceTransportOperation,
                client: ClientRef? = nil, payload: JSONValue? = nil) {
        self.id = id
        self.operation = operation
        self.client = client
        self.payload = payload
    }
}

public struct WorkServiceTransportErrorBody: Codable, Hashable, Sendable {
    public let code: WorkServiceTransportErrorCode
    public let detail: String?

    public init(code: WorkServiceTransportErrorCode, detail: String? = nil) {
        self.code = code
        self.detail = WorkServiceTransportText.bound(detail)
    }
}

public struct WorkServiceTransportResponseEnvelope: Codable, Hashable, Sendable {
    public let id: String
    public let ok: Bool
    public let data: JSONValue?
    public let error: WorkServiceTransportErrorBody?
    /// Every successful post-handshake response carries the exact instance negotiated on this
    /// connection. Stable journal authority alone cannot distinguish a restarted or swapped
    /// Work Host process when a page happens to be empty.
    public let hostInstance: WorkHostInstanceRef?

    public init(id: String, ok: Bool, data: JSONValue? = nil,
                error: WorkServiceTransportErrorBody? = nil,
                hostInstance: WorkHostInstanceRef? = nil) {
        self.id = id
        self.ok = ok
        self.data = data
        self.error = error
        self.hostInstance = hostInstance
    }
}

public enum WorkServiceTransportCodec {
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxRequestIDCharacters = 128

    /// Keep every socket-side framing decision on the same bounded configuration.  In particular,
    /// a negative or enormous caller value must never make ``LineFramer`` or a write queue grow
    /// without limit.
    public static func clampFrameBytes(_ value: Int) -> Int {
        max(2, min(value, maxFrameBytes))
    }

    public static func encodeFrame<T: Encodable>(_ value: T,
                                                   maxBytes: Int = maxFrameBytes) throws -> Data {
        let limit = clampFrameBytes(maxBytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        let frameBytes = encoded.count + 1
        guard frameBytes <= limit else {
            throw WorkServiceTransportError.frameTooLarge(bytes: frameBytes, limit: limit)
        }
        var frame = encoded
        frame.append(UInt8(ascii: "\n"))
        return frame
    }

    public static func decodeRequest(_ data: Data) throws -> WorkServiceTransportRequestEnvelope {
        do {
            let envelope = try JSONDecoder().decode(
                WorkServiceTransportRequestEnvelope.self, from: data)
            guard validRequestID(envelope.id) else {
                throw WorkServiceTransportError.invalidFrame
            }
            if let payload = envelope.payload {
                do {
                    try validateJSONSemantics(payload)
                } catch {
                    // Keep malformed request shape classified as a frame error. The same
                    // bounded JSON walk is used for responses, but request failures must not
                    // expose the response-side error vocabulary on the server.
                    throw WorkServiceTransportError.invalidFrame
                }
            }
            return envelope
        } catch let error as WorkServiceTransportError {
            throw error
        } catch {
            throw WorkServiceTransportError.invalidFrame
        }
    }

    public static func decodeResponse(_ data: Data) throws -> WorkServiceTransportResponseEnvelope {
        do {
            let envelope = try JSONDecoder().decode(
                WorkServiceTransportResponseEnvelope.self, from: data)
            guard validRequestID(envelope.id), envelope.ok == (envelope.error == nil),
                  envelope.ok ? envelope.data != nil : envelope.data == nil else {
                throw WorkServiceTransportError.invalidResponse
            }
            if let detail = envelope.error?.detail,
               detail.utf8.count > WorkServiceBounds.maxDiagnosticCharacters {
                throw WorkServiceTransportError.invalidResponse
            }
            if let data = envelope.data {
                try validateJSONSemantics(data)
            }
            if let hostInstance = envelope.hostInstance {
                try validateHostInstanceValue(hostInstance)
            }
            return envelope
        } catch let error as WorkServiceTransportError {
            throw error
        } catch {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    fileprivate static func encodePayload<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let payload = JSONValue.parse(data) else {
            throw WorkServiceTransportError.invalidFrame
        }
        return payload
    }

    fileprivate static func decodePayload<T: Decodable>(_ type: T.Type,
                                                          from payload: JSONValue?) throws -> T {
        guard let payload else { throw WorkServiceTransportError.invalidFrame }
        let data = try JSONEncoder().encode(payload)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw WorkServiceTransportError.invalidFrame
        }
    }

    fileprivate static func validRequestID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= maxRequestIDCharacters
            && !id.contains(where: { $0 == "\n" || $0 == "\r" })
    }

    /// Validate bounds that a frame-size check alone cannot express.  A four-megabyte JSON frame
    /// can still contain a pathological nesting/array shape that makes a consumer allocate or
    /// render without limit.  These are transport safeguards; the Work service remains the
    /// authority for the exact domain limits and the client decodes those values afterward.
    static func validateResponseSemantics(
        _ response: WorkServiceTransportResponseEnvelope,
        operation: WorkServiceTransportOperation
    ) throws {
        if let data = response.data {
            switch operation {
            case .listWorks:
                try validateArray(data["works"], maxCount: WorkServiceBounds.maxPageSize)
                try validateArray(data["omissions"], maxCount: WorkServiceBounds.maxOmissions)
                for work in data["works"]?.arrayValue ?? [] {
                    try validateWorkDescriptor(work)
                }
            case .describeWork:
                try validateArray(
                    data["attachments"], maxCount: WorkServiceBounds.maxAttachmentsPerWork)
                try validateArray(data["artifacts"], maxCount: WorkServiceBounds.maxArtifactsPerWork)
                try validateArray(data["omissions"], maxCount: WorkServiceBounds.maxOmissions)
                try validateWorkDescriptor(data)
            case .snapshot:
                try validateWorkDescriptor(data["work"] ?? .null)
                try validateArray(data["events"], maxCount: WorkServiceBounds.maxEventsPerPage)
                try validateArray(data["omissions"], maxCount: WorkServiceBounds.maxOmissions)
                try validatePrefixDigest(data["basePrefixDigest"])
                try validatePrefixDigest(data["prefixDigest"])
                for event in data["events"]?.arrayValue ?? [] {
                    try validateTimelineEvent(event)
                }
            case .eventsAfterCursor:
                try validateArray(data["events"], maxCount: WorkServiceBounds.maxEventsPerPage)
                try validateArray(data["omissions"], maxCount: WorkServiceBounds.maxOmissions)
                try validatePrefixDigest(data["basePrefixDigest"])
                try validatePrefixDigest(data["prefixDigest"])
                for event in data["events"]?.arrayValue ?? [] {
                    try validateTimelineEvent(event)
                }
            case .handshake:
                try validateArray(
                    data["capabilities"], maxCount: WorkServiceCapability.allCases.count)
                try validateHostInstance(data["hostInstance"], required: true)
                try validateJournalReference(data["controlJournal"] ?? .null)
                try validateCursor(data["controlCursor"], required: true)
                try validateWorkspaceCatalog(data["workspaceCatalog"] ?? .null)
                try validateDiagnostic(data["diagnostic"])
            case .attach:
                try validateArray(data["work"]?["attachments"],
                                  maxCount: WorkServiceBounds.maxAttachmentsPerWork)
                try validateWorkDescriptor(data["work"] ?? .null)
                if let attachment = data["attachment"], !attachment.isNull {
                    try validateClientAttachment(attachment)
                }
                try validateAuthorization(data["authorization"], required: true)
                try validateIdentity(data["commandID"], required: true)
                try validateHostInstance(data["host"], required: true)
                try validateCursor(data["causalControlCursor"], required: true)
                try validateCursor(data["resultingControlCursor"], required: true)
                try validateControlReceipt(data["receipt"] ?? .null)
                try validateDiagnostic(data["diagnostic"])
            case .createWork:
                try validateWorkDescriptor(data["work"] ?? .null)
                try validateIdentity(data["session"]?["sessionID"], required: true)
                try validateJournalReference(data["sessionJournal"] ?? .null)
                try validateIdentity(data["sessionAttachment"]?["attachmentID"], required: true)
                try validateClientAttachment(data["attachment"] ?? .null)
                try validateCursor(data["workCursor"], required: true)
                try validateCursor(data["sessionCursor"], required: true)
                try validateCursor(data["controlCursor"], required: true)
                try validateAuthorization(data["authorization"], required: true)
                try validateControlReceipt(data["receipt"] ?? .null)
            case .createSession:
                try validateWorkDescriptor(data["work"] ?? .null)
                try validateIdentity(data["session"]?["sessionID"])
                if let journal = data["sessionJournal"], !journal.isNull {
                    try validateJournalReference(journal)
                }
                try validateIdentity(data["sessionAttachment"]?["attachmentID"])
                if let attachment = data["attachment"], !attachment.isNull {
                    try validateClientAttachment(attachment)
                }
                if let relationship = data["relationship"], !relationship.isNull {
                    try validateSessionAttachmentDescriptor(relationship)
                }
                try validateCursor(data["workCursor"], required: true)
                try validateCursor(data["sessionCursor"])
                try validateCursor(data["controlCursor"], required: true)
                try validateAuthorization(data["authorization"], required: true)
                try validateIdentity(data["commandID"], required: true)
                try validateHostInstance(data["host"], required: true)
                try validateCursor(data["causalControlCursor"], required: true)
                try validateCursor(data["causalWorkCursor"], required: true)
                try validateControlReceipt(data["receipt"] ?? .null)
                try validateDiagnostic(data["diagnostic"])
            case .completeWork, .command:
                try validateReceipt(data)
            case .updateCapabilities:
                try validateIdentity(data["work"]?["workHostID"], required: true)
                try validateIdentity(data["work"]?["workID"], required: true)
                if let attachment = data["attachment"], !attachment.isNull {
                    try validateClientAttachment(attachment)
                }
                try validateAuthorization(data["authorization"], required: true)
                try validateIdentity(data["commandID"], required: true)
                try validateHostInstance(data["host"], required: true)
                try validateCursor(data["causalControlCursor"], required: true)
                try validateCursor(data["resultingControlCursor"], required: true)
                try validateControlReceipt(data["receipt"] ?? .null)
                try validateDiagnostic(data["diagnostic"])
            case .acknowledgeRead:
                try validateIdentity(data["work"]?["workHostID"], required: true)
                try validateIdentity(data["work"]?["workID"], required: true)
                try validateIdentity(data["commandID"], required: true)
                try validateHostInstance(data["host"], required: true)
                try validateReadTarget(data["target"] ?? .null)
                try validateCursor(data["cursor"], required: true)
                try validateCursor(data["causalControlCursor"], required: true)
                try validateCursor(data["resultingControlCursor"], required: true)
                try validateControlReceipt(data["receipt"] ?? .null)
                try validateDiagnostic(data["diagnostic"])
            case .detach:
                try validateIdentity(data["commandID"], required: true)
                try validateDiagnostic(data["diagnostic"])
                try validateIdentity(data["work"]?["workHostID"], required: true)
                try validateIdentity(data["work"]?["workID"], required: true)
                try validateHostInstance(data["host"], required: true)
                try validateCursor(data["causalControlCursor"], required: true)
                try validateCursor(data["resultingControlCursor"], required: true)
                try validateControlReceipt(data["receipt"] ?? .null)
            case .fetchArtifact:
                try validateArtifactDescriptor(data)
            case .fetchBody:
                try validateBodyResponse(data)
            }
        }
    }

    /// A response can be frame-valid and still answer a different Work, cursor, or body than
    /// the request that is waiting for it.  Keep this correlation check beside the semantic
    /// bounds so a remote host cannot make a client silently attach a valid-looking projection
    /// to the wrong durable identity.
    static func validateResponseCorrelation(
        _ response: WorkServiceTransportResponseEnvelope,
        request: WorkServiceTransportRequestEnvelope,
        expectedHostInstance: WorkHostInstanceRef? = nil
    ) throws {
        if request.operation != .handshake {
            guard let expectedHostInstance,
                  response.hostInstance == expectedHostInstance else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        guard response.ok else { return }
        guard let data = response.data else {
            throw WorkServiceTransportError.invalidResponse
        }
        switch request.operation {
        case .handshake:
            // `validateHandshake` additionally verifies the host and host-instance pairing. The
            // envelope copy must agree with the negotiated DTO so it cannot be swapped between
            // the handshake response and later response correlation.
            let handshake: WorkServiceHandshakeResponse = try decodeResponseValue(
                WorkServiceHandshakeResponse.self, from: data)
            guard response.hostInstance == handshake.hostInstance else {
                throw WorkServiceTransportError.invalidResponse
            }
            return
        case .listWorks:
            let response: WorkServiceWorkPage = try decodeResponseValue(
                WorkServiceWorkPage.self, from: data)
            if let expectedHostInstance {
                try response.works.forEach {
                    try validateDescriptorHost($0, expected: expectedHostInstance)
                }
            }
        case .describeWork:
            let response: WorkServiceWorkDescriptor = try decodeResponseValue(
                WorkServiceWorkDescriptor.self, from: data)
            let request: WorkServiceDescribeRequest = try decodeRequestValue(
                WorkServiceDescribeRequest.self, from: request.payload)
            guard response.work == request.work, response.journal == request.journal else {
                throw WorkServiceTransportError.invalidResponse
            }
            if let expectedHostInstance {
                try validateDescriptorHost(response, expected: expectedHostInstance)
            }
        case .createWork:
            let response: WorkServiceCreateWorkResponse = try decodeResponseValue(
                WorkServiceCreateWorkResponse.self, from: data)
            let request: WorkServiceCreateWorkRequest = try decodeRequestValue(
                WorkServiceCreateWorkRequest.self, from: request.payload)
            let attachmentRows = response.work.attachments.filter {
                $0.attachment == response.attachment.attachment
            }
            guard response.receipt.operation == .createWork,
                  response.receipt.state == .accepted || response.receipt.state == .duplicate,
                  response.receipt.outcome == .created,
                  response.receipt.rejection == nil,
                  response.receipt.work == response.work.work,
                  response.receipt.commandID == request.commandID,
                  response.receipt.causalControlCursor == request.causalControlCursor,
                  response.controlCursor == response.receipt.resultingControlCursor,
                  response.authorization == response.receipt.authorization,
                  response.session == response.attachment.session,
                  response.sessionJournal == response.attachment.sessionJournal,
                  response.sessionAttachment == response.attachment.sessionAttachment,
                  response.attachment.client == request.client,
                  response.work.journal.owner == .work(response.work.work),
                  response.workCursor.journal == response.work.journal,
                  response.sessionCursor.journal == response.sessionJournal,
                  attachmentRows.count <= 1,
                  (attachmentRows.first == response.attachment
                      || (response.receipt.state == .duplicate
                          && attachmentRows.isEmpty
                          && response.attachment.authorization == response.authorization)) else {
                throw WorkServiceTransportError.invalidResponse
            }
            if response.receipt.state == .accepted {
                guard response.attachment.authorization == response.authorization else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            try validateRequestedAuthorization(
                response.authorization, requested: request.requestedCapabilities)
            try validateControlResultCursor(
                response.receipt.resultingControlCursor,
                causal: request.causalControlCursor, state: response.receipt.state,
                acceptedAdvance: 3,
                expectedHostInstance: expectedHostInstance)
            if let expectedHostInstance {
                try validateDescriptorHost(response.work, expected: expectedHostInstance)
                try validateHost(response.receipt.host, expected: expectedHostInstance)
                guard response.sessionJournal.authority.authorityID
                        == expectedHostInstance.host.workHostID,
                      response.sessionJournal.owner == .session(response.session) else {
                    throw WorkServiceTransportError.invalidResponse
                }
                guard response.attachment.client == request.client else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        case .createSession:
            let response: WorkServiceCreateSessionResponse = try decodeResponseValue(
                WorkServiceCreateSessionResponse.self, from: data)
            let request: WorkServiceCreateSessionRequest = try decodeRequestValue(
                WorkServiceCreateSessionRequest.self, from: request.payload)
            guard response.work.work == request.work,
                  response.work.journal == request.journal,
                  response.workCursor.journal == request.journal,
                  response.commandID == request.commandID,
                  response.host == response.receipt.host,
                  response.causalControlCursor == request.causalControlCursor,
                  response.causalWorkCursor == request.causalWorkCursor,
                  response.controlCursor == response.receipt.resultingControlCursor,
                  response.authorization == response.receipt.authorization,
                  response.state == response.receipt.state,
                  response.rejection == response.receipt.rejection,
                  response.receipt.operation == .createSession,
                  response.receipt.work == request.work,
                  response.receipt.commandID == request.commandID,
                  response.receipt.causalControlCursor == request.causalControlCursor else {
                throw WorkServiceTransportError.invalidResponse
            }
            try validateControlResultCursor(
                response.controlCursor, causal: request.causalControlCursor,
                state: response.state, acceptedAdvance: 2,
                expectedHostInstance: expectedHostInstance)
            try validateRequestedAuthorization(
                response.authorization, requested: request.requestedCapabilities)
            switch response.state {
            case .accepted, .duplicate:
                guard let session = response.session,
                      let sessionJournal = response.sessionJournal,
                      let sessionAttachment = response.sessionAttachment,
                      let attachment = response.attachment,
                      let relationship = response.relationship,
                      let sessionCursor = response.sessionCursor,
                      response.rejection == nil,
                      response.receipt.outcome == .sessionCreated,
                      sessionJournal.owner == .session(session),
                      sessionCursor.journal == sessionJournal,
                      relationship.session == session,
                      relationship.sessionJournal == sessionJournal,
                      relationship.sessionAttachment == sessionAttachment,
                      relationship.isAttached,
                      relationship.capabilities == response.authorization.granted,
                      relationship.causalSessionCursor.sequence == 0,
                      relationship.causalSessionCursor.eventID == nil,
                      relationship.sessionCursor.sequence == 3,
                      relationship.sessionCursor.eventID != nil,
                      relationship.sessionCursor == sessionCursor,
                      relationship.causalWorkCursor == request.causalWorkCursor,
                      relationship.resultingWorkCursor == response.workCursor,
                      response.work.sessionAttachments.contains(relationship),
                      attachment.client == request.client,
                      attachment.session == session,
                      attachment.sessionJournal == sessionJournal,
                      attachment.sessionAttachment == sessionAttachment,
                      attachment.attachment != request.attachment else {
                    throw WorkServiceTransportError.invalidResponse
                }
                let attachmentRows = response.work.attachments.filter {
                    $0.attachment == attachment.attachment
                }
                guard attachmentRows.count <= 1,
                      (attachmentRows.first == attachment
                          || (response.state == .duplicate
                              && attachmentRows.isEmpty
                              && attachment.authorization == response.authorization)) else {
                    throw WorkServiceTransportError.invalidResponse
                }
                if response.state == .accepted {
                    guard attachment.authorization == response.authorization else {
                        throw WorkServiceTransportError.invalidResponse
                    }
                }
                if let observation = response.work.hostObservation {
                    guard let served = observation.servedCursor,
                          served.journal == response.workCursor.journal else {
                        throw WorkServiceTransportError.invalidResponse
                    }
                    if response.state == .accepted {
                        guard served == response.workCursor else {
                            throw WorkServiceTransportError.invalidResponse
                        }
                    } else {
                        // A duplicate replays immutable creation cursors while the descriptor's
                        // observation may have advanced (or terminalized) since publication.
                        // Require the observation to cover the replayed cursor without coupling
                        // the response to the Work's current disposition.
                        guard served.sequence >= response.workCursor.sequence,
                              served.sequence > response.workCursor.sequence
                                  || served.eventID == response.workCursor.eventID else {
                            throw WorkServiceTransportError.invalidResponse
                        }
                    }
                }
                switch relationship.publication {
                case .mirrored:
                    guard relationship.resultingWorkCursor.sequence
                        > relationship.causalWorkCursor.sequence else {
                        throw WorkServiceTransportError.invalidResponse
                    }
                case .terminalReference:
                    guard relationship.resultingWorkCursor == relationship.causalWorkCursor else {
                        throw WorkServiceTransportError.invalidResponse
                    }
                }
                if response.state == .accepted {
                    // A fresh publication must agree with the Work state it just observed. Only
                    // exact duplicates are allowed to replay immutable relationship evidence after
                    // the Work has advanced or terminalized.
                    switch response.work.recordedDisposition {
                    case .reusable:
                        guard relationship.publication == .mirrored else {
                            throw WorkServiceTransportError.invalidResponse
                        }
                    case .completed, .destroyed:
                        guard relationship.publication == .terminalReference,
                              response.workCursor == request.causalWorkCursor,
                              response.authorization.granted == [.observe] else {
                            throw WorkServiceTransportError.invalidResponse
                        }
                    }
                }
            case .rejected:
                guard response.session == nil, response.sessionJournal == nil,
                      response.sessionAttachment == nil, response.attachment == nil,
                      response.relationship == nil, response.sessionCursor == nil,
                      response.rejection != nil, response.receipt.outcome == nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            if let expectedHostInstance {
                try validateDescriptorHost(response.work, expected: expectedHostInstance)
                try validateHost(response.host, expected: expectedHostInstance)
                try validateHost(response.receipt.host, expected: expectedHostInstance)
                if let sessionJournal = response.sessionJournal,
                   sessionJournal.authority.authorityID != expectedHostInstance.host.workHostID {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        case .completeWork:
            let response: WorkServiceCommandReceipt = try decodeResponseValue(
                WorkServiceCommandReceipt.self, from: data)
            let request: WorkServiceCompleteWorkRequest = try decodeRequestValue(
                WorkServiceCompleteWorkRequest.self, from: request.payload)
            guard let client = request.command.client else {
                throw WorkServiceTransportError.invalidResponse
            }
            let command = WorkServiceCommandRequest(
                work: request.work, journal: request.journal, attachment: request.attachment,
                commandID: request.command.commandID, client: client,
                sessionAttachment: request.command.sessionAttachment,
                causalWorkCursor: request.causalWorkCursor, kind: .complete)
            try validateCommandReceipt(response, request: command,
                                       expectedHostInstance: expectedHostInstance)
            if let expectedHostInstance {
                try validateHost(response.host, expected: expectedHostInstance)
            }
        case .attach:
            let response: WorkServiceAttachResponse = try decodeResponseValue(
                WorkServiceAttachResponse.self, from: data)
            let request: WorkServiceAttachRequest = try decodeRequestValue(
                WorkServiceAttachRequest.self, from: request.payload)
            guard response.work.work == request.work,
                  response.work.journal == request.journal,
                  response.commandID == request.commandID,
                  response.causalControlCursor == request.causalControlCursor,
                  response.receipt.operation == .attach,
                  response.state == response.receipt.state,
                  response.host == response.receipt.host,
                  response.authorization == response.receipt.authorization,
                  response.rejection == response.receipt.rejection,
                  response.receipt.work == request.work,
                  response.receipt.commandID == request.commandID,
                  response.receipt.causalControlCursor == request.causalControlCursor,
                  response.receipt.resultingControlCursor == response.resultingControlCursor else {
                throw WorkServiceTransportError.invalidResponse
            }
            switch response.state {
            case .accepted, .duplicate:
                let requestSessionTupleIsOmitted = request.session == nil
                    && request.sessionJournal == nil
                    && request.sessionAttachment == nil
                let returnedSessionTupleIsComplete = response.attachment.map {
                    ($0.session == nil && $0.sessionJournal == nil
                        && $0.sessionAttachment == nil)
                        || ($0.session != nil && $0.sessionJournal != nil
                            && $0.sessionAttachment != nil)
                } ?? false
                let sessionTupleMatches = requestSessionTupleIsOmitted
                    || (response.attachment?.session == request.session
                        && response.attachment?.sessionJournal == request.sessionJournal
                        && response.attachment?.sessionAttachment == request.sessionAttachment)
                guard let attachment = response.attachment,
                      response.receipt.outcome == .attached,
                      response.receipt.rejection == nil,
                      response.rejection == nil,
                      attachment.client == request.client,
                      returnedSessionTupleIsComplete,
                      sessionTupleMatches,
                      attachment.authorization == response.authorization,
                      response.work.attachments.contains(attachment)
                        || response.state == .duplicate else {
                    throw WorkServiceTransportError.invalidResponse
                }
                try validateRequestedAuthorization(
                    response.authorization, requested: request.requestedCapabilities)
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
            case .rejected:
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
                guard response.attachment == nil,
                      response.receipt.outcome == nil,
                      response.rejection != nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            if let expectedHostInstance {
                try validateDescriptorHost(response.work, expected: expectedHostInstance)
                try validateHost(response.host, expected: expectedHostInstance)
                try validateHost(response.receipt.host, expected: expectedHostInstance)
            }
        case .detach:
            let response: WorkServiceDetachResponse = try decodeResponseValue(
                WorkServiceDetachResponse.self, from: data)
            let request: WorkServiceDetachRequest = try decodeRequestValue(
                WorkServiceDetachRequest.self, from: request.payload)
            guard response.work == request.work,
                  response.commandID == request.commandID,
                  response.causalControlCursor == request.causalControlCursor,
                  response.receipt.operation == .detach,
                  response.state == response.receipt.state,
                  response.host == response.receipt.host,
                  response.rejection == response.receipt.rejection,
                  response.receipt.work == request.work,
                  response.receipt.commandID == request.commandID,
                  response.receipt.causalControlCursor == request.causalControlCursor,
                  response.receipt.resultingControlCursor == response.resultingControlCursor else {
                throw WorkServiceTransportError.invalidResponse
            }
            switch response.state {
            case .accepted, .duplicate:
                guard response.receipt.outcome == .detached,
                      response.rejection == nil,
                      response.receipt.rejection == nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
            case .rejected:
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
                guard response.receipt.outcome == nil,
                      response.rejection != nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            if let expectedHostInstance {
                try validateHost(response.host, expected: expectedHostInstance)
                try validateHost(response.receipt.host, expected: expectedHostInstance)
            }
        case .updateCapabilities:
            let response: WorkServiceUpdateCapabilitiesResponse = try decodeResponseValue(
                WorkServiceUpdateCapabilitiesResponse.self, from: data)
            let request: WorkServiceUpdateCapabilitiesRequest = try decodeRequestValue(
                WorkServiceUpdateCapabilitiesRequest.self, from: request.payload)
            guard response.work == request.work,
                  response.commandID == request.commandID,
                  response.causalControlCursor == request.causalControlCursor,
                  response.receipt.operation == .updateCapabilities,
                  response.state == response.receipt.state,
                  response.host == response.receipt.host,
                  response.authorization == response.receipt.authorization,
                  response.rejection == response.receipt.rejection,
                  response.receipt.work == request.work,
                  response.receipt.commandID == request.commandID,
                  response.receipt.causalControlCursor == request.causalControlCursor,
                  response.receipt.resultingControlCursor == response.resultingControlCursor else {
                throw WorkServiceTransportError.invalidResponse
            }
            switch response.state {
            case .accepted, .duplicate:
                guard response.receipt.outcome == .capabilitiesUpdated,
                      response.rejection == nil,
                      response.receipt.rejection == nil,
                      response.attachment?.client == request.client,
                      response.attachment?.authorization == response.authorization else {
                    throw WorkServiceTransportError.invalidResponse
                }
                try validateRequestedAuthorization(
                    response.authorization, requested: request.requestedCapabilities)
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
            case .rejected:
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
                guard response.attachment == nil,
                      response.receipt.outcome == nil,
                      response.rejection != nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            if let expectedHostInstance {
                try validateHost(response.host, expected: expectedHostInstance)
                try validateHost(response.receipt.host, expected: expectedHostInstance)
            }
            if let attachment = response.attachment {
                guard attachment.client == request.client else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        case .acknowledgeRead:
            let response: WorkServiceAcknowledgeReadResponse = try decodeResponseValue(
                WorkServiceAcknowledgeReadResponse.self, from: data)
            let request: WorkServiceAcknowledgeReadRequest = try decodeRequestValue(
                WorkServiceAcknowledgeReadRequest.self, from: request.payload)
            guard response.work == request.work,
                  response.target == request.target,
                  response.cursor == request.cursor,
                  response.commandID == request.commandID,
                  response.causalControlCursor == request.causalControlCursor,
                  response.receipt.operation == .acknowledgeRead,
                  response.state == response.receipt.state,
                  response.host == response.receipt.host,
                  response.rejection == response.receipt.rejection,
                  response.receipt.work == request.work,
                  response.receipt.commandID == request.commandID,
                  response.receipt.causalControlCursor == request.causalControlCursor,
                  response.receipt.resultingControlCursor == response.resultingControlCursor else {
                throw WorkServiceTransportError.invalidResponse
            }
            switch response.state {
            case .accepted, .duplicate:
                guard response.receipt.outcome == .readAcknowledged,
                      response.rejection == nil,
                      response.receipt.rejection == nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
            case .rejected:
                try validateControlResultCursor(
                    response.resultingControlCursor,
                    causal: request.causalControlCursor, state: response.state,
                    acceptedAdvance: 1,
                    expectedHostInstance: expectedHostInstance)
                guard response.receipt.outcome == nil,
                      response.rejection != nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            if let expectedHostInstance {
                try validateHost(response.host, expected: expectedHostInstance)
                try validateHost(response.receipt.host, expected: expectedHostInstance)
                guard response.target.journal.authority.authorityID
                        == expectedHostInstance.host.workHostID else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        case .snapshot:
            let response: WorkServiceSnapshot = try decodeResponseValue(
                WorkServiceSnapshot.self, from: data)
            let request: WorkServiceSnapshotRequest = try decodeRequestValue(
                WorkServiceSnapshotRequest.self, from: request.payload)
            guard response.work.work == request.work,
                  response.work.journal == request.journal else {
                throw WorkServiceTransportError.invalidResponse
            }
            guard response.target == request.target else {
                throw WorkServiceTransportError.invalidResponse
            }
            if let expectedHostInstance {
                try validateDescriptorHost(response.work, expected: expectedHostInstance)
            }
            try validateEventPage(
                response.events, journal: request.target.journal,
                after: request.afterCursor,
                served: response.servedCursor, next: nil,
                omissions: response.omissions, maxEvents: request.limit,
                maxBytes: request.maxBytes, nextRequiredForOmission: false)
            try validateEventOwnership(
                response.events, target: request.target, requestedWork: request.work,
                expectedHostInstance: expectedHostInstance)
        case .eventsAfterCursor:
            let response: WorkServiceEventPage = try decodeResponseValue(
                WorkServiceEventPage.self, from: data)
            let request: WorkServiceEventsRequest = try decodeRequestValue(
                WorkServiceEventsRequest.self, from: request.payload)
            guard response.target == request.target else {
                throw WorkServiceTransportError.invalidResponse
            }
            try validateEventPage(
                response.events, journal: request.target.journal,
                after: request.afterCursor,
                served: response.servedCursor, next: response.nextCursor,
                omissions: response.omissions, maxEvents: request.limit,
                maxBytes: request.maxBytes, nextRequiredForOmission: true)
            try validateEventOwnership(
                response.events, target: request.target, requestedWork: request.work,
                expectedHostInstance: expectedHostInstance)
        case .fetchArtifact:
            let response: WorkServiceArtifactDescriptor = try decodeResponseValue(
                WorkServiceArtifactDescriptor.self, from: data)
            let request: WorkServiceArtifactRequest = try decodeRequestValue(
                WorkServiceArtifactRequest.self, from: request.payload)
            guard response.artifactID == request.artifactID, response.work == request.work else {
                throw WorkServiceTransportError.invalidResponse
            }
            if let expectedHostInstance {
                guard response.work.workHostID == expectedHostInstance.host.workHostID else {
                    throw WorkServiceTransportError.invalidResponse
                }
                if let reference = response.bodyReference {
                    guard reference.authority.authority.authorityID == expectedHostInstance.host.workHostID else {
                        throw WorkServiceTransportError.invalidResponse
                    }
                }
            }
        case .fetchBody:
            let response: WorkServiceBodyResponse = try decodeResponseValue(
                WorkServiceBodyResponse.self, from: data)
            let request: WorkServiceBodyRequest = try decodeRequestValue(
                WorkServiceBodyRequest.self, from: request.payload)
            guard response.reference == request.reference,
                  response.offset == request.offset else {
                throw WorkServiceTransportError.invalidResponse
            }
            if let expectedHostInstance {
                guard response.reference.authority.authority.authorityID == expectedHostInstance.host.workHostID else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            try validateBodyProgress(response, request: request)
        case .command:
            let response: WorkServiceCommandReceipt = try decodeResponseValue(
                WorkServiceCommandReceipt.self, from: data)
            let request: WorkServiceCommandRequest = try decodeRequestValue(
                WorkServiceCommandRequest.self, from: request.payload)
            try validateCommandReceipt(response, request: request,
                                       expectedHostInstance: expectedHostInstance)
            if let expectedHostInstance {
                try validateHost(response.host, expected: expectedHostInstance)
            }
        }
    }

    private static func validateRequestedAuthorization(
        _ authorization: WorkServiceAuthorizationOutcome,
        requested: Set<WorkServiceCapability>
    ) throws {
        guard authorization.requested == requested,
              authorization.granted.union(authorization.denied) == requested,
              authorization.granted.isDisjoint(with: authorization.denied) else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateControlResultCursor(
        _ resulting: JournalCursor,
        causal: JournalCursor,
        state: WorkServiceCommandReceiptState,
        acceptedAdvance: Int,
        expectedHostInstance: WorkHostInstanceRef?
    ) throws {
        guard resulting.journal == causal.journal,
              case .workHost(let controlHost) = resulting.journal.owner,
              resulting.journal.authority.authorityID == controlHost.workHostID,
              resulting.sequence >= 0,
              (resulting.sequence == 0 ? resulting.eventID == nil : resulting.eventID != nil) else {
            throw WorkServiceTransportError.invalidResponse
        }
        if let expectedHostInstance {
            guard controlHost == expectedHostInstance.host,
                  resulting.journal.authority.authorityID == expectedHostInstance.host.workHostID else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        switch state {
        case .accepted, .duplicate:
            let (expectedSequence, overflow) = causal.sequence.addingReportingOverflow(
                acceptedAdvance)
            guard !overflow, resulting.sequence == expectedSequence,
                  resulting.eventID != nil else {
                throw WorkServiceTransportError.invalidResponse
            }
        case .rejected:
            guard resulting.sequence >= causal.sequence else {
                throw WorkServiceTransportError.invalidResponse
            }
            if resulting.sequence == causal.sequence {
                guard resulting.eventID == causal.eventID else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        }
    }

    private static func validateCommandReceipt(
        _ receipt: WorkServiceCommandReceipt,
        request: WorkServiceCommandRequest,
        expectedHostInstance: WorkHostInstanceRef?
    ) throws {
        guard receipt.work == request.work,
              receipt.commandID == request.command.commandID,
              receipt.causalWorkCursor == request.causalWorkCursor else {
            throw WorkServiceTransportError.invalidResponse
        }
        switch receipt.state {
        case .accepted, .duplicate:
            guard let outcome = receipt.outcome,
                  receipt.rejection == nil,
                  receipt.hostSequence != nil,
                  let resulting = receipt.resultingWorkCursor,
                  resulting.journal == request.journal,
                  resulting.sequence > request.causalWorkCursor.sequence,
                  resulting.eventID != nil else {
                throw WorkServiceTransportError.invalidResponse
            }
            let expectedOutcome: WorkServiceCommandOutcome
            switch request.kind {
            case .start: expectedOutcome = outcome == .startRecoveryRequired
                    ? .startRecoveryRequired : .started
            case .send: expectedOutcome = .inputAccepted
            case .steer: expectedOutcome = .steeringAccepted
            case .queue: expectedOutcome = .queued
            case .hold: expectedOutcome = .holdRequested
            case .cancel: expectedOutcome = .cancellationRequested
            case .end: expectedOutcome = .endRequested
            case .destroy: expectedOutcome = .destroyed
            case .complete: expectedOutcome = .completed
            }
            guard outcome == expectedOutcome else {
                throw WorkServiceTransportError.invalidResponse
            }
            if request.kind == .complete || request.kind == .destroy {
                guard let proof = receipt.terminalProof else {
                    throw WorkServiceTransportError.invalidResponse
                }
                try validateTerminalProof(
                    proof, request: request, receipt: receipt,
                    expectedHostInstance: expectedHostInstance)
            } else {
                guard receipt.terminalProof == nil else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        case .rejected:
            guard receipt.outcome == nil,
                  receipt.rejection != nil,
                  receipt.terminalProof == nil,
                  receipt.hostSequence == nil else {
                throw WorkServiceTransportError.invalidResponse
            }
            try validateCursorJournal(receipt.resultingWorkCursor, journal: request.journal)
        }
    }

    private static func validateTerminalProof(
        _ proof: WorkServiceTerminalCommitProof,
        request: WorkServiceCommandRequest,
        receipt: WorkServiceCommandReceipt,
        expectedHostInstance: WorkHostInstanceRef?
    ) throws {
        let expectedCausalEvent = request.causalWorkCursor.eventID.map {
            EventRef(journal: request.journal, eventID: $0)
        }
        guard let client = request.command.client,
              let resulting = receipt.resultingWorkCursor,
              proof.operation == (request.kind == .complete ? .complete : .destroy),
              proof.work == request.work,
              proof.journal == request.journal,
              proof.command.commandID == WorkServiceCommandLedgerIdentity.commandID(
                  client: client, commandID: request.command.commandID),
              proof.command.client == client,
              proof.command.sessionAttachment == request.command.sessionAttachment,
              proof.command.causalCursor == request.causalWorkCursor,
              proof.causalWorkCursor == request.causalWorkCursor,
              proof.resultingWorkCursor == resulting,
              proof.terminalEvent.journal == request.journal,
              proof.terminalEvent.sequence == resulting.sequence,
              proof.terminalEvent.eventID == resulting.eventID,
              proof.terminalEvent.previousEventID == request.causalWorkCursor.eventID,
              proof.terminalEvent.causedByEventID == expectedCausalEvent,
              proof.terminalEvent.work == request.work,
              proof.terminalEvent.workHost == WorkHostRef(request.work.workHostID),
              proof.terminalEvent.command == proof.command,
              proof.terminalEvent.client == client,
              proof.terminalEvent.session == proof.session,
              proof.terminalEvent.sessionAttachment == proof.sessionAttachment,
              proof.terminalEvent.type == (request.kind == .complete
                  ? TimelineEventType.workCompleted : TimelineEventType.workDestroyed),
              proof.terminalEvent.idempotencyKey == terminalIdempotencyKey(
                  type: proof.terminalEvent.type, command: proof.command,
                  causalCursor: request.causalWorkCursor, detail: request.value),
              proof.commitID == proof.terminalEvent.eventID,
              proof.sessionJournal.owner == .session(proof.session),
              proof.sessionJournal.authority.authorityID == request.work.workHostID,
              request.command.sessionAttachment == Optional(proof.sessionAttachment),
              proof.sessionPairingVerified,
              let paired = proof.pairedSessionCursor,
              paired.journal == proof.sessionJournal,
              proof.outstandingHandleIDs.isEmpty else {
            throw WorkServiceTransportError.invalidResponse
        }
        if let expectedHostInstance {
            guard proof.terminalEvent.workHost == expectedHostInstance.host,
                  proof.sessionJournal.authority.authorityID == expectedHostInstance.host.workHostID else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
    }

    private static func terminalIdempotencyKey(
        type: String, command: CommandRef, causalCursor: JournalCursor, detail: String?
    ) -> String {
        func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let client = command.client?.clientID ?? ""
        let attachment = command.sessionAttachment?.attachmentID ?? ""
        let detailComponent = detail.map { "some:\(component($0))" } ?? "none"
        return "work-terminal:v1/type:\(component(type))"
            + "/command:\(component(command.commandID))"
            + "/client:\(component(client))"
            + "/attachment:\(component(attachment))"
            + "/journal:\(component(causalCursor.journal.stableKey))"
            + "/sequence:\(causalCursor.sequence)"
            + "/event:\(component(causalCursor.eventID ?? ""))"
            + "/detail:\(detailComponent)"
    }

    private static func validateHost(
        _ actual: WorkHostInstanceRef?, expected: WorkHostInstanceRef
    ) throws {
        guard actual == expected else { throw WorkServiceTransportError.invalidResponse }
    }

    private static func validateHostInstanceValue(_ value: WorkHostInstanceRef) throws {
        func validHostIdentity(_ identity: String) -> Bool {
            !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && identity.utf8.count <= WorkServiceBounds.maxIdentityCharacters
                && !identity.contains(where: { $0 == "\n" || $0 == "\r" })
        }
        guard validHostIdentity(value.host.workHostID),
              validHostIdentity(value.instanceID),
              validHostIdentity(value.startIdentity) else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    /// Validate the path-free workspace projection before Codable decoding can discard unknown
    /// fields. A future/host-private `path`, `url`, or `canonicalPath` field must never silently
    /// cross the normal WorkService wire just because the current client ignores it.
    private static func validateWorkspaceCatalog(_ value: JSONValue) throws {
        guard case .object(let catalog) = value,
              let entries = catalog["entries"],
              let revision = catalog["revision"],
              let complete = catalog["isComplete"],
              catalog.keys.allSatisfy({ ["entries", "revision", "isComplete"].contains($0) }),
              entries.arrayValue != nil,
              revision.intValue != nil,
              complete.boolValue != nil,
              entries.arrayValue!.count <= WorkHostWorkspaceRegistry.maximumEntries else {
            throw WorkServiceTransportError.invalidResponse
        }
        for entry in entries.arrayValue! {
            guard case .object(let fields) = entry,
                  fields.keys.allSatisfy({
                      ["workspaceID", "label", "isDefault", "availability", "capabilities"]
                          .contains($0)
                  }) else {
                throw WorkServiceTransportError.invalidResponse
            }
            // Codable validates the typed ID, label, availability, and capability set below;
            // this decode is deliberately after the unknown-key/path check above.
            do {
                _ = try decodeResponseValue(
                    WorkHostWorkspaceDescriptor.self, from: entry)
            } catch {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        do {
            _ = try decodeResponseValue(WorkHostWorkspaceCatalog.self, from: value)
        } catch {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateTerminalProof(
        _ proof: WorkServiceTerminalCommitProof?, expected: WorkHostInstanceRef
    ) throws {
        guard let proof else { return }
        guard proof.work.workHostID == expected.host.workHostID,
              proof.journal.authority.authorityID == expected.host.workHostID,
              proof.terminalEvent.workHost == expected.host else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateDescriptorHost(
        _ descriptor: WorkServiceWorkDescriptor, expected: WorkHostInstanceRef
    ) throws {
        guard descriptor.work.workHostID == expected.host.workHostID,
              descriptor.journal.authority.authorityID == expected.host.workHostID,
              descriptor.journal.owner == .work(descriptor.work) else {
            throw WorkServiceTransportError.invalidResponse
        }
        // The response envelope already proves which service instance answered this request.
        // A descriptor-level observation is deliberately optional: a newly created idle Work,
        // historical Work, or recovery projection may have no live actor observation. When an
        // observation is present it is still fenced to the negotiated instance.
        if let observation = descriptor.hostObservation,
           observation.instance != expected {
            throw WorkServiceTransportError.invalidResponse
        }
        for attachment in descriptor.attachments {
            if let journal = attachment.sessionJournal {
                guard journal.authority.authorityID == expected.host.workHostID else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        }
    }

    private static func validateEventPage(
        _ events: [TimelineEvent], journal: JournalRef,
        after: JournalCursor?, served: JournalCursor?, next: JournalCursor?,
        omissions: [WorkServiceOmission], maxEvents: Int, maxBytes: Int,
        nextRequiredForOmission: Bool
    ) throws {
        guard maxEvents > 0, maxEvents <= WorkServiceBounds.maxEventsPerPage,
              maxBytes > 0 else { throw WorkServiceTransportError.invalidResponse }
        let baseline = after ?? JournalCursor(journal: journal, sequence: 0)
        guard baseline.journal == journal, baseline.sequence >= 0,
              baseline.sequence < Int.max,
              (baseline.sequence == 0 ? baseline.eventID == nil : baseline.eventID != nil) else {
            throw WorkServiceTransportError.invalidResponse
        }
        guard events.count <= maxEvents else { throw WorkServiceTransportError.invalidResponse }
        let expectedPrevious = baseline.eventID
        var expectedSequence = baseline.sequence + 1
        var priorID = expectedPrevious
        var seen: Set<String> = []
        for event in events {
            guard event.journal == journal,
                  event.sequence == expectedSequence,
                  event.previousEventID == priorID,
                  seen.insert(event.eventID).inserted else {
                throw WorkServiceTransportError.invalidResponse
            }
            priorID = event.eventID
            guard expectedSequence < Int.max else {
                throw WorkServiceTransportError.invalidResponse
            }
            expectedSequence += 1
        }
        let pageCursor = events.last.map {
            JournalCursor(journal: journal, eventID: $0.eventID, sequence: $0.sequence)
        } ?? baseline
        guard served == pageCursor else { throw WorkServiceTransportError.invalidResponse }
        let hasOmissions = !omissions.isEmpty
        if let next {
            guard hasOmissions, next == pageCursor, !events.isEmpty else {
                throw WorkServiceTransportError.invalidResponse
            }
        } else {
            guard !nextRequiredForOmission || !hasOmissions else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        try validateEventPageBytes(events, maxBytes: maxBytes)
    }

    private static func validateEventOwnership(
        _ events: [TimelineEvent], target: WorkServiceReadTarget,
        requestedWork: WorkRef, expectedHostInstance: WorkHostInstanceRef?
    ) throws {
        switch target {
        case .work(let journal):
            guard journal.owner == .work(requestedWork),
                  journal.authority.authorityID == requestedWork.workHostID else {
                throw WorkServiceTransportError.invalidResponse
            }
            for event in events {
                guard event.work == requestedWork,
                      event.workHost == WorkHostRef(requestedWork.workHostID) else {
                    throw WorkServiceTransportError.invalidResponse
                }
                if let expectedHostInstance, event.workHost != expectedHostInstance.host {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        case .session(let session, let journal):
            // Session journals are conversation authority and may contain messages associated
            // with Works on other hosts. Only the Session identity/owner is authoritative here;
            // do not incorrectly require a Work Host field on Session genesis.
            guard journal.owner == .session(session) else {
                throw WorkServiceTransportError.invalidResponse
            }
            if let expectedHostInstance {
                guard journal.authority.authorityID == expectedHostInstance.host.workHostID else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            for event in events {
                guard event.session == session else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        }
    }

    private static func validateBodyProgress(
        _ response: WorkServiceBodyResponse, request: WorkServiceBodyRequest
    ) throws {
        guard request.limit > 0, request.offset >= 0 else {
            throw WorkServiceTransportError.invalidResponse
        }
        guard response.status == .retained else {
            guard response.data == nil, response.nextOffset == nil else {
                throw WorkServiceTransportError.invalidResponse
            }
            return
        }
        guard let declared = response.reference.byteCount, declared >= 0,
              let body = response.data,
              body.count <= min(request.limit, WorkServiceBounds.maxBodyChunkBytes),
              response.offset <= Int.max - body.count else {
            throw WorkServiceTransportError.invalidResponse
        }
        let end = response.offset + body.count
        guard end <= declared else { throw WorkServiceTransportError.invalidResponse }
        if let next = response.nextOffset {
            guard next == end, next > response.offset,
                  end < declared else {
                throw WorkServiceTransportError.invalidResponse
            }
        } else {
            // A nil next offset is an EOF claim. It is only truthful when the reference declares
            // that this exact chunk reaches the end; an unknown-length body must keep progressing.
            guard end == declared else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        if declared > response.offset, body.isEmpty {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func decodeResponseValue<T: Decodable>(
        _ type: T.Type, from value: JSONValue
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func decodeResponseValueIfPresent<T: Decodable>(
        _ type: T.Type, from value: JSONValue?
    ) throws -> T? {
        guard let value, !value.isNull else { return nil }
        return try decodeResponseValue(type, from: value)
    }

    private static func decodeRequestValue<T: Decodable>(
        _ type: T.Type, from value: JSONValue?
    ) throws -> T {
        guard let value else { throw WorkServiceTransportError.invalidResponse }
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateEventJournal(
        _ events: [TimelineEvent], journal: JournalRef
    ) throws {
        guard events.allSatisfy({ $0.journal == journal }) else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateEventPageBytes(
        _ events: [TimelineEvent], maxBytes: Int
    ) throws {
        guard maxBytes > 0 else { throw WorkServiceTransportError.invalidResponse }
        let byteLimit = min(maxBytes, WorkServiceBounds.maxEventPageBytes)
        let total: Int
        do {
            total = try WorkServiceEventPageSizing.encodedByteCount(of: events)
        } catch {
            throw WorkServiceTransportError.invalidResponse
        }
        guard total <= byteLimit else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateCursorJournal(
        _ cursor: JournalCursor?, journal: JournalRef
    ) throws {
        guard cursor == nil || cursor?.journal == journal else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateArray(_ value: JSONValue?, maxCount: Int) throws {
        guard let value else { return }
        guard case .array(let values) = value, values.count <= maxCount else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateIdentity(_ value: JSONValue?, required: Bool = false) throws {
        guard let value else {
            if required { throw WorkServiceTransportError.invalidResponse }
            return
        }
        guard let string = value.stringValue,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.utf8.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateDiagnostic(_ value: JSONValue?) throws {
        guard let value else { return }
        guard let string = value.stringValue,
              string.utf8.count <= WorkServiceBounds.maxDiagnosticCharacters else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validatePrefixDigest(_ value: JSONValue?) throws {
        guard let value else { return }
        guard let digest = value.stringValue,
              digest.hasPrefix("sha256:"),
              digest.dropFirst("sha256:".count).count == 64,
              digest.dropFirst("sha256:".count).allSatisfy({ $0.isHexDigit }) else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateNonnegativeInteger(_ value: JSONValue?, required: Bool = false)
        throws {
        guard let value else {
            if required { throw WorkServiceTransportError.invalidResponse }
            return
        }
        guard let integer = value.intValue, integer >= 0 else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validatePositiveBoundedInteger(
        _ value: JSONValue?, maximum: Int, required: Bool = false
    ) throws {
        guard let value else {
            if required { throw WorkServiceTransportError.invalidResponse }
            return
        }
        guard let integer = value.intValue, integer > 0, integer <= maximum else {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateReadTarget(_ value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        if let work = object["work"] {
            guard case .object(let fields) = work else {
                throw WorkServiceTransportError.invalidResponse
            }
            try validateJournalReference(fields["journal"] ?? .null)
            return
        }
        if let session = object["session"] {
            guard case .object(let fields) = session else {
                throw WorkServiceTransportError.invalidResponse
            }
            // Swift's synthesized Codable representation retains associated-value labels:
            // `{ "session": { "session": { "sessionID": ... }, "journal": ... } }`.
            // Accept the flattened spelling as well so a future hand-written codec can remain
            // wire-compatible without weakening the required Session identity check.
            try validateIdentity(
                fields["session"]?["sessionID"] ?? fields["session"]?["session_id"]
                    ?? fields["sessionID"] ?? fields["session_id"], required: true)
            try validateJournalReference(fields["journal"] ?? .null)
            return
        }
        throw WorkServiceTransportError.invalidResponse
    }

    private static func validateJournalReference(_ value: JSONValue) throws {
        guard case .object(let object) = value,
              let kind = object["kind"]?.stringValue,
              let owner = object["owner"]?.objectValue,
              owner["kind"]?.stringValue == kind else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["journal_id"], required: true)
        try validateIdentity(object["authority"]?["authorityID"], required: true)
        switch kind {
        case "work":
            try validateIdentity(owner["work_host_id"], required: true)
            try validateIdentity(owner["work_id"], required: true)
        case "session":
            try validateIdentity(owner["session_id"], required: true)
        case "work_host":
            try validateIdentity(owner["work_host_id"], required: true)
        default:
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateCursor(_ value: JSONValue?, required: Bool = false) throws {
        guard let value else {
            if required { throw WorkServiceTransportError.invalidResponse }
            return
        }
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateJournalReference(object["journal"] ?? .null)
        try validateIdentity(object["eventID"])
        try validateNonnegativeInteger(object["sequence"], required: true)
    }

    private static func validateHostInstance(_ value: JSONValue?, required: Bool = false)
        throws {
        guard let value else {
            if required { throw WorkServiceTransportError.invalidResponse }
            return
        }
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["host"]?["workHostID"], required: true)
        try validateIdentity(object["instanceID"], required: true)
        try validateIdentity(object["startIdentity"], required: true)
    }

    private static func validateBodyReference(_ value: JSONValue?, required: Bool = false)
        throws {
        guard let value else {
            if required { throw WorkServiceTransportError.invalidResponse }
            return
        }
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateJournalReference(object["authority"] ?? .null)
        try validateIdentity(object["reference_id"], required: true)
        try validateDiagnostic(object["media_type"])
        try validateNonnegativeInteger(object["byte_count"])
        try validateDiagnostic(object["digest"])
    }

    private static func validateAuthorization(_ value: JSONValue?, required: Bool = false)
        throws {
        guard let value else {
            if required { throw WorkServiceTransportError.invalidResponse }
            return
        }
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateDiagnostic(object["diagnostic"])
        for key in ["requested", "granted", "denied"] {
            try validateArray(object[key], maxCount: WorkServiceCapability.allCases.count)
            for capability in object[key]?.arrayValue ?? [] {
                try validateIdentity(capability, required: true)
            }
        }
    }

    private static func validateClientAttachment(
        _ value: JSONValue,
        workJournal: JournalRef? = nil
    ) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["attachment"]?["attachmentID"], required: true)
        try validateIdentity(object["client"]?["clientID"], required: true)
        try validateIdentity(object["session"]?["sessionID"])
        if object["sessionJournal"] != nil {
            try validateJournalReference(object["sessionJournal"] ?? .null)
        }
        try validateIdentity(object["sessionAttachment"]?["attachmentID"])
        try validateAuthorization(object["authorization"], required: true)
        try validateArray(
            object["readAcknowledgements"],
            maxCount: WorkServiceBounds.maxReadAcknowledgementsPerAttachment)
        let decodedAttachment = try decodeResponseValue(
            WorkServiceClientAttachment.self, from: value)
        var targetJournals: Set<JournalRef> = []
        for value in object["readAcknowledgements"]?.arrayValue ?? [] {
            guard case .object(let acknowledgement) = value else {
                throw WorkServiceTransportError.invalidResponse
            }
            try validateReadTarget(acknowledgement["target"] ?? .null)
            try validateCursor(acknowledgement["cursor"], required: true)
            let decoded = try decodeResponseValue(
                WorkServiceReadAcknowledgement.self, from: value)
            guard decoded.cursor.journal == decoded.target.journal,
                  targetJournals.insert(decoded.target.journal).inserted else {
                throw WorkServiceTransportError.invalidResponse
            }
            if case .work(let journal) = decoded.target,
               let workJournal,
               journal != workJournal {
                throw WorkServiceTransportError.invalidResponse
            }
            if case .session(let session, let journal) = decoded.target {
                guard session == decodedAttachment.session,
                      journal == decodedAttachment.sessionJournal else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        }
    }

    private static func validateSessionAttachmentDescriptor(_ value: JSONValue) throws {
        guard case .object(let object) = value,
              let publication = object["publication"]?.stringValue,
              WorkServiceSessionAttachmentPublication(rawValue: publication) != nil else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["session"]?["sessionID"], required: true)
        try validateJournalReference(object["sessionJournal"] ?? .null)
        try validateIdentity(object["sessionAttachment"]?["attachmentID"], required: true)
        try validateCursor(object["causalSessionCursor"], required: true)
        try validateCursor(object["sessionCursor"], required: true)
        try validateCursor(object["causalWorkCursor"], required: true)
        try validateCursor(object["resultingWorkCursor"], required: true)
        try validateArray(
            object["capabilities"], maxCount: WorkServiceCapability.allCases.count)
        for capability in object["capabilities"]?.arrayValue ?? [] {
            try validateIdentity(capability, required: true)
        }
        let descriptor = try decodeResponseValue(
            WorkServiceSessionAttachmentDescriptor.self, from: value)
        guard descriptor.sessionJournal.owner == .session(descriptor.session),
              descriptor.causalSessionCursor.journal == descriptor.sessionJournal,
              descriptor.sessionCursor.journal == descriptor.sessionJournal,
              case .work(let work) = descriptor.causalWorkCursor.journal.owner,
              descriptor.resultingWorkCursor.journal == descriptor.causalWorkCursor.journal,
              descriptor.sessionJournal.authority.authorityID == work.workHostID,
              !descriptor.capabilities.contains(.createSession) else {
            throw WorkServiceTransportError.invalidResponse
        }
        switch descriptor.publication {
        case .mirrored:
            let (expectedSequence, overflow) = descriptor.causalWorkCursor.sequence
                .addingReportingOverflow(1)
            guard !overflow,
                  descriptor.resultingWorkCursor.sequence == expectedSequence,
                  descriptor.resultingWorkCursor.eventID != nil else {
                throw WorkServiceTransportError.invalidResponse
            }
        case .terminalReference:
            guard descriptor.resultingWorkCursor == descriptor.causalWorkCursor,
                  descriptor.capabilities == [.observe] else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
    }

    private static func validateWorkDescriptor(_ value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        let work = object["work"]
        let descriptorWork = try decodeResponseValue(WorkRef.self, from: work ?? .null)
        try validateIdentity(work?["workHostID"], required: true)
        try validateIdentity(work?["workID"], required: true)
        try validateJournalReference(object["journal"] ?? .null)
        let workJournal = try decodeResponseValue(
            JournalRef.self, from: object["journal"] ?? .null)
        // Decode the configuration explicitly so a path-shaped or otherwise unknown workspace
        // field cannot be silently discarded by the descriptor's surrounding Codable object.
        _ = try decodeResponseValue(
            WorkServiceWorkConfiguration.self, from: object["configuration"] ?? .null)
        try validateArray(object["attachments"], maxCount: WorkServiceBounds.maxAttachmentsPerWork)
        try validateArray(
            object["sessionAttachments"],
            maxCount: WorkServiceBounds.maxSessionAttachmentsPerWork)
        try validateArray(object["artifacts"], maxCount: WorkServiceBounds.maxArtifactsPerWork)
        try validateArray(object["omissions"], maxCount: WorkServiceBounds.maxOmissions)
        var clientAttachments: Set<ClientAttachmentRef> = []
        for attachment in object["attachments"]?.arrayValue ?? [] {
            try validateClientAttachment(attachment, workJournal: workJournal)
            let decoded = try decodeResponseValue(
                WorkServiceClientAttachment.self, from: attachment)
            guard clientAttachments.insert(decoded.attachment).inserted else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        var sessionAttachments: Set<SessionAttachmentRef> = []
        var decodedSessionAttachmentRelationships: [WorkServiceSessionAttachmentDescriptor] = []
        for relationshipValue in object["sessionAttachments"]?.arrayValue ?? [] {
            try validateSessionAttachmentDescriptor(relationshipValue)
            let relationship = try decodeResponseValue(
                WorkServiceSessionAttachmentDescriptor.self, from: relationshipValue)
            guard relationship.causalWorkCursor.journal == workJournal,
                  sessionAttachments.insert(relationship.sessionAttachment).inserted else {
                throw WorkServiceTransportError.invalidResponse
            }
            decodedSessionAttachmentRelationships.append(relationship)
        }
        let currentRun = try decodeResponseValueIfPresent(
            RunRef.self, from: object["currentRun"])
        let currentRunSession = try decodeResponseValueIfPresent(
            SessionRef.self, from: object["currentRunSession"])
        let currentRunSessionAttachment = try decodeResponseValueIfPresent(
            SessionAttachmentRef.self, from: object["currentRunSessionAttachment"])
        guard (currentRun == nil) == (currentRunSession == nil),
              (currentRun == nil) == (currentRunSessionAttachment == nil) else {
            throw WorkServiceTransportError.invalidResponse
        }
        if currentRun != nil {
            let ownerRelationshipCount = decodedSessionAttachmentRelationships.count {
                $0.session == currentRunSession
                    && $0.sessionAttachment == currentRunSessionAttachment
                    && $0.isAttached
            }
            guard ownerRelationshipCount == 1 else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        var artifactIDs: Set<String> = []
        for artifact in object["artifacts"]?.arrayValue ?? [] {
            try validateArtifactDescriptor(artifact, expectedWork: descriptorWork)
            guard let artifactID = artifact["artifactID"]?.stringValue,
                  artifactIDs.insert(artifactID).inserted else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        for omission in object["omissions"]?.arrayValue ?? [] {
            try validateIdentity(omission["category"], required: true)
            try validateDiagnostic(omission["diagnostic"])
            try validateNonnegativeInteger(omission["count"], required: true)
            guard let count = omission["count"]?.intValue,
                  count <= WorkServiceBounds.maxOmissionCount else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        // Decode the complete DTO after the bounded wire walk. This enforces the cross-field
        // owner envelope and complete host-observation agreement at the transport boundary too,
        // so a forged response cannot rely on the later client decode to quarantine it.
        _ = try decodeResponseValue(WorkServiceWorkDescriptor.self, from: value)
    }

    private static func validateArtifactDescriptor(
        _ value: JSONValue, expectedWork: WorkRef? = nil
    ) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["artifactID"], required: true)
        try validateIdentity(object["work"]?["workHostID"], required: true)
        try validateIdentity(object["work"]?["workID"], required: true)
        let artifactWork = try decodeResponseValue(
            WorkRef.self, from: object["work"] ?? .null)
        if let expectedWork, artifactWork != expectedWork {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateDiagnostic(object["label"])
        try validateDiagnostic(object["mediaType"])
        try validateDiagnostic(object["digest"])
        try validateNonnegativeInteger(object["byteCount"])
        try validateBodyReference(object["bodyReference"])
        if let truncated = object["metadataWasTruncated"], truncated.boolValue == nil {
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private static func validateBodyResponse(_ value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        guard let status = object["status"]?.stringValue,
              WorkServiceBodyStatus(rawValue: status) != nil else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateBodyReference(object["reference"], required: true)
        try validateNonnegativeInteger(object["offset"], required: true)
        try validateNonnegativeInteger(object["nextOffset"])
        try validateDiagnostic(object["diagnostic"])
        let offset = object["offset"]?.intValue ?? 0
        let nextOffset = object["nextOffset"]?.intValue
        let declaredByteCount = object["reference"]?["byte_count"]?.intValue
        if status == WorkServiceBodyStatus.retained.rawValue {
            guard let declaredByteCount, declaredByteCount >= 0 else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        if let declaredByteCount {
            guard offset <= declaredByteCount else {
                throw WorkServiceTransportError.invalidResponse
            }
            if let nextOffset, nextOffset > declaredByteCount {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        if let body = object["data"], !body.isNull {
            guard let encoded = body.stringValue,
                  let decoded = Data(base64Encoded: encoded),
                  decoded.count <= WorkServiceBounds.maxBodyChunkBytes else {
                throw WorkServiceTransportError.invalidResponse
            }
            guard status == WorkServiceBodyStatus.retained.rawValue else {
                throw WorkServiceTransportError.invalidResponse
            }
            guard offset <= Int.max - decoded.count else {
                throw WorkServiceTransportError.invalidResponse
            }
            let expectedNext = offset + decoded.count
            if let declaredByteCount {
                guard expectedNext <= declaredByteCount else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
            if let nextOffset {
                guard nextOffset > offset, nextOffset == expectedNext else {
                    throw WorkServiceTransportError.invalidResponse
                }
            }
        } else {
            guard status == WorkServiceBodyStatus.unavailable.rawValue,
                  nextOffset == nil else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        if let nextOffset {
            guard nextOffset > offset,
                  nextOffset - offset <= WorkServiceBounds.maxBodyChunkBytes else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
    }

    private static func validateEventDescriptor(_ value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["eventID"], required: true)
        try validateDiagnostic(object["kind"])
        try validateIdentity(object["commandID"])
        try validateCursor(object["cursor"], required: true)
        if let run = object["run"] {
            try validateIdentity(run["runID"], required: true)
        }
        if let provenance = object["provenance"] {
            try validateJSONSemantics(provenance)
        }
        guard let bodyStatus = object["bodyStatus"]?.stringValue,
              WorkServiceEventDescriptor.BodyStatus(rawValue: bodyStatus) != nil else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateBodyReference(object["bodyReference"])
    }

    /// Full read pages carry the native ``TimelineEvent`` envelope. Keep the wire-side walk
    /// bounded without requiring the transport to know every future payload field.
    private static func validateTimelineEvent(_ value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["event_id"], required: true)
        try validateJournalReference(object["journal"] ?? .null)
        try validateNonnegativeInteger(object["sequence"], required: true)
        try validateNonnegativeInteger(object["host_sequence"])
        try validateIdentity(object["idempotency_key"])
        if let command = object["command"] {
            guard case .object = command else { throw WorkServiceTransportError.invalidResponse }
            try validateIdentity(command["command_id"] ?? command["commandID"], required: true)
            try validateIdentity(command["client"]?["client_id"] ?? command["client"]?["clientID"])
            try validateIdentity(command["session_attachment"]?["attachment_id"]
                                 ?? command["session_attachment"]?["attachmentID"])
            try validateCursor(command["causal_cursor"] ?? command["causalCursor"])
        }
        for key in ["session", "work", "work_host", "client", "session_attachment",
                    "client_attachment", "run", "turn", "action", "handle", "actor"] {
            if let value = object[key] {
                guard case .object = value else { throw WorkServiceTransportError.invalidResponse }
            }
        }
        try validateIdentity(object["session"]?["session_id"] ?? object["session"]?["sessionID"])
        try validateIdentity(object["work"]?["work_host_id"] ?? object["work"]?["workHostID"])
        try validateIdentity(object["work"]?["work_id"] ?? object["work"]?["workID"])
        try validateIdentity(object["work_host"]?["work_host_id"] ?? object["work_host"]?["workHostID"])
        try validateIdentity(object["client"]?["client_id"] ?? object["client"]?["clientID"])
        try validateIdentity(object["session_attachment"]?["attachment_id"]
                             ?? object["session_attachment"]?["attachmentID"])
        try validateIdentity(object["client_attachment"]?["attachment_id"]
                             ?? object["client_attachment"]?["attachmentID"])
        try validateIdentity(object["run"]?["run_id"] ?? object["run"]?["runID"])
        try validateIdentity(object["turn"]?["turn_id"] ?? object["turn"]?["turnID"])
        try validateIdentity(object["action"]?["action_id"] ?? object["action"]?["actionID"])
        try validateIdentity(object["handle"]?["handle_id"] ?? object["handle"]?["handleID"])
        try validateIdentity(object["actor"]?["actor_id"] ?? object["actor"]?["actorID"], required: true)
        try validateDiagnostic(object["actor"]?["kind"])
        try validateNonnegativeInteger(object["schema_version"], required: true)
        try validateNonnegativeInteger(object["payload_version"], required: true)
        try validateDiagnostic(object["type"])
        try validateArray(object["declared_domains"], maxCount: TimelineDomain.allCases.count)
        try validateDiagnostic(object["provenance"])
        try validateArray(object["links"], maxCount: TimelineEvent.maxEvidenceLinks)
        try validatePositiveBoundedInteger(
            object["omitted_evidence_link_count"],
            maximum: TimelineEvent.maxOmittedEvidenceLinkCount)
        try validateJSONSemantics(object["payload"] ?? .object([:]))
    }

    private static func validateControlReceipt(_ value: JSONValue) throws {
        guard case .object(let object) = value,
              let operation = object["operation"]?.stringValue,
              WorkServiceControlOperation(rawValue: operation) != nil else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["work"]?["workHostID"] ?? object["work"]?["work_host_id"], required: true)
        try validateIdentity(object["work"]?["workID"] ?? object["work"]?["work_id"], required: true)
        try validateIdentity(object["commandID"] ?? object["command_id"], required: true)
        try validateHostInstance(object["host"], required: true)
        try validateCursor(object["causalControlCursor"] ?? object["causal_control_cursor"], required: true)
        try validateCursor(object["resultingControlCursor"] ?? object["resulting_control_cursor"], required: true)
        try validateAuthorization(object["authorization"], required: true)
        try validateDiagnostic(object["diagnostic"])
        if let outcome = object["outcome"] {
            guard let raw = outcome.stringValue,
                  WorkServiceControlOutcome(rawValue: raw) != nil else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
        if let rejection = object["rejection"] {
            guard let raw = rejection.stringValue,
                  WorkServiceCommandRejection(rawValue: raw) != nil else {
                throw WorkServiceTransportError.invalidResponse
            }
        }
    }

    private static func validateReceipt(_ value: JSONValue) throws {
        guard case .object(let object) = value else {
            throw WorkServiceTransportError.invalidResponse
        }
        try validateIdentity(object["work"]?["workHostID"], required: true)
        try validateIdentity(object["work"]?["workID"], required: true)
        try validateIdentity(object["commandID"], required: true)
        try validateDiagnostic(object["diagnostic"])
        try validateHostInstance(object["host"], required: true)
        // Work host sequence is optional evidence on execution events only. It is absent on
        // rejections and on every control-journal receipt.
        try validateNonnegativeInteger(object["hostSequence"] ?? object["host_sequence"])
        try validateCursor(object["causalWorkCursor"] ?? object["causal_work_cursor"], required: true)
        try validateCursor(object["resultingWorkCursor"] ?? object["resulting_work_cursor"])
        if let proof = object["terminalProof"] {
            guard case .object = proof,
                  let operation = proof["operation"]?.stringValue,
                  WorkServiceTerminalOperation(rawValue: operation) != nil else {
                throw WorkServiceTransportError.invalidResponse
            }
            try validateIdentity(proof["work"]?["workHostID"], required: true)
            try validateIdentity(proof["work"]?["workID"], required: true)
            try validateJournalReference(proof["journal"] ?? .null)
            try validateDiagnostic(proof["diagnostic"])
            try validateIdentity(proof["command"]?["commandID"], required: true)
            try validateIdentity(proof["command"]?["client"]?["clientID"], required: true)
            try validateCursor(proof["command"]?["causalCursor"], required: true)
            try validateCursor(proof["causalWorkCursor"], required: true)
            try validateCursor(proof["resultingWorkCursor"], required: true)
            try validateTimelineEvent(proof["terminalEvent"] ?? .null)
            try validateIdentity(proof["session"]?["sessionID"], required: true)
            try validateJournalReference(proof["sessionJournal"] ?? .null)
            try validateIdentity(proof["sessionAttachment"]?["attachmentID"], required: true)
            try validateCursor(proof["pairedSessionCursor"])
            try validateArray(
                proof["outstandingHandleIDs"],
                maxCount: WorkServiceBounds.maxTerminalProofHandles)
            for handle in proof["outstandingHandleIDs"]?.arrayValue ?? [] {
                try validateIdentity(handle["handleID"], required: true)
            }
            try validateIdentity(proof["commitID"], required: true)
        }
    }

    private static func validateJSONSemantics(_ value: JSONValue) throws {
        var nodeCount = 0
        var totalStringBytes = 0
        try validateJSONSemantics(
            value, depth: 0, nodeCount: &nodeCount, totalStringBytes: &totalStringBytes)
    }

    private static func validateJSONSemantics(
        _ value: JSONValue, depth: Int, nodeCount: inout Int,
        totalStringBytes: inout Int
    ) throws {
        nodeCount += 1
        guard nodeCount <= 50_000, depth <= 32 else {
            throw WorkServiceTransportError.invalidResponse
        }
        switch value {
        case .null, .bool, .number:
            return
        case .string(let string):
            let bytes = string.utf8.count
            guard bytes <= 1_048_576,
                  totalStringBytes <= 3 * 1_048_576 - bytes else {
                throw WorkServiceTransportError.invalidResponse
            }
            totalStringBytes += bytes
        case .array(let values):
            guard values.count <= 4_096 else {
                throw WorkServiceTransportError.invalidResponse
            }
            for value in values {
                try validateJSONSemantics(
                    value, depth: depth + 1, nodeCount: &nodeCount,
                    totalStringBytes: &totalStringBytes)
            }
        case .object(let values):
            guard values.count <= 256 else {
                throw WorkServiceTransportError.invalidResponse
            }
            for (key, value) in values {
                guard key.utf8.count <= WorkServiceBounds.maxIdentityCharacters else {
                    throw WorkServiceTransportError.invalidResponse
                }
                try validateJSONSemantics(
                    value, depth: depth + 1, nodeCount: &nodeCount,
                    totalStringBytes: &totalStringBytes)
            }
        }
    }
}

// MARK: - POSIX socket implementation

private enum WorkServiceUnixSocketFailure: Error {
    case invalidPath
    case endpointOccupied
    case system(Int32)
    case closed
}

/// Normalize every transport timeout before it reaches a POSIX poll, a Dispatch deadline, or
/// `Task.sleep`.  In addition to ordinary negative/oversized values, this handles NaN and
/// infinity supplied by configuration decoding without allowing a numeric conversion to trap.
private func workServiceBoundedTimeout(
    _ value: TimeInterval, minimum: TimeInterval, maximum: TimeInterval
) -> TimeInterval {
    guard value.isFinite else {
        return value.isNaN || value < 0 ? minimum : maximum
    }
    return max(minimum, min(value, maximum))
}

private func workServiceSocketAddress(path: String) throws -> sockaddr_un {
    let bytes = Data(path.utf8)
    // Darwin's sockaddr_un has a 104-byte sun_path.  Leave the final byte for NUL.
    guard !bytes.isEmpty, bytes.count <= 103 else {
        throw WorkServiceUnixSocketFailure.invalidPath
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    var nulTerminated = bytes
    nulTerminated.append(0)
    let copied = withUnsafeMutableBytes(of: &address.sun_path) { destination in
        nulTerminated.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
        return nulTerminated.count
    }
    guard copied == nulTerminated.count else {
        throw WorkServiceUnixSocketFailure.invalidPath
    }
    return address
}

private func workServiceMakeNonBlocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw WorkServiceUnixSocketFailure.system(errno)
    }
}

private func workServiceConnect(
    descriptor: Int32, address: inout sockaddr_un, timeout: TimeInterval
) throws {
    let deadline = DispatchTime.now().uptimeNanoseconds
        + UInt64(workServiceBoundedTimeout(timeout, minimum: 0.01, maximum: 30)
            * 1_000_000_000)
    while true {
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return }
        let code = errno
        if code == EINTR { continue }
        guard code == EINPROGRESS || code == EALREADY else {
            throw WorkServiceUnixSocketFailure.system(code)
        }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw WorkServiceUnixSocketFailure.system(ETIMEDOUT)
            }
            var descriptorState = pollfd(
                fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let remaining = Int32(
                min(100, max(1, (deadline - now) / 1_000_000)))
            let ready = poll(&descriptorState, 1, remaining)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                throw WorkServiceUnixSocketFailure.system(errno)
            }
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
                throw WorkServiceUnixSocketFailure.system(errno)
            }
            guard socketError == 0 else {
                throw WorkServiceUnixSocketFailure.system(socketError)
            }
            return
        }
    }
}

private func workServiceNoSigPipe(_ descriptor: Int32) throws {
    let result = AviaryPOSIX.setNoSigPipe(descriptor)
    guard result == 0 else { throw WorkServiceUnixSocketFailure.system(errno) }
}

private struct WorkServiceSocketIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
}

private func workServiceSocketIdentity(path: String) -> WorkServiceSocketIdentity? {
    var information = stat()
    guard lstat(path, &information) == 0,
          (information.st_mode & S_IFMT) == S_IFSOCK else { return nil }
    return WorkServiceSocketIdentity(device: information.st_dev, inode: information.st_ino)
}

/// Remove only the socket inode this listener actually created.  Endpoint names are reusable;
/// blindly unlinking the current path after a stop can delete a replacement listener (or a file
/// owned by somebody else) if the path was swapped while the original descriptor was draining.
private func workServiceRemoveOwnedSocket(
    path: String, identity: WorkServiceSocketIdentity?
) {
    guard let identity,
          let current = workServiceSocketIdentity(path: path),
          current.device == identity.device, current.inode == identity.inode else { return }
    _ = unlink(path)
}

/// An accepted or connected endpoint.  Reads are surfaced as complete LF records; writes are
/// bounded, nonblocking sends so a GUI or remote peer that stops reading cannot wedge the service
/// actor indefinitely.
private final class WorkServiceUnixSocketPeer: @unchecked Sendable {
    private let handle: FileHandle
    private let maxFrameBytes: Int
    private let framer: LineFramer
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var closed = false
    private var handleClosed = false
    private var queuedWrites = 0
    private var queuedWriteBytes = 0
    private let writeQueue: DispatchQueue
    private let maxQueuedWrites: Int
    private let maxQueuedWriteBytes: Int

    init(
        fileDescriptor: Int32, maxFrameBytes: Int, maxQueuedWrites: Int,
        maxQueuedWriteBytes: Int
    ) throws {
        guard fileDescriptor >= 0 else { throw WorkServiceUnixSocketFailure.system(EBADF) }
        try workServiceNoSigPipe(fileDescriptor)
        try workServiceMakeNonBlocking(fileDescriptor)
        self.handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        let boundedFrameBytes = WorkServiceTransportCodec.clampFrameBytes(maxFrameBytes)
        self.maxFrameBytes = boundedFrameBytes
        self.framer = LineFramer(maxLineBytes: max(1, boundedFrameBytes - 1))
        self.maxQueuedWrites = max(1, maxQueuedWrites)
        self.maxQueuedWriteBytes = max(boundedFrameBytes, maxQueuedWriteBytes)
        self.writeQueue = DispatchQueue(
            label: "aviary.work-service.peer.write", qos: .utility)
    }

    func startReading(onFrame: @escaping @Sendable (Data) -> Bool,
                     onOverflow: @escaping @Sendable () -> Void,
                     onClose: @escaping @Sendable () -> Void,
                     onInputOverload: @escaping @Sendable () -> Void = {}) {
        handle.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            var shouldStop = false
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !shouldStop {
                let count = recv(
                    self.handle.fileDescriptor, &buffer, buffer.count, Int32(MSG_DONTWAIT))
                if count > 0 {
                    let lines = self.framer.feed(Data(buffer[0..<count]))
                    for line in lines {
                        guard onFrame(line) else {
                            onInputOverload()
                            // Foundation's readability-handler setter synchronizes with the
                            // dispatch source. Calling it from inside this callback traps on
                            // Linux (the source queue is already executing). Defer the setter
                            // until this callback has returned.
                            self.deferStopReading()
                            shouldStop = true
                            break
                        }
                    }
                    if self.framer.takeOverflowCount() > 0 {
                        onOverflow()
                        self.deferStopReading()
                        // Do not continue draining bytes after the frame bound has been
                        // violated. Valid lines already handed to the pump remain ordered;
                        // unread bytes are discarded when the connection is closed.
                        shouldStop = true
                    }
                    continue
                }
                if count == 0 {
                    if self.markClosed() { onClose() }
                    break
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if self.markClosed() { onClose() }
                break
            }
        }
    }

    /// Stop admitting new input while allowing an already-admitted pump to drain.  Closing the
    /// descriptor remains the responsibility of ``close()`` after the chosen stop policy elapses.
    func stopReading() {
        handle.readabilityHandler = nil
    }

    private func deferStopReading() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.stopReading()
        }
    }

    /// Enqueue a barrier after all writes accepted by this peer.  The caller races this barrier
    /// against a transport-wide deadline; the write queue itself never waits on a peer forever.
    func waitForWrites() async {
        await withCheckedContinuation { continuation in
            writeQueue.async {
                continuation.resume()
            }
        }
    }

    /// Queue a response in connection order.  The queue has a finite item bound and every item
    /// has a finite send deadline; a full/failed queue reports failure to the server, which drops
    /// only this connection.
    @discardableResult
    func enqueue(_ frame: Data, onFailure: @escaping @Sendable () -> Void) -> Bool {
        guard frame.count <= maxFrameBytes else {
            onFailure()
            return false
        }
        stateLock.lock()
        guard !closed, queuedWrites < maxQueuedWrites,
              frame.count <= maxQueuedWriteBytes,
              frame.count <= maxQueuedWriteBytes - queuedWriteBytes else {
            stateLock.unlock()
            onFailure()
            return false
        }
        queuedWrites += 1
        queuedWriteBytes += frame.count
        stateLock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.queuedWrites = max(0, self.queuedWrites - 1)
                self.queuedWriteBytes = max(0, self.queuedWriteBytes - frame.count)
                self.stateLock.unlock()
            }
            do {
                try self.write(frame)
            } catch {
                onFailure()
            }
        }
        return true
    }

    func write(_ frame: Data, timeout: TimeInterval = 1) throws {
        guard frame.count <= maxFrameBytes else {
            throw WorkServiceUnixSocketFailure.system(EMSGSIZE)
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed() else { throw WorkServiceUnixSocketFailure.closed }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(workServiceBoundedTimeout(timeout, minimum: 0.01, maximum: 30)
                * 1_000_000_000)
        try frame.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let sent = send(
                    handle.fileDescriptor, base.advanced(by: offset), rawBuffer.count - offset,
                    AviaryPOSIX.sendFlags)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0 && errno == EINTR { continue }
                if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else {
                        throw WorkServiceUnixSocketFailure.system(EAGAIN)
                    }
                    var descriptor = pollfd(
                        fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                    let remaining = Int32(
                        min(100, max(1, (deadline - now) / 1_000_000)))
                    let ready = poll(&descriptor, 1, remaining)
                    if ready == 0 { continue }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        throw WorkServiceUnixSocketFailure.system(errno)
                    }
                    if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                        throw WorkServiceUnixSocketFailure.system(EPIPE)
                    }
                    continue
                }
                throw WorkServiceUnixSocketFailure.system(errno)
            }
        }
    }

    @discardableResult
    func close() -> Bool {
        guard claimClosed() else { return false }
        finishClose()
        return true
    }

    private func claimClosed() -> Bool {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return false
        }
        closed = true
        stateLock.unlock()
        return true
    }

    private func finishClose() {
        writeLock.lock()
        if !handleClosed {
            handle.readabilityHandler = nil
            try? handle.close()
            handleClosed = true
        }
        writeLock.unlock()
    }

    private func markClosed() -> Bool {
        guard claimClosed() else { return false }
        // ``markClosed`` runs on Foundation's readability callback queue. Defer the
        // readability-handler mutation and descriptor close to avoid a reentrant dispatch_sync
        // in swift-corelibs-foundation's FileHandle implementation.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.finishClose()
        }
        return true
    }

    private func isClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }
}

private final class WorkServiceUnixSocketListener: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let socketIdentity: WorkServiceSocketIdentity?
    private let lock = NSLock()
    private var closed = false

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        var parentStat = stat()
        guard lstat(parent, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR,
              parentStat.st_uid == geteuid(),
              (parentStat.st_mode & mode_t(0o077)) == 0 else {
            throw WorkServiceUnixSocketFailure.invalidPath
        }
        var existing = stat()
        guard lstat(path, &existing) != 0 else {
            throw WorkServiceUnixSocketFailure.endpointOccupied
        }
        guard errno == ENOENT else {
            throw WorkServiceUnixSocketFailure.system(errno)
        }
        let socket = AviaryPOSIX.streamSocket()
        guard socket >= 0 else { throw WorkServiceUnixSocketFailure.system(errno) }
        var createdIdentity: WorkServiceSocketIdentity? = nil
        do {
            try workServiceNoSigPipe(socket)
            try workServiceMakeNonBlocking(socket)
            var address = try workServiceSocketAddress(path: path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw WorkServiceUnixSocketFailure.system(errno) }
            // Capture the inode immediately after bind. A later chmod/listen failure must
            // still clean up the socket this initializer created; waiting until after listen
            // would leave a half-created endpoint behind on that error path.
            createdIdentity = workServiceSocketIdentity(path: path)
            guard createdIdentity != nil else {
                throw WorkServiceUnixSocketFailure.system(EIO)
            }
            guard chmod(path, mode_t(0o600)) == 0 else {
                throw WorkServiceUnixSocketFailure.system(errno)
            }
            guard listen(socket, 32) == 0 else {
                throw WorkServiceUnixSocketFailure.system(errno)
            }
        } catch {
            _ = AviaryPOSIX.close(socket)
            workServiceRemoveOwnedSocket(path: path, identity: createdIdentity)
            throw error
        }
        self.path = path
        self.descriptor = socket
        self.source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .global(qos: .utility))
        self.socketIdentity = createdIdentity
        self.source.setCancelHandler { _ = AviaryPOSIX.close(socket) }
    }

    func start(onAccept: @escaping @Sendable (Int32) -> Void) {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let accepted = accept(self.descriptor, nil, nil)
                if accepted >= 0 {
                    onAccept(accepted)
                    continue
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                break
            }
        }
        source.resume()
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        source.cancel()
        // The listener created this exact endpoint in a validated private directory.  It is
        // safe to remove only that owned socket inode; a replacement file/socket is never
        // removed. The source's cancel handler owns the descriptor close.
        workServiceRemoveOwnedSocket(path: path, identity: socketIdentity)
    }
}

private final class WorkServiceTransportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }

    var isCanceled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class WorkServiceTransportConnectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }

    var isCanceled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// A single-consumer, bounded input pump.  Socket readability callbacks only perform admission
/// into this queue; they never create one unbounded Swift ``Task`` per frame.  The consumer task
/// is admitted when the connection is accepted, so a burst arriving before the first scheduler
/// turn is still subject to the item and byte bounds.  FIFO draining also makes a frame received
/// immediately before EOF observable before the connection-end callback.
private final class WorkServiceTransportInputPump: @unchecked Sendable {
    private let lock = NSLock()
    private let maxItems: Int
    private let maxBytes: Int
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var finished = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var consumer: Task<Void, Never>?

    init(maxItems: Int, maxBytes: Int) {
        self.maxItems = max(1, maxItems)
        self.maxBytes = max(1, maxBytes)
    }

    /// Starts exactly one consumer.  It is intentionally called before the peer begins reading.
    func start(
        onFrame: @escaping @Sendable (Data) async -> Void,
        onEnd: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        guard consumer == nil else {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            while !Task.isCancelled, let frame = await self?.next() {
                await onFrame(frame)
            }
            if !Task.isCancelled {
                await onEnd()
            }
        }
        consumer = task
        lock.unlock()
    }

    /// Returns false when the frame was not admitted.  The caller should close that connection;
    /// already admitted frames remain ordered and are never silently reclassified as EOF.
    func offer(_ frame: Data) -> Bool {
        lock.lock()
        guard !finished, frame.count <= maxBytes,
              queue.count < maxItems,
              frame.count <= maxBytes - queuedBytes else {
            lock.unlock()
            return false
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: frame)
        } else {
            queue.append(frame)
            queuedBytes += frame.count
            lock.unlock()
        }
        return true
    }

    /// Ends admission.  `next()` drains all frames admitted before this call, then returns nil;
    /// this is the explicit FIFO frame-before-EOF contract.
    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if queue.isEmpty, let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: nil)
        } else {
            lock.unlock()
        }
    }

    /// The already-admitted consumer task, if started.  Stop/drain uses this to wait for FIFO
    /// admission without awaiting each individual peer serially.
    var consumerTask: Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return consumer
    }

    private func next() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !queue.isEmpty {
                let frame = queue.removeFirst()
                queuedBytes = max(0, queuedBytes - frame.count)
                lock.unlock()
                continuation.resume(returning: frame)
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

private final class WorkServiceTransportOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class WorkServiceTransportDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(count: Int) {
        self.remaining = max(0, count)
        self.fired = count <= 0
    }

    func signal() {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        remaining = max(0, remaining - 1)
        if remaining == 0 {
            fired = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        } else {
            lock.unlock()
        }
    }

    func wait(timeout: TimeInterval) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + workServiceBoundedTimeout(
                    timeout, minimum: 0.001, maximum: 30)) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    guard !self.fired else {
                        self.lock.unlock()
                        return
                    }
                    self.fired = true
                    let continuation = self.continuation
                    self.continuation = nil
                    self.lock.unlock()
                    continuation?.resume()
                }
        }
    }

    func wait(until deadline: UInt64) async {
        await wait(timeout: WorkServiceTransportServerWait.remainingTime(until: deadline))
    }
}

private enum WorkServiceTransportServerWait {
    static func deadline(after timeout: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
            + UInt64(workServiceBoundedTimeout(timeout, minimum: 0.001, maximum: 30)
                * 1_000_000_000)
    }

    static func remainingTime(until deadline: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline > now else { return 0.001 }
        return TimeInterval(deadline - now) / 1_000_000_000
    }

    static func awaitCompletion(
        _ task: Task<Void, Never>, timeout: TimeInterval
    ) async {
        let gate = WorkServiceTransportOneShot()
        await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task {
                await task.value
                gate.fire()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + workServiceBoundedTimeout(
                    timeout, minimum: 0.001, maximum: 30)) {
                    gate.fire()
                }
        }
    }

    static func awaitCompletion(
        _ task: Task<Void, Never>, until deadline: UInt64
    ) async {
        await awaitCompletion(task, timeout: remainingTime(until: deadline))
    }

    static func awaitWrites(
        _ peer: WorkServiceUnixSocketPeer, timeout: TimeInterval
    ) async {
        let gate = WorkServiceTransportOneShot()
        await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task {
                await peer.waitForWrites()
                gate.fire()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + workServiceBoundedTimeout(
                    timeout, minimum: 0.001, maximum: 30)) {
                    gate.fire()
                }
        }
    }

    static func awaitWrites(
        _ peer: WorkServiceUnixSocketPeer, until deadline: UInt64
    ) async {
        await awaitWrites(peer, timeout: remainingTime(until: deadline))
    }
}

// MARK: - Server

/// A bounded local service adapter.  The server owns sockets and connection bookkeeping only;
/// one connection's EOF cancels its transport tasks and never calls a WorkService lifecycle
/// operation.  The backing service remains available for other GUIs and later reconnection.
public actor WorkServiceUnixSocketServer {
    public static let defaultMaxClients = 32
    public static let defaultMaxQueuedWrites = 64
    public static let defaultMaxPendingRequests = 128
    public static let defaultMaxRequestIDs = 4_096
    public static let defaultMaxInputBytes = 16 * 1024 * 1024
    public static let defaultInputDrainTimeout: TimeInterval = 1
    public static let defaultMaxQueuedWriteBytes = 16 * 1024 * 1024

    private let endpointStorage: WorkServiceTransportEndpoint
    private let service: any WorkServiceClient
    private let maxFrameBytes: Int
    private let maxClients: Int
    private let maxQueuedWrites: Int
    private let maxQueuedWriteBytes: Int
    private let maxPendingRequests: Int
    private let maxRequestIDs: Int
    private let maxInputBytes: Int
    private let principalBinding: (any WorkServiceTransportPrincipalBinding)?
    private var listener: WorkServiceUnixSocketListener?
    private var accepting = false
    private var connections: [UUID: WorkServiceUnixSocketPeer] = [:]
    private var inputPumps: [UUID: WorkServiceTransportInputPump] = [:]
    private var connectionGenerations: [UUID: UInt64] = [:]
    private var nextConnectionGeneration: UInt64 = 0
    private var clientIdentities: [UUID: ClientRef] = [:]
    /// The host instance negotiated on handshake is a per-connection authority fence. The
    /// backing service must not be swapped underneath an established connection.
    private var hostInstances: [UUID: WorkHostInstanceRef] = [:]
    private var seenRequestIDs: [UUID: Set<String>] = [:]
    private var pendingRequestCounts: [UUID: Int] = [:]
    private var cancellation: [UUID: WorkServiceTransportConnectionCancellation] = [:]

    public init(endpoint: WorkServiceTransportEndpoint, service: any WorkServiceClient,
                maxFrameBytes: Int = WorkServiceTransportCodec.maxFrameBytes,
                maxClients: Int = WorkServiceUnixSocketServer.defaultMaxClients,
                maxQueuedWrites: Int = WorkServiceUnixSocketServer.defaultMaxQueuedWrites,
                maxQueuedWriteBytes: Int = WorkServiceUnixSocketServer.defaultMaxQueuedWriteBytes,
                maxPendingRequests: Int = WorkServiceUnixSocketServer.defaultMaxPendingRequests,
                maxRequestIDs: Int = WorkServiceUnixSocketServer.defaultMaxRequestIDs,
                maxInputBytes: Int = WorkServiceUnixSocketServer.defaultMaxInputBytes,
                principalBinding: (any WorkServiceTransportPrincipalBinding)? = nil) {
        self.endpointStorage = endpoint
        self.service = service
        let boundedFrameBytes = WorkServiceTransportCodec.clampFrameBytes(maxFrameBytes)
        self.maxFrameBytes = boundedFrameBytes
        self.maxClients = max(1, min(maxClients, 256))
        self.maxQueuedWrites = max(1, min(maxQueuedWrites, 256))
        self.maxQueuedWriteBytes = max(
            boundedFrameBytes,
            min(maxQueuedWriteBytes, WorkServiceUnixSocketServer.defaultMaxQueuedWriteBytes * 4))
        self.maxPendingRequests = max(1, min(maxPendingRequests, 512))
        self.maxRequestIDs = max(1, min(maxRequestIDs, 16_384))
        self.maxInputBytes = max(
            boundedFrameBytes,
            min(maxInputBytes, WorkServiceUnixSocketServer.defaultMaxInputBytes * 4))
        self.principalBinding = principalBinding
    }

    public var endpoint: WorkServiceTransportEndpoint { endpointStorage }

    public func start() throws {
        guard !accepting else { return }
        do {
            let listener = try WorkServiceUnixSocketListener(path: endpointStorage.path)
            self.listener = listener
            accepting = true
            listener.start { [weak self] descriptor in
                Task { await self?.accept(descriptor: descriptor) }
            }
        } catch WorkServiceUnixSocketFailure.endpointOccupied {
            throw WorkServiceTransportError.endpointOccupied
        } catch WorkServiceUnixSocketFailure.system(let code) where code == EADDRINUSE {
            // The endpoint may have been created after the initial lstat. Report the same
            // deterministic occupancy result without exposing a race-dependent POSIX detail.
            throw WorkServiceTransportError.endpointOccupied
        } catch WorkServiceUnixSocketFailure.invalidPath {
            throw WorkServiceTransportError.invalidEndpoint(endpointStorage.path)
        } catch {
            throw WorkServiceTransportError.invalidEndpoint(
                WorkServiceTransportText.bound(String(describing: error)) ?? "socket setup failed")
        }
    }

    public func stop() async {
        await stop(drainTimeout: 0)
    }

    /// Stop accepting new connections and close existing ones.  With a positive timeout, input
    /// admission is first halted and already-admitted requests/responses get one shared bounded
    /// drain window; each connection drains concurrently, so a stalled peer cannot serialize
    /// shutdown behind another peer.  A zero timeout is an immediate abort.  No Work lifecycle
    /// operation is issued by either mode.
    public func stop(drainTimeout: TimeInterval) async {
        accepting = false
        listener?.close()
        listener = nil
        let ids = Array(connections.keys)
        let timeout = workServiceBoundedTimeout(drainTimeout, minimum: 0, maximum: 30)
        for id in ids {
            guard let generation = connectionGenerations[id] else {
                disconnect(id: id)
                continue
            }
            if timeout == 0 {
                disconnect(id: id, generation: generation)
            } else {
                inputPumps[id]?.finish()
                connections[id]?.stopReading()
            }
        }
        if timeout > 0 {
            let draining = ids.compactMap { id -> (UUID, UInt64, Task<Void, Never>?)? in
                guard let generation = connectionGenerations[id] else { return nil }
                return (id, generation, inputPumps[id]?.consumerTask)
            }
            let gate = WorkServiceTransportDrainGate(count: draining.count)
            let deadline = WorkServiceTransportServerWait.deadline(after: timeout)
            var drains: [Task<Void, Never>] = []
            drains.reserveCapacity(draining.count)
            for (id, generation, pumpTask) in draining {
                let drain = Task { [weak self] in
                    defer { gate.signal() }
                    if let pumpTask {
                        await WorkServiceTransportServerWait.awaitCompletion(
                            pumpTask, until: deadline)
                    }
                    await self?.drainConnection(
                        id: id, generation: generation, until: deadline)
                }
                drains.append(drain)
            }
            await gate.wait(until: deadline)
            // A timeout is an explicit abort boundary. The concurrent drains are canceled before
            // peers are removed; a service implementation that ignores cancellation may finish
            // its own work later, but this transport never claims that it drained in that case.
            for drain in drains { drain.cancel() }
            for id in ids { disconnect(id: id) }
        }
    }

    public var connectedClientCount: Int { connections.count }

    private func accept(descriptor: Int32) {
        guard accepting, connections.count < maxClients else {
            close(descriptor)
            return
        }
        do {
            let peer = try WorkServiceUnixSocketPeer(
                fileDescriptor: descriptor, maxFrameBytes: maxFrameBytes,
                maxQueuedWrites: maxQueuedWrites,
                maxQueuedWriteBytes: maxQueuedWriteBytes)
            let id = UUID()
            nextConnectionGeneration = nextConnectionGeneration == UInt64.max
                ? 1 : nextConnectionGeneration + 1
            let generation = nextConnectionGeneration
            let token = WorkServiceTransportConnectionCancellation()
            let pump = WorkServiceTransportInputPump(
                maxItems: maxPendingRequests, maxBytes: maxInputBytes)
            connections[id] = peer
            inputPumps[id] = pump
            connectionGenerations[id] = generation
            seenRequestIDs[id] = []
            pendingRequestCounts[id] = 0
            cancellation[id] = token
            // Admit the one consumer before readability is enabled. Every later frame is handed
            // to that awaited FIFO consumer; neither the socket callback nor the pump creates a
            // Task per frame.
            pump.start(
                onFrame: { [weak self] frame in
                    await self?.ingest(
                        frame: frame, connectionID: id, generation: generation)
                },
                onEnd: { [weak self] in
                    await self?.inputEnded(connectionID: id, generation: generation)
                })
            peer.startReading(
                onFrame: { frame in pump.offer(frame) },
                onOverflow: { [weak self] in
                    Task {
                        await self?.frameOverflow(connectionID: id, generation: generation)
                    }
                },
                onClose: { pump.finish() },
                onInputOverload: { [weak self] in
                    pump.finish()
                    Task {
                        await self?.inputOverload(connectionID: id, generation: generation)
                    }
                })
        } catch {
            close(descriptor)
        }
    }

    private func ingest(frame: Data, connectionID: UUID, generation: UInt64) async {
        guard isCurrent(connectionID: connectionID, generation: generation) else { return }
        if let envelope = try? WorkServiceTransportCodec.decodeRequest(frame) {
            if seenRequestIDs[connectionID, default: []].contains(envelope.id) {
                enqueue(
                    WorkServiceTransportResponseEnvelope(
                        id: envelope.id, ok: false,
                        error: .init(code: .duplicateRequestID,
                                     detail: "request id was already used on this connection"),
                        hostInstance: hostInstances[connectionID]),
                    connectionID: connectionID, generation: generation)
                return
            }
            if seenRequestIDs[connectionID, default: []].count >= maxRequestIDs {
                enqueue(
                    WorkServiceTransportResponseEnvelope(
                        id: envelope.id, ok: false,
                        error: .init(
                            code: .invalidRequest,
                            detail: "connection request-id budget is exhausted; reconnect"),
                        hostInstance: hostInstances[connectionID]),
                    connectionID: connectionID, generation: generation)
                return
            }
            seenRequestIDs[connectionID, default: []].insert(envelope.id)
            if pendingRequestCounts[connectionID, default: 0] >= maxPendingRequests {
                enqueue(
                    WorkServiceTransportResponseEnvelope(
                        id: envelope.id, ok: false,
                        error: .init(
                            code: .invalidRequest,
                            detail: "too many pending requests on this connection"),
                        hostInstance: hostInstances[connectionID]),
                    connectionID: connectionID, generation: generation)
                return
            }
            guard let token = cancellation[connectionID] else { return }
            pendingRequestCounts[connectionID] =
                pendingRequestCounts[connectionID, default: 0] + 1
            // The pump is the ordered executor. Awaiting the service operation here means the
            // next admitted frame cannot enter this actor until the current operation reaches its
            // response boundary; no unbounded Task-per-frame chain is needed.
            await process(
                envelope, connectionID: connectionID, generation: generation, token: token)
        } else {
            // Preserve a valid request identity when an otherwise undecodable frame names an
            // operation the current build does not know.  This lets a newer/older peer receive
            // an explicit typed refusal instead of a response addressed to nobody.
            let raw = JSONValue.parse(frame)
            let id = raw?["id"]?.stringValue
                .flatMap { WorkServiceTransportCodec.validRequestID($0) ? $0 : nil }
                ?? "invalid"
            let code: WorkServiceTransportErrorCode
            let detail: String?
            if let operation = raw?["operation"]?.stringValue,
               WorkServiceTransportOperation(rawValue: operation) == nil {
                code = .unsupportedOperation
                detail = "operation is not supported by this service"
            } else {
                code = .invalidFrame
                detail = "request was not valid JSON"
            }
            enqueue(
                WorkServiceTransportResponseEnvelope(
                    id: id, ok: false, error: .init(code: code, detail: detail),
                    hostInstance: hostInstances[connectionID]),
                connectionID: connectionID, generation: generation)
            return
        }
    }

    private func frameOverflow(connectionID: UUID, generation: UInt64) {
        guard isCurrent(connectionID: connectionID, generation: generation) else { return }
        enqueue(
            WorkServiceTransportResponseEnvelope(
                id: "overflow", ok: false,
                error: .init(code: .frameTooLarge,
                             detail: "request frame exceeded the transport bound"),
                hostInstance: hostInstances[connectionID]),
            connectionID: connectionID, generation: generation)
        inputPumps[connectionID]?.finish()
    }

    private func inputOverload(connectionID: UUID, generation: UInt64) {
        guard isCurrent(connectionID: connectionID, generation: generation) else { return }
        // The frame was not admitted, so there is no trustworthy request ID to answer.  Closing
        // this connection is the bounded overload result; other GUI connections remain alive.
        disconnect(id: connectionID, generation: generation)
    }

    private func inputEnded(connectionID: UUID, generation: UInt64) {
        guard isCurrent(connectionID: connectionID, generation: generation) else { return }
        // A server stop owns its own drain window. Avoid starting a second EOF drain while the
        // stop call is awaiting the pump and response queues under that same deadline.
        guard accepting else { return }
        // EOF follows all frames admitted to the pump.  Let those requests reach their bounded
        // service receipt boundary, but never make an EOF wait unboundedly on a broken service.
        let peer = connections[connectionID]
        Task { [weak self] in
            let deadline = WorkServiceTransportServerWait.deadline(
                after: WorkServiceUnixSocketServer.defaultInputDrainTimeout)
            if let peer {
                await WorkServiceTransportServerWait.awaitWrites(peer, until: deadline)
            }
            await self?.disconnect(id: connectionID, generation: generation)
        }
    }

    private func drainConnection(
        id: UUID, generation: UInt64, until deadline: UInt64
    ) async {
        guard isCurrent(connectionID: id, generation: generation) else { return }
        if let peer = connections[id] {
            await WorkServiceTransportServerWait.awaitWrites(peer, until: deadline)
        }
        disconnect(id: id, generation: generation)
    }

    private func process(
        _ envelope: WorkServiceTransportRequestEnvelope, connectionID: UUID,
        generation: UInt64,
        token: WorkServiceTransportConnectionCancellation
    ) async {
        defer {
            if isCurrent(connectionID: connectionID, generation: generation) {
                pendingRequestCounts[connectionID] = max(
                    0, pendingRequestCounts[connectionID, default: 1] - 1)
            }
        }
        guard isCurrent(connectionID: connectionID, generation: generation),
              !token.isCanceled else { return }
        do {
            if envelope.operation != .handshake,
               let expectedHostInstance = hostInstances[connectionID],
               let client = clientIdentities[connectionID] {
                // The response envelope is a wire fence, while this fresh observation verifies
                // that the service behind the adapter is still the instance negotiated on this
                // connection. This catches a backend/service swap even when the DTO is empty
                // (for example an empty list, snapshot page, or unavailable body).
                let observed = try await service.handshake(
                    WorkServiceHandshakeRequest(client: client))
                guard observed.accepted, observed.hostInstance == expectedHostInstance else {
                    throw WorkServiceTransportError.remote(
                        code: .identityMismatch,
                        detail: "Work Host instance changed after handshake")
                }
            }
            let response = try await dispatch(envelope, connectionID: connectionID)
            if envelope.operation != .handshake,
               let expectedHostInstance = hostInstances[connectionID] {
                try WorkServiceTransportCodec.validateResponseCorrelation(
                    response, request: envelope, expectedHostInstance: expectedHostInstance)
            }
            guard isCurrent(connectionID: connectionID, generation: generation),
                  !token.isCanceled else { return }
            enqueue(response, connectionID: connectionID, generation: generation)
        } catch {
            guard isCurrent(connectionID: connectionID, generation: generation),
                  !token.isCanceled else { return }
            let (code, detail) = WorkServiceTransportText.error(for: error)
            enqueue(
                WorkServiceTransportResponseEnvelope(
                    id: envelope.id, ok: false,
                    error: .init(code: code, detail: detail),
                    hostInstance: hostInstances[connectionID]),
                connectionID: connectionID, generation: generation)
        }
    }

    private func dispatch(
        _ envelope: WorkServiceTransportRequestEnvelope, connectionID: UUID
    ) async throws -> WorkServiceTransportResponseEnvelope {
        guard WorkServiceTransportCodec.validRequestID(envelope.id) else {
            throw WorkServiceTransportError.invalidFrame
        }
        switch envelope.operation {
        case .handshake:
            let request = try WorkServiceTransportCodec.decodePayload(
                WorkServiceHandshakeRequest.self, from: envelope.payload)
            guard WorkServiceTransportText.validIdentity(request.client),
                  envelope.client == nil || envelope.client == request.client else {
                throw WorkServiceTransportError.remote(
                    code: .identityMismatch, detail: "handshake client identity is inconsistent")
            }
            if let principalBinding,
               !principalBinding.accepts(claimedClient: request.client) {
                throw WorkServiceTransportError.remote(
                    code: .handshakeRejected,
                    detail: "client principal was not accepted by the Work Host")
            }
            let response = try await service.handshake(request)
            guard response.accepted else {
                throw WorkServiceTransportError.remote(
                    code: .handshakeRejected, detail: response.diagnostic)
            }
            if let existingClient = clientIdentities[connectionID] {
                guard existingClient == request.client,
                      hostInstances[connectionID] == response.hostInstance else {
                    throw WorkServiceTransportError.remote(
                        code: .identityMismatch,
                        detail: "repeated handshake changed the bound client or Work Host instance")
                }
            } else {
                clientIdentities[connectionID] = request.client
                hostInstances[connectionID] = response.hostInstance
            }
            return try success(id: envelope.id, value: response, connectionID: connectionID)

        default:
            guard let client = clientIdentities[connectionID] else {
                throw WorkServiceTransportError.remote(
                    code: .handshakeRequired, detail: "send handshake before Work requests")
            }
            guard envelope.client == client else {
                throw WorkServiceTransportError.remote(
                    code: .identityMismatch, detail: "request client differs from handshake")
            }
            switch envelope.operation {
            case .listWorks:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceListRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.listWorks(request), connectionID: connectionID)
            case .describeWork:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceDescribeRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.describeWork(request), connectionID: connectionID)
            case .createWork:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceCreateWorkRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.createWork(request), connectionID: connectionID)
            case .createSession:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceCreateSessionRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(
                    id: envelope.id, value: try await service.createSession(request),
                    connectionID: connectionID)
            case .completeWork:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceCompleteWorkRequest.self, from: envelope.payload)
                guard request.command.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.completeWork(request), connectionID: connectionID)
            case .attach:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceAttachRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.attach(request), connectionID: connectionID)
            case .detach:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceDetachRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.detach(request), connectionID: connectionID)
            case .updateCapabilities:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceUpdateCapabilitiesRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(
                    id: envelope.id, value: try await service.updateCapabilities(request),
                    connectionID: connectionID)
            case .acknowledgeRead:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceAcknowledgeReadRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(
                    id: envelope.id, value: try await service.acknowledgeRead(request),
                    connectionID: connectionID)
            case .snapshot:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceSnapshotRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.snapshot(request), connectionID: connectionID)
            case .eventsAfterCursor:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceEventsRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(
                    id: envelope.id, value: try await service.eventsAfterCursor(request),
                    connectionID: connectionID)
            case .fetchArtifact:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceArtifactRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                let artifact = try await service.fetchArtifact(request)
                return try success(id: envelope.id, value: artifact, connectionID: connectionID)
            case .fetchBody:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceBodyRequest.self, from: envelope.payload)
                guard request.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.fetchBody(request), connectionID: connectionID)
            case .command:
                let request = try WorkServiceTransportCodec.decodePayload(
                    WorkServiceCommandRequest.self, from: envelope.payload)
                guard request.command.client == client else { throw identityMismatch() }
                return try success(id: envelope.id, value: try await service.command(request), connectionID: connectionID)
            case .handshake:
                // Handshakes are handled above so that the same client can refresh the
                // control-journal cursor on an established connection.  This branch remains
                // unreachable for a well-formed dispatch call.
                throw WorkServiceTransportError.remote(
                    code: .handshakeRejected, detail: "handshake dispatch fell through")
            }
        }
    }

    private func identityMismatch() -> WorkServiceTransportError {
        .remote(code: .identityMismatch, detail: "request client differs from handshake")
    }

    private func success<T: Encodable>(id: String, value: T, connectionID: UUID) throws
        -> WorkServiceTransportResponseEnvelope {
        let payload = try WorkServiceTransportCodec.encodePayload(value)
        return WorkServiceTransportResponseEnvelope(
            id: id, ok: true, data: payload, hostInstance: hostInstances[connectionID])
    }

    private func enqueue(
        _ response: WorkServiceTransportResponseEnvelope, connectionID: UUID,
        generation: UInt64? = nil
    ) {
        guard isCurrent(connectionID: connectionID, generation: generation),
              let peer = connections[connectionID] else { return }
        do {
            let frame = try WorkServiceTransportCodec.encodeFrame(response, maxBytes: maxFrameBytes)
            _ = peer.enqueue(frame) { [weak self] in
                Task {
                    await self?.disconnect(id: connectionID, generation: generation)
                }
            }
        } catch {
            disconnect(id: connectionID, generation: generation)
        }
    }

    private func isCurrent(connectionID: UUID, generation: UInt64?) -> Bool {
        guard connections[connectionID] != nil else { return false }
        guard let generation else { return true }
        return connectionGenerations[connectionID] == generation
    }

    private func disconnect(id: UUID, generation: UInt64? = nil) {
        guard isCurrent(connectionID: id, generation: generation) else { return }
        cancellation[id]?.cancel()
        let pump = inputPumps[id]
        pump?.finish()
        pump?.consumerTask?.cancel()
        connections[id]?.stopReading()
        inputPumps.removeValue(forKey: id)
        connectionGenerations.removeValue(forKey: id)
        seenRequestIDs.removeValue(forKey: id)
        clientIdentities.removeValue(forKey: id)
        hostInstances.removeValue(forKey: id)
        pendingRequestCounts.removeValue(forKey: id)
        cancellation.removeValue(forKey: id)
        connections.removeValue(forKey: id)?.close()
    }
}

// MARK: - Client

private final class WorkServiceTransportRequestMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal = false

    @discardableResult
    func markTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return false }
        terminal = true
        return true
    }

    var isTerminal: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminal
    }
}

private struct WorkServiceTransportPendingResponse {
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let marker: WorkServiceTransportRequestMarker
    let operation: WorkServiceTransportOperation
    let request: WorkServiceTransportRequestEnvelope
}

/// A many-to-many-capable client adapter.  Each instance represents one GUI/device attachment;
/// multiple clients can connect to the same service independently, and disconnecting one client
/// only fails that client's pending transport continuations.
public actor WorkServiceUnixSocketClient: WorkServiceClient {
    private let endpointStorage: WorkServiceTransportEndpoint
    private let client: ClientRef
    private let expectedHost: WorkHostRef?
    private let maxFrameBytes: Int
    private let maxPendingRequests: Int
    private let requestTimeout: TimeInterval
    private var socket: WorkServiceUnixSocketPeer?
    private var inputPump: WorkServiceTransportInputPump?
    private var connected = false
    private var handshakeResponse: WorkServiceHandshakeResponse?
    private var nextRequestID = 0
    private var nextConnectionGeneration: UInt64 = 0
    private var activeConnectionGeneration: UInt64?
    private var pending: [String: WorkServiceTransportPendingResponse] = [:]
    private var completedResponseIDs: Set<String> = []
    private var completedResponseOrder: [String] = []
    private var lateResponseTombstones: Set<String> = []
    private var lateResponseOrder: [String] = []

    public init(endpoint: WorkServiceTransportEndpoint, client: ClientRef,
                expectedHost: WorkHostRef? = nil,
                maxFrameBytes: Int = WorkServiceTransportCodec.maxFrameBytes,
                maxPendingRequests: Int = WorkServiceUnixSocketServer.defaultMaxPendingRequests,
                requestTimeout: TimeInterval = 30) {
        self.endpointStorage = endpoint
        self.client = client
        self.expectedHost = expectedHost
        self.maxFrameBytes = WorkServiceTransportCodec.clampFrameBytes(maxFrameBytes)
        self.maxPendingRequests = max(1, min(maxPendingRequests, 512))
        self.requestTimeout = workServiceBoundedTimeout(requestTimeout, minimum: 0.1, maximum: 30)
    }

    public var isConnected: Bool { connected }
    public var negotiatedHandshake: WorkServiceHandshakeResponse? { handshakeResponse }

    @discardableResult
    public func connect(build: String? = nil) async throws -> WorkServiceHandshakeResponse {
        guard !connected else { throw WorkServiceTransportError.alreadyConnected }
        try openSocket()
        do {
            let request = WorkServiceHandshakeRequest(client: client, build: build)
            let response = try await performHandshake(request)
            try validateHandshake(response)
            handshakeResponse = response
            return response
        } catch {
            closeTransport(error)
            throw error
        }
    }

    public func close() {
        closeTransport(WorkServiceTransportError.disconnected)
    }

    public func handshake(
        _ request: WorkServiceHandshakeRequest
    ) async throws -> WorkServiceHandshakeResponse {
        guard request.client == client else {
            throw WorkServiceTransportError.remote(
                code: .identityMismatch, detail: "handshake client differs from this transport")
        }
        if let handshakeResponse, connected {
            do {
                let response = try await performHandshake(request)
                try validateHandshake(response)
                guard response.hostInstance == handshakeResponse.hostInstance else {
                    closeTransport(WorkServiceTransportError.remote(
                        code: .identityMismatch,
                        detail: "repeated handshake changed the Work Host instance"))
                    throw WorkServiceTransportError.remote(
                        code: .identityMismatch,
                        detail: "repeated handshake changed the Work Host instance")
                }
                self.handshakeResponse = response
                return response
            } catch {
                if connected, Self.shouldFenceHandshake(error) {
                    closeTransport(error)
                }
                throw error
            }
        }
        if let handshakeResponse { return handshakeResponse }
        guard !connected else { throw WorkServiceTransportError.alreadyConnected }
        try openSocket()
        do {
            let response = try await performHandshake(request)
            try validateHandshake(response)
            handshakeResponse = response
            return response
        } catch {
            closeTransport(error)
            throw error
        }
    }

    private static func shouldFenceHandshake(_ error: Error) -> Bool {
        guard let transport = error as? WorkServiceTransportError else { return false }
        switch transport {
        case .notConnected, .disconnected, .invalidFrame, .invalidResponse,
             .duplicateResponseID, .writeFailed:
            return true
        case .remote(let code, _):
            return code == .identityMismatch || code == .transportClosed
                || code == .serverStopping || code == .serviceUnavailable
        case .invalidEndpoint, .endpointOccupied, .alreadyConnected, .frameTooLarge,
             .tooManyPendingRequests, .timedOut, .canceled:
            return false
        }
    }

    public func listWorks(_ request: WorkServiceListRequest) async throws -> WorkServiceWorkPage {
        try await call(.listWorks, request)
    }

    public func describeWork(
        _ request: WorkServiceDescribeRequest
    ) async throws -> WorkServiceWorkDescriptor {
        try await call(.describeWork, request)
    }

    public func createWork(
        _ request: WorkServiceCreateWorkRequest
    ) async throws -> WorkServiceCreateWorkResponse {
        try await call(.createWork, request)
    }

    public func createSession(
        _ request: WorkServiceCreateSessionRequest
    ) async throws -> WorkServiceCreateSessionResponse {
        try await call(.createSession, request)
    }

    public func completeWork(
        _ request: WorkServiceCompleteWorkRequest
    ) async throws -> WorkServiceCommandReceipt {
        try await call(.completeWork, request)
    }

    public func attach(
        _ request: WorkServiceAttachRequest
    ) async throws -> WorkServiceAttachResponse {
        try await call(.attach, request)
    }

    public func detach(
        _ request: WorkServiceDetachRequest
    ) async throws -> WorkServiceDetachResponse {
        try await call(.detach, request)
    }

    public func updateCapabilities(
        _ request: WorkServiceUpdateCapabilitiesRequest
    ) async throws -> WorkServiceUpdateCapabilitiesResponse {
        try await call(.updateCapabilities, request)
    }

    public func acknowledgeRead(
        _ request: WorkServiceAcknowledgeReadRequest
    ) async throws -> WorkServiceAcknowledgeReadResponse {
        try await call(.acknowledgeRead, request)
    }

    public func snapshot(
        _ request: WorkServiceSnapshotRequest
    ) async throws -> WorkServiceSnapshot {
        try await call(.snapshot, request)
    }

    public func eventsAfterCursor(
        _ request: WorkServiceEventsRequest
    ) async throws -> WorkServiceEventPage {
        try await call(.eventsAfterCursor, request)
    }

    public func fetchArtifact(
        _ request: WorkServiceArtifactRequest
    ) async throws -> WorkServiceArtifactDescriptor {
        try await call(.fetchArtifact, request)
    }

    public func fetchBody(_ request: WorkServiceBodyRequest) async throws -> WorkServiceBodyResponse {
        try await call(.fetchBody, request)
    }

    public func command(
        _ request: WorkServiceCommandRequest
    ) async throws -> WorkServiceCommandReceipt {
        try await call(.command, request)
    }

    private func openSocket() throws {
        guard !connected else { throw WorkServiceTransportError.alreadyConnected }
        do {
            let descriptor = AviaryPOSIX.streamSocket()
            guard descriptor >= 0 else { throw WorkServiceUnixSocketFailure.system(errno) }
            do {
                try workServiceNoSigPipe(descriptor)
                try workServiceMakeNonBlocking(descriptor)
                var address = try workServiceSocketAddress(path: endpointStorage.path)
                try workServiceConnect(
                    descriptor: descriptor, address: &address,
                    timeout: min(10, max(0.1, requestTimeout)))
                let peer = try WorkServiceUnixSocketPeer(
                    fileDescriptor: descriptor,
                    maxFrameBytes: maxFrameBytes,
                    maxQueuedWrites: 1,
                    maxQueuedWriteBytes: maxFrameBytes)
                nextConnectionGeneration = nextConnectionGeneration == UInt64.max
                    ? 1 : nextConnectionGeneration + 1
                let generation = nextConnectionGeneration
                let pump = WorkServiceTransportInputPump(
                    maxItems: maxPendingRequests,
                    maxBytes: max(
                        maxFrameBytes,
                        min(
                            WorkServiceUnixSocketServer.defaultMaxInputBytes,
                            maxFrameBytes * maxPendingRequests)))
                self.socket = peer
                self.inputPump = pump
                self.activeConnectionGeneration = generation
                connected = true
                pump.start(
                    onFrame: { [weak self] line in
                        await self?.receive(line, generation: generation)
                    },
                    onEnd: { [weak self] in
                        await self?.transportClosed(generation: generation)
                    })
                peer.startReading(
                    onFrame: { line in pump.offer(line) },
                    onOverflow: { [weak self] in
                        Task {
                            await self?.receiveOverflow(generation: generation)
                        }
                    },
                    onClose: { pump.finish() },
                    onInputOverload: { [weak self] in
                        pump.finish()
                        Task {
                            await self?.receiveOverload(generation: generation)
                        }
                    })
            } catch {
                _ = AviaryPOSIX.close(descriptor)
                throw error
            }
        } catch WorkServiceUnixSocketFailure.invalidPath {
            throw WorkServiceTransportError.invalidEndpoint(endpointStorage.path)
        } catch WorkServiceUnixSocketFailure.system(let code) where code == ETIMEDOUT {
            throw WorkServiceTransportError.timedOut(operation: .handshake)
        } catch let error as WorkServiceUnixSocketFailure {
            throw WorkServiceTransportError.writeFailed(String(describing: error))
        } catch {
            throw WorkServiceTransportError.invalidEndpoint(endpointStorage.path)
        }
    }

    private func validateHandshake(_ response: WorkServiceHandshakeResponse) throws {
        guard response.accepted else {
            throw WorkServiceTransportError.remote(
                code: .handshakeRejected, detail: response.diagnostic)
        }
        guard response.host == response.hostInstance.host else {
            throw WorkServiceTransportError.invalidResponse
        }
        guard response.controlJournal == JournalRef.workHost(response.host),
              response.controlCursor.journal == response.controlJournal,
              response.controlCursor.sequence >= 0,
              response.controlCursor.sequence == 0
                  ? response.controlCursor.eventID == nil
                  : response.controlCursor.eventID != nil else {
            throw WorkServiceTransportError.invalidResponse
        }
        guard response.workspaceCatalog.entries.isEmpty
            || response.capabilities.contains(.workspaceCatalog) else {
            throw WorkServiceTransportError.invalidResponse
        }
        if let expectedHost, expectedHost != response.host {
            throw WorkServiceTransportError.remote(
                code: .identityMismatch,
                detail: "handshake host does not match the expected Work Host")
        }
    }

    private func performHandshake(
        _ request: WorkServiceHandshakeRequest
    ) async throws -> WorkServiceHandshakeResponse {
        let payload = try WorkServiceTransportCodec.encodePayload(request)
        let envelope = WorkServiceTransportRequestEnvelope(
            id: nextID(), operation: .handshake, client: client, payload: payload)
        let response: WorkServiceHandshakeResponse = try await callEnvelope(envelope)
        return response
    }

    private func call<Req: Encodable, Resp: Decodable>(
        _ operation: WorkServiceTransportOperation, _ request: Req
    ) async throws -> Resp {
        guard handshakeResponse != nil else { throw WorkServiceTransportError.notConnected }
        let payload = try WorkServiceTransportCodec.encodePayload(request)
        let envelope = WorkServiceTransportRequestEnvelope(
            id: nextID(), operation: operation, client: client, payload: payload)
        return try await callEnvelope(envelope)
    }

    private func callEnvelope<Resp: Decodable>(
        _ envelope: WorkServiceTransportRequestEnvelope
    ) async throws -> Resp {
        guard connected, let socket else { throw WorkServiceTransportError.notConnected }
        let frame = try WorkServiceTransportCodec.encodeFrame(
            envelope, maxBytes: maxFrameBytes)
        guard pending.count < maxPendingRequests else {
            throw WorkServiceTransportError.tooManyPendingRequests
        }
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        let marker = WorkServiceTransportRequestMarker()
        pending[envelope.id] = WorkServiceTransportPendingResponse(
            continuation: continuation, marker: marker, operation: envelope.operation,
            request: envelope)
        if Task.isCancelled {
            _ = marker.markTerminal()
            pending.removeValue(forKey: envelope.id)?.continuation.finish(
                throwing: WorkServiceTransportError.canceled)
            throw WorkServiceTransportError.canceled
        }
        do {
            try socket.write(frame)
        } catch {
            failRequest(
                envelope.id,
                marker: marker,
                error: WorkServiceTransportError.writeFailed(String(describing: error)))
            closeTransport(error)
            throw WorkServiceTransportError.writeFailed(String(describing: error))
        }
        let flag = WorkServiceTransportCancellationFlag()
        let raw: Data
        do {
            raw = try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        var iterator = stream.makeAsyncIterator()
                        guard let value = try await iterator.next() else {
                            if flag.isCanceled { throw WorkServiceTransportError.canceled }
                            throw WorkServiceTransportError.disconnected
                        }
                        return value
                    }
                    group.addTask {
                        try await Task.sleep(
                            nanoseconds: UInt64(self.requestTimeout * 1_000_000_000))
                        await self.failRequest(
                            envelope.id,
                            marker: marker,
                            error: WorkServiceTransportError.timedOut(operation: envelope.operation))
                        throw WorkServiceTransportError.timedOut(operation: envelope.operation)
                    }
                    do {
                        let value = try await group.next()!
                        group.cancelAll()
                        if flag.isCanceled || Task.isCancelled {
                            throw WorkServiceTransportError.canceled
                        }
                        return value
                    } catch {
                        group.cancelAll()
                        if flag.isCanceled || Task.isCancelled {
                            throw WorkServiceTransportError.canceled
                        }
                        throw error
                    }
                }
            }, onCancel: {
                flag.cancel()
                marker.markTerminal()
                Task { await self.failRequest(
                    envelope.id, marker: marker, error: WorkServiceTransportError.canceled) }
            })
        } catch {
            throw error
        }
        let response = try WorkServiceTransportCodec.decodeResponse(raw)
        try WorkServiceTransportCodec.validateResponseSemantics(
            response, operation: envelope.operation)
        try WorkServiceTransportCodec.validateResponseCorrelation(
            response, request: envelope, expectedHostInstance: handshakeResponse?.hostInstance)
        guard response.ok else {
            guard let error = response.error else { throw WorkServiceTransportError.invalidResponse }
            throw WorkServiceTransportError.remote(code: error.code, detail: error.detail)
        }
        guard let data = response.data else { throw WorkServiceTransportError.invalidResponse }
        do {
            return try JSONDecoder().decode(Resp.self, from: JSONEncoder().encode(data))
        } catch {
            // A frame can satisfy the generic JSON/shape checks while still failing the exact
            // operation's Codable contract. Treat that as a protocol violation and fence this
            // connection before a later response can be mis-associated with the wrong request.
            closeTransport(WorkServiceTransportError.invalidResponse)
            throw WorkServiceTransportError.invalidResponse
        }
    }

    private func nextID() -> String {
        nextRequestID = nextRequestID == Int.max ? 0 : nextRequestID + 1
        return "ws-\(nextRequestID)"
    }

    private func receive(_ line: Data, generation: UInt64) {
        guard connected, activeConnectionGeneration == generation else { return }
        do {
            let response = try WorkServiceTransportCodec.decodeResponse(line)
            guard let request = pending[response.id] else {
                if lateResponseTombstones.contains(response.id) {
                    // A timeout/cancellation is local to the request.  Its eventual response is
                    // harmless and must not tear down a connection that may carry other GUIs'
                    // work; consume the tombstone once the late frame arrives.
                    lateResponseTombstones.remove(response.id)
                    lateResponseOrder.removeAll { $0 == response.id }
                } else if completedResponseIDs.contains(response.id) {
                    closeTransport(WorkServiceTransportError.duplicateResponseID)
                } else {
                    closeTransport(WorkServiceTransportError.invalidResponse)
                }
                return
            }
            if request.marker.isTerminal {
                pending.removeValue(forKey: response.id)
                rememberLateResponse(response.id)
                request.continuation.finish(throwing: WorkServiceTransportError.canceled)
                return
            }
            try WorkServiceTransportCodec.validateResponseSemantics(
                response, operation: request.operation)
            try WorkServiceTransportCodec.validateResponseCorrelation(
                response, request: request.request,
                expectedHostInstance: handshakeResponse?.hostInstance)
            pending.removeValue(forKey: response.id)
            _ = request.marker.markTerminal()
            rememberCompleted(response.id)
            request.continuation.yield(line)
            request.continuation.finish()
        } catch {
            closeTransport(error)
        }
    }

    private func rememberCompleted(_ id: String) {
        guard completedResponseIDs.insert(id).inserted else { return }
        completedResponseOrder.append(id)
        while completedResponseOrder.count > 256 {
            let old = completedResponseOrder.removeFirst()
            completedResponseIDs.remove(old)
        }
    }

    private func rememberLateResponse(_ id: String) {
        guard lateResponseTombstones.insert(id).inserted else { return }
        lateResponseOrder.append(id)
        while lateResponseOrder.count > 1_024 {
            let old = lateResponseOrder.removeFirst()
            lateResponseTombstones.remove(old)
        }
    }

    private func receiveOverflow(generation: UInt64) {
        guard connected, activeConnectionGeneration == generation else { return }
        closeTransport(WorkServiceTransportError.frameTooLarge(
            bytes: maxFrameBytes + 1, limit: maxFrameBytes))
    }

    private func receiveOverload(generation: UInt64) {
        guard connected, activeConnectionGeneration == generation else { return }
        closeTransport(WorkServiceTransportError.tooManyPendingRequests)
    }

    private func transportClosed(generation: UInt64) {
        guard connected, activeConnectionGeneration == generation else { return }
        closeTransport(WorkServiceTransportError.disconnected)
    }

    private func failRequest(
        _ id: String, marker: WorkServiceTransportRequestMarker, error: Error
    ) {
        guard let request = pending[id], request.marker === marker else { return }
        pending.removeValue(forKey: id)
        _ = request.marker.markTerminal()
        rememberLateResponse(id)
        request.continuation.finish(throwing: error)
    }

    private func closeTransport(_ error: Error) {
        connected = false
        handshakeResponse = nil
        activeConnectionGeneration = nil
        inputPump?.finish()
        inputPump = nil
        socket?.close()
        socket = nil
        let transportError: Error
        if let error = error as? WorkServiceTransportError {
            transportError = error
        } else {
            transportError = WorkServiceTransportError.disconnected
        }
        for (_, request) in pending {
            _ = request.marker.markTerminal()
            request.continuation.finish(throwing: transportError)
        }
        pending.removeAll()
    }
}

// MARK: - Diagnostics

private enum WorkServiceTransportText {
    static func bound(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.utf8.count <= WorkServiceBounds.maxDiagnosticCharacters
            ? value : String(decoding: value.utf8.prefix(WorkServiceBounds.maxDiagnosticCharacters), as: UTF8.self)
    }

    static func validIdentity(_ client: ClientRef) -> Bool {
        !client.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && client.clientID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
    }

    static func error(for error: Error)
        -> (WorkServiceTransportErrorCode, String?) {
        if let error = error as? WorkServiceTransportError {
            switch error {
            case .invalidEndpoint: return (.invalidRequest, "invalid transport endpoint")
            case .endpointOccupied: return (.invalidRequest, "socket endpoint is occupied")
            case .notConnected: return (.transportClosed, "client is not connected")
            case .alreadyConnected: return (.invalidRequest, "client is already connected")
            case .disconnected: return (.transportClosed, "transport disconnected")
            case .frameTooLarge: return (.frameTooLarge, "frame exceeded the transport bound")
            case .invalidFrame: return (.invalidFrame, "frame was not valid")
            case .invalidResponse: return (.invalidFrame, "response was not valid")
            case .remote(let code, let detail):
                return code == .internalError
                    ? (.internalError, "internal service error")
                    : (code, bound(detail))
            case .duplicateResponseID: return (.invalidFrame, "duplicate response identity")
            case .tooManyPendingRequests: return (.invalidRequest, "too many pending requests")
            case .timedOut: return (.transportClosed, "request timed out")
            case .canceled: return (.transportClosed, "request was canceled")
            case .writeFailed: return (.transportClosed, "transport write failed")
            }
        }
        switch error {
        case WorkServiceProtocolError.unsupportedVersion(let version):
            return (.unsupportedVersion, "unsupported protocol version \(version)")
        case WorkServiceProtocolError.invalidRequest(let detail):
            return (.invalidRequest, bound(detail))
        case WorkServiceProtocolError.hostUnavailable:
            return (.serviceUnavailable, "Work Host is unavailable")
        case WorkServiceProtocolError.workNotFound:
            return (.workNotFound, "Work was not found")
        case WorkServiceProtocolError.journalMismatch:
            return (.journalMismatch, "journal identity does not match Work")
        case WorkServiceProtocolError.attachmentNotFound:
            return (.attachmentNotFound, "attachment was not found")
        case WorkServiceProtocolError.capabilityDenied:
            return (.capabilityDenied, "capability was not granted")
        case WorkServiceProtocolError.artifactNotFound:
            return (.artifactNotFound, "artifact was not found")
        case WorkServiceProtocolError.eventPageCannotProgress(
            let requiredBytes, let maximumBytes):
            return (
                .eventPageCannotProgress,
                "next canonical event requires \(requiredBytes) bytes; page limit is \(maximumBytes)")
        case WorkServiceProtocolError.staleCursor:
            return (.staleCursor, "cursor is stale")
        case WorkServiceProtocolError.sourceIncomplete:
            return (.sourceIncomplete, "source is incomplete")
        default:
            // Never serialize arbitrary Error descriptions: providers and Python exceptions can
            // include credentials, paths, prompts, or socket details.  The typed code is the
            // durable evidence; this generic text is deliberately non-diagnostic.
            return (.internalError, "internal service error")
        }
    }
}
