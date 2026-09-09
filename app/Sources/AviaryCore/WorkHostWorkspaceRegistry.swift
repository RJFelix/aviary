import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Public workspace identity and projection

/// An opaque identity minted by the Work Host for one registered local workspace.
///
/// The value deliberately has no path-derived material.  Clients can retain and send this
/// identity back to its owning host, but cannot use it to infer where the workspace lives.
public struct WorkHostWorkspaceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public typealias RawValue = String
    public let rawValue: String

    public var value: String { rawValue }
    public var description: String { rawValue }

    /// Construct an ID after applying the same validation used when decoding a client value.
    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw WorkHostWorkspaceRegistryError.invalidWorkspaceID
        }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    fileprivate static let prefix = "workspace-"
    public static let maximumBytes = 64

    fileprivate static func isValid(_ value: String) -> Bool {
        guard value.utf8.count <= maximumBytes,
              value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        let scalars = Array(suffix.unicodeScalars)
        guard scalars.count == 36 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard scalar.value == 0x2D else { return false }
            } else {
                let digit = scalar.value >= 0x30 && scalar.value <= 0x39
                let lowerHex = scalar.value >= 0x61 && scalar.value <= 0x66
                guard digit || lowerHex else { return false }
            }
        }
        return UUID(uuidString: suffix) != nil && suffix == suffix.lowercased()
    }
}

public enum WorkHostWorkspaceAvailability: String, Codable, Hashable, Sendable {
    case available
    case unavailable
}

/// Capabilities are observations about a registered directory, never permissions or credentials
/// from the host.  A client may use them to decide whether to offer an operation before asking
/// the host to resolve the opaque workspace ID.
public enum WorkHostWorkspaceCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case directory
    case read
    case write
    case execute
    case resolve
}

/// A bounded, path-free explanation for an unavailable workspace.  The reason is intentionally
/// coarse: it gives a client enough information to offer the right recovery action without
/// exposing a host-local locator or filesystem measurement.
public enum WorkHostWorkspaceUnavailabilityReason: String, Codable, Hashable, Sendable {
    case identityNeedsConfirmation = "identity_needs_confirmation"
    case inaccessible
}

/// Host-private durable identity. `volumeUUID` is Foundation's persistent volume UUID on Darwin;
/// `device` is retained as a current observation and as the fallback on platforms/filesystems
/// which do not publish one.  Foundation's `volumeIdentifier` and `fileResourceIdentifier` are
/// explicitly process/restart-scoped, so neither is persisted here.
struct WorkHostWorkspaceFilesystemIdentity: Codable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let type: UInt64
    let volumeUUID: String?

    init(device: UInt64, inode: UInt64, type: UInt64, volumeUUID: String? = nil) {
        self.device = device
        self.inode = inode
        self.type = type
        self.volumeUUID = volumeUUID
    }

    func identifiesSameResource(as current: Self) -> Bool {
        guard inode == current.inode, type == current.type else { return false }
        if let volumeUUID {
            // Once registration captured a persistent volume identity, losing that evidence is
            // not permission to fall back to a boot-scoped device number.
            guard let currentVolumeUUID = current.volumeUUID else { return false }
            return volumeUUID == currentVolumeUUID
        }
        return device == current.device
    }
}

/// The client-safe description of one workspace.  In particular, this type has no URL, path,
/// username, process ID, or host-local diagnostic field.
public struct WorkHostWorkspaceDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let workspaceID: WorkHostWorkspaceID
    public let label: String?
    public let isDefault: Bool
    public let availability: WorkHostWorkspaceAvailability
    public let capabilities: Set<WorkHostWorkspaceCapability>
    public let unavailabilityReason: WorkHostWorkspaceUnavailabilityReason?

    public var id: WorkHostWorkspaceID { workspaceID }
    public var identifier: WorkHostWorkspaceID { workspaceID }
    public var displayLabel: String? { label }
    public var isAvailable: Bool { availability == .available }

    public init(
        workspaceID: WorkHostWorkspaceID,
        label: String? = nil,
        isDefault: Bool = false,
        availability: WorkHostWorkspaceAvailability = .available,
        capabilities: Set<WorkHostWorkspaceCapability> = [],
        unavailabilityReason: WorkHostWorkspaceUnavailabilityReason? = nil
    ) throws {
        guard WorkHostWorkspaceRegistry.isValidLabel(label) else {
            throw WorkHostWorkspaceRegistryError.invalidLabel
        }
        guard availability == .unavailable || unavailabilityReason == nil else {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }
        self.workspaceID = workspaceID
        self.label = label
        self.isDefault = isDefault
        self.availability = availability
        self.capabilities = capabilities
        self.unavailabilityReason = unavailabilityReason
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID, label, isDefault, availability, capabilities, unavailabilityReason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let workspaceID = try values.decode(WorkHostWorkspaceID.self, forKey: .workspaceID)
        let label = try values.decodeIfPresent(String.self, forKey: .label)
        guard WorkHostWorkspaceRegistry.isValidLabel(label) else {
            throw WorkHostWorkspaceRegistryError.invalidLabel
        }
        let isDefault = try values.decode(Bool.self, forKey: .isDefault)
        let availability = try values.decode(
            WorkHostWorkspaceAvailability.self, forKey: .availability)
        let capabilities = try values.decode(
            Set<WorkHostWorkspaceCapability>.self, forKey: .capabilities)
        let unavailabilityReason = try values.decodeIfPresent(
            WorkHostWorkspaceUnavailabilityReason.self, forKey: .unavailabilityReason)
        guard capabilities.count <= WorkHostWorkspaceCapability.allCases.count else {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }
        try self.init(
            workspaceID: workspaceID,
            label: label,
            isDefault: isDefault,
            availability: availability,
            capabilities: capabilities,
            unavailabilityReason: unavailabilityReason)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(workspaceID, forKey: .workspaceID)
        try values.encodeIfPresent(label, forKey: .label)
        try values.encode(isDefault, forKey: .isDefault)
        try values.encode(availability, forKey: .availability)
        try values.encode(
            capabilities.sorted { $0.rawValue < $1.rawValue },
            forKey: .capabilities)
        try values.encodeIfPresent(unavailabilityReason, forKey: .unavailabilityReason)
    }
}

