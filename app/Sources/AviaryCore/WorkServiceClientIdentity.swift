import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors from the GUI/device identity record. A record which exists but cannot be verified is
/// never replaced: doing so would silently fork the identity used by durable client attachments.
public enum WorkServiceClientIdentityError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case accessDenied
    case invalidRecord
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The Work service client identity location is invalid."
        case .accessDenied: return "The Work service client identity location is not private."
        case .invalidRecord: return "The Work service client identity record is invalid."
        case .ioFailure(let operation): return "The Work service client identity \(operation) failed."
        }
    }
}

/// Durable identity for one GUI/device. The URL is supplied by the application so Core does not
/// invent a platform-specific settings location. The app may use the same record across launches
/// and GUI processes; a remote GUI can use a different durable record without changing the
/// Work-service protocol.
public struct WorkServiceClientIdentityStore: Sendable, Hashable {
    public static let maximumRecordBytes = 128

    public let url: URL

    public init(url: URL) throws {
        guard url.isFileURL, !url.path.isEmpty,
              !url.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkServiceClientIdentityError.invalidURL
        }
        self.url = url
    }

    /// Load the existing identity or atomically create it. Existing malformed, symlinked, or
    /// foreign content is an error rather than an invitation to rotate the durable identity.
    public func loadOrCreate() throws -> ClientRef {
        try preparePrivateDirectory(url.deletingLastPathComponent())
        return try withExclusiveLock {
            switch readState() {
            case .valid(let value): return ClientRef(value)
            case .malformed: throw WorkServiceClientIdentityError.invalidRecord
            case .missing: break
            }

            let value = "client-" + AviarySecureRandom.uuidString()
            let temporary = url.deletingLastPathComponent().appending(
                path: ".\(url.lastPathComponent)-\(AviarySecureRandom.uuidString()).tmp",
                directoryHint: .notDirectory)
            defer { _ = unlink(temporary.path) }
            let fd = temporary.path.withCString {
                open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            }
            guard fd >= 0 else {
                throw WorkServiceClientIdentityError.ioFailure("temporary-file open")
            }
            defer { close(fd) }
            try writeAll(Data((value + "\n").utf8), to: fd)
            guard fsync(fd) == 0 else {
                throw WorkServiceClientIdentityError.ioFailure("synchronization")
            }
            guard temporary.path.withCString({ source in
                url.path.withCString { destination in link(source, destination) }
            }) == 0 else {
                if errno == EEXIST {
                    switch readState() {
                    case .valid(let winner): return ClientRef(winner)
                    case .malformed, .missing: throw WorkServiceClientIdentityError.invalidRecord
                    }
                }
                throw WorkServiceClientIdentityError.ioFailure("publication")
            }
            try synchronizeDirectory(url.deletingLastPathComponent())
            guard case .valid(let persisted) = readState() else {
                throw WorkServiceClientIdentityError.ioFailure("read-back")
            }
            return ClientRef(persisted)
        }
    }

    private enum State { case missing, malformed, valid(String) }

    private func readState() -> State {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            return errno == ENOENT ? .missing : .malformed
        }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o077) == 0,
              information.st_size >= 0,
              information.st_size <= off_t(Self.maximumRecordBytes + 1) else {
            return .malformed
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= Self.maximumRecordBytes + 1 - count else { return .malformed }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return .malformed
            }
        }
        guard let raw = String(data: data, encoding: .utf8) else { return .malformed }
        var value = raw
        if value.hasSuffix("\n") {
            value.removeLast()
            if value.hasSuffix("\r") { value.removeLast() }
        }
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r"),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.valid(value) else { return .malformed }
        return .valid(value)
    }

    private static func valid(_ value: String) -> Bool {
        guard value.utf8.count <= maximumRecordBytes,
              value.hasPrefix("client-") else { return false }
        let suffix = String(value.dropFirst("client-".count))
        return suffix.count == 36 && UUID(uuidString: suffix) != nil
            && suffix == suffix.lowercased()
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = url.deletingLastPathComponent().appending(
            path: ".\(url.lastPathComponent).lock", directoryHint: .notDirectory)
        let fd = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else { throw WorkServiceClientIdentityError.ioFailure("lock") }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(), information.st_mode & mode_t(0o077) == 0 else {
            throw WorkServiceClientIdentityError.accessDenied
        }
        return try body()
    }

    private func preparePrivateDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch { throw WorkServiceClientIdentityError.ioFailure("directory creation") }
        var information = stat()
        guard lstat(directory.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid(), information.st_mode & mode_t(0o077) == 0 else {
            throw WorkServiceClientIdentityError.accessDenied
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let fd = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw WorkServiceClientIdentityError.ioFailure("directory open") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw WorkServiceClientIdentityError.ioFailure("directory synchronization") }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && errno == EINTR { continue }
                else { throw WorkServiceClientIdentityError.ioFailure("write") }
            }
        }
    }
}
