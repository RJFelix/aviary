import Foundation
import Darwin

/// The caller-supplied part of a Timeline v2 event.
///
/// Journal position, the physical append-chain link, host time, and the writer actor are
/// deliberately not inputs.  Those values are facts established by the journal owner at commit
/// time.  Event ids are also writer-owned: a caller can describe an event, but cannot make a
/// second event look like an already committed one.
public struct TimelineEventDraft: Codable, Hashable, Sendable {
    public let hostSequence: Int?
    public let idempotencyKey: String?
    public let command: CommandRef?
    public let causedByEventID: EventRef?
    public let parentActivityID: EventRef?
    public let conversationParent: EventRef?
    public let session: SessionRef?
    public let work: WorkRef?
    public let workHost: WorkHostRef?
    public let client: ClientRef?
    public let sessionAttachment: SessionAttachmentRef?
    public let clientAttachment: ClientAttachmentRef?
    public let run: RunRef?
    public let turn: TurnRef?
    public let action: ActionRef?
    public let handle: HandleRef?
    public let clientTimestamp: Date?
    public let payloadVersion: Int
    public let type: String
    public let declaredDomains: Set<TimelineDomain>
    public let links: [TimelineLink]
    public let payload: JSONValue

    public init(
        hostSequence: Int? = nil,
        idempotencyKey: String? = nil,
        command: CommandRef? = nil,
        causedByEventID: EventRef? = nil,
        parentActivityID: EventRef? = nil,
        conversationParent: EventRef? = nil,
        session: SessionRef? = nil,
        work: WorkRef? = nil,
        workHost: WorkHostRef? = nil,
        client: ClientRef? = nil,
        sessionAttachment: SessionAttachmentRef? = nil,
        clientAttachment: ClientAttachmentRef? = nil,
        run: RunRef? = nil,
        turn: TurnRef? = nil,
        action: ActionRef? = nil,
        handle: HandleRef? = nil,
        clientTimestamp: Date? = nil,
        payloadVersion: Int = 1,
        type: String,
        declaredDomains: Set<TimelineDomain> = [],
        links: [TimelineLink] = [],
        payload: JSONValue = .object([:])
    ) {
        self.hostSequence = hostSequence
        self.idempotencyKey = idempotencyKey
        self.command = command
        self.causedByEventID = causedByEventID
        self.parentActivityID = parentActivityID
        self.conversationParent = conversationParent
        self.session = session
        self.work = work
        self.workHost = workHost
        self.client = client
        self.sessionAttachment = sessionAttachment
        self.clientAttachment = clientAttachment
        self.run = run
        self.turn = turn
        self.action = action
        self.handle = handle
        self.clientTimestamp = clientTimestamp
        self.payloadVersion = payloadVersion
        self.type = type
        self.declaredDomains = declaredDomains
        self.links = links
        self.payload = payload
    }

    /// A descriptive alias for callers that think of links as evidence rather than causal
    /// edges.  The wire field remains `links`, matching `TimelineEvent`.
    public var evidenceLinks: [TimelineLink] { links }
}

/// The durable result of one successful append.
public struct TimelineJournalCommit: Codable, Hashable, Sendable {
    public let eventRef: EventRef
    public let cursor: JournalCursor

    public init(eventRef: EventRef, cursor: JournalCursor) {
        self.eventRef = eventRef
        self.cursor = cursor
    }

}

