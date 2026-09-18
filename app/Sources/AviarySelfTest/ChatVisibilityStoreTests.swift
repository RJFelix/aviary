import Foundation
@testable import AviaryCore

private func chatVisibilityTestHome() throws -> (AgentHome, URL) {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-chat-visibility-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory)), root)
}

func test_chatVisibilityStoreRoundTripsStablePendingAndNativeIdentities() throws {
    let (home, root) = try chatVisibilityTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatVisibilityStore(home: home)
    let pending = ChatVisibilityIdentity.pending(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    let journal = JournalRef.session(
        SessionRef("native-session"), journalID: "session-journal",
        authority: TimelineAuthorityRef("authority"))
    let native = ChatVisibilityIdentity.nativeSession(journal: journal)
    XCTAssertEqual(try store.setHidden(true, identity: pending), Set([pending]))
    XCTAssertEqual(try store.setHidden(true, identity: native), Set([native, pending]))
    XCTAssertEqual(try ChatVisibilityStore(home: home).load(), Set([native, pending]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
}

func test_chatVisibilityStoreRestoreDoesNotTouchSourceFiles() throws {
    let (home, root) = try chatVisibilityTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = home.root.appending(path: "sessions/source.jsonl")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sourceBytes = Data("source remains exact\n".utf8)
    try sourceBytes.write(to: source)
    let store = ChatVisibilityStore(home: home)
    let identity = try XCTUnwrap(ChatVisibilityIdentity.legacySession(id: "source"))
    _ = try store.setHidden(true, identity: identity)
    _ = try store.setHidden(false, identity: identity)
    XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    XCTAssertTrue(try store.load().isEmpty)
}

func test_chatVisibilityStoreMigratesPendingHiddenIdentityToNativeSession() throws {
    let (home, root) = try chatVisibilityTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatVisibilityStore(home: home)
    let pending = ChatVisibilityIdentity.pending(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    let journal = JournalRef.session(
        SessionRef("native-session"), journalID: "session-journal",
        authority: TimelineAuthorityRef("authority"))
    let native = ChatVisibilityIdentity.nativeSession(journal: journal)
    _ = try store.setHidden(true, identity: pending)
    XCTAssertEqual(
        try store.aliasHidden(from: pending, to: native), Set([pending, native]))
    XCTAssertEqual(try ChatVisibilityStore(home: home).load(), Set([pending, native]))
    XCTAssertEqual(
        try store.retirePendingAlias(pending, canonical: native), Set([native]))
    XCTAssertEqual(try ChatVisibilityStore(home: home).load(), Set([native]))
}

func test_chatVisibilityStoreExplicitNativeRestoreWinsPendingRetirement() throws {
    let (home, root) = try chatVisibilityTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatVisibilityStore(home: home)
    let pending = ChatVisibilityIdentity.pending(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    let native = ChatVisibilityIdentity.nativeSession(journal: .session(
        SessionRef("native-session"), journalID: "session-journal",
        authority: TimelineAuthorityRef("authority")))
    _ = try store.setHidden(true, identity: pending)
    _ = try store.aliasHidden(from: pending, to: native)
    _ = try store.setHidden(false, identity: native)
    _ = try store.retirePendingAlias(pending, canonical: native)
    XCTAssertTrue(try store.load().isEmpty)
    _ = try store.setHidden(true, identity: pending)
    _ = try store.aliasHidden(from: pending, to: native)
    _ = try store.setHidden(false, identities: Set([pending, native]))
    XCTAssertTrue(try store.load().isEmpty)
    _ = try store.retirePendingAlias(pending, canonical: native)
    XCTAssertTrue(try store.load().isEmpty)
}

func test_chatVisibilityStoreMigrationFailurePreservesSidecarBytes() throws {
    let (home, root) = try chatVisibilityTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatVisibilityStore(home: home)
    let pending = ChatVisibilityIdentity.pending(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    _ = try store.setHidden(true, identity: pending)
    let before = Data("not-json".utf8)
    try before.write(to: store.fileURL, options: .atomic)
    let native = ChatVisibilityIdentity.nativeSession(journal: .session(
        SessionRef("native-session"), journalID: "session-journal",
        authority: TimelineAuthorityRef("authority")))
    do {
        _ = try store.retirePendingAlias(pending, canonical: native)
        XCTFail("migration unexpectedly replaced unreadable state")
    } catch ChatVisibilityStoreError.malformed { }
    catch { XCTFail("unexpected migration error: \(error)") }
    XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
}

func test_chatVisibilityStoreRejectsMalformedStateInsteadOfTreatingItAsEmpty() throws {
    let (home, root) = try chatVisibilityTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatVisibilityStore(home: home)
    try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: store.fileURL)
    do {
        _ = try store.load()
        XCTFail("malformed hidden-chat state unexpectedly loaded as empty")
    } catch ChatVisibilityStoreError.malformed { }
    catch { XCTFail("unexpected hidden-chat load error: \(error)") }
}

func test_chatVisibilityStoreFailedReadDoesNotOverwriteExistingState() throws {
    let (home, root) = try chatVisibilityTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatVisibilityStore(home: home)
    let identity = ChatVisibilityIdentity.pending(UUID())
    _ = try store.setHidden(true, identity: identity)
    let malformed = Data("not-json".utf8)
    try malformed.write(to: store.fileURL, options: .atomic)
    do {
        _ = try store.setHidden(true, identity: ChatVisibilityIdentity.pending(UUID()))
        XCTFail("failed read unexpectedly overwrote state")
    } catch ChatVisibilityStoreError.malformed { }
    catch { XCTFail("unexpected failed-read error: \(error)") }
    XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
}

func test_chatVisibilityIdentityRejectsTransientOrOversizedValues() {
    XCTAssertNil(ChatVisibilityIdentity(rawValue: "live|process-only"))
    XCTAssertNil(ChatVisibilityIdentity.legacySession(id: String(repeating: "x", count: 1_025)))
    XCTAssertNil(ChatVisibilityIdentity(rawValue: "pending|not-a-uuid"))
}

let casesChatVisibilityStore: [Case] = [
    ("chat visibility: restore clears startup aliases and wins retirement", {
        try test_chatVisibilityStoreExplicitNativeRestoreWinsPendingRetirement()
    }),
    ("chat visibility: concurrent updates retain every hidden identity", {
        let (home, root) = try chatVisibilityTestHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let identities = (0..<16).map { _ in ChatVisibilityIdentity.pending(UUID()) }
        let failureLock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: identities.count) { index in
            do { try ChatVisibilityStore(home: home).setHidden(true, identity: identities[index]) }
            catch { failureLock.lock(); failures += 1; failureLock.unlock() }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try ChatVisibilityStore(home: home).load(), Set(identities))
    }),
    ("chat visibility: oversized state and invalid native identity cannot overwrite preferences", {
        let (home, root) = try chatVisibilityTestHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatVisibilityStore(home: home)
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        let oversized = Data(repeating: 32, count: 8 * 1_024 * 1_024 + 1)
        try oversized.write(to: store.fileURL)
        do {
            try store.setHidden(true, identity: .pending(UUID()))
            XCTFail("Oversized hidden state was overwritten")
        } catch ChatVisibilityStoreError.malformed { }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), oversized)
        let invalid = ChatVisibilityIdentity.nativeSession(journal: .session(
            SessionRef(String(repeating: "s", count: 4_096)), journalID: "j",
            authority: TimelineAuthorityRef("host")))
        do {
            try store.setHidden(true, identity: invalid)
            XCTFail("Invalid native identity was accepted")
        } catch ChatVisibilityStoreError.invalidIdentity { }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), oversized)
    }),
    ("chat visibility: stable pending and native identities round trip", {
        try test_chatVisibilityStoreRoundTripsStablePendingAndNativeIdentities()
    }),
    ("chat visibility: restore leaves source files untouched", {
        try test_chatVisibilityStoreRestoreDoesNotTouchSourceFiles()
    }),
    ("chat visibility: pending hidden identity migrates to native Session", {
        try test_chatVisibilityStoreMigratesPendingHiddenIdentityToNativeSession()
    }),
    ("chat visibility: migration failure preserves sidecar", {
        try test_chatVisibilityStoreMigrationFailurePreservesSidecarBytes()
    }),
    ("chat visibility: malformed state is reported", {
        try test_chatVisibilityStoreRejectsMalformedStateInsteadOfTreatingItAsEmpty()
    }),
    ("chat visibility: failed read does not overwrite state", {
        try test_chatVisibilityStoreFailedReadDoesNotOverwriteExistingState()
    }),
    ("chat visibility: transient and oversized identities are rejected", {
        test_chatVisibilityIdentityRejectsTransientOrOversizedValues()
    }),
]
