import Foundation
@testable import AviaryCore

private func searchCanonical(
    sessionID: String = "search-session", authority: String = "search-authority",
    journalID: String = "search-journal", messages: [SessionMessageSnapshot] = [],
    read: Bool = true, tail: Bool = false, structural: Bool = true,
    semantic: Bool = true, unknownDomains: Set<TimelineDomain> = [],
    modelID: String = "native-model"
) throws -> CanonicalSessionCatalogSummary {
    let session = SessionRef(sessionID)
    let journal = JournalRef.session(
        session, journalID: journalID, authority: TimelineAuthorityRef(authority))
    var snapshot = SessionSnapshot()
    snapshot.session = session
    snapshot.journal = journal
    snapshot.lifecycle = .active
    snapshot.attention = .review
    snapshot.modelID = modelID
    snapshot.messages = messages
    snapshot.messageHistory = messages
    snapshot.lastEventID = "last"
    snapshot.lastSequence = 1
    snapshot.seenEventIDs = ["last"]
    snapshot.structuralIntegrityValid = structural
    snapshot.semanticProjectionValid = semantic
    snapshot.unknownDomains = unknownDomains
    let sessionRead: TimelineJournalReadResult?
    if read {
        let event = TimelineEvent(
            eventID: "last", journal: journal, sequence: 1, session: session,
            actor: TimelineActor(actorID: "search-test", kind: "test"),
            hostRecordedAt: Date(timeIntervalSince1970: 1), type: "session.message")
        let record = TimelineJournalRecord(
            event: event, rawLineBytes: Data("{}\n".utf8), byteStart: 0, byteEnd: 3)
        sessionRead = TimelineJournalReadResult(
            records: [record],
            truncatedTail: tail ? TimelineJournalTail(rawBytes: Data("tail".utf8), byteStart: 3, byteEnd: 7) : nil)
    } else {
        sessionRead = nil
    }
    return try XCTUnwrap(SessionCatalog.summarizeCanonical(
        session: snapshot, works: [], sessionRead: sessionRead))
}

private func searchLegacy(
    id: String, prompt: String = "legacy prompt", name: String = "Legacy title",
    model: String = "legacy-model", lastAssistant: String = "legacy answer"
) -> SessionCatalogProjection {
    let summary = SessionSummary(
        id: id, headerID: nil, fileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
        name: name, cwd: "/tmp/project", gitBranch: nil,
        createdAt: .distantPast, updatedAt: .distantPast, byteSize: 0,
        provider: "legacy-provider", model: model, usage: Usage(),
        childUsage: Usage(), counts: Transcript.Counts(), firstPrompt: prompt,
        lastAssistantText: lastAssistant, status: nil, sessionState: "completed",
        rlmDepth: 0, parentSessionPath: nil)
    return LegacySessionCatalogAdapter.project(summary: summary, authorityID: "legacy")
}

func test_canonicalSessionSearchSeparatesAuthorityQualifiedSameIDs() throws {
    let a = try searchCanonical(authority: "host-a")
    let b = try searchCanonical(authority: "host-b")
    let index = CanonicalSessionSearchIndex(entries: [.canonical(a), .canonical(b)])
    XCTAssertEqual(index.documents.count, 2)
    XCTAssertNotEqual(index.documents[0].canonicalIdentity, index.documents[1].canonicalIdentity)
    XCTAssertEqual(Set(index.documents.map(\.authorityID)), ["host-a", "host-b"])
    XCTAssertEqual(Set(index.documents.map(\.sessionID)), ["search-session"])
}

func test_canonicalSessionSearchUnknownNeverRefillsCompanionLegacyFacts() throws {
    let canonical = try searchCanonical(read: false)
    let legacy = searchLegacy(id: "search-session", prompt: "secret legacy prompt")
    let companion = try XCTUnwrap(CompanionSessionCatalogProjection(
        canonical: canonical, legacySummary: try XCTUnwrap(legacy.legacySummary)))
    let document = try XCTUnwrap(
        CanonicalSessionSearchIndex(entries: [.companion(companion)]).documents.first)
    XCTAssertEqual(document.source, .companion)
    XCTAssertEqual(document.displayTitle, "Session details unknown")
    XCTAssertEqual(document.canonicalIdentity, canonical.journal.stableKey)
    XCTAssertEqual(document.authorityID, "search-authority")
    XCTAssertFalse(document.matches("secret legacy prompt"))
    XCTAssertFalse(document.matches("legacy-model"))
    XCTAssertTrue(document.matches("search-session"))
    XCTAssertFalse(document.matches("kind:session"))
    XCTAssertNil(document.modelID)

    let proven = try searchCanonical()
    let provenCompanion = try XCTUnwrap(CompanionSessionCatalogProjection(
        canonical: proven, legacySummary: try XCTUnwrap(legacy.legacySummary)))
    let canonicalTitle = try XCTUnwrap(CanonicalSessionSearchIndex(
        entries: [.canonical(proven)]).documents.first)
    let companionTitle = try XCTUnwrap(CanonicalSessionSearchIndex(
        entries: [.companion(provenCompanion)]).documents.first)
    XCTAssertEqual(canonicalTitle.displayTitle, "Untitled session")
    XCTAssertEqual(companionTitle.displayTitle, "Untitled session",
                   "an empty proven native title must not refill from the legacy title")
}

