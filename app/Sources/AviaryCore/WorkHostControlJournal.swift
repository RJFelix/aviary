import CryptoKit
import Darwin
import Foundation

private enum WorkHostControlLimits {
    static let maxIdentityCharacters = 256
    static let maxIdentityMintAttempts = 32
    static let maxCapabilities = 64
    static let maxCapabilityCharacters = 128
    static let maxDigestCharacters = 80
    static let maxTargetJournalBytes = 64 * 1024 * 1024
    static let maxControlJournalBytes = 64 * 1024 * 1024
    static let maxDurabilitySealBytes = 16 * 1024
}

/// Control-plane event names that are intentionally kept here until the general Timeline event
/// catalog has a first-class Work Host transaction namespace. They are still ordinary Timeline
/// events: unknown reducers retain them, while this reducer understands the current schema.
public enum WorkHostControlEventType {
    public static let creationReserved = "creation.reserved"
    public static let workRegistered = "work.registered"
}

/// Opaque identities minted by a Work Host before either source journal is created. Keeping the
/// three values together makes the reservation atomic from the caller's perspective and gives
/// tests a deterministic identity-minter seam without allowing a client to select identities.
public struct WorkHostControlMintedIdentity: Codable, Hashable, Sendable {
    public let workID: String
    public let sessionID: String
    public let sessionAttachmentID: String

    public init(workID: String, sessionID: String, sessionAttachmentID: String) {
        self.workID = workID
        self.sessionID = sessionID
        self.sessionAttachmentID = sessionAttachmentID
    }
}

private func controlBoundedIdentity(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && value.utf8.count <= WorkHostControlLimits.maxIdentityCharacters
}

private func controlBoundedDigest(_ value: String) -> Bool {
    guard value.utf8.count <= WorkHostControlLimits.maxDigestCharacters else { return false }
    let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].lowercased() == "sha256",
          parts[1].utf8.count == 64 else { return false }
    return parts[1].unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }
}

private func controlBoundedCursor(_ cursor: JournalCursor) -> Bool {
    guard controlBoundedIdentity(cursor.journal.journalID),
          controlBoundedIdentity(cursor.journal.authority.authorityID),
          cursor.sequence >= 0, cursor.sequence < Int.max else { return false }
    switch cursor.journal.owner {
    case .work(let work):
        guard controlBoundedIdentity(work.workHostID), controlBoundedIdentity(work.workID) else {
            return false
        }
    case .session(let session):
        guard controlBoundedIdentity(session.sessionID) else { return false }
    case .workHost(let host):
        guard controlBoundedIdentity(host.workHostID) else { return false }
    }
    if cursor.sequence == 0 { return cursor.eventID == nil }
    return cursor.eventID.map(controlBoundedIdentity) ?? false
}

private func controlLengthPrefixedKey(_ client: ClientRef, commandID: String) -> String {
    "client:\(client.clientID.utf8.count):\(client.clientID)/command:\(commandID.utf8.count):\(commandID)"
}

private func controlSHA256(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct WorkHostControlDurabilitySeal: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let journal: JournalRef
    let cursor: JournalCursor
    let byteCount: Int
    let sha256: String
}

private struct WorkHostControlMutationIdentity: Codable {
    let type: String
    let work: WorkRef
    let workJournal: JournalRef
    let attachment: ClientAttachmentRef
    let client: ClientRef
    let session: SessionRef?
    let sessionJournal: JournalRef?
    let sessionAttachment: SessionAttachmentRef?
    let capabilities: [String]?
    let targetJournal: JournalRef?
    let targetCursor: JournalCursor?
    let causalControlCursor: JournalCursor
}

// MARK: - Durable creation transaction

/// The request identity for creating Work. Bodies are deliberately represented by canonical
/// digests only; a control journal never receives a prompt, cwd, credential, or other raw
/// configuration body.
public struct WorkHostControlCreationRequest: Codable, Hashable, Sendable {
    public let client: ClientRef
    public let command: CommandRef
    public let bodyDigest: String
    public let configurationDigest: String
    public let causalControlCursor: JournalCursor

    public init(
        client: ClientRef,
        commandID: String,
        bodyDigest: String,
        configurationDigest: String,
        causalControlCursor: JournalCursor
    ) {
        self.client = client
        self.command = CommandRef(
            commandID: commandID, client: client, causalCursor: causalControlCursor)
        self.bodyDigest = bodyDigest
        self.configurationDigest = configurationDigest
        self.causalControlCursor = causalControlCursor
    }

    public init(
        client: ClientRef,
        command: CommandRef,
        bodyDigest: String,
        configurationDigest: String,
        causalControlCursor: JournalCursor
    ) {
        self.client = client
        self.command = command
        self.bodyDigest = bodyDigest
        self.configurationDigest = configurationDigest
        self.causalControlCursor = causalControlCursor
    }

    public var key: String {
        controlLengthPrefixedKey(client, commandID: command.commandID)
    }
}

/// The host-minted identity reservation. This is durable before either execution journal is
/// created. `reservationEvent`/`reservationCursor` identify the control fact that can be used to
/// reconcile a lost create response.
public struct WorkHostControlCreationReservation: Codable, Hashable, Sendable {
    public let client: ClientRef
    public let command: CommandRef
    public let bodyDigest: String
    public let configurationDigest: String
    public let causalControlCursor: JournalCursor
    public let work: WorkRef
    public let session: SessionRef
    public let sessionAttachment: SessionAttachmentRef
    public let reservationEvent: EventRef
    public let reservationCursor: JournalCursor

    public init(
        client: ClientRef,
        command: CommandRef,
        bodyDigest: String,
        configurationDigest: String,
        causalControlCursor: JournalCursor,
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef,
        reservationEvent: EventRef,
        reservationCursor: JournalCursor
    ) {
        self.client = client
        self.command = command
        self.bodyDigest = bodyDigest
        self.configurationDigest = configurationDigest
        self.causalControlCursor = causalControlCursor
        self.work = work
        self.session = session
        self.sessionAttachment = sessionAttachment
        self.reservationEvent = reservationEvent
        self.reservationCursor = reservationCursor
    }

    public var key: String {
        controlLengthPrefixedKey(client, commandID: command.commandID)
    }
}

public struct WorkHostControlWorkRegistrationRequest: Codable, Hashable, Sendable {
    public let reservation: WorkHostControlCreationReservation
    public let workJournal: JournalRef
    public let sessionJournal: JournalRef
    public let workGenesisCursor: JournalCursor
    public let sessionGenesisCursor: JournalCursor
    public let causalControlCursor: JournalCursor

    public init(
        reservation: WorkHostControlCreationReservation,
        workJournal: JournalRef,
        sessionJournal: JournalRef,
        workGenesisCursor: JournalCursor,
        sessionGenesisCursor: JournalCursor,
        causalControlCursor: JournalCursor
    ) {
        self.reservation = reservation
        self.workJournal = workJournal
        self.sessionJournal = sessionJournal
        self.workGenesisCursor = workGenesisCursor
        self.sessionGenesisCursor = sessionGenesisCursor
        self.causalControlCursor = causalControlCursor
    }
}

/// The exact source-journal identities and genesis cursors supplied after creation's Session and
/// Work journals exist. Genesis cursors are the cursors returned by those journal owners, not
/// fabricated control cursors. This control record is recoverable if the create response is lost,
/// but it does not by itself prove that either source journal still exists: readers must supply
/// independent, canonical source-presence evidence before projecting it as registered.
public struct WorkHostControlWorkRegistration: Codable, Hashable, Sendable {
    public let reservation: WorkHostControlCreationReservation
    public let workJournal: JournalRef
    public let sessionJournal: JournalRef
    public let workGenesisCursor: JournalCursor
    public let sessionGenesisCursor: JournalCursor
    public let causalControlCursor: JournalCursor
    public let registrationEvent: EventRef
    public let registrationCursor: JournalCursor

    public init(
        reservation: WorkHostControlCreationReservation,
        workJournal: JournalRef,
        sessionJournal: JournalRef,
        workGenesisCursor: JournalCursor,
        sessionGenesisCursor: JournalCursor,
        causalControlCursor: JournalCursor,
        registrationEvent: EventRef,
        registrationCursor: JournalCursor
    ) {
        self.reservation = reservation
        self.workJournal = workJournal
        self.sessionJournal = sessionJournal
        self.workGenesisCursor = workGenesisCursor
        self.sessionGenesisCursor = sessionGenesisCursor
        self.causalControlCursor = causalControlCursor
        self.registrationEvent = registrationEvent
        self.registrationCursor = registrationCursor
    }
}

/// A cold reader can supply source presence without exposing filesystem paths. `notObserved`
/// means the control journal alone is insufficient to make a claim; it is not an assertion that
/// the source journal is absent.
public enum WorkHostControlCreationSourcePresence: String, Codable, Hashable, Sendable {
    /// The reader has not supplied complete, authority-qualified source-journal evidence.
    case notObserved = "not_observed"
    /// Source presence was attempted but the source journals or their cursors could not be
    /// verified. This is distinct from `none`: absence itself is not proven.
    case unverified
    /// Neither source journal was observed at the reserved identities.
    case none
    /// Exactly one source journal was observed at its reserved identity and cursor.
    case workOnly = "work_only"
    case sessionOnly = "session_only"
    /// Both source journals were observed as complete canonical chains at their registered
    /// genesis cursors. This is a diagnostic projection hint only; it is never sufficient to
    /// make a registered creation reconstructable. Use the Work Host's fresh
    /// `verifiedCreationProjection` operation for that claim.
    case both
    /// Both source journals passed the Work Host's canonical source verifier for one exact
    /// registration. This status is emitted only by a fresh actor-owned verification, never
    /// accepted as proof when supplied to the projection hint overload.
    case verified
}

public enum WorkHostControlCreationSourceVerificationFailure: String, Codable, Hashable, Sendable {
    case controlJournalUnavailable = "control_journal_unavailable"
    case creationMissing = "creation_missing"
    case creationConflicted = "creation_conflicted"
    case registrationMissing = "registration_missing"
    case bothSourcesMissing = "both_sources_missing"
    case workSourceMissing = "work_source_missing"
    case sessionSourceMissing = "session_source_missing"
    case workSourceUnreadable = "work_source_unreadable"
    case sessionSourceUnreadable = "session_source_unreadable"
    case workSourceIncomplete = "work_source_incomplete"
    case sessionSourceIncomplete = "session_source_incomplete"
    case workSourceMismatch = "work_source_mismatch"
    case sessionSourceMismatch = "session_source_mismatch"
    case attachmentMirrorMismatch = "attachment_mirror_mismatch"
}

/// Result of observing the two source journals for one durable registration. Negative outcomes
/// are typed and bounded so missing/corrupt source files never collapse into a successful
/// registration claim and never expose a raw local path.
public struct WorkHostControlCreationSourceVerification: Hashable, Sendable {
    public let sourcePresence: WorkHostControlCreationSourcePresence
    public let failure: WorkHostControlCreationSourceVerificationFailure?
    /// Digests cover only the canonical bytes through each registration cursor. They are
    /// diagnostic measurements, not reusable proof: callers must ask the Work Host to perform a
    /// fresh verification before projecting a creation as registered.
    public let workSourceDigest: String?
    public let sessionSourceDigest: String?

    public var isVerified: Bool {
        sourcePresence == .verified && failure == nil
            && workSourceDigest != nil && sessionSourceDigest != nil
    }

    fileprivate init(
        sourcePresence: WorkHostControlCreationSourcePresence,
        failure: WorkHostControlCreationSourceVerificationFailure? = nil,
        workSourceDigest: String? = nil,
        sessionSourceDigest: String? = nil
    ) {
        self.sourcePresence = sourcePresence
        self.failure = failure
        self.workSourceDigest = workSourceDigest
        self.sessionSourceDigest = sessionSourceDigest
    }
}

/// The result of one fresh actor-owned source verification and projection. The projection and
/// typed evidence are returned together so a caller cannot retain a success token and later apply
/// it to a detached or stale snapshot after the source journals have changed.
public struct WorkHostControlCreationProjectionResult: Hashable, Sendable {
    public let projection: WorkHostControlCreationProjection?
    public let verification: WorkHostControlCreationSourceVerification

    fileprivate init(
        projection: WorkHostControlCreationProjection?,
        verification: WorkHostControlCreationSourceVerification
    ) {
        self.projection = projection
        self.verification = verification
    }
}

