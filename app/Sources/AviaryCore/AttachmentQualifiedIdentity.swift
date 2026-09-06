import Foundation

private struct AttachmentQualifiedCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func attachmentQualifiedKeys(
    from decoder: Decoder
) throws -> Set<String> {
    let container = try decoder.container(keyedBy: AttachmentQualifiedCodingKey.self)
    return Set(container.allKeys.map(\.stringValue))
}

/// The exact relationship between one Work and one Session.
///
/// A Work can host several independent Sessions.  The Session journal and attachment identity
/// are part of the key so callers cannot accidentally collapse those projections by Work id.
public struct WorkSessionKey: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let work: WorkRef
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef

    public init?(
        work: WorkRef,
        session: SessionRef,
        sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef
    ) {
        guard Self.validIdentity(work.workHostID),
              Self.validIdentity(work.workID),
              Self.validIdentity(session.sessionID),
              Self.validIdentity(sessionJournal.journalID),
              Self.validIdentity(sessionJournal.authority.authorityID),
              sessionJournal.owner == .session(session),
              sessionJournal.authority.authorityID == work.workHostID,
              Self.validIdentity(sessionAttachment.attachmentID) else { return nil }
        self.schemaVersion = Self.schemaVersion
        self.work = work
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
    }

    /// The same invariant used by construction, exposed for persistence boundaries that receive
    /// values from older or manually decoded envelopes.
    public var isValid: Bool {
        Self.validIdentity(work.workHostID)
            && Self.validIdentity(work.workID)
            && Self.validIdentity(session.sessionID)
            && Self.validIdentity(sessionJournal.journalID)
            && Self.validIdentity(sessionJournal.authority.authorityID)
            && sessionJournal.owner == .session(session)
            && sessionJournal.authority.authorityID == work.workHostID
            && Self.validIdentity(sessionAttachment.attachmentID)
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, work, session, sessionJournal, sessionAttachment
    }

    public init(from decoder: Decoder) throws {
        guard try attachmentQualifiedKeys(from: decoder) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unknown or missing WorkSessionKey fields"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "unsupported WorkSessionKey schema")
        }
        let work = try container.decode(WorkRef.self, forKey: .work)
        let session = try container.decode(SessionRef.self, forKey: .session)
        let sessionJournal = try container.decode(JournalRef.self, forKey: .sessionJournal)
        let sessionAttachment = try container.decode(
            SessionAttachmentRef.self, forKey: .sessionAttachment)
        guard let value = Self(
            work: work, session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionJournal, in: container,
                debugDescription: "invalid attachment-qualified Session identity")
        }
        self = value
    }
}

/// The exact durable identity of one client attachment to one Work/Session relationship.
public struct ServiceAttachmentKey: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let client: ClientRef
    public let clientAttachment: ClientAttachmentRef
    public let workSession: WorkSessionKey

    public init?(
        client: ClientRef,
        clientAttachment: ClientAttachmentRef,
        workSession: WorkSessionKey
    ) {
        guard Self.validIdentity(client.clientID), workSession.isValid,
              Self.validIdentity(clientAttachment.attachmentID) else { return nil }
        self.schemaVersion = Self.schemaVersion
        self.client = client
        self.clientAttachment = clientAttachment
        self.workSession = workSession
    }

    public init?(
        client: ClientRef,
        clientAttachment: ClientAttachmentRef,
        work: WorkRef,
        session: SessionRef?,
        sessionJournal: JournalRef?,
        sessionAttachment: SessionAttachmentRef?
    ) {
        guard let session, let sessionJournal, let sessionAttachment else { return nil }
        guard let workSession = WorkSessionKey(
            work: work, session: session, sessionJournal: sessionJournal,
            sessionAttachment: sessionAttachment) else { return nil }
        self.init(
            client: client, clientAttachment: clientAttachment,
            workSession: workSession)
    }

    public init?(work: WorkRef, attachment: WorkServiceClientAttachment) {
        self.init(
            client: attachment.client, clientAttachment: attachment.attachment,
            work: work, session: attachment.session,
            sessionJournal: attachment.sessionJournal,
            sessionAttachment: attachment.sessionAttachment)
    }

    /// Exposed for persistence boundaries that validate a key before hashing or accepting it.
    public var isValid: Bool {
        Self.validIdentity(client.clientID)
            && Self.validIdentity(clientAttachment.attachmentID)
            && workSession.isValid
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, client, clientAttachment, workSession
    }

    public init(from decoder: Decoder) throws {
        guard try attachmentQualifiedKeys(from: decoder) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unknown or missing ServiceAttachmentKey fields"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "unsupported ServiceAttachmentKey schema")
        }
        let client = try container.decode(ClientRef.self, forKey: .client)
        let clientAttachment = try container.decode(
            ClientAttachmentRef.self, forKey: .clientAttachment)
        let workSession = try container.decode(WorkSessionKey.self, forKey: .workSession)
        guard let value = Self(
            client: client, clientAttachment: clientAttachment, workSession: workSession) else {
            throw DecodingError.dataCorruptedError(
                forKey: .workSession, in: container,
                debugDescription: "invalid service attachment identity")
        }
        self = value
    }
}

/// The target identity for a client Attach mutation.
///
/// The target Session attachment is deliberately carried independently of any client attachment:
/// a new client attachment is minted for this exact existing relationship by the host.
public struct AttachTargetKey: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let client: ClientRef
    public let workSession: WorkSessionKey

    public init?(
        client: ClientRef,
        workSession: WorkSessionKey
    ) {
        guard Self.validIdentity(client.clientID), workSession.isValid else { return nil }
        self.schemaVersion = Self.schemaVersion
        self.client = client
        self.workSession = workSession
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, client, workSession
    }

    public init(from decoder: Decoder) throws {
        guard try attachmentQualifiedKeys(from: decoder) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unknown or missing AttachTargetKey fields"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: container,
                debugDescription: "unsupported AttachTargetKey schema")
        }
        let client = try container.decode(ClientRef.self, forKey: .client)
        let workSession = try container.decode(WorkSessionKey.self, forKey: .workSession)
        guard let value = Self(client: client, workSession: workSession) else {
            throw DecodingError.dataCorruptedError(
                forKey: .workSession, in: container,
                debugDescription: "invalid Attach target identity")
        }
        self = value
    }
}

public extension WorkServiceWorkDescriptor {
    /// Canonical Session relationships that are safe to offer as Attach targets. A duplicate
    /// Session-attachment id is withheld even when one copy is detached: selecting either copy
    /// would otherwise make the target depend on descriptor ordering.
    var attachmentQualifiedSessionTargets: [WorkSessionKey] {
        var targets: [WorkSessionKey] = []
        let grouped = Dictionary(grouping: sessionAttachments) {
            $0.sessionAttachment.attachmentID
        }
        for relationship in sessionAttachments {
            let id = relationship.sessionAttachment.attachmentID
            guard grouped[id]?.count == 1, relationship.isAttached else { continue }
            guard let target = WorkSessionKey(
                work: work, session: relationship.session,
                sessionJournal: relationship.sessionJournal,
                sessionAttachment: relationship.sessionAttachment) else { continue }
            targets.append(target)
        }
        return targets
    }

    /// Resolve one exact target, failing closed on duplicate/conflicting relationship facts.
    func exactAttachmentQualifiedSessionTarget(
        _ target: SessionAttachmentRef
    ) -> WorkSessionKey? {
        let matches = attachmentQualifiedSessionTargets.filter {
            $0.sessionAttachment == target
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
