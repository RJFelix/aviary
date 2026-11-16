import Foundation

#if canImport(Security)
import Security
#endif

/// Metadata for a local provider credential.
///
/// This is deliberately the only record that leaves ``LocalSecretStore``.  It identifies a
/// credential and the exact provider route it is allowed to serve; it never contains the
/// credential bytes, a masked value, or a length derived from those bytes.
public struct LocalSecretMetadata: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let allowedProviderID: String
    public let allowedOrigin: String

    public var id: String { name }

    public init(name: String, allowedProviderID: String, allowedOrigin: String) {
        self.name = name
        self.allowedProviderID = allowedProviderID
        self.allowedOrigin = allowedOrigin
    }
}

/// The small backend seam used by ``LocalSecretStore``.
///
/// Production uses the macOS Keychain.  The in-memory implementation exists for tests only;
/// there is intentionally no file-backed implementation, especially on Linux.  The record's
/// value is private to this module's store/backend boundary and is not Codable or printable.
public protocol LocalSecretStoreBackend: Sendable {
    func insert(
        namespace: String,
        name: String,
        value: Data,
        metadata: LocalSecretMetadata
    ) throws

    func update(
        namespace: String,
        name: String,
        value: Data,
        metadata: LocalSecretMetadata
    ) throws

    func read(namespace: String, name: String) throws -> LocalSecretBackendRecord?
    func list(namespace: String) throws -> [LocalSecretMetadata]
    func remove(namespace: String, name: String) throws
}

/// A backend record is intentionally not Codable, and its custom description omits the value.
/// Only the store uses those bytes; no public metadata/diagnostic surface receives them.
public struct LocalSecretBackendRecord: Sendable, CustomStringConvertible {
    public let metadata: LocalSecretMetadata
    fileprivate let value: Data

    fileprivate init(metadata: LocalSecretMetadata, value: Data) {
        self.metadata = metadata
        self.value = value
    }

    public var description: String {
        "LocalSecretBackendRecord(metadata: \(metadata))"
    }
}

public enum LocalSecretStoreError: Swift.Error, LocalizedError, Equatable, Sendable {
    case backendUnavailable
    case invalidName
    case invalidProviderID
    case invalidOrigin
    case invalidValue
    case invalidReference
    case missing
    case alreadyExists
    case notFound
    case providerNotPermitted
    case originNotPermitted

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "Local secure credential storage is unavailable on this system."
        case .invalidName:
            return "The local credential name is invalid."
        case .invalidProviderID:
            return "The provider identity for this credential is invalid."
        case .invalidOrigin:
            return "The credential must be bound to a valid HTTPS provider origin."
        case .invalidValue:
            return "The local credential value is invalid or too large."
        case .invalidReference:
            return "The local credential reference is invalid."
        case .missing:
            return "The referenced local credential is unavailable."
        case .alreadyExists:
            return "A local credential with that name already exists."
        case .notFound:
            return "The local credential was not found."
        case .providerNotPermitted:
            return "The local credential is not permitted for this provider."
        case .originNotPermitted:
            return "The local credential is not permitted for this provider origin."
        }
    }
}

/// Keychain-backed credentials for one Aviary ``AgentHome``.
///
/// The Keychain service name is a digest of the home path, so two AgentHomes on the same Mac do
/// not see one another's records.  Values are never written to a plaintext fallback.  On a
/// platform without Security, the default backend is unavailable and every secret reference
/// fails closed.
public struct LocalSecretStore: Sendable, CustomStringConvertible {
    public static let referencePrefix = "@secret:"
    public static let aviaryBundleIdentifier = "works.duckbill.aviary"

    public static let maximumNameBytes = 128
    public static let maximumProviderIDBytes = 256
    public static let maximumOriginBytes = 2_048
    public static let maximumValueBytes = 16 * 1024

    public let home: AgentHome
    private let namespace: String
    private let backend: any LocalSecretStoreBackend

    /// Authentication UI is opt-in for an explicit user-initiated credential test only.
    /// Background discovery and Work Host resolution use the noninteractive default.
    public init(home: AgentHome, backend: (any LocalSecretStoreBackend)? = nil,
                allowAuthenticationUI: Bool = false) {
        self.home = home
        namespace = Self.namespace(for: home)
        self.backend = backend ?? Self.defaultBackend(allowAuthenticationUI: allowAuthenticationUI)
    }

