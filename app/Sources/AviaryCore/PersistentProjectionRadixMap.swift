import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A disposable, exact, disk-backed map for reducer state that cannot fit in a bounded HEAD.
///
/// The map is a fixed-depth radix trie over a domain-separated SHA-256 route. Nodes and values
/// are immutable, content addressed, and scoped to one namespace, journal, source generation,
/// map kind, and schema. A transaction returns a new root; publishing that root atomically beside
/// a projection HEAD is intentionally the responsibility of a later integration layer.
///
/// Route collisions do not alias keys. A leaf retains the bounded original key and compares it
/// exactly. Collision buckets are themselves bounded and fail closed if exhausted. The map is
/// same-user cooperating storage, not a sandbox: its immediate parent must already be an owned,
/// private directory. The map creates only one path component at a time and fsyncs the parent
/// entry; it does not claim to defend an arbitrary ancestor path from concurrent replacement.
public struct PersistentProjectionRadixMap: Sendable {
    public static let schemaVersion = 1
    public static let routeByteCount = 32
    public static let trieDepth = routeByteCount
    public static let maximumLookupObjectReads = trieDepth + 2
    public static let maximumMutationObjectReads = (trieDepth + 1) * 3 + 2
    public static let maximumMutationObjectsCreated = trieDepth + 2
    public static let maximumMutationNodesVisited = (trieDepth + 1) * 2

    public struct Limits: Codable, Hashable, Sendable {
        public static let `default` = Limits()

        public let maximumKeyBytes: Int
        public let maximumValueBytes: Int
        public let maximumObjectBytes: Int
        public let maximumCollisionEntries: Int
        public let maximumIdentityBytes: Int

        public init(
            maximumKeyBytes: Int = 4 * 1_024,
            maximumValueBytes: Int = 4 * 1_024 * 1_024,
            maximumObjectBytes: Int = 8 * 1_024 * 1_024,
            maximumCollisionEntries: Int = 16,
            maximumIdentityBytes: Int = 512
        ) {
            self.maximumKeyBytes = Self.clamp(maximumKeyBytes, upper: 64 * 1_024)
            self.maximumValueBytes = Self.clamp(maximumValueBytes, upper: 64 * 1_024 * 1_024)
            self.maximumObjectBytes = Self.clamp(maximumObjectBytes, upper: 96 * 1_024 * 1_024)
            self.maximumCollisionEntries = Self.clamp(maximumCollisionEntries, upper: 256)
            self.maximumIdentityBytes = Self.clamp(maximumIdentityBytes, upper: 4 * 1_024)
        }

        private static func clamp(_ value: Int, upper: Int) -> Int {
            max(1, min(value, upper))
        }
    }

    public enum MapError: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidIdentity
        case invalidRoot
        case invalidRoute
        case invalidObject
        case invalidOrdering
        case duplicateKey
        case collisionCapacityExceeded
        case keyTooLarge
        case valueTooLarge
        case objectTooLarge
        case missingObject
        case checksumMismatch
        case mixedScope
        case symlinkOrNonRegularFile
        case insecurePermissions
        case accessDenied
        case ioFailure

