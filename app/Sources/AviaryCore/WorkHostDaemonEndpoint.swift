import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum WorkHostDaemonEndpointLimits {
    public static let maximumDescriptorBytes = 16 * 1024
    public static let maximumIdentityBytes = 256
    public static let maximumUnixSocketPathBytes = 103
}

public enum WorkHostDaemonEndpointError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentity(String)
    case invalidEndpoint
    case invalidDescriptor
    case descriptorTooLarge
    case accessDenied
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity(let field):
            return "Invalid Work Host daemon \(field)."
        case .invalidEndpoint:
            return "Invalid Work Host daemon endpoint."
        case .invalidDescriptor:
            return "Invalid Work Host daemon descriptor."
        case .descriptorTooLarge:
            return "Work Host daemon descriptor exceeds its size bound."
        case .accessDenied:
            return "Work Host daemon endpoint storage is not privately owned."
        case .ioFailure(let operation):
            return "Work Host daemon endpoint \(operation) failed."
        }
    }
}

/// A discovery hint for one running Work Host process.
///
/// The file containing this value can survive a crash and a PID can be reused. Neither proves
/// liveness: a client must connect and require an exact ``WorkServiceHandshakeResponse`` for the
/// recorded host instance before it treats the process as reachable.
public struct WorkHostDaemonDescriptor: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let workServiceProtocolVersion: Int
    public let hostInstance: WorkHostInstanceRef
    public let endpoint: WorkServiceTransportEndpoint
    public let processID: Int32
    public let publishedAt: Date
    public let isLivenessProof: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workServiceProtocolVersion, hostInstance, endpoint, processID
        case publishedAt, isLivenessProof
    }

    public init(
        hostInstance: WorkHostInstanceRef,
        endpoint: WorkServiceTransportEndpoint,
        processID: Int32,
        publishedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.workServiceProtocolVersion = WorkServiceProtocol.currentVersion
        self.hostInstance = hostInstance
        self.endpoint = endpoint
        self.processID = processID
        self.publishedAt = publishedAt
        self.isLivenessProof = false
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        workServiceProtocolVersion = try values.decode(
            Int.self, forKey: .workServiceProtocolVersion)
        hostInstance = try values.decode(WorkHostInstanceRef.self, forKey: .hostInstance)
        endpoint = try values.decode(WorkServiceTransportEndpoint.self, forKey: .endpoint)
        processID = try values.decode(Int32.self, forKey: .processID)
        publishedAt = try values.decode(Date.self, forKey: .publishedAt)
        // Persisted endpoint material can never upgrade itself into liveness evidence.
        _ = try values.decodeIfPresent(Bool.self, forKey: .isLivenessProof)
        isLivenessProof = false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(workServiceProtocolVersion, forKey: .workServiceProtocolVersion)
        try values.encode(hostInstance, forKey: .hostInstance)
        try values.encode(endpoint, forKey: .endpoint)
        try values.encode(processID, forKey: .processID)
        try values.encode(publishedAt, forKey: .publishedAt)
        try values.encode(false, forKey: .isLivenessProof)
    }

    public func validate(expectedHost: WorkHostRef? = nil) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              workServiceProtocolVersion == WorkServiceProtocol.currentVersion,
              processID > 0,
              !isLivenessProof else {
            throw WorkHostDaemonEndpointError.invalidDescriptor
        }
        let identities = [
            hostInstance.host.workHostID,
            hostInstance.instanceID,
            hostInstance.startIdentity,
        ]
        guard identities.allSatisfy(Self.validIdentity) else {
            throw WorkHostDaemonEndpointError.invalidIdentity("identity")
        }
        if let expectedHost, hostInstance.host != expectedHost {
            throw WorkHostDaemonEndpointError.invalidIdentity("authority")
        }
        let endpointBytes = endpoint.path.utf8.count
        guard endpoint.path.hasPrefix("/"), endpointBytes > 0,
              endpointBytes <= WorkHostDaemonEndpointLimits.maximumUnixSocketPathBytes,
              !endpoint.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkHostDaemonEndpointError.invalidEndpoint
        }
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= WorkHostDaemonEndpointLimits.maximumIdentityBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

/// Stable descriptor storage plus a short, process-generation-specific Unix socket address.
/// The endpoint itself lives outside AgentHome so an arbitrarily long test or remote-mount path
/// cannot exceed Darwin's 104-byte `sockaddr_un.sun_path` field.
public struct WorkHostDaemonEndpointLayout: Hashable, Sendable {
    public let home: AgentHome
    public let workHost: WorkHostRef
    public let socketRoot: URL

