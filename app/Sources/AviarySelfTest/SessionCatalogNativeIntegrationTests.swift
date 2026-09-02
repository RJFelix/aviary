import Foundation
@testable import AviaryCore

private let nativeCatalogTestActor = TimelineActor(
    actorID: "session-catalog-native-integration", kind: "test")

private func nativeCatalogHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-session-catalog-native-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AgentHome(root: root)
}

private func nativeCatalogEvent(
    id: String,
    journal: JournalRef,
    sequence: Int,
    previous: String? = nil,
    session: SessionRef? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    type: String,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) throws -> Data {
    let event = TimelineEvent(
        eventID: id, journal: journal, sequence: sequence, previousEventID: previous,
        session: session, work: work, workHost: workHost,
        actor: nativeCatalogTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, declaredDomains: declaredDomains, payload: payload)
    var data = try JSONEncoder().encode(event)
    data.append(0x0A)
    return data
}

private func appendNativeCatalogEvent(
    _ data: inout Data,
    id: String,
    journal: JournalRef,
    sequence: Int,
    previous: String? = nil,
    session: SessionRef? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    type: String,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) throws {
    data.append(try nativeCatalogEvent(
        id: id, journal: journal, sequence: sequence, previous: previous,
        session: session, work: work, workHost: workHost, type: type,
        declaredDomains: declaredDomains, payload: payload))
}

private func writeNativeCatalogJournal(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func writeNativeCatalogLegacy(
    _ home: AgentHome,
    id: String,
    name: String,
    state: String = "completed",
    model: String = "legacy-model"
) throws {
    try FileManager.default.createDirectory(at: home.sessionsDir, withIntermediateDirectories: true)
    let jsonl = [
        "{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\",\"timestamp\":\"2026-08-20T10:00:00.000Z\",\"cwd\":\"/tmp/project\"}",
        "{\"type\":\"session_info\",\"name\":\"\(name)\"}",
        "{\"type\":\"session_state\",\"state\":{\"status\":\"\(state)\"}}",
        "{\"type\":\"model_change\",\"provider\":\"legacy-provider\",\"modelId\":\"\(model)\"}",
        "{\"type\":\"message\",\"id\":\"legacy-message\",\"parentId\":null,\"timestamp\":\"2026-08-20T10:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"legacy prompt\"}}"
    ].joined(separator: "\n") + "\n"
    try Data(jsonl.utf8).write(to: home.sessionFile(id: id), options: .atomic)
}

private func nativeSessionJournal(
    _ session: SessionRef,
    authority: String = "native-session-host"
) -> JournalRef {
    JournalRef.session(
        session, journalID: "native-session-journal",
        authority: TimelineAuthorityRef(authority))
}

private func nativeSessionData(
    _ session: SessionRef,
    authority: String = "native-session-host",
    includeTitle: Bool = true,
    model: String = "native-model",
    attention: String = "review"
) throws -> Data {
    let journal = nativeSessionJournal(session, authority: authority)
    var data = try nativeCatalogEvent(
        id: "session-created", journal: journal, sequence: 1, session: session,
        type: TimelineEventType.sessionCreated)
    try appendNativeCatalogEvent(
        &data, id: "model-changed", journal: journal, sequence: 2,
        previous: "session-created", session: session, type: TimelineEventType.modelChanged,
        payload: .object(["model_id": .string(model)]))
    try appendNativeCatalogEvent(
        &data, id: "attention", journal: journal, sequence: 3,
        previous: "model-changed", session: session, type: TimelineEventType.sessionAttention,
        payload: .object(["attention": .string(attention)]))
    if includeTitle {
        try appendNativeCatalogEvent(
            &data, id: "native-prompt", journal: journal, sequence: 4,
            previous: "attention", session: session, type: TimelineEventType.inputAccepted,
            payload: .object(["text": .string("native prompt")]))
    }
    return data
}

func test_sessionCatalogScanCatalogJoinsNativeAndLegacyIntoOneCompanion() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("joined-native-legacy")
    try writeNativeCatalogLegacy(home, id: session.sessionID, name: "Legacy title")
    try writeNativeCatalogJournal(
        try nativeSessionData(session), to: home.timelineV2SessionJournalURL(session))

    let result = await SessionCatalog(home: home).scanCatalog()
    XCTAssertEqual(result.entries.count, 1)
    let entry = try XCTUnwrap(result.entries.first)
    XCTAssertEqual(entry.id, session.sessionID)
    XCTAssertEqual(entry.title, "native prompt")
    XCTAssertEqual(entry.canonical?.lifecycle, .active)
    XCTAssertEqual(entry.canonical?.modelIDs, ["native-model"])
    XCTAssertEqual(entry.canonical?.attention, .review)
    XCTAssertEqual(entry.legacySummary?.id, session.sessionID)
    XCTAssertEqual(entry.legacySummary?.model, "legacy-model")
    XCTAssertEqual(entry.legacySummary?.sessionState, "completed")
    XCTAssertEqual(entry.displaySummary?.model, "native-model")
    XCTAssertNil(entry.displaySummary?.provider)
    XCTAssertEqual(entry.displaySummary?.sessionState, "active")
    XCTAssertEqual(
        entry.legacySummary?.fileURL?.resolvingSymlinksInPath(),
        home.sessionFile(id: session.sessionID).resolvingSymlinksInPath())
    XCTAssertFalse(entry.displaySummary?.isCanonicalOnly == true)
    XCTAssertEqual(result.nativeCompanionLegacyIDs, [session.sessionID])
    XCTAssertEqual(result.diagnostics, [])
}

