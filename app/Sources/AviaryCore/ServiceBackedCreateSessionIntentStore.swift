import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct ServiceBackedCreateSessionIntentCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private enum ServiceBackedCreateSessionRequestCodingKey: String, CodingKey, CaseIterable {
    case work
    case journal
    case attachment
    case client
    case commandID
    case causalControlCursor
    case causalWorkCursor
    case requestedCapabilities
}

/// GUI-local durability for the Work-service Create Session boundary.
///
/// The Work Host owns all newly-created identities, so an indeterminate response can only be
/// reconciled by replaying this exact request. Persisting it before transport prevents a GUI
/// restart from inventing a second command and therefore a second Session.
public struct ServiceBackedCreateSessionIntentStore: Sendable {
    public static let maximumRecordBytes = 64 * 1_024
    public static let maximumPendingRecords = 32

    private struct Record: Codable, Hashable, Sendable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let request: WorkServiceCreateSessionRequest

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, request
        }

        init(request: WorkServiceCreateSessionRequest) {
            schemaVersion = Self.schemaVersion
            self.request = request
        }

        init(from decoder: Decoder) throws {
            let dynamic = try decoder.container(
                keyedBy: ServiceBackedCreateSessionIntentCodingKey.self)
            guard Set(dynamic.allKeys.map(\.stringValue))
                == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Create Session intent fields must match its version"))
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(Int.self, forKey: .schemaVersion)
                == Self.schemaVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion, in: container,
                    debugDescription: "unsupported Create Session intent schema")
            }
            schemaVersion = Self.schemaVersion
            let requestDecoder = try container.superDecoder(forKey: .request)
            let requestDynamic = try requestDecoder.container(
                keyedBy: ServiceBackedCreateSessionIntentCodingKey.self)
            guard Set(requestDynamic.allKeys.map(\.stringValue))
                == Set(ServiceBackedCreateSessionRequestCodingKey.allCases.map(\.rawValue)) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: requestDecoder.codingPath,
                    debugDescription: "Create Session request fields must match its version"))
            }
            let requestContainer = try requestDecoder.container(
                keyedBy: ServiceBackedCreateSessionRequestCodingKey.self)
            request = WorkServiceCreateSessionRequest(
                work: try requestContainer.decode(WorkRef.self, forKey: .work),
                journal: try requestContainer.decode(JournalRef.self, forKey: .journal),
                attachment: try requestContainer.decode(
                    ClientAttachmentRef.self, forKey: .attachment),
                client: try requestContainer.decode(ClientRef.self, forKey: .client),
                commandID: try requestContainer.decode(String.self, forKey: .commandID),
                causalControlCursor: try requestContainer.decode(
                    JournalCursor.self, forKey: .causalControlCursor),
                causalWorkCursor: try requestContainer.decode(
                    JournalCursor.self, forKey: .causalWorkCursor),
                requestedCapabilities: try requestContainer.decode(
                    Set<WorkServiceCapability>.self, forKey: .requestedCapabilities))
        }
    }

    public let directory: URL
    private let client: ClientRef
    private let host: WorkHostRef
    private let homeRoot: URL

    public init(home: AgentHome, client: ClientRef, host: WorkHostRef) throws {
        guard Self.validIdentity(client.clientID),
              Self.validIdentity(host.workHostID) else {
            throw LocalCreateIntentError.corrupt
        }
        self.client = client
        self.host = host
        self.homeRoot = home.root
        let clientDigest = AviarySHA256.hash(data: Data(client.clientID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let hostDigest = AviarySHA256.hash(data: Data(host.workHostID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.directory = home.root
            .appending(path: "work-service-clients", directoryHint: .isDirectory)
            .appending(path: "create-session-intents", directoryHint: .isDirectory)
            .appending(path: clientDigest, directoryHint: .isDirectory)
            .appending(path: hostDigest, directoryHint: .isDirectory)
        try prepareDirectory()
    }

    public func load() throws -> [WorkServiceCreateSessionRequest] {
        try prepareDirectory()
        return try withLock {
            return try recordURLsLocked().sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }.map { try readRecord($0).request }
        }
    }

    public func retain(_ request: WorkServiceCreateSessionRequest) throws {
        try validate(request)
        try prepareDirectory()
        try withLock {
            let destination = url(for: request)
            var information = stat()
            if lstat(destination.path, &information) == 0 {
                guard try readRecord(destination).request == request else {
                    throw LocalCreateIntentError.conflict
                }
                return
            } else if errno != ENOENT {
                throw LocalCreateIntentError.corrupt
            }
            // Enforce the bound before publishing the next durable record. Letting record 33
            // land and relying on `load` to reject it would make every earlier intent
            // unrecoverable until somebody edited the directory by hand.
            guard try recordURLsLocked().count < Self.maximumPendingRecords else {
                throw LocalCreateIntentError.tooLarge
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Record(request: request))
            guard data.count <= Self.maximumRecordBytes else {
                throw LocalCreateIntentError.tooLarge
            }
            try atomicallyWrite(data, to: destination)
        }
    }

    private func recordURLsLocked() throws -> [URL] {
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
            let resources = try value.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard resources.isDirectory != true,
                  resources.isSymbolicLink != true,
                  value.pathExtension == "json" else {
                throw LocalCreateIntentError.corrupt
            }
            urls.append(value)
        }
        return urls
    }

    public func clear(_ request: WorkServiceCreateSessionRequest) throws {
        try validate(request)
        try prepareDirectory()
        try withLock {
            let destination = url(for: request)
            var information = stat()
            guard lstat(destination.path, &information) == 0 else {
                if errno == ENOENT { return }
                throw LocalCreateIntentError.corrupt
            }
            guard try readRecord(destination).request == request else {
                throw LocalCreateIntentError.conflict
            }
            guard unlink(destination.path) == 0 else {
                throw LocalCreateIntentError.corrupt
            }
            try synchronizeDirectory()
        }
    }

    private func validate(_ request: WorkServiceCreateSessionRequest) throws {
        guard request.client == client,
              request.work.workHostID == host.workHostID,
              Self.validIdentity(request.work.workHostID),
              Self.validIdentity(request.work.workID),
              request.journal.owner == .work(request.work),
              request.journal.authority.authorityID == request.work.workHostID,
              Self.validIdentity(request.journal.journalID),
              Self.validIdentity(request.journal.authority.authorityID),
              Self.validIdentity(request.attachment.attachmentID),
              Self.validIdentity(request.commandID),
              Self.validCursor(
                request.causalControlCursor,
                journal: .workHost(WorkHostRef(request.work.workHostID))),
              Self.validCursor(request.causalWorkCursor, journal: request.journal),
              !request.requestedCapabilities.isEmpty else {
            throw LocalCreateIntentError.corrupt
        }
    }

    private func url(for request: WorkServiceCreateSessionRequest) -> URL {
        let fields = [
            request.work.workHostID, request.work.workID, request.client.clientID,
            request.commandID,
        ]
        let material = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = AviarySHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest + ".json", directoryHint: .notDirectory)
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
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw LocalCreateIntentError.corrupt
            }
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
            try validate(record.request)
        } catch {
            throw LocalCreateIntentError.corrupt
        }
        guard record.schemaVersion == Record.schemaVersion,
              recordURL.lastPathComponent == url(for: record.request).lastPathComponent else {
            throw LocalCreateIntentError.corrupt
        }
        return record
    }

    private func prepareDirectory() throws {
        let clients = homeRoot.appending(
            path: "work-service-clients", directoryHint: .isDirectory)
        let intents = clients.appending(
            path: "create-session-intents", directoryHint: .isDirectory)
        let clientDirectory = directory.deletingLastPathComponent()
        for (index, candidate) in [
            homeRoot, clients, intents, clientDirectory, directory,
        ].enumerated() {
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
        // The store lock admits only one writer, so one fixed staging name is sufficient and
        // bounds crash-left temporary state to one file. A UUID per attempt would let repeated
        // process death accumulate an unbounded hidden directory that normal record enumeration
        // could never repair.
        let temporary = directory.appending(
            path: ".pending-write.tmp",
            directoryHint: .notDirectory)
        var existing = stat()
        if lstat(temporary.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG,
                  existing.st_uid == geteuid(),
                  (existing.st_mode & mode_t(0o777)) == mode_t(0o600),
                  unlink(temporary.path) == 0 else {
                throw LocalCreateIntentError.corrupt
            }
            try synchronizeDirectory()
        } else if errno != ENOENT {
            throw LocalCreateIntentError.corrupt
        }
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

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= WorkServiceBounds.maxIdentityCharacters
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func validCursor(_ cursor: JournalCursor, journal: JournalRef) -> Bool {
        cursor.journal == journal
            && cursor.sequence >= 0
            && cursor.sequence < Int.max
            && (cursor.sequence == 0
                ? cursor.eventID == nil
                : cursor.eventID.map(validIdentity) == true)
    }
}