/// A host-local, single-use-shaped confirmation prepared from an explicit directory selection.
/// Only opaque identity and the revision fence are public; path and filesystem observations never
/// cross the Work-service boundary.  Confirming reopens and revalidates the selected directory.
public struct WorkHostWorkspaceReconfirmation: Hashable, Sendable {
    public let workspaceID: WorkHostWorkspaceID
    public let expectedRegistryRevision: UInt64

    fileprivate let canonicalPath: String
    fileprivate let expectedRegisteredIdentity: WorkHostWorkspaceFilesystemIdentity
    fileprivate let selectedIdentity: WorkHostWorkspaceFilesystemIdentity

    fileprivate init(
        workspaceID: WorkHostWorkspaceID,
        expectedRegistryRevision: UInt64,
        canonicalPath: String,
        expectedRegisteredIdentity: WorkHostWorkspaceFilesystemIdentity,
        selectedIdentity: WorkHostWorkspaceFilesystemIdentity
    ) {
        self.workspaceID = workspaceID
        self.expectedRegistryRevision = expectedRegistryRevision
        self.canonicalPath = canonicalPath
        self.expectedRegisteredIdentity = expectedRegisteredIdentity
        self.selectedIdentity = selectedIdentity
    }
}

/// A bounded public snapshot.  `isComplete` means that the host returned the complete bounded
/// registry projection for this revision; it is independent of whether each directory is
/// currently available.
public struct WorkHostWorkspaceCatalog: Codable, Hashable, Sendable {
    public let entries: [WorkHostWorkspaceDescriptor]
    public let revision: UInt64
    public let isComplete: Bool

    public var workspaces: [WorkHostWorkspaceDescriptor] { entries }
    public var complete: Bool { isComplete }
    public var defaultWorkspace: WorkHostWorkspaceDescriptor? {
        entries.first(where: { $0.isDefault })
    }

    /// The empty catalog is a valid bounded projection used by in-memory/conformance hosts
    /// which do not own a filesystem workspace registry.
    public static let empty: WorkHostWorkspaceCatalog = {
        do {
            return try WorkHostWorkspaceCatalog(entries: [], revision: 0, isComplete: true)
        } catch {
            preconditionFailure("empty workspace catalog must satisfy its own bounds")
        }
    }()

    public init(
        entries: [WorkHostWorkspaceDescriptor],
        revision: UInt64,
        isComplete: Bool = true
    ) throws {
        guard entries.count <= WorkHostWorkspaceRegistry.maximumEntries,
              Set(entries.map(\.workspaceID)).count == entries.count,
              entries.filter(\.isDefault).count <= 1,
              revision <= WorkHostWorkspaceRegistry.maximumRevision else {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }
        self.entries = entries.sorted { $0.workspaceID.rawValue < $1.workspaceID.rawValue }
        self.revision = revision
        self.isComplete = isComplete
    }

    private enum CodingKeys: String, CodingKey {
        case entries, revision, isComplete
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode([WorkHostWorkspaceDescriptor].self, forKey: .entries)
        guard entries.count <= WorkHostWorkspaceRegistry.maximumEntries else {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }
        guard Set(entries.map(\.workspaceID)).count == entries.count,
              entries.filter(\.isDefault).count <= 1 else {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }
        let revision = try values.decode(UInt64.self, forKey: .revision)
        guard revision <= WorkHostWorkspaceRegistry.maximumRevision else {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }
        self.entries = entries.sorted { $0.workspaceID.rawValue < $1.workspaceID.rawValue }
        self.revision = revision
        self.isComplete = try values.decode(Bool.self, forKey: .isComplete)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries, forKey: .entries)
        try values.encode(revision, forKey: .revision)
        try values.encode(isComplete, forKey: .isComplete)
    }
}

/// A host-owned catalog read boundary. The async shape is deliberate: implementations may cross
/// an actor or process boundary, and the Work service can keep this probe off its request actor.
/// Providers must return only the bounded public projection; private locators never cross this
/// boundary.
public typealias WorkHostWorkspaceCatalogProvider =
    @Sendable () async throws -> WorkHostWorkspaceCatalog

