import Foundation

// MARK: - Bounded registry values

/// Finite limits for the in-process Work Host registry.
///
/// A registry is a service boundary, so all values that can be supplied by a client are bounded
/// before they become state owned by this actor. The hard ceilings keep a caller from selecting
/// an effectively unbounded custom limit while the smaller configurable limits make it possible
/// for a host to reserve a deliberately small footprint.
public struct WorkHostRegistryBounds: Codable, Hashable, Sendable {
    public static let `default` = WorkHostRegistryBounds()

    public let maxEntries: Int
    public let maxLiveEntries: Int
    public let maxCanonicalEntries: Int
    public let maxPageSize: Int
    public let maxIdentityBytes: Int
    public let maxMetadataBytes: Int

    public init(
        maxEntries: Int = 256,
        maxLiveEntries: Int = 256,
        maxCanonicalEntries: Int = 256,
        maxPageSize: Int = 64,
        maxIdentityBytes: Int = 256,
        maxMetadataBytes: Int = 256
    ) {
        self.maxEntries = max(0, min(maxEntries, 4_096))
        self.maxLiveEntries = max(0, min(maxLiveEntries, 4_096))
        self.maxCanonicalEntries = max(0, min(maxCanonicalEntries, 4_096))
        self.maxPageSize = max(1, min(maxPageSize, 256))
        self.maxIdentityBytes = max(1, min(maxIdentityBytes, 4_096))
        self.maxMetadataBytes = max(1, min(maxMetadataBytes, 4_096))
    }

    private enum CodingKeys: String, CodingKey {
        case maxEntries, maxLiveEntries, maxCanonicalEntries, maxPageSize
        case maxIdentityBytes, maxMetadataBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxEntries: try values.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 256,
            maxLiveEntries: try values.decodeIfPresent(Int.self, forKey: .maxLiveEntries) ?? 256,
            maxCanonicalEntries: try values.decodeIfPresent(Int.self, forKey: .maxCanonicalEntries)
                ?? 256,
            maxPageSize: try values.decodeIfPresent(Int.self, forKey: .maxPageSize) ?? 64,
            maxIdentityBytes: try values.decodeIfPresent(Int.self, forKey: .maxIdentityBytes)
                ?? 256,
            maxMetadataBytes: try values.decodeIfPresent(Int.self, forKey: .maxMetadataBytes)
                ?? 256)
    }
}

public enum WorkHostWorkingDirectoryPolicy: String, Codable, Hashable, Sendable {
    case project
    case workspace
    case temporary
    case agentHome = "agent_home"
    case unspecified
}

/// Launch facts that are safe to carry across the Work Host boundary.
///
/// This type intentionally has no prompt, environment, credential, process, socket, or
/// provider-key field. It contains only bounded display/routing metadata. A truncation marker is
/// retained so a shortened value cannot be mistaken for the complete launch record.
public struct WorkHostLaunchMetadata: Codable, Hashable, Sendable {
    private static let defaultMaximumBytes = 256

    public let providerID: String?
    public let modelID: String?
    /// Opaque host-minted workspace identity. A descriptor may carry this identity, but never
    /// the host-local path it resolves to.
    public let workspaceID: WorkHostWorkspaceID?
    public let runtimeHostKind: String?
    public let actorKind: String?
    public let metadataWasTruncated: Bool

    public init(
        providerID: String? = nil,
        modelID: String? = nil,
        workspaceID: WorkHostWorkspaceID? = nil,
        runtimeHostKind: String? = nil,
        actorKind: String? = nil
    ) {
        self.init(
            providerID: providerID,
            modelID: modelID,
            workspaceID: workspaceID,
            runtimeHostKind: runtimeHostKind,
            actorKind: actorKind,
            metadataWasTruncated: false,
            maximumBytes: Self.defaultMaximumBytes)
    }

    private init(
        providerID: String?,
        modelID: String?,
        workspaceID: WorkHostWorkspaceID?,
        runtimeHostKind: String?,
        actorKind: String?,
        metadataWasTruncated: Bool,
        maximumBytes: Int
    ) {
        let provider = Self.bound(providerID, maximumBytes: maximumBytes)
        let model = Self.bound(modelID, maximumBytes: maximumBytes)
        let runtime = Self.bound(runtimeHostKind, maximumBytes: maximumBytes)
        let actor = Self.bound(actorKind, maximumBytes: maximumBytes)
        self.providerID = provider.value
        self.modelID = model.value
        self.workspaceID = workspaceID
        self.runtimeHostKind = runtime.value
        self.actorKind = actor.value
        self.metadataWasTruncated = metadataWasTruncated
            || provider.wasTruncated
            || model.wasTruncated
            || runtime.wasTruncated
            || actor.wasTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, modelID, workspaceID, runtimeHostKind, actorKind
        case metadataWasTruncated
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let encodedWasTruncated = try values.decodeIfPresent(
            Bool.self, forKey: .metadataWasTruncated) ?? false
        self.init(
            providerID: try values.decodeIfPresent(String.self, forKey: .providerID),
            modelID: try values.decodeIfPresent(String.self, forKey: .modelID),
            workspaceID: try values.decodeIfPresent(
                WorkHostWorkspaceID.self, forKey: .workspaceID),
            runtimeHostKind: try values.decodeIfPresent(String.self, forKey: .runtimeHostKind),
            actorKind: try values.decodeIfPresent(String.self, forKey: .actorKind),
            metadataWasTruncated: encodedWasTruncated,
            maximumBytes: Self.defaultMaximumBytes)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(providerID, forKey: .providerID)
        try values.encodeIfPresent(modelID, forKey: .modelID)
        try values.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try values.encodeIfPresent(runtimeHostKind, forKey: .runtimeHostKind)
        try values.encodeIfPresent(actorKind, forKey: .actorKind)
        try values.encode(metadataWasTruncated, forKey: .metadataWasTruncated)
    }