func test_sessionCatalogScanCatalogRetainsNativeOnlyRowsAsCanonicalOnly() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("native-only-session")
    try writeNativeCatalogJournal(
        try nativeSessionData(session, includeTitle: false),
        to: home.timelineV2SessionJournalURL(session))

    let result = await SessionCatalog(home: home).scanCatalog()
    let entry = try XCTUnwrap(result.entries.first)
    XCTAssertEqual(result.entries.count, 1)
    XCTAssertEqual(entry.id, nativeSessionJournal(session).stableKey)
    XCTAssertNil(entry.legacySummary)
    XCTAssertNil(entry.legacyID)
    XCTAssertNil(entry.displaySummary?.fileURL)
    XCTAssertTrue(entry.displaySummary?.isCanonicalOnly == true)
    XCTAssertEqual(entry.canonical?.modelIDs, ["native-model"])
    XCTAssertFalse(LocalTimelineCatalog.blocksLegacyAction(
        home: home, sessionID: session.sessionID))
}

func test_sessionCatalogScanCatalogLeavesLegacyOnlyRowsUnchanged() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    try writeNativeCatalogLegacy(
        home, id: "legacy-only-session", name: "Legacy-only title", model: "legacy-only-model")

    let result = await SessionCatalog(home: home).scanCatalog()
    let entry = try XCTUnwrap(result.entries.first)
    XCTAssertEqual(result.entries.count, 1)
    XCTAssertEqual(entry.id, "legacy-only-session")
    XCTAssertEqual(
        entry.legacySummary?.fileURL?.resolvingSymlinksInPath(),
        home.sessionFile(id: "legacy-only-session").resolvingSymlinksInPath())
    XCTAssertFalse(entry.displaySummary?.isCanonicalOnly == true)
    XCTAssertEqual(entry.canonical?.modelIDs, ["legacy-only-model"])
    XCTAssertFalse(entry.canonical?.sessionSemanticProjectionValid == true)
    XCTAssertTrue(result.nativeCompanionLegacyIDs.isEmpty,
                  "legacy-only roots must remain eligible for the compatibility Flock view")
}

func test_sessionCatalogScanCatalogKeepsIndependentWorkWithoutSession() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "independent-host", workID: "orphan-work")
    let journal = JournalRef.work(work)
    let data = try nativeCatalogEvent(
        id: "work-created", journal: journal, sequence: 1, work: work,
        workHost: WorkHostRef(work.workHostID), type: TimelineEventType.workCreated)
    try writeNativeCatalogJournal(data, to: home.timelineV2WorkJournalURL(work))

    let result = await SessionCatalog(home: home).scanCatalog()
    XCTAssertEqual(result.entries, [])
    let workRow = try XCTUnwrap(result.workInventory.first)
    XCTAssertEqual(result.workInventory.count, 1)
    XCTAssertEqual(workRow.work, work)
    XCTAssertTrue(workRow.isAvailable)
    XCTAssertEqual(workRow.lifecycle, .active)
}

func test_sessionCatalogScanCatalogKeepsUnknownSessionVisibleButSuppressesItsFacts() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("future-session-domain")
    let journal = nativeSessionJournal(session)
    var data = try nativeSessionData(session)
    try appendNativeCatalogEvent(
        &data, id: "future-session-event", journal: journal, sequence: 5,
        previous: "native-prompt", session: session, type: "future.session_semantics",
        declaredDomains: [.session])
    try writeNativeCatalogJournal(data, to: home.timelineV2SessionJournalURL(session))

    let result = await SessionCatalog(home: home).scanCatalog()
    let canonical = try XCTUnwrap(result.entries.first?.canonical)
    XCTAssertEqual(result.entries.count, 1)
    XCTAssertEqual(canonical.unknownDomains, [.session])
    XCTAssertEqual(canonical.title, "")
    XCTAssertEqual(canonical.lifecycle, .unknown)
    XCTAssertEqual(canonical.authoredAttention, .none)
    XCTAssertNil(canonical.effectiveAttention)
    XCTAssertNil(canonical.sessionModelID)
    XCTAssertEqual(canonical.visibleMessages, [])
    XCTAssertEqual(canonical.work, [])
    XCTAssertFalse(canonical.assemblyReady)
    XCTAssertTrue(canonical.hasOngoingOrUncertainAttachedWork)
}

