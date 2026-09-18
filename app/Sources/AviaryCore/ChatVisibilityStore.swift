import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A durable identity for a chat's local list presentation.
///
/// These values identify source records, never their visible prompt or title. Pending chats use
/// their saved UUID, native chats use their authority-qualified Session journal, and legacy chats
/// use the catalog's durable session id. A process-local LiveRun UUID is intentionally not a
/// supported identity: hiding a chat must survive relaunch or fail closed at the UI boundary.
public struct ChatVisibilityIdentity: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func pending(_ id: UUID) -> ChatVisibilityIdentity {
        ChatVisibilityIdentity(unchecked: "pending|\(id.uuidString.lowercased())")
    }

    public static func nativeSession(journal: JournalRef) -> ChatVisibilityIdentity {
        ChatVisibilityIdentity(unchecked: "native|\(journal.stableKey)")
    }

    public static func legacySession(id: String) -> ChatVisibilityIdentity? {
        guard !id.isEmpty, id.utf8.count <= maximumComponentBytes,
              !id.contains("\0"), !id.contains("\n"), !id.contains("\r") else {
            return nil
        }
        return ChatVisibilityIdentity(rawValue: "legacy|\(id)")
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    fileprivate static let maximumComponentBytes = 1_024
    fileprivate static let maximumIdentityBytes = 4_096

    fileprivate static func isValid(_ value: String) -> Bool {
        guard value.utf8.count > 0, value.utf8.count <= maximumIdentityBytes,
              !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            return false
        }
        guard let separator = value.firstIndex(of: "|") else { return false }
        let kind = value[..<separator]
        let component = value[value.index(after: separator)...]
        guard !component.isEmpty, component.utf8.count <= maximumComponentBytes else {
            return false
        }
        switch kind {
        case "pending":
            return UUID(uuidString: String(component)) != nil
        case "native", "legacy":
            return true
        default:
            return false
        }
    }
}

public enum ChatVisibilityStoreError: LocalizedError, Equatable, Sendable {
    case malformed(String)
    case unreadable(String)
    case unwritable(String)
    case invalidIdentity
    case capacityExceeded

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason): return "Hidden chat preferences are malformed: \(reason)"
        case .unreadable(let reason): return "Hidden chat preferences could not be read: \(reason)"
        case .unwritable(let reason): return "Hidden chat preferences could not be saved: \(reason)"
        case .invalidIdentity: return "The chat has no valid durable identity, so it was not hidden."
        case .capacityExceeded: return "The hidden chat preference limit was reached."
        }
    }
}

/// GUI-local list presentation state. This store never opens, moves, rewrites, ends, or deletes
/// a Session, Work, transcript, or pending prompt.
public struct ChatVisibilityStore: Sendable {
    public static let maximumHiddenChats = 4_096

    private struct Payload: Codable {
        let version: Int
        let hidden: [String]
    }

    public let fileURL: URL

