import Foundation
@testable import AviaryCore

private enum FlockCatalogFixture {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ReaderCensus")
    }

    static let session = SessionRef("census-session")
    static let work = WorkRef(workHostID: "census-host", workID: "census-work")
    static let sessionJournal = JournalRef.session(
        session, journalID: "session-journal",
        authority: TimelineAuthorityRef("session-authority"))
    static let workJournal = JournalRef.work(work, journalID: "work-journal")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: root.appending(path: name))
    }

    static func prefixLines(_ data: Data, count: Int) -> Data {
        var result = Data()
        for line in data.split(separator: 0x0A).prefix(count) {
            result.append(contentsOf: line)
            result.append(0x0A)
        }
        return result
    }

    static func home() throws -> AgentHome {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "aviary-flock-catalog-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AgentHome(root: root)
    }
}

private func flockWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

func test_canonicalFlockCatalogQualifiesChildIDsAndSessionLinks() throws {
    let home = try FlockCatalogFixture.home()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let sessionData = try FlockCatalogFixture.data("session.jsonl")
    let workData = FlockCatalogFixture.prefixLines(
        try FlockCatalogFixture.data("work.jsonl"), count: 19)
    try flockWrite(sessionData, to: home.timelineV2SessionJournalURL(
        sessionID: FlockCatalogFixture.session.sessionID))
    try flockWrite(workData, to: home.timelineV2WorkJournalURL(FlockCatalogFixture.work))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let summary = try XCTUnwrap(catalog.sessions.first?.summary)
    let projection = try XCTUnwrap(
        CanonicalFlockCatalogProjection.project(
            sessions: [summary], works: catalog.works).first)

    XCTAssertTrue(projection.childLifecycleAvailable)
    XCTAssertEqual(projection.children.map(\.childID), ["child-1"])
    XCTAssertTrue(projection.children[0].id.hasPrefix("work:11:census-host:11:census-work/child:"))
    XCTAssertEqual(projection.sessions.map(\.id), [FlockCatalogFixture.sessionJournal.stableKey])
    XCTAssertEqual(projection.sessions[0].session, FlockCatalogFixture.session)
}

func test_canonicalFlockCatalogSuppressesChildrenForUnknownAffectedDomains() throws {
    let home = try FlockCatalogFixture.home()
    defer { try? FileManager.default.removeItem(at: home.root) }
    try flockWrite(try FlockCatalogFixture.data("session.jsonl"),
                   to: home.timelineV2SessionJournalURL(
                    sessionID: FlockCatalogFixture.session.sessionID))
    try flockWrite(try FlockCatalogFixture.data("work.jsonl"),
                   to: home.timelineV2WorkJournalURL(FlockCatalogFixture.work))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let projection = try XCTUnwrap(
        CanonicalFlockCatalogProjection.project(
            sessions: catalog.sessionSummaries, works: catalog.works).first)

    XCTAssertTrue(projection.isAvailable)
    XCTAssertFalse(projection.childLifecycleAvailable)
    XCTAssertTrue(projection.children.isEmpty)
    XCTAssertTrue(projection.unknownDomains.contains(.externalEffects)
                  || projection.unknownDomains.contains(.work)
                  || projection.unknownDomains.contains(.runtime))
    XCTAssertTrue(projection.unavailableReason?.contains("partial") == true)
}

func test_canonicalFlockLegacyCompatibilityRequiresExplicitNativeCompanionProvenance() {
    let roots = CanonicalFlockCatalogProjection.legacyCompatibilityRootIDs(
        ["legacy-only", "same-local-id-different-authority", "native-companion"],
        nativeCompanionLegacyIDs: ["native-companion"])
    XCTAssertEqual(roots, ["legacy-only", "same-local-id-different-authority"])
    XCTAssertEqual(
        LegacyFlockIdentity.rowID(parentSessionID: "session-a", childID: "duplicate"),
        "legacy:9:session-a:child:9:duplicate")
    XCTAssertNotEqual(
        LegacyFlockIdentity.rowID(parentSessionID: "session-a", childID: "duplicate"),
        LegacyFlockIdentity.rowID(parentSessionID: "session-b", childID: "duplicate"))
}

func test_canonicalFlockUnknownWorkAndExternalEffectsSuppressChildCompleteness() {
    let work = FlockCatalogFixture.work
    let journal = FlockCatalogFixture.workJournal
    let flock = CanonicalFlockProjection(
        journal: journal, work: work, workHost: WorkHostRef(work.workHostID), cursor: nil,
        nodes: [CanonicalFlockNode(
            childID: "child", name: nil, state: "running", parentSession: nil,
            parentWork: work, parentRun: nil,
            source: EventRef(journal: journal, eventID: "child"))],
        isAvailable: true, integrityValid: true)
    for domain in [TimelineDomain.work, .externalEffects] {
        let projection = CanonicalFlockCatalogProjection.project(
            sessions: [], flock: flock, unknownDomains: [domain])
        XCTAssertFalse(projection.childLifecycleAvailable)
        XCTAssertTrue(projection.children.isEmpty)
    }
}