// MARK: - Bounds and errors

/// Bounds apply to both private records and public projections.  The upper ceilings are fixed
/// here so a caller cannot turn this host boundary into an unbounded local database.
public struct WorkHostWorkspaceRegistryBounds: Codable, Hashable, Sendable {
    public static let `default` = WorkHostWorkspaceRegistryBounds()

    public let maxEntries: Int
    public let maxRecordBytes: Int
    public let maxLabelBytes: Int
    public let maxWorkspaceIDBytes: Int
    public let maxPathBytes: Int

    public var maximumEntries: Int { maxEntries }
    public var maximumRecordBytes: Int { maxRecordBytes }
    public var maximumLabelBytes: Int { maxLabelBytes }
    public var maximumWorkspaceIDBytes: Int { maxWorkspaceIDBytes }
    public var maximumPathBytes: Int { maxPathBytes }

    public init(
        maxEntries: Int = 256,
        maxRecordBytes: Int = 256 * 1024,
        maxLabelBytes: Int = 128,
        maxWorkspaceIDBytes: Int = WorkHostWorkspaceID.maximumBytes,
        maxPathBytes: Int = 4 * 1024
    ) {
        self.maxEntries = max(0, min(maxEntries, 256))
        self.maxRecordBytes = max(1, min(maxRecordBytes, 1 * 1024 * 1024))
        self.maxLabelBytes = max(1, min(maxLabelBytes, 128))
        self.maxWorkspaceIDBytes = max(1, min(maxWorkspaceIDBytes, WorkHostWorkspaceID.maximumBytes))
        self.maxPathBytes = max(1, min(maxPathBytes, 64 * 1024))
    }

    private enum CodingKeys: String, CodingKey {
        case maxEntries, maxRecordBytes, maxLabelBytes, maxWorkspaceIDBytes, maxPathBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxEntries: try values.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 256,
            maxRecordBytes: try values.decodeIfPresent(Int.self, forKey: .maxRecordBytes)
                ?? 256 * 1024,
            maxLabelBytes: try values.decodeIfPresent(Int.self, forKey: .maxLabelBytes) ?? 128,
            maxWorkspaceIDBytes: try values.decodeIfPresent(
                Int.self, forKey: .maxWorkspaceIDBytes) ?? WorkHostWorkspaceID.maximumBytes,
            maxPathBytes: try values.decodeIfPresent(Int.self, forKey: .maxPathBytes) ?? 4 * 1024)
    }

    /// Spelled-out labels are useful at call sites that treat these as a wire/storage policy.
    /// Requiring `maximumEntries` keeps this overload unambiguous with the default initializer.
    public init(
        maximumEntries: Int,
        maximumRecordBytes: Int = 256 * 1024,
        maximumLabelBytes: Int = 128,
        maximumWorkspaceIDBytes: Int = WorkHostWorkspaceID.maximumBytes,
        maximumPathBytes: Int = 4 * 1024
    ) {
        self.init(
            maxEntries: maximumEntries,
            maxRecordBytes: maximumRecordBytes,
            maxLabelBytes: maximumLabelBytes,
            maxWorkspaceIDBytes: maximumWorkspaceIDBytes,
            maxPathBytes: maximumPathBytes)
    }
}

public enum WorkHostWorkspaceRegistryError: Error, LocalizedError, Equatable, Sendable {
    case invalidRegistryRoot
    case registryRootSymlink
    case registryRootUnavailable
    case registrySymlink
    case registryNotRegular
    case registryNotPrivate
    case registryTooLarge
    case malformedRegistry
    case registryInaccessible
    case lockUnavailable
    case invalidWorkspacePath
    case workspaceSymlink
    case workspaceNotDirectory
    case workspaceNotOwned
    case workspaceInaccessible
    case workspaceIdentityMismatch
    case workspaceReconfirmationStale
    case invalidLabel
    case invalidWorkspaceID
    case capacityExceeded
    case workspaceNotFound
    case revisionExhausted
    case ioFailure

    public var errorDescription: String? {
        switch self {
        case .invalidRegistryRoot: return "The workspace registry root is invalid."
        case .registryRootSymlink: return "The workspace registry root is a symlink."
        case .registryRootUnavailable: return "The workspace registry root is unavailable."
        case .registrySymlink: return "The workspace registry file is a symlink."
        case .registryNotRegular: return "The workspace registry is not a regular file."
        case .registryNotPrivate: return "The workspace registry is not privately owned."
        case .registryTooLarge: return "The workspace registry exceeds its byte bound."
        case .malformedRegistry: return "The workspace registry is malformed."
        case .registryInaccessible: return "The workspace registry cannot be read."
        case .lockUnavailable: return "The workspace registry lock is unavailable."
        case .invalidWorkspacePath: return "The requested workspace is invalid."
        case .workspaceSymlink: return "Symlinked workspaces are not accepted."
        case .workspaceNotDirectory: return "The requested workspace is not a directory."
        case .workspaceNotOwned: return "The requested workspace is not owned by this host user."
        case .workspaceInaccessible: return "The requested workspace is inaccessible."
        case .workspaceIdentityMismatch:
            return "The registered workspace identity no longer matches this folder and requires confirmation."
        case .workspaceReconfirmationStale:
            return "The workspace changed after confirmation was prepared. Choose the folder again."
        case .invalidLabel: return "The workspace label is invalid."
        case .invalidWorkspaceID: return "The workspace identity is invalid."
        case .capacityExceeded: return "The workspace registry capacity is exhausted."
        case .workspaceNotFound: return "The workspace identity is not registered."
        case .revisionExhausted: return "The workspace registry revision is exhausted."
        case .ioFailure: return "The workspace registry could not be durably updated."
        }
    }
}