    public var description: String {
        "LocalSecretStore(namespace: \(namespace))"
    }

    /// Save a new credential.  Use ``replace`` for an intentional rotation.
    public func save(
        name: String,
        value: String,
        allowedProviderID: String,
        allowedOrigin: String
    ) throws {
        let metadata = try validatedMetadata(
            name: name, allowedProviderID: allowedProviderID, allowedOrigin: allowedOrigin)
        let bytes = try validatedValue(value)
        try backend.insert(
            namespace: namespace, name: metadata.name, value: bytes, metadata: metadata)
    }

    /// Atomically replace an existing credential's value and route binding.
    public func replace(
        name: String,
        value: String,
        allowedProviderID: String,
        allowedOrigin: String
    ) throws {
        let metadata = try validatedMetadata(
            name: name, allowedProviderID: allowedProviderID, allowedOrigin: allowedOrigin)
        let bytes = try validatedValue(value)
        try backend.update(
            namespace: namespace, name: metadata.name, value: bytes, metadata: metadata)
    }

    public func list() throws -> [LocalSecretMetadata] {
        try backend.list(namespace: namespace)
            .filter { Self.isValidName($0.name) && Self.isValidProviderID($0.allowedProviderID)
                && Self.normalizedHTTPSOrigin($0.allowedOrigin) == $0.allowedOrigin }
            .sorted { $0.name < $1.name }
    }

    /// Catalogue availability is metadata, not proof that this process can decrypt a key.
    /// Actual provider construction must still call `resolve` on the executing host.
    public func hasScopedMetadata(name: String, providerID: String, origin: String) throws -> Bool {
        guard Self.isValidName(name), Self.isValidProviderID(providerID),
              let normalized = Self.normalizedHTTPSOrigin(origin) else { return false }
        return try list().contains {
            $0.name == name && $0.allowedProviderID == providerID && $0.allowedOrigin == normalized
        }
    }

    public func remove(name: String) throws {
        guard Self.isValidName(name) else { throw LocalSecretStoreError.invalidName }
        try backend.remove(namespace: namespace, name: name)
    }

    /// Resolve a name only when both provider identity and HTTPS origin exactly match the
    /// metadata captured when it was saved.  A missing or malformed record is an error rather
    /// than a literal fallback.
    public func resolve(
        name: String,
        providerID: String,
        origin: String
    ) throws -> String? {
        guard Self.isValidName(name) else { throw LocalSecretStoreError.invalidReference }
        guard Self.isValidProviderID(providerID) else {
            throw LocalSecretStoreError.invalidProviderID
        }
        guard let requestedOrigin = Self.normalizedHTTPSOrigin(origin) else {
            throw LocalSecretStoreError.invalidOrigin
        }

        guard let record = try backend.read(namespace: namespace, name: name) else {
            throw LocalSecretStoreError.missing
        }
        guard record.metadata.allowedProviderID == providerID else {
            throw LocalSecretStoreError.providerNotPermitted
        }
        guard record.metadata.allowedOrigin == requestedOrigin else {
            throw LocalSecretStoreError.originNotPermitted
        }
        guard let value = String(data: record.value, encoding: .utf8),
              Self.isValidValue(value) else {
            throw LocalSecretStoreError.invalidValue
        }
        return value
    }

    /// Resolve an ``@secret:<name>`` expression.  Non-secret expressions return nil so callers
    /// can continue with their ordinary environment/command/literal resolution path.
    public func resolve(
        expression: String?,
        providerID: String,
        origin: String
    ) throws -> String? {
        guard let expression, !expression.isEmpty else { return nil }
        guard case .secretReference(let name) = ApiKeyForm.classify(expression) else {
            return nil
        }
        guard !name.isEmpty else { throw LocalSecretStoreError.invalidReference }
        return try resolve(name: name, providerID: providerID, origin: origin)
    }

    /// Hash only the standardized path; the path itself never becomes a Keychain service name.
    public static func namespace(for home: AgentHome) -> String {
        let path = home.root.standardizedFileURL.path
        let digest = AviarySHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "com.l9labs.aviary.local-secret.\(digest)"
    }

