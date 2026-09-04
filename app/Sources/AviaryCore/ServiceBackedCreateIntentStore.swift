import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// GUI-local durability for the Work-service Create boundary.
///
/// Create is idempotent only when the exact client/command/configuration/cursor tuple is
/// replayed. Retaining that tuple before opening the transport means a GUI crash or a lost
/// response cannot silently mint a second Work on the next launch. This is an Aviary-owned
/// intent record, not a Work projection; the host remains the authority for whether the
/// command was accepted.
public struct ServiceBackedCreateIntentStore: Sendable {
    public static let maximumRecordBytes = 64 * 1_024
    public static let maximumPendingRecords = 32

    public struct Pending: Hashable, Sendable {
        public let request: WorkServiceCreateWorkRequest
        public let initialStart: InitialStart?
    }

    public struct InitialStart: Codable, Hashable, Sendable {
        public let commandID: String
        public let prompt: String

        public init(commandID: String, prompt: String) throws {
            guard !commandID.isEmpty,
                  commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
                  !commandID.unicodeScalars.contains(where: { $0.value == 0 }),
                  prompt.utf8.count <= WorkServiceBounds.maxCommandValueCharacters else {
                throw LocalCreateIntentError.tooLarge
            }
            self.commandID = commandID
            self.prompt = prompt
        }
    }

    private struct Record: Codable, Hashable, Sendable {
        static let schemaVersion = 2
        let schemaVersion: Int
        let request: WorkServiceCreateWorkRequest
        let initialStart: InitialStart?

        init(request: WorkServiceCreateWorkRequest, initialStart: InitialStart?) {
            self.schemaVersion = Self.schemaVersion
            self.request = request
            self.initialStart = initialStart
        }
    }

    public let directory: URL
    private let clientID: String
    private let homeRoot: URL