    private var lockURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("lock")
    }

    private static let maximumPayloadBytes = 8 * 1_024 * 1_024

    public init(home: AgentHome) {
        self.fileURL = home.root.appending(path: "hidden-chats.json", directoryHint: .notDirectory)
    }

    public func load() throws -> Set<ChatVisibilityIdentity> {
        try withAdvisoryLock { try loadUnlocked() }
    }

    private func loadUnlocked() throws -> Set<ChatVisibilityIdentity> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let values = try? fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChatVisibilityStoreError.unreadable("state file is not a regular file")
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            guard let bounded = try handle.read(upToCount: Self.maximumPayloadBytes + 1) else {
                throw ChatVisibilityStoreError.unreadable("state file could not be read")
            }
            guard bounded.count <= Self.maximumPayloadBytes else {
                throw ChatVisibilityStoreError.malformed("state file is too large")
            }
            data = bounded
        } catch let error as ChatVisibilityStoreError {
            throw error
        } catch {
            throw ChatVisibilityStoreError.unreadable("state file could not be read")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ChatVisibilityStoreError.malformed("invalid JSON")
        }
        guard payload.version == 1 else {
            throw ChatVisibilityStoreError.malformed("unsupported version")
        }
        guard payload.hidden.count <= Self.maximumHiddenChats else {
            throw ChatVisibilityStoreError.malformed("too many hidden chat identities")
        }
        var result = Set<ChatVisibilityIdentity>()
        result.reserveCapacity(payload.hidden.count)
        for raw in payload.hidden {
            guard let identity = ChatVisibilityIdentity(rawValue: raw) else {
                throw ChatVisibilityStoreError.malformed("invalid chat identity")
            }
            result.insert(identity)
        }
        return result
    }

    @discardableResult
    public func setHidden(
        _ hidden: Bool, identity: ChatVisibilityIdentity
    ) throws -> Set<ChatVisibilityIdentity> {
        try setHidden(hidden, identities: [identity])
    }

    /// Apply one visibility decision to several source identities under one sidecar lock. The
    /// multi-identity form is required when restoring an associated pending chat: its native
    /// alias and retained pending UUID must disappear together.
    @discardableResult
    public func setHidden(
        _ hidden: Bool, identities: Set<ChatVisibilityIdentity>
    ) throws -> Set<ChatVisibilityIdentity> {
        guard identities.allSatisfy({ ChatVisibilityIdentity.isValid($0.rawValue) }) else {
            throw ChatVisibilityStoreError.invalidIdentity
        }
        return try withAdvisoryLock {
            var current = try loadUnlocked()
            if hidden {
                current.formUnion(identities)
                guard current.count <= Self.maximumHiddenChats else {
                    throw ChatVisibilityStoreError.capacityExceeded
                }
            } else {
                current.subtract(identities)
            }
            try writeUnlocked(current)
            return current
        }
    }

    /// Atomically retires a pending alias after its canonical alias was published. It deliberately
    /// does not re-add the destination: a user may have restored the canonical chat while the
    /// pending card remained visible, and that explicit restore must win.
    @discardableResult
    public func retirePendingAlias(
        _ source: ChatVisibilityIdentity, canonical destination: ChatVisibilityIdentity
    ) throws -> Set<ChatVisibilityIdentity> {
        guard ChatVisibilityIdentity.isValid(source.rawValue),
              ChatVisibilityIdentity.isValid(destination.rawValue) else {
            throw ChatVisibilityStoreError.invalidIdentity
        }
        return try withAdvisoryLock {
            var current = try loadUnlocked()
            guard current.remove(source) != nil else { return current }
            try writeUnlocked(current)
            return current
        }
    }

    /// Adds the canonical alias while retaining the pending identity. This is used before the
    /// pending record publishes its association, so a crash between those two durable writes
    /// cannot make a previously hidden chat visible. Retirement removes the old identity later.
    @discardableResult
    public func aliasHidden(
        from source: ChatVisibilityIdentity, to destination: ChatVisibilityIdentity
    ) throws -> Set<ChatVisibilityIdentity> {
        guard ChatVisibilityIdentity.isValid(source.rawValue),
              ChatVisibilityIdentity.isValid(destination.rawValue) else {
            throw ChatVisibilityStoreError.invalidIdentity
        }
        return try withAdvisoryLock {
            var current = try loadUnlocked()
            guard current.contains(source), !current.contains(destination) else { return current }
            current.insert(destination)
            guard current.count <= Self.maximumHiddenChats else {
                throw ChatVisibilityStoreError.capacityExceeded
            }
            try writeUnlocked(current)
            return current
        }
    }

    private func writeUnlocked(_ identities: Set<ChatVisibilityIdentity>) throws {
        guard identities.count <= Self.maximumHiddenChats else {
            throw ChatVisibilityStoreError.capacityExceeded
        }
        let payload = Payload(version: 1, hidden: identities.map(\.rawValue).sorted())
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            throw ChatVisibilityStoreError.unwritable(error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ChatVisibilityStoreError.unwritable("state file could not be written")
        }
    }

    private func withAdvisoryLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ChatVisibilityStoreError.unwritable("preference directory is unavailable")
        }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw ChatVisibilityStoreError.unreadable("preference lock is unavailable")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            _ = close(descriptor)
            throw ChatVisibilityStoreError.unreadable("preference lock is unavailable")
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        return try body()
    }
}
