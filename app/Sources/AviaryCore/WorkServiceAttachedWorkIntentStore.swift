import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Host-private persistence for the one command whose outcome a GUI has not yet reconciled.
///
/// The exact request is retained before transport dispatch so closing or crashing the GUI does
/// not destroy the command identity/body needed to reconcile an indeterminate result. Records
/// are local client state, not Work truth: they never advance a canonical cursor and are removed
/// only after canonical command evidence (or a final rejection) or an explicit abandonment of a
/// known-stale request. A transport receipt alone never consumes the durable intent.
public struct WorkServiceAttachedWorkIntentStore: Sendable, Hashable {
    public static let maximumRecordBytes = 64 * 1_024

    struct Record: Codable, Hashable, Sendable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let request: WorkServiceCommandRequest
        let state: WorkServiceAttachedWorkPendingState
        let expectedResultingWorkCursor: JournalCursor?
        let expectedHostSequence: Int?

        init(request: WorkServiceCommandRequest, state: WorkServiceAttachedWorkPendingState,
             expectedResultingWorkCursor: JournalCursor? = nil,
             expectedHostSequence: Int? = nil) {
            self.schemaVersion = Self.currentSchemaVersion
            self.request = request
            self.state = state
            self.expectedResultingWorkCursor = expectedResultingWorkCursor
            self.expectedHostSequence = expectedHostSequence
        }
    }

    public let url: URL

    public init(url: URL) throws {
        guard url.isFileURL, !url.path.isEmpty,
              !url.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkServiceAttachedWorkControllerError.invalidOptions
        }
        self.url = url
    }

    /// Stable per-client/per-Work location under Aviary-owned state. Opaque digests keep remote
    /// host/work labels out of local path names while the record itself remains exact and private.
    public init(home: AgentHome, client: ClientRef, work: WorkRef) throws {
        let identity = Data((client.clientID + "\u{0}" + work.workHostID + "\u{0}" + work.workID).utf8)
        let digest = AviarySHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        try self.init(url: home.root
            .appending(path: "work-service-clients", directoryHint: .isDirectory)
            .appending(path: "pending-intents", directoryHint: .isDirectory)
            .appending(path: digest + ".json", directoryHint: .notDirectory))
    }

    func load() throws -> Record? {
        try prepareDirectory()
        return try withLock { try readLocked() }
    }

    func retain(_ request: WorkServiceCommandRequest,
                state: WorkServiceAttachedWorkPendingState,
                expectedResultingWorkCursor: JournalCursor? = nil,
                expectedHostSequence: Int? = nil) throws {
        try prepareDirectory()
        try withLock {
            if let existing = try readLocked(), existing.request != request {
                throw WorkServiceAttachedWorkControllerError.pendingCommandExists
            }
            try writeLocked(Record(
                request: request, state: state,
                expectedResultingWorkCursor: expectedResultingWorkCursor,
                expectedHostSequence: expectedHostSequence))
        }
    }

    func clear(expecting request: WorkServiceCommandRequest) throws {
        try prepareDirectory()
        try withLock {
            guard let existing = try readLocked() else { return }
            guard existing.request == request else {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
            guard unlink(url.path) == 0 else {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private func readLocked() throws -> Record? {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o077) == 0,
              information.st_size >= 0,
              information.st_size <= off_t(Self.maximumRecordBytes) else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= Self.maximumRecordBytes - count else {
                    throw WorkServiceAttachedWorkControllerError.sourceIncomplete
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard record.schemaVersion == Record.currentSchemaVersion,
              !record.request.valueWasTruncated,
              (record.request.value?.utf8.count ?? 0) <= WorkServiceBounds.maxCommandValueCharacters,
              record.request.command.client != nil,
              record.request.command.causalCursor == record.request.causalWorkCursor,
              Self.validEvidenceShape(record) else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        return record
    }

    private static func validEvidenceShape(_ record: Record) -> Bool {
        switch record.state {
        case .awaitingCanonicalEvidence:
            guard let cursor = record.expectedResultingWorkCursor,
                  let hostSequence = record.expectedHostSequence,
                  cursor.journal == record.request.journal,
                  cursor.sequence > record.request.causalWorkCursor.sequence,
                  cursor.eventID?.isEmpty == false,
                  hostSequence > 0 else { return false }
            return true
        case .stale, .indeterminate:
            return record.expectedResultingWorkCursor == nil
                && record.expectedHostSequence == nil
        }
    }

    private func writeLocked(_ record: Record) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(record)
        } catch {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw WorkServiceAttachedWorkControllerError.commandNotAdmissible
        }
        if let existing = try readLocked(), existing.request != record.request {
            throw WorkServiceAttachedWorkControllerError.pendingCommandExists
        }
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(
            path: "." + url.lastPathComponent + "-" + UUID().uuidString.lowercased() + ".tmp",
            directoryHint: .notDirectory)
        defer { _ = unlink(temporary.path) }
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw WorkServiceAttachedWorkControllerError.sourceIncomplete }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw WorkServiceAttachedWorkControllerError.sourceIncomplete }
                }
            }
            guard fsync(fd) == 0 else {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
        } catch {
            close(fd)
            throw error
        }
        close(fd)

        var destination = stat()
        if lstat(url.path, &destination) == 0 {
            guard (destination.st_mode & S_IFMT) == S_IFREG,
                  destination.st_uid == geteuid(),
                  destination.st_mode & mode_t(0o077) == 0 else {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
        } else if errno != ENOENT {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        try synchronizeDirectory(directory)
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        var information = stat()
        guard lstat(directory.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o077) == 0 else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lock = url.deletingLastPathComponent().appending(
            path: "." + url.lastPathComponent + ".lock", directoryHint: .notDirectory)
        let fd = lock.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else { throw WorkServiceAttachedWorkControllerError.sourceIncomplete }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(), information.st_mode & mode_t(0o077) == 0 else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        return try body()
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let fd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw WorkServiceAttachedWorkControllerError.sourceIncomplete }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
    }
}
