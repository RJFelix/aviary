import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum WorkHostControlLimits {
    static let maxIdentityCharacters = 256
    static let maxIdentityMintAttempts = 32
    static let maxCapabilities = 64
    static let maxCapabilityCharacters = 128
    static let maxDigestCharacters = 80
    static let sourceAbsenceVerificationChunkBytes = 64 * 1024
    static let maxDurabilitySealBytes = 16 * 1024
    static let maxProjectedRegistrationPrefixBytes = 64 * 1024 * 1024
    /// Temporary supported state envelope until the persistent projection store lands. This is a
    /// record-count bound, not a journal byte ceiling; it keeps reducer copy-on-write costs
    /// explicit rather than silently accepting an unbounded projection.
    static let maxSupportedControlRecords = 1_000_000
}

/// Control-plane event names that are intentionally kept here until the general Timeline event
/// catalog has a first-class Work Host transaction namespace. They are still ordinary Timeline
/// events: unknown reducers retain them, while this reducer understands the current schema.
public enum WorkHostControlEventType {
    public static let creationReserved = "creation.reserved"
    public static let workRegistered = "work.registered"
    /// A Session relationship is reserved in the Work Host control journal before either
    /// source journal is touched.  The source-journal result is recorded separately because
    /// these files do not share an atomic commit primitive yet.
    public static let sessionCreationReserved = "session_creation.reserved"
    public static let sessionCreationCompleted = "session_creation.completed"
    /// A reservation may be resolved only after a fresh, owner-locked source check proves that
    /// no Session source claim exists.  This is not a generic cancellation or timeout event.
    public static let sessionCreationAborted = "session_creation.aborted"
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
    "sha256:" + AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The caller's Create cursor was compared with the current control projection while holding
/// the canonical mutation gate. This proves rejection before append, rather than an unknown
/// append failure, so the service boundary may safely expose the exact cursor pair.
public struct WorkHostControlCreationStaleCursorError: Error, Equatable, Sendable {
    public let expected: JournalCursor
    public let actual: JournalCursor

    public init(expected: JournalCursor, actual: JournalCursor) {
        self.expected = expected
        self.actual = actual
    }
}

/// A small streaming SHA-256 implementation used only for the control journal seal.  The
/// platform digest helper intentionally exposes a one-shot API; keeping this state here means an
/// append extends the prior seal without retaining or hashing the complete history again.
private struct ControlSHA256State: Sendable {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pending: [UInt8] = []
    private var byteCount: UInt64 = 0

    mutating func update(_ data: Data) {
        byteCount += UInt64(data.count)
        pending.append(contentsOf: data)
        while pending.count >= 64 {
            let block = Array(pending.prefix(64))
            pending.removeFirst(64)
            compress(block)
        }
    }