func test_canonicalFlockDuplicateWorkPresentationIDsAreStableAcrossInputOrder() throws {
    let home = try FlockCatalogFixture.home()
    defer { try? FileManager.default.removeItem(at: home.root) }
    try flockWrite(try FlockCatalogFixture.data("session.jsonl"),
                   to: home.timelineV2SessionJournalURL(sessionID: FlockCatalogFixture.session.sessionID))
    try flockWrite(FlockCatalogFixture.prefixLines(
        try FlockCatalogFixture.data("work.jsonl"), count: 19),
        to: home.timelineV2WorkJournalURL(FlockCatalogFixture.work))
    let catalog = LocalTimelineCatalog.scan(home: home)
    let rows = try XCTUnwrap(catalog.works.first)
    let first = CanonicalFlockCatalogProjection.project(sessions: [], works: [rows, rows])
    let second = CanonicalFlockCatalogProjection.project(sessions: [], works: [rows, rows].reversed())
    XCTAssertEqual(first.map(\.id), second.map(\.id))
    XCTAssertEqual(Set(first.map(\.id)).count, 2)
    XCTAssertTrue(first[1].id.contains("#locator-"))
}

func test_canonicalFlockAttentionCountDeduplicatesAuthorityQualifiedSessions() throws {
    let home = try FlockCatalogFixture.home()
    defer { try? FileManager.default.removeItem(at: home.root) }
    try flockWrite(try FlockCatalogFixture.data("session.jsonl"),
                   to: home.timelineV2SessionJournalURL(sessionID: FlockCatalogFixture.session.sessionID))
    try flockWrite(FlockCatalogFixture.prefixLines(
        try FlockCatalogFixture.data("work.jsonl"), count: 19),
        to: home.timelineV2WorkJournalURL(FlockCatalogFixture.work))
    let catalog = LocalTimelineCatalog.scan(home: home)
    let row = try XCTUnwrap(catalog.works.first)
    let projection = CanonicalFlockCatalogProjection.project(
        sessions: catalog.sessionSummaries, works: [row]).first!
    let expected = projection.sessions.contains {
        $0.attention.map { $0 != .none } ?? false
    } ? 1 : 0
    XCTAssertEqual(
        CanonicalFlockCatalogProjection.attentionSessionCount([projection, projection]), expected)

    let mixed = CanonicalFlockCatalogProjection.summarizeAttention(
        [SessionAttention.none, .review])
    XCTAssertEqual(mixed.requirement, .required)
    XCTAssertEqual(mixed.attention, .review)
    let needsYou = CanonicalFlockCatalogProjection.summarizeAttention([.review, .input])
    XCTAssertEqual(needsYou.requirement, .required)
    XCTAssertEqual(needsYou.attention, .input)
    let uncertain = CanonicalFlockCatalogProjection.summarizeAttention(
        [SessionAttention.none, nil])
    XCTAssertEqual(uncertain.requirement, .unknown)
    XCTAssertNil(uncertain.attention)
    let none = CanonicalFlockCatalogProjection.summarizeAttention(
        [SessionAttention.none, SessionAttention.none])
    XCTAssertEqual(none.requirement, .none)
    XCTAssertEqual(none.attention, SessionAttention.none)
}

func test_legacyAgentTreePreservesDuplicateChildIDsPerParentSession() throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    for (parent, name) in [("parent-a", "first"), ("parent-b", "second")] {
        let recorder = SubAgentRecorder(home: home, parentSessionID: parent)
        let childFile = recorder.childDirectory(childID: "duplicate-child").appending(path: "c.jsonl")
        try FileManager.default.createDirectory(
            at: childFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: childFile.path, contents: nil)
        try recorder.record(
            childID: "duplicate-child", name: name, sessionFile: childFile,
            prompt: "prompt", spawnCode: "", depth: 1, maxDepth: 2, status: "completed",
            provider: "test", model: "model", createdAt: Date())
    }
    let tree = AgentTreeReader.read(home: home)
    XCTAssertEqual(tree.byParentSession["parent-a"]?.map(\.id), ["duplicate-child"])
    XCTAssertEqual(tree.byParentSession["parent-b"]?.map(\.id), ["duplicate-child"])
    XCTAssertEqual(tree.allNodes.filter { $0.id == "duplicate-child" }.count, 2)
    XCTAssertEqual(Set(tree.allNodes.filter { $0.id == "duplicate-child" }.map(\.name)), ["first", "second"])

    // Two different parent records advertise the same child-session basename. A later child
    // cannot be safely nested under either one, so it remains visible under an unknown root.
    let sharedSessionFile = home.root.appending(path: "shared-session.jsonl")
    for (parent, childID) in [("parent-c", "parent-c-node"), ("parent-d", "parent-d-node")] {
        let recorder = SubAgentRecorder(home: home, parentSessionID: parent)
        try recorder.record(
            childID: childID, name: childID, sessionFile: sharedSessionFile,
            prompt: "prompt", spawnCode: "", depth: 1, maxDepth: 2, status: "completed",
            provider: "test", model: "model", createdAt: Date())
    }
    let ambiguousRecorder = SubAgentRecorder(home: home, parentSessionID: "shared-session")
    let nestedFile = home.root.appending(path: "nested-session.jsonl")
    try ambiguousRecorder.record(
        childID: "ambiguous-child", name: "ambiguous", sessionFile: nestedFile,
        prompt: "prompt", spawnCode: "", depth: 2, maxDepth: 2, status: "unknown",
        provider: nil, model: nil, createdAt: Date())
    let ambiguousTree = AgentTreeReader.read(home: home)
    XCTAssertEqual(ambiguousTree.byParentSession["shared-session"]?.map(\.id), ["ambiguous-child"])
    XCTAssertFalse(ambiguousTree.byParentSession["parent-c"]?.flatMap(\.flattened)
        .contains { $0.id == "ambiguous-child" } == true)
}
