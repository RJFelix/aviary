import Foundation
@testable import AviaryCore

private func wireLogDirectoryStoreFixture(_ name: String) -> (WireLogDirectoryStore, URL) {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-wire-log-dir-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    return (WireLogDirectoryStore(home: home), root)
}

private func assertWireLogDirectoryStoreError(
    _ expected: WireLogDirectoryStoreError,
    _ body: () throws -> Void,
    line: Int = #line
) {
    do {
        try body()
        XCTFail("expected wire-log directory store failure", line: line)
    } catch let error as WireLogDirectoryStoreError {
        XCTAssertEqual(error, expected, line: line)
    } catch {
        XCTFail("unexpected wire-log directory store error: \(error)", line: line)
    }
}

func testWireLogDirectoryStoreDefaultsToWireLogDirectoryAndRetainsHistory() throws {
    let (store, root) = wireLogDirectoryStoreFixture("history")
    defer { try? FileManager.default.removeItem(at: root) }

    let initial = try store.load()
    let defaultDirectory = WireLog.directory.standardizedFileURL
    XCTAssertEqual(initial.directory, defaultDirectory)
    XCTAssertEqual(initial.knownDirectories, [defaultDirectory])

    let firstDirectory = root.appending(path: "logs/first", directoryHint: .isDirectory)
    let first = try store.select(directory: firstDirectory)
    XCTAssertEqual(first.directory, firstDirectory.standardizedFileURL)
    XCTAssertEqual(first.knownDirectories, [firstDirectory.standardizedFileURL, defaultDirectory])
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory.path))

    let beforeSecondSelection = try Data(contentsOf: store.configurationURL)
    let secondDirectory = root.appending(path: "logs/second", directoryHint: .isDirectory)
    let second = try store.select(directory: secondDirectory)
    XCTAssertEqual(second.knownDirectories, [
        secondDirectory.standardizedFileURL,
        firstDirectory.standardizedFileURL,
        defaultDirectory,
    ])

    let reloaded = try WireLogDirectoryStore(
        home: AgentHome(root: store.configurationURL.deletingLastPathComponent())).load()
    XCTAssertEqual(reloaded, second)
    let backups = try FileManager.default.contentsOfDirectory(
        at: store.configurationURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(
            "\(WireLogDirectoryStore.configurationFilename).aviary-bak-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: backups[0]), beforeSecondSelection)
}

func testWireLogDirectoryStoreRejectsMalformedConfigWithoutDefaultFallback() throws {
    let (store, root) = wireLogDirectoryStoreFixture("malformed")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: store.configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let malformed = Data("not-json".utf8)
    try malformed.write(to: store.configurationURL, options: [.atomic])

    assertWireLogDirectoryStoreError(.invalidConfiguration) { _ = try store.load() }
    assertWireLogDirectoryStoreError(.invalidConfiguration) {
        _ = try store.select(directory: root.appending(path: "logs"))
    }
    XCTAssertEqual(try Data(contentsOf: store.configurationURL), malformed,
                   "invalid configuration must not be repaired by silently using the default")
}

func testWireLogDirectoryStoreExplicitResetBacksUpMalformedBytesAndKeepsLogs() throws {
    let (store, root) = wireLogDirectoryStoreFixture("reset-malformed")
    defer { try? FileManager.default.removeItem(at: root) }
    let customDirectory = root.appending(path: "custom-logs", directoryHint: .isDirectory)
    _ = try store.select(directory: customDirectory)
    let log = customDirectory.appending(path: "run-preserved.jsonl", directoryHint: .notDirectory)
    let logBytes = Data("full provider request log".utf8)
    try logBytes.write(to: log)

    let malformed = Data([0x7B, 0x00, 0xFF, 0x0A, 0x7D])
    try malformed.write(to: store.configurationURL, options: [.atomic])
    assertWireLogDirectoryStoreError(.invalidConfiguration) { _ = try store.load() }

    let selection = try store.resetToDefault()
    let defaultDirectory = WireLog.directory.standardizedFileURL
    XCTAssertEqual(selection.directory, defaultDirectory)
    XCTAssertEqual(selection.knownDirectories, [defaultDirectory])
    XCTAssertEqual(try Data(contentsOf: log), logBytes,
                   "reset changes only the directory setting, not any saved logs")

    let backups = try FileManager.default.contentsOfDirectory(
        at: store.configurationURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(
            "\(WireLogDirectoryStore.configurationFilename).aviary-bak-") }
    XCTAssertEqual(backups.count, 1, "the malformed config should have one reset backup")
    let exactMalformedBackups = try backups.filter { try Data(contentsOf: $0) == malformed }
    XCTAssertEqual(exactMalformedBackups.count, 1,
                   "reset must preserve the exact bytes of the malformed regular config")

    let reopened = WireLogDirectoryStore(
        home: AgentHome(root: store.configurationURL.deletingLastPathComponent()))
    XCTAssertEqual(try reopened.load(), selection)
}

func testWireLogDirectoryStoreResetWithMissingConfigAndRejectsNonRegularConfig() throws {
    let (store, root) = wireLogDirectoryStoreFixture("reset-missing")
    defer { try? FileManager.default.removeItem(at: root) }

    let defaultDirectory = WireLog.directory.standardizedFileURL
    let initialReset = try store.resetToDefault()
    XCTAssertEqual(initialReset, WireLogDirectoryStore.Selection(
        directory: defaultDirectory, knownDirectories: [defaultDirectory]))
    XCTAssertEqual(try store.load(), initialReset)
    let initialBackups = try FileManager.default.contentsOfDirectory(
        at: store.configurationURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(
            "\(WireLogDirectoryStore.configurationFilename).aviary-bak-") }
    XCTAssertTrue(initialBackups.isEmpty, "missing settings need no backup")

    let target = root.appending(path: "target.json")
    try Data("do not alter".utf8).write(to: target)
    try FileManager.default.removeItem(at: store.configurationURL)
    try FileManager.default.createSymbolicLink(
        at: store.configurationURL, withDestinationURL: target)
    assertWireLogDirectoryStoreError(.invalidConfiguration) { _ = try store.resetToDefault() }
    XCTAssertEqual(try Data(contentsOf: target), Data("do not alter".utf8))

    try FileManager.default.removeItem(at: store.configurationURL)
    try FileManager.default.createDirectory(at: store.configurationURL, withIntermediateDirectories: false)
    assertWireLogDirectoryStoreError(.invalidConfiguration) { _ = try store.resetToDefault() }
}

func testWireLogDirectoryStoreCreatesAndChecksSelectedDirectory() throws {
    let (store, root) = wireLogDirectoryStoreFixture("create-and-check")
    defer { try? FileManager.default.removeItem(at: root) }
    let selectedURL = root.appending(path: "nested/new-logs", directoryHint: .isDirectory)
    let selected = try store.select(directory: selectedURL)
    XCTAssertEqual(selected.directory, selectedURL.standardizedFileURL)
    let contents = try FileManager.default.contentsOfDirectory(
        at: selected.directory, includingPropertiesForKeys: nil)
    XCTAssertTrue(contents.isEmpty, "the writability probe must be removed")

    try FileManager.default.removeItem(at: selected.directory)
    XCTAssertEqual(try store.load(), selected,
                   "history remains discoverable when its directory is temporarily absent")
    assertWireLogDirectoryStoreError(.directoryUnavailable) {
        _ = try store.resolveForCreate()
    }
}

func testWireLogDirectoryStoreRejectsInvalidAndOversizedPaths() throws {
    let (store, root) = wireLogDirectoryStoreFixture("paths")
    defer { try? FileManager.default.removeItem(at: root) }

    assertWireLogDirectoryStoreError(.invalidDirectory) {
        _ = try store.select(directory: URL(string: "https://example.com/logs")!)
    }
    let oversized = URL(fileURLWithPath: "/" + String(
        repeating: "x", count: WireLogDirectoryStore.maximumPathBytes))
    assertWireLogDirectoryStoreError(.invalidDirectory) {
        _ = try store.select(directory: oversized)
    }
}

func testWireLogDirectoryStoreNeverEvictsKnownDirectories() throws {
    let (store, root) = wireLogDirectoryStoreFixture("bounded-history")
    defer { try? FileManager.default.removeItem(at: root) }

    var selected: [URL] = []
    for index in 0..<(WireLogDirectoryStore.maximumKnownDirectories - 1) {
        let directory = root.appending(path: "logs/\(index)", directoryHint: .isDirectory)
        selected.append(directory.standardizedFileURL)
        _ = try store.select(directory: directory)
    }
    let full = try store.load()
    XCTAssertEqual(full.knownDirectories.count, WireLogDirectoryStore.maximumKnownDirectories)
    XCTAssertTrue(full.knownDirectories.contains(WireLog.directory.standardizedFileURL))
    XCTAssertTrue(selected.allSatisfy(full.knownDirectories.contains))

    let rejected = root.appending(path: "logs/rejected", directoryHint: .isDirectory)
    assertWireLogDirectoryStoreError(
        .knownDirectoryLimitReached(WireLogDirectoryStore.maximumKnownDirectories)) {
            _ = try store.select(directory: rejected)
        }
    XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path),
                   "limit failure should happen before creating an untracked destination")

    let reselected = try store.select(directory: selected[0])
    XCTAssertEqual(reselected.knownDirectories.count, WireLogDirectoryStore.maximumKnownDirectories)
    XCTAssertTrue(reselected.knownDirectories.contains(WireLog.directory.standardizedFileURL))
}