func test_sessionCatalogScanCatalogDoesNotPairConflictingNativeAuthority() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("ambiguous-native-session")
    try writeNativeCatalogLegacy(home, id: session.sessionID, name: "Legacy remains")
    let firstJournal = nativeSessionJournal(session, authority: "authority-a")
    let secondJournal = nativeSessionJournal(session, authority: "authority-b")
    var data = try nativeCatalogEvent(
        id: "first", journal: firstJournal, sequence: 1, session: session,
        type: TimelineEventType.sessionCreated)
    // A second authority in the same locator is the filesystem-constructible form of an
    // authority collision. The reducer quarantines it, and scanCatalog must not make a native
    // companion out of the resulting partial/corrupt snapshot.
    data.append(try nativeCatalogEvent(
        id: "other-authority", journal: secondJournal, sequence: 2,
        previous: "first", session: session, type: TimelineEventType.modelChanged,
        payload: .object(["model_id": .string("untrusted-model")])) )
    try writeNativeCatalogJournal(data, to: home.timelineV2SessionJournalURL(session))

    let result = await SessionCatalog(home: home).scanCatalog()
    let entry = try XCTUnwrap(result.entries.first)
    XCTAssertEqual(result.entries.count, 1)
    XCTAssertEqual(entry.legacySummary?.id, session.sessionID)
    XCTAssertEqual(entry.canonical?.modelIDs, ["legacy-model"])
    XCTAssertFalse(entry.canonical?.sessionSemanticProjectionValid == true)
    XCTAssertTrue(result.diagnostics.contains { $0.kind == "unavailable_session" })
    XCTAssertTrue(result.nativeActionBlockedSessionIDs.contains(session.sessionID))
}

func test_sessionCatalogScanCatalogCorruptNativeTailCannotReplaceHealthyLegacy() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("tailed-native-session")
    try writeNativeCatalogLegacy(
        home, id: session.sessionID, name: "Healthy legacy", model: "healthy-legacy-model")
    var data = try nativeSessionData(session, includeTitle: false, model: "corrupt-native-model")
    data.append(Data("{\"incomplete\":".utf8))
    try writeNativeCatalogJournal(data, to: home.timelineV2SessionJournalURL(session))

    let result = await SessionCatalog(home: home).scanCatalog()
    let entry = try XCTUnwrap(result.entries.first)
    XCTAssertEqual(result.entries.count, 1)
    XCTAssertEqual(
        entry.legacySummary?.fileURL?.resolvingSymlinksInPath(),
        home.sessionFile(id: session.sessionID).resolvingSymlinksInPath())
    XCTAssertEqual(entry.canonical?.modelIDs, ["healthy-legacy-model"])
    XCTAssertEqual(entry.canonical?.lifecycle, .completed)
    XCTAssertTrue(entry.canonical?.corruptionReasons.contains {
        $0.contains("legacy SessionSummary mapped")
    } == true)
    XCTAssertFalse(entry.displaySummary?.isCanonicalOnly == true)
    XCTAssertTrue(result.diagnostics.contains { $0.kind == "unavailable_session" })
    XCTAssertTrue(result.nativeActionBlockedSessionIDs.contains(session.sessionID))
}

func test_sessionCatalogTrashSharesTheNativeSessionOwnerLock() async throws {
    let home = try nativeCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("locked-native-session")
    try writeNativeCatalogLegacy(home, id: session.sessionID, name: "Locked transcript")
    let journal = nativeSessionJournal(session)
    let writer = try TimelineJournalWriter(
        freshAt: home.timelineV2SessionJournalURL(session), journal: journal,
        actor: nativeCatalogTestActor, home: home)
    _ = try await writer.append(TimelineEventDraft(
        session: session, type: TimelineEventType.sessionCreated,
        declaredDomains: [.session]))

    let catalog = SessionCatalog(home: home)
    let summary = try XCTUnwrap(await catalog.scan().first)
    let blocked = await catalog.trash(sessions: [summary])
    XCTAssertEqual(blocked.trashedIDs, [])
    XCTAssertNotNil(blocked.failures[session.sessionID])
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: home.sessionFile(id: session.sessionID).path))

    try await writer.closeChecked()
    let completed = await catalog.trash(sessions: [summary])
    XCTAssertEqual(completed.trashedIDs, [session.sessionID])
    XCTAssertEqual(completed.failures, [:])
    XCTAssertFalse(FileManager.default.fileExists(
        atPath: home.sessionFile(id: session.sessionID).path))
}
