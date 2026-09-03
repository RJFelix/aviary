import CryptoKit
import Darwin
import Foundation

private enum WorkHostControlLimits {
    static let maxIdentityCharacters = 256
    static let maxCapabilities = 64
    static let maxCapabilityCharacters = 128
    static let maxTargetJournalBytes = 64 * 1024 * 1024
    static let maxControlJournalBytes = 64 * 1024 * 1024
    static let maxDurabilitySealBytes = 16 * 1024
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
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws {
        let journal = JournalRef.workHost(workHost)
        self.journal = journal
        self.workHost = workHost
        self.fileURL = fileURL
        self.readerActor = actor
        self.home = home
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
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws {
        let journal = JournalRef.workHost(workHost)
        self.journal = journal
        self.workHost = workHost
        self.fileURL = fileURL
        self.readerActor = actor
        self.home = home
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
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws -> WorkHostControlJournal {
        return try WorkHostControlJournal(
            freshAt: home.timelineV2WorkHostControlJournalURL(workHost),
            workHost: workHost, actor: actor, home: home, failurePlan: failurePlan,
            eventIDProvider: eventIDProvider, now: now, didSynchronize: didSynchronize)
    }

    public static func reopenExisting(
        home: AgentHome,
        workHost: WorkHostRef,
        actor: TimelineActor,
        failurePlan: TimelineJournalWriter.FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws -> WorkHostControlJournal {
        return try WorkHostControlJournal(
            reopening: home.timelineV2WorkHostControlJournalURL(workHost),
            workHost: workHost, actor: actor, home: home, failurePlan: failurePlan,
            eventIDProvider: eventIDProvider, now: now, didSynchronize: didSynchronize)
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
