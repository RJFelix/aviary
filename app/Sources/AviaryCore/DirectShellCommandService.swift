import Foundation

private enum DirectShellServiceText {
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
    }

    static func bound(_ value: String?) -> String? {
        guard let value else { return nil }
        guard value.utf8.count > WorkServiceBounds.maxDiagnosticCharacters else { return value }
        return String(
            decoding: value.utf8.prefix(WorkServiceBounds.maxDiagnosticCharacters), as: UTF8.self)
    }
}

/// Canonical facts emitted by the host for one settled direct-shell result.  The journal reader
/// and cold-resume reducer both consume untrusted canonical bytes, so neither may reconstruct a
/// descriptor from only the body reference and silently discard the event's advertised metadata.
enum DirectShellCommandCanonicalValidation {
    static let artifactLabel = "Command output"

    static func resultDigest(_ result: DirectShellCommandResult) -> String? {
        guard let body = try? DirectShellJournalFormat.encoded(result) else { return nil }
        return "sha256:" + AviarySHA256.hash(data: body).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func artifactPayloadIsCanonical(
        _ value: JSONValue,
        body: TimelineBodyReference,
        result: DirectShellCommandResult,
        action: ActionRef
    ) -> Bool {
        guard let payload = value.objectValue,
              let digest = resultDigest(result),
              let encoded = try? DirectShellJournalFormat.encoded(result),
              let artifactID = payload["artifact_id"]?.stringValue,
              let label = payload["label"]?.stringValue,
              let available = payload["available"]?.boolValue,
              let mediaType = payload["media_type"]?.stringValue,
              let byteCount = payload["byte_count"]?.intValue,
              let payloadDigest = payload["digest"]?.stringValue,
              let encodedBody: TimelineBodyReference = payload["body_reference"].flatMap({
                  decodeTimelineValue($0)
              }) else { return false }
        guard Set(payload.keys) == Set([
            "artifact_id", "label", "available", "media_type", "byte_count", "digest",
            "body_reference"
        ]),
            artifactID == action.actionID + "-output",
            label == artifactLabel,
            available,
            mediaType == DirectShellJournalFormat.resultMediaType,
            byteCount == encoded.count,
            payloadDigest == digest,
            body == encodedBody,
            body.referenceID == digest,
            body.mediaType == DirectShellJournalFormat.resultMediaType,
            body.byteCount == encoded.count,
            body.digest == digest else { return false }
        return true
    }

    /// A direct-shell result has one truthful action mapping.  Keeping this explicit prevents a
    /// forged terminal outcome from turning a timeout into cancellation or changing retry policy.
    static func outcome(for status: DirectShellCommandTerminalStatus)
        -> (state: ActionExecutionState, failureKind: ActionFailureKind?) {
        switch status {
        case .exited:
            return (.succeeded, nil)
        case .nonzero:
            return (.failed, .task)
        case .signaled:
            return (.failed, .infrastructure)
        case .canceled:
            return (.canceled, .cancellation)
        case .timedOut:
            return (.failed, .timeout)
        case .invalidRequest:
            return (.failed, .policy)
        case .launchFailed:
            return (.failed, .infrastructure)
        case .workerFailed:
            return (.indeterminateEffect, .indeterminateEffect)
        }
    }

    static func outcomeMatches(
        _ status: DirectShellCommandTerminalStatus,
        state: ActionExecutionState,
        failureKind: ActionFailureKind?
    ) -> Bool {
        if case .exited(let code) = status, code != 0 { return false }
        let expected = outcome(for: status)
        return expected.state == state && expected.failureKind == failureKind
    }
}

/// The Work-service operation for direct shell execution. Direct shell is deliberately a
/// separate endpoint from model-input commands: it has its own capability and durable result.
public enum WorkServiceDirectShellOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case run
    case stop
    case dismiss
    case inspect
}

public enum WorkServiceDirectShellDisposition: String, Codable, Hashable, Sendable {
    case accepted
    case duplicate
    case rejected
    /// The service cannot authoritatively inspect this command from its current source.
    case unavailable
}

public enum WorkServiceDirectShellBounds {
    public static let maximumEntries = 8
    public static let maximumTimeout: TimeInterval = 7 * 24 * 60 * 60
}

/// One identity-qualified direct-shell request. The command reference carries the exact client,
/// Session attachment, and causal Work cursor; none may be inferred by the host.
public struct WorkServiceDirectShellRequest: Codable, Equatable, Sendable {
    public let work: WorkRef
    public let journal: JournalRef
    public let attachment: ClientAttachmentRef
    public let command: CommandRef
    public let causalWorkCursor: JournalCursor
    public let run: RunRef
    public let operation: WorkServiceDirectShellOperation
    public let language: DirectShellLanguage?
    public let source: Data?
    public let durationLimitSeconds: TimeInterval?
    public let action: ActionRef?

