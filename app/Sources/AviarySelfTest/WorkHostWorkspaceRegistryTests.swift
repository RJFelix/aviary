import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import AviaryCore

private struct WorkHostWorkspaceRegistryFixture {
    let root: URL
    let home: AgentHome
    let first: URL
    let second: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "aviary-workspace-registry-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory)
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        first = root.appending(path: "first", directoryHint: .isDirectory)
        second = root.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func workspaceRegistryExpectError(
    _ operation: () throws -> Void,
    _ expected: WorkHostWorkspaceRegistryError
) {
    do {
        try operation()
        XCTFail("expected \(expected)")
    } catch let error as WorkHostWorkspaceRegistryError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("unexpected workspace registry error: \(error)")
    }
}

private func workspaceRegistryWrite(
    _ data: Data,
    to url: URL,
    mode: mode_t = mode_t(0o600)
) throws {
    guard FileManager.default.createFile(
        atPath: url.path,
        contents: data,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
        throw WorkHostWorkspaceRegistryError.ioFailure
    }
    guard chmod(url.path, mode) == 0 else {
        throw WorkHostWorkspaceRegistryError.ioFailure
    }
}

private func workspaceRegistryCanonicalPath(_ url: URL) -> String {
    guard let pointer = url.path.withCString({ realpath($0, nil) }) else {
        return url.standardizedFileURL.path
    }
    defer { free(pointer) }
    return String(cString: pointer)
}

func test_workHostWorkspaceRegistryStableAcrossReopen() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }

    let firstRegistry = try WorkHostWorkspaceRegistry(home: fixture.home)
    let first = try firstRegistry.registerLocalDirectory(
        fixture.first, label: "Project", isDefault: true)
    let reopened = try WorkHostWorkspaceRegistry(home: fixture.home)
    let second = try reopened.registerLocalDirectory(fixture.first)

    XCTAssertEqual(first.workspaceID, second.workspaceID)
    XCTAssertEqual(second.label, "Project")
    XCTAssertTrue(second.isDefault)
    XCTAssertEqual(try reopened.catalog().entries.count, 1)
    XCTAssertEqual(try reopened.catalog().revision, 1)
}

func test_workHostWorkspaceRegistryConcurrentSamePathConverges() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }

    let resultLock = NSLock()
    var IDs: [WorkHostWorkspaceID] = []
    var errors: [Error] = []
    DispatchQueue.concurrentPerform(iterations: 24) { index in
        do {
            let registry = try WorkHostWorkspaceRegistry(home: fixture.home)
            let descriptor = try registry.registerLocalDirectory(
                fixture.first, label: index == 0 ? "Concurrent" : nil)
            resultLock.lock()
            IDs.append(descriptor.workspaceID)
            resultLock.unlock()
        } catch {
            resultLock.lock()
            errors.append(error)
            resultLock.unlock()
        }
    }

    XCTAssertTrue(errors.isEmpty, "concurrent registration errors: \(errors)")
    XCTAssertEqual(Set(IDs).count, 1)
    let registry = try WorkHostWorkspaceRegistry(home: fixture.home)
    XCTAssertEqual(try registry.catalog().entries.count, 1)
}

func test_workHostWorkspaceRegistryDistinctPathsAndDefaultSemantics() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }
    let registry = try WorkHostWorkspaceRegistry(home: fixture.home)

    let first = try registry.registerLocalDirectory(
        fixture.first, label: "First", isDefault: false)
    let second = try registry.registerLocalDirectory(
        fixture.second, label: "Second", isDefault: true)
    XCTAssertNotEqual(first.workspaceID, second.workspaceID)

    var catalog = try registry.catalog()
    XCTAssertEqual(catalog.entries.count, 2)
    XCTAssertEqual(catalog.entries.filter(\.isDefault).count, 1)
    XCTAssertEqual(catalog.defaultWorkspace?.workspaceID, second.workspaceID)

    let promoted = try registry.registerLocalDirectory(
        fixture.first, label: nil, isDefault: true)
    XCTAssertEqual(promoted.workspaceID, first.workspaceID)
    catalog = try registry.catalog()
    XCTAssertEqual(catalog.entries.filter(\.isDefault).map(\.workspaceID), [first.workspaceID])

    // An omitted/false default request is idempotent and does not clear the selected default.
    _ = try registry.registerLocalDirectory(fixture.first, isDefault: false)
    catalog = try registry.catalog()
    XCTAssertEqual(catalog.entries.filter(\.isDefault).map(\.workspaceID), [first.workspaceID])
}