    func hexDigest() -> String {
        var copy = self
        let bitCount = copy.byteCount &* 8
        copy.pending.append(0x80)
        while copy.pending.count % 64 != 56 { copy.pending.append(0) }
        copy.pending.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian, Array.init))
        while !copy.pending.isEmpty {
            let block = Array(copy.pending.prefix(64))
            copy.pending.removeFirst(64)
            copy.compress(block)
        }
        return copy.state.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func compress(_ block: [UInt8]) {
        let constants: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
            0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
            0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
            0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
            0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
            0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
            0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
            0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = index * 4
            words[index] = UInt32(block[base]) << 24 | UInt32(block[base + 1]) << 16
                | UInt32(block[base + 2]) << 8 | UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let value = words[index - 15]
            let s0 = value.rotateRight(7) ^ value.rotateRight(18) ^ (value >> 3)
            let prior = words[index - 2]
            let s1 = prior.rotateRight(17) ^ prior.rotateRight(19) ^ (prior >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for index in 0..<64 {
            let s1 = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
            let choose = (e & f) ^ ((~e) & g)
            let first = h &+ s1 &+ choose &+ constants[index] &+ words[index]
            let s0 = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let second = s0 &+ majority
            h = g; g = f; f = e; e = d &+ first
            d = c; c = b; b = a; a = first &+ second
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

private extension UInt32 {
    func rotateRight(_ amount: UInt32) -> UInt32 {
        (self >> amount) | (self << (32 - amount))
    }
}

private struct WorkHostControlDurabilitySeal: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let journal: JournalRef
    let cursor: JournalCursor
    let byteCount: Int
    let sha256: String
}

/// Read-path observations for proving that a live control journal extends from its cache. These
/// counters are diagnostics only and never participate in journal identity or admission. Normal
/// mutation CPU is not claimed to be O(delta): one reducer preflight can trigger Swift
/// copy-on-write across the bounded control-state envelope above.
public struct WorkHostControlJournalReadMetrics: Codable, Hashable, Sendable {
    public let fullReads: Int
    public let cacheHits: Int
    public let incrementalReads: Int
    public let invalidations: Int
    public let bytesScanned: Int
    public let recordsApplied: Int
    public let targetVerificationBytesScanned: Int
    public let targetVerificationChunks: Int
    public let targetVerificationPeakChunkBytes: Int
    /// Durable Work source projection observations. These are separate from control-journal
    /// bytes because the Work projection is a source-read adapter, not control authority.
    public let projectedWorkReadCalls: Int
    public let projectedWorkCacheHits: Int
    public let projectedWorkBytesRead: Int
    public let projectedWorkSuffixBytesRead: Int
    public let projectedWorkPrefixBytesRead: Int
    /// Durable Session source projection observations. Session and Work are measured separately
    /// because either journal may grow independently and neither total should disguise the
    /// other's canonical verification cost.
    public let projectedSessionReadCalls: Int
    public let projectedSessionCacheHits: Int
    public let projectedSessionBytesRead: Int
    public let projectedSessionSuffixBytesRead: Int
    public let projectedSessionPrefixBytesRead: Int

    public init(
        fullReads: Int = 0, cacheHits: Int = 0, incrementalReads: Int = 0,
        invalidations: Int = 0, bytesScanned: Int = 0, recordsApplied: Int = 0,
        targetVerificationBytesScanned: Int = 0, targetVerificationChunks: Int = 0,
        targetVerificationPeakChunkBytes: Int = 0,
        projectedWorkReadCalls: Int = 0, projectedWorkCacheHits: Int = 0,
        projectedWorkBytesRead: Int = 0, projectedWorkSuffixBytesRead: Int = 0,
        projectedWorkPrefixBytesRead: Int = 0,
        projectedSessionReadCalls: Int = 0, projectedSessionCacheHits: Int = 0,
        projectedSessionBytesRead: Int = 0, projectedSessionSuffixBytesRead: Int = 0,
        projectedSessionPrefixBytesRead: Int = 0
    ) {
        self.fullReads = fullReads
        self.cacheHits = cacheHits
        self.incrementalReads = incrementalReads
        self.invalidations = invalidations
        self.bytesScanned = bytesScanned
        self.recordsApplied = recordsApplied
        self.targetVerificationBytesScanned = targetVerificationBytesScanned
        self.targetVerificationChunks = targetVerificationChunks
        self.targetVerificationPeakChunkBytes = targetVerificationPeakChunkBytes
        self.projectedWorkReadCalls = max(0, projectedWorkReadCalls)
        self.projectedWorkCacheHits = max(0, projectedWorkCacheHits)
        self.projectedWorkBytesRead = max(0, projectedWorkBytesRead)
        self.projectedWorkSuffixBytesRead = max(0, projectedWorkSuffixBytesRead)
        self.projectedWorkPrefixBytesRead = max(0, projectedWorkPrefixBytesRead)
        self.projectedSessionReadCalls = max(0, projectedSessionReadCalls)
        self.projectedSessionCacheHits = max(0, projectedSessionCacheHits)
        self.projectedSessionBytesRead = max(0, projectedSessionBytesRead)
        self.projectedSessionSuffixBytesRead = max(0, projectedSessionSuffixBytesRead)
        self.projectedSessionPrefixBytesRead = max(0, projectedSessionPrefixBytesRead)
    }
}

struct WorkHostControlMutationIdentity: Codable, Hashable, Sendable {
    let type: String
    let work: WorkRef
    let workJournal: JournalRef
    let attachment: ClientAttachmentRef
    let client: ClientRef
    let session: SessionRef?
    let sessionJournal: JournalRef?
    let sessionAttachment: SessionAttachmentRef?
    let capabilities: [String]?
    /// The caller's requested capability envelope is distinct from the host's granted set. It is
    /// retained in the digest so two requests which reduce to the same grant cannot alias one
    /// another under a client/Work/command identity.
    let requestedCapabilities: [String]?
    let targetJournal: JournalRef?
    let targetCursor: JournalCursor?
    let causalControlCursor: JournalCursor
}

/// A previously committed control mutation. This is an internal reconciliation seam: callers
/// still have to validate the request envelope before turning the record into a response, while
/// the journal remains the only authority for the resulting cursor/event identity.
struct WorkHostControlPriorMutation: Sendable {
    let event: TimelineEvent
    let commit: TimelineJournalCommit
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

/// The bounded control-plane intent for adding a Session to an existing Work.  All Session,
/// SessionAttachment, and ClientAttachment identities are host-minted and are present here
/// before source-journal publication.  This is deliberately separate from WorkService's wire
/// request: the control journal stores the complete retry identity, not an untrusted request
/// object or any source body.
public struct WorkHostControlSessionCreationRequest: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let workJournal: JournalRef
    public let authorizingAttachment: ClientAttachmentRef
    public let client: ClientRef
    public let command: CommandRef
    public let causalControlCursor: JournalCursor
    public let causalWorkCursor: JournalCursor
    public let requestedCapabilities: [String]
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let clientAttachment: ClientAttachmentRef

    public init(
        work: WorkRef,
        workJournal: JournalRef,
        authorizingAttachment: ClientAttachmentRef,
        client: ClientRef,
        command: CommandRef,
        causalControlCursor: JournalCursor,
        causalWorkCursor: JournalCursor,
        requestedCapabilities: [String],
        session: SessionRef,
        sessionJournal: JournalRef,
        sessionAttachment: SessionAttachmentRef,
        clientAttachment: ClientAttachmentRef
    ) {
        self.work = work
        self.workJournal = workJournal
        self.authorizingAttachment = authorizingAttachment
        self.client = client
        self.command = command
        self.causalControlCursor = causalControlCursor
        self.causalWorkCursor = causalWorkCursor
        self.requestedCapabilities = requestedCapabilities.sorted()
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.clientAttachment = clientAttachment
    }

    public var key: String {
        controlSessionCreationKey(work: work, client: client, commandID: command.commandID)
    }
}

/// Source-journal evidence recorded after a Session relationship reservation.  Event refs and
/// cursors are retained rather than inferred from prose, so a restart can either replay the
/// exact response or expose the reservation as incomplete. `publication` is the wire enum's
/// stable raw value (`mirrored` or `terminal_reference`) to keep this control file independent
/// of the transport module.
public struct WorkHostControlSessionCreationResult: Codable, Hashable, Sendable {
    public let causalControlCursor: JournalCursor
    /// The control-journal cursor of the durable `session_creation.completed` event. This is
    /// captured from the append commit rather than reread after the mutation gate is released.
    public let resultingControlCursor: JournalCursor
    public let publication: String
    public let capabilities: [String]
    public let causalSessionCursor: JournalCursor
    public let sessionCursor: JournalCursor
    public let causalWorkCursor: JournalCursor
    public let resultingWorkCursor: JournalCursor
    public let sessionCreatedEvent: EventRef
    public let sessionAttachedEvent: EventRef
    public let workMirrorEvent: EventRef?
    public let cursorAdvancedEvent: EventRef
    public let resultEvent: EventRef

    public init(
        causalControlCursor: JournalCursor,
        resultingControlCursor: JournalCursor,
        publication: String,
        capabilities: [String],
        causalSessionCursor: JournalCursor,
        sessionCursor: JournalCursor,
        causalWorkCursor: JournalCursor,
        resultingWorkCursor: JournalCursor,
        sessionCreatedEvent: EventRef,
        sessionAttachedEvent: EventRef,
        workMirrorEvent: EventRef?,
        cursorAdvancedEvent: EventRef,
        resultEvent: EventRef
    ) {
        self.causalControlCursor = causalControlCursor
        self.resultingControlCursor = resultingControlCursor
        self.publication = publication
        self.capabilities = capabilities.sorted()
        self.causalSessionCursor = causalSessionCursor
        self.sessionCursor = sessionCursor
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.sessionCreatedEvent = sessionCreatedEvent
        self.sessionAttachedEvent = sessionAttachedEvent
        self.workMirrorEvent = workMirrorEvent
        self.cursorAdvancedEvent = cursorAdvancedEvent
        self.resultEvent = resultEvent
    }
}

/// Source evidence supplied when the multi-journal operation reaches its result boundary. The
/// control journal validates this against its reservation and assigns the control result event
/// identity itself; callers cannot forge that final EventRef.
public struct WorkHostControlSessionCreationResultRequest: Codable, Hashable, Sendable {
    public let reservationEvent: EventRef
    public let commandID: String
    public let causalControlCursor: JournalCursor
    public let publication: String
    public let capabilities: [String]
    public let causalSessionCursor: JournalCursor
    public let sessionCursor: JournalCursor
    public let causalWorkCursor: JournalCursor
    public let resultingWorkCursor: JournalCursor
    public let sessionCreatedEvent: EventRef
    public let sessionAttachedEvent: EventRef
    public let workMirrorEvent: EventRef?
    public let cursorAdvancedEvent: EventRef

    public init(
        reservationEvent: EventRef,
        commandID: String,
        causalControlCursor: JournalCursor,
        publication: String,
        capabilities: [String],
        causalSessionCursor: JournalCursor,
        sessionCursor: JournalCursor,
        causalWorkCursor: JournalCursor,
        resultingWorkCursor: JournalCursor,
        sessionCreatedEvent: EventRef,
        sessionAttachedEvent: EventRef,
        workMirrorEvent: EventRef?,
        cursorAdvancedEvent: EventRef
    ) {
        self.reservationEvent = reservationEvent
        self.commandID = commandID
        self.causalControlCursor = causalControlCursor
        self.publication = publication
        self.capabilities = capabilities.sorted()
        self.causalSessionCursor = causalSessionCursor
        self.sessionCursor = sessionCursor
        self.causalWorkCursor = causalWorkCursor
        self.resultingWorkCursor = resultingWorkCursor
        self.sessionCreatedEvent = sessionCreatedEvent
        self.sessionAttachedEvent = sessionAttachedEvent
        self.workMirrorEvent = workMirrorEvent
        self.cursorAdvancedEvent = cursorAdvancedEvent
    }
}

/// Durable resolution for a Session reservation whose source operation is proven not to have
/// created a Session journal.  The only currently supported outcome is `sourcePresence == .none`;
/// partial or indeterminate source prefixes remain blocked and retryable.
public struct WorkHostControlSessionCreationAbort: Codable, Hashable, Sendable {
    public let causalControlCursor: JournalCursor
    public let resultingControlCursor: JournalCursor
    public let sourcePresence: WorkHostControlCreationSourcePresence
    public let resultEvent: EventRef

    public init(
        causalControlCursor: JournalCursor,
        resultingControlCursor: JournalCursor,
        sourcePresence: WorkHostControlCreationSourcePresence,
        resultEvent: EventRef
    ) {
        self.causalControlCursor = causalControlCursor
        self.resultingControlCursor = resultingControlCursor
        self.sourcePresence = sourcePresence
        self.resultEvent = resultEvent
    }
}

public struct WorkHostControlSessionCreationSnapshot: Codable, Hashable, Sendable {
    public let reservation: WorkHostControlSessionCreationRequest
    public let reservationEvent: EventRef
    public let reservationCursor: JournalCursor
    public var result: WorkHostControlSessionCreationResult?
    public var abort: WorkHostControlSessionCreationAbort?
    public var isConflicted: Bool
    public var conflictEventRefs: [EventRef]

    public init(
        reservation: WorkHostControlSessionCreationRequest,
        reservationEvent: EventRef,
        reservationCursor: JournalCursor,
        result: WorkHostControlSessionCreationResult? = nil,
        abort: WorkHostControlSessionCreationAbort? = nil,
        isConflicted: Bool = false,
        conflictEventRefs: [EventRef] = []
    ) {
        self.reservation = reservation
        self.reservationEvent = reservationEvent
        self.reservationCursor = reservationCursor
        self.result = result
        self.abort = abort
        self.isConflicted = isConflicted
        self.conflictEventRefs = Array(conflictEventRefs.prefix(TimelineEvent.maxEvidenceLinks))
    }

    public var isResolved: Bool { result != nil || abort != nil }
}

/// The owner-mediated result of the cross-journal Session publication saga. The control mutation
/// gate remains held while the source writers run, so the result always spans exactly one
/// reservation and one completion event; another control mutation cannot silently widen it.
public struct WorkHostControlSessionCreationPublication: Sendable {
    public let reservation: WorkHostControlSessionCreationSnapshot
    public let source: RunJournalBundleSessionPublication
    public let result: WorkHostControlSessionCreationResult

    public var resultingControlCursor: JournalCursor { result.resultingControlCursor }

    public init(
        reservation: WorkHostControlSessionCreationSnapshot,
        source: RunJournalBundleSessionPublication,
        result: WorkHostControlSessionCreationResult
    ) {
        self.reservation = reservation
        self.source = source
        self.result = result
    }
}

private func controlSessionCreationKey(
    work: WorkRef, client: ClientRef, commandID: String
) -> String {
    "work:\(work.workHostID.utf8.count):\(work.workHostID)/\(work.workID.utf8.count):\(work.workID)/"
        + controlLengthPrefixedKey(client, commandID: commandID)
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
    /// Session relationship transactions are keyed by the existing Work/client/command tuple.
    /// A reservation without a result is intentionally visible to recovery code but is never a
    /// Session or attachment fact until the source journals prove the corresponding result.
    public var sessionCreations: [String: WorkHostControlSessionCreationSnapshot] = [:]
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

    public func sessionCreation(
        work: WorkRef, client: ClientRef, commandID: String
    ) -> WorkHostControlSessionCreationSnapshot? {
        sessionCreations[controlSessionCreationKey(
            work: work, client: client, commandID: commandID)]
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
        case WorkHostControlEventType.sessionCreationReserved:
            applySessionCreationReserved(event)
        case WorkHostControlEventType.sessionCreationCompleted:
            applySessionCreationCompleted(event)
        case WorkHostControlEventType.sessionCreationAborted:
            applySessionCreationAborted(event)
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

    // MARK: Existing-Work Session transactions

    /// Reduce the reservation half of an existing-Work Session transaction. This record is
    /// intentionally not a client attachment: until the source journals are proven, exposing
    /// it as an attachment would turn a control-plane intent into a false Session fact.
    private mutating func applySessionCreationReserved(_ event: TimelineEvent) {
        guard let work = event.work,
              let workHost = event.workHost,
              let client = event.client,
              let command = event.command,
              let session = event.session,
              let sessionAttachment = event.sessionAttachment,
              let clientAttachment = event.clientAttachment,
              command.client == client,
              command.sessionAttachment == nil,
              let causalControlCursor = command.causalCursor,
              causalControlCursor == controlCursorBefore(event),
              let workJournal: JournalRef = event.payload["work_journal"].flatMap(decodeControlValue),
              let sessionJournal: JournalRef = event.payload["session_journal"].flatMap(decodeControlValue),
              let authorizingAttachment: ClientAttachmentRef = event.payload[
                  "authorizing_attachment"].flatMap(decodeControlValue),
              let causalWorkCursor: JournalCursor = event.payload["causal_work_cursor"].flatMap(
                  decodeControlValue),
              let requestedCapabilities = controlCapabilities(
                  event.payload["requested_capabilities"]),
              controlSessionCreationPayloadIsExact(event.payload),
              work.workHostID == workHost.workHostID,
              workJournal.owner == .work(work),
              workJournal.authority.authorityID == workHost.workHostID,
              causalWorkCursor.journal == workJournal,
              sessionJournal.owner == .session(session),
              sessionJournal.authority.authorityID == workHost.workHostID,
              controlBoundedIdentity(authorizingAttachment.attachmentID),
              controlBoundedIdentity(work.workHostID),
              controlBoundedIdentity(work.workID),
              controlBoundedIdentity(client.clientID),
              controlBoundedIdentity(command.commandID),
              controlBoundedIdentity(session.sessionID),
              controlBoundedIdentity(sessionAttachment.attachmentID),
              controlBoundedIdentity(clientAttachment.attachmentID),
              controlBoundedCursor(causalWorkCursor),
              controlBoundedCursor(causalControlCursor) else {
            quarantine(event, reason: "Work Host Session creation reservation is malformed")
            return
        }
        let request = WorkHostControlSessionCreationRequest(
            work: work, workJournal: workJournal, authorizingAttachment: authorizingAttachment,
            client: client, command: command,
            causalControlCursor: causalControlCursor, causalWorkCursor: causalWorkCursor,
            requestedCapabilities: requestedCapabilities, session: session,
            sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
            clientAttachment: clientAttachment)
        let key = request.key
        if let existing = snapshot.sessionCreations[key] {
            guard existing.reservation == request else {
                markSessionCreationConflict(key: key, event: event)
                return
            }
            return
        }
        snapshot.sessionCreations[key] = WorkHostControlSessionCreationSnapshot(
            reservation: request,
            reservationEvent: EventRef(journal: event.journal, eventID: event.eventID),
            reservationCursor: JournalCursor(
                journal: event.journal, eventID: event.eventID, sequence: event.sequence))
    }

    private mutating func applySessionCreationCompleted(_ event: TimelineEvent) {
        guard controlSessionCreationPayloadIsExact(event.payload),
              let reservationEvent: EventRef = event.payload["reservation_event"].flatMap(
                  decodeControlValue),
              let causalControlCursor: JournalCursor = event.payload[
                  "causal_control_cursor"].flatMap(decodeControlValue),
              let publication = event.payload["publication"]?.stringValue,
              publication == "mirrored" || publication == "terminal_reference",
              let capabilities = controlCapabilities(event.payload["capabilities"]),
              let causalSessionCursor: JournalCursor = event.payload[
                  "causal_session_cursor"].flatMap(decodeControlValue),
              let sessionCursor: JournalCursor = event.payload["session_cursor"].flatMap(
                  decodeControlValue),
              let causalWorkCursor: JournalCursor = event.payload["causal_work_cursor"].flatMap(
                  decodeControlValue),
              let resultingWorkCursor: JournalCursor = event.payload[
                  "resulting_work_cursor"].flatMap(decodeControlValue),
              let sessionCreatedEvent: EventRef = event.payload[
                  "session_created_event"].flatMap(decodeControlValue),
              let sessionAttachedEvent: EventRef = event.payload[
                  "session_attached_event"].flatMap(decodeControlValue),
              let cursorAdvancedEvent: EventRef = event.payload[
                  "cursor_advanced_event"].flatMap(decodeControlValue),
              let work = event.work,
              let client = event.client,
              let commandID = event.payload["command_id"]?.stringValue,
              let reservation = snapshot.sessionCreations.values.first(where: {
                  $0.reservation.work == work
                      && $0.reservation.client == client
                      && $0.reservation.command.commandID == commandID
                      && $0.reservationEvent == reservationEvent
              }) else {
            quarantine(event, reason: "Work Host Session creation result is malformed")
            return
        }
        let (expectedSessionSequence, sessionSequenceOverflow) =
            causalSessionCursor.sequence.addingReportingOverflow(3)
        let workMirrorEvent = workMirrorEventFromPayload(event.payload)
        let (expectedMirroredWorkSequence, mirroredWorkSequenceOverflow) =
            causalWorkCursor.sequence.addingReportingOverflow(1)
        guard !sessionSequenceOverflow,
              causalSessionCursor.journal == reservation.reservation.sessionJournal,
              sessionCursor.journal == reservation.reservation.sessionJournal,
              causalWorkCursor == reservation.reservation.causalWorkCursor,
              event.causedByEventID == reservationEvent,
              causalControlCursor == controlCursorBefore(event),
              event.session == reservation.reservation.session,
              event.sessionAttachment == reservation.reservation.sessionAttachment,
              event.work == reservation.reservation.work,
              event.workHost == snapshot.workHost,
              event.client == reservation.reservation.client,
              resultingWorkCursor.journal == reservation.reservation.workJournal,
              sessionCreatedEvent.journal == reservation.reservation.sessionJournal,
              sessionAttachedEvent.journal == reservation.reservation.sessionJournal,
              cursorAdvancedEvent.journal == reservation.reservation.sessionJournal,
              (publication == "mirrored"
                  ? workMirrorEvent != nil
                      && !mirroredWorkSequenceOverflow
                      && resultingWorkCursor.sequence == expectedMirroredWorkSequence
                      && workMirrorEvent?.journal == resultingWorkCursor.journal
                      && workMirrorEvent?.eventID == resultingWorkCursor.eventID
                  : workMirrorEvent == nil && resultingWorkCursor == causalWorkCursor),
              Set(capabilities).isSubset(of: Set(reservation.reservation.requestedCapabilities)),
              (publication == "terminal_reference" ? capabilities == ["observe"] : true),
              controlBoundedCursor(causalSessionCursor),
              controlBoundedCursor(sessionCursor),
              controlBoundedCursor(causalWorkCursor),
              controlBoundedCursor(resultingWorkCursor),
              sessionCursor.sequence == expectedSessionSequence,
              sessionCursor.eventID == cursorAdvancedEvent.eventID,
              capabilities.count <= WorkHostControlLimits.maxCapabilities else {
            quarantine(event, reason: "Work Host Session creation result has mismatched evidence")
            return
        }
        let result = WorkHostControlSessionCreationResult(
            causalControlCursor: causalControlCursor,
            resultingControlCursor: JournalCursor(
                journal: event.journal, eventID: event.eventID, sequence: event.sequence),
            publication: publication, capabilities: capabilities,
            causalSessionCursor: causalSessionCursor, sessionCursor: sessionCursor,
            causalWorkCursor: causalWorkCursor, resultingWorkCursor: resultingWorkCursor,
            sessionCreatedEvent: sessionCreatedEvent, sessionAttachedEvent: sessionAttachedEvent,
            workMirrorEvent: workMirrorEvent, cursorAdvancedEvent: cursorAdvancedEvent,
            resultEvent: EventRef(journal: event.journal, eventID: event.eventID))
        let key = reservation.reservation.key
        guard var existing = snapshot.sessionCreations[key], !existing.isConflicted else {
            quarantine(event, reason: "Work Host Session creation result has no reservation")
            return
        }
        guard existing.abort == nil else {
            quarantine(event, reason: "Work Host Session creation result follows an abort")
            return
        }
        if let prior = existing.result {
            guard prior == result else {
                markSessionCreationConflict(key: key, event: event)
                return
            }
            return
        }
        let attachment = WorkHostClientAttachmentSnapshot(
            attachment: reservation.reservation.clientAttachment,
            client: reservation.reservation.client,
            work: reservation.reservation.work,
            workJournal: reservation.reservation.workJournal,
            session: reservation.reservation.session,
            sessionJournal: reservation.reservation.sessionJournal,
            sessionAttachment: reservation.reservation.sessionAttachment,
            capabilities: Set(result.capabilities), isAttached: true,
            attachedEvent: result.resultEvent)
        if let priorAttachment = snapshot.clientAttachments[attachment.attachment.attachmentID] {
            guard priorAttachment == attachment else {
                quarantine(event, reason: "Session creation client attachment conflicts")
                return
            }
        } else {
            snapshot.clientAttachments[attachment.attachment.attachmentID] = attachment
        }
        existing.result = result
        snapshot.sessionCreations[key] = existing
    }

    private mutating func applySessionCreationAborted(_ event: TimelineEvent) {
        guard controlSessionCreationAbortPayloadIsExact(event.payload),
              let reservationEvent: EventRef = event.payload["reservation_event"].flatMap(
                  decodeControlValue),
              let causalControlCursor: JournalCursor = event.payload[
                  "causal_control_cursor"].flatMap(decodeControlValue),
              event.payload["source_presence"]?.stringValue ==
                  WorkHostControlCreationSourcePresence.none.rawValue,
              let commandID = event.payload["command_id"]?.stringValue,
              let work = event.work,
              let client = event.client,
              let reservation = snapshot.sessionCreations.values.first(where: {
                  $0.reservation.work == work
                      && $0.reservation.client == client
                      && $0.reservation.command.commandID == commandID
                      && $0.reservationEvent == reservationEvent
              }) else {
            quarantine(event, reason: "Work Host Session creation abort is malformed")
            return
        }
        let actualCursor = JournalCursor(
            journal: event.journal, eventID: event.eventID, sequence: event.sequence)
        guard event.causedByEventID == reservationEvent,
              causalControlCursor == controlCursorBefore(event),
              reservationEvent.journal == event.journal,
              causalControlCursor.journal == event.journal,
              event.session == reservation.reservation.session,
              event.sessionAttachment == reservation.reservation.sessionAttachment,
              event.work == reservation.reservation.work,
              event.workHost == snapshot.workHost,
              event.client == reservation.reservation.client,
              controlBoundedCursor(causalControlCursor),
              controlBoundedIdentity(commandID) else {
            quarantine(event, reason: "Work Host Session creation abort has mismatched evidence")
            return
        }
        let abort = WorkHostControlSessionCreationAbort(
            causalControlCursor: causalControlCursor,
            resultingControlCursor: actualCursor,
            sourcePresence: .none,
            resultEvent: EventRef(journal: event.journal, eventID: event.eventID))
        let key = reservation.reservation.key
        guard var existing = snapshot.sessionCreations[key], !existing.isConflicted else {
            quarantine(event, reason: "Work Host Session creation abort has no reservation")
            return
        }
        guard existing.result == nil else {
            quarantine(event, reason: "Work Host Session creation abort follows a completion")
            return
        }
        if let prior = existing.abort {
            guard prior == abort else {
                markSessionCreationConflict(key: key, event: event)
                return
            }
            return
        }
        existing.abort = abort
        snapshot.sessionCreations[key] = existing
    }

    private func controlSessionCreationPayloadIsExact(_ payload: JSONValue) -> Bool {
        guard let object = payload.objectValue else { return false }
        let keys = Set(object.keys)
        let reservation: Set<String> = [
            "work_journal", "session_journal", "authorizing_attachment",
            "causal_work_cursor", "requested_capabilities",
        ]
        let result: Set<String> = [
            "reservation_event", "command_id", "causal_control_cursor", "publication", "capabilities",
            "causal_session_cursor", "session_cursor", "causal_work_cursor",
            "resulting_work_cursor", "session_created_event", "session_attached_event",
            "work_mirror_event", "cursor_advanced_event",
        ]
        return keys == reservation || keys == result
    }

    private func controlSessionCreationAbortPayloadIsExact(_ payload: JSONValue) -> Bool {
        guard let object = payload.objectValue else { return false }
        return Set(object.keys) == [
            "reservation_event", "command_id", "causal_control_cursor", "source_presence",
        ]
    }

    private func controlCapabilities(_ value: JSONValue?) -> [String]? {
        guard let values = value?.arrayValue else { return nil }
        let strings = values.compactMap(\JSONValue.stringValue)
        guard strings.count == values.count,
              strings == strings.sorted(),
              Set(strings).count == strings.count,
              strings.allSatisfy({ controlBoundedIdentity($0) }) else { return nil }
        return strings
    }

    private func workMirrorEventFromPayload(_ payload: JSONValue) -> EventRef? {
        guard let value = payload["work_mirror_event"] else { return nil }
        return decodeControlValue(value)
    }

    private mutating func markSessionCreationConflict(key: String, event: TimelineEvent) {
        if var existing = snapshot.sessionCreations[key] {
            existing.isConflicted = true
            if existing.conflictEventRefs.count < TimelineEvent.maxEvidenceLinks {
                existing.conflictEventRefs.append(
                    EventRef(journal: event.journal, eventID: event.eventID))
            }
            snapshot.sessionCreations[key] = existing
        }
        quarantine(event, reason: "Work Host Session creation transaction conflicts")
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
    private struct ControlFileFingerprint: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let byteCount: Int
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let lastByte: UInt8?
    }
    private var cachedReadFingerprint: ControlFileFingerprint?
    private var cachedReadResult: TimelineJournalReadResult?
    /// Record segments are append-only. Keeping them separate avoids an O(history) array copy
    /// when one new control event is committed; `read()` flattens only on explicit caller demand.
    private var cachedRecordSegments: [[TimelineJournalRecord]] = []
    private var cachedSnapshot: WorkHostControlSnapshot?
    /// These values are the actor's sealed-prefix state. They are published as one unit only
    /// after the Timeline append and the atomic seal publication have both succeeded.
    private var cachedCursor: JournalCursor?
    private var cachedCommandIndex: [String: [TimelineJournalRecord]] = [:]
    private var cachedSealedByteCount = 0
    private var cachedDigestState: ControlSHA256State?
    private var readMetrics = WorkHostControlJournalReadMetrics()
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
        try ensureControlCache()
        if cachedReadResult == nil {
            cachedReadResult = TimelineJournalReadResult(
                records: cachedRecordSegments.flatMap { $0 })
        }
        guard let cachedReadResult else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal has an incomplete tail")
        }
        return cachedReadResult
    }

    /// Bring the actor-owned sealed-prefix cache current without materializing its record list.
    /// Normal mutations use this path; the public read API is the only operation that asks for a
    /// flat history value.
    private func ensureControlCache() throws {
        // A failed append or seal is deliberately a read-only view of the last known sealed
        // prefix. The writer may have a complete line in page cache, or the seal rename may have
        // become visible without its directory fsync; neither is a successful mutation.
        if controlFailure != nil, cachedSnapshot != nil { return }
        let fingerprint = try controlFileFingerprint()
        if let cachedReadFingerprint, cachedReadFingerprint == fingerprint,
           cachedSnapshot != nil {
            try Self.validateCachedSeal(
                at: fileURL, journal: journal, byteCount: cachedSealedByteCount,
                cursor: cachedCursor ?? JournalCursor(journal: journal, sequence: 0),
                digest: cachedDigestState?.hexDigest()
                    ?? String(controlSHA256(Data()).dropFirst("sha256:".count)))
            addReadMetrics(cacheHits: 1)
            return
        }

        // During the small await in writer.append(), the complete append is intentionally not
        // visible yet. Keep serving the old projection until its seal can be published. A public
        // read is otherwise an external mutation observation and must fail closed.
        if mutationInFlight, cachedSnapshot != nil { return }
        let data = try Self.readFileData(at: fileURL)
        let committedData = try Self.committedPrefixData(
            for: fileURL, journal: journal, data: data)
        guard committedData.count == data.count else {
            invalidateCache()
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal has an unsealed external suffix")
        }
        let result = TimelineJournalReader.read(
            committedData, journal: journal, actor: readerActor, hostRecordedAt: Date())
        guard result.quarantinedSuffix == nil, result.truncatedTail == nil else {
            invalidateCache()
            return
        }
        guard result.records.count <= WorkHostControlLimits.maxSupportedControlRecords else {
            invalidateCache()
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control projection exceeds its supported record envelope")
        }
        let after = try controlFileFingerprint()
        guard fingerprint == after else {
            invalidateCache()
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal changed during read")
        }
        let snapshot = WorkHostControlReducer.reduce(
            result.records.map(\.event), initial: WorkHostControlSnapshot(journal: journal))
        var digestState = ControlSHA256State()
        digestState.update(committedData)
        let cursor = currentCursor(of: snapshot)
        var commandIndex: [String: [TimelineJournalRecord]] = [:]
        for record in result.records {
            if let key = Self.commandIndexKey(for: record.event) {
                commandIndex[key, default: []].append(record)
            }
        }
        cachedReadFingerprint = after
        cachedReadResult = result
        cachedRecordSegments = [result.records]
        cachedSnapshot = snapshot
        cachedCursor = cursor
        cachedCommandIndex = commandIndex
        cachedSealedByteCount = committedData.count
        cachedDigestState = digestState
        addReadMetrics(fullReads: 1, bytesScanned: committedData.count,
                       recordsApplied: result.records.count)
        return
    }

    public func snapshot() throws -> WorkHostControlSnapshot {
        try ensureControlCache()
        if let cachedSnapshot { return cachedSnapshot }
        return WorkHostControlSnapshot(journal: journal)
    }

    public func journalReadMetrics() -> WorkHostControlJournalReadMetrics { readMetrics }

    /// Find one client-qualified command without applying any current attachment, source-journal,
    /// or causal-cursor policy. JournalBackedWorkService uses this before those mutable checks so
    /// an exact retry can reconstruct a durable response after the original response was lost.
    /// The caller must still compare the complete request envelope and mutation digest.
    func priorCommand(
        work: WorkRef, client: ClientRef, commandID: String
    ) async throws -> WorkHostControlPriorMutation? {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        guard controlBoundedIdentity(work.workHostID),
              controlBoundedIdentity(work.workID),
              work.workHostID == workHost.workHostID,
              controlBoundedIdentity(client.clientID),
              controlBoundedIdentity(commandID) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control command lookup identities exceed the bounded contract")
        }
        try ensureControlCache()
        guard let current = cachedSnapshot else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal cache was not published")
        }
        guard current.structuralIntegrityValid,
              current.semanticProjectionValid,
              current.unknownEvents.isEmpty else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is not completely projectable")
        }
        let key = Self.commandIndexKey(work: work, client: client, commandID: commandID)
        let matches = cachedCommandIndex[key] ?? []
        guard matches.count <= 1 else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "client-qualified control command has duplicate durable records")
        }
        guard let record = matches.first else { return nil }
        if case .failed(let reason) = await writer.health {
            throw TimelineJournalWriter.WriterError.unavailable(reason)
        }
        return WorkHostControlPriorMutation(
            event: record.event,
            commit: TimelineJournalCommit(
                eventRef: EventRef(journal: journal, eventID: record.event.eventID),
                cursor: JournalCursor(
                    journal: journal, eventID: record.event.eventID,
                    sequence: record.event.sequence)))
    }

    /// Find an exact mutation identity without appending. Unlike `commitMutation`, this method is
    /// intentionally only a lookup; a nil result leaves the caller free to perform source and
    /// attachment validation before invoking the normal mutating API.
    func priorMutation(
        _ identity: WorkHostControlMutationIdentity, command: CommandRef
    ) async throws -> WorkHostControlPriorMutation? {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        try validateMutationCommand(command, identity: identity)
        let digest = try mutationDigest(identity)
        try ensureControlCache()
        guard let current = cachedSnapshot else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal cache was not published")
        }
        guard current.structuralIntegrityValid,
              current.semanticProjectionValid,
              current.unknownEvents.isEmpty else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is not completely projectable")
        }
        let key = Self.commandIndexKey(
            work: identity.work, client: identity.client, commandID: command.commandID)
        let matches = cachedCommandIndex[key] ?? []
        guard matches.count <= 1 else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "client-qualified control command has duplicate durable records")
        }
        guard let record = matches.first else { return nil }
        guard record.event.command == command,
              record.event.type == identity.type,
              record.event.idempotencyKey == digest else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "client-qualified control command conflicts with a prior request")
        }
        if case .failed(let reason) = await writer.health {
            throw TimelineJournalWriter.WriterError.unavailable(reason)
        }
        return WorkHostControlPriorMutation(
            event: record.event,
            commit: TimelineJournalCommit(
                eventRef: EventRef(journal: journal, eventID: record.event.eventID),
                cursor: JournalCursor(
                    journal: journal, eventID: record.event.eventID,
                    sequence: record.event.sequence)))
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
        requestedCapabilities: Set<String>,
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
            capabilities: capabilities.sorted(),
            requestedCapabilities: requestedCapabilities.sorted(),
            targetJournal: nil, targetCursor: nil,
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
            capabilities: nil, requestedCapabilities: nil,
            targetJournal: nil, targetCursor: nil,
            causalControlCursor: causalControlCursor), command: command)
    }

    @discardableResult
    public func updateClientCapabilities(
        work: WorkRef,
        workJournal: JournalRef,
        attachment: ClientAttachmentRef,
        client: ClientRef,
        capabilities: Set<String>,
        requestedCapabilities: Set<String>,
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
            capabilities: capabilities.sorted(),
            requestedCapabilities: requestedCapabilities.sorted(),
            targetJournal: nil, targetCursor: nil,
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
            capabilities: nil, requestedCapabilities: nil,
            targetJournal: targetJournal, targetCursor: cursor,
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
        try rejectNewMutationWhileSessionCreationIncomplete(current)
        guard request.causalControlCursor == actualCursor else {
            throw WorkHostControlCreationStaleCursorError(
                expected: request.causalControlCursor, actual: actualCursor)
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
        try rejectNewMutationWhileSessionCreationIncomplete(current)
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

    /// Reserve an existing-Work Session relationship in the host control journal. All three
    /// Session-side identities are host-minted before this call and are retained in the durable
    /// reservation. Exact retries return the original reservation before stale-cursor checks;
    /// conflicting envelopes fail without minting or appending anything.
    ///
    /// This is intentionally only the control half of the cross-journal operation. The current
    /// RunJournalBundle owns live Work writers and has no primitive for atomically coordinating a
    /// new Session writer with that Work writer. Until that seam exists, a reservation without a
    /// result is the truthful recovery state, not a successful Session attachment.
    public func reserveSessionCreation(
        _ request: WorkHostControlSessionCreationRequest
    ) async throws -> WorkHostControlSessionCreationSnapshot {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        return try await reserveSessionCreationLocked(request)
    }

    private func reserveSessionCreationLocked(
        _ request: WorkHostControlSessionCreationRequest
    ) async throws -> WorkHostControlSessionCreationSnapshot {
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        try validateSessionCreationRequest(request)
        let (current, actualCursor) = try readControlState()
        if let existing = current.sessionCreations[request.key] {
            guard !existing.isConflicted, existing.reservation == request else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "Session creation command conflicts with its reservation")
            }
            if existing.abort != nil {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "Session creation reservation was durably aborted")
            }
            if case .failed(let reason) = await writer.health {
                throw TimelineJournalWriter.WriterError.unavailable(reason)
            }
            return existing
        }
        try rejectNewMutationWhileSessionCreationIncomplete(current)
        guard request.causalControlCursor == actualCursor else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation reservation causal control cursor is stale")
        }
        guard current.clientAttachments[request.authorizingAttachment.attachmentID].map({
            $0.client == request.client && $0.work == request.work
                && $0.workJournal == request.workJournal && $0.isAttached
                && $0.capabilities.contains("create_session")
        }) == true else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation reservation lacks an attached authorizing client")
        }
        let payload: JSONValue = .object([
            "work_journal": encodeControlValue(request.workJournal),
            "session_journal": encodeControlValue(request.sessionJournal),
            "authorizing_attachment": encodeControlValue(request.authorizingAttachment),
            "causal_work_cursor": encodeControlValue(request.causalWorkCursor),
            "requested_capabilities": .array(
                request.requestedCapabilities.sorted().map { .string($0) }),
        ])
        let draft = TimelineEventDraft(
            command: request.command, session: request.session, work: request.work,
            workHost: workHost, client: request.client,
            sessionAttachment: request.sessionAttachment,
            clientAttachment: request.clientAttachment,
            type: WorkHostControlEventType.sessionCreationReserved,
            declaredDomains: [.work, .session], payload: payload)
        let digest = try sessionCreationRequestDigest(request)
        let commit = try await appendSessionCreationDraft(
            draft, digest: digest, current: current, causalCursor: actualCursor)
        return WorkHostControlSessionCreationSnapshot(
            reservation: request, reservationEvent: commit.eventRef,
            reservationCursor: commit.cursor)
    }

    /// Resolve a failed Session publication only when the host can freshly prove that the
    /// reserved Session journal has no source bytes at all.  A missing source is a safe negative
    /// outcome; a partial, malformed, or unreadable source remains indeterminate and must be
    /// retried or repaired by the source owner.  This event is deliberately not a generic timeout
    /// or client cancellation, and it does not create an attachment or Session fact.
    public func abortSessionCreation(
        work: WorkRef, client: ClientRef, commandID: String
    ) async throws -> WorkHostControlSessionCreationAbort {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        return try await abortSessionCreationLocked(
            work: work, client: client, commandID: commandID)
    }

    private func abortSessionCreationLocked(
        work: WorkRef, client: ClientRef, commandID: String
    ) async throws -> WorkHostControlSessionCreationAbort {
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        guard controlBoundedIdentity(work.workHostID), work.workHostID == workHost.workHostID,
              controlBoundedIdentity(work.workID), controlBoundedIdentity(client.clientID),
              controlBoundedIdentity(commandID) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation abort identity is unbounded or foreign")
        }
        try ensureControlCache()
        guard let current = cachedSnapshot,
              let existing = current.sessionCreation(
                  work: work, client: client, commandID: commandID),
              !existing.isConflicted else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation abort has no matching reservation")
        }
        if let abort = existing.abort {
            if case .failed(let reason) = await writer.health {
                throw TimelineJournalWriter.WriterError.unavailable(reason)
            }
            return abort
        }
        guard existing.result == nil else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation already completed")
        }
        guard try proveSessionSourceAbsent(existing.reservation) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session source outcome is not provably absent")
        }
        let actualCursor = cachedCursor ?? currentCursor(of: current)
        guard actualCursor == existing.reservationCursor else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation abort causal control cursor is stale")
        }
        let payload: JSONValue = .object([
            "reservation_event": encodeControlValue(existing.reservationEvent),
            "command_id": .string(commandID),
            "causal_control_cursor": encodeControlValue(existing.reservationCursor),
            "source_presence": .string(
                WorkHostControlCreationSourcePresence.none.rawValue),
        ])
        let draft = TimelineEventDraft(
            causedByEventID: existing.reservationEvent,
            session: existing.reservation.session, work: existing.reservation.work,
            workHost: workHost, client: existing.reservation.client,
            sessionAttachment: existing.reservation.sessionAttachment,
            type: WorkHostControlEventType.sessionCreationAborted,
            declaredDomains: [.work, .session], payload: payload)
        let digest = try sessionCreationAbortDigest(
            reservationEvent: existing.reservationEvent,
            commandID: commandID, causalControlCursor: existing.reservationCursor)
        let commit = try await appendSessionCreationDraft(
            draft, digest: digest, current: current, causalCursor: actualCursor)
        return WorkHostControlSessionCreationAbort(
            causalControlCursor: existing.reservationCursor,
            resultingControlCursor: commit.cursor,
            sourcePresence: .none,
            resultEvent: commit.eventRef)
    }

    /// Append the control-journal result for a source-journal Session publication. The exact
    /// result is reconciled before checking the current control cursor, so a lost response can
    /// be recovered without reminting. This does not assert that the referenced source bytes
    /// exist; the Work Host's source verifier must make that independent check before exposing a
    /// successful descriptor or granting the new Session any authority.
    public func completeSessionCreation(
        work: WorkRef, client: ClientRef, commandID: String,
        _ request: WorkHostControlSessionCreationResultRequest
    ) async throws -> WorkHostControlSessionCreationResult {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        return try await completeSessionCreationLocked(
            work: work, client: client, commandID: commandID, request)
    }

    private func completeSessionCreationLocked(
        work: WorkRef, client: ClientRef, commandID: String,
        _ request: WorkHostControlSessionCreationResultRequest
    ) async throws -> WorkHostControlSessionCreationResult {
        if let controlFailure {
            throw TimelineJournalWriter.WriterError.unavailable(controlFailure)
        }
        try validateSessionCreationResultRequest(request)
        let (current, actualCursor) = try readControlState()
        guard let existing = current.sessionCreation(
            work: work, client: client, commandID: commandID),
              existing.reservationEvent == request.reservationEvent else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation result has no matching reservation")
        }
        if let prior = existing.result {
            let expected = WorkHostControlSessionCreationResult(
                causalControlCursor: request.causalControlCursor,
                resultingControlCursor: prior.resultingControlCursor,
                publication: request.publication, capabilities: request.capabilities,
                causalSessionCursor: request.causalSessionCursor, sessionCursor: request.sessionCursor,
                causalWorkCursor: request.causalWorkCursor,
                resultingWorkCursor: request.resultingWorkCursor,
                sessionCreatedEvent: request.sessionCreatedEvent,
                sessionAttachedEvent: request.sessionAttachedEvent,
                workMirrorEvent: request.workMirrorEvent,
                cursorAdvancedEvent: request.cursorAdvancedEvent,
                resultEvent: prior.resultEvent)
            guard prior == expected else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "Session creation result conflicts with its prior evidence")
            }
            if case .failed(let reason) = await writer.health {
                throw TimelineJournalWriter.WriterError.unavailable(reason)
            }
            return prior
        }
        guard existing.abort == nil else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation reservation was durably aborted")
        }
        guard request.reservationEvent.journal == journal,
              request.reservationEvent == existing.reservationEvent,
              request.commandID == existing.reservation.command.commandID,
              work == existing.reservation.work,
              client == existing.reservation.client,
              request.causalWorkCursor == existing.reservation.causalWorkCursor,
              request.causalSessionCursor.sequence == 0,
              request.causalSessionCursor.eventID == nil,
              request.causalSessionCursor.journal == existing.reservation.sessionJournal,
              request.sessionCursor.journal == existing.reservation.sessionJournal,
              request.sessionCreatedEvent.journal == existing.reservation.sessionJournal,
              request.sessionAttachedEvent.journal == existing.reservation.sessionJournal,
              request.cursorAdvancedEvent.journal == existing.reservation.sessionJournal,
              request.causalWorkCursor.journal == existing.reservation.workJournal,
              request.resultingWorkCursor.journal == existing.reservation.workJournal,
              Set(request.capabilities).isSubset(
                  of: Set(existing.reservation.requestedCapabilities)),
              (request.publication == "terminal_reference"
                  ? request.capabilities == ["observe"] : true),
              request.publication == "mirrored"
                  ? request.workMirrorEvent != nil
                  : request.publication == "terminal_reference"
                      && request.workMirrorEvent == nil
                      && request.resultingWorkCursor == request.causalWorkCursor,
              request.causalControlCursor == actualCursor else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation result evidence does not match reservation")
        }
        let payload: JSONValue = .object([
            "reservation_event": encodeControlValue(request.reservationEvent),
            "command_id": .string(request.commandID),
            "causal_control_cursor": encodeControlValue(request.causalControlCursor),
            "publication": .string(request.publication),
            "capabilities": .array(request.capabilities.sorted().map { .string($0) }),
            "causal_session_cursor": encodeControlValue(request.causalSessionCursor),
            "session_cursor": encodeControlValue(request.sessionCursor),
            "causal_work_cursor": encodeControlValue(request.causalWorkCursor),
            "resulting_work_cursor": encodeControlValue(request.resultingWorkCursor),
            "session_created_event": encodeControlValue(request.sessionCreatedEvent),
            "session_attached_event": encodeControlValue(request.sessionAttachedEvent),
            "work_mirror_event": request.workMirrorEvent.map(encodeControlValue) ?? .null,
            "cursor_advanced_event": encodeControlValue(request.cursorAdvancedEvent),
        ])
        let draft = TimelineEventDraft(
            causedByEventID: existing.reservationEvent,
            session: existing.reservation.session, work: existing.reservation.work,
            workHost: workHost, client: existing.reservation.client,
            sessionAttachment: existing.reservation.sessionAttachment,
            type: WorkHostControlEventType.sessionCreationCompleted,
            declaredDomains: [.work, .session], payload: payload)
        let digest = try sessionCreationResultDigest(request)
        let commit = try await appendSessionCreationDraft(
            draft, digest: digest, current: current, causalCursor: actualCursor)
        return WorkHostControlSessionCreationResult(
            causalControlCursor: request.causalControlCursor,
            resultingControlCursor: commit.cursor,
            publication: request.publication, capabilities: request.capabilities,
            causalSessionCursor: request.causalSessionCursor, sessionCursor: request.sessionCursor,
            causalWorkCursor: request.causalWorkCursor,
            resultingWorkCursor: request.resultingWorkCursor,
            sessionCreatedEvent: request.sessionCreatedEvent,
            sessionAttachedEvent: request.sessionAttachedEvent,
            workMirrorEvent: request.workMirrorEvent,
            cursorAdvancedEvent: request.cursorAdvancedEvent,
            resultEvent: commit.eventRef)
    }

    /// Run the source-journal publication while the control mutation gate is held. This is the
    /// owner-mediated seam for the two-file saga: reservation and completion are adjacent control
    /// records even when the source writer has to recover a partial prefix or awaits a filesystem
    /// synchronize. A failed source operation remains durable and retryable unless the host can
    /// immediately prove source absence, in which case it records an adjacent abort while still
    /// rethrowing the original source error.
    public func publishSessionCreation(
        _ request: WorkHostControlSessionCreationRequest,
        source: @escaping @Sendable
            (WorkHostControlSessionCreationRequest) async throws
            -> RunJournalBundleSessionPublication
    ) async throws -> WorkHostControlSessionCreationPublication {
        await acquireMutationGate()
        defer { releaseMutationGate() }
        let reservation = try await reserveSessionCreationLocked(request)
        let publication: RunJournalBundleSessionPublication
        do {
            publication = try await source(reservation.reservation)
        } catch {
            // Preserve the source failure for the caller.  A fresh, owner-locked proof may still
            // safely resolve the reservation when no Session bytes were created; otherwise the
            // reservation remains the truthful blocked/retryable state.
            _ = try? await abortSessionCreationLocked(
                work: request.work, client: request.client,
                commandID: request.command.commandID)
            throw error
        }
        let result = try await completeSessionCreationLocked(
            work: request.work, client: request.client, commandID: request.command.commandID,
            WorkHostControlSessionCreationResultRequest(
                reservationEvent: reservation.reservationEvent,
                commandID: request.command.commandID,
                causalControlCursor: reservation.reservationCursor,
                publication: publication.publication,
                capabilities: publication.capabilities,
                causalSessionCursor: publication.causalSessionCursor,
                sessionCursor: publication.sessionCursor,
                causalWorkCursor: publication.causalWorkCursor,
                resultingWorkCursor: publication.resultingWorkCursor,
                sessionCreatedEvent: publication.sessionCreated.eventRef,
                sessionAttachedEvent: publication.sessionAttached.eventRef,
                workMirrorEvent: publication.workMirror?.eventRef,
                cursorAdvancedEvent: publication.cursorAdvanced.eventRef))
        return WorkHostControlSessionCreationPublication(
            reservation: reservation, source: publication, result: result)
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
        await verifiedCreationProjection(
            client: client, commandID: commandID,
            canonicalWork: nil, canonicalSession: nil)
    }

    /// Verify a creation registration with an optional live canonical observation supplied by
    /// its owning RunJournalBundle. A live Work read is authoritative only for this actor call;
    /// it is accepted under the writer's lock and still has to prove the exact registered prefix
    /// and a re-read of the control registration. A supplied observation for another Session is
    /// never substituted for the registration's Session; alternate active bindings use the
    /// Work-only form while the registered Session is checked through the cold path.
    public func verifiedCreationProjection(
        client: ClientRef,
        commandID: String,
        canonicalWork: TimelineJournalCanonicalRead?,
        canonicalSession: TimelineJournalCanonicalRead?
    ) async -> WorkHostControlCreationProjectionResult {
        let outcome = verifyCreationSourcesNow(
            client: client, commandID: commandID,
            canonicalWork: canonicalWork, canonicalSession: canonicalSession)
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
        commandID: String,
        canonicalWork: TimelineJournalCanonicalRead? = nil,
        canonicalSession: TimelineJournalCanonicalRead? = nil
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

        let workObservation: WorkHostControlSourceObservation = if let canonicalWork {
            observeSuppliedWorkSource(
                canonicalWork, cursor: registration.workGenesisCursor,
                expectedWork: registration.reservation.work,
                expectedSession: registration.reservation.session,
                expectedAttachment: registration.reservation.sessionAttachment)
        } else {
            observeSourceJournal(
                registration.workJournal,
                cursor: registration.workGenesisCursor,
                expectedWork: registration.reservation.work,
                expectedSession: registration.reservation.session,
                expectedAttachment: registration.reservation.sessionAttachment,
                expectedGenesisType: TimelineEventType.workCreated)
        }
        let sessionObservation: WorkHostControlSourceObservation = if let canonicalSession,
            canonicalSession.journal == registration.sessionJournal {
            observeSuppliedSessionSource(
                canonicalSession, cursor: registration.sessionGenesisCursor,
                expectedWork: registration.reservation.work,
                expectedSession: registration.reservation.session,
                expectedAttachment: registration.reservation.sessionAttachment)
        } else {
            observeSourceJournal(
                registration.sessionJournal,
                cursor: registration.sessionGenesisCursor,
                expectedWork: registration.reservation.work,
                expectedSession: registration.reservation.session,
                expectedAttachment: registration.reservation.sessionAttachment,
                expectedGenesisType: TimelineEventType.sessionCreated)
        }

        // Source reads can suspend in the live bundle or race a control mutation. Never project
        // a success-shaped registration from the first snapshot if the control registration has
        // changed in the meantime.
        let rechecked: WorkHostControlSnapshot
        do {
            rechecked = try readControlState().snapshot
        } catch {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: current,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .unverified, failure: .controlJournalUnavailable))
        }
        guard rechecked.creation(client: client, commandID: commandID)?.registration == registration else {
            return WorkHostControlCreationVerificationOutcome(
                snapshot: rechecked,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .unverified, failure: .registrationMissing))
        }

        switch (workObservation, sessionObservation) {
        case (.valid(let workEvidence), .valid(let sessionEvidence)):
            let expected = Set([registration.reservation.sessionAttachment])
            guard workEvidence.attachments == expected,
                  sessionEvidence.attachments == expected,
                  workEvidence.attachments == sessionEvidence.attachments else {
                return WorkHostControlCreationVerificationOutcome(
                    snapshot: rechecked,
                    verification: WorkHostControlCreationSourceVerification(
                        sourcePresence: .unverified, failure: .attachmentMirrorMismatch,
                        workSourceDigest: workEvidence.dataDigest,
                        sessionSourceDigest: sessionEvidence.dataDigest))
            }
            return WorkHostControlCreationVerificationOutcome(
                snapshot: rechecked,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .verified,
                    workSourceDigest: workEvidence.dataDigest,
                    sessionSourceDigest: sessionEvidence.dataDigest))

        case (.valid, let sessionObservation):
            return WorkHostControlCreationVerificationOutcome(
                snapshot: rechecked,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .workOnly,
                    failure: sourceVerificationFailure(sessionObservation, source: .session)))
        case (let workObservation, .valid):
            return WorkHostControlCreationVerificationOutcome(
                snapshot: rechecked,
                verification: WorkHostControlCreationSourceVerification(
                    sourcePresence: .sessionOnly,
                    failure: sourceVerificationFailure(workObservation, source: .work)))
        case (.missing, .missing):
            return WorkHostControlCreationVerificationOutcome(
                snapshot: rechecked,
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
                snapshot: rechecked,
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

    private func validateSessionCreationRequest(
        _ request: WorkHostControlSessionCreationRequest
    ) throws {
        let identities = [
            request.work.workHostID, request.work.workID, request.client.clientID,
            request.command.commandID, request.authorizingAttachment.attachmentID,
            request.session.sessionID, request.sessionAttachment.attachmentID,
            request.clientAttachment.attachmentID,
        ]
        guard identities.allSatisfy(controlBoundedIdentity),
              request.work.workHostID == workHost.workHostID,
              request.command.client == request.client,
              request.command.sessionAttachment == nil,
              request.command.causalCursor == request.causalControlCursor,
              request.causalControlCursor.journal == journal,
              controlBoundedCursor(request.causalControlCursor),
              controlBoundedCursor(request.causalWorkCursor),
              request.workJournal.owner == .work(request.work),
              request.workJournal.authority.authorityID == workHost.workHostID,
              request.workJournal.kind == .work,
              request.causalWorkCursor.journal == request.workJournal,
              request.sessionJournal.owner == .session(request.session),
              request.sessionJournal.authority.authorityID == workHost.workHostID,
              request.sessionJournal.kind == .session,
              request.sessionAttachment != SessionAttachmentRef(request.authorizingAttachment.attachmentID),
              request.clientAttachment != ClientAttachmentRef(request.authorizingAttachment.attachmentID),
              request.requestedCapabilities == request.requestedCapabilities.sorted(),
              Set(request.requestedCapabilities).count == request.requestedCapabilities.count else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation reservation identities or journals are mismatched")
        }
        try validateCapabilities(Set(request.requestedCapabilities))
    }

    private func validateSessionCreationResultRequest(
        _ request: WorkHostControlSessionCreationResultRequest
    ) throws {
        guard controlBoundedIdentity(request.commandID),
              request.publication == "mirrored" || request.publication == "terminal_reference",
              request.capabilities == request.capabilities.sorted(),
              Set(request.capabilities).count == request.capabilities.count,
              request.reservationEvent.journal == journal,
              controlBoundedIdentity(request.reservationEvent.eventID),
              controlBoundedCursor(request.causalControlCursor),
              controlBoundedCursor(request.causalSessionCursor),
              controlBoundedCursor(request.sessionCursor),
              controlBoundedCursor(request.causalWorkCursor),
              controlBoundedCursor(request.resultingWorkCursor) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation result is outside the bounded contract")
        }
        try validateCapabilities(Set(request.capabilities))
    }

    private func sessionCreationRequestDigest(
        _ request: WorkHostControlSessionCreationRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return controlSHA256(try encoder.encode(request))
    }

    private func sessionCreationResultDigest(
        _ request: WorkHostControlSessionCreationResultRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return controlSHA256(try encoder.encode(request))
    }

    private func sessionCreationAbortDigest(
        reservationEvent: EventRef, commandID: String, causalControlCursor: JournalCursor
    ) throws -> String {
        let value: JSONValue = .object([
            "reservation_event": encodeControlValue(reservationEvent),
            "command_id": .string(commandID),
            "causal_control_cursor": encodeControlValue(causalControlCursor),
            "source_presence": .string(WorkHostControlCreationSourcePresence.none.rawValue),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return controlSHA256(try encoder.encode(value))
    }

    /// Check the reserved source paths while holding their canonical owner locks. The absence of
    /// the Session file, or the canonical zero-byte file created before a Session writer's first
    /// append, plus an unchanged complete Work journal at the exact reserved tip is the only
    /// supported negative proof. Existing Session bytes, partial/malformed Work bytes, symlinks,
    /// path replacement, or otherwise unreadable paths are not classified as "no source". This
    /// is an owner-coordination invariant, not a sandbox or hostile-filesystem security boundary.
    private func proveSessionSourceAbsent(
        _ reservation: WorkHostControlSessionCreationRequest
    ) throws -> Bool {
        guard let home else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "Session source absence cannot be proved without a Work Host AgentHome")
        }
        let sourceURL = home.timelineV2SessionJournalURL(reservation.session)
        let workURL = home.timelineV2WorkJournalURL(reservation.work)
        return try TimelineJournalWriter.withAdvisoryOwnerLock(
            home: home, journal: reservation.sessionJournal, dataURL: sourceURL
        ) {
            guard try Self.sessionSourceIsAbsentOrCanonicalEmpty(at: sourceURL) else {
                return false
            }
            return try TimelineJournalWriter.withAdvisoryOwnerLock(
                home: home, journal: reservation.workJournal, dataURL: workURL
            ) {
                try Self.streamCanonicalJournalToExactTip(
                    at: workURL, journal: reservation.workJournal,
                    cursor: reservation.causalWorkCursor)
            }
        }
    }

    /// A source writer creates the owner directory and an empty regular file before its first
    /// append. That state is still a truthful negative source claim. The descriptor and pathname
    /// are compared before and after the zero-byte check so a final-component symlink or path
    /// replacement cannot be accepted as the canonical pre-write state.
    private static func sessionSourceIsAbsentOrCanonicalEmpty(at url: URL) throws -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = url.deletingLastPathComponent().standardizedFileURL.path
        var directoryBefore = stat()
        let directoryBeforeResult = directoryPath.withCString { lstat($0, &directoryBefore) }
        if directoryBeforeResult == 0 {
            guard (directoryBefore.st_mode & S_IFMT) == S_IFDIR,
                  directoryBefore.st_uid == geteuid() else { return false }
        } else if errno != ENOENT {
            throw TimelineJournalWriter.WriterError.unavailable(
                "Session source directory could not be read")
        }
        var observed = stat()
        let observedResult = path.withCString { lstat($0, &observed) }
        if observedResult != 0 {
            guard errno == ENOENT else {
                throw TimelineJournalWriter.WriterError.unavailable(
                    "Session source absence could not be read")
            }
            var directoryAfter = stat()
            let directoryAfterResult = directoryPath.withCString { lstat($0, &directoryAfter) }
            if directoryBeforeResult == 0 {
                guard directoryAfterResult == 0,
                      (directoryAfter.st_mode & S_IFMT) == S_IFDIR,
                      directoryAfter.st_uid == geteuid(),
                      directoryAfter.st_dev == directoryBefore.st_dev,
                      directoryAfter.st_ino == directoryBefore.st_ino else { return false }
            } else {
                guard directoryAfterResult != 0, errno == ENOENT else { return false }
            }
            return true
        }
        guard (observed.st_mode & S_IFMT) == S_IFREG, observed.st_uid == geteuid() else {
            return false
        }
        let descriptor = path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "Session source pre-write state could not be opened")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var before = stat()
        var beforePath = stat()
        let beforePathResult = path.withCString { lstat($0, &beforePath) }
        guard fstat(descriptor, &before) == 0,
              beforePathResult == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_dev == beforePath.st_dev, before.st_ino == beforePath.st_ino,
              before.st_dev == observed.st_dev, before.st_ino == observed.st_ino,
              before.st_size == 0 else {
            return false
        }
        var byte: UInt8 = 0
        let readCount = withUnsafeMutableBytes(of: &byte) { buffer in
            AviaryPOSIX.read(descriptor, buffer.baseAddress, 1)
        }
        guard readCount == 0 else { return false }
        var after = stat()
        var afterPath = stat()
        var directoryAfter = stat()
        let afterPathResult = path.withCString { lstat($0, &afterPath) }
        let directoryAfterResult = directoryPath.withCString { lstat($0, &directoryAfter) }
        guard fstat(descriptor, &after) == 0,
              afterPathResult == 0,
              directoryBeforeResult == 0, directoryAfterResult == 0,
              (directoryAfter.st_mode & S_IFMT) == S_IFDIR,
              directoryAfter.st_uid == geteuid(),
              directoryAfter.st_dev == directoryBefore.st_dev,
              directoryAfter.st_ino == directoryBefore.st_ino,
              (after.st_mode & S_IFMT) == S_IFREG,
              after.st_uid == geteuid(),
              after.st_dev == afterPath.st_dev, after.st_ino == afterPath.st_ino,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == 0 else {
            return false
        }
        return true
    }

    /// Stream one native journal through EOF while retaining only parser framing, the last event,
    /// and the duplicate-identity index required by the canonical writer contract. There is no
    /// whole-journal Data allocation or total byte ceiling; individual Timeline records remain
    /// bounded by the writer's record limit. The final descriptor/path identity and size fence
    /// prevents a replaced or concurrently extended pathname from satisfying the reserved tip.
    private static func streamCanonicalJournalToExactTip(
        at url: URL, journal: JournalRef, cursor: JournalCursor
    ) throws -> Bool {
        guard cursor.sequence > 0, cursor.eventID != nil else { return false }
        let path = url.standardizedFileURL.path
        let descriptor = path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return false }
            throw TimelineJournalWriter.WriterError.unavailable(
                "Work source absence evidence could not be opened")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var before = stat()
        var beforePath = stat()
        let beforePathResult = path.withCString { lstat($0, &beforePath) }
        guard fstat(descriptor, &before) == 0,
              beforePathResult == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(), before.st_size >= 0,
              before.st_dev == beforePath.st_dev, before.st_ino == beforePath.st_ino else {
            return false
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let decoder = JSONDecoder()
        var eventIDs = Set<String>()
        var lastEvent: TimelineEvent?
        var pendingLine = Data()
        var expectedSequence = 1
        var previousEventID: String?
        var canonical = true

        func consumeLine() {
            guard !pendingLine.isEmpty,
                  let event = try? decoder.decode(TimelineEvent.self, from: pendingLine),
                  event.journal == journal,
                  event.sequence == expectedSequence,
                  event.previousEventID == previousEventID,
                  event.provenance == .native,
                  event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  event.payloadVersion <= 1,
                  event.evidenceLinkBoundsAreValid,
                  controlBoundedIdentity(event.eventID),
                  eventIDs.insert(event.eventID).inserted,
                  expectedSequence < Int.max else {
                canonical = false
                return
            }
            do {
                try TimelineJournalWriter.validate(
                    TimelineEventDraft(
                        session: event.session, work: event.work, workHost: event.workHost,
                        type: event.type, declaredDomains: event.declaredDomains,
                        links: event.links),
                    for: journal)
            } catch {
                canonical = false
                return
            }
            lastEvent = event
            previousEventID = event.eventID
            expectedSequence += 1
            pendingLine.removeAll(keepingCapacity: true)
        }

        while canonical {
            let chunk = try handle.read(
                upToCount: WorkHostControlLimits.sourceAbsenceVerificationChunkBytes) ?? Data()
            if chunk.isEmpty { break }
            var start = chunk.startIndex
            while canonical, start < chunk.endIndex {
                let suffix = chunk[start..<chunk.endIndex]
                if let newline = suffix.firstIndex(of: 0x0A) {
                    let fragment = chunk[start..<newline]
                    let (lineBytes, lineOverflow) = pendingLine.count.addingReportingOverflow(
                        fragment.count + 1)
                    guard !lineOverflow,
                          lineBytes <= TimelineJournalWriter.maximumRecordBytes else {
                        canonical = false
                        break
                    }
                    pendingLine.append(contentsOf: fragment)
                    consumeLine()
                    start = chunk.index(after: newline)
                } else {
                    let fragment = chunk[start..<chunk.endIndex]
                    let (lineBytes, lineOverflow) = pendingLine.count.addingReportingOverflow(
                        fragment.count)
                    guard !lineOverflow,
                          lineBytes < TimelineJournalWriter.maximumRecordBytes else {
                        canonical = false
                        break
                    }
                    pendingLine.append(contentsOf: fragment)
                    start = chunk.endIndex
                }
                if pendingLine.count >= TimelineJournalWriter.maximumRecordBytes {
                    canonical = false
                    break
                }
            }
        }
        if !pendingLine.isEmpty { canonical = false }

        var after = stat()
        var afterPath = stat()
        let afterPathResult = path.withCString { lstat($0, &afterPath) }
        guard fstat(descriptor, &after) == 0,
              afterPathResult == 0,
              (after.st_mode & S_IFMT) == S_IFREG,
              after.st_uid == geteuid(),
              after.st_dev == afterPath.st_dev, after.st_ino == afterPath.st_ino,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size else {
            return false
        }
        guard canonical, let lastEvent else { return false }
        return lastEvent.eventID == cursor.eventID && lastEvent.sequence == cursor.sequence
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

        // Work and Session source verification are long-lived production read paths. Use each
        // durable projection/typed exact-state checkpoint for the whole current source, then
        // read only the registered prefix to preserve the creation-pair digest and attachment
        // evidence.
        if case .work = sourceJournal.owner {
            return observeProjectedWorkSource(
                sourceJournal, home: home, sourceURL: sourceURL, cursor: cursor,
                expectedWork: expectedWork, expectedSession: expectedSession,
                expectedAttachment: expectedAttachment,
                expectedGenesisType: expectedGenesisType)
        }
        if case .session = sourceJournal.owner {
            return observeProjectedSessionSource(
                sourceJournal, home: home, sourceURL: sourceURL, cursor: cursor,
                expectedWork: expectedWork, expectedSession: expectedSession,
                expectedAttachment: expectedAttachment,
                expectedGenesisType: expectedGenesisType)
        }
        return .mismatch

    }

    /// Validate the exact registered prefix against a writer-owned live read. This path never
    /// opens the source file itself: the supplied read was produced by the owning writer while
    /// its lock was held. The registration is still checked here because a live Work actor may
    /// belong to a different Session than the original creation reservation.
    private func observeSuppliedWorkSource(
        _ read: TimelineJournalCanonicalRead,
        cursor: JournalCursor,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedAttachment: SessionAttachmentRef
    ) -> WorkHostControlSourceObservation {
        let registrationRecords: [TimelineJournalRecord]
        if read.isFullyResident {
            guard read.records.count == read.eventCount else { return .mismatch }
            registrationRecords = read.records
        } else {
            guard read.records.isEmpty,
                  !read.prefixRecords.isEmpty,
                  read.prefixRecords.count <= read.eventCount,
                  cursor.sequence <= read.prefixRecords.count else { return .mismatch }
            registrationRecords = read.prefixRecords
        }
        guard read.journal == cursor.journal,
              read.source.journal == read.journal,
              read.source.cursor == JournalCursor(
                  journal: read.journal, eventID: read.lastEvent.event.eventID,
                  sequence: read.lastEvent.event.sequence),
              read.source.prefixByteCount == read.source.sourceByteCount,
              case .work(let head) = read.projection,
              head.source == read.source,
              head.work == expectedWork,
              head.workHost == workHost,
              head.structuralIntegrityValid,
              head.semanticProjectionValid,
              let workSnapshot = read.workSnapshot,
              workSnapshot.work == expectedWork,
              workSnapshot.workHost == workHost else {
            return .mismatch
        }
        return validateSuppliedPrefix(
            registrationRecords.map(\.event), cursor: cursor,
            expectedWork: expectedWork, expectedSession: expectedSession,
            expectedAttachment: expectedAttachment, requireWorkHost: true,
            expectedGenesisType: TimelineEventType.workCreated,
            dataDigest: "sha256:" + read.source.prefixDigest,
            allowAlternateSessionEnvelopes: true,
            knownSessionAttachments: workSnapshot.sessionAttachments)
    }

    private func observeSuppliedSessionSource(
        _ read: TimelineJournalCanonicalRead,
        cursor: JournalCursor,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedAttachment: SessionAttachmentRef
    ) -> WorkHostControlSourceObservation {
        let registrationRecords: [TimelineJournalRecord]
        if read.isFullyResident {
            guard read.records.count == read.eventCount else { return .mismatch }
            registrationRecords = read.records
        } else {
            guard read.records.isEmpty,
                  !read.prefixRecords.isEmpty,
                  read.prefixRecords.count <= read.eventCount,
                  cursor.sequence <= read.prefixRecords.count else { return .mismatch }
            registrationRecords = read.prefixRecords
        }
        guard read.journal == cursor.journal,
              read.source.journal == read.journal,
              read.source.cursor == JournalCursor(
                  journal: read.journal, eventID: read.lastEvent.event.eventID,
                  sequence: read.lastEvent.event.sequence),
              read.source.prefixByteCount == read.source.sourceByteCount,
              case .session(let head) = read.projection,
              head.source == read.source,
              head.session == expectedSession,
              head.structuralIntegrityValid,
              head.semanticProjectionValid else {
            return .mismatch
        }
        return validateSuppliedPrefix(
            registrationRecords.map(\.event), cursor: cursor,
            expectedWork: expectedWork, expectedSession: expectedSession,
            expectedAttachment: expectedAttachment, requireWorkHost: false,
            expectedGenesisType: TimelineEventType.sessionCreated,
            dataDigest: "sha256:" + read.source.prefixDigest)
    }

    private func validateSuppliedPrefix(
        _ events: [TimelineEvent],
        cursor: JournalCursor,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedAttachment: SessionAttachmentRef,
        requireWorkHost: Bool,
        expectedGenesisType: String,
        dataDigest: String,
        allowAlternateSessionEnvelopes: Bool = false,
        knownSessionAttachments: [String: WorkSessionAttachmentSnapshot] = [:]
    ) -> WorkHostControlSourceObservation {
        guard cursor.sequence > 0,
              cursor.sequence <= events.count,
              let terminal = events.first(where: { $0.sequence == cursor.sequence }),
              terminal.eventID == cursor.eventID else { return .mismatch }
        let registered = Array(events.prefix(cursor.sequence))
        guard registered.count == cursor.sequence,
              let first = registered.first,
              first.sequence == 1,
              first.type == expectedGenesisType,
              registered.dropFirst().allSatisfy({ $0.type != expectedGenesisType }) else {
            return .mismatch
        }
        var previousEventID: String?
        var eventIDs = Set<String>()
        var attachments = Set<SessionAttachmentRef>()
        for event in registered {
            guard event.journal == cursor.journal,
                  event.sequence == eventIDs.count + 1,
                  event.previousEventID == previousEventID,
                  event.provenance == .native,
                  event.schemaVersion == TimelineEvent.currentSchemaVersion,
                  event.payloadVersion <= 1,
                  event.isKnownType,
                  eventIDs.insert(event.eventID).inserted,
                  event.work == expectedWork || event.work == nil else { return .mismatch }
            if allowAlternateSessionEnvelopes {
                switch (event.session, event.sessionAttachment) {
                case (nil, nil):
                    break
                case (.some(let session), .some(let attachment)):
                    guard knownSessionAttachments[attachment.attachmentID].map({
                        $0.session == session
                    }) == true else { return .mismatch }
                default:
                    return .mismatch
                }
            } else {
                guard event.session == expectedSession || event.session == nil,
                      event.sessionAttachment == expectedAttachment
                          || event.sessionAttachment == nil else { return .mismatch }
            }
            if requireWorkHost {
                guard event.workHost == workHost || event.workHost == nil else {
                    return .mismatch
                }
            }
            if event.type == TimelineEventType.sessionAttached {
                guard event.work == expectedWork else { return .mismatch }
                if allowAlternateSessionEnvelopes {
                    guard let session = event.session,
                          let attachment = event.sessionAttachment,
                          knownSessionAttachments[attachment.attachmentID].map({
                              $0.session == session
                          }) == true else {
                        return .mismatch
                    }
                    if session == expectedSession && attachment == expectedAttachment {
                        attachments.insert(expectedAttachment)
                    }
                } else {
                    guard event.session == expectedSession,
                          event.sessionAttachment == expectedAttachment else {
                        return .mismatch
                    }
                    attachments.insert(expectedAttachment)
                }
            }
            previousEventID = event.eventID
        }
        return .valid(WorkHostControlSourceJournalEvidence(
            attachments: attachments, dataDigest: dataDigest))
    }

    /// Verify a Work source through its persistent projection. The projection head authenticates
    /// the complete canonical tip and exact reducer state; the small prefix read is retained only
    /// for the control registration's exact genesis/attachment/digest proof. No projection result
    /// is accepted as a second authority or as a substitute for the canonical prefix bytes.
    private func observeProjectedWorkSource(
        _ sourceJournal: JournalRef,
        home: AgentHome,
        sourceURL: URL,
        cursor: JournalCursor,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedAttachment: SessionAttachmentRef,
        expectedGenesisType: String,
        cacheRepairAttempted: Bool = false
    ) -> WorkHostControlSourceObservation {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return .missing }
        guard cursor.sequence > 0, cursor.eventID != nil else { return .mismatch }
        let projectionDigest = AviarySHA256.hash(data: Data(sourceJournal.stableKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let projectionDirectory = home.timelineV2Dir
            .appending(path: "projections", directoryHint: .isDirectory)
            .appending(path: "work-host-control", directoryHint: .isDirectory)
            .appending(path: projectionDigest, directoryHint: .isDirectory)
        do {
            let store = try DisposableTimelineProjectionStore(
                directory: projectionDirectory, journal: sourceJournal)
            let reader = try LocalTimelineProjectionReader(
                store: store, home: home,
                limits: LocalTimelineProjectionReader.Limits(
                    maximumBootstrapSourceBytes: 256 * 1024 * 1024))
            addReadMetrics(projectedWorkReadCalls: 1)
            let result = try reader.read()
            addReadMetrics(
                projectedWorkCacheHits: result.metrics.cacheHit ? 1 : 0,
                projectedWorkBytesRead: result.metrics.bytesRead,
                projectedWorkSuffixBytesRead: result.metrics.suffixBytesRead)
            guard let head = result.reducerHead.work,
                  head.source.journal == sourceJournal,
                  head.source.cursor.sequence >= cursor.sequence,
                  head.work == expectedWork,
                  head.workHost == workHost else {
                return .mismatch
            }
            // The canonical reducer reports a well-formed unknown/semantically invalid suffix as
            // a mismatch. Incomplete is reserved for an uncommitted/quarantined tail below,
            // matching the source verifier's pre-projection contract.
            guard head.structuralIntegrityValid else { return .mismatch }
            if head.coverage.unknownEventCount > 0 || head.coverage.corruptionCount > 0
                    || !head.semanticProjectionValid {
                return .mismatch
            }
            let bucket = try store.loadBucket(
                containingSequence: cursor.sequence, proving: result.source)
            guard let row = bucket.rows.first(where: { $0.sequence == cursor.sequence }),
                  row.eventID == cursor.eventID,
                  row.byteEnd > 0 else { return .mismatch }
            let prefixData = try Self.readPrefixData(
                at: sourceURL, offset: 0, expectedByteCount: row.byteEnd,
                maximum: WorkHostControlLimits.maxProjectedRegistrationPrefixBytes,
                expectedSourceByteCount: result.source.sourceByteCount)
            addReadMetrics(projectedWorkPrefixBytesRead: prefixData.count)
            let read = TimelineJournalReader.read(
                prefixData, journal: sourceJournal, actor: readerActor,
                hostRecordedAt: Date(timeIntervalSince1970: 0))
            guard read.quarantinedSuffix == nil,
                  read.truncatedTail == nil,
                  read.records.count == cursor.sequence else { return .mismatch }
            let registered = read.records.map(\.event)
            guard let first = registered.first,
                  first.sequence == 1,
                  first.type == expectedGenesisType,
                  registered.dropFirst().allSatisfy({ $0.type != expectedGenesisType }) else {
                return .mismatch
            }
            var previousEventID: String?
            var attachments = Set<SessionAttachmentRef>()
            var eventIDs = Set<String>()
            for event in registered {
                guard event.journal == sourceJournal,
                      event.sequence == eventIDs.count + 1,
                      event.previousEventID == previousEventID,
                      event.provenance == .native,
                      event.schemaVersion == TimelineEvent.currentSchemaVersion,
                      event.payloadVersion <= 1,
                      event.isKnownType,
                      controlBoundedIdentity(event.eventID),
                      eventIDs.insert(event.eventID).inserted,
                      event.work == expectedWork,
                      event.workHost == workHost else { return .mismatch }
                guard event.session.map({ $0 == expectedSession }) ?? true,
                      event.sessionAttachment.map({ $0 == expectedAttachment }) ?? true else {
                    return .mismatch
                }
                if event.type == TimelineEventType.sessionAttached {
                    guard event.session == expectedSession,
                          event.work == expectedWork,
                          event.sessionAttachment == expectedAttachment else { return .mismatch }
                    attachments.insert(expectedAttachment)
                }
                previousEventID = event.eventID
            }
            return .valid(WorkHostControlSourceJournalEvidence(
                attachments: attachments, dataDigest: controlSHA256(prefixData)))
        } catch let error as LocalTimelineProjectionReader.ReaderError {
            if (error == .cacheUnavailable || error == .sourceChanged
                    || error == .invalidCachedProjection || error == .exactStateUnavailable),
               !cacheRepairAttempted {
                // The projection is disposable cache state.  A malformed HEAD/object must not
                // turn an otherwise canonical source into a permanent registration failure;
                // discard only this source's cache and retry from byte zero.  The source itself
                // remains under the reader's owner lock and is still fully verified below.
                try? FileManager.default.removeItem(at: projectionDirectory)
                return observeProjectedWorkSource(
                    sourceJournal, home: home, sourceURL: sourceURL, cursor: cursor,
                    expectedWork: expectedWork, expectedSession: expectedSession,
                    expectedAttachment: expectedAttachment,
                    expectedGenesisType: expectedGenesisType, cacheRepairAttempted: true)
            }
            switch error {
            case .malformedLine, .truncatedTail, .lineTooLarge:
                return .incomplete
            case .sourceChanged, .duplicateIdentity, .tooManyEvents, .sourceTooLarge,
                 .invalidCachedProjection, .cacheUnavailable, .projectionFailed,
                 .exactStateUnavailable, .storeRejected, .unsupportedJournal,
                 .tooManyIndexedRows, .tooManyBuckets:
                return .mismatch
            }
        } catch {
            return .unreadable
        }
    }

    /// Verify a Session source through its persistent projection. Session identity is fixed by
    /// the journal owner, while Work identity is deliberately checked only for the registered
    /// creation prefix because one Session may later attach to several Works.
    private func observeProjectedSessionSource(
        _ sourceJournal: JournalRef,
        home: AgentHome,
        sourceURL: URL,
        cursor: JournalCursor,
        expectedWork: WorkRef,
        expectedSession: SessionRef,
        expectedAttachment: SessionAttachmentRef,
        expectedGenesisType: String,
        cacheRepairAttempted: Bool = false
    ) -> WorkHostControlSourceObservation {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return .missing }
        guard cursor.sequence > 0, cursor.eventID != nil else { return .mismatch }
        let projectionDigest = AviarySHA256.hash(data: Data(sourceJournal.stableKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let projectionDirectory = home.timelineV2Dir
            .appending(path: "projections", directoryHint: .isDirectory)
            .appending(path: "work-host-control", directoryHint: .isDirectory)
            .appending(path: projectionDigest, directoryHint: .isDirectory)
        do {
            let store = try DisposableTimelineProjectionStore(
                directory: projectionDirectory, journal: sourceJournal)
            let reader = try LocalTimelineProjectionReader(
                store: store, home: home,
                limits: LocalTimelineProjectionReader.Limits(
                    maximumBootstrapSourceBytes: 256 * 1024 * 1024))
            addReadMetrics(projectedSessionReadCalls: 1)
            let result = try reader.read()
            addReadMetrics(
                projectedSessionCacheHits: result.metrics.cacheHit ? 1 : 0,
                projectedSessionBytesRead: result.metrics.bytesRead,
                projectedSessionSuffixBytesRead: result.metrics.suffixBytesRead)
            guard let head = result.reducerHead.session,
                  head.source.journal == sourceJournal,
                  head.source.cursor.sequence >= cursor.sequence,
                  head.session == expectedSession else {
                return .mismatch
            }
            guard head.structuralIntegrityValid else { return .mismatch }
            if head.coverage.unknownEventCount > 0 || head.coverage.corruptionCount > 0
                    || !head.semanticProjectionValid {
                return .mismatch
            }
            let bucket = try store.loadBucket(
                containingSequence: cursor.sequence, proving: result.source)
            guard let row = bucket.rows.first(where: { $0.sequence == cursor.sequence }),
                  row.eventID == cursor.eventID,
                  row.byteEnd > 0 else { return .mismatch }
            let prefixData = try Self.readPrefixData(
                at: sourceURL, offset: 0, expectedByteCount: row.byteEnd,
                maximum: WorkHostControlLimits.maxProjectedRegistrationPrefixBytes,
                expectedSourceByteCount: result.source.sourceByteCount)
            addReadMetrics(projectedSessionPrefixBytesRead: prefixData.count)
            let read = TimelineJournalReader.read(
                prefixData, journal: sourceJournal, actor: readerActor,
                hostRecordedAt: Date(timeIntervalSince1970: 0))
            guard read.quarantinedSuffix == nil,
                  read.truncatedTail == nil,
                  read.records.count == cursor.sequence else { return .mismatch }
            let registered = read.records.map(\.event)
            guard let first = registered.first,
                  first.sequence == 1,
                  first.type == expectedGenesisType,
                  registered.dropFirst().allSatisfy({ $0.type != expectedGenesisType }) else {
                return .mismatch
            }
            var previousEventID: String?
            var attachments = Set<SessionAttachmentRef>()
            var eventIDs = Set<String>()
            for event in registered {
                guard event.journal == sourceJournal,
                      event.sequence == eventIDs.count + 1,
                      event.previousEventID == previousEventID,
                      event.provenance == .native,
                      event.schemaVersion == TimelineEvent.currentSchemaVersion,
                      event.payloadVersion <= 1,
                      event.isKnownType,
                      controlBoundedIdentity(event.eventID),
                      eventIDs.insert(event.eventID).inserted,
                      event.session == expectedSession else { return .mismatch }
                if let eventWork = event.work {
                    guard controlBoundedIdentity(eventWork.workHostID),
                          controlBoundedIdentity(eventWork.workID),
                          event.workHost.map({ $0.workHostID == eventWork.workHostID }) ?? true else {
                        return .mismatch
                    }
                } else if event.workHost != nil {
                    return .mismatch
                }
                guard event.work.map({ $0 == expectedWork }) ?? true,
                      event.workHost.map({ $0 == workHost }) ?? true,
                      event.sessionAttachment.map({ $0 == expectedAttachment }) ?? true else {
                    return .mismatch
                }
                if event.type == TimelineEventType.sessionAttached {
                    guard event.work == expectedWork,
                          event.sessionAttachment == expectedAttachment else { return .mismatch }
                    attachments.insert(expectedAttachment)
                }
                previousEventID = event.eventID
            }
            return .valid(WorkHostControlSourceJournalEvidence(
                attachments: attachments, dataDigest: controlSHA256(prefixData)))
        } catch let error as LocalTimelineProjectionReader.ReaderError {
            if (error == .cacheUnavailable || error == .sourceChanged
                    || error == .invalidCachedProjection || error == .exactStateUnavailable),
               !cacheRepairAttempted {
                // HEAD and exact-state objects are disposable. Rebuild after a cache boundary
                // failure, but never relax the canonical prefix/suffix checks below.
                try? FileManager.default.removeItem(at: projectionDirectory)
                return observeProjectedSessionSource(
                    sourceJournal, home: home, sourceURL: sourceURL, cursor: cursor,
                    expectedWork: expectedWork, expectedSession: expectedSession,
                    expectedAttachment: expectedAttachment,
                    expectedGenesisType: expectedGenesisType, cacheRepairAttempted: true)
            }
            switch error {
            case .malformedLine, .truncatedTail, .lineTooLarge:
                return .incomplete
            case .sourceChanged, .duplicateIdentity, .tooManyEvents, .sourceTooLarge,
                 .invalidCachedProjection, .cacheUnavailable, .projectionFailed,
                 .exactStateUnavailable, .storeRejected, .unsupportedJournal,
                 .tooManyIndexedRows, .tooManyBuckets:
                return .mismatch
            }
        } catch {
            return .unreadable
        }
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
        let snapshot = try self.snapshot()
        guard snapshot.structuralIntegrityValid,
              snapshot.semanticProjectionValid,
              snapshot.unknownEvents.isEmpty else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is not completely projectable")
        }
        let cursor = currentCursor(of: snapshot)
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
        guard causalCursor.journal == journal else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "creation mutation causal control journal does not match host journal")
        }
        let actualCursor = currentCursor(of: current)
        guard causalCursor == actualCursor else {
            throw WorkHostControlCreationStaleCursorError(
                expected: causalCursor, actual: actualCursor)
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
            omittedEvidenceLinkCount: draft.omittedEvidenceLinkCount,
            payload: draft.payload)
        let commit: TimelineJournalCommit
        do {
            commit = try await writer.append(boundedDraft)
        } catch {
            if case .failed(let reason) = await writer.health { controlFailure = reason }
            throw error
        }
        do {
            try appendToCacheAndSeal(commit: commit, current: current)
            return commit
        } catch {
            let reason = "Work Host control durability seal failed: \(error.localizedDescription)"
            controlFailure = reason
            throw TimelineJournalWriter.WriterError.unavailable(reason)
        }
    }

    /// Append one of the typed Session-creation control facts. It uses the same preflight,
    /// canonical append, and independently synchronized seal path as ordinary control
    /// mutations; keeping it here avoids a second persistence mechanism for recovery state.
    private func appendSessionCreationDraft(
        _ draft: TimelineEventDraft,
        digest: String,
        current: WorkHostControlSnapshot,
        causalCursor: JournalCursor
    ) async throws -> TimelineJournalCommit {
        guard causalCursor == currentCursor(of: current), causalCursor.journal == journal else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation control cursor is stale")
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
            clientAttachment: draft.clientAttachment,
            actor: readerActor, hostRecordedAt: Date(), type: draft.type,
            declaredDomains: draft.declaredDomains, payload: draft.payload)
        var preflight = WorkHostControlReducer(snapshot: current)
        preflight.apply(preflightEvent)
        guard preflight.snapshot.structuralIntegrityValid,
              preflight.snapshot.semanticProjectionValid,
              preflight.snapshot.quarantinedEvents.count == current.quarantinedEvents.count else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "Session creation control fact is not valid for current state")
        }
        let boundedDraft = TimelineEventDraft(
            idempotencyKey: digest, command: draft.command,
            causedByEventID: draft.causedByEventID,
            session: draft.session, work: draft.work, workHost: draft.workHost,
            client: draft.client, sessionAttachment: draft.sessionAttachment,
            clientAttachment: draft.clientAttachment, type: draft.type,
            declaredDomains: draft.declaredDomains, payload: draft.payload)
        let commit: TimelineJournalCommit
        do {
            commit = try await writer.append(boundedDraft)
        } catch {
            if case .failed(let reason) = await writer.health { controlFailure = reason }
            throw error
        }
        do {
            try appendToCacheAndSeal(commit: commit, current: current)
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

    /// A source-journal failure leaves the Session reservation durable, but there is no atomic
    /// cross-journal commit which could make a later control event part of that transaction. Keep
    /// the reservation cursor current until its matching completion or a source-absence abort is
    /// recorded. Exact retries are handled before this guard, so replaying an already committed
    /// mutation remains safe.
    private func rejectNewMutationWhileSessionCreationIncomplete(
        _ snapshot: WorkHostControlSnapshot
    ) throws {
        guard !snapshot.sessionCreations.values.contains(where: { !$0.isResolved }) else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control mutation is blocked by an incomplete Session creation reservation")
        }
    }

    private static func commandIndexKey(
        work: WorkRef, client: ClientRef, commandID: String
    ) -> String {
        "work:\(work.workHostID.utf8.count):\(work.workHostID)/\(work.workID.utf8.count):\(work.workID)/"
            + controlLengthPrefixedKey(client, commandID: commandID)
    }

    private static func commandIndexKey(for event: TimelineEvent) -> String? {
        guard let work = event.work, let command = event.command,
              let client = command.client else { return nil }
        return commandIndexKey(work: work, client: client, commandID: command.commandID)
    }

    /// Parse exactly the bytes appended after the actor's sealed cache, extend the reducer and
    /// command index, then publish one new seal. Nothing from the candidate becomes visible until
    /// the seal's fsync, rename, and containing-directory fsync have all succeeded.
    private func appendToCacheAndSeal(
        commit: TimelineJournalCommit, current: WorkHostControlSnapshot
    ) throws {
        guard let priorDigest = cachedDigestState,
              cachedCursor == currentCursor(of: current),
              cachedSealedByteCount >= 0,
              current.lastSequence < WorkHostControlLimits.maxSupportedControlRecords else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host append cache is not at the current sealed cursor")
        }
        let before = try controlFileFingerprint()
        guard before.byteCount >= cachedSealedByteCount else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal moved backwards during append")
        }
        let appended = try Self.readDataRange(
            at: fileURL, offset: cachedSealedByteCount, expectedByteCount: before.byteCount,
            maximum: nil)
        let parsed = TimelineJournalReader.read(
            appended, journal: journal, actor: readerActor, hostRecordedAt: Date(),
            initialByteOffset: cachedSealedByteCount,
            initialSequence: current.lastSequence + 1,
            initialPreviousEventID: current.lastEventID)
        guard parsed.quarantinedSuffix == nil, parsed.truncatedTail == nil,
              parsed.records.count == 1,
              let record = parsed.records.first,
              record.event.eventID == commit.eventRef.eventID,
              record.event.sequence == commit.cursor.sequence else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host append did not produce one canonical event")
        }
        var nextSnapshot = current
        var reducer = WorkHostControlReducer(snapshot: current)
        reducer.apply(record.event)
        nextSnapshot = reducer.snapshot
        guard nextSnapshot.structuralIntegrityValid,
              nextSnapshot.semanticProjectionValid,
              nextSnapshot.quarantinedEvents.count == current.quarantinedEvents.count else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host append is not valid for the cached projection")
        }
        var nextDigest = priorDigest
        nextDigest.update(appended)
        try Self.persistDurabilitySeal(
            for: fileURL, journal: journal, cursor: commit.cursor,
            byteCount: before.byteCount, digest: nextDigest.hexDigest())
        let after = try controlFileFingerprint()
        guard after.byteCount == before.byteCount else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal changed while publishing its seal")
        }
        cachedReadFingerprint = after
        cachedReadResult = nil
        cachedRecordSegments.append(parsed.records)
        cachedSnapshot = nextSnapshot
        cachedCursor = commit.cursor
        if let key = Self.commandIndexKey(for: record.event) {
            cachedCommandIndex[key, default: []].append(record)
        }
        cachedSealedByteCount = before.byteCount
        cachedDigestState = nextDigest
        addReadMetrics(incrementalReads: 1, bytesScanned: appended.count, recordsApplied: 1)
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
        try ensureControlCache()
        guard let current = cachedSnapshot else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal cache was not published")
        }
        guard current.structuralIntegrityValid,
              current.semanticProjectionValid,
              current.unknownEvents.isEmpty else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is not completely projectable")
        }

        let key = Self.commandIndexKey(
            work: identity.work, client: identity.client, commandID: command.commandID)
        let prior = cachedCommandIndex[key] ?? []
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

        try rejectNewMutationWhileSessionCreationIncomplete(current)

        // Verification is deliberately after exact-command reconciliation. Once this exact
        // acknowledgement is durable, a lost-response retry must not start depending on mutable
        // target state that may since have been archived, replaced, or become unavailable.
        if identity.type == TimelineEventType.clientReadAcknowledged,
           let targetJournal = identity.targetJournal,
           let targetCursor = identity.targetCursor {
            try verifyTargetCursor(journal: targetJournal, cursor: targetCursor)
        }

        let actualCursor = cachedCursor ?? currentCursor(of: current)
        guard identity.causalControlCursor == actualCursor else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "control mutation causal cursor is stale")
        }

        let payload = controlPayload(
            workJournal: identity.workJournal,
            sessionJournal: identity.sessionJournal,
            targetJournal: identity.targetJournal,
            cursor: identity.targetCursor,
            capabilities: identity.capabilities.map(Set.init),
            requestedCapabilities: identity.requestedCapabilities.map(Set.init))
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
        // The preflight ID is longer than production UUIDs; the small fixed margin also covers
        // representation differences in an injected clock. Refuse before append so the first
        // byte beyond the bounded journal can never be written by this owner.
        let commit: TimelineJournalCommit
        do {
            commit = try await writer.append(draft)
        } catch {
            if case .failed(let reason) = await writer.health { controlFailure = reason }
            throw error
        }
        do {
            try appendToCacheAndSeal(commit: commit, current: current)
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

    private func addReadMetrics(
        fullReads: Int = 0, cacheHits: Int = 0, incrementalReads: Int = 0,
        invalidations: Int = 0, bytesScanned: Int = 0, recordsApplied: Int = 0,
        targetVerificationBytesScanned: Int = 0, targetVerificationChunks: Int = 0,
        targetVerificationPeakChunkBytes: Int = 0,
        projectedWorkReadCalls: Int = 0, projectedWorkCacheHits: Int = 0,
        projectedWorkBytesRead: Int = 0, projectedWorkSuffixBytesRead: Int = 0,
        projectedWorkPrefixBytesRead: Int = 0,
        projectedSessionReadCalls: Int = 0, projectedSessionCacheHits: Int = 0,
        projectedSessionBytesRead: Int = 0, projectedSessionSuffixBytesRead: Int = 0,
        projectedSessionPrefixBytesRead: Int = 0
    ) {
        func add(_ value: Int, _ delta: Int) -> Int {
            let (result, overflow) = value.addingReportingOverflow(delta)
            return overflow ? Int.max : result
        }
        readMetrics = WorkHostControlJournalReadMetrics(
            fullReads: add(readMetrics.fullReads, fullReads),
            cacheHits: add(readMetrics.cacheHits, cacheHits),
            incrementalReads: add(readMetrics.incrementalReads, incrementalReads),
            invalidations: add(readMetrics.invalidations, invalidations),
            bytesScanned: add(readMetrics.bytesScanned, bytesScanned),
            recordsApplied: add(readMetrics.recordsApplied, recordsApplied),
            targetVerificationBytesScanned: add(
                readMetrics.targetVerificationBytesScanned, targetVerificationBytesScanned),
            targetVerificationChunks: add(
                readMetrics.targetVerificationChunks, targetVerificationChunks),
            targetVerificationPeakChunkBytes: max(
                readMetrics.targetVerificationPeakChunkBytes, targetVerificationPeakChunkBytes),
            projectedWorkReadCalls: add(
                readMetrics.projectedWorkReadCalls, projectedWorkReadCalls),
            projectedWorkCacheHits: add(
                readMetrics.projectedWorkCacheHits, projectedWorkCacheHits),
            projectedWorkBytesRead: add(
                readMetrics.projectedWorkBytesRead, projectedWorkBytesRead),
            projectedWorkSuffixBytesRead: add(
                readMetrics.projectedWorkSuffixBytesRead, projectedWorkSuffixBytesRead),
            projectedWorkPrefixBytesRead: add(
                readMetrics.projectedWorkPrefixBytesRead, projectedWorkPrefixBytesRead),
            projectedSessionReadCalls: add(
                readMetrics.projectedSessionReadCalls, projectedSessionReadCalls),
            projectedSessionCacheHits: add(
                readMetrics.projectedSessionCacheHits, projectedSessionCacheHits),
            projectedSessionBytesRead: add(
                readMetrics.projectedSessionBytesRead, projectedSessionBytesRead),
            projectedSessionSuffixBytesRead: add(
                readMetrics.projectedSessionSuffixBytesRead, projectedSessionSuffixBytesRead),
            projectedSessionPrefixBytesRead: add(
                readMetrics.projectedSessionPrefixBytesRead, projectedSessionPrefixBytesRead))
    }

    private func invalidateCache() {
        cachedReadFingerprint = nil
        cachedReadResult = nil
        cachedRecordSegments.removeAll()
        cachedSnapshot = nil
        cachedCursor = nil
        cachedCommandIndex.removeAll()
        cachedSealedByteCount = 0
        cachedDigestState = nil
        addReadMetrics(invalidations: 1)
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
        if let requestedCapabilities = identity.requestedCapabilities {
            try validateCapabilities(Set(requestedCapabilities))
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

    func mutationDigest(_ identity: WorkHostControlMutationIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        return AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

        let scan = try Self.scanTargetThroughCursor(
            at: targetURL, journal: targetJournal, cursor: cursor, actor: readerActor)
        addReadMetrics(
            targetVerificationBytesScanned: scan.bytesScanned,
            targetVerificationChunks: scan.chunks,
            targetVerificationPeakChunkBytes: scan.peakChunkBytes)
    }

    /// Verify only the canonical prefix named by an acknowledgement cursor. Bytes after that
    /// cursor are intentionally neither read nor interpreted: a client may acknowledge an early
    /// page while a producer is still appending (or has an unusable tail). The Work/Session source
    /// service validates global event-ID uniqueness when it admits and serves a source journal;
    /// this acknowledgement proof retains no prefix-sized ID set and proves the exact local
    /// chain/sequence/previous-link/cursor instead. The open descriptor's identity is compared
    /// with the path before and after scanning to fence replacement races.
    private struct TargetCursorScanStats {
        let bytesScanned: Int
        let chunks: Int
        let peakChunkBytes: Int
    }

    private static func scanTargetThroughCursor(
        at url: URL, journal: JournalRef, cursor: JournalCursor, actor: TimelineActor
    ) throws -> TargetCursorScanStats {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement target is unavailable")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var before = stat()
        var beforePath = stat()
        let beforePathResult = url.path.withCString { lstat($0, &beforePath) }
        guard fstat(descriptor, &before) == 0,
              beforePathResult == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(), before.st_size >= 0,
              before.st_size <= off_t(Int.max),
              before.st_dev == beforePath.st_dev, before.st_ino == beforePath.st_ino else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement target is not a bounded owner-readable file")
        }

        // The empty-prefix cursor is a valid acknowledgement even when later bytes already
        // exist. No bytes after the requested cursor are needed to prove it.
        var bytesScanned = 0
        var chunks = 0
        var peakChunkBytes = 0
        if cursor.sequence > 0 {
            var parser = TimelineJournalReaderState(
                journal: journal, actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 0))
            var sequence = 1
            var previousEventID: String?
            var found = false
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            while !found {
                let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty {
                    let final = parser.append(Data(), final: true)
                    guard final.quarantinedSuffix == nil, final.truncatedTail == nil else {
                        throw TimelineJournalWriter.WriterError.invalidDraft(
                            reason: "read acknowledgement target has malformed bytes before cursor")
                    }
                    break
                }
                bytesScanned += chunk.count
                chunks += 1
                peakChunkBytes = max(peakChunkBytes, chunk.count)
                let parsed = parser.append(chunk, final: false)
                for record in parsed.records {
                    let event = record.event
                    guard event.journal == journal,
                          event.sequence == sequence,
                          event.previousEventID == previousEventID,
                          event.provenance == .native,
                          event.schemaVersion == TimelineEvent.currentSchemaVersion,
                          event.payloadVersion <= 1,
                          !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TimelineJournalWriter.WriterError.invalidDraft(
                            reason: "read acknowledgement target is not one canonical append chain")
                    }
                    if sequence == cursor.sequence {
                        guard event.eventID == cursor.eventID else {
                            throw TimelineJournalWriter.WriterError.invalidDraft(
                                reason: "read acknowledgement cursor is absent from the target journal")
                        }
                        found = true
                        break
                    }
                    previousEventID = event.eventID
                    sequence += 1
                }
                // A malformed suffix in the same bounded chunk is irrelevant only if the exact
                // target was already emitted from the chunk. Otherwise it is before the cursor.
                if !found, parsed.quarantinedSuffix != nil {
                    throw TimelineJournalWriter.WriterError.invalidDraft(
                        reason: "read acknowledgement target has malformed bytes before cursor")
                }
            }
            guard found else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "read acknowledgement cursor is absent from the target journal")
            }
        } else {
            guard cursor.eventID == nil else {
                throw TimelineJournalWriter.WriterError.invalidDraft(
                    reason: "read acknowledgement baseline cursor carries an event identity")
            }
        }

        var after = stat()
        var afterPath = stat()
        let afterPathResult = url.path.withCString { lstat($0, &afterPath) }
        guard fstat(descriptor, &after) == 0,
              afterPathResult == 0,
              after.st_dev == afterPath.st_dev, after.st_ino == afterPath.st_ino,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size else {
            throw TimelineJournalWriter.WriterError.invalidDraft(
                reason: "read acknowledgement target changed during verification")
        }
        return TargetCursorScanStats(
            bytesScanned: bytesScanned, chunks: chunks, peakChunkBytes: peakChunkBytes)
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
        capabilities: Set<String>? = nil,
        requestedCapabilities: Set<String>? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = ["work_journal": encodeControlValue(workJournal)]
        if let sessionJournal { object["session_journal"] = encodeControlValue(sessionJournal) }
        if let targetJournal { object["target_journal"] = encodeControlValue(targetJournal) }
        if let cursor { object["cursor"] = encodeControlValue(cursor) }
        if let capabilities {
            object["capabilities"] = .array(capabilities.sorted().map { .string($0) })
        }
        if let requestedCapabilities {
            object["requested_capabilities"] = .array(
                requestedCapabilities.sorted().map { .string($0) })
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
        let sealData = try readFileData(
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

    private static func validateCachedSeal(
        at journalURL: URL, journal: JournalRef, byteCount: Int,
        cursor: JournalCursor, digest: String
    ) throws {
        let sealData = try readFileData(
            at: durabilitySealURL(for: journalURL), maximum: WorkHostControlLimits.maxDurabilitySealBytes)
        guard let seal = try? JSONDecoder().decode(WorkHostControlDurabilitySeal.self, from: sealData),
              seal.schemaVersion == 1, seal.journal == journal,
              seal.cursor == cursor, seal.byteCount == byteCount, seal.sha256 == digest else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability seal changed outside the owner")
        }
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
        var digestState = ControlSHA256State()
        digestState.update(data)
        try persistDurabilitySeal(
            for: journalURL, journal: journal, cursor: cursor,
            byteCount: data.count, digest: digestState.hexDigest())
    }

    private static func persistDurabilitySeal(
        for journalURL: URL,
        journal: JournalRef,
        cursor: JournalCursor,
        byteCount: Int,
        digest: String
    ) throws {
        guard byteCount >= 0,
              digest.count == 64,
              digest.unicodeScalars.allSatisfy({
                  switch $0.value {
                  case 48...57, 65...70, 97...102: return true
                  default: return false
                  }
              }) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control durability seal digest is malformed")
        }
        let seal = WorkHostControlDurabilitySeal(
            schemaVersion: 1, journal: journal, cursor: cursor,
            byteCount: byteCount, sha256: digest)
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
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not create Work Host control durability seal")
        }
        defer {
            _ = AviaryPOSIX.close(descriptor)
            _ = temporaryURL.path.withCString { unlink($0) }
        }
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = write(
                    descriptor, base.advanced(by: written), bytes.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw TimelineJournalWriter.WriterError.unavailable(
                        "could not write Work Host control durability seal")
                }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not synchronize Work Host control durability seal")
        }
        let renamed = temporaryURL.path.withCString { source in
            sealURL.path.withCString { destination in rename(source, destination) }
        }
        guard renamed == 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not publish Work Host control durability seal")
        }
        let directoryDescriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.unavailable(
                "could not open Work Host control directory for synchronization")
        }
        defer { _ = AviaryPOSIX.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
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
            let sealResult = sealURL.path.withCString { lstat($0, &sealStatus) }
            guard data.isEmpty, sealResult != 0, errno == ENOENT else { throw error }
            let zero = JournalCursor(journal: journal, eventID: nil, sequence: 0)
            try persistDurabilitySeal(
                for: journalURL, journal: journal, cursor: zero, data: Data())
            return 0
        }
    }

    private static func readFileData(at url: URL, maximum: Int? = nil) throws -> Data {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "required Work Host journal data is unavailable")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size >= 0,
              maximum.map({ status.st_size <= off_t($0) }) ?? true,
              status.st_size <= off_t(Int.max) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host journal data is not one owner-readable file")
        }
        var data = Data()
        let expectedByteCount = Int(status.st_size)
        while data.count < expectedByteCount {
            var buffer = [UInt8](repeating: 0, count: min(1024 * 1024, expectedByteCount - data.count))
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                AviaryPOSIX.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "Work Host control durability data could not be read")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == expectedByteCount,
              maximum.map({ data.count <= $0 }) ?? true else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host journal data could not be read to EOF")
        }
        return data
    }

    /// Read only a newly appended range. The descriptor and path are fenced on both sides so a
    /// replacement or concurrent rewrite cannot be mistaken for the owner's append.
    private static func readDataRange(
        at url: URL, offset: Int, expectedByteCount: Int, maximum: Int?
    ) throws -> Data {
        guard offset >= 0, expectedByteCount >= offset else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control append range is invalid")
        }
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is unavailable while extending its cache")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var before = stat()
        var path = stat()
        let pathResult = url.path.withCString { lstat($0, &path) }
        guard fstat(descriptor, &before) == 0,
              pathResult == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_dev == path.st_dev, before.st_ino == path.st_ino,
              before.st_size == off_t(expectedByteCount), before.st_size >= 0,
              maximum.map({ expectedByteCount - offset <= $0 }) ?? true else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal changed while extending its cache")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: UInt64(offset))
        var data = Data()
        while data.count < expectedByteCount - offset {
            let requested = min(1024 * 1024, expectedByteCount - offset - data.count)
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "Work Host control append range was truncated")
            }
            data.append(chunk)
        }
        var after = stat()
        var afterPath = stat()
        let afterPathResult = url.path.withCString { lstat($0, &afterPath) }
        guard fstat(descriptor, &after) == 0,
              afterPathResult == 0,
              after.st_dev == afterPath.st_dev, after.st_ino == afterPath.st_ino,
              after.st_size == off_t(expectedByteCount) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal changed while extending its cache")
        }
        return data
    }

    /// Read a bounded canonical prefix while allowing the source to have a newer suffix. This is
    /// used only for the registration proof after the persistent Work projection has verified the
    /// current tip; it must not be confused with append-cache range reads above, which require an
    /// exact file size.
    private static func readPrefixData(
        at url: URL, offset: Int, expectedByteCount: Int, maximum: Int?,
        expectedSourceByteCount: Int
    ) throws -> Data {
        guard offset >= 0, expectedByteCount >= offset,
              maximum.map({ expectedByteCount - offset <= $0 }) ?? true else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control prefix range is invalid")
        }
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host source is unavailable while reading its prefix")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var before = stat()
        var path = stat()
        let pathResult = url.path.withCString { lstat($0, &path) }
        guard fstat(descriptor, &before) == 0,
              pathResult == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_dev == path.st_dev, before.st_ino == path.st_ino,
              before.st_size == off_t(expectedSourceByteCount),
              before.st_size >= off_t(expectedByteCount) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host source changed while reading its prefix")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: UInt64(offset))
        var data = Data()
        while data.count < expectedByteCount - offset {
            let requested = min(1024 * 1024, expectedByteCount - offset - data.count)
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "Work Host source prefix was truncated")
            }
            data.append(chunk)
        }
        var after = stat()
        var afterPath = stat()
        let afterPathResult = url.path.withCString { lstat($0, &afterPath) }
        guard fstat(descriptor, &after) == 0,
              afterPathResult == 0,
              after.st_dev == afterPath.st_dev, after.st_ino == afterPath.st_ino,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == off_t(expectedSourceByteCount),
              after.st_size >= off_t(expectedByteCount) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host source changed while reading its prefix")
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        AviarySHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func controlFileFingerprint() throws -> ControlFileFingerprint {
        let descriptor = fileURL.standardizedFileURL.path.withCString {
            AviaryPOSIX.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "required Work Host control journal is unavailable")
        }
        defer { _ = AviaryPOSIX.close(descriptor) }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_size >= 0,
              descriptorStatus.st_size <= off_t(Int.max) else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal is not one owner file")
        }
        var pathStatus = stat()
        let pathResult = fileURL.standardizedFileURL.path.withCString {
            lstat($0, &pathStatus)
        }
        guard pathResult == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            throw TimelineJournalWriter.WriterError.invalidJournal(
                reason: "Work Host control journal path changed during read")
        }
        let byteCount = Int(descriptorStatus.st_size)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let lastByte: UInt8?
        if byteCount == 0 {
            lastByte = nil
        } else {
            try handle.seek(toOffset: UInt64(byteCount - 1))
            let data = try handle.read(upToCount: 1) ?? Data()
            guard data.count == 1 else {
                throw TimelineJournalWriter.WriterError.invalidJournal(
                    reason: "Work Host control journal could not be fingerprinted")
            }
            lastByte = data[data.startIndex]
            try handle.seek(toOffset: 0)
        }
        #if canImport(Darwin)
        let modificationSeconds = Int64(descriptorStatus.st_mtimespec.tv_sec)
        let modificationNanoseconds = Int64(descriptorStatus.st_mtimespec.tv_nsec)
        let changeSeconds = Int64(descriptorStatus.st_ctimespec.tv_sec)
        let changeNanoseconds = Int64(descriptorStatus.st_ctimespec.tv_nsec)
        #elseif canImport(Glibc)
        let modificationSeconds = Int64(descriptorStatus.st_mtim.tv_sec)
        let modificationNanoseconds = Int64(descriptorStatus.st_mtim.tv_nsec)
        let changeSeconds = Int64(descriptorStatus.st_ctim.tv_sec)
        let changeNanoseconds = Int64(descriptorStatus.st_ctim.tv_nsec)
        #else
        let modificationSeconds: Int64 = 0
        let modificationNanoseconds: Int64 = 0
        let changeSeconds: Int64 = 0
        let changeNanoseconds: Int64 = 0
        #endif
        return ControlFileFingerprint(
            device: UInt64(descriptorStatus.st_dev), inode: UInt64(descriptorStatus.st_ino),
            mode: UInt32(descriptorStatus.st_mode), byteCount: byteCount,
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds,
            changeSeconds: changeSeconds, changeNanoseconds: changeNanoseconds,
            lastByte: lastByte)
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