func testWireLogDirectoryStoreConcurrentInstancesMergeSelections() throws {
    let (firstStore, root) = wireLogDirectoryStoreFixture("concurrent-select")
    defer { try? FileManager.default.removeItem(at: root) }
    let secondStore = WireLogDirectoryStore(
        home: AgentHome(root: firstStore.configurationURL.deletingLastPathComponent()))
    let seed = root.appending(path: "logs/seed", directoryHint: .isDirectory)
    _ = try firstStore.select(directory: seed)

    let stores = [firstStore, secondStore]
    let paths = [
        root.appending(path: "logs/concurrent-a", directoryHint: .isDirectory).standardizedFileURL,
        root.appending(path: "logs/concurrent-b", directoryHint: .isDirectory).standardizedFileURL,
    ]
    let ready = DispatchGroup()
    let finished = DispatchGroup()
    let start = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var failures: [String] = []

    for index in stores.indices {
        ready.enter()
        finished.enter()
        DispatchQueue.global().async {
            ready.leave()
            start.wait()
            defer { finished.leave() }
            do {
                _ = try stores[index].select(directory: paths[index])
            } catch {
                resultLock.lock()
                failures.append(error.localizedDescription)
                resultLock.unlock()
            }
        }
    }
    ready.wait()
    start.signal()
    start.signal()
    finished.wait()

    XCTAssertTrue(failures.isEmpty, "concurrent selections failed: \(failures)")
    let merged = try firstStore.load()
    XCTAssertTrue(merged.knownDirectories.contains(seed.standardizedFileURL))
    XCTAssertTrue(paths.allSatisfy(merged.knownDirectories.contains),
                  "both concurrently selected directories must survive the merge")
    XCTAssertTrue(merged.knownDirectories.contains(WireLog.directory.standardizedFileURL))
}