func test_workHostWorkspaceRegistryResolvesOnlyAfterCurrentValidation() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }
    let registry = try WorkHostWorkspaceRegistry(home: fixture.home)
    let descriptor = try registry.registerLocalDirectory(fixture.first)

    let resolved = try registry.resolve(descriptor.workspaceID)
    XCTAssertEqual(workspaceRegistryCanonicalPath(resolved),
                   workspaceRegistryCanonicalPath(fixture.first))

    let replacement = fixture.root.appending(path: "replacement", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: fixture.first)
    try FileManager.default.createSymbolicLink(at: fixture.first, withDestinationURL: replacement)
    workspaceRegistryExpectError({ _ = try registry.resolve(descriptor.workspaceID) }, .workspaceSymlink)

    // Replacing the symlink with a different real directory must not silently rebind the opaque
    // identity. A path match is not an identity match.
    try FileManager.default.removeItem(at: fixture.first)
    try FileManager.default.createDirectory(at: fixture.first, withIntermediateDirectories: true)
    workspaceRegistryExpectError({ _ = try registry.resolve(descriptor.workspaceID) }, .workspaceIdentityMismatch)
}

func test_workHostWorkspaceRegistryPublicProjectionIsPathFree() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }
    let registry = try WorkHostWorkspaceRegistry(home: fixture.home)
    _ = try registry.registerLocalDirectory(fixture.first, label: "Safe label")
    let catalog = try registry.catalog()
    let encoded = try JSONEncoder().encode(catalog)
    let json = String(decoding: encoded, as: UTF8.self)

    XCTAssertFalse(json.contains(fixture.root.path))
    XCTAssertFalse(json.contains(fixture.home.root.path))
    XCTAssertFalse(json.contains(NSUserName()))
    XCTAssertFalse(json.contains("pid"))
    XCTAssertTrue(json.contains("workspaceID"))
    XCTAssertTrue(json.contains("isComplete"))
}

func test_workHostWorkspaceRegistryRejectsSymlinksAndInvalidLabelsOrIDs() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }
    let registry = try WorkHostWorkspaceRegistry(home: fixture.home)
    let symlink = fixture.root.appending(path: "first-link", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.first)

    workspaceRegistryExpectError({
        _ = try registry.registerLocalDirectory(symlink)
    }, .workspaceSymlink)
    workspaceRegistryExpectError({
        _ = try registry.registerLocalDirectory(fixture.first, label: "\u{0000}")
    }, .invalidLabel)
    workspaceRegistryExpectError({
        _ = try registry.registerLocalDirectory(
            fixture.first, label: String(repeating: "x", count: 129))
    }, .invalidLabel)
    for label in ["/tmp/project", "file:///tmp/project", "~/project", "../project", "C:\\project", "C:project"] {
        workspaceRegistryExpectError({
            _ = try registry.registerLocalDirectory(fixture.first, label: label)
        }, .invalidLabel)
    }
    let descriptorID = try WorkHostWorkspaceID(
        "workspace-00000000-0000-0000-0000-000000000099")
    for label in ["/tmp/project", "file:///tmp/project", "~/project", "../project"] {
        workspaceRegistryExpectError({
            _ = try WorkHostWorkspaceDescriptor(workspaceID: descriptorID, label: label)
        }, .invalidLabel)
    }
    workspaceRegistryExpectError({ _ = try registry.resolve("workspace-not-an-id") }, .invalidWorkspaceID)
    workspaceRegistryExpectError({
        _ = try registry.registerLocalDirectory(URL(fileURLWithPath: "/dev/null"))
    }, .workspaceNotDirectory)
}

func test_workHostWorkspaceRegistryMalformedOversizedAndNonPrivateFailClosed() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }
    let file = fixture.home.workHostWorkspaceRegistryFile

    let malformed = Data("not-json".utf8)
    try workspaceRegistryWrite(malformed, to: file)
    workspaceRegistryExpectError({ _ = try WorkHostWorkspaceRegistry(home: fixture.home) }, .malformedRegistry)
    XCTAssertEqual(try Data(contentsOf: file), malformed)
    try FileManager.default.removeItem(at: file)

    let oversized = Data(repeating: 0x78, count: WorkHostWorkspaceRegistry.defaultMaximumRecordBytes + 1)
    try workspaceRegistryWrite(oversized, to: file)
    workspaceRegistryExpectError({ _ = try WorkHostWorkspaceRegistry(home: fixture.home) }, .registryTooLarge)
    XCTAssertEqual(try Data(contentsOf: file), oversized)
    try FileManager.default.removeItem(at: file)

    let privateBytes = Data("{}".utf8)
    try workspaceRegistryWrite(privateBytes, to: file, mode: mode_t(0o644))
    workspaceRegistryExpectError({ _ = try WorkHostWorkspaceRegistry(home: fixture.home) }, .registryNotPrivate)
    XCTAssertEqual(try Data(contentsOf: file), privateBytes)
    try FileManager.default.removeItem(at: file)

    let target = fixture.root.appending(path: "registry-target.json", directoryHint: .notDirectory)
    try workspaceRegistryWrite(Data("not-json".utf8), to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    workspaceRegistryExpectError({ _ = try WorkHostWorkspaceRegistry(home: fixture.home) }, .registrySymlink)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
}

