import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private let radixMapWork = WorkRef(
    workHostID: "radix-map-host", workID: "radix-map-work")
private let radixMapJournal = JournalRef.work(
    radixMapWork, journalID: "radix-map-journal")
private let radixMapGeneration = String(repeating: "a", count: 64)

private func radixMapTemporaryDirectory(_ suffix: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "aviary-radix-map-\(suffix.lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard chmod(url.path, mode_t(0o700)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    return url
}

private func radixMap(
    at directory: URL,
    namespaceID: String = "radix-map-namespace",
    journal: JournalRef = radixMapJournal,
    sourceGeneration: String = radixMapGeneration,
    mapKind: String = "seen-events",
    limits: PersistentProjectionRadixMap.Limits = .default,
    routeDigest: (@Sendable (Data) -> String)? = nil
) throws -> PersistentProjectionRadixMap {
    if let routeDigest {
        return try PersistentProjectionRadixMap(
            directory: directory, namespaceID: namespaceID, journal: journal,
            sourceGeneration: sourceGeneration, mapKind: mapKind,
            limits: limits, routeDigest: routeDigest)
    }
    return try PersistentProjectionRadixMap(
        directory: directory, namespaceID: namespaceID, journal: journal,
        sourceGeneration: sourceGeneration, mapKind: mapKind, limits: limits)
}

private func expectRadixMapError(
    _ expected: PersistentProjectionRadixMap.MapError,
    _ body: () throws -> Void,
    line: Int = #line
) {
    do {
        try body()
        XCTFail("expected \(expected)", line: line)
    } catch let error as PersistentProjectionRadixMap.MapError {
        XCTAssertEqual(error, expected, line: line)
    } catch {
        XCTFail("unexpected error \(error)", line: line)
    }
}

private func testPersistentRadixMapDeterministicCopyOnWriteCRUD() throws {
    let root = try radixMapTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try radixMap(at: root.appending(path: "first", directoryHint: .isDirectory))
    let second = try radixMap(at: root.appending(path: "second", directoryHint: .isDirectory))
    let rows = [
        ("event-z", Data("value-z".utf8)),
        ("event-a", Data("value-a".utf8)),
        ("event-m", Data("value-m".utf8)),
    ]

    var firstRoot: PersistentProjectionRadixMap.Root?
    for row in rows {
        let result = try first.setting(root: firstRoot, key: row.0, value: row.1)
        XCTAssertEqual(result.disposition, .inserted)
        XCTAssertEqual(result.newRoot?.entryCount, (firstRoot?.entryCount ?? 0) + 1)
        XCTAssertTrue(
            result.createdObjectIDs.count
                <= PersistentProjectionRadixMap.maximumMutationObjectsCreated)
        XCTAssertTrue(
            result.metrics.objectsRead
                <= PersistentProjectionRadixMap.maximumMutationObjectReads)
        XCTAssertTrue(
            result.metrics.nodesVisited
                <= PersistentProjectionRadixMap.maximumMutationNodesVisited)
        firstRoot = result.newRoot
    }
    var secondRoot: PersistentProjectionRadixMap.Root?
    for row in rows.reversed() {
        secondRoot = try second.setting(
            root: secondRoot, key: row.0, value: row.1).newRoot
    }
    let originalRoot = try XCTUnwrap(firstRoot)
    XCTAssertEqual(originalRoot, secondRoot)
    XCTAssertEqual(originalRoot.entryCount, 3)

    for row in rows {
        XCTAssertEqual(try first.lookup(root: originalRoot, key: row.0).value, row.1)
    }
    let updated = try first.setting(
        root: originalRoot, key: "event-a", value: Data("new-value-a".utf8))
    XCTAssertEqual(updated.disposition, .updated)
    XCTAssertEqual(updated.newRoot?.entryCount, 3)
    XCTAssertFalse(updated.replacedObjectIDs.isEmpty)
    XCTAssertEqual(
        try first.lookup(root: originalRoot, key: "event-a").value,
        Data("value-a".utf8), "an old root must remain an exact immutable snapshot")
    XCTAssertEqual(
        try first.lookup(root: updated.newRoot, key: "event-a").value,
        Data("new-value-a".utf8))

    let unchanged = try first.setting(
        root: updated.newRoot, key: "event-a", value: Data("new-value-a".utf8))
    XCTAssertEqual(unchanged.disposition, .unchanged)
    XCTAssertEqual(unchanged.newRoot, updated.newRoot)
    XCTAssertTrue(unchanged.createdObjectIDs.isEmpty)
    XCTAssertTrue(unchanged.replacedObjectIDs.isEmpty)

    let removed = try first.removing(root: updated.newRoot, key: "event-m")
    XCTAssertEqual(removed.disposition, .deleted)
    XCTAssertEqual(removed.newRoot?.entryCount, 2)
    XCTAssertNil(try first.lookup(root: removed.newRoot, key: "event-m").value)
    XCTAssertEqual(
        try first.lookup(root: updated.newRoot, key: "event-m").value,
        Data("value-m".utf8))
    let absent = try first.removing(root: removed.newRoot, key: "never-present")
    XCTAssertEqual(absent.disposition, .unchanged)
    XCTAssertEqual(absent.newRoot, removed.newRoot)

    var emptying = removed.newRoot
    emptying = try first.removing(root: emptying, key: "event-a").newRoot
    emptying = try first.removing(root: emptying, key: "event-z").newRoot
    XCTAssertNil(emptying)
}

