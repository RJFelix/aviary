import Foundation
@testable import AviaryCore

private func catalogJoinCanonical(
    sessionID: String = "joined-session",
    title: String? = "Native title",
    lifecycle: SessionLifecycle = .active,
    attention: SessionAttention = .error,
    modelID: String? = "native-model",
    unknownDomains: Set<TimelineDomain> = []
) throws -> CanonicalSessionCatalogSummary {
    let sessionRef = SessionRef(sessionID)
    let journal = JournalRef.session(
        sessionRef, journalID: "joined-journal", authority: TimelineAuthorityRef("native-host"))
    var snapshot = SessionSnapshot()
    snapshot.session = sessionRef
    snapshot.journal = journal
    snapshot.lifecycle = lifecycle
    snapshot.attention = attention
    snapshot.modelID = modelID
    snapshot.unknownDomains = unknownDomains
    if let title {
        let message = SessionMessageSnapshot(eventID: "joined-user", role: "user", text: title)
        snapshot.messages = [message]
        snapshot.messageHistory = [message]
    }
    return try XCTUnwrap(SessionCatalog.summarizeCanonical(session: snapshot, works: []))
}

private func catalogJoinLegacy(
    id: String = "joined-session",
    name: String? = "Legacy title",
    state: String? = "completed",
    model: String? = "legacy-model"
) -> SessionSummary {
    SessionSummary(
        id: id, headerID: "legacy-header", fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
        name: name, cwd: "/tmp/project", gitBranch: "main",
        createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20),
        byteSize: 42, provider: "legacy-provider", model: model,
        usage: Usage(), childUsage: Usage(), counts: Transcript.Counts(),
        firstPrompt: "legacy prompt", lastAssistantText: "legacy answer", status: nil,
        sessionState: state, rlmDepth: 0, parentSessionPath: nil)
}

func test_companionProjectionIsOneLegacyBackedDisplayRow() throws {
    let canonical = try catalogJoinCanonical()
    let legacy = catalogJoinLegacy()
    let companion = try XCTUnwrap(
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacy))
    let entry = SessionCatalogProjection.companion(companion)

    XCTAssertEqual(entry.id, legacy.id)
    XCTAssertEqual(entry.legacyID, legacy.id)
    XCTAssertEqual(entry.legacySummary?.id, legacy.id)
    XCTAssertEqual(entry.legacySummary?.fileURL, legacy.fileURL)
    XCTAssertFalse(entry.displaySummary?.isCanonicalOnly == true)
    XCTAssertEqual(entry.title, canonical.title)
    XCTAssertEqual(entry.canonical?.lifecycle, .active)
    XCTAssertEqual(entry.canonical?.modelIDs, ["native-model"])
    XCTAssertEqual(entry.canonical?.attention, .error)
    XCTAssertEqual(entry.displaySummary?.model, "native-model")
    XCTAssertNil(entry.displaySummary?.provider)
    XCTAssertEqual(entry.displaySummary?.sessionState, "active")
}

func test_companionTitleFallsBackToLegacyWhenCanonicalIsEmpty() throws {
    let canonical = try catalogJoinCanonical(title: nil)
    let legacy = catalogJoinLegacy(name: "Legacy fallback")
    let companion = try XCTUnwrap(
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacy))

    XCTAssertEqual(companion.title, "Legacy fallback")
    XCTAssertEqual(companion.summary.title, "Legacy fallback")
    XCTAssertFalse(companion.summary.isCanonicalOnly)
}

func test_companionKeepsCanonicalFactsSeparateFromHealthierLegacyFacts() throws {
    let canonical = try catalogJoinCanonical(
        title: "Authoritative title", lifecycle: .unknown, attention: .error,
        modelID: "authoritative-model")
    let legacy = catalogJoinLegacy(
        name: "Misleading completed title", state: "completed", model: "misleading-model")
    let companion = try XCTUnwrap(
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacy))
    let entry = SessionCatalogProjection.companion(companion)

    XCTAssertEqual(entry.canonical?.lifecycle, .unknown)
    XCTAssertEqual(entry.canonical?.attention, .error)
    XCTAssertEqual(entry.canonical?.modelIDs, ["authoritative-model"])
    XCTAssertEqual(entry.legacySummary?.sessionState, "completed")
    XCTAssertEqual(entry.legacySummary?.model, "misleading-model")
    XCTAssertEqual(entry.displaySummary?.sessionState, "unknown")
    XCTAssertEqual(entry.displaySummary?.model, "authoritative-model")
    XCTAssertNil(entry.displaySummary?.provider)
    XCTAssertEqual(entry.title, "Authoritative title")
}