    fileprivate func bounded(to maximumBytes: Int) -> WorkHostLaunchMetadata {
        guard maximumBytes < Self.defaultMaximumBytes else { return self }
        return WorkHostLaunchMetadata(
            providerID: providerID,
            modelID: modelID,
            workspaceID: workspaceID,
            runtimeHostKind: runtimeHostKind,
            actorKind: actorKind,
            metadataWasTruncated: metadataWasTruncated,
            maximumBytes: maximumBytes)
    }

    private static func bound(
        _ value: String?, maximumBytes: Int
    ) -> (value: String?, wasTruncated: Bool) {
        guard let value else { return (nil, false) }
        guard value.utf8.count > maximumBytes else { return (value, false) }
        return (boundedUTF8(value, maximumBytes: maximumBytes), true)
    }
}

private func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    var result = String()
    result.reserveCapacity(maximumBytes)
    var used = 0
    for scalar in value.unicodeScalars {
        let scalarBytes = String(scalar).utf8.count
        guard used + scalarBytes <= maximumBytes else { break }
        result.unicodeScalars.append(scalar)
        used += scalarBytes
    }
    return result
}

/// A canonical fact imported from durable history or a recovery/catalog scan.
///
/// These dispositions are observations about recorded source state. They do not assert that the
/// Work Host process, endpoint, or RuntimeHost is alive. An optional instance identifies the
/// generation that produced the fact; it is not a liveness proof.
public enum WorkHostRegistryCanonicalDisposition: String, Codable, Hashable, Sendable {
    case historical
    case recovering
    case unavailable
}

public struct WorkHostRegistryCanonicalFact: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let disposition: WorkHostRegistryCanonicalDisposition
    public let sourceID: String
    public let hostInstance: WorkHostInstanceRef?
    public let launchMetadata: WorkHostLaunchMetadata?
    public let recordedAt: Date

    public init(
        work: WorkRef,
        disposition: WorkHostRegistryCanonicalDisposition,
        sourceID: String,
        hostInstance: WorkHostInstanceRef? = nil,
        launchMetadata: WorkHostLaunchMetadata? = nil,
        recordedAt: Date = Date()
    ) {
        self.work = work
        self.disposition = disposition
        self.sourceID = boundedUTF8(sourceID, maximumBytes: 256)
        self.hostInstance = hostInstance
        self.launchMetadata = launchMetadata
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey {
        case work, disposition, sourceID, hostInstance, launchMetadata, recordedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            work: try values.decode(WorkRef.self, forKey: .work),
            disposition: try values.decode(
                WorkHostRegistryCanonicalDisposition.self, forKey: .disposition),
            sourceID: try values.decode(String.self, forKey: .sourceID),
            hostInstance: try values.decodeIfPresent(
                WorkHostInstanceRef.self, forKey: .hostInstance),
            launchMetadata: try values.decodeIfPresent(
                WorkHostLaunchMetadata.self, forKey: .launchMetadata),
            recordedAt: try values.decode(Date.self, forKey: .recordedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(work, forKey: .work)
        try values.encode(disposition, forKey: .disposition)
        try values.encode(sourceID, forKey: .sourceID)
        try values.encodeIfPresent(hostInstance, forKey: .hostInstance)
        try values.encodeIfPresent(launchMetadata, forKey: .launchMetadata)
        try values.encode(recordedAt, forKey: .recordedAt)
    }
}

/// The errors that keep the registry fail-closed at identity, capacity, and lifetime seams.
public enum WorkHostRegistryError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidIdentity(String)
    case hostMismatch(expected: WorkHostRef, actual: WorkHostRef)
    case divergentRegistration(expected: WorkRef, actual: WorkRef)
    case duplicateRegistration(WorkRef)
    case registrationConflict(WorkRef)
    case divergentCanonicalFact(WorkRef)
    case capacityExceeded
    case liveCapacityExceeded
    case canonicalCapacityExceeded
    case invalidPageSize(requested: Int, maximum: Int)
    case invalidPageToken
    case workNotFound(WorkRef)
    case notLive(WorkRef)
    case invalidTerminalProof(WorkRef)
    case notTerminalized(WorkRef, lifecycle: HostedInHouseWorkLifecycle)
    case terminalSnapshotMismatch(WorkRef)
    case invalidReplacement(WorkRef, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Invalid Work Host registry configuration: " + detail
        case .invalidIdentity(let detail):
            return "Invalid Work Host registry identity: " + detail
        case .hostMismatch(let expected, let actual):
            return "Work Host mismatch (expected " + expected.workHostID
                + ", got " + actual.workHostID + ")."
        case .divergentRegistration(let expected, let actual):
            return "Hosted Work identity diverges from registration key ("
                + expected.workID + " vs " + actual.workID + ")."
        case .duplicateRegistration(let work):
            return "Work is already registered: " + work.workHostID + "/" + work.workID + "."
        case .registrationConflict(let work):
            return "Work identity is already occupied by a canonical registry fact: "
                + work.workHostID + "/" + work.workID + "."
        case .divergentCanonicalFact(let work):
            return "Canonical registry fact diverges for Work: "
                + work.workHostID + "/" + work.workID + "."
        case .capacityExceeded:
            return "Work Host registry capacity is exhausted."
        case .liveCapacityExceeded:
            return "Live Work Host registry capacity is exhausted."
        case .canonicalCapacityExceeded:
            return "Canonical Work Host registry capacity is exhausted."
        case .invalidPageSize(let requested, let maximum):
            return "Registry page size " + String(requested)
                + " is outside 1..." + String(maximum) + "."
        case .invalidPageToken:
            return "Invalid Work Host registry page token."
        case .workNotFound(let work):
            return "Work is not registered: " + work.workHostID + "/" + work.workID + "."
        case .notLive(let work):
            return "Work is canonical history, not a live registry entry: "
                + work.workHostID + "/" + work.workID + "."
        case .invalidTerminalProof(let work):
            return "Canonical Work terminal proof is invalid: "
                + work.workHostID + "/" + work.workID + "."
        case .notTerminalized(let work, let lifecycle):
            return "Work cannot be released before explicit terminalization ("
                + work.workID + " is " + lifecycle.rawValue + ")."
        case .terminalSnapshotMismatch(let work):
            return "Hosted Work snapshot identity did not match the registry key: "
                + work.workID + "."
        case .invalidReplacement(let work, let reason):
            return "Hosted Work replacement is invalid for " + work.workID + ": " + reason
        }
    }
}