// MARK: - AgentHome locations

public extension AgentHome {
    /// Aviary's private host-owned workspace record.  The file contains canonical paths, so it
    /// must never be sent to a Work-service client.
    var workHostWorkspaceRegistryFile: URL {
        root.appending(path: "workspaces.json", directoryHint: .notDirectory)
    }
}

// MARK: - Durable registry

/// A host-local, durable registry of directories that may be selected by future Work-service
/// clients.  Every operation reopens and validates the private record; no in-memory cache is
/// authoritative.  This is intentionally a value type so independent processes can share one
/// AgentHome while the on-disk lock provides the mutation fence.
public struct WorkHostWorkspaceRegistry: Sendable, Hashable {
    public static let maximumEntries = 256
    public static let maximumRevision: UInt64 = 1_000_000_000
    public static let defaultMaximumRecordBytes = 256 * 1024
    public static let defaultMaximumLabelBytes = 128
    public static let defaultMaximumPathBytes = 4 * 1024

    public let home: AgentHome
    public let bounds: WorkHostWorkspaceRegistryBounds

    public init(
        home: AgentHome,
        bounds: WorkHostWorkspaceRegistryBounds = .default
    ) throws {
        guard home.root.isFileURL, !home.root.path.isEmpty,
              home.root.path.unicodeScalars.allSatisfy({ $0.value != 0 }) else {
            throw WorkHostWorkspaceRegistryError.invalidRegistryRoot
        }
        self.home = home
        self.bounds = bounds

        // Opening a store is deliberately part of initialization.  A pre-existing malformed,
        // symlinked, or foreign-private file cannot be turned into a fresh registry later.
        try validateRootIfPresent()
        if rootExists() {
            _ = try readStore()
        }
    }

    /// Register one local directory through the explicit host-admin boundary.
    ///
    /// A second registration of the same canonical directory returns the original opaque ID.
    /// Supplying a label updates that existing label; `isDefault` can promote the entry and
    /// clears the previous default atomically.  A false `isDefault` never clears an existing
    /// default, which makes omission safe for idempotent callers.
    @discardableResult
    public func registerLocalDirectory(
        _ directory: URL,
        label: String? = nil,
        isDefault: Bool = false
    ) throws -> WorkHostWorkspaceDescriptor {
        try validateLabel(label)
        return try withExclusiveLock(createRoot: true) {
            let canonical = try secureWorkspaceURL(directory, requireWrite: true)
            var store = try readStore()

            if let existingIndex = store.entries.firstIndex(where: {
                $0.canonicalPath == canonical.url.path
            }) {
                var existing = store.entries[existingIndex]
                // A path is only a locator. If the directory identity at that path changed,
                // never silently rebind the old opaque ID to the new filesystem object.
                guard existing.filesystemIdentity.identifiesSameResource(as: canonical.identity) else {
                    throw WorkHostWorkspaceRegistryError.workspaceIdentityMismatch
                }
                var changed = false
                // Normalize a positively matched legacy/raw-device identity through this one
                // explicit registration path. A pre-existing mismatch never reaches this write.
                if existing.filesystemIdentity != canonical.identity {
                    existing.filesystemIdentity = canonical.identity
                    changed = true
                }
                if let label, existing.label != label {
                    existing.label = label
                    changed = true
                }
                if isDefault && !existing.isDefault {
                    for index in store.entries.indices where store.entries[index].isDefault {
                        store.entries[index].isDefault = false
                    }
                    existing.isDefault = true
                    changed = true
                }
                store.entries[existingIndex] = existing
                if changed {
                    store.revision = try nextRevision(after: store.revision)
                    try publish(store)
                }
                return try descriptor(for: existing)
            }

            guard store.entries.count < bounds.maxEntries else {
                throw WorkHostWorkspaceRegistryError.capacityExceeded
            }

            let id = try mintID(notIn: store.entries)
            if isDefault {
                for index in store.entries.indices where store.entries[index].isDefault {
                    store.entries[index].isDefault = false
                }
            }
            store.entries.append(StoredWorkspace(
                id: id,
                label: label ?? generatedLabel(for: canonical.url),
                isDefault: isDefault,
                canonicalPath: canonical.url.path,
                filesystemIdentity: canonical.identity))
            store.revision = try nextRevision(after: store.revision)
            try publish(store)
            return try descriptor(for: store.entries[store.entries.count - 1])
        }
    }