        public var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "Persistent projection map identity is invalid."
            case .invalidRoot: return "Persistent projection map root is invalid."
            case .invalidRoute: return "Persistent projection map route is invalid."
            case .invalidObject: return "Persistent projection map object is invalid."
            case .invalidOrdering: return "Persistent projection map ordering is invalid."
            case .duplicateKey: return "Persistent projection map contains a duplicate key."
            case .collisionCapacityExceeded: return "Persistent projection map collision capacity is exhausted."
            case .keyTooLarge: return "Persistent projection map key exceeds its bound."
            case .valueTooLarge: return "Persistent projection map value exceeds its bound."
            case .objectTooLarge: return "Persistent projection map object exceeds its bound."
            case .missingObject: return "Persistent projection map object is missing."
            case .checksumMismatch: return "Persistent projection map checksum does not match."
            case .mixedScope: return "Persistent projection map object belongs to another scope."
            case .symlinkOrNonRegularFile: return "Persistent projection map path is not a private regular object."
            case .insecurePermissions: return "Persistent projection map permissions are not private."
            case .accessDenied: return "Persistent projection map access was denied."
            case .ioFailure: return "Persistent projection map I/O failed."
            }
        }
    }

    public typealias Error = MapError

    public struct Root: Codable, Hashable, Sendable {
        public let schemaVersion: Int
        public let namespaceID: String
        public let journal: JournalRef
        public let sourceGeneration: String
        public let mapKind: String
        public let objectID: String
        public let entryCount: Int

        fileprivate init(scope: Scope, objectID: String, entryCount: Int) {
            self.schemaVersion = scope.schemaVersion
            self.namespaceID = scope.namespaceID
            self.journal = scope.journal
            self.sourceGeneration = scope.sourceGeneration
            self.mapKind = scope.mapKind
            self.objectID = objectID
            self.entryCount = entryCount
        }
    }

    public struct Metrics: Codable, Hashable, Sendable {
        public let nodesVisited: Int
        public let objectsRead: Int
        public let objectsCreated: Int
        public let bytesRead: Int
        public let bytesWritten: Int
        public let peakObjectBytes: Int
        public let maximumDepthVisited: Int

        fileprivate init(_ value: MetricAccumulator) {
            self.nodesVisited = value.nodesVisited
            self.objectsRead = value.objectsRead
            self.objectsCreated = value.objectsCreated
            self.bytesRead = value.bytesRead
            self.bytesWritten = value.bytesWritten
            self.peakObjectBytes = value.peakObjectBytes
            self.maximumDepthVisited = value.maximumDepthVisited
        }
    }

    public struct LookupResult: Hashable, Sendable {
        public let value: Data?
        public let metrics: Metrics
    }

    public enum TransactionDisposition: String, Codable, Hashable, Sendable {
        case inserted
        case updated
        case deleted
        case unchanged
    }

    public struct TransactionResult: Hashable, Sendable {
        public let previousRoot: Root?
        public let newRoot: Root?
        public let disposition: TransactionDisposition
        /// Objects newly materialized by this operation.
        public let createdObjectIDs: [String]
        /// Objects displaced from the new root's changed path. Prior roots may still reference
        /// them; this list is evidence for later tracing, never authorization to delete them.
        public let replacedObjectIDs: [String]
        public let metrics: Metrics
    }

    fileprivate struct Scope: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let namespaceID: String
        let journal: JournalRef
        let sourceGeneration: String
        let mapKind: String
    }

    private enum NodeKind: String, Codable, Hashable, Sendable {
        case branch
        case leaf
    }

    private struct Child: Codable, Hashable, Sendable {
        let edge: String
        let objectID: String
        let entryCount: Int
    }

    private struct Entry: Codable, Hashable, Sendable {
        let route: String
        let key: Data
        let valueObjectID: String
        let valueDigest: String
        let valueByteCount: Int
    }

    private struct NodeBody: Codable, Hashable, Sendable {
        let scope: Scope
        let depth: Int
        let prefix: String
        let kind: NodeKind
        let entryCount: Int
        let children: [Child]
        let entries: [Entry]
    }

    private struct NodeEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let objectID: String
        let bodyDigest: String
        let body: NodeBody
    }

    private struct ValueBody: Codable, Hashable, Sendable {
        let scope: Scope
        let digest: String
        let byteCount: Int
        let bytes: Data
    }

    private struct ValueEnvelope: Codable, Sendable {
        let schemaVersion: Int
        let objectID: String
        let bodyDigest: String
        let body: ValueBody
    }

    fileprivate struct MetricAccumulator {
        var nodesVisited = 0
        var objectsRead = 0
        var objectsCreated = 0
        var bytesRead = 0
        var bytesWritten = 0
        var peakObjectBytes = 0
        var maximumDepthVisited = 0

        mutating func read(_ count: Int) {
            objectsRead = Self.add(objectsRead, 1)
            bytesRead = Self.add(bytesRead, count)
            peakObjectBytes = max(peakObjectBytes, count)
        }

        mutating func created(_ count: Int) {
            objectsCreated = Self.add(objectsCreated, 1)
            bytesWritten = Self.add(bytesWritten, count)
            peakObjectBytes = max(peakObjectBytes, count)
        }

        mutating func visit(depth: Int) {
            nodesVisited = Self.add(nodesVisited, 1)
            maximumDepthVisited = max(maximumDepthVisited, depth)
        }

        private static func add(_ lhs: Int, _ rhs: Int) -> Int {
            lhs > Int.max - rhs ? Int.max : lhs + rhs
        }
    }

    private struct RewriteResult {
        let objectID: String?
        let entryCount: Int
        let changed: Bool
        var created: [String]
        var replaced: [String]
    }

    public let directory: URL
    public let namespaceID: String
    public let journal: JournalRef
    public let sourceGeneration: String
    public let mapKind: String
    public let schemaVersion: Int
    public let limits: Limits

    private let scope: Scope
    private let routeDigest: @Sendable (Data) -> String

    public init(
        directory: URL,
        namespaceID: String,
        journal: JournalRef,
        sourceGeneration: String,
        mapKind: String,
        schemaVersion: Int = PersistentProjectionRadixMap.schemaVersion,
        limits: Limits = .default
    ) throws {
        try self.init(
            directory: directory, namespaceID: namespaceID, journal: journal,
            sourceGeneration: sourceGeneration, mapKind: mapKind,
            schemaVersion: schemaVersion, limits: limits,
            routeDigest: { material in AviarySHA256.hash(data: material).description })
    }

    /// Internal collision seam. Production callers always use SHA-256; tests can force two exact
    /// keys onto one route without weakening the persisted exact-key comparison.
    init(
        directory: URL,
        namespaceID: String,
        journal: JournalRef,
        sourceGeneration: String,
        mapKind: String,
        schemaVersion: Int = PersistentProjectionRadixMap.schemaVersion,
        limits: Limits = .default,
        routeDigest: @escaping @Sendable (Data) -> String
    ) throws {
        guard Self.validIdentity(namespaceID, maxBytes: limits.maximumIdentityBytes),
              Self.validIdentity(mapKind, maxBytes: limits.maximumIdentityBytes),
              Self.validIdentity(journal.stableKey, maxBytes: limits.maximumIdentityBytes),
              Self.validDigest(sourceGeneration), schemaVersion > 0, schemaVersion < Int.max else {
            throw MapError.invalidIdentity
        }
        let standardized = directory.standardizedFileURL
        self.directory = standardized
        self.namespaceID = namespaceID
        self.journal = journal
        self.sourceGeneration = sourceGeneration
        self.mapKind = mapKind
        self.schemaVersion = schemaVersion
        self.limits = limits
        self.scope = Scope(
            schemaVersion: schemaVersion, namespaceID: namespaceID, journal: journal,
            sourceGeneration: sourceGeneration, mapKind: mapKind)
        self.routeDigest = routeDigest
        try prepareDirectories()
    }

    public func lookup(root: Root?, key: Data) throws -> LookupResult {
        try validateKey(key)
        let route = try route(for: key)
        var metrics = MetricAccumulator()
        let value: Data? = try withLock {
            guard let root else { return nil }
            try validateRoot(root)
            var objectID = root.objectID
            var prefix = ""
            var expectedEntryCount = root.entryCount
            for depth in 0...Self.trieDepth {
                let node = try readNode(
                    objectID: objectID, depth: depth, prefix: prefix, metrics: &metrics)
                guard node.entryCount == expectedEntryCount else { throw MapError.invalidObject }
                metrics.visit(depth: depth)
                if depth == Self.trieDepth {
                    guard let entry = node.entries.first(where: { $0.route == route && $0.key == key })
                    else { return nil }
                    return try readValue(entry: entry, metrics: &metrics)
                }
                let edge = routeComponent(route, depth: depth)
                guard let child = node.children.first(where: { $0.edge == edge }) else {
                    return nil
                }
                objectID = child.objectID
                expectedEntryCount = child.entryCount
                prefix += edge
            }
            throw MapError.invalidObject
        }
        return LookupResult(value: value, metrics: Metrics(metrics))
    }

    public func lookup(root: Root?, key: String) throws -> LookupResult {
        try lookup(root: root, key: Data(key.utf8))
    }

    public func setting(root: Root?, key: Data, value: Data) throws -> TransactionResult {
        try validateKey(key)
        guard value.count <= limits.maximumValueBytes else { throw MapError.valueTooLarge }
        let route = try route(for: key)
        var metrics = MetricAccumulator()
        return try withLock {
            if let root { try validateRoot(root) }
            let oldValue = try existingEntry(
                root: root, route: route, key: key, metrics: &metrics)
            if let oldValue {
                _ = try readValue(entry: oldValue, metrics: &metrics)
            }
            let valueWrite = try writeValue(
                value, route: route, key: key, metrics: &metrics)
            let rewritten = try rewrite(
                objectID: root?.objectID, depth: 0, prefix: "", route: route,
                key: key, replacement: valueWrite.reference,
                expectedEntryCount: root?.entryCount, metrics: &metrics)
            guard let rootID = rewritten.objectID, rewritten.entryCount > 0 else {
                throw MapError.invalidObject
            }
            let newRoot = Root(scope: scope, objectID: rootID, entryCount: rewritten.entryCount)
            let disposition: TransactionDisposition
            if !rewritten.changed {
                disposition = .unchanged
            } else if oldValue == nil {
                disposition = .inserted
            } else {
                disposition = .updated
            }
            var created = rewritten.created
            if valueWrite.created { created.append(valueWrite.reference.valueObjectID) }
            var replaced = rewritten.replaced
            if let oldValue, oldValue.valueObjectID != valueWrite.reference.valueObjectID {
                replaced.append(oldValue.valueObjectID)
            }
            return TransactionResult(
                previousRoot: root, newRoot: newRoot, disposition: disposition,
                createdObjectIDs: Self.sortedUnique(created),
                replacedObjectIDs: Self.sortedUnique(replaced), metrics: Metrics(metrics))
        }
    }

    public func setting(root: Root?, key: String, value: Data) throws -> TransactionResult {
        try setting(root: root, key: Data(key.utf8), value: value)
    }

    public func removing(root: Root?, key: Data) throws -> TransactionResult {
        try validateKey(key)
        let route = try route(for: key)
        var metrics = MetricAccumulator()
        return try withLock {
            guard let root else {
                return TransactionResult(
                    previousRoot: nil, newRoot: nil, disposition: .unchanged,
                    createdObjectIDs: [], replacedObjectIDs: [], metrics: Metrics(metrics))
            }
            try validateRoot(root)
            let oldValue = try existingEntry(
                root: root, route: route, key: key, metrics: &metrics)
            guard oldValue != nil else {
                return TransactionResult(
                    previousRoot: root, newRoot: root, disposition: .unchanged,
                    createdObjectIDs: [], replacedObjectIDs: [], metrics: Metrics(metrics))
            }
            if let oldValue {
                _ = try readValue(entry: oldValue, metrics: &metrics)
            }
            let rewritten = try rewrite(
                objectID: root.objectID, depth: 0, prefix: "", route: route,
                key: key, replacement: nil,
                expectedEntryCount: root.entryCount, metrics: &metrics)
            let newRoot = rewritten.objectID.map {
                Root(scope: scope, objectID: $0, entryCount: rewritten.entryCount)
            }
            var replaced = rewritten.replaced
            if let oldValue { replaced.append(oldValue.valueObjectID) }
            return TransactionResult(
                previousRoot: root, newRoot: newRoot, disposition: .deleted,
                createdObjectIDs: Self.sortedUnique(rewritten.created),
                replacedObjectIDs: Self.sortedUnique(replaced), metrics: Metrics(metrics))
        }
    }

    public func removing(root: Root?, key: String) throws -> TransactionResult {
        try removing(root: root, key: Data(key.utf8))
    }

    /// Validates the scoped root envelope. Lookup and mutation additionally validate every object
    /// on the selected route; this deliberately does not turn one bounded operation into a scan of
    /// the entire disk-scaled map.
    @discardableResult
    public func validate(root: Root) throws -> Metrics {
        var metrics = MetricAccumulator()
        try withLock {
            try validateRoot(root)
            let node = try readNode(
                objectID: root.objectID, depth: 0, prefix: "", metrics: &metrics)
            guard node.entryCount == root.entryCount else { throw MapError.invalidRoot }
        }
        return Metrics(metrics)
    }

    /// Proves that every node and value reachable from `root` is locally present and valid.
    ///
    /// Ordinary lookups intentionally validate only one route. Projection publication and an
    /// explicit repair/audit operation may need the stronger availability statement, so they use
    /// this finite full-tree walk. The returned metrics make that cost observable and allow a
    /// future packed/checkpoint format to replace it without weakening the contract.
    @discardableResult
    public func validateReachable(root: Root) throws -> Metrics {
        var metrics = MetricAccumulator()
        try withLock {
            try validateRoot(root)
            var pending: [(objectID: String, depth: Int, prefix: String, expectedCount: Int)] = [
                (root.objectID, 0, "", root.entryCount)
            ]
            var visited = Set<String>()
            var validatedEntries = 0
            while let item = pending.popLast() {
                guard visited.insert(item.objectID).inserted else {
                    throw MapError.invalidObject
                }
                let node = try readNode(
                    objectID: item.objectID, depth: item.depth,
                    prefix: item.prefix, metrics: &metrics)
                metrics.visit(depth: item.depth)
                guard node.entryCount == item.expectedCount else {
                    throw MapError.invalidObject
                }
                if item.depth == Self.trieDepth {
                    guard validatedEntries <= Int.max - node.entries.count else {
                        throw MapError.invalidObject
                    }
                    validatedEntries += node.entries.count
                    for entry in node.entries {
                        _ = try readValue(entry: entry, metrics: &metrics)
                    }
                } else {
                    for child in node.children.reversed() {
                        pending.append((
                            child.objectID, item.depth + 1,
                            item.prefix + child.edge, child.entryCount))
                    }
                }
            }
            guard validatedEntries == root.entryCount else {
                throw MapError.invalidRoot
            }
        }
        return Metrics(metrics)
    }

    // MARK: Trie rewrite

    private func rewrite(
        objectID: String?,
        depth: Int,
        prefix: String,
        route: String,
        key: Data,
        replacement: Entry?,
        expectedEntryCount: Int?,
        metrics: inout MetricAccumulator
    ) throws -> RewriteResult {
        struct PathNode {
            let objectID: String?
            let depth: Int
            let prefix: String
            let edge: String
            let childIndex: Int?
            let existing: NodeBody?
        }

        guard depth >= 0, depth <= Self.trieDepth,
              prefix.utf8.count == depth * 2,
              route.utf8.count == Self.trieDepth * 2 else { throw MapError.invalidRoute }

        // Collect the single route before mutating anything. Rebuilding this fixed-depth path
        // iteratively avoids consuming the small cooperative-task stack once per trie level.
        var path: [PathNode] = []
        path.reserveCapacity(Self.trieDepth - depth)
        var currentObjectID = objectID
        var currentDepth = depth
        var currentPrefix = prefix
        var currentExpectedCount = expectedEntryCount
        var leaf: NodeBody?
        while true {
            guard currentDepth >= 0, currentDepth <= Self.trieDepth,
                  currentPrefix.utf8.count == currentDepth * 2 else {
                throw MapError.invalidRoute
            }
            metrics.visit(depth: currentDepth)
            let existing: NodeBody?
            if let currentObjectID {
                existing = try readNode(
                    objectID: currentObjectID, depth: currentDepth,
                    prefix: currentPrefix, metrics: &metrics)
                guard currentExpectedCount == nil
                    || existing?.entryCount == currentExpectedCount else {
                    throw MapError.invalidObject
                }
            } else {
                existing = nil
            }
            if currentDepth == Self.trieDepth {
                leaf = existing
                break
            }
            let edge = routeComponent(route, depth: currentDepth)
            let children = existing?.children ?? []
            let childIndex = children.firstIndex(where: { $0.edge == edge })
            path.append(PathNode(
                objectID: currentObjectID, depth: currentDepth, prefix: currentPrefix,
                edge: edge, childIndex: childIndex, existing: existing))
            let oldChild = childIndex.map { children[$0] }
            currentObjectID = oldChild?.objectID
            currentExpectedCount = oldChild?.entryCount
            currentDepth += 1
            currentPrefix += edge
        }

        var entries = leaf?.entries ?? []
        let index = entries.firstIndex(where: { $0.route == route && $0.key == key })
        let originalEntryCount = path.first?.existing?.entryCount ?? (objectID == nil ? 0 : entries.count)
        if let replacement {
            if let index {
                guard entries[index] != replacement else {
                    return RewriteResult(
                        objectID: objectID, entryCount: originalEntryCount, changed: false,
                        created: [], replaced: [])
                }
                entries[index] = replacement
            } else {
                guard entries.count < limits.maximumCollisionEntries else {
                    throw MapError.collisionCapacityExceeded
                }
                entries.append(replacement)
            }
        } else if let index {
            entries.remove(at: index)
        } else {
            return RewriteResult(
                objectID: objectID, entryCount: originalEntryCount, changed: false,
                created: [], replaced: [])
        }
        entries.sort(by: Self.entryLess)

        var result: RewriteResult
        if entries.isEmpty {
            result = RewriteResult(
                objectID: nil, entryCount: 0, changed: true, created: [],
                replaced: currentObjectID.map { [$0] } ?? [])
        } else {
            let leafDepth = depth + path.count
            let leafPrefix = path.reduce(into: prefix) { $0 += $1.edge }
            let body = NodeBody(
                scope: scope, depth: leafDepth, prefix: leafPrefix, kind: .leaf,
                entryCount: entries.count, children: [], entries: entries)
            let written = try writeNode(body, metrics: &metrics)
            result = RewriteResult(
                objectID: written.objectID, entryCount: entries.count,
                changed: written.objectID != currentObjectID,
                created: written.created ? [written.objectID] : [],
                replaced: currentObjectID.flatMap {
                    $0 == written.objectID ? nil : [$0]
                } ?? [])
        }

        for node in path.reversed() {
            var children = node.existing?.children ?? []
            if let childObjectID = result.objectID {
                let child = Child(
                    edge: node.edge, objectID: childObjectID, entryCount: result.entryCount)
                if let childIndex = node.childIndex {
                    children[childIndex] = child
                } else {
                    children.append(child)
                }
            } else if let childIndex = node.childIndex {
                children.remove(at: childIndex)
            }
            children.sort { $0.edge < $1.edge }
            guard !children.isEmpty else {
                var replaced = result.replaced
                if let oldObjectID = node.objectID { replaced.append(oldObjectID) }
                result = RewriteResult(
                    objectID: nil, entryCount: 0, changed: true,
                    created: result.created, replaced: replaced)
                continue
            }
            let count = try Self.sumEntryCounts(children)
            let body = NodeBody(
                scope: scope, depth: node.depth, prefix: node.prefix, kind: .branch,
                entryCount: count, children: children, entries: [])
            let written = try writeNode(body, metrics: &metrics)
            var created = result.created
            if written.created { created.append(written.objectID) }
            var replaced = result.replaced
            if let oldObjectID = node.objectID, oldObjectID != written.objectID {
                replaced.append(oldObjectID)
            }
            result = RewriteResult(
                objectID: written.objectID, entryCount: count,
                changed: written.objectID != node.objectID,
                created: created, replaced: replaced)
        }
        return result
    }

    private func existingEntry(
        root: Root?, route: String, key: Data, metrics: inout MetricAccumulator
    ) throws -> Entry? {
        guard let root else { return nil }
        var objectID = root.objectID
        var prefix = ""
        var expectedEntryCount = root.entryCount
        for depth in 0...Self.trieDepth {
            let node = try readNode(
                objectID: objectID, depth: depth, prefix: prefix, metrics: &metrics)
            guard node.entryCount == expectedEntryCount else { throw MapError.invalidObject }
            metrics.visit(depth: depth)
            if depth == Self.trieDepth {
                return node.entries.first { $0.route == route && $0.key == key }
            }
            let edge = routeComponent(route, depth: depth)
            guard let child = node.children.first(where: { $0.edge == edge }) else { return nil }
            objectID = child.objectID
            expectedEntryCount = child.entryCount
            prefix += edge
        }
        throw MapError.invalidObject
    }

    // MARK: Object validation and I/O

    private func validateRoot(_ root: Root) throws {
        guard root.schemaVersion == scope.schemaVersion,
              root.namespaceID == scope.namespaceID,
              root.journal == scope.journal,
              root.sourceGeneration == scope.sourceGeneration,
              root.mapKind == scope.mapKind else { throw MapError.mixedScope }
        guard Self.validDigest(root.objectID), root.entryCount > 0 else {
            throw MapError.invalidRoot
        }
    }

    private func validateKey(_ key: Data) throws {
        guard !key.isEmpty else { throw MapError.invalidIdentity }
        guard key.count <= limits.maximumKeyBytes else { throw MapError.keyTooLarge }
    }

    private func route(for key: Data) throws -> String {
        var material = Data("aviary-projection-radix-route-v1\0".utf8)
        material.append(try Self.canonicalJSON(scope))
        material.append(0)
        material.append(key)
        let value = routeDigest(material).lowercased()
        guard Self.validDigest(value) else { throw MapError.invalidRoute }
        return value
    }

    private func routeComponent(_ route: String, depth: Int) -> String {
        let start = route.index(route.startIndex, offsetBy: depth * 2)
        let end = route.index(start, offsetBy: 2)
        return String(route[start..<end])
    }

    private func validateNode(_ node: NodeBody, depth: Int, prefix: String) throws {
        guard node.scope == scope else { throw MapError.mixedScope }
        guard node.depth == depth, node.prefix == prefix,
              depth >= 0, depth <= Self.trieDepth,
              prefix.utf8.count == depth * 2 else { throw MapError.invalidObject }
        if depth == Self.trieDepth {
            guard node.kind == .leaf, node.children.isEmpty,
                  !node.entries.isEmpty,
                  node.entries.count <= limits.maximumCollisionEntries,
                  node.entryCount == node.entries.count else { throw MapError.invalidObject }
            guard node.entries == node.entries.sorted(by: Self.entryLess) else {
                throw MapError.invalidOrdering
            }
            var keys = Set<Data>()
            for entry in node.entries {
                let expectedRoute = try route(for: entry.key)
                guard entry.key.count > 0, entry.key.count <= limits.maximumKeyBytes,
                      entry.route == expectedRoute, entry.route == prefix,
                      Self.validDigest(entry.valueObjectID),
                      Self.validDigest(entry.valueDigest),
                      entry.valueByteCount >= 0,
                      entry.valueByteCount <= limits.maximumValueBytes,
                      keys.insert(entry.key).inserted else { throw MapError.duplicateKey }
            }
        } else {
            let expectedEntryCount = try Self.sumEntryCounts(node.children)
            guard node.kind == .branch, node.entries.isEmpty,
                  !node.children.isEmpty, node.children.count <= 256,
                  node.entryCount == expectedEntryCount else {
                throw MapError.invalidObject
            }
            guard node.children == node.children.sorted(by: { $0.edge < $1.edge }),
                  Set(node.children.map(\.edge)).count == node.children.count else {
                throw MapError.invalidOrdering
            }
            for child in node.children {
                guard child.edge.utf8.count == 2, Self.validRouteComponent(child.edge),
                      Self.validDigest(child.objectID), child.entryCount > 0 else {
                    throw MapError.invalidObject
                }
            }
        }
    }

    private func readNode(
        objectID: String, depth: Int, prefix: String, metrics: inout MetricAccumulator
    ) throws -> NodeBody {
        let data = try readObject(
            at: nodeURL(objectID), maximumBytes: limits.maximumObjectBytes, metrics: &metrics)
        do {
            let envelope = try JSONDecoder().decode(NodeEnvelope.self, from: data)
            let bodyData = try Self.canonicalJSON(envelope.body)
            guard envelope.schemaVersion == schemaVersion,
                  envelope.objectID == objectID,
                  envelope.bodyDigest == Self.digest(bodyData),
                  objectID == Self.objectID(kind: "node", body: bodyData) else {
                throw MapError.checksumMismatch
            }
            try validateNode(envelope.body, depth: depth, prefix: prefix)
            return envelope.body
        } catch let error as MapError {
            throw error
        } catch {
            throw MapError.invalidObject
        }
    }

    private func writeNode(
        _ body: NodeBody, metrics: inout MetricAccumulator
    ) throws -> (objectID: String, created: Bool) {
        try validateNode(body, depth: body.depth, prefix: body.prefix)
        let bodyData = try Self.canonicalJSON(body)
        let objectID = Self.objectID(kind: "node", body: bodyData)
        let envelope = NodeEnvelope(
            schemaVersion: schemaVersion, objectID: objectID,
            bodyDigest: Self.digest(bodyData), body: body)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumObjectBytes else { throw MapError.objectTooLarge }
        let created = try writeImmutable(data, to: nodeURL(objectID), metrics: &metrics)
        return (objectID, created)
    }

    private func writeValue(
        _ value: Data,
        route: String,
        key: Data,
        metrics: inout MetricAccumulator
    ) throws -> (reference: Entry, created: Bool) {
        let valueDigest = Self.digest(value)
        let body = ValueBody(
            scope: scope, digest: valueDigest, byteCount: value.count, bytes: value)
        let bodyData = try Self.canonicalJSON(body)
        let objectID = Self.objectID(kind: "value", body: bodyData)
        let envelope = ValueEnvelope(
            schemaVersion: schemaVersion, objectID: objectID,
            bodyDigest: Self.digest(bodyData), body: body)
        let data = try Self.canonicalJSON(envelope)
        guard data.count <= limits.maximumObjectBytes else { throw MapError.objectTooLarge }
        let created = try writeImmutable(data, to: valueURL(objectID), metrics: &metrics)
        return (Entry(
            route: route, key: key, valueObjectID: objectID,
            valueDigest: valueDigest, valueByteCount: value.count), created)
    }

    private func readValue(entry: Entry, metrics: inout MetricAccumulator) throws -> Data {
        let data = try readObject(
            at: valueURL(entry.valueObjectID), maximumBytes: limits.maximumObjectBytes,
            metrics: &metrics)
        do {
            let envelope = try JSONDecoder().decode(ValueEnvelope.self, from: data)
            let bodyData = try Self.canonicalJSON(envelope.body)
            guard envelope.schemaVersion == schemaVersion,
                  envelope.objectID == entry.valueObjectID,
                  envelope.bodyDigest == Self.digest(bodyData),
                  entry.valueObjectID == Self.objectID(kind: "value", body: bodyData),
                  envelope.body.scope == scope,
                  envelope.body.byteCount == envelope.body.bytes.count,
                  envelope.body.byteCount == entry.valueByteCount,
                  envelope.body.byteCount <= limits.maximumValueBytes,
                  envelope.body.digest == entry.valueDigest,
                  envelope.body.digest == Self.digest(envelope.body.bytes) else {
                throw MapError.checksumMismatch
            }
            return envelope.body.bytes
        } catch let error as MapError {
            throw error
        } catch {
            throw MapError.invalidObject
        }
    }

    private func writeImmutable(
        _ data: Data, to url: URL, metrics: inout MetricAccumulator
    ) throws -> Bool {
        var existingStatus = stat()
        if lstat(url.path, &existingStatus) == 0 {
            let existing = try readObject(
                at: url, maximumBytes: limits.maximumObjectBytes, metrics: &metrics)
            guard existing == data else { throw MapError.checksumMismatch }
            try synchronizeDirectory(url.deletingLastPathComponent())
            return false
        }
        guard errno == ENOENT else {
            if errno == ELOOP { throw MapError.symlinkOrNonRegularFile }
            if errno == EACCES || errno == EPERM { throw MapError.accessDenied }
            throw MapError.ioFailure
        }

        let temporary = url.deletingLastPathComponent().appending(
            path: ".radix-tmp-\(UUID().uuidString.lowercased())", directoryHint: .notDirectory)
        let fd = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw MapError.ioFailure }
        var descriptorOpen = true
        var temporaryExists = true
        defer {
            if descriptorOpen { _ = AviaryPOSIX.close(fd) }
            if temporaryExists { _ = unlink(temporary.path) }
        }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let count = write(fd, base.advanced(by: offset), raw.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0, errno == EINTR { continue }
                    else { throw MapError.ioFailure }
                }
            }
            guard fsync(fd) == 0 else { throw MapError.ioFailure }
            guard AviaryPOSIX.close(fd) == 0 else { throw MapError.ioFailure }
            descriptorOpen = false
        } catch {
            throw error
        }

        let linked = temporary.path.withCString { temporaryPath in
            url.path.withCString { finalPath in
                projectionRadixLink(temporaryPath, finalPath)
            }
        }
        if linked != 0 {
            guard errno == EEXIST else { throw MapError.ioFailure }
            let existing = try readObject(
                at: url, maximumBytes: limits.maximumObjectBytes, metrics: &metrics)
            guard existing == data else { throw MapError.checksumMismatch }
            try synchronizeDirectory(url.deletingLastPathComponent())
            return false
        }
        guard unlink(temporary.path) == 0 else { throw MapError.ioFailure }
        temporaryExists = false
        metrics.created(data.count)
        try synchronizeDirectory(url.deletingLastPathComponent())
        return true
    }

    private func readObject(
        at url: URL, maximumBytes: Int, metrics: inout MetricAccumulator
    ) throws -> Data {
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            if errno == ENOENT { throw MapError.missingObject }
            if errno == ELOOP { throw MapError.symlinkOrNonRegularFile }
            if errno == EACCES || errno == EPERM { throw MapError.accessDenied }
            throw MapError.ioFailure
        }
        defer { _ = AviaryPOSIX.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw MapError.ioFailure }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw MapError.symlinkOrNonRegularFile
        }
        guard status.st_uid == geteuid(),
              (status.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw MapError.insecurePermissions
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumBytes) else {
            throw MapError.objectTooLarge
        }
        var result = Data()
        result.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1_024, maximumBytes))
        while true {
            let amount = buffer.withUnsafeMutableBytes {
                AviaryPOSIX.read(fd, $0.baseAddress, $0.count)
            }
            if amount > 0 {
                guard result.count <= maximumBytes - amount else { throw MapError.objectTooLarge }
                result.append(buffer, count: amount)
            } else if amount == 0 {
                break
            } else if errno != EINTR {
                throw MapError.ioFailure
            }
        }
        metrics.read(result.count)
        return result
    }

    // MARK: Filesystem discipline

    private var nodesDirectory: URL {
        directory.appending(path: "nodes", directoryHint: .isDirectory)
    }

    private var valuesDirectory: URL {
        directory.appending(path: "values", directoryHint: .isDirectory)
    }

    private var lockURL: URL {
        directory.appending(path: ".radix.lock", directoryHint: .notDirectory)
    }

    private func nodeURL(_ objectID: String) -> URL {
        nodesDirectory.appending(path: "\(objectID).node", directoryHint: .notDirectory)
    }

    private func valueURL(_ objectID: String) -> URL {
        valuesDirectory.appending(path: "\(objectID).value", directoryHint: .notDirectory)
    }

    private func prepareDirectories() throws {
        try ensurePrivateDirectory(directory)
        try ensurePrivateDirectory(nodesDirectory)
        try ensurePrivateDirectory(valuesDirectory)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var parentStatus = stat()
        guard lstat(parent.path, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR,
              parentStatus.st_uid == geteuid(),
              (parentStatus.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw MapError.insecurePermissions
        }
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw MapError.symlinkOrNonRegularFile
            }
            guard status.st_uid == geteuid(),
                  (status.st_mode & mode_t(0o777)) == mode_t(0o700) else {
                throw MapError.insecurePermissions
            }
            try synchronizeDirectory(url)
            try synchronizeDirectory(parent)
            return
        }
        guard errno == ENOENT else { throw MapError.accessDenied }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw MapError.ioFailure
        }
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw MapError.insecurePermissions
        }
        try synchronizeDirectory(url)
        try synchronizeDirectory(parent)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try prepareDirectories()
        let fd = lockURL.path.withCString {
            AviaryPOSIX.openExclusiveLock(
                $0, flags: O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode: mode_t(0o600))
        }
        guard fd >= 0 else { throw MapError.accessDenied }
        defer { _ = AviaryPOSIX.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw MapError.insecurePermissions
        }
        return try body()
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let fd = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw MapError.ioFailure }
        defer { _ = AviaryPOSIX.close(fd) }
        guard fsync(fd) == 0 else { throw MapError.ioFailure }
    }

    // MARK: Deterministic helpers

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        AviarySHA256.hash(data: data).description
    }

    private static func objectID(kind: String, body: Data) -> String {
        var material = Data("aviary-projection-radix-object-v1\0".utf8)
        material.append(Data(kind.utf8))
        material.append(0)
        material.append(body)
        return digest(material)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func validRouteComponent(_ value: String) -> Bool {
        value.utf8.count == 2 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func validIdentity(_ value: String, maxBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func entryLess(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.route != rhs.route { return lhs.route < rhs.route }
        return lhs.key.lexicographicallyPrecedes(rhs.key)
    }

    private static func sumEntryCounts(_ children: [Child]) throws -> Int {
        var total = 0
        for child in children {
            guard child.entryCount > 0, total <= Int.max - child.entryCount else {
                throw MapError.invalidObject
            }
            total += child.entryCount
        }
        return total
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

private func projectionRadixLink(
    _ existing: UnsafePointer<CChar>, _ new: UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.link(existing, new)
    #elseif canImport(Glibc)
    Glibc.link(existing, new)
    #else
    -1
    #endif
}