func test_canonicalSessionSearchWithholdsNonExactOrInvalidNativeFacts() throws {
    let messages = [SessionMessageSnapshot(eventID: "u", role: "user", text: "native text")]
    for summary in [
        try searchCanonical(messages: messages, read: false),
        try searchCanonical(messages: messages, tail: true),
        try searchCanonical(messages: messages, structural: false),
        try searchCanonical(messages: messages, semantic: false),
        try searchCanonical(messages: messages, unknownDomains: [.session]),
    ] {
        let document = try XCTUnwrap(
            CanonicalSessionSearchIndex(entries: [.canonical(summary)]).documents.first)
        XCTAssertNil(document.title)
        XCTAssertNil(document.visibleConversation)
        XCTAssertEqual(document.canonicalIdentity, summary.journal.stableKey)
        XCTAssertEqual(document.searchableText, "")
    }
}

func test_canonicalSessionSearchBoundsLargeFieldsBeforeIndexing() throws {
    let huge = String(repeating: "x", count: 100_000)
    let legacy = try XCTUnwrap(CanonicalSessionSearchIndex(entries: [
        searchLegacy(
            id: "large-legacy", prompt: huge, name: huge, model: huge,
            lastAssistant: huge),
    ]).documents.first)
    XCTAssertEqual(legacy.title?.count, CanonicalSessionSearchDocument.maximumTitleCharacters)
    XCTAssertEqual(legacy.modelID?.count, CanonicalSessionSearchDocument.maximumModelCharacters)
    XCTAssertTrue((legacy.visibleConversation?.count ?? 0)
                  <= CanonicalSessionSearchDocument.maximumConversationCharacters)
    XCTAssertTrue(legacy.omittedConversationCharacterCount > 0)
    XCTAssertTrue(legacy.omittedSearchCharacterCount > 0)

    let native = try XCTUnwrap(CanonicalSessionSearchIndex(entries: [.canonical(
        try searchCanonical(
            messages: [SessionMessageSnapshot(eventID: "huge", role: "user", text: huge)],
            modelID: huge)
    )]).documents.first)
    XCTAssertEqual(native.modelID?.count, CanonicalSessionSearchDocument.maximumModelCharacters)
    XCTAssertTrue((native.visibleConversation?.count ?? 0)
                  <= CanonicalSessionSearchDocument.maximumConversationCharacters)
    XCTAssertTrue(native.omittedConversationCharacterCount > 0)
    XCTAssertTrue(native.omittedSearchCharacterCount > 0)
}

func test_legacyAgentSearchIsBoundedAndExcludesInjectedPromptContext() {
    let huge = String(repeating: "s", count: 100_000)
    let node = AgentNode(
        id: "child", name: huge, sessionID: "child-session",
        sessionFile: URL(fileURLWithPath: "/tmp/child.jsonl"),
        sessionDir: URL(fileURLWithPath: "/tmp"), parentSessionID: "parent",
        depth: 1, maxDepth: 2, status: huge, provider: huge, model: huge,
        prompt: "<system-reminder>\(huge)</system-reminder>person question",
        spawnCode: huge, createdAt: .distantPast, updatedAt: .distantPast)
    let document = LegacyAgentSearchDocument(node: node)
    XCTAssertEqual(document.displayName.count, LegacyAgentSearchDocument.maximumNameCharacters)
    XCTAssertTrue(document.displaySubtitle.count
                  <= LegacyAgentSearchDocument.maximumMetadataCharacters)
    XCTAssertEqual(document.userFacingPrompt, "person question")
    XCTAssertTrue(document.matches("person question"))
    XCTAssertFalse(document.matches(String(repeating: "s", count: 600)))

    var wrapperOnly = node
    wrapperOnly.name = "<system-reminder>secret name</system-reminder>"
    wrapperOnly.prompt = "<system-reminder>secret-only</system-reminder>"
    let strict = LegacyAgentSearchDocument(node: wrapperOnly)
    XCTAssertEqual(strict.displayName, "Unnamed agent")
    XCTAssertEqual(strict.userFacingPrompt, "")
    XCTAssertFalse(strict.matches("secret-only"))

    let wrapperTitle = CanonicalSessionSearchIndex(entries: [searchLegacy(
        id: "wrapper-title",
        name: "<system-reminder>secret title</system-reminder>")])
    XCTAssertEqual(wrapperTitle.documents.first?.displayTitle, "Untitled session")
    XCTAssertFalse(wrapperTitle.documents.first?.matches("secret title") == true)
}