/// Explicit projection states for the crash windows around Create. In particular, `.registered`
/// includes the case where the host committed registration and lost the response; callers can
/// reconstruct the response from this record rather than treating response delivery as a source
/// journal fact.
public enum WorkHostControlCreationProjectionState: String, Codable, Hashable, Sendable {
    case reservationOnly = "reservation_only"
    case sourceIncomplete = "source_incomplete"
    case journalsUnregistered = "journals_unregistered"
    case registered
    case recoveryRequired = "recovery_required"
    case conflicted
}

public struct WorkHostControlCreationSnapshot: Codable, Hashable, Sendable {
    public let reservation: WorkHostControlCreationReservation
    public var registration: WorkHostControlWorkRegistration?
    public var isConflicted: Bool
    public var conflictEventRefs: [EventRef]

    public init(
        reservation: WorkHostControlCreationReservation,
        registration: WorkHostControlWorkRegistration? = nil,
        isConflicted: Bool = false,
        conflictEventRefs: [EventRef] = []
    ) {
        self.reservation = reservation
        self.registration = registration
        self.isConflicted = isConflicted
        self.conflictEventRefs = Array(conflictEventRefs.prefix(TimelineEvent.maxEvidenceLinks))
    }
}

public struct WorkHostControlCreationProjection: Codable, Hashable, Sendable {
    public let state: WorkHostControlCreationProjectionState
    public let sourcePresence: WorkHostControlCreationSourcePresence
    public let reservation: WorkHostControlCreationReservation
    public let registration: WorkHostControlWorkRegistration?
    /// True when the registration is durable and can reconstruct a lost response. It does not
    /// claim that a particular client received the response.
    public let responseIsReconstructable: Bool

    public init(
        state: WorkHostControlCreationProjectionState,
        sourcePresence: WorkHostControlCreationSourcePresence,
        reservation: WorkHostControlCreationReservation,
        registration: WorkHostControlWorkRegistration?,
        responseIsReconstructable: Bool
    ) {
        self.state = state
        self.sourcePresence = sourcePresence
        self.reservation = reservation
        self.registration = registration
        self.responseIsReconstructable = responseIsReconstructable
    }
}

// MARK: - Work Host control projection

/// The durable client relationship kept by a Work Host.
///
/// `isAttached` is an explicit durable detach state. It is deliberately not a transport
/// connectivity bit: a socket disappearing, a GUI being killed, or a device going offline does
/// not change this value. A later client can reconnect and observe the same attachment until an
/// explicit `client.detached` event is committed.
public struct WorkHostClientAttachmentSnapshot: Codable, Hashable, Sendable {
    public let attachment: ClientAttachmentRef
    public let client: ClientRef
    public let work: WorkRef
    public let workJournal: JournalRef
    public let session: SessionRef?
    public let sessionJournal: JournalRef?
    public let sessionAttachment: SessionAttachmentRef?
    public var capabilities: Set<String>
    public var isAttached: Bool
    public let attachedEvent: EventRef
    public var detachedEvent: EventRef?

    public init(
        attachment: ClientAttachmentRef,
        client: ClientRef,
        work: WorkRef,
        workJournal: JournalRef,
        session: SessionRef? = nil,
        sessionJournal: JournalRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil,
        capabilities: Set<String> = [],
        isAttached: Bool = true,
        attachedEvent: EventRef,
        detachedEvent: EventRef? = nil
    ) {
        self.attachment = attachment
        self.client = client
        self.work = work
        self.workJournal = workJournal
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.capabilities = capabilities
        self.isAttached = isAttached
        self.attachedEvent = attachedEvent
        self.detachedEvent = detachedEvent
    }
}

/// A client's durable acknowledgement that it has consumed a cursor in a target journal.
///
/// The acknowledgement lives in the Work Host control journal, but the cursor's `journal` is
/// the target journal itself. This lets a client acknowledge a Work or Session page without
/// advancing either journal's append cursor or mutating its immutable outcome.
public struct WorkHostReadAcknowledgementSnapshot: Codable, Hashable, Sendable {
    public let client: ClientRef
    public let attachment: ClientAttachmentRef
    public let work: WorkRef
    public let targetJournal: JournalRef
    public var cursor: JournalCursor
    public let acknowledgedEvent: EventRef

    public init(
        client: ClientRef,
        attachment: ClientAttachmentRef,
        work: WorkRef,
        targetJournal: JournalRef,
        cursor: JournalCursor,
        acknowledgedEvent: EventRef
    ) {
        self.client = client
        self.attachment = attachment
        self.work = work
        self.targetJournal = targetJournal
        self.cursor = cursor
        self.acknowledgedEvent = acknowledgedEvent
    }
}

/// Pure projection of a Work Host control journal.
///
/// This reducer never observes a socket, process, or GUI. In particular, reducing a prefix after
/// an unexpected transport disconnect leaves an attached client's durable state attached. Only a
/// committed explicit detach changes `isAttached`.
public struct WorkHostControlSnapshot: Codable, Hashable, Sendable {
    public var journal: JournalRef?
    public var workHost: WorkHostRef?
    public var clientAttachments: [String: WorkHostClientAttachmentSnapshot] = [:]
    public var readAcknowledgements: [String: WorkHostReadAcknowledgementSnapshot] = [:]
    /// Durable Create transactions keyed by length-prefixed client/command identity. The map is
    /// a projection of the control journal, not a second manifest or registry.
    public var creations: [String: WorkHostControlCreationSnapshot] = [:]
    public var lastEventID: String?
    public var lastSequence: Int = 0
    public var eventSequences: [String: Int] = [:]
    public var lastHostSequence: Int?
    public var causalOrderValid = true
    public var structuralIntegrityValid = true
    public var semanticProjectionValid = true
    public var seenEventIDs: Set<String> = []
    public var unknownEvents: [UnknownTimelineEvent] = []
    public var quarantinedEvents: [TimelineEvent] = []
    public var corruptionReasons: [String] = []

    public init(journal: JournalRef? = nil) {
        self.journal = journal
        if case .workHost(let host) = journal?.owner {
            self.workHost = host
        }
    }

    /// Durable attachments that have not received an explicit detach event. This is intentionally
    /// not named `connected`; transport reachability is an ephemeral observation outside the
    /// control journal.
    public var attachedClientIDs: Set<String> {
        Set(clientAttachments.values.filter(\.isAttached).map { $0.client.clientID })
    }

    public func creation(client: ClientRef, commandID: String) -> WorkHostControlCreationSnapshot? {
        creations[controlLengthPrefixedKey(client, commandID: commandID)]
    }

    /// Project one durable reservation against bounded source-presence evidence supplied by a
    /// reader. Control records alone cannot prove that either source journal survived a crash.
    /// Even `.both` is only a diagnostic hint; it cannot make a registration reconstructable.
    public func creationProjection(
        client: ClientRef,
        commandID: String,
        sourcePresence: WorkHostControlCreationSourcePresence = .notObserved
    ) -> WorkHostControlCreationProjection? {
        guard let creation = creation(client: client, commandID: commandID) else { return nil }
        return creationProjection(
            creation, sourcePresence: sourcePresence, verified: false)
    }

    fileprivate func creationProjection(
        _ creation: WorkHostControlCreationSnapshot,
        sourcePresence: WorkHostControlCreationSourcePresence,
        verified: Bool
    ) -> WorkHostControlCreationProjection {
        if let registration = creation.registration {
            let state: WorkHostControlCreationProjectionState = creation.isConflicted
                ? .conflicted
                : (verified && sourcePresence == .verified ? .registered : .recoveryRequired)
            return WorkHostControlCreationProjection(
                state: state, sourcePresence: sourcePresence,
                reservation: creation.reservation, registration: registration,
                responseIsReconstructable: !creation.isConflicted
                    && verified && sourcePresence == .verified)
        }

        let state: WorkHostControlCreationProjectionState
        if creation.isConflicted {
            state = .conflicted
        } else {
            switch sourcePresence {
            case .none: state = .reservationOnly
            case .workOnly, .sessionOnly: state = .sourceIncomplete
            case .both: state = .journalsUnregistered
            case .notObserved, .unverified, .verified: state = .recoveryRequired
            }
        }
        return WorkHostControlCreationProjection(
            state: state, sourcePresence: sourcePresence,
            reservation: creation.reservation, registration: nil,
            responseIsReconstructable: false)
    }
}

private struct WorkHostControlSourceJournalEvidence {
    let attachments: Set<SessionAttachmentRef>
    let dataDigest: String
}

private enum WorkHostControlSourceObservation {
    case valid(WorkHostControlSourceJournalEvidence)
    case missing
    case unreadable
    case incomplete
    case mismatch
}

private enum WorkHostControlSourceKind {
    case work
    case session
}

/// Reducer for the Work Host-owned control journal.
public struct WorkHostControlReducer: Sendable {
    public private(set) var snapshot: WorkHostControlSnapshot

    public init(snapshot: WorkHostControlSnapshot = WorkHostControlSnapshot()) {
        self.snapshot = snapshot
    }

    public static func reduce<S: Sequence>(
        _ events: S,
        initial: WorkHostControlSnapshot = WorkHostControlSnapshot()
    ) -> WorkHostControlSnapshot where S.Element == TimelineEvent {
        var reducer = WorkHostControlReducer(snapshot: initial)
        for event in events { reducer.apply(event) }
        return reducer.snapshot
    }

    public mutating func apply(_ event: TimelineEvent) {
        guard accept(event) else { return }
        guard event.schemaVersion <= TimelineEvent.currentSchemaVersion,
              event.payloadVersion <= 1 else {
            recordUnknown(event)
            return
        }

        switch event.type {
        case WorkHostControlEventType.creationReserved:
            applyCreationReserved(event)
        case WorkHostControlEventType.workRegistered:
            applyWorkRegistered(event)
        case TimelineEventType.clientAttached:
            applyClientAttached(event)
        case TimelineEventType.clientDetached:
            applyClientDetached(event)
        case TimelineEventType.clientCapabilityChanged:
            applyClientCapabilityChange(event)
        case TimelineEventType.clientReadAcknowledged, TimelineEventType.clientCursorAdvanced:
            applyReadAcknowledgement(event)
        case TimelineEventType.hostOrderObserved:
            // Host order observations are control-journal facts but carry no attachment state.
            break
        default:
            if event.isKnownType {
                quarantine(event, reason: "event type is not valid in a Work Host control journal")
            } else {
                recordUnknown(event)
            }
        }
    }

    // MARK: Envelope and shared validation