/// A live registration. `hostedWork` is the service-owned actor reference; the registry retains
/// another strong reference in its actor-isolated storage even when no client holds this value.
/// The word live means registered in this in-process service, not that a runtime process is alive.
public struct WorkHostRegistryLiveEntry: Sendable {
    public let work: WorkRef
    public let hostedWork: HostedInHouseWork
    public let hostInstance: WorkHostInstanceRef
    public let launchMetadata: WorkHostLaunchMetadata
    public let registeredAt: Date
}

/// A fenced slot reservation used when opening a Hosted Work can suspend.  The reservation is
/// counted against live/total bounds and prevents another registry mutation from occupying the
/// Work while the service materializes the actor.  It is deliberately opaque to callers: only
/// the registry that minted it can commit or cancel the token.
public struct WorkHostRegistryRegistrationReservation: Hashable, Sendable {
    public let work: WorkRef
    public let launchMetadata: WorkHostLaunchMetadata
    fileprivate let token: String

    fileprivate init(
        work: WorkRef,
        launchMetadata: WorkHostLaunchMetadata,
        token: String
    ) {
        self.work = work
        self.launchMetadata = launchMetadata
        self.token = token
    }
}

public enum WorkHostRegistryEntryKind: String, Codable, Hashable, Sendable {
    case liveRegistered = "live_registered"
    case historical
    case recovering
    case unavailable
}

/// A lookup/list result keeps live ownership separate from durable canonical facts.
public enum WorkHostRegistryLookup: Sendable {
    case live(WorkHostRegistryLiveEntry)
    case historical(WorkHostRegistryCanonicalFact)
    case recovering(WorkHostRegistryCanonicalFact)
    case unavailable(WorkHostRegistryCanonicalFact)

    public var work: WorkRef {
        switch self {
        case .live(let entry): return entry.work
        case .historical(let fact), .recovering(let fact), .unavailable(let fact):
            return fact.work
        }
    }

    public var kind: WorkHostRegistryEntryKind {
        switch self {
        case .live: return .liveRegistered
        case .historical: return .historical
        case .recovering: return .recovering
        case .unavailable: return .unavailable
        }
    }

    public var isLiveRegistration: Bool {
        if case .live = self { return true }
        return false
    }
}

public struct WorkHostRegistryPage: Sendable {
    public let entries: [WorkHostRegistryLookup]
    public let nextPageToken: String?
    public let totalCount: Int
    public let remainingCount: Int

    public var hasMore: Bool { nextPageToken != nil }
}

public struct WorkHostRegistryReleaseReceipt: Codable, Hashable, Sendable {
    public let work: WorkRef
    public let hostInstance: WorkHostInstanceRef
    public let terminalLifecycle: HostedInHouseWorkLifecycle
    public let terminalOperation: WorkServiceTerminalOperation
    public let released: Bool

    fileprivate init(
        work: WorkRef,
        hostInstance: WorkHostInstanceRef,
        terminalLifecycle: HostedInHouseWorkLifecycle,
        terminalOperation: WorkServiceTerminalOperation
    ) {
        self.work = work
        self.hostInstance = hostInstance
        self.terminalLifecycle = terminalLifecycle
        self.terminalOperation = terminalOperation
        self.released = true
    }
}

// MARK: - Registry