    /// Prepare an explicit re-confirmation from a user-selected directory. The selected path must
    /// still be the registered canonical path; this operation cannot relocate launch manifests.
    /// No durable state changes until the returned revision- and identity-bound token is confirmed.
    public func prepareReconfirmation(
        workspaceID: WorkHostWorkspaceID,
        directory: URL
    ) throws -> WorkHostWorkspaceReconfirmation {
        try validateRootIfPresent()
        guard rootExists() else { throw WorkHostWorkspaceRegistryError.workspaceNotFound }
        return try withExclusiveLock(createRoot: false) {
            let store = try readStore()
            guard let entry = store.entries.first(where: { $0.id == workspaceID.rawValue }) else {
                throw WorkHostWorkspaceRegistryError.workspaceNotFound
            }
            let selected = try secureWorkspaceURL(directory, requireWrite: true)
            guard selected.url.path == entry.canonicalPath else {
                throw WorkHostWorkspaceRegistryError.workspaceIdentityMismatch
            }
            return WorkHostWorkspaceReconfirmation(
                workspaceID: workspaceID,
                expectedRegistryRevision: store.revision,
                canonicalPath: entry.canonicalPath,
                expectedRegisteredIdentity: entry.filesystemIdentity,
                selectedIdentity: selected.identity)
        }
    }

    /// Confirm a previously prepared directory selection. Every mutable input is re-read under
    /// the registry lock. A changed revision, registration, path, or selected filesystem object
    /// invalidates the token rather than silently adopting new state.
    @discardableResult
    public func confirmReconfirmation(
        _ confirmation: WorkHostWorkspaceReconfirmation
    ) throws -> WorkHostWorkspaceDescriptor {
        try validateRootIfPresent()
        guard rootExists() else { throw WorkHostWorkspaceRegistryError.workspaceNotFound }
        return try withExclusiveLock(createRoot: false) {
            var store = try readStore()
            guard store.revision == confirmation.expectedRegistryRevision,
                  let index = store.entries.firstIndex(where: {
                      $0.id == confirmation.workspaceID.rawValue
                  }),
                  store.entries[index].canonicalPath == confirmation.canonicalPath,
                  store.entries[index].filesystemIdentity
                    == confirmation.expectedRegisteredIdentity else {
                throw WorkHostWorkspaceRegistryError.workspaceReconfirmationStale
            }

            let selected = try secureWorkspaceURL(
                URL(fileURLWithPath: confirmation.canonicalPath, isDirectory: true),
                requireWrite: true)
            guard selected.url.path == confirmation.canonicalPath,
                  selected.identity == confirmation.selectedIdentity else {
                throw WorkHostWorkspaceRegistryError.workspaceReconfirmationStale
            }

            if store.entries[index].filesystemIdentity != selected.identity {
                store.entries[index].filesystemIdentity = selected.identity
                store.revision = try nextRevision(after: store.revision)
                try publish(store)
            }
            return try descriptor(for: store.entries[index])
        }
    }

    /// Return a fresh path-free public snapshot of the host registry.
    public func catalog() throws -> WorkHostWorkspaceCatalog {
        try validateRootIfPresent()
        guard rootExists() else {
            return try WorkHostWorkspaceCatalog(entries: [], revision: 0, isComplete: true)
        }
        return try withExclusiveLock(createRoot: false) {
            let store = try readStore()
            let descriptors = try store.entries
                .sorted { $0.id < $1.id }
                .map { try descriptor(for: $0) }
            return try WorkHostWorkspaceCatalog(
                entries: descriptors, revision: store.revision, isComplete: true)
        }
    }

    /// Look up an already-registered canonical directory without registering, minting, or
    /// writing anything. This is the recovery discovery path for a fresh-chat request whose
    /// existing registration now needs explicit identity confirmation.
    public func registeredWorkspace(
        for directory: URL
    ) throws -> WorkHostWorkspaceDescriptor? {
        try validateRootIfPresent()
        guard rootExists() else { return nil }
        let selected = try secureWorkspaceURL(directory, requireWrite: false)
        return try withExclusiveLock(createRoot: false) {
            let store = try readStore()
            guard let entry = store.entries.first(where: {
                $0.canonicalPath == selected.url.path
            }) else { return nil }
            return try descriptor(for: entry)
        }
    }

    /// Resolve an opaque identity only after the current private record and directory are checked.
    /// The returned URL is host-side material and must not be included in a client projection.
    public func resolve(_ workspaceID: WorkHostWorkspaceID) throws -> URL {
        try resolve(workspaceID.rawValue)
    }

    public func resolve(_ workspaceID: String) throws -> URL {
        guard WorkHostWorkspaceID.isValid(workspaceID),
              workspaceID.utf8.count <= bounds.maxWorkspaceIDBytes else {
            throw WorkHostWorkspaceRegistryError.invalidWorkspaceID
        }
        try validateRootIfPresent()
        guard rootExists() else { throw WorkHostWorkspaceRegistryError.workspaceNotFound }
        return try withExclusiveLock(createRoot: false) {
            let store = try readStore()
            guard let entry = store.entries.first(where: { $0.id == workspaceID }) else {
                throw WorkHostWorkspaceRegistryError.workspaceNotFound
            }
            let resolved = try secureWorkspaceURL(
                URL(fileURLWithPath: entry.canonicalPath), requireWrite: false)
            guard entry.filesystemIdentity.identifiesSameResource(as: resolved.identity) else {
                throw WorkHostWorkspaceRegistryError.workspaceIdentityMismatch
            }
            return resolved.url
        }
    }