    private mutating func accept(_ event: TimelineEvent) -> Bool {
        guard snapshot.structuralIntegrityValid else {
            snapshot.quarantinedEvents.append(event)
            return false
        }
        guard !snapshot.seenEventIDs.contains(event.eventID) else {
            quarantine(event, reason: "duplicate event \(event.eventID)", structural: true)
            return false
        }
        guard case .workHost(let ownerHost) = event.journal.owner else {
            quarantine(event, reason: "control event does not belong to a Work Host journal", structural: true)
            return false
        }
        guard !ownerHost.workHostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quarantine(event, reason: "control journal Work Host identity is empty", structural: true)
            return false
        }
        guard snapshot.journal == nil || snapshot.journal == event.journal else {
            quarantine(event, reason: "event belongs to another Work Host control journal", structural: true)
            return false
        }
        if snapshot.journal == nil { snapshot.journal = event.journal }
        if snapshot.workHost == nil { snapshot.workHost = ownerHost }
        guard snapshot.workHost == ownerHost else {
            quarantine(event, reason: "event Work Host identity does not match control journal owner", structural: true)
            return false
        }
        guard event.workHost == ownerHost else {
            quarantine(event, reason: "control event must carry its Work Host owner", structural: false)
            return false
        }
        if let work = event.work, work.workHostID != ownerHost.workHostID {
            quarantine(event, reason: "control event Work belongs to another Work Host", structural: false)
            return false
        }
        if let hostSequence = event.hostSequence,
           let previousHostSequence = snapshot.lastHostSequence,
           hostSequence <= previousHostSequence {
            quarantine(event, reason: "non-increasing host order", structural: true)
            return false
        }
        guard !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quarantine(event, reason: "control event id is empty", structural: true)
            return false
        }
        let (expectedSequence, didOverflow) = snapshot.lastSequence.addingReportingOverflow(1)
        guard !didOverflow, event.sequence == expectedSequence else {
            quarantine(event, reason: "sequence gap or non-increasing sequence", structural: true)
            return false
        }
        if let previous = snapshot.lastEventID {
            guard event.previousEventID == previous else {
                quarantine(event, reason: "previous event mismatch", structural: true)
                return false
            }
        } else if event.previousEventID != nil {
            quarantine(event, reason: "non-empty previous event at journal start", structural: true)
            return false
        }
        snapshot.seenEventIDs.insert(event.eventID)
        snapshot.eventSequences[event.eventID] = event.sequence
        snapshot.lastEventID = event.eventID
        snapshot.lastSequence = event.sequence
        if let hostSequence = event.hostSequence { snapshot.lastHostSequence = hostSequence }
        return true
    }

    private func targetWork(from event: TimelineEvent) -> (work: WorkRef, journal: JournalRef)? {
        guard let work = event.work,
              let workJournal: JournalRef = event.payload["work_journal"].flatMap(decodeControlValue),
              workJournal.owner == .work(work),
              workJournal.authority.authorityID == work.workHostID,
              work.workHostID == snapshot.workHost?.workHostID,
              !work.workHostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !work.workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.client?.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              event.clientAttachment?.attachmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return (work, workJournal)
    }

    private func validSessionEnvelope(_ event: TimelineEvent) -> Bool {
        switch (event.session, event.sessionAttachment) {
        case (nil, nil): return event.payload["session_journal"] == nil
        case (.some(let session), .some(let attachment)):
            guard !session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !attachment.attachmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sessionJournal: JournalRef = event.payload["session_journal"].flatMap(decodeControlValue)
            else { return false }
            return sessionJournal.owner == .session(session)
        default: return false
        }
    }

    private func sessionJournal(from event: TimelineEvent) -> JournalRef? {
        event.payload["session_journal"].flatMap(decodeControlValue)
    }

    private func capabilities(from event: TimelineEvent) -> Set<String>? {
        guard let values = event.payload["capabilities"]?.arrayValue else { return nil }
        let strings = values.compactMap(\.stringValue)
        guard strings.count == values.count,
              strings.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        return Set(strings)
    }

    private func targetCursor(from event: TimelineEvent) -> (JournalRef, JournalCursor)? {
        guard let target: JournalRef = event.payload["target_journal"].flatMap(decodeControlValue),
              let cursor: JournalCursor = event.payload["cursor"].flatMap(decodeControlValue),
              cursor.journal == target,
              cursor.sequence >= 0,
              cursor.sequence == 0
                ? cursor.eventID == nil
                : cursor.eventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return (target, cursor)
    }

    // MARK: Creation transactions

    private func controlCursorBefore(_ event: TimelineEvent) -> JournalCursor? {
        guard event.sequence > 0 else { return nil }
        return JournalCursor(
            journal: event.journal, eventID: event.previousEventID,
            sequence: event.sequence - 1)
    }

    private func creationPayloadIsExact(_ event: TimelineEvent, keys: Set<String>) -> Bool {
        guard let object = event.payload.objectValue else { return false }
        return Set(object.keys) == keys
    }

    private func creationIdentityIsValid(
        _ event: TimelineEvent,
        commandCursorMustMatchPrior: Bool = true
    ) -> Bool {
        guard case .workHost(let host) = event.journal.owner,
              let eventHost = event.workHost,
              eventHost == host,
              let work = event.work,
              let session = event.session,
              let sessionAttachment = event.sessionAttachment,
              let client = event.client,
              let command = event.command,
              controlBoundedIdentity(event.eventID),
              command.client == client,
              command.sessionAttachment == nil,
              let commandCursor = command.causalCursor,
              event.clientAttachment == nil,
              work.workHostID == host.workHostID,
              controlBoundedIdentity(host.workHostID),
              controlBoundedIdentity(client.clientID),
              controlBoundedIdentity(command.commandID),
              controlBoundedIdentity(work.workHostID),
              controlBoundedIdentity(work.workID),
              controlBoundedIdentity(session.sessionID),
              controlBoundedIdentity(sessionAttachment.attachmentID),
              controlBoundedCursor(commandCursor),
              !commandCursorMustMatchPrior || commandCursor == controlCursorBefore(event) else {
            return false
        }
        return true
    }

    private func creationDigests(from event: TimelineEvent) -> (body: String, configuration: String)? {
        guard let body = event.payload["body_digest"]?.stringValue,
              let configuration = event.payload["configuration_digest"]?.stringValue,
              controlBoundedDigest(body), controlBoundedDigest(configuration) else {
            return nil
        }
        return (body, configuration)
    }

    private mutating func applyCreationReserved(_ event: TimelineEvent) {
        guard creationPayloadIsExact(
            event, keys: ["body_digest", "configuration_digest"]),
            creationIdentityIsValid(event),
            let digests = creationDigests(from: event),
            let client = event.client,
            let command = event.command,
            let work = event.work,
            let session = event.session,
            let sessionAttachment = event.sessionAttachment,
            let causalCursor = command.causalCursor,
            controlCursorBefore(event) != nil else {
            quarantine(event, reason: "Work Host creation reservation is malformed")
            return
        }

        let key = controlLengthPrefixedKey(client, commandID: command.commandID)
        let reservation = WorkHostControlCreationReservation(
            client: client, command: command, bodyDigest: digests.body,
            configurationDigest: digests.configuration, causalControlCursor: causalCursor,
            work: work, session: session, sessionAttachment: sessionAttachment,
            reservationEvent: EventRef(journal: event.journal, eventID: event.eventID),
            reservationCursor: JournalCursor(
                journal: event.journal, eventID: event.eventID, sequence: event.sequence))
        if let existing = snapshot.creations[key] {
            guard existing.reservation.client == reservation.client,
                  existing.reservation.command == reservation.command,
                  existing.reservation.bodyDigest == reservation.bodyDigest,
                  existing.reservation.configurationDigest == reservation.configurationDigest,
                  existing.reservation.causalControlCursor == reservation.causalControlCursor,
                  existing.reservation.work == reservation.work,
                  existing.reservation.session == reservation.session,
                  existing.reservation.sessionAttachment == reservation.sessionAttachment else {
                markCreationConflict(
                    key: key, event: event,
                    reason: "Work Host creation reservation conflicts with a prior envelope")
                return
            }
            // A host may see a repeated reservation line after a response-loss/recovery window.
            // Preserve the first event as provenance and reconcile the exact envelope.
            return
        }
        snapshot.creations[key] = WorkHostControlCreationSnapshot(reservation: reservation)
    }

    private func registrationValues(from event: TimelineEvent) -> (
        workJournal: JournalRef,
        sessionJournal: JournalRef,
        workGenesisCursor: JournalCursor,
        sessionGenesisCursor: JournalCursor,
        causalControlCursor: JournalCursor,
        reservationEvent: EventRef,
        bodyDigest: String,
        configurationDigest: String
    )? {
        guard let workJournal: JournalRef = event.payload["work_journal"].flatMap(decodeControlValue),
              let sessionJournal: JournalRef = event.payload["session_journal"].flatMap(decodeControlValue),
              let workGenesisCursor: JournalCursor = event.payload["work_genesis_cursor"].flatMap(decodeControlValue),
              let sessionGenesisCursor: JournalCursor = event.payload["session_genesis_cursor"].flatMap(decodeControlValue),
              let causalControlCursor: JournalCursor = event.payload["causal_control_cursor"].flatMap(decodeControlValue),
              let reservationEvent: EventRef = event.payload["reservation_event"].flatMap(decodeControlValue),
              let bodyDigest = event.payload["body_digest"]?.stringValue,
              let configurationDigest = event.payload["configuration_digest"]?.stringValue,
              controlBoundedDigest(bodyDigest), controlBoundedDigest(configurationDigest),
              controlBoundedCursor(causalControlCursor),
              controlBoundedCursor(workGenesisCursor),
              controlBoundedCursor(sessionGenesisCursor) else {
            return nil
        }
        return (
            workJournal, sessionJournal, workGenesisCursor, sessionGenesisCursor,
            causalControlCursor, reservationEvent, bodyDigest, configurationDigest)
    }

    private mutating func applyWorkRegistered(_ event: TimelineEvent) {
        let registrationKeys: Set<String> = [
            "work_journal", "session_journal", "work_genesis_cursor", "session_genesis_cursor",
            "causal_control_cursor", "reservation_event", "body_digest", "configuration_digest",
        ]
        guard creationPayloadIsExact(event, keys: registrationKeys),
              creationIdentityIsValid(event, commandCursorMustMatchPrior: false),
              let values = registrationValues(from: event),
              let client = event.client,
              let command = event.command,
              let work = event.work,
              let session = event.session,
              let sessionAttachment = event.sessionAttachment,
              let priorCursor = controlCursorBefore(event),
              values.causalControlCursor == priorCursor,
              values.reservationEvent.journal == event.journal else {
            quarantine(event, reason: "Work Host Work registration is malformed")
            return
        }
        guard case .work(let workJournalWork) = values.workJournal.owner,
              workJournalWork == work,
              values.workJournal.authority.authorityID == work.workHostID,
              values.workJournal.kind == .work,
              case .session(let sessionJournalSession) = values.sessionJournal.owner,
              sessionJournalSession == session,
              values.sessionJournal.authority.authorityID == work.workHostID,
              values.sessionJournal.kind == .session,
              values.workGenesisCursor.journal == values.workJournal,
              values.sessionGenesisCursor.journal == values.sessionJournal,
              controlBoundedIdentity(values.reservationEvent.eventID) else {
            quarantine(event, reason: "Work Host Work registration journals are malformed")
            return
        }

        let key = controlLengthPrefixedKey(client, commandID: command.commandID)
        guard var existing = snapshot.creations[key] else {
            quarantine(event, reason: "Work Host Work registration has no matching reservation")
            return
        }
        let reservation = existing.reservation
        guard reservation.client == client,
              reservation.command == command,
              reservation.work == work,
              reservation.session == session,
              reservation.sessionAttachment == sessionAttachment,
              reservation.bodyDigest == values.bodyDigest,
              reservation.configurationDigest == values.configurationDigest,
              reservation.reservationEvent == values.reservationEvent,
              event.causedByEventID == values.reservationEvent else {
            markCreationConflict(
                key: key, event: event,
                reason: "Work Host Work registration conflicts with its reservation")
            return
        }
        let registration = WorkHostControlWorkRegistration(
            reservation: reservation, workJournal: values.workJournal,
            sessionJournal: values.sessionJournal, workGenesisCursor: values.workGenesisCursor,
            sessionGenesisCursor: values.sessionGenesisCursor,
            causalControlCursor: values.causalControlCursor,
            registrationEvent: EventRef(journal: event.journal, eventID: event.eventID),
            registrationCursor: JournalCursor(
                journal: event.journal, eventID: event.eventID, sequence: event.sequence))
        if let prior = existing.registration {
            guard prior.workJournal == registration.workJournal,
                  prior.sessionJournal == registration.sessionJournal,
                  prior.workGenesisCursor == registration.workGenesisCursor,
                  prior.sessionGenesisCursor == registration.sessionGenesisCursor,
                  prior.causalControlCursor == registration.causalControlCursor else {
                markCreationConflict(
                    key: key, event: event,
                    reason: "Work Host Work registration conflicts with a prior registration")
                return
            }
            return
        }
        existing.registration = registration
        snapshot.creations[key] = existing
    }

    private mutating func markCreationConflict(key: String, event: TimelineEvent, reason: String) {
        if var existing = snapshot.creations[key] {
            existing.isConflicted = true
            if existing.conflictEventRefs.count < TimelineEvent.maxEvidenceLinks {
                existing.conflictEventRefs.append(
                    EventRef(journal: event.journal, eventID: event.eventID))
            }
            snapshot.creations[key] = existing
        }
        quarantine(event, reason: reason)
    }

    // MARK: Attachment events

    private mutating func applyClientAttached(_ event: TimelineEvent) {
        guard let target = targetWork(from: event), validSessionEnvelope(event),
              let client = event.client, let attachment = event.clientAttachment,
              let capabilities = capabilities(from: event) else {
            quarantine(event, reason: "Work Host client attachment is malformed")
            return
        }
        let id = attachment.attachmentID
        guard snapshot.clientAttachments[id] == nil else {
            quarantine(event, reason: "Work Host client attachment identity was reused")
            return
        }
        let eventRef = EventRef(journal: event.journal, eventID: event.eventID)
        let sessionJournal = sessionJournal(from: event)
        snapshot.clientAttachments[id] = WorkHostClientAttachmentSnapshot(
            attachment: attachment, client: client, work: target.work, workJournal: target.journal,
            session: event.session, sessionJournal: sessionJournal,
            sessionAttachment: event.sessionAttachment, capabilities: capabilities,
            attachedEvent: eventRef)
    }

    private mutating func applyClientDetached(_ event: TimelineEvent) {
        guard let target = targetWork(from: event), validSessionEnvelope(event),
              let client = event.client, let attachment = event.clientAttachment,
              var state = snapshot.clientAttachments[attachment.attachmentID],
              state.client == client, state.work == target.work,
              state.workJournal == target.journal,
              state.session == event.session,
              state.sessionAttachment == event.sessionAttachment,
              state.sessionJournal == sessionJournal(from: event) else {
            quarantine(event, reason: "Work Host client detach references the wrong attachment")
            return
        }
        guard state.isAttached else {
            quarantine(event, reason: "Work Host client attachment was already explicitly detached")
            return
        }
        state.isAttached = false
        state.detachedEvent = EventRef(journal: event.journal, eventID: event.eventID)
        snapshot.clientAttachments[attachment.attachmentID] = state
    }

    private mutating func applyClientCapabilityChange(_ event: TimelineEvent) {
        guard let target = targetWork(from: event), validSessionEnvelope(event),
              let client = event.client, let attachment = event.clientAttachment,
              var state = snapshot.clientAttachments[attachment.attachmentID],
              state.client == client, state.work == target.work,
              state.workJournal == target.journal,
              state.session == event.session,
              state.sessionAttachment == event.sessionAttachment,
              state.sessionJournal == sessionJournal(from: event),
              state.isAttached,
              let capabilities = capabilities(from: event) else {
            quarantine(event, reason: "Work Host client capability change is malformed")
            return
        }
        state.capabilities = capabilities
        snapshot.clientAttachments[attachment.attachmentID] = state
    }

    // MARK: Read acknowledgement

    private mutating func applyReadAcknowledgement(_ event: TimelineEvent) {
        guard let target = targetWork(from: event), validSessionEnvelope(event),
              let client = event.client, let attachment = event.clientAttachment,
              let state = snapshot.clientAttachments[attachment.attachmentID],
              state.client == client, state.work == target.work,
              state.workJournal == target.journal, state.isAttached,
              let (targetJournal, cursor) = targetCursor(from: event),
              validReadTarget(targetJournal, work: target.work, state: state, event: event) else {
            quarantine(event, reason: "Work Host read acknowledgement is malformed")
            return
        }
        let key = readAcknowledgementKey(client: client, attachment: attachment,
                                         targetJournal: targetJournal)
        if let existing = snapshot.readAcknowledgements[key] {
            guard existing.work == target.work, existing.targetJournal == targetJournal,
                  cursor.sequence >= existing.cursor.sequence else {
                quarantine(event, reason: "Work Host read acknowledgement moved backwards")
                return
            }
            if cursor.sequence == existing.cursor.sequence {
                guard cursor.eventID == existing.cursor.eventID else {
                    quarantine(event, reason: "Work Host read acknowledgement conflicts at one sequence")
                    return
                }
                // Repeating the same acknowledgement is an idempotent observation. The first
                // event remains provenance for the durable cursor.
                return
            }
        }
        snapshot.readAcknowledgements[key] = WorkHostReadAcknowledgementSnapshot(
            client: client, attachment: attachment, work: target.work,
            targetJournal: targetJournal, cursor: cursor,
            acknowledgedEvent: EventRef(journal: event.journal, eventID: event.eventID))
    }

    private func validReadTarget(
        _ journal: JournalRef,
        work: WorkRef,
        state: WorkHostClientAttachmentSnapshot,
        event: TimelineEvent
    ) -> Bool {
        switch journal.owner {
        case .work(let targetWork):
            return targetWork == work
                && state.workJournal == journal
                && journal.authority.authorityID == work.workHostID
        case .session(let session):
            return state.session == session
                && state.sessionJournal == journal
                && state.sessionJournal == sessionJournal(from: event)
                && state.sessionAttachment == event.sessionAttachment
                && event.session == session
        case .workHost:
            return false
        }
    }

    private func readAcknowledgementKey(
        client: ClientRef,
        attachment: ClientAttachmentRef,
        targetJournal: JournalRef
    ) -> String {
        // JournalRef.stableKey is length-prefixed and therefore safe as a dictionary key even
        // when caller-controlled identities contain delimiters.
        "client:\(client.clientID.utf8.count):\(client.clientID)/attachment:\(attachment.attachmentID.utf8.count):\(attachment.attachmentID)/target:\(targetJournal.stableKey)"
    }

    // MARK: Unknown/corrupt facts

    private mutating func recordUnknown(_ event: TimelineEvent) {
        let domains = event.declaredDomains.isEmpty
            ? Set(TimelineDomain.allCases)
            : event.declaredDomains
        snapshot.unknownEvents.append(UnknownTimelineEvent(
            event: event, journalOffset: snapshot.seenEventIDs.count - 1,
            affectedDomains: domains))
    }

    private mutating func quarantine(
        _ event: TimelineEvent,
        reason: String,
        structural: Bool = false
    ) {
        if structural {
            snapshot.causalOrderValid = false
            snapshot.structuralIntegrityValid = false
        } else {
            snapshot.semanticProjectionValid = false
        }
        snapshot.corruptionReasons.append(reason)
        snapshot.quarantinedEvents.append(event)
    }
}