/// One host-side writer for one Timeline v2 journal.
///
/// The actor serializes callers in one process.  The advisory lock acquired during construction
/// is the separate process boundary: a GUI, CLI, or service cannot accidentally become a second
/// writer merely because it has a different actor instance.
public actor TimelineJournalWriter {
    public enum FailurePoint: String, CaseIterable, Hashable, Sendable {
        case beforeWrite
        case partialWrite
        case afterWriteBeforeSync
        case sync
        case close
    }

    public struct FailurePlan: Hashable, Sendable {
        public var point: FailurePoint?

        public init(point: FailurePoint? = nil) {
            self.point = point
        }

        public static let none = FailurePlan()
    }

    public enum WriterHealth: Hashable, Sendable {
        case healthy
        case failed(reason: String)
        case closed
    }

    public enum WriterError: LocalizedError, Equatable, Sendable {
        case alreadyExists(path: String)
        case missing(path: String)
        case competingWriter(path: String)
        case accessDenied(path: String)
        case openFailed(path: String, reason: String)
        case invalidDraft(reason: String)
        case invalidJournal(reason: String)
        case eventIDCollision(String)
        case encodingFailed(String)
        case dataPathReplaced(path: String)
        case injected(FailurePoint)
        case unavailable(String)
        case closed
        case closeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyExists(let path):
                return "Timeline journal already exists: \(path)"
            case .missing(let path):
                return "Timeline journal does not exist: \(path)"
            case .competingWriter(let path):
                return "Timeline journal is already held by another writer: \(path)"
            case .accessDenied(let path):
                return "Timeline journal cannot be opened for writing: \(path)"
            case .openFailed(let path, let reason):
                return "Timeline journal could not be opened at \(path): \(reason)"
            case .invalidDraft(let reason):
                return "Invalid Timeline event draft: \(reason)"
            case .invalidJournal(let reason):
                return "Invalid Timeline journal: \(reason)"
            case .eventIDCollision(let id):
                return "Timeline event id is empty or already used: \(id)"
            case .encodingFailed(let reason):
                return "Timeline event could not be encoded: \(reason)"
            case .dataPathReplaced(let path):
                return "Timeline journal data path no longer names the writer's file: \(path)"
            case .injected(let point):
                return "Injected Timeline journal failure at \(point.rawValue)."
            case .unavailable(let reason):
                return "Timeline journal unavailable: \(reason)"
            case .closed:
                return "Timeline journal is closed."
            case .closeFailed(let reason):
                return "Timeline journal close failed: \(reason)"
            }
        }
    }

    /// The journal identity is immutable for the lifetime of this writer.
    public nonisolated let journal: JournalRef
    /// The actor stamped onto every event produced by this writer.
    public nonisolated let hostActor: TimelineActor
    public nonisolated var actor: TimelineActor { hostActor }
    public nonisolated let fileURL: URL
    /// The stable lock locator. It is intentionally independent of the journal data path.
    public nonisolated let lockFileURL: URL

    private struct OpenedJournal {
        let handle: FileHandle
        let nextSequence: Int
        let previousEventID: String?
        let eventIDs: Set<String>
    }

    private struct OpenedWriter {
        let journal: OpenedJournal
        let lockHandle: FileHandle
        let lockURL: URL
    }

    private let handle: FileHandle
    private let lockHandle: FileHandle
    private let eventIDProvider: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let didSynchronize: (@Sendable () -> Void)?
    private var nextSequence: Int
    private var previousEventID: String?
    private var eventIDs: Set<String>
    private var failurePlan: FailurePlan
    private var synchronizeCount = 0
    private var healthState: WriterHealth = .healthy
    private var isClosed = false

    /// Create a new, empty journal without ever overwriting an existing path.
    public init(
        freshAt fileURL: URL,
        journal: JournalRef,
        actor: TimelineActor,
        home: AgentHome? = nil,
        failurePlan: FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws {
        let opened = try Self.openFreshWriter(
            fileURL, journal: journal, home: home ?? Self.inferHome(for: fileURL))
        self.journal = journal
        self.hostActor = actor
        self.fileURL = fileURL
        self.handle = opened.journal.handle
        self.lockHandle = opened.lockHandle
        self.lockFileURL = opened.lockURL
        self.eventIDProvider = eventIDProvider
        self.now = now
        self.didSynchronize = didSynchronize
        self.nextSequence = opened.journal.nextSequence
        self.previousEventID = opened.journal.previousEventID
        self.eventIDs = opened.journal.eventIDs
        self.failurePlan = failurePlan
    }

    /// Continue an existing journal only after validating its complete committed prefix.
    public init(
        reopening fileURL: URL,
        journal: JournalRef,
        actor: TimelineActor,
        home: AgentHome? = nil,
        recoveryCommittedByteCount: (@Sendable (Data) throws -> Int)? = nil,
        failurePlan: FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws {
        let opened = try Self.openExistingWriter(
            fileURL, journal: journal, actor: actor,
            home: home ?? Self.inferHome(for: fileURL),
            recoveryCommittedByteCount: recoveryCommittedByteCount)
        self.journal = journal
        self.hostActor = actor
        self.fileURL = fileURL
        self.handle = opened.journal.handle
        self.lockHandle = opened.lockHandle
        self.lockFileURL = opened.lockURL
        self.eventIDProvider = eventIDProvider
        self.now = now
        self.didSynchronize = didSynchronize
        self.nextSequence = opened.journal.nextSequence
        self.previousEventID = opened.journal.previousEventID
        self.eventIDs = opened.journal.eventIDs
        self.failurePlan = failurePlan
    }

    /// Run a synchronous owner-side operation under the same cross-process advisory lock used by
    /// Timeline writers. This is for short catalog mutations such as moving a legacy companion to
    /// Trash: the caller can revalidate native truth and complete the move without a cooperating
    /// writer entering between check and action. It is not a remote lease protocol.
    public static func withAdvisoryOwnerLock<T>(
        home: AgentHome,
        journal: JournalRef,
        dataURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        let lock = try openLock(
            at: home.timelineV2JournalLockURL(for: journal), reporting: dataURL)
        defer { try? lock.close() }
        return try operation()
    }

    public static func createFresh(
        at fileURL: URL,
        journal: JournalRef,
        actor: TimelineActor,
        home: AgentHome? = nil,
        failurePlan: FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws -> TimelineJournalWriter {
        try TimelineJournalWriter(freshAt: fileURL, journal: journal, actor: actor,
                                  home: home, failurePlan: failurePlan,
                                  eventIDProvider: eventIDProvider, now: now,
                                  didSynchronize: didSynchronize)
    }

    public static func reopenExisting(
        at fileURL: URL,
        journal: JournalRef,
        actor: TimelineActor,
        home: AgentHome? = nil,
        recoveryCommittedByteCount: (@Sendable (Data) throws -> Int)? = nil,
        failurePlan: FailurePlan = .none,
        eventIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        now: @escaping @Sendable () -> Date = { Date() },
        didSynchronize: (@Sendable () -> Void)? = nil
    ) throws -> TimelineJournalWriter {
        try TimelineJournalWriter(reopening: fileURL, journal: journal, actor: actor,
                                  home: home,
                                  recoveryCommittedByteCount: recoveryCommittedByteCount,
                                  failurePlan: failurePlan,
                                  eventIDProvider: eventIDProvider, now: now,
                                  didSynchronize: didSynchronize)
    }

    /// Validate caller-controlled envelope fields without opening a file.
    public static func validate(_ draft: TimelineEventDraft, for journal: JournalRef) throws {
        try validateEnvelope(type: draft.type, links: draft.links, session: draft.session,
                             work: draft.work, workHost: draft.workHost, journal: journal)
    }

    public var health: WriterHealth { healthState }
    public var nextSequenceNumber: Int { nextSequence }
    public var lastEventID: String? { previousEventID }
    public var synchronizeCallCount: Int { synchronizeCount }
    var descriptorsCloseOnExec: Bool {
        let dataFlags = Darwin.fcntl(handle.fileDescriptor, F_GETFD)
        let lockFlags = Darwin.fcntl(lockHandle.fileDescriptor, F_GETFD)
        return dataFlags >= 0 && lockFlags >= 0
            && (dataFlags & FD_CLOEXEC) != 0 && (lockFlags & FD_CLOEXEC) != 0
    }

    /// Install a one-shot failure at the next matching boundary. This is a diagnostic/test seam;
    /// production writers leave it at `nil`.
    public func injectFailure(_ point: FailurePoint?) {
        failurePlan.point = point
    }

    @discardableResult
    public func append(_ draft: TimelineEventDraft) throws -> TimelineJournalCommit {
        try ensureAppendable()
        try Self.validate(draft, for: journal)

        let eventID = eventIDProvider()
        guard !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !eventIDs.contains(eventID)
        else {
            let error = WriterError.eventIDCollision(eventID)
            healthState = .failed(reason: error.localizedDescription)
            throw error
        }

        let event = TimelineEvent(
            eventID: eventID,
            journal: journal,
            sequence: nextSequence,
            hostSequence: draft.hostSequence,
            idempotencyKey: draft.idempotencyKey,
            command: draft.command,
            previousEventID: previousEventID,
            causedByEventID: draft.causedByEventID,
            parentActivityID: draft.parentActivityID,
            conversationParent: draft.conversationParent,
            session: draft.session,
            work: draft.work,
            workHost: draft.workHost,
            client: draft.client,
            sessionAttachment: draft.sessionAttachment,
            clientAttachment: draft.clientAttachment,
            run: draft.run,
            turn: draft.turn,
            action: draft.action,
            handle: draft.handle,
            actor: hostActor,
            hostRecordedAt: now(),
            clientTimestamp: draft.clientTimestamp,
            schemaVersion: TimelineEvent.currentSchemaVersion,
            payloadVersion: draft.payloadVersion,
            type: draft.type,
            declaredDomains: draft.declaredDomains,
            provenance: .native,
            links: draft.links,
            payload: draft.payload)

        let bytes: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            bytes = try encoder.encode(event) + Data([UInt8(ascii: "\n")])
        } catch {
            throw WriterError.encodingFailed(error.localizedDescription)
        }

        do {
            try writeAndSynchronize(bytes)
        } catch let error as WriterError {
            healthState = .failed(reason: error.localizedDescription)
            throw error
        } catch {
            let wrapped = WriterError.unavailable(error.localizedDescription)
            healthState = .failed(reason: wrapped.localizedDescription)
            throw wrapped
        }

        // These facts advance only after the complete line and its synchronize have succeeded.
        eventIDs.insert(eventID)
        previousEventID = eventID
        nextSequence += 1
        let eventRef = EventRef(journal: journal, eventID: eventID)
        return TimelineJournalCommit(
            eventRef: eventRef,
            cursor: JournalCursor(journal: journal, eventID: eventID, sequence: event.sequence))
    }

    /// Validate the entire batch before writing its first line. A write failure after that point
    /// remains intentionally visible; committed prefix bytes are never rolled back or repaired.
    public func appendBatch(_ drafts: [TimelineEventDraft]) throws -> [TimelineJournalCommit] {
        try ensureAppendable()
        for draft in drafts {
            try Self.validate(draft, for: journal)
        }
        var commits: [TimelineJournalCommit] = []
        commits.reserveCapacity(drafts.count)
        for draft in drafts {
            commits.append(try append(draft))
        }
        return commits
    }

    /// Close the file and release its OS lock. A close failure never leaves the descriptor/lock
    /// behind, and a prior ambiguous write failure is still reported to the caller.
    public func closeChecked() throws {
        guard !isClosed else {
            if case .failed(let reason) = healthState {
                throw WriterError.unavailable(reason)
            }
            return
        }

        var failure: WriterError?
        let priorFailure: WriterError?
        if case .failed(let reason) = healthState {
            priorFailure = .unavailable(reason)
        } else {
            priorFailure = nil
        }

        let injectedClose = consumeFailure(.close)
        if let priorFailure {
            failure = priorFailure
        } else if let injectedClose {
            failure = injectedClose
        } else {
            do {
                try synchronizeFile()
            } catch {
                failure = .closeFailed(error.localizedDescription)
            }
        }

        do {
            try handle.close()
        } catch {
            if failure == nil { failure = .closeFailed(error.localizedDescription) }
        }
        do {
            try lockHandle.close()
        } catch {
            if failure == nil { failure = .closeFailed(error.localizedDescription) }
        }
        isClosed = true

        if let failure {
            healthState = .failed(reason: failure.localizedDescription)
            throw failure
        }
        healthState = .closed
    }

    /// Source-compatible best-effort teardown for callers that do not need close diagnostics.
    public func close() {
        try? closeChecked()
    }

    // MARK: - Append internals

    private func ensureAppendable() throws {
        guard !isClosed else { throw WriterError.closed }
        switch healthState {
        case .healthy:
            return
        case .failed(let reason):
            throw WriterError.unavailable(reason)
        case .closed:
            throw WriterError.closed
        }
    }

    private func consumeFailure(_ point: FailurePoint) -> WriterError? {
        guard failurePlan.point == point else { return nil }
        failurePlan.point = nil
        return .injected(point)
    }

    private func writeAndSynchronize(_ bytes: Data) throws {
        if let failure = consumeFailure(.beforeWrite) { throw failure }
        try verifyDataPathIdentity()
        if consumeFailure(.partialWrite) != nil {
            let prefixLength = max(1, bytes.count / 2)
            try handle.write(contentsOf: Data(bytes.prefix(prefixLength)))
            throw WriterError.injected(.partialWrite)
        }

        try handle.write(contentsOf: bytes)
        if let failure = consumeFailure(.afterWriteBeforeSync) { throw failure }
        if let failure = consumeFailure(.sync) { throw failure }
        try synchronizeFile()
    }

    private func synchronizeFile() throws {
        try verifyDataPathIdentity()
        try handle.synchronize()
        synchronizeCount += 1
        didSynchronize?()
        try verifyDataPathIdentity()
    }

    /// The owner lock prevents a cooperating second writer, but a catalog move or Trash operation
    /// can still rename the data path itself. Never acknowledge bytes on an orphaned inode as the
    /// canonical journal. Checking on both sides of fsync makes that race explicit and latches the
    /// writer instead of silently forking the path-visible prefix.
    private func verifyDataPathIdentity() throws {
        var descriptorStatus = Darwin.stat()
        guard Darwin.fstat(handle.fileDescriptor, &descriptorStatus) == 0 else {
            throw WriterError.unavailable(
                "could not inspect open journal descriptor: \(String(cString: strerror(errno)))")
        }
        var pathStatus = Darwin.stat()
        let result = fileURL.path.withCString { Darwin.lstat($0, &pathStatus) }
        guard result == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino
        else {
            throw WriterError.dataPathReplaced(path: fileURL.path)
        }
    }

    // MARK: - Open/reopen and validation

    private static func openFreshWriter(
        _ url: URL, journal: JournalRef, home: AgentHome
    ) throws -> OpenedWriter {
        let lockURL = home.timelineV2JournalLockURL(for: journal)
        let lock = try openLock(at: lockURL, reporting: url)
        do {
            let opened = try openFreshFile(url)
            return OpenedWriter(journal: opened, lockHandle: lock, lockURL: lockURL)
        } catch {
            try? lock.close()
            throw error
        }
    }

    private static func openExistingWriter(
        _ url: URL, journal: JournalRef, actor: TimelineActor, home: AgentHome,
        recoveryCommittedByteCount: (@Sendable (Data) throws -> Int)?
    ) throws -> OpenedWriter {
        let lockURL = home.timelineV2JournalLockURL(for: journal)
        let lock = try openLock(at: lockURL, reporting: url)
        do {
            let opened = try openExistingFile(
                url, journal: journal, actor: actor,
                recoveryCommittedByteCount: recoveryCommittedByteCount)
            return OpenedWriter(journal: opened, lockHandle: lock, lockURL: lockURL)
        } catch {
            try? lock.close()
            throw error
        }
    }

    private static func openLock(at url: URL, reporting dataURL: URL) throws -> FileHandle {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw WriterError.openFailed(path: dataURL.path, reason: error.localizedDescription)
        }

        let fd = url.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_CLOEXEC,
                        S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw openError(dataURL, operation: "lock") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Infer the AgentHome for the canonical Timeline v2 locator when callers provide only a
    /// file URL. New integrations should pass `home` explicitly; this keeps the low-level URL API
    /// useful without deriving authority from the data path. The marker itself is excluded from
    /// the inferred root, so `/root/timeline-v2/...` maps back to `/root`, never
    /// `/root/timeline-v2`.
    private static func inferHome(for fileURL: URL) -> AgentHome {
        let path = fileURL.standardizedFileURL.path
        guard let marker = path.range(of: "/timeline-v2/", options: .backwards) else {
            return AgentHome(root: fileURL.deletingLastPathComponent())
        }
        let rootPath = String(path[..<marker.lowerBound])
        return AgentHome(root: URL(fileURLWithPath: rootPath.isEmpty ? "/" : rootPath))
    }

    private static func openFreshFile(_ url: URL) throws -> OpenedJournal {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw WriterError.openFailed(path: url.path, reason: error.localizedDescription)
        }

        let fd = url.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_CLOEXEC,
                        S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw openError(url, operation: "create") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw WriterError.openFailed(path: url.path, reason: error.localizedDescription)
        }
        return OpenedJournal(handle: handle, nextSequence: 1,
                             previousEventID: nil, eventIDs: [])
    }

    private static func openExistingFile(
        _ url: URL, journal: JournalRef, actor: TimelineActor,
        recoveryCommittedByteCount: (@Sendable (Data) throws -> Int)? = nil
    ) throws -> OpenedJournal {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WriterError.missing(path: url.path)
        }
        let fd = url.path.withCString {
            Darwin.open($0, O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw openError(url, operation: "open") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        do {
            try handle.seek(toOffset: 0)
            var bytes = Data()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                bytes.append(chunk)
            }
            if let recoveryCommittedByteCount {
                let committedByteCount = try recoveryCommittedByteCount(bytes)
                guard committedByteCount >= 0, committedByteCount <= bytes.count else {
                    throw WriterError.invalidJournal(
                        reason: "recovery prefix is outside the readable journal")
                }
                if committedByteCount < bytes.count {
                    var descriptorStatus = Darwin.stat()
                    var pathStatus = Darwin.stat()
                    let pathResult = url.path.withCString { Darwin.lstat($0, &pathStatus) }
                    guard Darwin.fstat(handle.fileDescriptor, &descriptorStatus) == 0,
                          pathResult == 0,
                          (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
                          descriptorStatus.st_dev == pathStatus.st_dev,
                          descriptorStatus.st_ino == pathStatus.st_ino,
                          Darwin.ftruncate(
                              handle.fileDescriptor, off_t(committedByteCount)) == 0 else {
                        throw WriterError.invalidJournal(
                            reason: "uncommitted journal suffix could not be discarded safely")
                    }
                    try handle.synchronize()
                    bytes = Data(bytes.prefix(committedByteCount))
                }
            }
            if bytes.isEmpty {
                // A fresh journal is created before its first genesis event. A process crash in
                // that window leaves a valid zero-event prefix; the identity lock prevents a
                // second writer from racing while this one decides what to append first.
                try handle.seekToEnd()
                return OpenedJournal(handle: handle, nextSequence: 1,
                                     previousEventID: nil, eventIDs: [])
            }

            let read = TimelineJournalReader.read(
                bytes, journal: journal, actor: actor, hostRecordedAt: Date())
            guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
                throw WriterError.invalidJournal(reason: "journal has malformed or truncated tail")
            }
            guard !read.records.isEmpty else {
                throw WriterError.invalidJournal(reason: "journal has no committed events")
            }

            var ids = Set<String>()
            for record in read.records {
                let event = record.event
                guard event.provenance == .native else {
                    throw WriterError.invalidJournal(reason: "legacy event at byte \(record.byteStart)")
                }
                guard event.schemaVersion == TimelineEvent.currentSchemaVersion else {
                    throw WriterError.invalidJournal(reason: "event schema is not native v2")
                }
                guard !event.eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ids.insert(event.eventID).inserted
                else {
                    throw WriterError.invalidJournal(reason: "event ids are not unique")
                }
                try validateEvent(event, for: journal)
            }
            guard let last = read.records.last else {
                throw WriterError.invalidJournal(reason: "journal has no tail event")
            }
            guard last.event.sequence < Int.max else {
                throw WriterError.invalidJournal(reason: "journal sequence cannot advance")
            }
            try handle.seekToEnd()
            return OpenedJournal(handle: handle,
                                 nextSequence: last.event.sequence + 1,
                                 previousEventID: last.event.eventID, eventIDs: ids)
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func validateEvent(_ event: TimelineEvent, for journal: JournalRef) throws {
        guard event.journal == journal else {
            throw WriterError.invalidJournal(reason: "event belongs to another journal")
        }
        guard event.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw WriterError.invalidJournal(reason: "event type is empty")
        }
        guard event.links.count <= TimelineEvent.maxEvidenceLinks else {
            throw WriterError.invalidJournal(reason: "event has too many evidence links")
        }
        if let reason = envelopeValidationReason(
            type: event.type, links: event.links, session: event.session,
            work: event.work, workHost: event.workHost, journal: journal) {
            throw WriterError.invalidJournal(reason: reason)
        }
    }

    private static func validateEnvelope(
        type: String,
        links: [TimelineLink],
        session: SessionRef?,
        work: WorkRef?,
        workHost: WorkHostRef?,
        journal: JournalRef
    ) throws {
        if let reason = envelopeValidationReason(
            type: type, links: links, session: session, work: work,
            workHost: workHost, journal: journal) {
            throw WriterError.invalidDraft(reason: reason)
        }
    }

    private static func envelopeValidationReason(
        type: String,
        links: [TimelineLink],
        session: SessionRef?,
        work: WorkRef?,
        workHost: WorkHostRef?,
        journal: JournalRef
    ) -> String? {
        guard !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "event type must not be empty"
        }
        guard links.count <= TimelineEvent.maxEvidenceLinks else {
            return "event has too many evidence links"
        }

        if let work, let workHost, work.workHostID != workHost.workHostID {
            return "Work and Work Host identities disagree"
        }
        if workHost != nil, work == nil {
            // A Work Host control journal is itself owned by the Work Host, so host-level
            // records may carry the typed host identity without naming one Work.
            if case .workHost = journal.owner {
                // Valid for host-level control records.
            } else {
                return "Work Host identity requires a Work identity"
            }
        }

        switch journal.owner {
        case .work(let ownerWork):
            if let work, work != ownerWork {
                return "event Work does not match journal owner"
            }
            if let workHost, workHost.workHostID != ownerWork.workHostID {
                return "event Work Host does not match journal owner"
            }
        case .session(let ownerSession):
            if let session, session != ownerSession {
                return "event Session does not match journal owner"
            }
            // Work is intentionally not required to equal anything in a Session journal. A
            // session may attach remote Work from a different Work Host.
        case .workHost(let ownerHost):
            guard let workHost else {
                return "Work Host control event requires its Work Host identity"
            }
            if workHost != ownerHost {
                return "event Work Host does not match control journal owner"
            }
            if let work, work.workHostID != ownerHost.workHostID {
                return "event Work does not belong to control journal owner"
            }
        }
        return nil
    }

    private static func openError(_ url: URL, operation: String) -> WriterError {
        let code = errno
        switch code {
        case EACCES, EPERM:
            return .accessDenied(path: url.path)
        case ENOENT:
            return .missing(path: url.path)
        case EEXIST:
            return .alreadyExists(path: url.path)
        case EAGAIN, EWOULDBLOCK:
            return .competingWriter(path: url.path)
        default:
            return .openFailed(path: url.path,
                               reason: "\(operation): \(String(cString: strerror(code)))")
        }
    }

}

extension TimelineEventDraft {
    public func validate(for journal: JournalRef) throws {
        try TimelineJournalWriter.validate(self, for: journal)
    }
}