func test_canonicalSessionSearchWhitelistsVisibleConversationAndBoundsIt() throws {
    let messages = (0..<80).map { index in
        SessionMessageSnapshot(eventID: "m\(index)", role: index == 2 ? "tool" : "user",
                               text: index == 2 ? "tool-secret" : String(repeating: "x", count: 400))
    }
    let summary = try searchCanonical(messages: messages)
    let document = try XCTUnwrap(
        CanonicalSessionSearchIndex(entries: [.canonical(summary)]).documents.first)
    XCTAssertEqual(document.omittedConversationMessageCount, 15)
    XCTAssertTrue(document.omittedConversationCharacterCount > 0)
    XCTAssertTrue((document.visibleConversation?.count ?? 0)
                  <= CanonicalSessionSearchDocument.maximumConversationCharacters)
    XCTAssertEqual(document.sourceEventRefs.count, 41)
    XCTAssertTrue(document.sourceEventRefs.allSatisfy { $0.journal == summary.journal })
    XCTAssertFalse(document.matches("tool-secret"))
    XCTAssertTrue(document.omittedSearchCharacterCount >= 0)
}

func test_canonicalSessionSearchLegacyCompatibilityIsExplicitAndSanitized() throws {
    let index = CanonicalSessionSearchIndex(entries: [
        searchLegacy(id: "legacy-only", prompt: "<system-reminder>hide</system-reminder>person question")])
    let document = try XCTUnwrap(index.documents.first)
    XCTAssertEqual(document.source, .legacyCompatibility)
    XCTAssertTrue(document.matches("person question"))
    XCTAssertFalse(document.matches("system-reminder"))
    XCTAssertEqual(document.actionTargetID, "legacy-only")
    XCTAssertEqual(document.localCompatibilityID, "legacy-only")
    XCTAssertFalse(document.matches("egacy-on"))
}

func test_canonicalSessionSearchDuplicateRowsAreWithheldAndGlobalBoundsAreDeterministic() throws {
    let duplicate = searchLegacy(id: "duplicate")
    let duplicateIndex = CanonicalSessionSearchIndex(entries: [duplicate, duplicate])
    XCTAssertEqual(duplicateIndex.documents.count, 0)
    XCTAssertEqual(duplicateIndex.duplicateDocumentIDs, ["duplicate"])
    let canonical = try searchCanonical(sessionID: "canonical-companion")
    let legacy = searchLegacy(id: "canonical-companion")
    let companion = try XCTUnwrap(CompanionSessionCatalogProjection(
        canonical: canonical, legacySummary: try XCTUnwrap(legacy.legacySummary)))
    let identityConflict = CanonicalSessionSearchIndex(
        entries: [.canonical(canonical), .companion(companion)])
    XCTAssertTrue(identityConflict.documents.isEmpty)
    XCTAssertEqual(identityConflict.duplicateDocumentIDs, [])
    XCTAssertEqual(identityConflict.duplicateCanonicalIdentities, [canonical.journal.stableKey])
    let entries = (0..<140).map { searchLegacy(id: String(format: "legacy-%03d", $0)) }
    let first = CanonicalSessionSearchIndex(entries: entries)
    let reversed = CanonicalSessionSearchIndex(entries: entries.reversed())
    XCTAssertEqual(first.documents.count, 140)
    XCTAssertEqual(first.documents.map(\.id), reversed.documents.map(\.id))
    XCTAssertEqual(first.matching("legacy" ).count, CanonicalSessionSearchIndex.maximumResultCount)
}

func test_canonicalSessionSearchKeepsConversationLifecycleSeparateFromWorkLiveness() throws {
    let activeConversation = try searchCanonical()
    XCTAssertEqual(activeConversation.lifecycle, .active)
    XCTAssertEqual(CanonicalSessionLivenessProjection.project(
        inProcess: false, source: .canonical, summary: activeConversation), false)
    XCTAssertEqual(CanonicalSessionLivenessProjection.project(
        inProcess: true, source: .canonical, summary: activeConversation), true)
    XCTAssertEqual(CanonicalSessionLivenessProjection.project(
        inProcess: false, source: .legacyCompatibility, summary: nil), false)
    XCTAssertNil(CanonicalSessionLivenessProjection.project(
        inProcess: false, source: .canonical,
        summary: try searchCanonical(read: false)))
}