    public init(
        work: WorkRef,
        journal: JournalRef,
        attachment: ClientAttachmentRef,
        command: CommandRef,
        causalWorkCursor: JournalCursor,
        run: RunRef,
        operation: WorkServiceDirectShellOperation,
        language: DirectShellLanguage? = nil,
        source: Data? = nil,
        durationLimitSeconds: TimeInterval? = nil,
        action: ActionRef? = nil
    ) {
        self.work = work
        self.journal = journal
        self.attachment = attachment
        self.command = command
        self.causalWorkCursor = causalWorkCursor
        self.run = run
        self.operation = operation
        self.language = language
        self.source = source
        self.durationLimitSeconds = durationLimitSeconds
        self.action = action
    }

    public func validate() throws {
        try Self.requireIdentity(work.workHostID, "work host")
        try Self.requireIdentity(work.workID, "work")
        guard journal.kind == .work, journal.owner == .work(work),
              journal.authority.authorityID == work.workHostID else {
            throw WorkServiceProtocolError.invalidRequest("direct shell journal does not own Work")
        }
        try Self.requireIdentity(journal.journalID, "journal")
        try Self.requireIdentity(attachment.attachmentID, "client attachment")
        try Self.requireIdentity(command.commandID, "command")
        guard let client = command.client else {
            throw WorkServiceProtocolError.invalidRequest("direct shell command requires a client")
        }
        try Self.requireIdentity(client.clientID, "client")
        guard let sessionAttachment = command.sessionAttachment else {
            throw WorkServiceProtocolError.invalidRequest(
                "direct shell command requires a Session attachment")
        }
        try Self.requireIdentity(sessionAttachment.attachmentID, "Session attachment")
        guard command.causalCursor == causalWorkCursor else {
            throw WorkServiceProtocolError.invalidRequest(
                "direct shell command and request cursors differ")
        }
        try Self.validate(cursor: causalWorkCursor, journal: journal)
        try Self.requireIdentity(run.runID, "Run")

        switch operation {
        case .run:
            guard action == nil, let source, language != nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "direct shell Run requires language and source, without a target Action")
            }
            try Self.validateSource(source)
            try Self.validate(timeout: durationLimitSeconds)
        case .stop, .dismiss:
            guard let action, language == nil, source == nil, durationLimitSeconds == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "direct shell Stop/Dismiss requires only a target Action")
            }
            try Self.requireIdentity(action.actionID, "Action")
        case .inspect:
            guard language == nil, source == nil, durationLimitSeconds == nil else {
                throw WorkServiceProtocolError.invalidRequest(
                    "direct shell Inspect cannot include execution input")
            }
            if let action { try Self.requireIdentity(action.actionID, "Action") }
        }
    }

    static func validateSource(_ source: Data) throws {
        guard !source.isEmpty,
              source.count <= DirectShellCommandRequest.maximumSourceBytes,
              !source.contains(0),
              String(data: source, encoding: .utf8) != nil else {
            throw WorkServiceProtocolError.invalidRequest(
                "direct shell source must be nonempty NUL-free UTF-8 within the byte limit")
        }
    }

    static func validate(timeout: TimeInterval?) throws {
        guard let timeout else { return }
        guard timeout.isFinite, timeout > 0, timeout <= WorkServiceDirectShellBounds.maximumTimeout
        else {
            throw WorkServiceProtocolError.invalidRequest("direct shell timeout is out of bounds")
        }
    }

    static func requireIdentity(_ value: String, _ name: String) throws {
        guard DirectShellServiceText.valid(value),
              value.utf8.count <= WorkServiceBounds.maxIdentityCharacters else {
            throw WorkServiceProtocolError.invalidRequest("invalid direct shell \(name) identity")
        }
    }

    static func validate(cursor: JournalCursor, journal: JournalRef) throws {
        guard cursor.journal == journal, cursor.sequence > 0 else {
            throw WorkServiceProtocolError.invalidRequest("invalid direct shell Work cursor")
        }
        if let eventID = cursor.eventID { try requireIdentity(eventID, "cursor event") }
    }
}

