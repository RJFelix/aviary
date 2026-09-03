import Foundation
@testable import AviaryCore

/// Exercise the real actor scan boundary rather than only testing the canonical adapter with
/// hand-built snapshots. The legacy transcript remains the source, but the consumer receives a
/// typed canonical projection and retains the filename identity separately.
func test_sessionCatalogScanUsesExplicitLegacyProjectionBoundary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-catalog-projection-\(UUID().uuidString)",
                   directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    try FileManager.default.createDirectory(at: home.sessionsDir, withIntermediateDirectories: true)
    let file = home.sessionFile(id: "legacy-row")
    let jsonl = [
        #"{"type":"session","version":3,"id":"header-id","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}"#,
        #"{"type":"session_info","name":"Canonical boundary check"}"#,
        #"{"type":"session_state","state":{"status":"completed"}}"#,
        #"{"type":"model_change","provider":"test","modelId":"model-a"}"#,
        #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":"Inspect the projection"}}"#,
    ].joined(separator: "\n") + "\n"
    try Data(jsonl.utf8).write(to: file)

    let catalog = SessionCatalog(home: home)
    let entries = await catalog.scanCatalog().entries
    let entry = try XCTUnwrap(entries.first)
    let legacy = try XCTUnwrap(entry.legacySummary)
    let canonical = try XCTUnwrap(entry.canonical)

    // Existing filesystem joins keep the filename stem, while the canonical identity carries
    // authority and journal kind. They must not be substituted for one another.
    XCTAssertEqual(entry.legacyID, "legacy-row")
    XCTAssertEqual(legacy.id, "legacy-row")
    XCTAssertEqual(canonical.session.sessionID, "legacy-row")
    XCTAssertNotEqual(canonical.id, legacy.id)
    XCTAssertTrue(canonical.id.contains("authority:"))
    XCTAssertTrue(canonical.id.contains("kind:session"))

    // A real list read goes through the canonical row, but the adapter is honest about what the
    // legacy scanner did not reconstruct. No raw JSON or repr is carried by this projection.
    XCTAssertEqual(canonical.title, "Canonical boundary check")
    XCTAssertEqual(canonical.modelIDs, ["model-a"])
    XCTAssertEqual(canonical.lifecycle, .completed)
    XCTAssertFalse(canonical.sessionSemanticProjectionValid)
    XCTAssertEqual(Set(canonical.unknownDomains), Set(TimelineDomain.allCases))
    XCTAssertTrue(canonical.work.isEmpty)
    XCTAssertNil(canonical.sessionIntegrityValid)
    XCTAssertEqual(entry.title, canonical.title)
}

func test_legacyProjectionDoesNotInventWorkOrEffectiveAttention() throws {
    var summary = SessionSummary(
        id: "legacy-no-work", headerID: nil,
        fileURL: URL(fileURLWithPath: "/tmp/legacy-no-work.jsonl"),
        name: nil, cwd: "/tmp", gitBranch: nil,
        createdAt: .distantPast, updatedAt: .distantPast, byteSize: 0,
        provider: "test", model: "model-a", usage: Usage(), childUsage: Usage(),
        counts: Transcript.Counts(), firstPrompt: "A legacy prompt", lastAssistantText: "",
        status: nil, sessionState: "active", rlmDepth: 0, parentSessionPath: nil)
    summary.isLive = true
    let entry = LegacySessionCatalogAdapter.project(
        summary: summary, authorityID: "legacy-host")
    let canonical = try XCTUnwrap(entry.canonical)
    XCTAssertNil(canonical.effectiveAttention)
    XCTAssertTrue(canonical.work.isEmpty)
    XCTAssertFalse(canonical.sessionSemanticProjectionValid)
    XCTAssertEqual(canonical.lifecycle, .active)
}

func test_canonicalOnlyProjectionSurvivesListDisplayAdapter() throws {
    let session = SessionRef("native-session")
    let journal = JournalRef.session(
        session, journalID: "native", authority: TimelineAuthorityRef("remote-service"))
    var snapshot = SessionSnapshot()
    snapshot.session = session
    snapshot.journal = journal
    snapshot.lifecycle = .completed
    snapshot.messages = [SessionMessageSnapshot(eventID: "m1", role: "user", text: "Native work")]
    let canonical = try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: snapshot, works: []))
    let displayed = SessionCatalog.displaySummaries(from: [.canonical(canonical)])
    let row = try XCTUnwrap(displayed.first)
    XCTAssertEqual(row.id, canonical.id)
    XCTAssertEqual(row.title, canonical.title)
    XCTAssertTrue(row.isCanonicalOnly)
    XCTAssertNil(row.fileURL)
}

func test_untitledLegacyProjectionRemainsNonblankAndSearchable() throws {
    let summary = SessionSummary(
        id: "untitled", headerID: nil, fileURL: URL(fileURLWithPath: "/tmp/untitled.jsonl"),
        name: nil, cwd: "/tmp", gitBranch: nil,
        createdAt: .distantPast, updatedAt: .distantPast, byteSize: 0,
        provider: nil, model: nil, usage: Usage(), childUsage: Usage(),
        counts: Transcript.Counts(), firstPrompt: "", lastAssistantText: "",
        status: nil, sessionState: nil, rlmDepth: 0, parentSessionPath: nil)
    let entry = LegacySessionCatalogAdapter.project(summary: summary, authorityID: "host")
    XCTAssertEqual(entry.title, "Untitled session")
    XCTAssertFalse(entry.title.isEmpty)
    XCTAssertTrue(entry.title.lowercased().contains("untitled"))
}

func test_duplicateProjectionIDsAreReportedWithoutTrapping() throws {
    let summary = SessionSummary(
        id: "duplicate", headerID: nil, fileURL: URL(fileURLWithPath: "/tmp/duplicate.jsonl"),
        name: "Duplicate", cwd: "/tmp", gitBranch: nil,
        createdAt: .distantPast, updatedAt: .distantPast, byteSize: 0,
        provider: nil, model: nil, usage: Usage(), childUsage: Usage(),
        counts: Transcript.Counts(), firstPrompt: "Duplicate", lastAssistantText: "",
        status: nil, sessionState: nil, rlmDepth: 0, parentSessionPath: nil)
    let first = LegacySessionCatalogAdapter.project(summary: summary, authorityID: "host-a")
    var secondSummary = summary
    secondSummary.name = "Second display row"
    let second = LegacySessionCatalogAdapter.project(summary: secondSummary, authorityID: "host-b")
    let index = SessionCatalogProjectionIndex(entries: [first, second])
    XCTAssertEqual(index.duplicateIDs, ["duplicate"])
    XCTAssertTrue(index.canonicalByID.isEmpty)
    XCTAssertTrue(index.displaySummaries.isEmpty)
}
