import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The GUI's durable first-Start obligation for a newly-created Work.
///
/// This is deliberately separate from the controller's ordinary pending-command record.  It
/// exists before a controller can be constructed, and therefore covers the interval after the
/// host durably creates Work but before the GUI has refreshed the Work/Session pair.  The Work
/// Host remains authoritative; this record only preserves the exact user intent and command
/// identity needed to resume that admission after a process crash.
public struct ServiceBackedStartIntent: Codable, Hashable, Sendable {
    public static let schemaVersion = 3

    public let schemaVersion: Int
    public let client: ClientRef
    public let work: WorkRef
    public let session: SessionRef
    public let sessionJournal: JournalRef
    public let sessionAttachment: SessionAttachmentRef
    public let causalWorkCursor: JournalCursor
    public let commandID: String
    public let prompt: String

    /// Work-service journals qualify caller command IDs with the client identity before they
    /// enter the canonical command ledger. The original caller ID remains in this GUI-owned
    /// seed so the exact external request can be retried; evidence lookup uses only the shared
    /// canonical ledger identity.
    public var canonicalCommandID: String {
        WorkServiceCommandLedgerIdentity.commandID(client: client, commandID: commandID)
    }

    public init(
        client: ClientRef, work: WorkRef, session: SessionRef,
        sessionJournal: JournalRef, sessionAttachment: SessionAttachmentRef,
        causalWorkCursor: JournalCursor, commandID: String, prompt: String
    ) throws {
        guard !client.clientID.isEmpty,
              !work.workID.isEmpty,
              !work.workHostID.isEmpty,
              !session.sessionID.isEmpty,
              !sessionJournal.journalID.isEmpty,
              !sessionAttachment.attachmentID.isEmpty,
              causalWorkCursor.journal.owner == .work(work),
              causalWorkCursor.journal.authority.authorityID == work.workHostID,
              causalWorkCursor.sequence >= 0,
              causalWorkCursor.eventID != nil || causalWorkCursor.sequence == 0,
              !commandID.isEmpty,
              commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              prompt.utf8.count <= WorkServiceBounds.maxCommandValueCharacters,
              !commandID.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ServiceBackedStartIntentError.invalid
        }
        self.schemaVersion = Self.schemaVersion
        self.client = client
        self.work = work
        self.session = session
        self.sessionJournal = sessionJournal
        self.sessionAttachment = sessionAttachment
        self.causalWorkCursor = causalWorkCursor
        self.commandID = commandID
        self.prompt = prompt
    }

    /// Construct the first-Start obligation from the exact host-minted Create response. This is
    /// the only transition from a pre-Create seed to a Work/Session-bound intent.
    public init(
        seed: ServiceBackedCreateIntentStore.InitialStart,
        response: WorkServiceCreateWorkResponse,
        client: ClientRef
    ) throws {
        guard response.receipt.state == .accepted || response.receipt.state == .duplicate,
              response.attachment.client == client,
              response.attachment.session == response.session,
              response.attachment.sessionJournal == response.sessionJournal,
              response.attachment.sessionAttachment == response.sessionAttachment,
              response.workCursor.journal.owner == .work(response.work.work),
              response.work.journal == response.workCursor.journal else {
            throw ServiceBackedStartIntentError.invalid
        }
        try self.init(
            client: client, work: response.work.work,
            session: response.session, sessionJournal: response.sessionJournal,
            sessionAttachment: response.sessionAttachment,
            causalWorkCursor: response.workCursor,
            commandID: seed.commandID, prompt: seed.prompt)
    }

    /// True only when a complete canonical projection contains this exact client-qualified
    /// command envelope. A receipt, current Run, or user message is insufficient evidence.
    public func hasCanonicalEvidence(
        in projection: WorkServiceAttachedWorkProjection
    ) -> Bool {
        let expectedCommand = WorkServiceCommandLedgerIdentity.command(
            from: CommandRef(
                commandID: commandID, client: client,
                sessionAttachment: sessionAttachment, causalCursor: causalWorkCursor),
            client: client)
        guard projection.isCanonical,
              projection.descriptor.work == work,
              projection.descriptor.journal == causalWorkCursor.journal,
              projection.attachment.client == client,
              projection.attachment.session == session,
              projection.attachment.sessionJournal == sessionJournal,
              projection.attachment.sessionAttachment == sessionAttachment,
              let recorded = projection.workSnapshot.commands[canonicalCommandID],
              recorded.command == expectedCommand else { return false }
        switch recorded.state {
        case .accepted, .delivered, .notDelivered, .indeterminate, .rejected:
            return true
        }
    }

    public func hasMatchingAttachment(
        in projection: WorkServiceAttachedWorkProjection
    ) -> Bool {
        projection.descriptor.work == work
            && projection.attachment.client == client
            && projection.attachment.session == session
            && projection.attachment.sessionJournal == sessionJournal
            && projection.attachment.sessionAttachment == sessionAttachment
    }
}

public struct ServiceBackedStartIntentStore: Sendable {
    public static let maximumRecordBytes = 64 * 1_024

    public let url: URL
    private let expectedClient: ClientRef
    private let expectedWork: WorkRef
    private let homeRoot: URL

    public init(home: AgentHome, client: ClientRef, work: WorkRef) throws {
        let identity = Data((client.clientID + "\u{0}" + work.workHostID + "\u{0}" + work.workID).utf8)
        let digest = AviarySHA256.hash(data: identity)
            .map { String(format: "%02x", $0) }.joined()
        self.expectedClient = client
        self.expectedWork = work
        self.homeRoot = home.root
        self.url = home.root
            .appending(path: "work-service-clients", directoryHint: .isDirectory)
            .appending(path: "start-intents", directoryHint: .isDirectory)
            .appending(path: digest + ".json", directoryHint: .notDirectory)
        try prepareDirectory()
    }