    /// Return the only two executable paths eligible for a new item's trusted-application ACL.
    ///
    /// This helper is pure: it does not inspect files or touch Keychain.  The caller supplies the
    /// bundle identity already obtained from a real ``Bundle``.  A copied SwiftPM binary, a
    /// helper outside the bundle, a different bundle identifier, or an arbitrary `.app` path
    /// therefore receives no trusted paths and falls back to the ordinary Keychain policy.
    public static func bundledTrustedApplicationPaths(
        bundleURL: URL,
        bundleIdentifier: String,
        executableURL: URL?
    ) -> [String] {
        let app = bundleURL.standardizedFileURL
        guard let executableURL,
              app.pathExtension == "app",
              app.lastPathComponent == "Aviary.app",
              bundleIdentifier == aviaryBundleIdentifier else { return [] }

        let appExecutable = app.appending(path: "Contents/MacOS/Aviary").standardizedFileURL
        let daemonExecutable = app.appending(path: "Contents/Helpers/aviaryd").standardizedFileURL
        let current = executableURL.standardizedFileURL
        guard current == appExecutable || current == daemonExecutable else { return [] }
        return [appExecutable.path, daemonExecutable.path]
    }

    /// Resolve the bundled GUI/helper paths for the current process.  A standalone test binary
    /// and an unbundled SwiftPM executable intentionally return an empty list.
    public static func currentBundledTrustedApplicationPaths() -> [String] {
        let main = Bundle.main
        guard let executable = main.executableURL?.standardizedFileURL else { return [] }
        let app: URL
        if main.bundleURL.pathExtension == "app" {
            app = main.bundleURL.standardizedFileURL
        } else {
            let helpers = executable.deletingLastPathComponent()
            guard helpers.lastPathComponent == "Helpers",
                  helpers.deletingLastPathComponent().lastPathComponent == "Contents" else {
                return []
            }
            app = helpers.deletingLastPathComponent().deletingLastPathComponent()
        }
        let identifier = Bundle(url: app)?.bundleIdentifier ?? main.bundleIdentifier ?? ""
        return bundledTrustedApplicationPaths(
            bundleURL: app, bundleIdentifier: identifier, executableURL: executable)
    }

    /// Normalize a provider URL to its HTTPS origin.  Paths are deliberately dropped, while
    /// credentials, query strings and fragments are rejected.
    public static func normalizedHTTPSOrigin(_ raw: String) -> String? {
        guard raw.utf8.count <= maximumOriginBytes,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }

        let lowerHost = host.lowercased()
        var result = "https://"
        if lowerHost.contains(":") && !lowerHost.hasPrefix("[") {
            result += "[\(lowerHost)]"
        } else {
            result += lowerHost
        }
        if let port = components.port, port != 443 {
            result += ":\(port)"
        }
        return result
    }

    public static func isValidName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumNameBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
                || ($0.value >= 0x30 && $0.value <= 0x39)
                || $0.value == 0x2D || $0.value == 0x2E || $0.value == 0x5F
        }
    }

    public static func isValidProviderID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumProviderIDBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 }
    }

    private func validatedMetadata(
        name: String,
        allowedProviderID: String,
        allowedOrigin: String
    ) throws -> LocalSecretMetadata {
        guard Self.isValidName(name) else { throw LocalSecretStoreError.invalidName }
        guard Self.isValidProviderID(allowedProviderID) else {
            throw LocalSecretStoreError.invalidProviderID
        }
        guard let origin = Self.normalizedHTTPSOrigin(allowedOrigin) else {
            throw LocalSecretStoreError.invalidOrigin
        }
        return LocalSecretMetadata(
            name: name, allowedProviderID: allowedProviderID, allowedOrigin: origin)
    }

    private func validatedValue(_ value: String) throws -> Data {
        let data = Data(value.utf8)
        guard Self.isValidValue(value) else {
            throw LocalSecretStoreError.invalidValue
        }
        return data
    }

    private static func isValidValue(_ value: String) -> Bool {
        let data = Data(value.utf8)
        return !data.isEmpty
            && data.count <= maximumValueBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    private static func defaultBackend(allowAuthenticationUI: Bool) -> any LocalSecretStoreBackend {
        #if canImport(Security)
        return KeychainLocalSecretStoreBackend(allowAuthenticationUI: allowAuthenticationUI)
        #else
        return UnavailableLocalSecretStoreBackend()
        #endif
    }
}