/// Bounded direct-shell state returned by the authoritative hosted Work.
public struct WorkServiceDirectShellEntry: Codable, Equatable, Sendable {
    public let command: CommandRef
    public let session: SessionRef
    public let sessionAttachment: SessionAttachmentRef
    public let run: RunRef
    public let action: ActionRef
    public let language: DirectShellLanguage
    public let source: Data
    public let timeout: TimeInterval?
    public let state: ActionExecutionState
    public let result: DirectShellCommandResult?
    public let artifact: WorkServiceArtifactDescriptor?
    public let pendingContext: Bool

    public init(
        command: CommandRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        run: RunRef,
        action: ActionRef,
        language: DirectShellLanguage,
        source: Data,
        timeout: TimeInterval? = nil,
        state: ActionExecutionState,
        result: DirectShellCommandResult? = nil,
        artifact: WorkServiceArtifactDescriptor? = nil,
        pendingContext: Bool = false
    ) {
        self.command = command
        self.session = session
        self.sessionAttachment = sessionAttachment
        self.run = run
        self.action = action
        self.language = language
        self.source = source
        self.timeout = timeout
        self.state = state
        self.result = result
        self.artifact = artifact
        self.pendingContext = pendingContext
    }

    public func validate(work: WorkRef, journal: JournalRef) throws {
        try WorkServiceDirectShellRequest.requireIdentity(command.commandID, "entry command")
        guard command.client != nil, command.sessionAttachment == sessionAttachment,
              let causalCursor = command.causalCursor else {
            throw WorkServiceProtocolError.invalidRequest(
                "direct shell entry lacks its qualified command identity")
        }
        try WorkServiceDirectShellRequest.validate(cursor: causalCursor, journal: journal)
        try WorkServiceDirectShellRequest.requireIdentity(session.sessionID, "entry Session")
        try WorkServiceDirectShellRequest.requireIdentity(
            sessionAttachment.attachmentID, "entry Session attachment")
        try WorkServiceDirectShellRequest.requireIdentity(run.runID, "entry Run")
        try WorkServiceDirectShellRequest.requireIdentity(action.actionID, "entry Action")
        try WorkServiceDirectShellRequest.validateSource(source)
        try WorkServiceDirectShellRequest.validate(timeout: timeout)

        if let result {
            try result.validate()
            guard result.commandID == command.commandID,
                  result.actionID == action.actionID,
                  result.language == language,
                  result.source == source,
                  state == DirectShellCommandCanonicalValidation.outcome(for: result.status).state else {
                throw WorkServiceProtocolError.invalidRequest(
                    "direct shell result does not match its durable entry")
            }
            guard let artifact else {
                throw WorkServiceProtocolError.invalidRequest(
                    "terminal direct shell result lacks its artifact")
            }
            let encoded = try DirectShellJournalFormat.encoded(result)
            let digest = Self.digest(encoded)
            guard artifact.mediaType == DirectShellJournalFormat.resultMediaType,
                  artifact.artifactID == action.actionID + "-output",
                  artifact.label == DirectShellCommandCanonicalValidation.artifactLabel,
                  artifact.available,
                  let reference = artifact.bodyReference,
                  reference.authority == journal,
                  reference.referenceID == digest,
                  reference.mediaType == DirectShellJournalFormat.resultMediaType,
                  reference.byteCount == encoded.count,
                  reference.digest == digest,
                  artifact.byteCount == encoded.count,
                  artifact.digest == digest else {
                throw WorkServiceProtocolError.invalidRequest(
                    "direct shell result bytes do not match the retained artifact")
            }
        }
        if let artifact {
            guard artifact.work == work, artifact.session == session,
                  artifact.sessionAttachment == sessionAttachment,
                  artifact.run == run, artifact.action == action,
                  artifact.sourceEvent.journal == journal,
                  artifact.artifactID == action.actionID + "-output",
                  artifact.label == DirectShellCommandCanonicalValidation.artifactLabel else {
                throw WorkServiceProtocolError.invalidRequest(
                    "direct shell artifact does not match its durable entry")
            }
        }
        guard !state.isTerminal || artifact == nil || result != nil else {
            throw WorkServiceProtocolError.invalidRequest(
                "terminal direct shell artifact lacks its decoded result")
        }
        guard !pendingContext || (state.isTerminal && result != nil && artifact != nil) else {
            throw WorkServiceProtocolError.invalidRequest(
                "pending direct shell context lacks a terminal result artifact")
        }
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + AviarySHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

/// Hosted Work returns journal-derived state without inventing transport identity or authority.
public struct HostedDirectShellResponse: Sendable {
    public let disposition: WorkServiceDirectShellDisposition
    public let entries: [WorkServiceDirectShellEntry]
    public let resultingWorkCursor: JournalCursor
    public let diagnostic: String?

    public init(
        disposition: WorkServiceDirectShellDisposition,
        entries: [WorkServiceDirectShellEntry],
        resultingWorkCursor: JournalCursor,
        diagnostic: String? = nil
    ) {
        self.disposition = disposition
        self.entries = entries
        self.resultingWorkCursor = resultingWorkCursor
        self.diagnostic = DirectShellServiceText.bound(diagnostic)
    }
}

/// Transport response wrapped by the Work service after exact ownership and capability checks.
public struct WorkServiceDirectShellResponse: Codable, Equatable, Sendable {
    public let work: WorkRef
    public let operation: WorkServiceDirectShellOperation
    public let commandID: String
    public let host: WorkHostInstanceRef
    public let causalWorkCursor: JournalCursor
    public let resultingWorkCursor: JournalCursor
    public let authorization: WorkServiceAuthorizationOutcome
    public let disposition: WorkServiceDirectShellDisposition
    public let entries: [WorkServiceDirectShellEntry]
    public let diagnostic: String?

    public init(
        work: WorkRef,
        operation: WorkServiceDirectShellOperation,
        commandID: String,
        host: WorkHostInstanceRef,
        causalWorkCursor: JournalCursor,
        resultingWorkCursor: JournalCursor,
        authorization: WorkServiceAuthorizationOutcome,
        disposition: WorkServiceDirectShellDisposition,
        entries: [WorkServiceDirectShellEntry],
        diagnostic: String? = nil
    ) {
        self.work = work
        self.operation = operation
        self.commandID = commandID
        self.host = host
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.authorization = authorization
        self.disposition = disposition
        self.entries = entries
        self.diagnostic = DirectShellServiceText.bound(diagnostic)
    }

    public func validate(for request: WorkServiceDirectShellRequest) throws {
        try request.validate()
        guard work == request.work, operation == request.operation,
              commandID == request.command.commandID,
              host.host == WorkHostRef(request.work.workHostID),
              causalWorkCursor == request.causalWorkCursor,
              resultingWorkCursor.journal == request.journal,
              resultingWorkCursor.sequence >= request.causalWorkCursor.sequence,
              entries.count <= WorkServiceDirectShellBounds.maximumEntries else {
            throw WorkServiceProtocolError.invalidRequest(
                "direct shell response does not correlate to its request")
        }
        let required: Set<WorkServiceCapability> = request.operation == .inspect
            ? [.observe, .inspectArtifacts] : [.control, .directShell]
        guard required.allSatisfy(authorization.allows) else {
            throw WorkServiceProtocolError.invalidRequest(
                "direct shell response lacks its required authorization")
        }
        guard disposition != .unavailable || (entries.isEmpty && diagnostic != nil) else {
            throw WorkServiceProtocolError.invalidRequest(
                "unavailable direct shell state must be explicit")
        }
        guard request.operation == .inspect || disposition != .unavailable else {
            throw WorkServiceProtocolError.invalidRequest(
                "a direct shell mutation cannot report unavailable as success")
        }
        for entry in entries {
            try entry.validate(work: work, journal: request.journal)
            guard entry.sessionAttachment == request.command.sessionAttachment else {
                throw WorkServiceProtocolError.invalidRequest(
                    "direct shell entry does not match the request binding")
            }
        }
        guard disposition == .unavailable || disposition == .rejected
                || operationHasCorrelatedEntry(request) else {
            throw WorkServiceProtocolError.invalidRequest(
                "direct shell response omits the requested command state")
        }
    }

    private func operationHasCorrelatedEntry(_ request: WorkServiceDirectShellRequest) -> Bool {
        switch request.operation {
        case .run:
            guard let client = request.command.client,
                  let language = request.language,
                  let source = request.source else { return false }
            let qualifiedID = WorkServiceCommandLedgerIdentity.commandID(
                client: client, commandID: request.command.commandID)
            let expectedAction = DirectShellJournalFormat.action(commandID: qualifiedID)
            return entries.filter {
                $0.command.commandID == qualifiedID
                    && $0.command.client == client
                    && $0.command.causalCursor == request.causalWorkCursor
                    && $0.run == request.run
                    && $0.action == expectedAction
                    && $0.language == language
                    && $0.source == source
                    && $0.timeout == request.durationLimitSeconds
            }.count == 1
        case .stop, .dismiss:
            guard let action = request.action else { return false }
            return entries.contains { $0.action == action }
        case .inspect:
            guard let action = request.action else { return true }
            return entries.contains { $0.action == action }
        }
    }
}