// MARK: - Durable Work Host control journal

/// A journal owner/writer for the Work Host control plane.
///
/// The wrapper keeps the control journal's authority and canonical locator together while
/// delegating byte-level locking, fsync, and append-chain validation to
/// `TimelineJournalWriter`. It has no transport or connectivity state; a client socket may come
/// and go without producing a control-journal event.
public actor WorkHostControlJournal {
    public nonisolated let journal: JournalRef
    public nonisolated let workHost: WorkHostRef
    public nonisolated let fileURL: URL
    private let writer: TimelineJournalWriter
    private let readerActor: TimelineActor
    private let home: AgentHome?
    private let creationIdentityMinter: @Sendable () -> WorkHostControlMintedIdentity
    private var controlFailure: String?
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        freshAt fileURL: URL,
        workHost: WorkHostRef,
        actor: TimelineActor,
        home: AgentHome? = nil,
        failurePlan: TimelineJournalWriter.FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil,
        creationIdentityMinter: @escaping @Sendable () -> WorkHostControlMintedIdentity = {
            WorkHostControlMintedIdentity(
                workID: "work-\(UUID().uuidString.lowercased())",
                sessionID: "session-\(UUID().uuidString.lowercased())",
                sessionAttachmentID: "session-attachment-\(UUID().uuidString.lowercased())")
        }
    ) throws {
        let journal = JournalRef.workHost(workHost)
        self.journal = journal
        self.workHost = workHost
        self.fileURL = fileURL
        self.readerActor = actor
        self.home = home
        self.creationIdentityMinter = creationIdentityMinter
        let boundedEventIDProvider: @Sendable () -> String = {
            let value = eventIDProvider()
            return value.utf8.count <= WorkHostControlLimits.maxIdentityCharacters ? value : ""
        }
        self.writer = try TimelineJournalWriter(
            freshAt: fileURL, journal: journal, actor: actor, home: home,
            failurePlan: failurePlan, eventIDProvider: boundedEventIDProvider, now: now,
            didSynchronize: didSynchronize)
        try Self.persistDurabilitySeal(
            for: fileURL, journal: journal,
            cursor: JournalCursor(journal: journal, eventID: nil, sequence: 0),
            data: Data())
    }

    public init(
        reopening fileURL: URL,
        workHost: WorkHostRef,
        actor: TimelineActor,
        home: AgentHome? = nil,
        failurePlan: TimelineJournalWriter.FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil,
        creationIdentityMinter: @escaping @Sendable () -> WorkHostControlMintedIdentity = {
            WorkHostControlMintedIdentity(
                workID: "work-\(UUID().uuidString.lowercased())",
                sessionID: "session-\(UUID().uuidString.lowercased())",
                sessionAttachmentID: "session-attachment-\(UUID().uuidString.lowercased())")
        }
    ) throws {
        let journal = JournalRef.workHost(workHost)
        self.journal = journal
        self.workHost = workHost
        self.fileURL = fileURL
        self.readerActor = actor
        self.home = home
        self.creationIdentityMinter = creationIdentityMinter
        let boundedEventIDProvider: @Sendable () -> String = {
            let value = eventIDProvider()
            return value.utf8.count <= WorkHostControlLimits.maxIdentityCharacters ? value : ""
        }
        self.writer = try TimelineJournalWriter(
            reopening: fileURL, journal: journal, actor: actor, home: home,
            recoveryCommittedByteCount: { data in
                try Self.recoverableCommittedByteCount(
                    for: fileURL, journal: journal, data: data)
            },
            failurePlan: failurePlan, eventIDProvider: boundedEventIDProvider, now: now,
            didSynchronize: didSynchronize)
    }

    public static func createFresh(
        home: AgentHome,
        workHost: WorkHostRef,
        actor: TimelineActor,
        failurePlan: TimelineJournalWriter.FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil,
        creationIdentityMinter: @escaping @Sendable () -> WorkHostControlMintedIdentity = {
            WorkHostControlMintedIdentity(
                workID: "work-\(UUID().uuidString.lowercased())",
                sessionID: "session-\(UUID().uuidString.lowercased())",
                sessionAttachmentID: "session-attachment-\(UUID().uuidString.lowercased())")
        }
    ) throws -> WorkHostControlJournal {
        return try WorkHostControlJournal(
            freshAt: home.timelineV2WorkHostControlJournalURL(workHost),
            workHost: workHost, actor: actor, home: home, failurePlan: failurePlan,
            eventIDProvider: eventIDProvider, now: now, didSynchronize: didSynchronize,
            creationIdentityMinter: creationIdentityMinter)
    }

    public static func reopenExisting(
        home: AgentHome,
        workHost: WorkHostRef,
        actor: TimelineActor,
        failurePlan: TimelineJournalWriter.FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil,
        creationIdentityMinter: @escaping @Sendable () -> WorkHostControlMintedIdentity = {
            WorkHostControlMintedIdentity(
                workID: "work-\(UUID().uuidString.lowercased())",
                sessionID: "session-\(UUID().uuidString.lowercased())",
                sessionAttachmentID: "session-attachment-\(UUID().uuidString.lowercased())")
        }
    ) throws -> WorkHostControlJournal {
        return try WorkHostControlJournal(
            reopening: home.timelineV2WorkHostControlJournalURL(workHost),
            workHost: workHost, actor: actor, home: home, failurePlan: failurePlan,
            eventIDProvider: eventIDProvider, now: now, didSynchronize: didSynchronize,
            creationIdentityMinter: creationIdentityMinter)
    }

    public func read() throws -> TimelineJournalReadResult {
        let data = try Self.readBoundedData(
            at: fileURL, maximum: WorkHostControlLimits.maxControlJournalBytes)
        let committedData = try Self.committedPrefixData(
            for: fileURL, journal: journal, data: data)
        return TimelineJournalReader.read(
            committedData, journal: journal, actor: readerActor, hostRecordedAt: Date())
    }

    public func snapshot() throws -> WorkHostControlSnapshot {
        let result = try read()
        let initial = WorkHostControlSnapshot(journal: journal)
        return WorkHostControlReducer.reduce(result.records.map(\.event), initial: initial)
    }

    public func closeChecked() async throws {
        var closeError: Error?
        do { try await writer.closeChecked() } catch { closeError = error }
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        if let closeError { throw closeError }
    }

    public func close() async {
        await writer.close()
    }

    public var health: TimelineJournalWriter.WriterHealth {
        get async {
            if let controlFailure { return .failed(reason: controlFailure) }
            return await writer.health
        }
    }

    public var nextSequenceNumber: Int {
        get async { await writer.nextSequenceNumber }
    }

    // MARK: Canonical control-event builders

    @discardableResult
    public func attachClient(
        work: WorkRef,
        workJournal: JournalRef,
        attachment: ClientAttachmentRef,
        client: ClientRef,
        capabilities: Set<String>,
        session: SessionRef? = nil,
        sessionJournal: JournalRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil,
        command: CommandRef,
        causalControlCursor: JournalCursor
    ) async throws -> TimelineJournalCommit {
        try validateWorkTarget(work: work, journal: workJournal)
        try validateSessionContext(
            session: session, sessionJournal: sessionJournal, sessionAttachment: sessionAttachment)
        try validateCapabilities(capabilities)
        return try await commitMutation(WorkHostControlMutationIdentity(
            type: TimelineEventType.clientAttached, work: work, workJournal: workJournal,
            attachment: attachment, client: client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            capabilities: capabilities.sorted(), targetJournal: nil, targetCursor: nil,
            causalControlCursor: causalControlCursor), command: command)
    }

    @discardableResult
    public func explicitlyDetachClient(
        work: WorkRef,
        workJournal: JournalRef,
        attachment: ClientAttachmentRef,
        client: ClientRef,
        session: SessionRef? = nil,
        sessionJournal: JournalRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil,
        command: CommandRef,
        causalControlCursor: JournalCursor
    ) async throws -> TimelineJournalCommit {
        try validateWorkTarget(work: work, journal: workJournal)
        try validateSessionContext(
            session: session, sessionJournal: sessionJournal, sessionAttachment: sessionAttachment)
        return try await commitMutation(WorkHostControlMutationIdentity(
            type: TimelineEventType.clientDetached, work: work, workJournal: workJournal,
            attachment: attachment, client: client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            capabilities: nil, targetJournal: nil, targetCursor: nil,
            causalControlCursor: causalControlCursor), command: command)
    }

    @discardableResult
    public func updateClientCapabilities(
        work: WorkRef,
        workJournal: JournalRef,
        attachment: ClientAttachmentRef,
        client: ClientRef,
        capabilities: Set<String>,
        session: SessionRef? = nil,
        sessionJournal: JournalRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil,
        command: CommandRef,
        causalControlCursor: JournalCursor
    ) async throws -> TimelineJournalCommit {
        try validateWorkTarget(work: work, journal: workJournal)
        try validateSessionContext(
            session: session, sessionJournal: sessionJournal, sessionAttachment: sessionAttachment)
        try validateCapabilities(capabilities)
        return try await commitMutation(WorkHostControlMutationIdentity(
            type: TimelineEventType.clientCapabilityChanged, work: work,
            workJournal: workJournal, attachment: attachment, client: client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            capabilities: capabilities.sorted(), targetJournal: nil, targetCursor: nil,
            causalControlCursor: causalControlCursor), command: command)
    }

    @discardableResult
    public func acknowledgeRead(
        work: WorkRef,
        workJournal: JournalRef,
        attachment: ClientAttachmentRef,
        client: ClientRef,
        targetJournal: JournalRef,
        cursor: JournalCursor,
        session: SessionRef? = nil,
        sessionJournal: JournalRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil,
        command: CommandRef,
        causalControlCursor: JournalCursor
    ) async throws -> TimelineJournalCommit {
        try validateWorkTarget(work: work, journal: workJournal)
        try validateSessionContext(
            session: session, sessionJournal: sessionJournal, sessionAttachment: sessionAttachment)
        if case .session = targetJournal.owner {
            guard session != nil, sessionJournal == targetJournal, sessionAttachment != nil else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "Session read acknowledgement requires the attached Session tuple")
            }
        }
        return try await commitMutation(WorkHostControlMutationIdentity(
            type: TimelineEventType.clientReadAcknowledged, work: work,
            workJournal: workJournal, attachment: attachment, client: client, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            capabilities: nil, targetJournal: targetJournal, targetCursor: cursor,
            causalControlCursor: causalControlCursor), command: command)
    }

    /// Durably reserve host-minted Session/Work identities before either source journal exists.
    /// The request contains only bounded identities and digests, so this control record is safe to
    /// recover without retaining the prompt, cwd, credentials, or configuration body.
    public func reserveCreation(
        _ request: WorkHostControlCreationRequest
    ) async throws -> WorkHostControlCreationReservation {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        try validateCreationRequest(request)
        let (current, actualCursor) = try readControlState()
        let key = request.key
        if let existing = current.creations[key] {
            guard !existing.isConflicted,
                  creationMatches(existing.reservation, request) else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "create command conflicts with its prior reservation")
            }
            if case .failed(let reason) = await writer.health {
                throw TimelineJournalWriter.WriterError.unavailable(reason)
            }
            return existing.reservation
        }
        guard request.causalControlCursor == actualCursor else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "creation reservation causal control cursor is stale")
        }

        let minted = try mintCreationIdentity(current: current)
        let work = minted.work
        let session = minted.session
        let sessionAttachment = minted.sessionAttachment
        let payload: JSONValue = .object([
            "body_digest": .string(request.bodyDigest),
            "configuration_digest": .string(request.configurationDigest),
        ])
        let draft = TimelineEventDraft(
            command: request.command, session: session, work: work, workHost: workHost,
            client: request.client, sessionAttachment: sessionAttachment,
            type: WorkHostControlEventType.creationReserved,
            declaredDomains: [.work, .session], payload: payload)
        let digest = try creationRequestDigest(request)
        let commit = try await appendCreationDraft(
            draft, digest: digest, current: current, causalCursor: actualCursor)
        return WorkHostControlCreationReservation(
            client: request.client, command: request.command,
            bodyDigest: request.bodyDigest, configurationDigest: request.configurationDigest,
            causalControlCursor: request.causalControlCursor,
            work: work, session: session, sessionAttachment: sessionAttachment,
            reservationEvent: commit.eventRef, reservationCursor: commit.cursor)
    }

    /// Record the two source journal identities and their exact genesis cursors. This is a
    /// separate control fact from reservation because a crash may leave one or both journals
    /// absent. This control record does not itself prove source survival; callers must run the
    /// explicit actor-owned source verification before a reader calls the result registered or
    /// reconstructable. An exact retry reconciles the durable registration;
    /// changed journal identities or cursors are a conflict rather than a second registration.
    public func registerWork(
        _ request: WorkHostControlWorkRegistrationRequest
    ) async throws -> WorkHostControlWorkRegistration {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        try validateRegistrationRequest(request)
        let (current, actualCursor) = try readControlState()
        let key = request.reservation.key
        guard let existing = current.creations[key],
              !existing.isConflicted,
              creationMatches(existing.reservation, request.reservation) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Work registration does not match a durable reservation")
        }
        if let prior = existing.registration {
            guard registrationMatches(prior, request) else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "Work registration conflicts with its prior registration")
            }
            if case .failed(let reason) = await writer.health {
                throw TimelineJournalWriter.WriterError.unavailable(reason)
            }
            return prior
        }
        guard request.causalControlCursor == actualCursor else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Work registration causal control cursor is stale")
        }
        let payload: JSONValue = .object([
            "work_journal": encodeControlValue(request.workJournal),
            "session_journal": encodeControlValue(request.sessionJournal),
            "work_genesis_cursor": encodeControlValue(request.workGenesisCursor),
            "session_genesis_cursor": encodeControlValue(request.sessionGenesisCursor),
            "causal_control_cursor": encodeControlValue(request.causalControlCursor),
            "reservation_event": encodeControlValue(request.reservation.reservationEvent),
            "body_digest": .string(request.reservation.bodyDigest),
            "configuration_digest": .string(request.reservation.configurationDigest),
        ])
        let draft = TimelineEventDraft(
            command: request.reservation.command,
            causedByEventID: request.reservation.reservationEvent,
            session: request.reservation.session, work: request.reservation.work,
            workHost: workHost, client: request.reservation.client,
            sessionAttachment: request.reservation.sessionAttachment,
            type: WorkHostControlEventType.workRegistered,
            declaredDomains: [.work, .session], payload: payload)
        let digest = try registrationRequestDigest(request)
        let commit = try await appendCreationDraft(
            draft, digest: digest, current: current, causalCursor: actualCursor)
        return WorkHostControlWorkRegistration(
            reservation: request.reservation, workJournal: request.workJournal,
            sessionJournal: request.sessionJournal,
            workGenesisCursor: request.workGenesisCursor,
            sessionGenesisCursor: request.sessionGenesisCursor,
            causalControlCursor: request.causalControlCursor,
            registrationEvent: commit.eventRef, registrationCursor: commit.cursor)
    }

    /// Independently verify the two source journals for one durable registration. This is a
    /// diagnostic read: its digest fields are measurements, not reusable proof. Callers that need
    /// a reconstructable projection must use `verifiedCreationProjection`, which reads the
    /// control and source journals together and returns the projection produced by that fresh
    /// actor-owned operation. Missing, malformed, incomplete, foreign, or mismatched source
    /// journals return a bounded typed result instead of throwing a success-shaped cursor claim.
    /// This verifier reads only canonical journal bytes; it never returns raw paths, prompts, cwd,
    /// or other source bodies.
    public func verifyCreationSources(
        client: ClientRef,
        commandID: String
    ) async -> WorkHostControlCreationSourceVerification {
        verifyCreationSourcesNow(client: client, commandID: commandID).verification
    }

    /// Perform a fresh source verification and project the current control-journal creation in
    /// one actor-owned operation. There is intentionally no detached success receipt: deleting
    /// or replacing a source journal after this call cannot make a later call reuse stale proof.
    /// The returned projection and its bounded verification describe the same read attempt.
    public func verifiedCreationProjection(
        client: ClientRef,
        commandID: String
    ) async -> WorkHostControlCreationProjectionResult {
        let outcome = verifyCreationSourcesNow(client: client, commandID: commandID)
        guard let snapshot = outcome.snapshot,
              let creation = snapshot.creation(client: client, commandID: commandID) else {
            return WorkHostControlCreationProjectionResult(
                projection: nil, verification: outcome.verification)
        }
        return WorkHostControlCreationProjectionResult(
            projection: snapshot.creationProjection(
                creation,
                sourcePresence: outcome.verification.sourcePresence,
                verified: outcome.verification.isVerified),
            verification: outcome.verification)
    }

    private struct WorkHostControlCreationVerificationOutcome {
        let snapshot: WorkHostControlSnapshot?
        let verification: WorkHostControlCreationSourceVerification
    }

    private func verifyCreationSourcesNow(
        client: ClientRef,
        commandID: String
    ) -> WorkHostControlCreationVerificationOutcome {
        guard controlFailure == nil else {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: nil,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .unverified, failure: .controlJournalUnavailable))
        }
        let current: WorkHostControlSnapshot
        do {
            current = try readControlState().snapshot
        } catch {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: nil,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .unverified, failure: .controlJournalUnavailable))
        }
        guard let creation = current.creation(client: client, commandID: commandID) else {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .notObserved, failure: .creationMissing))
        }
        guard !creation.isConflicted else {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .unverified, failure: .creationConflicted))
        }
        guard let registration = creation.registration else {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .notObserved, failure: .registrationMissing))
        }
        guard let home,
              (try? home.requirePersistedWorkHost()) == workHost else {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .unverified, failure: .controlJournalUnavailable))
        }

        let workObservation = observeSourceJournal(
            registration.workJournal,
            cursor: registration.workGenesisCursor,
            expectedWork: registration.reservation.work,
            expectedSession: registration.reservation.session,
            expectedAttachment: registration.reservation.sessionAttachment,
            expectedGenesisType: TimelineEventType.workCreated)
        let sessionObservation = observeSourceJournal(
            registration.sessionJournal,
            cursor: registration.sessionGenesisCursor,
            expectedWork: registration.reservation.work,
            expectedSession: registration.reservation.session,
            expectedAttachment: registration.reservation.sessionAttachment,
            expectedGenesisType: TimelineEventType.sessionCreated)

        switch (workObservation, sessionObservation) {
        case (.valid(let workEvidence), .valid(let sessionEvidence)):
            let expected = Set([registration.reservation.sessionAttachment])
            guard workEvidence.attachments == expected,
                  sessionEvidence.attachments == expected,
                  workEvidence.attachments == sessionEvidence.attachments else {
                return WorkHostControlCreationVerificationOutcome(
                    snapshot: current,
                    verification: WorkHostControlCreationSourceVerification(
                        sourcePresence: .unverified, failure: .attachmentMirrorMismatch,
                        workSourceDigest: workEvidence.dataDigest,
                        sessionSourceDigest: sessionEvidence.dataDigest))
            }
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .verified,
                    workSourceDigest: workEvidence.dataDigest,
                    sessionSourceDigest: sessionEvidence.dataDigest))

        case (.valid, let sessionObservation):
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .workOnly,
                    failure: sourceVerificationFailure(sessionObservation, source: .session)))
        case (let workObservation, .valid):
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .sessionOnly,
                    failure: sourceVerificationFailure(workObservation, source: .work)))
        case (.missing, .missing):
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .none, failure: .bothSourcesMissing))
        case (let workObservation, let sessionObservation):
            let failure: WorkHostControlCreationSourceVerificationFailure
            switch workObservation {
            case .missing:
                failure = sourceVerificationFailure(sessionObservation, source: .session)
            default:
                failure = sourceVerificationFailure(workObservation, source: .work)
            }
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .unverified, failure: failure))
        }
    }

    private func validateCreationRequest(
        _ request: WorkHostControlCreationRequest
    ) throws {
        guard controlBoundedIdentity(request.client.clientID),
              controlBoundedIdentity(request.command.commandID),
              request.command.client == request.client,
              request.command.sessionAttachment == nil,
              request.command.causalCursor == request.causalControlCursor,
              controlBoundedDigest(request.bodyDigest),
              controlBoundedDigest(request.configurationDigest),
              controlBoundedCursor(request.causalControlCursor),
              request.causalControlCursor.journal == journal else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "creation request contains unbounded or mismatched identities")
        }
    }

    private func validateRegistrationRequest(
        _ request: WorkHostControlWorkRegistrationRequest
    ) throws {
        let reservation = request.reservation
        guard reservation.client == request.reservation.client,
              controlBoundedIdentity(reservation.client.clientID),
              controlBoundedIdentity(reservation.command.commandID),
              reservation.command.client == reservation.client,
              reservation.command.sessionAttachment == nil,
              controlBoundedDigest(reservation.bodyDigest),
              controlBoundedDigest(reservation.configurationDigest),
              controlBoundedCursor(reservation.causalControlCursor),
              reservation.reservationEvent.journal == journal,
              controlBoundedIdentity(reservation.reservationEvent.eventID),
              controlBoundedCursor(reservation.reservationCursor),
              reservation.reservationCursor.journal == journal,
              reservation.reservationCursor.eventID == reservation.reservationEvent.eventID,
              controlBoundedIdentity(reservation.work.workHostID),
              controlBoundedIdentity(reservation.work.workID),
              reservation.work.workHostID == workHost.workHostID,
              controlBoundedIdentity(reservation.session.sessionID),
              controlBoundedIdentity(reservation.sessionAttachment.attachmentID),
              isBoundedJournal(request.workJournal),
              isBoundedJournal(request.sessionJournal),
              request.workJournal.owner == .work(reservation.work),
              request.workJournal.authority.authorityID == workHost.workHostID,
              request.sessionJournal.owner == .session(reservation.session),
              request.sessionJournal.authority.authorityID == workHost.workHostID,
              controlBoundedCursor(request.workGenesisCursor),
              request.workGenesisCursor.journal == request.workJournal,
              controlBoundedCursor(request.sessionGenesisCursor),
              request.sessionGenesisCursor.journal == request.sessionJournal,
              controlBoundedCursor(request.causalControlCursor),
              request.causalControlCursor.journal == journal else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Work registration contains unbounded or mismatched journal evidence")
        }
    }

    private func observeSourceJournal(
        _ sourceJournal: JournalRef,
        cursor: JournalCursor,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedAttachment: SessionAttachmentRef,
        expectedGenesisType: String
    ) -> WorkHostControlSourceObservation {
        guard let home else { return .unreadable }
        guard cursor.journal == sourceJournal else { return .mismatch }

        let sourceURL: URL
        switch sourceJournal.owner {
        case .work(let work):
            guard sourceJournal.kind == .work,
                  work == expectedWork,
                  sourceJournal.authority.authorityID == workHost.workHostID else {
                return .mismatch
            }
            sourceURL = home.timelineV2WorkJournalURL(work)
        case .session(let session):
            guard sourceJournal.kind == .session,
                  session == expectedSession,
                  sourceJournal.authority.authorityID == workHost.workHostID else {
                return .mismatch
            }
            sourceURL = home.timelineV2SessionJournalURL(session)
        case .workHost:
            return .mismatch
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try Self.readBoundedData(
                at: sourceURL, maximum: WorkHostControlLimits.maxTargetJournalBytes)
        } catch {
            return .unreadable
        }
        let read = TimelineJournalReader.read(
            data, journal: sourceJournal, actor: readerActor,
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        guard read.quarantinedSuffix == nil,
              read.truncatedTail == nil,
              !read.records.isEmpty else {
            return .incomplete
        }

        // A registration cursor names the exact prefix observed by the control transaction;
        // it is not required to remain the source journal's current tip. Locate that prefix
        // before checking semantic genesis/attachment evidence. The complete read above still
        // validates every later record, so a corrupt or unverifiable suffix cannot be hidden by
        // an earlier registered cursor.
        guard cursor.sequence > 0,
              cursor.sequence <= read.records.count,
              read.records[cursor.sequence - 1].event.sequence == cursor.sequence,
              read.records[cursor.sequence - 1].event.eventID == cursor.eventID else {
            return .mismatch
        }
        let registeredRecords = Array(read.records.prefix(cursor.sequence))

        var previousEventID: String?
        var eventIDs = Set<String>()
        var attachments = Set<SessionAttachmentRef>()
        for (offset, record) in read.records.enumerated() {
            let event = record.event
            let isRegisteredPrefix = offset < cursor.sequence
            guard event.journal == sourceJournal,
                  event.sequence == offset + 1,
                  event.previousEventID == previousEventID,
                  event.provenance == .native,
                  event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  event.payloadVersion <= 1,
                  event.isKnownType,
                  controlBoundedIdentity(event.eventID),
                  eventIDs.insert(event.eventID).inserted else {
                return .mismatch
            }
            switch sourceJournal.owner {
            case .work:
                // The journal owner and Work Host authority are invariant for the entire
                // physical Work journal. Session/attachment identity is creation-pair evidence
                // only for the registered prefix: a Work can later be attached to many Sessions.
                guard event.work == expectedWork, event.workHost == workHost,
                      event.session.map({ controlBoundedIdentity($0.sessionID) }) ?? true,
                      event.sessionAttachment.map({ controlBoundedIdentity($0.attachmentID) }) ?? true else {
                    return .mismatch
                }
                if isRegisteredPrefix {
                    guard event.session.map({ $0 == expectedSession }) ?? true,
                          event.sessionAttachment.map({ $0 == expectedAttachment }) ?? true else {
                        return .mismatch
                    }
                }
            case .session:
                // A Session journal is owned by one Session, but that Session may validly
                // reference more than one Work over its lifetime. Keep the owner identity
                // strict while limiting the creation-pair Work/attachment check to the prefix.
                guard let eventSession = event.session,
                      eventSession == expectedSession,
                      controlBoundedIdentity(eventSession.sessionID),
                      event.sessionAttachment.map({ controlBoundedIdentity($0.attachmentID) }) ?? true else {
                    return .mismatch
                }
                if let eventWork = event.work {
                    guard controlBoundedIdentity(eventWork.workHostID),
                          controlBoundedIdentity(eventWork.workID),
                          event.workHost.map({ $0.workHostID == eventWork.workHostID }) ?? true else {
                        return .mismatch
                    }
                } else if event.workHost != nil {
                    return .mismatch
                }
                if isRegisteredPrefix {
                    guard event.work.map({ $0 == expectedWork }) ?? true,
                          event.workHost.map({ $0 == workHost }) ?? true,
                          event.sessionAttachment.map({ $0 == expectedAttachment }) ?? true else {
                        return .mismatch
                    }
                }
            case .workHost:
                return .mismatch
            }
            if event.type == TimelineEventType.sessionAttached {
                // Every attachment event must carry a complete, bounded identity envelope. Only
                // the registered prefix must mirror this creation's exact Session/Work pair.
                guard let attachedSession = event.session,
                      let attachedWork = event.work,
                      let attachedAttachment = event.sessionAttachment,
                      controlBoundedIdentity(attachedSession.sessionID),
                      controlBoundedIdentity(attachedWork.workHostID),
                      controlBoundedIdentity(attachedWork.workID),
                      controlBoundedIdentity(attachedAttachment.attachmentID) else {
                    return .mismatch
                }
                if isRegisteredPrefix {
                    guard attachedSession == expectedSession,
                          attachedWork == expectedWork,
                          attachedAttachment == expectedAttachment else {
                        return .mismatch
                    }
                    attachments.insert(expectedAttachment)
                }
            }
            previousEventID = event.eventID
        }

        // The envelope checks above are deliberately source-kind generic for suffix records, but
        // the canonical reducers still own per-event semantic rules (for example, a Work-side
        // attachment must have an identity envelope, and a Session attachment must reference a
        // Work). Reduce the complete read so a foreign or otherwise malformed suffix cannot be
        // hidden behind an earlier registered cursor.
        switch sourceJournal.owner {
        case .work:
            let reduced = WorkReducer.reduce(read.records.map(\TimelineJournalRecord.event))
            guard reduced.structuralIntegrityValid,
                  reduced.semanticProjectionValid,
                  reduced.unknownEvents.isEmpty else {
                return .mismatch
            }
        case .session:
            let reduced = SessionReducer.reduce(read.records.map(\TimelineJournalRecord.event))
            guard reduced.structuralIntegrityValid,
                  reduced.semanticProjectionValid,
                  reduced.unknownEvents.isEmpty else {
                return .mismatch
            }
        case .workHost:
            return .mismatch
        }

        guard let first = registeredRecords.first?.event,
              first.sequence == 1,
              first.type == expectedGenesisType,
              registeredRecords.dropFirst().allSatisfy({ $0.event.type != expectedGenesisType }) else {
            return .mismatch
        }
        var registeredPrefixData = Data()
        for record in registeredRecords {
            registeredPrefixData.append(record.rawLineBytes)
        }
        return .valid(WorkHostControlSourceJournalEvidence(
            attachments: attachments, dataDigest: controlSHA256(registeredPrefixData)))
    }

    private func sourceVerificationFailure(
        _ observation: WorkHostControlSourceObservation,
        source: WorkHostControlSourceKind
    ) -> WorkHostControlCreationSourceVerificationFailure {
        switch (source, observation) {
        case (.work, .missing): return .workSourceMissing
        case (.session, .missing): return .sessionSourceMissing
        case (.work, .unreadable): return .workSourceUnreadable
        case (.session, .unreadable): return .sessionSourceUnreadable
        case (.work, .incomplete): return .workSourceIncomplete
        case (.session, .incomplete): return .sessionSourceIncomplete
        case (.work, .mismatch): return .workSourceMismatch
        case (.session, .mismatch): return .sessionSourceMismatch
        case (.work, .valid): return .workSourceMismatch
        case (.session, .valid): return .sessionSourceMismatch
        }
    }

    private func creationMatches(
        _ reservation: WorkHostControlCreationReservation,
        _ request: WorkHostControlCreationRequest
    ) -> Bool {
        reservation.client == request.client
            && reservation.command == request.command
            && reservation.bodyDigest == request.bodyDigest
            && reservation.configurationDigest == request.configurationDigest
            && reservation.causalControlCursor == request.causalControlCursor
    }

    private func creationMatches(
        _ left: WorkHostControlCreationReservation,
        _ right: WorkHostControlCreationReservation
    ) -> Bool {
        left == right
    }

    private func registrationMatches(
        _ registration: WorkHostControlWorkRegistration,
        _ request: WorkHostControlWorkRegistrationRequest
    ) -> Bool {
        registration.reservation == request.reservation
            && registration.workJournal == request.workJournal
            && registration.sessionJournal == request.sessionJournal
            && registration.workGenesisCursor == request.workGenesisCursor
            && registration.sessionGenesisCursor == request.sessionGenesisCursor
            && registration.causalControlCursor == request.causalControlCursor
    }

    private func readControlState() throws -> (
        snapshot: WorkHostControlSnapshot,
        cursor: JournalCursor
    ) {
        let read = try self.read()
        guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal has an incomplete tail")
        }
        let snapshot = WorkHostControlReducer.reduce(
            read.records.map(\.event), initial: WorkHostControlSnapshot(journal: journal))
        guard snapshot.structuralIntegrityValid,
              snapshot.semanticProjectionValid,
              snapshot.unknownEvents.isEmpty else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is not completely projectable")
        }
        let cursor: JournalCursor
        if let event = read.records.last?.event {
            cursor = JournalCursor(journal: journal, eventID: event.eventID, sequence: event.sequence)
        } else {
            cursor = JournalCursor(journal: journal, eventID: nil, sequence: 0)
        }
        return (snapshot, cursor)
    }

    private func creationRequestDigest(
        _ request: WorkHostControlCreationRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return controlSHA256(try encoder.encode(request))
    }

    private func registrationRequestDigest(
        _ request: WorkHostControlWorkRegistrationRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return controlSHA256(try encoder.encode(request))
    }

    private func mintCreationIdentity(
        current: WorkHostControlSnapshot
    ) throws -> (
        work: WorkRef,
        session: SessionRef,
        sessionAttachment: SessionAttachmentRef
    ) {
        guard controlBoundedIdentity(workHost.workHostID) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Work Host identity is unbounded")
        }
        for _ in 0..<WorkHostControlLimits.maxIdentityMintAttempts {
            let minted = creationIdentityMinter()
            guard controlBoundedIdentity(minted.workID),
                  controlBoundedIdentity(minted.sessionID),
                  controlBoundedIdentity(minted.sessionAttachmentID) else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "Work Host minted an unbounded creation identity")
            }
            let work = WorkRef(workHostID: workHost.workHostID, workID: minted.workID)
            let session = SessionRef(minted.sessionID)
            let sessionAttachment = SessionAttachmentRef(minted.sessionAttachmentID)
            let collides = current.creations.values.contains { creation in
                creation.reservation.work == work
                    || creation.reservation.session == session
                    || creation.reservation.sessionAttachment == sessionAttachment
            }
            guard !collides else { continue }
            return (work: work, session: session, sessionAttachment: sessionAttachment)
        }
        throw TimelineJournalWriter.WriterError.invalidDraft(
            reason: "Work Host could not mint a unique creation identity")
    }

    private func appendCreationDraft(
        _ draft: TimelineEventDraft,
        digest: String,
        current: WorkHostControlSnapshot,
        causalCursor: JournalCursor
    ) async throws -> TimelineJournalCommit {
        guard causalCursor == currentCursor(of: current),
              causalCursor.journal == journal else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "creation mutation causal control cursor is stale")
        }
        let (expectedSequence, sequenceOverflow) = causalCursor.sequence.addingReportingOverflow(1)
        guard !sequenceOverflow else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal sequence cannot advance")
        }
        let preflightEvent = TimelineEvent(
            eventID: "control-preflight-\(UUID().uuidString.lowercased())",
            journal: journal, sequence: expectedSequence,
            command: draft.command, previousEventID: causalCursor.eventID,
            causedByEventID: draft.causedByEventID,
            session: draft.session, work: draft.work, workHost: draft.workHost,
            client: draft.client, sessionAttachment: draft.sessionAttachment,
            actor: readerActor, hostRecordedAt: Date(), type: draft.type,
            declaredDomains: draft.declaredDomains, payload: draft.payload)
        var preflight = WorkHostControlReducer(snapshot: current)
        preflight.apply(preflightEvent)
        guard preflight.snapshot.structuralIntegrityValid,
              preflight.snapshot.semanticProjectionValid,
              preflight.snapshot.quarantinedEvents.count == current.quarantinedEvents.count else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "creation mutation is not valid for the current control projection")
        }
        let currentData = try Self.readBoundedData(
            at: fileURL, maximum: WorkHostControlLimits.maxControlJournalBytes)
        let committedData = try Self.committedPrefixData(
            for: fileURL, journal: journal, data: currentData)
        guard committedData.count == currentData.count else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal has an unsealed suffix")
        }
        var upperBoundEventBytes = try JSONEncoder().encode(preflightEvent)
        upperBoundEventBytes.append(0x0A)
        guard currentData.count <= WorkHostControlLimits.maxControlJournalBytes
                - upperBoundEventBytes.count - 4096 else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Work Host control journal has reached its byte bound")
        }
        var boundedDraft = draft
        // Keep the request digest as the event's idempotency identity. This is metadata only and
        // does not duplicate any raw request body in the control journal.
        boundedDraft = TimelineEventDraft(
            hostSequence: draft.hostSequence, idempotencyKey: digest,
            command: draft.command, causedByEventID: draft.causedByEventID,
            parentActivityID: draft.parentActivityID,
            conversationParent: draft.conversationParent, session: draft.session,
            work: draft.work, workHost: draft.workHost, client: draft.client,
            sessionAttachment: draft.sessionAttachment,
            clientAttachment: draft.clientAttachment, run: draft.run, turn: draft.turn,
            action: draft.action, handle: draft.handle,
            clientTimestamp: draft.clientTimestamp, payloadVersion: draft.payloadVersion,
            type: draft.type, declaredDomains: draft.declaredDomains, links: draft.links,
            payload: draft.payload)
        let commit = try await writer.append(boundedDraft)
        do {
            let data = try Self.readBoundedData(
                at: fileURL, maximum: WorkHostControlLimits.maxControlJournalBytes)
            try Self.persistDurabilitySeal(
                for: fileURL, journal: journal, cursor: commit.cursor, data: data)
            return commit
        } catch {
            let reason = "Work Host control durability seal failed: \(error.localizedDescription)"
            controlFailure = reason
            throw TimelineJournalWriter.WriterError.unavailable(reason)
        }
    }

    private func currentCursor(of snapshot: WorkHostControlSnapshot) -> JournalCursor {
        JournalCursor(
            journal: journal, eventID: snapshot.lastEventID, sequence: snapshot.lastSequence)
    }

    /// Commit a control-plane mutation with one client-qualified idempotency identity.
    ///
    /// Exact duplicates are reconciled before stale-cursor validation so a caller can safely
    /// retry after losing the response. A changed envelope under the same client/Work/command ID
    /// is a conflict. New mutations must name the exact current control-journal cursor.
    private func commitMutation(
        _ identity: WorkHostControlMutationIdentity,
        command: CommandRef
    ) async throws -> TimelineJournalCommit {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        try validateMutationCommand(command, identity: identity)
        let digest = try mutationDigest(identity)
        let read = try self.read()
        guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal has an incomplete tail")
        }
        let current = WorkHostControlReducer.reduce(
            read.records.map(\.event), initial: WorkHostControlSnapshot(journal: journal))
        guard current.structuralIntegrityValid,
              current.semanticProjectionValid,
              current.unknownEvents.isEmpty else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is not completely projectable")
        }

        let prior = read.records.filter {
            $0.event.work == identity.work
                && $0.event.command?.client == identity.client
                && $0.event.command?.commandID == command.commandID
        }
        if let record = prior.first {
            guard prior.count == 1,
                  record.event.command == command,
                  record.event.type == identity.type,
                  record.event.idempotencyKey == digest else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "client-qualified control command conflicts with a prior request")
            }
            // A complete line may be visible after a failed write/synchronize boundary without
            // ever having become a durable commit. Do not turn that uncertain prefix into a
            // success receipt merely because an exact retry can read it back from page cache.
            if case .failed(let reason) = await writer.health {
                throw TimelineJournalWriter.WriterError.unavailable(reason)
            }
            return TimelineJournalCommit(
                eventRef: EventRef(journal: journal, eventID: record.event.eventID),
                cursor: JournalCursor(
                    journal: journal, eventID: record.event.eventID,
                    sequence: record.event.sequence))
        }

        // Verification is deliberately after exact-command reconciliation. Once this exact
        // acknowledgement is durable, a lost-response retry must not start depending on mutable
        // target state that may since have been archived, replaced, or become unavailable.
        if identity.type == TimelineEventType.clientReadAcknowledged,
           let targetJournal = identity.targetJournal,
           let targetCursor = identity.targetCursor {
            try verifyTargetCursor(journal: targetJournal, cursor: targetCursor)
        }

        let actualCursor: JournalCursor
        if let last = read.records.last?.event {
            actualCursor = JournalCursor(
                journal: journal, eventID: last.eventID, sequence: last.sequence)
        } else {
            actualCursor = JournalCursor(journal: journal, eventID: nil, sequence: 0)
        }
        guard identity.causalControlCursor == actualCursor else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control mutation causal cursor is stale")
        }

        let payload = controlPayload(
            workJournal: identity.workJournal,
            sessionJournal: identity.sessionJournal,
            targetJournal: identity.targetJournal,
            cursor: identity.targetCursor,
            capabilities: identity.capabilities.map(Set.init))
        let draft = TimelineEventDraft(
            idempotencyKey: digest, command: command, session: identity.session,
            work: identity.work, workHost: workHost, client: identity.client,
            sessionAttachment: identity.sessionAttachment,
            clientAttachment: identity.attachment, type: identity.type,
            declaredDomains: [.work], payload: payload)

        // Refuse a semantically invalid event before it becomes an immutable journal fact. The
        // writer will assign a different event ID/time, neither of which affects reducer validity.
        let (expectedSequence, sequenceOverflow) = actualCursor.sequence.addingReportingOverflow(1)
        guard !sequenceOverflow else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal sequence cannot advance")
        }
        let preflightEvent = TimelineEvent(
            eventID: "control-preflight-\(UUID().uuidString.lowercased())",
            journal: journal, sequence: expectedSequence,
            command: command, previousEventID: actualCursor.eventID,
            session: identity.session, work: identity.work, workHost: workHost,
            client: identity.client, sessionAttachment: identity.sessionAttachment,
            clientAttachment: identity.attachment, actor: readerActor,
            hostRecordedAt: Date(), type: identity.type, declaredDomains: [.work],
            payload: payload)
        var preflight = WorkHostControlReducer(snapshot: current)
        preflight.apply(preflightEvent)
        guard preflight.snapshot.structuralIntegrityValid,
              preflight.snapshot.semanticProjectionValid,
              preflight.snapshot.quarantinedEvents.count == current.quarantinedEvents.count else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control mutation is not valid for the current attachment state")
        }
        let currentData = try Self.readBoundedData(
            at: fileURL, maximum: WorkHostControlLimits.maxControlJournalBytes)
        let committedData = try Self.committedPrefixData(
            for: fileURL, journal: journal, data: currentData)
        guard committedData.count == currentData.count else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal has an unsealed suffix")
        }
        var upperBoundEventBytes = try JSONEncoder().encode(preflightEvent)
        upperBoundEventBytes.append(0x0A)
        // The preflight ID is longer than production UUIDs; the small fixed margin also covers
        // representation differences in an injected clock. Refuse before append so the first
        // byte beyond the bounded journal can never be written by this owner.
        guard currentData.count <= WorkHostControlLimits.maxControlJournalBytes
                - upperBoundEventBytes.count - 4096 else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Work Host control journal has reached its byte bound")
        }
        let commit = try await writer.append(draft)
        do {
            let data = try Self.readBoundedData(
                at: fileURL, maximum: WorkHostControlLimits.maxControlJournalBytes)
            try Self.persistDurabilitySeal(
                for: fileURL, journal: journal, cursor: commit.cursor, data: data)
            return commit
        } catch {
            let reason = "Work Host control durability seal failed: \(error.localizedDescription)"
            controlFailure = reason
            throw TimelineJournalWriter.WriterError.unavailable(reason)
        }
    }

    private func acquireMutationGate() async {
        if !mutationInFlight {
            mutationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationGate() {
        if mutationWaiters.isEmpty {
            mutationInFlight = false
        } else {
            // Ownership passes directly to the oldest waiter. Keeping the flag set prevents a
            // newly arriving call from overtaking the resumed mutation at this actor boundary.
            mutationWaiters.removeFirst().resume()
        }
    }

    private func validateMutationCommand(
        _ command: CommandRef,
        identity: WorkHostControlMutationIdentity
    ) throws {
        let identities = [
            command.commandID,
            identity.client.clientID,
            identity.attachment.attachmentID,
            identity.work.workHostID,
            identity.work.workID,
        ]
        guard identities.allSatisfy({
            isBoundedIdentity($0)
        }),
            command.client == identity.client,
            command.sessionAttachment == identity.sessionAttachment,
            command.causalCursor == identity.causalControlCursor,
            identity.causalControlCursor.journal == journal,
            isBoundedJournal(identity.workJournal),
            isBoundedCursor(identity.causalControlCursor),
            identity.session.map({ isBoundedIdentity($0.sessionID) }) ?? true,
            identity.sessionJournal.map(isBoundedJournal) ?? true,
            identity.sessionAttachment.map({ isBoundedIdentity($0.attachmentID) }) ?? true,
            identity.targetJournal.map(isBoundedJournal) ?? true,
            identity.targetCursor.map(isBoundedCursor) ?? true
        else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control command must carry bounded identities and the exact control cursor")
        }
    }

    private func validateCapabilities(_ capabilities: Set<String>) throws {
        guard capabilities.count <= WorkHostControlLimits.maxCapabilities,
              capabilities.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.utf8.count <= WorkHostControlLimits.maxCapabilityCharacters
              }) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control capabilities exceed the bounded contract")
        }
    }

    private func mutationDigest(_ identity: WorkHostControlMutationIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Resolve and read the target journal inside the Work Host. The remote caller supplies only
    /// a journal identity and cursor; it cannot mint a proof object or choose a filesystem path.
    private func verifyTargetCursor(journal targetJournal: JournalRef, cursor: JournalCursor) throws {
        guard isBoundedJournal(targetJournal), isBoundedCursor(cursor) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement target identities exceed the bounded contract")
        }
        guard let home else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement requires a Work Host AgentHome")
        }
        let targetURL: URL
        switch targetJournal.owner {
        case .work(let work):
            targetURL = home.timelineV2WorkJournalURL(work)
        case .session(let session):
            targetURL = home.timelineV2SessionJournalURL(sessionID: session.sessionID)
        case .workHost:
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control journals cannot acknowledge themselves as a read target")
        }

        let descriptor = targetURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement target is unavailable")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_uid == geteuid(),
              fileStatus.st_size >= 0,
              fileStatus.st_size <= WorkHostControlLimits.maxTargetJournalBytes else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement target is not a bounded owner-readable file")
        }
        var data = Data()
        while data.count <= WorkHostControlLimits.maxTargetJournalBytes {
            let remaining = WorkHostControlLimits.maxTargetJournalBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(1024 * 1024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= WorkHostControlLimits.maxTargetJournalBytes else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement target exceeds the byte bound")
        }
        let read = TimelineJournalReader.read(
            data, journal: targetJournal, actor: readerActor,
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        try validateTargetRead(read, journal: targetJournal, cursor: cursor)
    }

    private func validateTargetRead(
        _ read: TimelineJournalReadResult,
        journal targetJournal: JournalRef,
        cursor: JournalCursor
    ) throws {
        guard cursor.journal == targetJournal,
              read.quarantinedSuffix == nil,
              read.truncatedTail == nil else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement requires a complete canonical target read")
        }
        var previousEventID: String?
        var eventIDs = Set<String>()
        for (offset, record) in read.records.enumerated() {
            let event = record.event
            guard event.journal == targetJournal,
                  event.sequence == offset + 1,
                  event.previousEventID == previousEventID,
                  event.provenance == .native,
                  event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  eventIDs.insert(event.eventID).inserted else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "read acknowledgement target is not one canonical append chain")
            }
            previousEventID = event.eventID
        }
        if cursor.sequence == 0 {
            guard cursor.eventID == nil, read.records.isEmpty else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "empty read acknowledgement does not match the target journal")
            }
        } else {
            guard cursor.sequence > 0,
                  read.records.contains(where: {
                      $0.event.sequence == cursor.sequence && $0.event.eventID == cursor.eventID
                  }) else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "read acknowledgement cursor is absent from the target journal")
            }
        }
    }

    private func validateWorkTarget(work: WorkRef, journal: JournalRef) throws {
        guard isBoundedIdentity(work.workHostID),
              isBoundedIdentity(work.workID),
              isBoundedJournal(journal),
              work.workHostID == workHost.workHostID,
              journal.owner == .work(work),
              journal.authority.authorityID == work.workHostID else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control event Work and Work journal must belong to this Work Host")
        }
    }

    private func validateSessionContext(
        session: SessionRef?,
        sessionJournal: JournalRef?,
        sessionAttachment: SessionAttachmentRef?
    ) throws {
        switch (session, sessionJournal, sessionAttachment) {
        case (nil, nil, nil):
            return
        case (.some(let session), .some(let journal), .some(let attachment)):
            guard isBoundedIdentity(session.sessionID),
                  isBoundedIdentity(attachment.attachmentID),
                  isBoundedJournal(journal),
                  journal.owner == .session(session) else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "control event Session context must name one matching Session journal")
            }
        default:
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control event Session, Session journal, and attachment are all-or-none")
        }
    }

    private func isBoundedIdentity(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= WorkHostControlLimits.maxIdentityCharacters
    }

    private func isBoundedJournal(_ journal: JournalRef) -> Bool {
        guard isBoundedIdentity(journal.journalID),
              isBoundedIdentity(journal.authority.authorityID) else { return false }
        switch journal.owner {
        case .work(let work):
            return isBoundedIdentity(work.workHostID) && isBoundedIdentity(work.workID)
        case .session(let session):
            return isBoundedIdentity(session.sessionID)
        case .workHost(let host):
            return isBoundedIdentity(host.workHostID)
        }
    }

    private func isBoundedCursor(_ cursor: JournalCursor) -> Bool {
        guard isBoundedJournal(cursor.journal), cursor.sequence >= 0 else { return false }
        if cursor.sequence == 0 { return cursor.eventID == nil }
        guard let eventID = cursor.eventID else { return false }
        return isBoundedIdentity(eventID)
    }

    private func controlPayload(
        workJournal: JournalRef,
        sessionJournal: JournalRef? = nil,
        targetJournal: JournalRef? = nil,
        cursor: JournalCursor? = nil,
        capabilities: Set<String>? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = ["work_journal": encodeControlValue(workJournal)]
        if let sessionJournal { object["session_journal"] = encodeControlValue(sessionJournal) }
        if let targetJournal { object["target_journal"] = encodeControlValue(targetJournal) }
        if let cursor { object["cursor"] = encodeControlValue(cursor) }
        if let capabilities {
            object["capabilities"] = .array(capabilities.sorted().map { .string($0) })
        }
        return .object(object)
    }

    /// Validate the independently synchronized high-water mark used by both the live owner and
    /// cold catalog readers. A complete JSONL line without this exact seal is readable evidence,
    /// but it is not a committed control-plane fact.
    static func validateDurabilitySeal(
        for journalURL: URL,
        journal: JournalRef,
        data: Data
    ) throws {
        _ = try committedPrefixData(for: journalURL, journal: journal, data: data)
    }

    /// Return only bytes proven by the last independently synchronized seal. A suffix beyond
    /// that high-water mark belongs to an interrupted control transaction and must never hide the
    /// earlier committed attachment/read state.
    static func committedPrefixData(
        for journalURL: URL,
        journal: JournalRef,
        data: Data
    ) throws -> Data {
        guard data.count <= WorkHostControlLimits.maxControlJournalBytes else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal exceeds its byte bound")
        }
        let sealData = try readBoundedData(
            at: durabilitySealURL(for: journalURL),
            maximum: WorkHostControlLimits.maxDurabilitySealBytes)
        let seal: WorkHostControlDurabilitySeal
        do {
            seal = try JSONDecoder().decode(WorkHostControlDurabilitySeal.self, from: sealData)
        } catch {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability seal is malformed")
        }
        guard seal.byteCount >= 0, seal.byteCount <= data.count else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability seal exceeds the readable journal")
        }
        let committed = Data(data.prefix(seal.byteCount))
        let expectedCursor = try canonicalTip(journal: journal, data: committed)
        guard seal.schemaVersion == 1,
              seal.journal == journal,
              seal.cursor == expectedCursor,
              seal.sha256 == sha256(committed) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability seal does not match the journal prefix")
        }
        return committed
    }

    static func durabilitySealURL(for journalURL: URL) -> URL {
        journalURL.appendingPathExtension("commit")
    }

    private static func persistDurabilitySeal(
        for journalURL: URL,
        journal: JournalRef,
        cursor: JournalCursor,
        data: Data
    ) throws {
        let canonicalCursor = try canonicalTip(journal: journal, data: data)
        guard canonicalCursor == cursor else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control commit does not match its journal tip")
        }
        let seal = WorkHostControlDurabilitySeal(
            schemaVersion: 1, journal: journal, cursor: cursor,
            byteCount: data.count, sha256: sha256(data))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(seal)
        bytes.append(0x0A)
        guard bytes.count <= WorkHostControlLimits.maxDurabilitySealBytes else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability seal exceeds its byte bound")
        }

        let sealURL = durabilitySealURL(for: journalURL)
        let directory = sealURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appending(
            path: ".control-commit-\(UUID().uuidString.lowercased()).tmp",
            directoryHint: .notDirectory)
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not create Work Host control durability seal")
        }
        defer {
            Darwin.close(descriptor)
            _ = temporaryURL.path.withCString { Darwin.unlink($0) }
        }
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor, base.advanced(by: written), bytes.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw TimelineJournalWriter.WriterError.unavailable(
                        "could not write Work Host control durability seal")
                }
                written += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not synchronize Work Host control durability seal")
        }
        let renamed = temporaryURL.path.withCString { source in
            sealURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renamed == 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not publish Work Host control durability seal")
        }
        let directoryDescriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not open Work Host control directory for synchronization")
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not synchronize Work Host control directory")
        }
    }

    private static func canonicalTip(journal: JournalRef, data: Data) throws -> JournalCursor {
        if data.isEmpty {
            return JournalCursor(journal: journal, eventID: nil, sequence: 0)
        }
        let read = TimelineJournalReader.read(
            data, journal: journal,
            actor: TimelineActor(actorID: "control-durability", kind: "reader"),
            hostRecordedAt: Date(timeIntervalSince1970: 0))
        guard read.quarantinedSuffix == nil, read.truncatedTail == nil,
              !read.records.isEmpty else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability seal requires one complete append chain")
        }
        var previousEventID: String?
        var eventIDs = Set<String>()
        for (offset, record) in read.records.enumerated() {
            let event = record.event
            guard event.journal == journal,
                  event.sequence == offset + 1,
                  event.previousEventID == previousEventID,
                  event.provenance == .native,
                  event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  eventIDs.insert(event.eventID).inserted else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "Work Host control durability seal requires one canonical append chain")
            }
            previousEventID = event.eventID
        }
        let last = read.records[read.records.count - 1].event
        return JournalCursor(journal: journal, eventID: last.eventID, sequence: last.sequence)
    }

    /// Called by TimelineJournalWriter only after it holds the long-lived owner lock. This keeps
    /// seal revalidation, optional sequence-zero recovery, suffix truncation, and writer sequence
    /// initialization inside one uninterrupted ownership interval.
    private static func recoverableCommittedByteCount(
        for journalURL: URL,
        journal: JournalRef,
        data: Data
    ) throws -> Int {
        do {
            return try committedPrefixData(
                for: journalURL, journal: journal, data: data)
                .count
        } catch {
            let sealURL = durabilitySealURL(for: journalURL)
            var sealStatus = stat()
            let sealResult = sealURL.path.withCString { Darwin.lstat($0, &sealStatus) }
            guard data.isEmpty, sealResult != 0, errno == ENOENT else { throw error }
            let zero = JournalCursor(journal: journal, eventID: nil, sequence: 0)
            try persistDurabilitySeal(
                for: journalURL, journal: journal, cursor: zero, data: Data())
            return 0
        }
    }

    private static func readBoundedData(at url: URL, maximum: Int) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "required Work Host control durability data is unavailable")
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size >= 0,
              status.st_size <= off_t(maximum) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability data is not one bounded owner file")
        }
        var data = Data()
        while data.count <= maximum {
            var buffer = [UInt8](
                repeating: 0, count: min(1024 * 1024, maximum + 1 - data.count))
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "Work Host control durability data could not be read")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximum else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability data exceeds its byte bound")
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}

private func encodeControlValue<T: Encodable>(_ value: T) -> JSONValue {
    guard let data = try? JSONEncoder().encode(value),
          let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return .null
    }
    return decoded
}

private func decodeControlValue<T: Decodable>(_ value: JSONValue) -> T? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