/// A process-local backend for deterministic tests.  It is never selected by the production
/// initializer and does not touch the user's Keychain.
public final class InMemoryLocalSecretStoreBackend: LocalSecretStoreBackend, @unchecked Sendable {
    private struct Entry {
        let value: Data
        let metadata: LocalSecretMetadata
    }

    private let lock = NSLock()
    private var entries: [String: [String: Entry]] = [:]

    public init() {}

    public func insert(
        namespace: String,
        name: String,
        value: Data,
        metadata: LocalSecretMetadata
    ) throws {
        lock.lock(); defer { lock.unlock() }
        var scoped = entries[namespace, default: [:]]
        guard scoped[name] == nil else { throw LocalSecretStoreError.alreadyExists }
        scoped[name] = Entry(value: value, metadata: metadata)
        entries[namespace] = scoped
    }

    public func update(
        namespace: String,
        name: String,
        value: Data,
        metadata: LocalSecretMetadata
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard entries[namespace]?[name] != nil else { throw LocalSecretStoreError.notFound }
        entries[namespace]?[name] = Entry(value: value, metadata: metadata)
    }

    public func read(namespace: String, name: String) throws -> LocalSecretBackendRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[namespace]?[name] else { return nil }
        return LocalSecretBackendRecord(metadata: entry.metadata, value: entry.value)
    }

    public func list(namespace: String) throws -> [LocalSecretMetadata] {
        lock.lock(); defer { lock.unlock() }
        return entries[namespace, default: [:]].values.map(\.metadata)
    }

    public func remove(namespace: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard entries[namespace]?[name] != nil else { throw LocalSecretStoreError.notFound }
        entries[namespace]?[name] = nil
    }
}

private struct UnavailableLocalSecretStoreBackend: LocalSecretStoreBackend {
    func insert(
        namespace: String, name: String, value: Data, metadata: LocalSecretMetadata
    ) throws { throw LocalSecretStoreError.backendUnavailable }

    func update(
        namespace: String, name: String, value: Data, metadata: LocalSecretMetadata
    ) throws { throw LocalSecretStoreError.backendUnavailable }

    func read(namespace: String, name: String) throws -> LocalSecretBackendRecord? {
        throw LocalSecretStoreError.backendUnavailable
    }

    func list(namespace: String) throws -> [LocalSecretMetadata] {
        throw LocalSecretStoreError.backendUnavailable
    }

    func remove(namespace: String, name: String) throws {
        throw LocalSecretStoreError.backendUnavailable
    }
}

#if canImport(Security)
private final class KeychainLocalSecretStoreBackend: LocalSecretStoreBackend, @unchecked Sendable {
    // The legacy interaction flag is process-wide, so distinct store instances must
    // serialize with each other as well as with their own reads and writes.
    private static let processLock = NSLock()
    private var lock: NSLock { Self.processLock }
    private let allowAuthenticationUI: Bool

    init(allowAuthenticationUI: Bool) { self.allowAuthenticationUI = allowAuthenticationUI }