    public init(
        home: AgentHome,
        workHost: WorkHostRef,
        socketRoot: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(
                path: "aviary-work-host-\(geteuid())",
                directoryHint: .isDirectory)
    ) {
        self.home = home
        self.workHost = workHost
        self.socketRoot = socketRoot
    }

    public var descriptorDirectory: URL {
        home.timelineV2WorkHostsDir
            .appending(
                path: AgentHome.timelineV2PathComponent(workHost.workHostID),
                directoryHint: .isDirectory)
            .appending(path: "service", directoryHint: .isDirectory)
    }

    public var descriptorURL: URL {
        descriptorDirectory.appending(path: "endpoint.json", directoryHint: .notDirectory)
    }

    public func endpoint(for hostInstance: WorkHostInstanceRef) throws
        -> WorkServiceTransportEndpoint
    {
        guard hostInstance.host == workHost else {
            throw WorkHostDaemonEndpointError.invalidIdentity("host instance")
        }
        try Self.preparePrivateDirectory(socketRoot)
        let material = home.root.standardizedFileURL.path + "\u{0}"
            + workHost.workHostID + "\u{0}" + hostInstance.instanceID + "\u{0}"
            + hostInstance.startIdentity
        let digest = AviarySHA256.hash(data: Data(material.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let path = socketRoot.appending(
            path: "ws-\(digest).sock", directoryHint: .notDirectory).path
        guard path.utf8.count <= WorkHostDaemonEndpointLimits.maximumUnixSocketPathBytes else {
            throw WorkHostDaemonEndpointError.invalidEndpoint
        }
        return WorkServiceTransportEndpoint(path: path)
    }

    fileprivate static func preparePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw WorkHostDaemonEndpointError.ioFailure("directory creation")
        }
        var information = stat()
        guard lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFDIR,
              information.st_uid == geteuid() else {
            throw WorkHostDaemonEndpointError.accessDenied
        }
        // Never "repair" an arbitrary caller-supplied directory. In particular, a mistaken
        // socketRoot of `/tmp` must fail rather than chmod a shared system directory. The daemon
        // only accepts a directory that was created private or was already private.
        guard information.st_mode & mode_t(0o077) == 0 else {
            throw WorkHostDaemonEndpointError.accessDenied
        }
    }
}

/// Atomically publishes and generation-checks the local endpoint hint.
///
/// The Work Host's continuously held control-journal writer lock is the single-owner boundary.
/// This publisher deliberately does not create a second lease protocol; it only ensures an older
/// generation cannot delete a newer generation's descriptor during shutdown.
public struct WorkHostDaemonEndpointPublisher: Sendable {
    public let layout: WorkHostDaemonEndpointLayout
    public let descriptor: WorkHostDaemonDescriptor

    public init(layout: WorkHostDaemonEndpointLayout, descriptor: WorkHostDaemonDescriptor) throws {
        guard descriptor.hostInstance.host == layout.workHost else {
            throw WorkHostDaemonEndpointError.invalidIdentity("descriptor authority")
        }
        try descriptor.validate(expectedHost: layout.workHost)
        self.layout = layout
        self.descriptor = descriptor
    }

