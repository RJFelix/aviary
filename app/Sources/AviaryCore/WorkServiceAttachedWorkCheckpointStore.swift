import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol WorkServiceAttachedWorkCheckpointStoring: Sendable {
    func load() throws -> WorkServiceAttachedWorkCheckpointStore.Record?
    func save(_ record: WorkServiceAttachedWorkCheckpointStore.Record) throws
}

/// Durable reducer truth for one exact GUI attachment.
///
/// A read acknowledgement is only a host-side progress fact.  It is never sufficient to skip
/// journal history on a cold start.  This record therefore stores the serialized reducer
/// snapshots and their exact cursors together with the attachment/journal generation that made
/// them meaningful.  A checkpoint with a mismatched identity, an invalid cursor, or an
/// unreconstructable reducer state is ignored by the controller and the next read starts at zero.
public struct WorkServiceAttachedWorkCheckpointStore: Sendable, Hashable,
    WorkServiceAttachedWorkCheckpointStoring {
    public static let maximumRecordBytes = 32 * 1_024 * 1_024

    /// A checkpoint is a cache, but a torn or partially overwritten cache must never be
    /// mistaken for reducer truth.  The checksum covers the canonical JSON encoding of the
    /// record (without this envelope), not the filesystem path or write timestamp.
    private struct DiskEnvelope: Codable {
        let schemaVersion: Int
        let record: Record
        let recordChecksum: String

        static let currentSchemaVersion = 1
    }

    public struct PendingAcknowledgement: Codable, Hashable, Sendable {
        public let request: WorkServiceAcknowledgeReadRequest
        public let stale: Bool

        public init(
            request: WorkServiceAcknowledgeReadRequest,
            stale: Bool = false
        ) {
            self.request = request
            self.stale = stale
        }
    }

    public struct Record: Codable, Hashable, Sendable {
        public static let currentSchemaVersion = 3

        public let schemaVersion: Int
        public let client: ClientRef
        public let work: WorkRef
        public let journal: JournalRef
        public let session: SessionRef
        public let sessionJournal: JournalRef
        public let sessionAttachment: SessionAttachmentRef
        public let attachment: ClientAttachmentRef
        /// Informational observation only. It is not part of checkpoint identity because a
        /// daemon restart may mint a new live instance while preserving journal history.
        public let hostInstance: WorkHostInstanceRef?
        public let descriptor: WorkServiceWorkDescriptor
        public let attachmentProjection: WorkServiceClientAttachment
        public let controlCursor: JournalCursor?
        public let committedWorkCursor: JournalCursor
        public let committedWorkPrefixDigest: String?
        /// A compact checkpoint intentionally omits reducer snapshots.  It remains useful for
        /// retaining exact idempotent acknowledgements and the service-issued prefix proof, but
        /// it can never be used to skip journal history; the controller falls back to replay.
        public let committedWorkSnapshot: WorkSnapshot?
        public let committedSessionCursor: JournalCursor
        public let committedSessionPrefixDigest: String?
        public let committedSessionSnapshot: SessionSnapshot?
        public let stagedWorkCursor: JournalCursor?
        public let stagedWorkPrefixDigest: String?
        public let stagedWorkSnapshot: WorkSnapshot?
        public let stagedWorkOmissions: [WorkServiceOmission]
        public let stagedSessionCursor: JournalCursor?
        public let stagedSessionPrefixDigest: String?
        public let stagedSessionSnapshot: SessionSnapshot?
        public let stagedSessionOmissions: [WorkServiceOmission]
        public let pendingAcknowledgements: [PendingAcknowledgement]

        public init(
            client: ClientRef,
            work: WorkRef,
            journal: JournalRef,
            session: SessionRef,
            sessionJournal: JournalRef,
            sessionAttachment: SessionAttachmentRef,
            attachment: ClientAttachmentRef,
            hostInstance: WorkHostInstanceRef?,
            descriptor: WorkServiceWorkDescriptor,
            attachmentProjection: WorkServiceClientAttachment,
            controlCursor: JournalCursor?,
            committedWorkCursor: JournalCursor,
            committedWorkPrefixDigest: String?,
            committedWorkSnapshot: WorkSnapshot?,
            committedSessionCursor: JournalCursor,
            committedSessionPrefixDigest: String?,
            committedSessionSnapshot: SessionSnapshot?,
            stagedWorkCursor: JournalCursor?,
            stagedWorkPrefixDigest: String?,
            stagedWorkSnapshot: WorkSnapshot?,
            stagedWorkOmissions: [WorkServiceOmission],
            stagedSessionCursor: JournalCursor?,
            stagedSessionPrefixDigest: String?,
            stagedSessionSnapshot: SessionSnapshot?,
            stagedSessionOmissions: [WorkServiceOmission],
            pendingAcknowledgements: [PendingAcknowledgement]
        ) {
            self.schemaVersion = Self.currentSchemaVersion
            self.client = client
            self.work = work
            self.journal = journal
            self.session = session
            self.sessionJournal = sessionJournal
            self.sessionAttachment = sessionAttachment
            self.attachment = attachment
            self.hostInstance = hostInstance
            self.descriptor = descriptor
            self.attachmentProjection = attachmentProjection
            self.controlCursor = controlCursor
            self.committedWorkCursor = committedWorkCursor
            self.committedWorkPrefixDigest = committedWorkPrefixDigest
            self.committedWorkSnapshot = committedWorkSnapshot
            self.committedSessionCursor = committedSessionCursor
            self.committedSessionPrefixDigest = committedSessionPrefixDigest
            self.committedSessionSnapshot = committedSessionSnapshot
            self.stagedWorkCursor = stagedWorkCursor
            self.stagedWorkPrefixDigest = stagedWorkPrefixDigest
            self.stagedWorkSnapshot = stagedWorkSnapshot
            self.stagedWorkOmissions = Array(stagedWorkOmissions.prefix(WorkServiceBounds.maxOmissions))
            self.stagedSessionCursor = stagedSessionCursor
            self.stagedSessionPrefixDigest = stagedSessionPrefixDigest
            self.stagedSessionSnapshot = stagedSessionSnapshot
            self.stagedSessionOmissions = Array(stagedSessionOmissions.prefix(WorkServiceBounds.maxOmissions))
            self.pendingAcknowledgements = Array(pendingAcknowledgements.prefix(
                WorkServiceBounds.maxReadAcknowledgementsPerAttachment))
        }

        /// Remove reducer state that cannot be bounded without losing canonical transcript data.
        /// Cursors/digests and pending idempotent requests remain durable evidence, but the next
        /// process must reconstruct the reducer from the journal rather than trusting this record
        /// as a snapshot.
        public func withoutReducerSnapshots() -> Record {
            Record(
                client: client, work: work, journal: journal, session: session,
                sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
                attachment: attachment, hostInstance: hostInstance, descriptor: descriptor,
                attachmentProjection: attachmentProjection, controlCursor: controlCursor,
                committedWorkCursor: committedWorkCursor,
                committedWorkPrefixDigest: committedWorkPrefixDigest,
                committedWorkSnapshot: nil, committedSessionCursor: committedSessionCursor,
                committedSessionPrefixDigest: committedSessionPrefixDigest,
                committedSessionSnapshot: nil,
                stagedWorkCursor: nil, stagedWorkPrefixDigest: nil, stagedWorkSnapshot: nil,
                stagedWorkOmissions: [], stagedSessionCursor: nil,
                stagedSessionPrefixDigest: nil, stagedSessionSnapshot: nil,
                stagedSessionOmissions: [], pendingAcknowledgements: pendingAcknowledgements)
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

    public func load() throws -> Record? {
        try prepareDirectory()
        return try withLock { try readLocked() }
    }

    public func save(_ record: Record) throws {
        try prepareDirectory()
        try withLock { try writeLocked(Self.boundedRecord(record)) }
    }

    public func clear() throws {
        try prepareDirectory()
        try withLock {
            guard unlink(url.path) == 0 else {
                if errno == ENOENT { return }
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
        var buffer = [UInt8](repeating: 0, count: 8_192)
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
        do {
            let envelope = try JSONDecoder().decode(DiskEnvelope.self, from: data)
            guard envelope.schemaVersion == DiskEnvelope.currentSchemaVersion,
                  envelope.record.schemaVersion == Record.currentSchemaVersion,
                  envelope.recordChecksum == Self.recordChecksum(envelope.record) else {
                throw WorkServiceAttachedWorkControllerError.sourceIncomplete
            }
            return envelope.record
        } catch let error as WorkServiceAttachedWorkControllerError {
            throw error
        } catch {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
    }

    private func writeLocked(_ record: Record) throws {
        let data: Data
        do {
            let envelope = DiskEnvelope(
                schemaVersion: DiskEnvelope.currentSchemaVersion,
                record: record,
                recordChecksum: Self.recordChecksum(record))
            data = try Self.canonicalJSON(envelope)
        } catch {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw WorkServiceAttachedWorkControllerError.sourceIncomplete
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
        var information = stat()
        if lstat(url.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) == S_IFREG,
                  information.st_uid == geteuid(),
                  information.st_mode & mode_t(0o077) == 0 else {
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

    /// Keep the on-disk cache bounded even when the reducer's canonical message history is much
    /// larger than the normal record limit.  The compact variant is deliberately not a resumable
    /// reducer checkpoint; it only preserves identity, proof metadata, and pending idempotent
    /// requests so a restart can safely replay the source and reconcile acknowledgements.
    public static func boundedRecord(_ record: Record) -> Record {
        let envelope = DiskEnvelope(
            schemaVersion: DiskEnvelope.currentSchemaVersion,
            record: record,
            recordChecksum: recordChecksum(record))
        guard let data = try? canonicalJSON(envelope), data.count > maximumRecordBytes else {
            return record
        }
        return record.withoutReducerSnapshots()
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
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o077) == 0 else {
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

    /// Encode a value through a small canonical JSON pass. `JSONEncoder.sortedKeys` only sorts
    /// dictionary keys; Swift `Set` values are still emitted in process-random order. A
    /// checkpoint crosses process boundaries, so normalize the known set-like arrays before
    /// hashing/writing while preserving order-sensitive journal, message, and reducer arrays.
    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let normalized = canonicalJSONObject(object, key: nil)
        return try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
    }

    private static let unorderedArrayKeys: Set<String> = [
        "requested", "granted", "denied", "capabilities",
        "attachedSessionIDs", "observedRunIDs", "activeActionIDs",
        "unknownDomains", "seenEventIDs", "declaredDomains", "affectedDomains",
        "readAcknowledgements", "pendingAcknowledgements", "attachments",
    ]

    private static func canonicalJSONObject(_ value: Any, key: String?) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = canonicalJSONObject(entry.value, key: entry.key)
            }
        }
        if let array = value as? [Any] {
            let normalized = array.map { canonicalJSONObject($0, key: key) }
            guard let key, unorderedArrayKeys.contains(key) else { return normalized }
            return normalized.sorted {
                canonicalJSONFragment($0) < canonicalJSONFragment($1)
            }
        }
        return value
    }

    private static func canonicalJSONFragment(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func recordChecksum(_ record: Record) -> String {
        // Record is intentionally Codable and its keys are all bounded.  The sorted-key
        // encoding makes this checksum deterministic across process restarts and dictionary
        // iteration order.  Encoding failure is impossible for these value types; return a
        // value that can never validate if a future field breaks that invariant.
        guard let data = try? canonicalJSON(record) else { return "sha256:" + String(repeating: "0", count: 64) }
        return "sha256:" + AviarySHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