func test_workHostWorkspaceRegistryCapacityPreservesDurableBytesAndBoundsValues() throws {
    let fixture = try WorkHostWorkspaceRegistryFixture()
    defer { fixture.tearDown() }
    let registry = try WorkHostWorkspaceRegistry(
        home: fixture.home,
        bounds: WorkHostWorkspaceRegistryBounds(maxEntries: 1))
    let first = try registry.registerLocalDirectory(fixture.first, label: "one")
    let before = try Data(contentsOf: fixture.home.workHostWorkspaceRegistryFile)

    workspaceRegistryExpectError({
        _ = try registry.registerLocalDirectory(fixture.second, label: "two")
    }, .capacityExceeded)
    XCTAssertEqual(try Data(contentsOf: fixture.home.workHostWorkspaceRegistryFile), before)

    XCTAssertTrue(first.workspaceID.rawValue.utf8.count <= WorkHostWorkspaceID.maximumBytes)
    XCTAssertTrue(first.label?.utf8.count ?? 0 <= WorkHostWorkspaceRegistry.defaultMaximumLabelBytes)
    XCTAssertEqual(try registry.catalog().entries.count, 1)
}

func test_workHostWorkspaceCatalogRejectsLossyOrConflictingProjection() throws {
    let firstID = try WorkHostWorkspaceID("workspace-00000000-0000-0000-0000-000000000001")
    let secondID = try WorkHostWorkspaceID("workspace-00000000-0000-0000-0000-000000000002")
    let first = try WorkHostWorkspaceDescriptor(
        workspaceID: firstID, label: "first", isDefault: true,
        availability: .available, capabilities: [.directory])
    let duplicate = try WorkHostWorkspaceDescriptor(
        workspaceID: firstID, label: "duplicate", availability: .available)
    let secondDefault = try WorkHostWorkspaceDescriptor(
        workspaceID: secondID, label: "second", isDefault: true,
        availability: .available)

    workspaceRegistryExpectError({
        _ = try WorkHostWorkspaceCatalog(entries: [first, duplicate], revision: 1)
    }, .malformedRegistry)
    workspaceRegistryExpectError({
        _ = try WorkHostWorkspaceCatalog(entries: [first, secondDefault], revision: 1)
    }, .malformedRegistry)
    let oversized = (0...WorkHostWorkspaceRegistry.maximumEntries).map { index in
        try! WorkHostWorkspaceDescriptor(
            workspaceID: try! WorkHostWorkspaceID(String(format:
                "workspace-00000000-0000-0000-0000-%012x", index)),
            availability: .available)
    }
    workspaceRegistryExpectError({
        _ = try WorkHostWorkspaceCatalog(entries: oversized, revision: 1)
    }, .malformedRegistry)

    let duplicateWire = Data("""
    {"entries":[
      {"workspaceID":"workspace-00000000-0000-0000-0000-000000000001","label":"first","isDefault":false,"availability":"available","capabilities":[]},
      {"workspaceID":"workspace-00000000-0000-0000-0000-000000000001","label":"other","isDefault":false,"availability":"available","capabilities":[]}
    ],"revision":1,"isComplete":true}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(WorkHostWorkspaceCatalog.self, from: duplicateWire)
        XCTFail("duplicate workspace IDs must be rejected while decoding")
    } catch {
        XCTAssertTrue(true)
    }

    let sorted = try WorkHostWorkspaceCatalog(
        entries: [secondDefault, try WorkHostWorkspaceDescriptor(
            workspaceID: firstID, label: "first", availability: .available)],
        revision: 2)
    XCTAssertEqual(sorted.entries.map(\.workspaceID), [firstID, secondID])
}

let casesWorkHostWorkspaceRegistry: [Case] = [
    ("phase3 workspace registry: stable reopen", {
        try test_workHostWorkspaceRegistryStableAcrossReopen()
    }),
    ("phase3 workspace registry: concurrent same-path dedupe", {
        try test_workHostWorkspaceRegistryConcurrentSamePathConverges()
    }),
    ("phase3 workspace registry: distinct paths and defaults", {
        try test_workHostWorkspaceRegistryDistinctPathsAndDefaultSemantics()
    }),
    ("phase3 workspace registry: current resolution validation", {
        try test_workHostWorkspaceRegistryResolvesOnlyAfterCurrentValidation()
    }),
    ("phase3 workspace registry: path-free public projection", {
        try test_workHostWorkspaceRegistryPublicProjectionIsPathFree()
    }),
    ("phase3 workspace registry: symlink and value rejection", {
        try test_workHostWorkspaceRegistryRejectsSymlinksAndInvalidLabelsOrIDs()
    }),
    ("phase3 workspace registry: malformed storage fails closed", {
        try test_workHostWorkspaceRegistryMalformedOversizedAndNonPrivateFailClosed()
    }),
    ("phase3 workspace registry: capacity preserves bytes and bounds", {
        try test_workHostWorkspaceRegistryCapacityPreservesDurableBytesAndBoundsValues()
    }),
    ("phase3 workspace registry: public catalog rejects lossy conflicts", {
        try test_workHostWorkspaceCatalogRejectsLossyOrConflictingProjection()
    }),
]