    public func descriptor(for workspaceID: WorkHostWorkspaceID) throws
        -> WorkHostWorkspaceDescriptor {
        try descriptor(for: workspaceID.rawValue)
    }

    public func descriptor(for workspaceID: String) throws -> WorkHostWorkspaceDescriptor {
        let snapshot = try catalog()
        guard let descriptor = snapshot.entries.first(where: {
            $0.workspaceID.rawValue == workspaceID
        }) else { throw WorkHostWorkspaceRegistryError.workspaceNotFound }
        return descriptor
    }

    // MARK: Private format and locking

    private struct StoredWorkspace: Codable, Hashable {
        var id: String
        var label: String?
        var isDefault: Bool
        var canonicalPath: String
        var filesystemIdentity: WorkHostWorkspaceFilesystemIdentity
    }

    private struct ValidatedWorkspace: Sendable {
        let url: URL
        let identity: WorkHostWorkspaceFilesystemIdentity
    }

    private struct StoredRegistry: Codable, Hashable {
        var format: String
        var revision: UInt64
        var entries: [StoredWorkspace]

        static func empty() -> StoredRegistry {
            StoredRegistry(format: format, revision: 0, entries: [])
        }

        static let format = "aviary-work-host-workspaces-v2"
    }

    private var registryURL: URL { home.workHostWorkspaceRegistryFile }
    private var lockURL: URL {
        home.root.appending(path: "workspaces.lock", directoryHint: .notDirectory)
    }

    private func rootExists() -> Bool {
        var info = stat()
        return home.root.path.withCString { lstat($0, &info) == 0 }
    }