    public func publish() throws {
        try WorkHostDaemonEndpointLayout.preparePrivateDirectory(layout.descriptorDirectory)
        try Self.withPublicationLock(in: layout.descriptorDirectory) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(descriptor)
            guard data.count <= WorkHostDaemonEndpointLimits.maximumDescriptorBytes else {
                throw WorkHostDaemonEndpointError.descriptorTooLarge
            }
            let temporary = layout.descriptorDirectory.appending(
                path: ".endpoint-\(AviarySecureRandom.uuidString()).tmp",
                directoryHint: .notDirectory)
            let descriptorFD = temporary.path.withCString {
                open(
                    $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600))
            }
            guard descriptorFD >= 0 else {
                throw WorkHostDaemonEndpointError.ioFailure("temporary-file open")
            }
            defer {
                close(descriptorFD)
                _ = unlink(temporary.path)
            }
            try Self.writeAll(data, to: descriptorFD)
            guard fsync(descriptorFD) == 0 else {
                throw WorkHostDaemonEndpointError.ioFailure("file synchronization")
            }
            guard temporary.path.withCString({ source in
                layout.descriptorURL.path.withCString { destination in
                    rename(source, destination)
                }
            }) == 0 else {
                throw WorkHostDaemonEndpointError.ioFailure("publication")
            }
            try Self.synchronizeDirectory(layout.descriptorDirectory)
        }
    }

    /// Remove only the exact generation this publisher wrote. A stale shutdown never removes a
    /// replacement daemon's descriptor.
    public func removeIfOwned() throws {
        try WorkHostDaemonEndpointLayout.preparePrivateDirectory(layout.descriptorDirectory)
        try Self.withPublicationLock(in: layout.descriptorDirectory) {
            let current: WorkHostDaemonDescriptor?
            do {
                current = try Self.discover(layout: layout)
            } catch WorkHostDaemonEndpointError.invalidDescriptor,
                    WorkHostDaemonEndpointError.descriptorTooLarge {
                return
            }
            guard current == descriptor else { return }
            if unlink(layout.descriptorURL.path) != 0, errno != ENOENT {
                throw WorkHostDaemonEndpointError.ioFailure("removal")
            }
            try Self.synchronizeDirectory(layout.descriptorDirectory)
        }
    }

    public static func discover(
        layout: WorkHostDaemonEndpointLayout
    ) throws -> WorkHostDaemonDescriptor? {
        var directoryInformation = stat()
        guard lstat(layout.descriptorDirectory.path, &directoryInformation) == 0 else {
            if errno == ENOENT { return nil }
            throw WorkHostDaemonEndpointError.ioFailure("directory read")
        }
        guard (directoryInformation.st_mode & S_IFMT) == S_IFDIR,
              directoryInformation.st_uid == geteuid(),
              directoryInformation.st_mode & mode_t(0o077) == 0 else {
            throw WorkHostDaemonEndpointError.accessDenied
        }
        let fd = layout.descriptorURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == EACCES || errno == ELOOP {
                throw WorkHostDaemonEndpointError.accessDenied
            }
            throw WorkHostDaemonEndpointError.ioFailure("read")
        }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0, (information.st_mode & S_IFMT) == S_IFREG else {
            throw WorkHostDaemonEndpointError.invalidDescriptor
        }
        guard information.st_uid == geteuid(), information.st_mode & mode_t(0o077) == 0 else {
            throw WorkHostDaemonEndpointError.accessDenied
        }
        guard information.st_size >= 0,
              information.st_size <= WorkHostDaemonEndpointLimits.maximumDescriptorBytes else {
            throw WorkHostDaemonEndpointError.descriptorTooLarge
        }
        let data = try readBounded(fd)
        let decoded: WorkHostDaemonDescriptor
        do {
            decoded = try JSONDecoder().decode(WorkHostDaemonDescriptor.self, from: data)
        } catch {
            throw WorkHostDaemonEndpointError.invalidDescriptor
        }
        try decoded.validate(expectedHost: layout.workHost)
        return decoded
    }

    private static func readBounded(_ fd: Int32) throws -> Data {
        let limit = WorkHostDaemonEndpointLimits.maximumDescriptorBytes
        var result = Data()
        result.reserveCapacity(min(limit, 4_096))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard result.count <= limit - count else {
                    throw WorkHostDaemonEndpointError.descriptorTooLarge
                }
                result.append(buffer, count: count)
                continue
            }
            if count == 0 { return result }
            if errno == EINTR { continue }
            throw WorkHostDaemonEndpointError.ioFailure("read")
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw WorkHostDaemonEndpointError.ioFailure("write")
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let fd = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw WorkHostDaemonEndpointError.ioFailure("directory open")
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw WorkHostDaemonEndpointError.ioFailure("directory synchronization")
        }
    }

    /// Serialize publication and conditional removal independently of the daemon's broader
    /// control-journal ownership. This closes the read/compare/unlink race: once an old
    /// generation has compared the descriptor, a replacement cannot publish until the old
    /// generation either removes its own record or observes that it no longer owns it.
    private static func withPublicationLock<T>(
        in directory: URL,
        _ body: () throws -> T
    ) throws -> T {
        let lockURL = directory.appending(path: ".endpoint.lock", directoryHint: .notDirectory)
        let fd = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else {
            throw WorkHostDaemonEndpointError.ioFailure("publication lock")
        }
        defer { close(fd) }
        var information = stat()
        guard fstat(fd, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o077) == 0 else {
            throw WorkHostDaemonEndpointError.accessDenied
        }
        return try body()
    }
}