private func testPersistentRadixMapExactCollisionFallback() throws {
    let root = try radixMapTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let limits = PersistentProjectionRadixMap.Limits(maximumCollisionEntries: 2)
    let forcedRoute = String(repeating: "0", count: 64)
    let map = try radixMap(
        at: root.appending(path: "map", directoryHint: .isDirectory),
        limits: limits, routeDigest: { _ in forcedRoute })

    let one = try map.setting(root: nil, key: "one", value: Data("first".utf8))
    let two = try map.setting(root: one.newRoot, key: "two", value: Data("second".utf8))
    XCTAssertEqual(two.newRoot?.entryCount, 2)
    XCTAssertEqual(try map.lookup(root: two.newRoot, key: "one").value, Data("first".utf8))
    XCTAssertEqual(try map.lookup(root: two.newRoot, key: "two").value, Data("second".utf8))
    XCTAssertNil(try map.lookup(root: two.newRoot, key: "not-one-or-two").value)
    expectRadixMapError(.collisionCapacityExceeded) {
        _ = try map.setting(root: two.newRoot, key: "three", value: Data("third".utf8))
    }
    XCTAssertEqual(try map.lookup(root: two.newRoot, key: "one").value, Data("first".utf8))

    let reverseMap = try radixMap(
        at: root.appending(path: "reverse", directoryHint: .isDirectory),
        limits: limits, routeDigest: { _ in forcedRoute })
    let reverseTwo = try reverseMap.setting(
        root: nil, key: "two", value: Data("second".utf8))
    let reverseOne = try reverseMap.setting(
        root: reverseTwo.newRoot, key: "one", value: Data("first".utf8))
    XCTAssertEqual(reverseOne.newRoot, two.newRoot)
}