/// The in-process owner for one logical Work Host's live HostedInHouseWork actors.
///
/// The registry is deliberately independent of clients: subscriptions belong to the hosted Work
/// actor, while this actor owns the Work's service lifetime. Disconnecting a GUI therefore cannot
/// remove, cancel, or otherwise mutate a registration. Durable historical/recovering/unavailable
/// facts may coexist in the registry namespace, but a full WorkRef can never name both a live
/// actor and a canonical fact at once.
public actor WorkHostRegistry {
    private static let maxProofIdentityBytes = 256

    public let host: WorkHostRef
    public let hostInstance: WorkHostInstanceRef
    public let bounds: WorkHostRegistryBounds

    private let initializationError: WorkHostRegistryError?
    private var live: [WorkRef: WorkHostRegistryLiveEntry] = [:]
    private var canonical: [WorkRef: WorkHostRegistryCanonicalFact] = [:]
    private var registrationReservations: [WorkRef: WorkHostRegistryRegistrationReservation] = [:]
    /// A replacement holds the logical Work slot while its new Run actor is being opened. This
    /// prevents a concurrent release from converting the old ended actor to history underneath
    /// the replacement's identity checks.
    private var replacementsInProgress: Set<WorkRef> = []

    /// Create a registry for one stable logical Work Host and one process/start generation.
    /// Defaults are generated once here and remain stable for the registry's lifetime.
    public init(
        host: WorkHostRef,
        instanceID: String = "instance-" + AviarySecureRandom.uuidString(),
        startIdentity: String = "start-" + AviarySecureRandom.uuidString(),
        bounds: WorkHostRegistryBounds = .default
    ) {
        self.host = host
        self.hostInstance = WorkHostInstanceRef(
            host: host, instanceID: instanceID, startIdentity: startIdentity)
        self.bounds = bounds
        self.initializationError = Self.configurationError(
            host: host, hostInstance: self.hostInstance, bounds: bounds)
    }

    /// Use an already allocated stable host-instance identity, for example one returned by a
    /// service handshake. The identity is retained exactly and is never replaced by a lookup.
    public init(
        hostInstance: WorkHostInstanceRef,
        bounds: WorkHostRegistryBounds = .default
    ) {
        self.host = hostInstance.host
        self.hostInstance = hostInstance
        self.bounds = bounds
        self.initializationError = Self.configurationError(
            host: hostInstance.host, hostInstance: hostInstance, bounds: bounds)
    }

    /// Register one actor under its complete Work identity. `key` is optional only to make the
    /// normal path concise; when supplied it is checked against the actor's nonisolated identity
    /// before any state is changed, which makes divergent registration explicit and fail-closed.
    @discardableResult
    public func register(
        _ hostedWork: HostedInHouseWork,
        key: WorkRef? = nil,
        launchMetadata: WorkHostLaunchMetadata = .init()
    ) throws -> WorkHostRegistryLiveEntry {
        try ensureConfigured()
        let actorWork = hostedWork.identity.work
        let work = key ?? actorWork
        guard work == actorWork else {
            throw WorkHostRegistryError.divergentRegistration(expected: actorWork, actual: work)
        }
        try validateWork(work)
        guard work.workHostID == host.workHostID else {
            throw WorkHostRegistryError.hostMismatch(
                expected: host, actual: WorkHostRef(work.workHostID))
        }
        guard registrationReservations[work] == nil else {
            throw WorkHostRegistryError.registrationConflict(work)
        }
        guard live[work] == nil else {
            throw WorkHostRegistryError.duplicateRegistration(work)
        }
        guard canonical[work] == nil else {
            throw WorkHostRegistryError.registrationConflict(work)
        }
        guard live.count < bounds.maxLiveEntries else {
            throw WorkHostRegistryError.liveCapacityExceeded
        }
        guard live.count + canonical.count < bounds.maxEntries else {
            throw WorkHostRegistryError.capacityExceeded
        }

        let entry = WorkHostRegistryLiveEntry(
            work: work,
            hostedWork: hostedWork,
            hostInstance: hostInstance,
            launchMetadata: launchMetadata.bounded(to: bounds.maxMetadataBytes),
            registeredAt: Date())
        live[work] = entry
        return entry
    }

    /// Reserve a live registry slot before opening a Hosted actor.  Hosted construction writes
    /// durable run evidence and may fail or suspend; keeping this reservation in the actor makes
    /// capacity and Work identity checks atomic across that await.
    public func reserveRegistration(
        for work: WorkRef,
        launchMetadata: WorkHostLaunchMetadata = .init()
    ) throws -> WorkHostRegistryRegistrationReservation {
        try ensureConfigured()
        try validateWork(work)
        guard work.workHostID == host.workHostID else {
            throw WorkHostRegistryError.hostMismatch(
                expected: host, actual: WorkHostRef(work.workHostID))
        }
        guard live[work] == nil, canonical[work] == nil,
              registrationReservations[work] == nil else {
            throw WorkHostRegistryError.registrationConflict(work)
        }
        guard live.count + registrationReservations.count < bounds.maxLiveEntries else {
            throw WorkHostRegistryError.liveCapacityExceeded
        }
        guard live.count + canonical.count + registrationReservations.count < bounds.maxEntries else {
            throw WorkHostRegistryError.capacityExceeded
        }
        let reservation = WorkHostRegistryRegistrationReservation(
            work: work,
            launchMetadata: launchMetadata.bounded(to: bounds.maxMetadataBytes),
            token: AviarySecureRandom.uuidString())
        registrationReservations[work] = reservation
        return reservation
    }

    /// Commit an actor into an exact preflight reservation.  Once the token is valid, no
    /// capacity/conflict check can fail because the slot was counted when it was reserved.
    @discardableResult
    public func commitRegistration(
        _ reservation: WorkHostRegistryRegistrationReservation,
        hostedWork: HostedInHouseWork
    ) throws -> WorkHostRegistryLiveEntry {
        try ensureConfigured()
        guard let current = registrationReservations[reservation.work],
              current == reservation else {
            throw WorkHostRegistryError.registrationConflict(reservation.work)
        }
        guard hostedWork.identity.work == reservation.work else {
            throw WorkHostRegistryError.divergentRegistration(
                expected: reservation.work, actual: hostedWork.identity.work)
        }
        guard reservation.work.workHostID == host.workHostID,
              live[reservation.work] == nil,
              canonical[reservation.work] == nil else {
            throw WorkHostRegistryError.registrationConflict(reservation.work)
        }
        registrationReservations.removeValue(forKey: reservation.work)
        let entry = WorkHostRegistryLiveEntry(
            work: reservation.work,
            hostedWork: hostedWork,
            hostInstance: hostInstance,
            launchMetadata: reservation.launchMetadata,
            registeredAt: Date())
        live[reservation.work] = entry
        return entry
    }

    /// Cancel an exact reservation after Hosted construction failed or was rejected.  A stale or
    /// foreign token is intentionally a no-op so cleanup cannot mutate another admission.
    public func cancelRegistration(
        _ reservation: WorkHostRegistryRegistrationReservation
    ) {
        guard registrationReservations[reservation.work] == reservation else { return }
        registrationReservations.removeValue(forKey: reservation.work)
    }

    /// Import one canonical non-live fact after a catalog/recovery reader has validated its
    /// durable source. This is intentionally module-internal: a public assertion DTO must not be
    /// enough for an external caller to manufacture recovery truth or host liveness.
    func registerCanonical(_ fact: WorkHostRegistryCanonicalFact) throws {
        try ensureConfigured()
        try validateWork(fact.work)
        guard fact.work.workHostID == host.workHostID else {
            throw WorkHostRegistryError.hostMismatch(
                expected: host, actual: WorkHostRef(fact.work.workHostID))
        }
        guard registrationReservations[fact.work] == nil else {
            throw WorkHostRegistryError.registrationConflict(fact.work)
        }
        guard validSourceID(fact.sourceID) else {
            throw WorkHostRegistryError.invalidIdentity("canonical source identity")
        }
        if let instance = fact.hostInstance {
            guard validHostInstance(instance), instance.host.workHostID == fact.work.workHostID else {
                throw WorkHostRegistryError.hostMismatch(
                    expected: WorkHostRef(fact.work.workHostID), actual: instance.host)
            }
        }
        guard live[fact.work] == nil else {
            throw WorkHostRegistryError.registrationConflict(fact.work)
        }
        let boundedFact = WorkHostRegistryCanonicalFact(
            work: fact.work,
            disposition: fact.disposition,
            sourceID: fact.sourceID,
            hostInstance: fact.hostInstance,
            launchMetadata: fact.launchMetadata?.bounded(to: bounds.maxMetadataBytes),
            recordedAt: fact.recordedAt)
        if let previous = canonical[fact.work] {
            if previous == boundedFact {
                throw WorkHostRegistryError.duplicateRegistration(fact.work)
            }
            throw WorkHostRegistryError.divergentCanonicalFact(fact.work)
        }
        guard canonical.count < bounds.maxCanonicalEntries else {
            throw WorkHostRegistryError.canonicalCapacityExceeded
        }
        // Release is a one-for-one live-slot conversion. It must remain possible even when the
        // historical category is already at its admission bound; otherwise an ended Work could
        // be stranded forever solely because canonical history filled after the live slot was
        // admitted.
        guard live.count + canonical.count < bounds.maxEntries else {
            throw WorkHostRegistryError.capacityExceeded
        }
        canonical[fact.work] = boundedFact
    }

    /// Look up one full Work identity. A malformed identity is simply not addressable; no
    /// partially normalized key is ever used.
    public func lookup(_ work: WorkRef) -> WorkHostRegistryLookup? {
        guard isValidWork(work), work.workHostID == host.workHostID else { return nil }
        return lookupUnchecked(work)
    }

    /// Remove one exact disposable recovery observation after its caller has independently
    /// revalidated canonical source and reconstruction material. This is deliberately a
    /// synchronous actor-local compare-and-swap: it can never remove a live actor, reservation,
    /// historical fact, or unavailable fact, and a concurrent registry change simply returns
    /// false.
    @discardableResult
    func discardRecoveringFact(
        _ work: WorkRef,
        expected: WorkHostRegistryCanonicalFact
    ) -> Bool {
        guard isValidWork(work), work.workHostID == host.workHostID,
              expected.work == work, expected.disposition == .recovering,
              live[work] == nil, registrationReservations[work] == nil,
              canonical[work] == expected else { return false }
        canonical.removeValue(forKey: work)
        return true
    }

    /// Return a deterministic, bounded page over live registrations and canonical facts.
    /// Tokens are opaque to callers and carry only a bounded offset; they are not capabilities.
    public func list(
        limit: Int = WorkHostRegistryBounds.default.maxPageSize,
        pageToken: String? = nil
    ) throws -> WorkHostRegistryPage {
        try ensureConfigured()
        guard limit > 0, limit <= bounds.maxPageSize else {
            throw WorkHostRegistryError.invalidPageSize(
                requested: limit, maximum: bounds.maxPageSize)
        }
        let allKeys = orderedKeys()
        let offset = try Self.parsePageToken(pageToken, totalCount: allKeys.count)
        let pageKeys = Array(allKeys.dropFirst(offset).prefix(limit))
        let nextOffset = offset + pageKeys.count
        let next = nextOffset < allKeys.count ? Self.pageToken(nextOffset) : nil
        let entries = pageKeys.compactMap { lookupUnchecked($0) }
        return WorkHostRegistryPage(
            entries: entries,
            nextPageToken: next,
            totalCount: allKeys.count,
            remainingCount: allKeys.count - nextOffset)
    }

    /// Release only an actor whose own native lifecycle has reached explicit, durably closed End
    /// and whose Work has a canonical complete/destroy terminal proof. End alone terminalizes only
    /// the current Run and leaves Work reusable, so it is intentionally insufficient here.
    /// GUI detachment, runtime disconnect, failed setup, and disappearance of client references
    /// do not satisfy this gate. The live actor slot is converted to canonical history only after
    /// the registry rechecks that the snapshot still belongs to the registration observed before
    /// the await; the canonical fact carries no host-liveness claim.
    @discardableResult
    public func release(
        _ work: WorkRef,
        terminalProof: WorkServiceTerminalCommitProof
    ) async throws -> WorkHostRegistryReleaseReceipt {
        try ensureConfigured()
        guard isValidWork(work), work.workHostID == host.workHostID else {
            throw WorkHostRegistryError.invalidIdentity("release Work identity")
        }
        guard !replacementsInProgress.contains(work) else {
            throw WorkHostRegistryError.invalidReplacement(
                work, reason: "another Run replacement is in progress")
        }
        guard Self.validTerminalProof(
            terminalProof, for: work, maximumIdentityBytes: bounds.maxIdentityBytes) else {
            throw WorkHostRegistryError.invalidTerminalProof(work)
        }
        guard let entry = live[work] else {
            if canonical[work] != nil { throw WorkHostRegistryError.notLive(work) }
            throw WorkHostRegistryError.workNotFound(work)
        }

        let snapshot = await entry.hostedWork.snapshot()
        guard snapshot.identity.work == work,
              snapshot.identity.sessionID == terminalProof.session.sessionID,
              snapshot.sessionAttachment == terminalProof.sessionAttachment else {
            throw WorkHostRegistryError.terminalSnapshotMismatch(work)
        }
        guard snapshot.lifecycle == .ended else {
            throw WorkHostRegistryError.notTerminalized(work, lifecycle: snapshot.lifecycle)
        }
        // A Hosted End may have durably committed `run.finished` while a close reports an
        // infrastructure error. The actor's canonical read-only verifier is the authority for
        // release; it also keeps the native close failure visible in the snapshot instead of
        // treating a presentation/close DTO as terminal truth.
        guard await entry.hostedWork.verifyCanonicalTerminalProof(terminalProof) else {
            throw WorkHostRegistryError.invalidTerminalProof(work)
        }
        // A concurrent release may have removed the entry while the snapshot call suspended.
        // Compare actor identity rather than just the WorkRef so a future replacement cannot be
        // mistaken for the registration that was terminalized.
        guard let current = live[work],
              ObjectIdentifier(current.hostedWork) == ObjectIdentifier(entry.hostedWork)
        else {
            throw WorkHostRegistryError.workNotFound(work)
        }
        // This is an atomic one-for-one conversion of an already admitted live slot. The
        // canonical category bound applies to standalone history admission, not to converting a
        // live Work that must remain discoverable after terminalization. Rejecting here would
        // strand an ended Work solely because history happened to fill after the live slot was
        // reserved.
        let terminalSourceID = "terminal-event:" + terminalProof.terminalEvent.eventID
            + ":" + terminalProof.terminalEvent.journal.stableKey
        let historicalFact = WorkHostRegistryCanonicalFact(
            work: work,
            disposition: .historical,
            sourceID: boundedUTF8(terminalSourceID, maximumBytes: bounds.maxIdentityBytes),
            hostInstance: entry.hostInstance,
            launchMetadata: entry.launchMetadata,
            recordedAt: Date())
        live.removeValue(forKey: work)
        canonical[work] = historicalFact
        return WorkHostRegistryReleaseReceipt(
            work: work, hostInstance: entry.hostInstance,
            terminalLifecycle: snapshot.lifecycle,
            terminalOperation: terminalProof.operation)
    }

    /// Replace an ended Run actor with a fresh Run actor against the same reusable Work. The
    /// logical Work slot remains live throughout the bounded operation; only the per-Run actor
    /// changes. The old actor must have completed explicit End and closed its writers, and the
    /// The old actor's terminal boundary is verified before the slot is replaced. The next Run
    /// may be selected by a different canonical Session/attachment on the same Work.
    @discardableResult
    public func replace(
        _ work: WorkRef,
        configuration: HostedInHouseWorkConfiguration,
        launchMetadata: WorkHostLaunchMetadata? = nil
    ) async throws -> WorkHostRegistryLiveEntry {
        try ensureConfigured()
        guard isValidWork(work), work.workHostID == host.workHostID else {
            throw WorkHostRegistryError.invalidIdentity("replacement Work identity")
        }
        guard let entry = live[work] else {
            if canonical[work] != nil { throw WorkHostRegistryError.notLive(work) }
            throw WorkHostRegistryError.workNotFound(work)
        }
        guard !replacementsInProgress.contains(work) else {
            throw WorkHostRegistryError.invalidReplacement(
                work, reason: "another Run replacement is in progress")
        }
        replacementsInProgress.insert(work)
        defer { replacementsInProgress.remove(work) }

        let oldSnapshot = await entry.hostedWork.snapshot()
        guard oldSnapshot.lifecycle == .ended, oldSnapshot.journalHealth == .closed else {
            throw WorkHostRegistryError.invalidReplacement(
                work, reason: "the previous Run actor must be ended and closed")
        }
        let binding = configuration.workRunBinding
        guard binding.workBinding.work == work,
              binding.workBinding.workHost == host else {
            throw WorkHostRegistryError.invalidReplacement(
                work, reason: "replacement must preserve Work and host identity")
        }
        guard binding.run.runID != oldSnapshot.identity.runID else {
            throw WorkHostRegistryError.invalidReplacement(
                work, reason: "replacement Run identity must be new")
        }
        let sameSessionBoundary = binding.workBinding.session
            == SessionRef(oldSnapshot.identity.sessionID)
            && binding.workBinding.sessionAttachment == oldSnapshot.sessionAttachment
        if sameSessionBoundary {
            guard configuration.projectionMode == .reopenHistorical else {
                throw WorkHostRegistryError.invalidReplacement(
                    work, reason: "same-Session replacement must reopen its historical projection")
            }
        } else {
            // A canonically attached replacement Session may have no legacy flat projection yet.
            // Its native Session/Work journals are still the durable attachment boundary, so a
            // different owner must launch a fresh projection rather than being rejected for the
            // absence of a file that was never part of Session attachment publication.
            guard configuration.modelContextMode == .launchFresh,
                  (configuration.projectionMode == .fresh
                      || configuration.projectionMode == .reopenHistorical) else {
                throw WorkHostRegistryError.invalidReplacement(
                    work, reason: "cross-Session replacement must use launch-fresh context")
            }
        }

        let replacement = try await HostedInHouseWork.open(configuration: configuration)
        // The in-progress reservation above makes this the only mutator that can change this
        // slot. Keep the identity check anyway: it turns a future registry edit into a safe
        // failure instead of silently swapping a different Work actor.
        guard let current = live[work],
              ObjectIdentifier(current.hostedWork) == ObjectIdentifier(entry.hostedWork) else {
            await closeUnadoptedReplacement(replacement)
            throw WorkHostRegistryError.invalidReplacement(
                work, reason: "the live Work slot changed while opening the replacement")
        }
        let replacementEntry = WorkHostRegistryLiveEntry(
            work: work,
            hostedWork: replacement,
            hostInstance: entry.hostInstance,
            launchMetadata: (launchMetadata ?? entry.launchMetadata).bounded(
                to: bounds.maxMetadataBytes),
            registeredAt: Date())
        live[work] = replacementEntry
        return replacementEntry
    }

    /// A replacement is opened outside this actor's isolation. The reservation makes a slot
    /// change impossible through the current API, but keep the post-open guard defensive: if a
    /// future mutator invalidates it, explicitly End the new actor so its native writers/runtime
    /// cannot leak after the actor is discarded.
    private func closeUnadoptedReplacement(_ replacement: HostedInHouseWork) async {
        let snapshot = await replacement.snapshot()
        guard snapshot.lifecycle != .ended,
              let causalCursor = snapshot.latestWorkCursor else { return }
        let command = HostedInHouseWorkCommand(
            work: snapshot.identity.work,
            session: SessionRef(snapshot.identity.sessionID),
            sessionAttachment: snapshot.sessionAttachment,
            client: ClientRef("work-host-registry-cleanup"),
            commandID: "registry-replacement-cleanup-" + UUID().uuidString.lowercased(),
            causalCursor: causalCursor,
            command: .endRun)
        _ = try? await replacement.submit(command)
    }

    public var count: Int { live.count + canonical.count }
    public var liveCount: Int { live.count }
    public var canonicalCount: Int { canonical.count }

    // MARK: Internal validation and ordering

    private func ensureConfigured() throws {
        if let initializationError { throw initializationError }
    }

    private func validateWork(_ work: WorkRef) throws {
        guard isValidWork(work) else {
            throw WorkHostRegistryError.invalidIdentity("Work identity")
        }
    }

    private func isValidWork(_ work: WorkRef) -> Bool {
        validIdentity(work.workHostID) && validIdentity(work.workID)
    }

    private func validSourceID(_ sourceID: String) -> Bool {
        validIdentity(sourceID)
    }

    private func validIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && value.utf8.count <= bounds.maxIdentityBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private func validHostInstance(_ instance: WorkHostInstanceRef) -> Bool {
        validIdentity(instance.host.workHostID)
            && validIdentity(instance.instanceID)
            && validIdentity(instance.startIdentity)
    }

    private func lookupUnchecked(_ work: WorkRef) -> WorkHostRegistryLookup? {
        if let entry = live[work] { return .live(entry) }
        guard let fact = canonical[work] else { return nil }
        switch fact.disposition {
        case .historical: return .historical(fact)
        case .recovering: return .recovering(fact)
        case .unavailable: return .unavailable(fact)
        }
    }

    private func orderedKeys() -> [WorkRef] {
        Set(live.keys).union(canonical.keys).sorted { lhs, rhs in
            if lhs.workHostID != rhs.workHostID { return lhs.workHostID < rhs.workHostID }
            return lhs.workID < rhs.workID
        }
    }

    private static func validTerminalProof(
        _ proof: WorkServiceTerminalCommitProof,
        for work: WorkRef,
        maximumIdentityBytes: Int
    ) -> Bool {
        let proofIdentityBytes = min(maximumIdentityBytes, maxProofIdentityBytes)
        let expectedCausalEvent = proof.causalWorkCursor.eventID.map {
            EventRef(journal: proof.journal, eventID: $0)
        }
        guard proof.work == work,
              proof.journal == JournalRef.work(work),
              validProofIdentity(work.workHostID, maximumBytes: proofIdentityBytes),
              validProofIdentity(work.workID, maximumBytes: proofIdentityBytes),
              validProofIdentity(proof.command.commandID, maximumBytes: proofIdentityBytes),
              let client = proof.command.client,
              validProofIdentity(client.clientID, maximumBytes: proofIdentityBytes),
              proof.command.sessionAttachment == proof.sessionAttachment,
              proof.command.causalCursor == proof.causalWorkCursor,
              proof.causalWorkCursor.journal == proof.journal,
              proof.causalWorkCursor.sequence >= 0,
              proof.causalWorkCursor.sequence < Int.max,
              validProofIdentity(
                  proof.causalWorkCursor.eventID ?? "", maximumBytes: proofIdentityBytes),
              proof.resultingWorkCursor.journal == proof.journal,
              proof.resultingWorkCursor.sequence == proof.causalWorkCursor.sequence + 1,
              validProofIdentity(
                  proof.resultingWorkCursor.eventID ?? "", maximumBytes: proofIdentityBytes),
              proof.terminalEvent.journal == proof.resultingWorkCursor.journal,
              proof.terminalEvent.sequence == proof.resultingWorkCursor.sequence,
              proof.terminalEvent.eventID == proof.resultingWorkCursor.eventID,
              proof.terminalEvent.command == proof.command,
              proof.terminalEvent.work == proof.work,
              proof.terminalEvent.workHost == WorkHostRef(work.workHostID),
              proof.terminalEvent.session == proof.session,
              proof.terminalEvent.client == client,
              proof.terminalEvent.sessionAttachment == proof.sessionAttachment,
              proof.terminalEvent.causedByEventID == expectedCausalEvent,
              proof.terminalEvent.provenance == .native,
              validProofIdentity(proof.session.sessionID, maximumBytes: proofIdentityBytes),
              proof.sessionJournal == JournalRef.session(
                  proof.session, authority: TimelineAuthorityRef(work.workHostID)),
              proof.sessionJournal.owner == .session(proof.session),
              proof.sessionAttachment.attachmentID.isEmpty == false,
              validProofIdentity(
                  proof.sessionAttachment.attachmentID, maximumBytes: proofIdentityBytes),
              let paired = proof.pairedSessionCursor,
              paired.journal == proof.sessionJournal,
              paired.sequence >= 0,
              validProofIdentity(paired.eventID ?? "", maximumBytes: proofIdentityBytes),
              proof.sessionPairingVerified,
              proof.outstandingHandleIDs.isEmpty,
              validProofIdentity(proof.commitID, maximumBytes: proofIdentityBytes) else {
            return false
        }
        switch proof.operation {
        case .complete:
            return proof.terminalEvent.type == TimelineEventType.workCompleted
        case .destroy:
            return proof.terminalEvent.type == TimelineEventType.workDestroyed
        }
    }

    private static func validProofIdentity(
        _ value: String, maximumBytes: Int = maxProofIdentityBytes
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func pageToken(_ offset: Int) -> String {
        "work-host-registry-v1-" + String(offset)
    }

    private static func parsePageToken(_ token: String?, totalCount: Int) throws -> Int {
        guard let token else { return 0 }
        let prefix = "work-host-registry-v1-"
        guard token.utf8.count <= 64, token.hasPrefix(prefix) else {
            throw WorkHostRegistryError.invalidPageToken
        }
        let suffix = String(token.dropFirst(prefix.count))
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber),
              let offset = Int(suffix), offset >= 0, offset <= totalCount
        else { throw WorkHostRegistryError.invalidPageToken }
        return offset
    }

    private static func configurationError(
        host: WorkHostRef,
        hostInstance: WorkHostInstanceRef,
        bounds: WorkHostRegistryBounds
    ) -> WorkHostRegistryError? {
        let identities = [
            host.workHostID,
            hostInstance.host.workHostID,
            hostInstance.instanceID,
            hostInstance.startIdentity,
        ]
        guard hostInstance.host == host else {
            return .invalidConfiguration("host instance names another Work Host")
        }
        guard identities.allSatisfy({
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && $0.utf8.count <= bounds.maxIdentityBytes
                && !$0.unicodeScalars.contains(where: { $0.value == 0 })
        }) else {
            return .invalidConfiguration("host and instance identities must be bounded and nonempty")
        }
        guard bounds.maxEntries >= 0,
              bounds.maxLiveEntries >= 0,
              bounds.maxCanonicalEntries >= 0,
              bounds.maxPageSize > 0 else {
            return .invalidConfiguration("registry bounds must be nonnegative and page size positive")
        }
        return nil
    }
}