    public init(home: AgentHome, client: ClientRef) throws {
        self.clientID = client.clientID
        self.homeRoot = home.root
        let digest = AviarySHA256.hash(data: Data(client.clientID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.directory = home.root
            .appending(path: "work-service-clients", directoryHint: .isDirectory)
            .appending(path: "create-intents", directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
        try prepareDirectory()
    }

    public func load() throws -> [WorkServiceCreateWorkRequest] {
        try loadPending().map(\.request)
    }

    /// Load the Create transaction together with the exact first Start seed. Keeping this seed
    /// beside Create closes the crash window between host admission and creation of the attached
    /// controller: a relaunch can still recover the user's original prompt and command identity.
    public func loadPending() throws -> [Pending] {
        try prepareDirectory()
        return try withLock {
            var urls: [URL] = []
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else {
                throw LocalCreateIntentError.corrupt
            }
            var enumeratedCount = 0
            while let value = enumerator.nextObject() as? URL {
                enumeratedCount += 1
                guard enumeratedCount <= Self.maximumPendingRecords else {
                    throw LocalCreateIntentError.corrupt
                }
                let resources = try value.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard resources.isDirectory != true else { throw LocalCreateIntentError.corrupt }
                if value.pathExtension == "json" { urls.append(value) }
            }
            guard urls.count <= Self.maximumPendingRecords else {
                throw LocalCreateIntentError.corrupt
            }
            return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { record in
                let decoded = try readRecord(record)
                return Pending(request: decoded.request, initialStart: decoded.initialStart)
            }
        }
    }

    public func retain(
        _ request: WorkServiceCreateWorkRequest,
        initialStart: InitialStart? = nil
    ) throws {
        try prepareDirectory()
        try withLock {
            guard request.client == ClientRef(clientID) else {
                throw LocalCreateIntentError.corrupt
            }
            let destination = url(for: request.commandID)
            var destinationInformation = stat()
            if lstat(destination.path, &destinationInformation) == 0 {
                let existing = try readRecord(destination)
                guard existing.request == request, existing.initialStart == initialStart else {
                    throw LocalCreateIntentError.conflict
                }
                return
            } else if errno != ENOENT {
                throw LocalCreateIntentError.corrupt
            }
            let data = try encoded(Record(request: request, initialStart: initialStart))
            guard data.count <= Self.maximumRecordBytes else {
                throw LocalCreateIntentError.tooLarge
            }
            try atomicallyWrite(data, to: destination)
        }
    }

    public func clear(_ request: WorkServiceCreateWorkRequest) throws {
        try prepareDirectory()
        try withLock {
            let destination = url(for: request.commandID)
            var information = stat()
            guard lstat(destination.path, &information) == 0 else {
                if errno == ENOENT { return }
                throw LocalCreateIntentError.corrupt
            }
            let existing = try readRecord(destination)
            guard existing.request == request else { throw LocalCreateIntentError.conflict }
            guard unlink(destination.path) == 0 else { throw LocalCreateIntentError.corrupt }
            try synchronizeDirectory()
        }
    }

    private func url(for commandID: String) -> URL {
        let digest = AviarySHA256.hash(data: Data(commandID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json", directoryHint: .notDirectory)
    }

    private func encoded(_ record: Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private func readRecord(_ recordURL: URL) throws -> Record {
        let fd = recordURL.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw LocalCreateIntentError.corrupt }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o777)) == mode_t(0o600),
              information.st_size >= 0,
              information.st_size <= off_t(Self.maximumRecordBytes) else {
            throw LocalCreateIntentError.corrupt
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= Self.maximumRecordBytes - count else {
                    throw LocalCreateIntentError.corrupt
                }
                data.append(buffer, count: count)
            } else if count == 0 { break
            } else if errno != EINTR { throw LocalCreateIntentError.corrupt }
        }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schemaVersion == Record.schemaVersion,
              record.request.client == ClientRef(clientID),
              !record.request.commandID.isEmpty,
              record.request.commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters,
              !record.request.commandID.unicodeScalars.contains(where: { $0.value == 0 }),
              record.initialStart.map({
                  !$0.commandID.isEmpty
                      && $0.commandID.utf8.count <= WorkServiceBounds.maxIdentityCharacters
                      && !$0.commandID.unicodeScalars.contains(where: { $0.value == 0 })
                      && $0.prompt.utf8.count <= WorkServiceBounds.maxCommandValueCharacters
              }) ?? true,
              recordURL.lastPathComponent == url(for: record.request.commandID).lastPathComponent else {
            throw LocalCreateIntentError.corrupt
        }
        return record
    }

    private func prepareDirectory() throws {
        let workClients = homeRoot.appending(
            path: "work-service-clients", directoryHint: .isDirectory)
        let createIntents = workClients.appending(
            path: "create-intents", directoryHint: .isDirectory)
        for (index, candidate) in [homeRoot, workClients, createIntents, directory].enumerated() {
            var information = stat()
            if lstat(candidate.path, &information) == 0 {
                guard (information.st_mode & S_IFMT) == S_IFDIR,
                      information.st_uid == geteuid(),
                      (information.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                    throw LocalCreateIntentError.corrupt
                }
            } else {
                guard errno == ENOENT else { throw LocalCreateIntentError.corrupt }
                do {
                    try FileManager.default.createDirectory(
                        at: candidate, withIntermediateDirectories: index == 0,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
                } catch {
                    throw LocalCreateIntentError.corrupt
                }
                guard lstat(candidate.path, &information) == 0,
                      (information.st_mode & S_IFMT) == S_IFDIR,
                      information.st_uid == geteuid(),
                      (information.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                    throw LocalCreateIntentError.corrupt
                }
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = directory.appending(path: ".store.lock", directoryHint: .notDirectory)
        let fd = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else { throw LocalCreateIntentError.corrupt }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              (information.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw LocalCreateIntentError.corrupt
        }
        return try body()
    }

    private func atomicallyWrite(_ data: Data, to destination: URL) throws {
        let temporary = directory.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory)
        defer { _ = unlink(temporary.path) }
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw LocalCreateIntentError.corrupt }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw LocalCreateIntentError.corrupt }
                }
            }
            guard fsync(fd) == 0 else { throw LocalCreateIntentError.corrupt }
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        var information = stat()
        if lstat(destination.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) == S_IFREG,
                  information.st_uid == geteuid(),
                  (information.st_mode & mode_t(0o777)) == mode_t(0o600) else {
                throw LocalCreateIntentError.corrupt
            }
        } else if errno != ENOENT { throw LocalCreateIntentError.corrupt }
        guard rename(temporary.path, destination.path) == 0 else {
            throw LocalCreateIntentError.corrupt
        }
        try synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let fd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw LocalCreateIntentError.corrupt }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw LocalCreateIntentError.corrupt }
    }
}

public enum LocalCreateIntentError: Error, Equatable, Sendable {
    case conflict
    case corrupt
    case tooLarge
}