private func testPersistentRadixMapMissingCorruptAndMixedScopeFailClosed() throws {
    let root = try radixMapTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "map", directoryHint: .isDirectory)
    let map = try radixMap(at: directory)
    let inserted = try map.setting(root: nil, key: "event", value: Data("body".utf8))
    let mapRoot = try XCTUnwrap(inserted.newRoot)
    let rootObject = directory.appending(
        path: "nodes/\(mapRoot.objectID).node", directoryHint: .notDirectory)
    let original = try Data(contentsOf: rootObject)

    let valueDirectory = directory.appending(path: "values", directoryHint: .isDirectory)
    let valueObject = try XCTUnwrap(
        FileManager.default.contentsOfDirectory(
            at: valueDirectory, includingPropertiesForKeys: nil).first)
    let originalValue = try Data(contentsOf: valueObject)
    try FileManager.default.removeItem(at: valueObject)
    expectRadixMapError(.missingObject) {
        _ = try map.lookup(root: mapRoot, key: "event")
    }
    try originalValue.write(to: valueObject, options: .atomic)
    guard chmod(valueObject.path, mode_t(0o600)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    var corruptedValue = originalValue
    corruptedValue[corruptedValue.startIndex] ^= 0x01
    try corruptedValue.write(to: valueObject, options: .atomic)
    guard chmod(valueObject.path, mode_t(0o600)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    do {
        _ = try map.lookup(root: mapRoot, key: "event")
        XCTFail("corrupt content-addressed value must fail closed")
    } catch let error as PersistentProjectionRadixMap.MapError {
        XCTAssertTrue(error == .invalidObject || error == .checksumMismatch)
    }
    do {
        _ = try map.setting(root: mapRoot, key: "event", value: Data("replacement".utf8))
        XCTFail("an update must not silently repair a corrupt input root")
    } catch let error as PersistentProjectionRadixMap.MapError {
        XCTAssertTrue(error == .invalidObject || error == .checksumMismatch)
    }
    do {
        _ = try map.removing(root: mapRoot, key: "event")
        XCTFail("a delete must not silently discard a corrupt input value")
    } catch let error as PersistentProjectionRadixMap.MapError {
        XCTAssertTrue(error == .invalidObject || error == .checksumMismatch)
    }
    try originalValue.write(to: valueObject, options: .atomic)
    guard chmod(valueObject.path, mode_t(0o600)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }

    try FileManager.default.removeItem(at: rootObject)
    expectRadixMapError(.missingObject) {
        _ = try map.lookup(root: mapRoot, key: "event")
    }
    try original.write(to: rootObject, options: .atomic)
    guard chmod(rootObject.path, mode_t(0o600)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    var corrupted = original
    corrupted[corrupted.startIndex] ^= 0x01
    try corrupted.write(to: rootObject, options: .atomic)
    guard chmod(rootObject.path, mode_t(0o600)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    do {
        _ = try map.lookup(root: mapRoot, key: "event")
        XCTFail("corrupt content-addressed node must fail closed")
    } catch let error as PersistentProjectionRadixMap.MapError {
        XCTAssertTrue(error == .invalidObject || error == .checksumMismatch)
    }

    let foreignNamespace = try radixMap(at: directory, namespaceID: "another-namespace")
    expectRadixMapError(.mixedScope) {
        _ = try foreignNamespace.lookup(root: mapRoot, key: "event")
    }
    let foreignGeneration = try radixMap(
        at: directory, sourceGeneration: String(repeating: "b", count: 64))
    expectRadixMapError(.mixedScope) {
        _ = try foreignGeneration.lookup(root: mapRoot, key: "event")
    }
    let foreignKind = try radixMap(at: directory, mapKind: "message-parents")
    expectRadixMapError(.mixedScope) {
        _ = try foreignKind.lookup(root: mapRoot, key: "event")
    }
}

private func testPersistentRadixMapBoundsDepthAndDeterministicRootCoding() throws {
    let root = try radixMapTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let map = try radixMap(
        at: root.appending(path: "map", directoryHint: .isDirectory),
        limits: PersistentProjectionRadixMap.Limits(
            maximumKeyBytes: 4, maximumValueBytes: 4,
            maximumObjectBytes: 128 * 1_024, maximumCollisionEntries: 4))
    expectRadixMapError(.keyTooLarge) {
        _ = try map.setting(root: nil, key: "12345", value: Data())
    }
    expectRadixMapError(.valueTooLarge) {
        _ = try map.setting(root: nil, key: "key", value: Data("12345".utf8))
    }
    expectRadixMapError(.invalidIdentity) {
        _ = try map.setting(root: nil, key: Data(), value: Data())
    }

    let inserted = try map.setting(root: nil, key: "key", value: Data("data".utf8))
    XCTAssertEqual(inserted.metrics.maximumDepthVisited, PersistentProjectionRadixMap.trieDepth)
    XCTAssertEqual(inserted.metrics.nodesVisited, PersistentProjectionRadixMap.trieDepth + 1)
    XCTAssertEqual(inserted.metrics.objectsCreated, PersistentProjectionRadixMap.trieDepth + 2)
    XCTAssertTrue(inserted.metrics.peakObjectBytes <= map.limits.maximumObjectBytes)
    let exact = try map.lookup(root: inserted.newRoot, key: "key")
    XCTAssertEqual(exact.value, Data("data".utf8))
    XCTAssertEqual(exact.metrics.nodesVisited, PersistentProjectionRadixMap.trieDepth + 1)
    XCTAssertEqual(exact.metrics.maximumDepthVisited, PersistentProjectionRadixMap.trieDepth)
    XCTAssertEqual(
        exact.metrics.objectsRead, PersistentProjectionRadixMap.maximumLookupObjectReads)
    XCTAssertTrue(exact.metrics.peakObjectBytes <= map.limits.maximumObjectBytes)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encodedOne = try encoder.encode(inserted.newRoot)
    let encodedTwo = try encoder.encode(inserted.newRoot)
    XCTAssertEqual(encodedOne, encodedTwo)
    let decoded = try JSONDecoder().decode(
        PersistentProjectionRadixMap.Root.self, from: encodedOne)
    XCTAssertEqual(decoded, inserted.newRoot)
    try map.validate(root: decoded)
    XCTAssertFalse(String(decoding: encodedOne, as: UTF8.self).contains("data"))

    var forgedObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encodedOne) as? [String: Any])
    forgedObject["entryCount"] = 0
    let forgedBytes = try JSONSerialization.data(withJSONObject: forgedObject)
    let forged = try JSONDecoder().decode(
        PersistentProjectionRadixMap.Root.self, from: forgedBytes)
    expectRadixMapError(.invalidRoot) {
        try map.validate(root: forged)
    }

    expectRadixMapError(.invalidIdentity) {
        _ = try radixMap(
            at: root.appending(path: "oversize-identity", directoryHint: .isDirectory),
            namespaceID: String(repeating: "n", count: 513))
    }
}

private func testPersistentRadixMapPrivateNoFollowFiles() throws {
    let root = try radixMapTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "map", directoryHint: .isDirectory)
    let map = try radixMap(at: directory)
    let inserted = try map.setting(root: nil, key: "key", value: Data("private".utf8))
    let mapRoot = try XCTUnwrap(inserted.newRoot)
    let reopened = try radixMap(at: directory)
    try reopened.validate(root: mapRoot)
    XCTAssertEqual(try reopened.lookup(root: mapRoot, key: "key").value, Data("private".utf8))
    let rootObject = directory.appending(
        path: "nodes/\(mapRoot.objectID).node", directoryHint: .notDirectory)
    var status = stat()
    XCTAssertEqual(lstat(rootObject.path, &status), 0)
    XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
    XCTAssertEqual(lstat(directory.path, &status), 0)
    XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o700))
    let objectNames = try FileManager.default.contentsOfDirectory(
        atPath: directory.appending(path: "nodes", directoryHint: .isDirectory).path)
        + FileManager.default.contentsOfDirectory(
            atPath: directory.appending(path: "values", directoryHint: .isDirectory).path)
    XCTAssertFalse(objectNames.contains { $0.hasPrefix(".radix-tmp-") })

    try FileManager.default.removeItem(at: rootObject)
    XCTAssertEqual(symlink("/dev/null", rootObject.path), 0)
    expectRadixMapError(.symlinkOrNonRegularFile) {
        _ = try map.lookup(root: mapRoot, key: "key")
    }

    let real = root.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    guard chmod(real.path, mode_t(0o700)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    let linked = root.appending(path: "linked", directoryHint: .isDirectory)
    XCTAssertEqual(symlink(real.path, linked.path), 0)
    expectRadixMapError(.symlinkOrNonRegularFile) {
        _ = try radixMap(at: linked)
    }

    let publicDirectory = root.appending(path: "public", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: false)
    guard chmod(publicDirectory.path, mode_t(0o755)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    expectRadixMapError(.insecurePermissions) {
        _ = try radixMap(at: publicDirectory)
    }

    let missingParentMap = root
        .appending(path: "missing-parent", directoryHint: .isDirectory)
        .appending(path: "map", directoryHint: .isDirectory)
    expectRadixMapError(.insecurePermissions) {
        _ = try radixMap(at: missingParentMap)
    }
}

let casesPersistentProjectionRadixMap: [Case] = [
    ("phase1 radix map: deterministic copy-on-write CRUD", {
        try testPersistentRadixMapDeterministicCopyOnWriteCRUD()
    }),
    ("phase1 radix map: exact key fallback survives forced route collisions", {
        try testPersistentRadixMapExactCollisionFallback()
    }),
    ("phase1 radix map: corrupt missing and mixed-scope objects fail closed", {
        try testPersistentRadixMapMissingCorruptAndMixedScopeFailClosed()
    }),
    ("phase1 radix map: bounds depth metrics and root coding are deterministic", {
        try testPersistentRadixMapBoundsDepthAndDeterministicRootCoding()
    }),
    ("phase1 radix map: durable objects are private and no-follow", {
        try testPersistentRadixMapPrivateNoFollowFiles()
    }),
]