func test_companionUnknownSessionDomainDoesNotRefillFactsFromLegacy() throws {
    let canonical = try catalogJoinCanonical(unknownDomains: [.session])
    var legacy = catalogJoinLegacy(
        name: "Misleading legacy title", state: "completed", model: "legacy-model")
    legacy.usage.input = 123
    legacy.usage.totalTokens = 123
    legacy.childUsage.output = 45
    legacy.childUsage.totalTokens = 45
    legacy.counts.assistant = 7
    legacy.counts.toolCalls = 3
    legacy.childCount = 2
    let companion = try XCTUnwrap(
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacy))
    let entry = SessionCatalogProjection.companion(companion)

    XCTAssertEqual(entry.legacySummary?.title, "Misleading legacy title")
    XCTAssertEqual(entry.legacySummary?.sessionState, "completed")
    XCTAssertEqual(entry.legacySummary?.model, "legacy-model")
    XCTAssertEqual(entry.legacySummary?.lastAssistantText, "legacy answer")
    XCTAssertEqual(entry.legacySummary?.usage.totalTokens, 123)
    XCTAssertEqual(entry.legacySummary?.counts.assistant, 7)
    XCTAssertEqual(entry.title, "Session details unknown")
    XCTAssertEqual(entry.displaySummary?.title, "Session details unknown")
    XCTAssertNil(entry.displaySummary?.sessionState)
    XCTAssertNil(entry.displaySummary?.model)
    XCTAssertNil(entry.displaySummary?.provider)
    XCTAssertNil(entry.displaySummary?.status)
    XCTAssertEqual(entry.displaySummary?.cwd, "")
    XCTAssertNil(entry.displaySummary?.gitBranch)
    XCTAssertEqual(entry.displaySummary?.firstPrompt, "")
    XCTAssertEqual(entry.displaySummary?.lastAssistantText, "")
    XCTAssertTrue(entry.displaySummary?.usage.isEmpty == true)
    XCTAssertTrue(entry.displaySummary?.childUsage.isEmpty == true)
    XCTAssertEqual(entry.displaySummary?.counts, Transcript.Counts())
    XCTAssertEqual(entry.displaySummary?.childCount, 0)
}

func test_companionIndexHasOneRowAndMapsLegacyIDToCanonicalSummary() throws {
    let canonical = try catalogJoinCanonical()
    let legacy = catalogJoinLegacy()
    let companion = try XCTUnwrap(
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacy))
    let index = SessionCatalogProjectionIndex(entries: [.companion(companion)])

    XCTAssertEqual(index.displaySummaries.map(\.id), [legacy.id])
    XCTAssertEqual(index.displaySummaries.count, 1)
    XCTAssertEqual(index.canonicalByID[legacy.id]?.id, canonical.id)
    XCTAssertEqual(index.duplicateIDs, [])
}

func test_companionFactoryRefusesMismatchedSessionIDs() throws {
    let canonical = try catalogJoinCanonical(sessionID: "native-session")
    let legacy = catalogJoinLegacy(id: "different-local-session")

    XCTAssertNil(CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacy))
    XCTAssertNil(CompanionSessionCatalogProjection.make(canonical: canonical, legacySummary: legacy))
}

func test_pureCanonicalAndLegacyProjectionBehaviorRemainsUnchanged() throws {
    let canonical = try catalogJoinCanonical()
    let canonicalEntry = SessionCatalogProjection.canonical(canonical)
    XCTAssertEqual(canonicalEntry.id, canonical.id)
    XCTAssertNil(canonicalEntry.legacySummary)
    XCTAssertTrue(canonicalEntry.displaySummary?.isCanonicalOnly == true)

    let legacy = catalogJoinLegacy()
    let legacyEntry = LegacySessionCatalogAdapter.project(summary: legacy, authorityID: "legacy-host")
    XCTAssertEqual(legacyEntry.id, legacy.id)
    XCTAssertEqual(legacyEntry.legacySummary?.fileURL, legacy.fileURL)
    XCTAssertFalse(legacyEntry.displaySummary?.isCanonicalOnly == true)
}

func test_companionAndDuplicateRowsRemainExplicitAndNonTrapping() throws {
    let canonical = try catalogJoinCanonical()
    let legacy = catalogJoinLegacy()
    let companion = try XCTUnwrap(
        CompanionSessionCatalogProjection(canonical: canonical, legacySummary: legacy))
    let duplicateLegacy = LegacySessionCatalogAdapter.project(summary: legacy, authorityID: "other-host")
    let index = SessionCatalogProjectionIndex(
        entries: [.companion(companion), duplicateLegacy])

    XCTAssertEqual(index.duplicateIDs, [legacy.id])
    XCTAssertEqual(index.displaySummaries, [])
    XCTAssertNil(index.canonicalByID[legacy.id])
}