    private func validateRootIfPresent() throws {
        var info = stat()
        let result = home.root.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else {
                throw WorkHostWorkspaceRegistryError.registryRootUnavailable
            }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw WorkHostWorkspaceRegistryError.registryRootSymlink
            }
            throw WorkHostWorkspaceRegistryError.registryRootUnavailable
        }
        guard info.st_uid == geteuid() else {
            throw WorkHostWorkspaceRegistryError.registryNotPrivate
        }
    }

    private func prepareRootForMutation() throws {
        if !rootExists() {
            do {
                try FileManager.default.createDirectory(
                    at: home.root, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            } catch {
                throw WorkHostWorkspaceRegistryError.registryRootUnavailable
            }
        }
        try validateRootIfPresent()
    }

    private func withExclusiveLock<T>(
        createRoot: Bool,
        _ body: () throws -> T
    ) throws -> T {
        if createRoot {
            try prepareRootForMutation()
        } else {
            try validateRootIfPresent()
        }

        let descriptor = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw WorkHostWorkspaceRegistryError.lockUnavailable
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o077) == 0 else {
            throw WorkHostWorkspaceRegistryError.registryNotPrivate
        }
        return try body()
    }

    private func readStore() throws -> StoredRegistry {
        let descriptor = registryURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return .empty() }
            if errno == ELOOP { throw WorkHostWorkspaceRegistryError.registrySymlink }
            throw WorkHostWorkspaceRegistryError.registryInaccessible
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw WorkHostWorkspaceRegistryError.registryInaccessible
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw WorkHostWorkspaceRegistryError.registryNotRegular
        }
        guard info.st_uid == geteuid(), info.st_mode & mode_t(0o077) == 0 else {
            throw WorkHostWorkspaceRegistryError.registryNotPrivate
        }
        guard info.st_size >= 0,
              info.st_size <= off_t(bounds.maxRecordBytes) else {
            throw WorkHostWorkspaceRegistryError.registryTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Int(info.st_size), bounds.maxRecordBytes))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count <= bounds.maxRecordBytes - count else {
                    throw WorkHostWorkspaceRegistryError.registryTooLarge
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw WorkHostWorkspaceRegistryError.registryInaccessible
            }
        }

        let decoded: StoredRegistry
        do {
            decoded = try JSONDecoder().decode(StoredRegistry.self, from: data)
        } catch {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }
        try validate(decoded)
        return decoded
    }

    private func validate(_ store: StoredRegistry) throws {
        guard store.format == StoredRegistry.format,
              store.revision <= Self.maximumRevision,
              store.entries.count <= bounds.maxEntries else {
            throw WorkHostWorkspaceRegistryError.malformedRegistry
        }

        var IDs = Set<String>()
        var paths = Set<String>()
        var defaults = 0
        for entry in store.entries {
            guard WorkHostWorkspaceID.isValid(entry.id),
                  entry.id.utf8.count <= bounds.maxWorkspaceIDBytes,
                  IDs.insert(entry.id).inserted,
                  Self.isValidLabel(entry.label),
                  (entry.label?.utf8.count ?? 0) <= bounds.maxLabelBytes,
                  entry.canonicalPath.utf8.count <= bounds.maxPathBytes,
                  entry.canonicalPath.hasPrefix("/"),
                  !entry.canonicalPath.unicodeScalars.contains(where: { $0.value == 0 }),
                  entry.filesystemIdentity.inode > 0,
                  entry.filesystemIdentity.type == UInt64(S_IFDIR),
                  Self.isValidVolumeUUID(entry.filesystemIdentity.volumeUUID),
                  paths.insert(entry.canonicalPath).inserted else {
                throw WorkHostWorkspaceRegistryError.malformedRegistry
            }
            if entry.isDefault { defaults += 1 }
        }
        guard defaults <= 1 else { throw WorkHostWorkspaceRegistryError.malformedRegistry }
    }

    private static func isValidVolumeUUID(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value == value.lowercased()
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }

    private func publish(_ store: StoredRegistry) throws {
        try validate(store)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(store)
        } catch {
            throw WorkHostWorkspaceRegistryError.ioFailure
        }
        guard data.count <= bounds.maxRecordBytes else {
            throw WorkHostWorkspaceRegistryError.registryTooLarge
        }

        // Re-read immediately before publication.  A malformed or symlinked destination is
        // never replaced by this store, even if it appeared after the caller's first read.
        _ = try readStore()

        let temporaryURL = home.root.appending(
            path: ".workspaces-\(UUID().uuidString.lowercased()).tmp",
            directoryHint: .notDirectory)
        let descriptor = temporaryURL.path.withCString {
            open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600))
        }
        guard descriptor >= 0 else { throw WorkHostWorkspaceRegistryError.ioFailure }
        defer {
            close(descriptor)
            _ = temporaryURL.path.withCString { unlink($0) }
        }

        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw WorkHostWorkspaceRegistryError.ioFailure
        }

        let renamed = temporaryURL.path.withCString { source in
            registryURL.path.withCString { destination in rename(source, destination) }
        }
        guard renamed == 0 else {
            if errno == ELOOP { throw WorkHostWorkspaceRegistryError.registrySymlink }
            throw WorkHostWorkspaceRegistryError.ioFailure
        }
        try synchronizeDirectory(home.root)

        // Validate the new inode and complete record before acknowledging the mutation.
        _ = try readStore()
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw WorkHostWorkspaceRegistryError.ioFailure
                }
            }
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw WorkHostWorkspaceRegistryError.ioFailure }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw WorkHostWorkspaceRegistryError.ioFailure
        }
    }

    private func mintID(notIn entries: [StoredWorkspace]) throws -> String {
        let IDs = Set(entries.map(\.id))
        for _ in 0..<16 {
            let candidate = WorkHostWorkspaceID.prefix + UUID().uuidString.lowercased()
            guard candidate.utf8.count <= bounds.maxWorkspaceIDBytes else {
                throw WorkHostWorkspaceRegistryError.invalidWorkspaceID
            }
            if !IDs.contains(candidate) { return candidate }
        }
        throw WorkHostWorkspaceRegistryError.ioFailure
    }

    private func nextRevision(after revision: UInt64) throws -> UInt64 {
        guard revision < Self.maximumRevision else {
            throw WorkHostWorkspaceRegistryError.revisionExhausted
        }
        return revision + 1
    }

    private func descriptor(for entry: StoredWorkspace) throws -> WorkHostWorkspaceDescriptor {
        let probe = probeWorkspace(entry.canonicalPath, expectedIdentity: entry.filesystemIdentity)
        return try WorkHostWorkspaceDescriptor(
            workspaceID: try WorkHostWorkspaceID(entry.id),
            label: entry.label,
            isDefault: entry.isDefault,
            availability: probe.availability,
            capabilities: probe.capabilities,
            unavailabilityReason: probe.unavailabilityReason)
    }

    private struct WorkspaceProbe {
        let availability: WorkHostWorkspaceAvailability
        let capabilities: Set<WorkHostWorkspaceCapability>
        let unavailabilityReason: WorkHostWorkspaceUnavailabilityReason?
    }

    private func probeWorkspace(
        _ path: String, expectedIdentity: WorkHostWorkspaceFilesystemIdentity
    ) -> WorkspaceProbe {
        guard path.utf8.count <= bounds.maxPathBytes else {
            return WorkspaceProbe(
                availability: .unavailable, capabilities: [],
                unavailabilityReason: .inaccessible)
        }
        guard let canonical = try? secureWorkspaceURL(
            URL(fileURLWithPath: path), requireWrite: false) else {
            return WorkspaceProbe(
                availability: .unavailable, capabilities: [],
                unavailabilityReason: .inaccessible)
        }
        guard expectedIdentity.identifiesSameResource(as: canonical.identity) else {
            return WorkspaceProbe(
                availability: .unavailable, capabilities: [],
                unavailabilityReason: .identityNeedsConfirmation)
        }
        var capabilities: Set<WorkHostWorkspaceCapability> = [.directory, .resolve]
        if access(canonical.url.path, R_OK) == 0 { capabilities.insert(.read) }
        if access(canonical.url.path, W_OK) == 0 { capabilities.insert(.write) }
        if access(canonical.url.path, X_OK) == 0 { capabilities.insert(.execute) }
        let available = capabilities.contains(.read) && capabilities.contains(.execute)
        return WorkspaceProbe(
            availability: available ? .available : .unavailable,
            capabilities: capabilities,
            unavailabilityReason: available ? nil : .inaccessible)
    }

    private func secureWorkspaceURL(
        _ input: URL, requireWrite: Bool
    ) throws -> ValidatedWorkspace {
        guard input.isFileURL, input.path.hasPrefix("/"), !input.path.isEmpty,
              input.path.utf8.count <= bounds.maxPathBytes,
              !input.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkHostWorkspaceRegistryError.invalidWorkspacePath
        }

        let standardized = input.standardizedFileURL
        // macOS commonly exposes the temp and home trees through system aliases such as
        // `/var`; those parent aliases are harmless.  The requested directory itself must be a
        // real directory, however, and the final no-follow open below closes the replacement
        // race for that component.
        try rejectFinalSymlink(standardized.path)

        var resolvedPointer: UnsafeMutablePointer<CChar>?
        resolvedPointer = standardized.path.withCString { realpath($0, nil) }
        guard let resolvedPointer else {
            throw WorkHostWorkspaceRegistryError.workspaceInaccessible
        }
        defer { free(resolvedPointer) }
        let canonicalPath = String(cString: resolvedPointer)
        guard canonicalPath.utf8.count <= bounds.maxPathBytes else {
            throw WorkHostWorkspaceRegistryError.invalidWorkspacePath
        }

        let descriptor = canonicalPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw WorkHostWorkspaceRegistryError.workspaceSymlink }
            if errno == ENOTDIR { throw WorkHostWorkspaceRegistryError.workspaceNotDirectory }
            throw WorkHostWorkspaceRegistryError.workspaceInaccessible
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw WorkHostWorkspaceRegistryError.workspaceInaccessible
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkHostWorkspaceRegistryError.workspaceNotDirectory
        }
        guard info.st_uid == geteuid() else {
            throw WorkHostWorkspaceRegistryError.workspaceNotOwned
        }
        let requiredAccess = requireWrite ? (R_OK | W_OK | X_OK) : (R_OK | X_OK)
        guard access(canonicalPath, requiredAccess) == 0 else {
            throw WorkHostWorkspaceRegistryError.workspaceInaccessible
        }
        return ValidatedWorkspace(
            url: URL(fileURLWithPath: canonicalPath, isDirectory: true),
            identity: WorkHostWorkspaceFilesystemIdentity(
                device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                type: UInt64(info.st_mode & S_IFMT),
                volumeUUID: persistentVolumeUUID(for: canonicalPath)))
    }

    private func persistentVolumeUUID(for canonicalPath: String) -> String? {
        #if canImport(Darwin)
        // Apple documents `volumeUUIDString` as persistent. The similarly named
        // `volumeIdentifier` and `fileResourceIdentifier` are explicitly not persistent across
        // restarts and therefore cannot replace the raw-device identity that failed here.
        guard let raw = try? URL(fileURLWithPath: canonicalPath, isDirectory: true)
                .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.utf8.count <= 128,
              !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return raw.lowercased()
        #else
        // Linux has no Foundation persistent-volume-UUID contract. Keep the bounded raw
        // st_dev + inode fallback there; explicit confirmation remains available after remount.
        return nil
        #endif
    }

    private func rejectFinalSymlink(_ path: String) throws {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        guard result == 0 else {
            throw WorkHostWorkspaceRegistryError.workspaceInaccessible
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            throw WorkHostWorkspaceRegistryError.workspaceSymlink
        }
    }

    private func validateLabel(_ label: String?) throws {
        guard Self.isValidLabel(label),
              (label?.utf8.count ?? 0) <= bounds.maxLabelBytes else {
            throw WorkHostWorkspaceRegistryError.invalidLabel
        }
    }

    fileprivate static func isValidLabel(_ label: String?) -> Bool {
        guard let label else { return true }
        guard !label.isEmpty,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label == label.trimmingCharacters(in: .whitespacesAndNewlines),
              label.utf8.count <= defaultMaximumLabelBytes else { return false }
        guard !label.unicodeScalars.contains(where: { (scalar: Unicode.Scalar) in
            scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar)
        }) else { return false }
        return !isPathShapedLabel(label)
    }

    /// Labels are display metadata, not a second path transport. Reject separators, URI/file
    /// forms, home expansion, and traversal-looking values at every public model boundary.
    private static func isPathShapedLabel(_ label: String) -> Bool {
        let lowercased = label.lowercased()
        let scalars = Array(label.unicodeScalars)
        let windowsDrivePath = scalars.count >= 2
            && ((scalars[0].value >= 0x41 && scalars[0].value <= 0x5A)
                || (scalars[0].value >= 0x61 && scalars[0].value <= 0x7A))
            && scalars[1].value == 0x3A
        return label.contains("/") || label.contains("\\")
            || label.hasPrefix("~")
            || lowercased.hasPrefix("file:")
            || lowercased.contains("://")
            || label == "." || label == ".."
            || label.hasPrefix("./") || label.hasPrefix("../")
            || lowercased.hasPrefix("$home") || lowercased.hasPrefix("${home}")
            || windowsDrivePath
    }

    private func generatedLabel(for url: URL) -> String {
        let candidate = url.lastPathComponent
        guard Self.isValidLabel(candidate),
              candidate.utf8.count <= bounds.maxLabelBytes else {
            let fallback = "Workspace"
            return String(fallback.prefix(bounds.maxLabelBytes))
        }
        return candidate
    }
}