    public func load() throws -> ServiceBackedStartIntent? {
        try prepareDirectory()
        return try withLock { try readLocked() }
    }

    private func readLocked() throws -> ServiceBackedStartIntent? {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ServiceBackedStartIntentError.corrupt
        }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o777)) == mode_t(0o600),
              information.st_size >= 0,
              information.st_size <= off_t(Self.maximumRecordBytes) else {
            throw ServiceBackedStartIntentError.corrupt
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= Self.maximumRecordBytes - count else {
                    throw ServiceBackedStartIntentError.corrupt
                }
                data.append(buffer, count: count)
            } else if count == 0 { break
            } else if errno != EINTR { throw ServiceBackedStartIntentError.corrupt }
        }
        let value: ServiceBackedStartIntent
        do {
            value = try JSONDecoder().decode(ServiceBackedStartIntent.self, from: data)
        } catch {
            throw ServiceBackedStartIntentError.corrupt
        }
        guard value.schemaVersion == ServiceBackedStartIntent.schemaVersion,
              value.client == expectedClient, value.work == expectedWork,
              Self.validIdentity(value.client.clientID),
              Self.validIdentity(value.work.workHostID),
              Self.validIdentity(value.work.workID),
              Self.validIdentity(value.session.sessionID),
              Self.validIdentity(value.sessionJournal.journalID),
              Self.validIdentity(value.sessionJournal.authority.authorityID),
              value.sessionJournal.owner == .session(value.session),
              Self.validIdentity(value.sessionAttachment.attachmentID),
              value.causalWorkCursor.journal.owner == .work(value.work),
              value.causalWorkCursor.journal.authority.authorityID == value.work.workHostID,
              value.causalWorkCursor.sequence >= 0,
              value.causalWorkCursor.eventID != nil || value.causalWorkCursor.sequence == 0,
              Self.validIdentity(value.commandID),
              value.prompt.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
            throw ServiceBackedStartIntentError.corrupt
        }
        return value
    }

    public func retain(_ intent: ServiceBackedStartIntent) throws {
        try prepareDirectory()
        try withLock {
            guard intent.client == expectedClient, intent.work == expectedWork else {
                throw ServiceBackedStartIntentError.conflict
            }
            if let existing = try readLocked() {
                guard existing == intent else {
                    throw ServiceBackedStartIntentError.conflict
                }
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(intent)
            } catch {
                throw ServiceBackedStartIntentError.corrupt
            }
            guard data.count <= Self.maximumRecordBytes else {
                throw ServiceBackedStartIntentError.tooLarge
            }
            try atomicallyWrite(data)
        }
    }

    public func clear(_ intent: ServiceBackedStartIntent) throws {
        try prepareDirectory()
        try withLock {
            guard let existing = try readLocked() else { return }
            guard existing == intent else { throw ServiceBackedStartIntentError.conflict }
            guard unlink(url.path) == 0 else { throw ServiceBackedStartIntentError.corrupt }
            try synchronizeDirectory()
        }
    }

    private func prepareDirectory() throws {
        let workClients = homeRoot.appending(
            path: "work-service-clients", directoryHint: .isDirectory)
        let startIntents = workClients.appending(
            path: "start-intents", directoryHint: .isDirectory)
        for (index, candidate) in [homeRoot, workClients, startIntents].enumerated() {
            var information = stat()
            if lstat(candidate.path, &information) == 0 {
                guard (information.st_mode & S_IFMT) == S_IFDIR,
                      information.st_uid == geteuid(),
                      (information.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                    throw ServiceBackedStartIntentError.corrupt
                }
            } else {
                guard errno == ENOENT else { throw ServiceBackedStartIntentError.corrupt }
                do {
                    try FileManager.default.createDirectory(
                        at: candidate, withIntermediateDirectories: index == 0,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                } catch {
                    throw ServiceBackedStartIntentError.corrupt
                }
                guard lstat(candidate.path, &information) == 0,
                      (information.st_mode & S_IFMT) == S_IFDIR,
                      information.st_uid == geteuid(),
                      (information.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                    throw ServiceBackedStartIntentError.corrupt
                }
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = url.deletingLastPathComponent().appending(
            path: "." + url.lastPathComponent + ".lock", directoryHint: .notDirectory)
        let fd = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else { throw ServiceBackedStartIntentError.corrupt }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw ServiceBackedStartIntentError.corrupt
        }
        return try body()
    }

    private func atomicallyWrite(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(
            path: "." + url.lastPathComponent + ".tmp-" + UUID().uuidString,
            directoryHint: .notDirectory)
        defer { _ = unlink(temporary.path) }
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw ServiceBackedStartIntentError.corrupt }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw ServiceBackedStartIntentError.corrupt }
                }
            }
            guard fsync(fd) == 0 else { throw ServiceBackedStartIntentError.corrupt }
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        var information = stat()
        if lstat(url.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) == S_IFREG,
                  information.st_uid == geteuid(),
                  (information.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                throw ServiceBackedStartIntentError.corrupt
            }
        } else if errno != ENOENT { throw ServiceBackedStartIntentError.corrupt }
        guard rename(temporary.path, url.path) == 0 else {
            throw ServiceBackedStartIntentError.corrupt
        }
        try synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let directory = url.deletingLastPathComponent()
        let fd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw ServiceBackedStartIntentError.corrupt }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ServiceBackedStartIntentError.corrupt }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

public enum ServiceBackedStartIntentError: Error, Equatable, Sendable {
    case invalid
    case conflict
    case corrupt
    case tooLarge
}