    func insert(
        namespace: String,
        name: String,
        value: Data,
        metadata: LocalSecretMetadata
    ) throws {
        lock.lock(); defer { lock.unlock() }
        var query = baseQuery(namespace: namespace, name: name)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrGeneric as String] = try metadataData(metadata)
        if let access = try trustedApplicationAccess() {
            // This is deliberately set only for a brand-new item.  Rotation updates the
            // existing value/metadata atomically and never rewrites its access policy.
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw LocalSecretStoreError.alreadyExists }
        guard status == errSecSuccess else { throw LocalSecretStoreError.backendUnavailable }
    }

    func update(
        namespace: String,
        name: String,
        value: Data,
        metadata: LocalSecretMetadata
    ) throws {
        lock.lock(); defer { lock.unlock() }
        let query = baseQuery(namespace: namespace, name: name)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrGeneric as String: try metadataData(metadata),
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { throw LocalSecretStoreError.notFound }
        guard status == errSecSuccess else { throw LocalSecretStoreError.backendUnavailable }
    }

    func read(namespace: String, name: String) throws -> LocalSecretBackendRecord? {
        lock.lock(); defer { lock.unlock() }
        var query = baseQuery(namespace: namespace, name: name)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Provider resolution can run on a daemon/background queue.  Never let a
        // hidden Keychain authorization prompt block that queue indefinitely; an
        // item that needs interaction is a failed resolution for this API.
        query[kSecUseAuthenticationUI as String] = allowAuthenticationUI
            ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var raw: CFTypeRef?
        let status = try withUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &raw)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let dictionary = raw as? [String: Any],
              let value = dictionary[kSecValueData as String] as? Data,
              let generic = dictionary[kSecAttrGeneric as String] as? Data,
              let metadata = try? JSONDecoder().decode(LocalSecretMetadata.self, from: generic)
        else { throw LocalSecretStoreError.backendUnavailable }
        return LocalSecretBackendRecord(metadata: metadata, value: value)
    }

    func list(namespace: String) throws -> [LocalSecretMetadata] {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            // Listing metadata is also part of provider preflight and must be
            // noninteractive for the same reason as secret reads.
            kSecUseAuthenticationUI as String: allowAuthenticationUI
                ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
        ]
        var raw: CFTypeRef?
        let status = try withUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &raw)
        }
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw LocalSecretStoreError.backendUnavailable }
        let records: [[String: Any]]
        if let one = raw as? [String: Any] {
            records = [one]
        } else if let many = raw as? [[String: Any]] {
            records = many
        } else {
            throw LocalSecretStoreError.backendUnavailable
        }
        return try records.map { dictionary in
            guard let generic = dictionary[kSecAttrGeneric as String] as? Data else {
                throw LocalSecretStoreError.backendUnavailable
            }
            guard let metadata = try? JSONDecoder().decode(
                LocalSecretMetadata.self, from: generic) else {
                throw LocalSecretStoreError.backendUnavailable
            }
            return metadata
        }
    }

    func remove(namespace: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(namespace: namespace, name: name) as CFDictionary)
        if status == errSecItemNotFound { throw LocalSecretStoreError.notFound }
        guard status == errSecSuccess else { throw LocalSecretStoreError.backendUnavailable }
    }

    private func baseQuery(namespace: String, name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace,
            kSecAttrAccount as String: name,
        ]
    }

    private func metadataData(_ metadata: LocalSecretMetadata) throws -> Data {
        do {
            return try JSONEncoder().encode(metadata)
        } catch {
            throw LocalSecretStoreError.backendUnavailable
        }
    }

    /// The legacy macOS keychain can still invoke SecurityAgent for a file-keychain ACL even
    /// when kSecUseAuthenticationUIFail is present.  Suppress that process-wide legacy switch
    /// for the duration of every background read/list operation, restoring the caller's prior
    /// setting afterwards.  The backend lock serializes these changes within this process.
    private func withUserInteractionDisabled<T>(_ operation: () -> T) throws -> T {
        if allowAuthenticationUI { return operation() }
        var previous = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else {
            throw LocalSecretStoreError.backendUnavailable
        }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw LocalSecretStoreError.backendUnavailable
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }

    private func trustedApplicationAccess() throws -> SecAccess? {
        let paths = LocalSecretStore.currentBundledTrustedApplicationPaths()
        guard !paths.isEmpty else { return nil }

        var applications: [SecTrustedApplication] = []
        applications.reserveCapacity(paths.count)
        for path in paths {
            var application: SecTrustedApplication?
            let status = path.withCString {
                SecTrustedApplicationCreateFromPath($0, &application)
            }
            guard status == errSecSuccess, let application else {
                throw LocalSecretStoreError.backendUnavailable
            }
            applications.append(application)
        }

        var access: SecAccess?
        let status = SecAccessCreate(
            "Aviary Local Credential" as CFString, applications as CFArray, &access)
        guard status == errSecSuccess else { throw LocalSecretStoreError.backendUnavailable }
        return access
    }
}
#endif
