import Foundation
@testable import AviaryCore

private func localCatalogHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-local-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AgentHome(root: root)
}

private let localCatalogActor = TimelineActor(actorID: "local-catalog-test", kind: "test")

private func localCatalogEvent(
    id: String, journal: JournalRef, sequence: Int, previous: String? = nil,
    type: String, session: SessionRef? = nil, work: WorkRef? = nil,
    workHost: WorkHostRef? = nil, sessionAttachment: SessionAttachmentRef? = nil,
    run: RunRef? = nil,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) throws -> Data {
    let event = TimelineEvent(
        eventID: id, journal: journal, sequence: sequence, previousEventID: previous,
        session: session, work: work, workHost: workHost,
        sessionAttachment: sessionAttachment, run: run,
        actor: localCatalogActor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, declaredDomains: declaredDomains, payload: payload)
    var data = try JSONEncoder().encode(event)
    data.append(0x0A)
    return data
}

private func localCatalogWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func localCatalogCursorValue(_ cursor: JournalCursor) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(cursor)))
}

private func localCatalogString(_ value: String) throws -> Data {
    try XCTUnwrap(value.data(using: .utf8))
}

func test_localTimelineCatalogDiscoversNativeSessionAndIndependentWork() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("catalog-session")
    let work = WorkRef(workHostID: "catalog-host", workID: "catalog-work")
    let sessionJournal = JournalRef.session(
        session, journalID: "session-journal", authority: TimelineAuthorityRef("session-service"))
    let workJournal = JournalRef.work(work, journalID: "work-journal")

    var workData = try localCatalogEvent(
        id: "w1", journal: workJournal, sequence: 1, type: TimelineEventType.workCreated,
        work: work, workHost: WorkHostRef(work.workHostID))
    workData.append(try localCatalogEvent(
        id: "w2", journal: workJournal, sequence: 2, previous: "w1",
        type: TimelineEventType.runStarted, work: work, workHost: WorkHostRef(work.workHostID),
        run: RunRef("run-1"), payload: .object(["model_id": .string("model-1")])))
    try localCatalogWrite(workData, to: home.timelineV2WorkJournalURL(work))

    var sessionData = try localCatalogEvent(
        id: "s1", journal: sessionJournal, sequence: 1, type: TimelineEventType.sessionCreated,
        session: session)
    sessionData.append(try localCatalogEvent(
        id: "s2", journal: sessionJournal, sequence: 2, previous: "s1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        sessionAttachment: SessionAttachmentRef("attachment-1"),
        payload: .object(["capabilities": .array([.string("observe")])])))
    try localCatalogWrite(sessionData, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let workRow = try XCTUnwrap(catalog.works.first { $0.work == work })
    XCTAssertTrue(workRow.isAvailable)
    XCTAssertEqual(workRow.cursor?.sequence, 2)
    XCTAssertEqual(workRow.lifecycle, .active)
    XCTAssertEqual(workRow.execution, .running)
    XCTAssertEqual(workRow.modelID, "model-1")
    XCTAssertEqual(workRow.activeRun, RunRef("run-1"))

    let sessionRow = try XCTUnwrap(catalog.sessions.first { $0.journal == sessionJournal })
    XCTAssertTrue(sessionRow.isAvailable)
    let summary = try XCTUnwrap(sessionRow.summary)
    XCTAssertFalse(summary.assemblyReady)
    XCTAssertEqual(summary.work.count, 1)
    XCTAssertEqual(summary.work[0].workReadAlignment, .exact)
    XCTAssertEqual(summary.work[0].cursorAlignment, .requestedUnavailable)
    XCTAssertTrue(LocalTimelineCatalog.blocksLegacyAction(
        home: home, sessionID: session.sessionID))
}

func test_localTimelineCatalogKeepsActiveWorkWhenSessionCursorIsAbsentOrStale() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("cursor-session")
    let work = WorkRef(workHostID: "cursor-host", workID: "cursor-work")
    let sessionJournal = JournalRef.session(
        session, journalID: "session-journal", authority: TimelineAuthorityRef("session-service"))
    let workJournal = JournalRef.work(work)
    var workData = try localCatalogEvent(
        id: "w1", journal: workJournal, sequence: 1, type: TimelineEventType.workCreated,
        work: work, workHost: WorkHostRef(work.workHostID))
    workData.append(try localCatalogEvent(
        id: "w2", journal: workJournal, sequence: 2, previous: "w1",
        type: TimelineEventType.hostOrderObserved, work: work, workHost: WorkHostRef(work.workHostID)))
    try localCatalogWrite(workData, to: home.timelineV2WorkJournalURL(work))

    let staleCursor = JournalCursor(journal: workJournal, eventID: "w1", sequence: 1)
    var sessionData = try localCatalogEvent(
        id: "s1", journal: sessionJournal, sequence: 1, type: TimelineEventType.sessionCreated,
        session: session)
    sessionData.append(try localCatalogEvent(
        id: "s2", journal: sessionJournal, sequence: 2, previous: "s1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        sessionAttachment: SessionAttachmentRef("attachment-1")))
    sessionData.append(try localCatalogEvent(
        id: "s3", journal: sessionJournal, sequence: 3, previous: "s2",
        type: TimelineEventType.sessionAttachmentCursorAdvanced, session: session,
        sessionAttachment: SessionAttachmentRef("attachment-1"),
        payload: .object(["cursor": try localCatalogCursorValue(staleCursor)])))
    try localCatalogWrite(sessionData, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.read(home: home)
    let workRow = try XCTUnwrap(catalog.works.first { $0.work == work })
    XCTAssertTrue(workRow.isAvailable)
    XCTAssertEqual(workRow.cursor?.eventID, "w2")
    let summary = try XCTUnwrap(catalog.sessions.first?.summary)
    XCTAssertFalse(summary.assemblyReady)
    XCTAssertEqual(summary.work.first?.cursorAlignment, .observedAhead)
    XCTAssertEqual(summary.work.first?.workReadAlignment, .exact)
}

func test_localTimelineCatalogRejectsOwnerAuthorityAndLocatorMismatches() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let actual = WorkRef(workHostID: "actual-host", workID: "actual-work")
    let declared = WorkRef(workHostID: "declared-host", workID: "declared-work")
    let declaredJournal = JournalRef.work(declared)
    let data = try localCatalogEvent(
        id: "mismatch", journal: declaredJournal, sequence: 1,
        type: TimelineEventType.workCreated, work: declared,
        workHost: WorkHostRef(declared.workHostID))
    try localCatalogWrite(data, to: home.timelineV2WorkJournalURL(actual))

    let wrongKind = SessionRef("wrong-kind")
    let wrongKindJournal = JournalRef.session(
        wrongKind, authority: TimelineAuthorityRef("service"))
    let wrongKindData = try localCatalogEvent(
        id: "wrong-kind", journal: wrongKindJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: wrongKind)
    let wrongKindURL = home.timelineV2WorkJournalURL(
        WorkRef(workHostID: "kind-host", workID: "kind-work"))
    try localCatalogWrite(wrongKindData, to: wrongKindURL)

    let authorityWork = WorkRef(workHostID: "authority-host", workID: "authority-work")
    let authorityJournal = JournalRef.work(authorityWork)
    let authorityEvent = try localCatalogEvent(
        id: "wrong-authority", journal: authorityJournal, sequence: 1,
        type: TimelineEventType.workCreated, work: authorityWork,
        workHost: WorkHostRef(authorityWork.workHostID))
    let authorityText = String(decoding: authorityEvent, as: UTF8.self)
        .replacingOccurrences(of: "\"authorityID\":\"authority-host\"",
                              with: "\"authorityID\":\"wrong-authority\"")
    try localCatalogWrite(Data(authorityText.utf8),
                          to: home.timelineV2WorkJournalURL(authorityWork))

    let catalog = LocalTimelineCatalog.scan(home: home)
    XCTAssertEqual(catalog.works.count, 3)
    XCTAssertTrue(catalog.works.allSatisfy { !$0.isAvailable && $0.cursor == nil })
    XCTAssertTrue(catalog.diagnostics.contains { $0.kind == "unavailable_work" })
}

func test_localTimelineCatalogKeepsTruncatedAndCorruptFilesVisible() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let truncated = WorkRef(workHostID: "tail-host", workID: "tail-work")
    let truncatedJournal = JournalRef.work(truncated)
    var data = try localCatalogEvent(
        id: "tail-1", journal: truncatedJournal, sequence: 1,
        type: TimelineEventType.workCreated, work: truncated,
        workHost: WorkHostRef(truncated.workHostID))
    data.append(try localCatalogString("{\"incomplete\":true"))
    try localCatalogWrite(data, to: home.timelineV2WorkJournalURL(truncated))

    let corrupt = WorkRef(workHostID: "corrupt-host", workID: "corrupt-work")
    try localCatalogWrite(
        try localCatalogString("not-json\n"), to: home.timelineV2WorkJournalURL(corrupt))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let tailRow = try XCTUnwrap(catalog.works.first { $0.work == truncated })
    XCTAssertFalse(tailRow.isAvailable)
    XCTAssertEqual(tailRow.committedPrefixCursor?.eventID, "tail-1")
    XCTAssertNil(tailRow.cursor)
    XCTAssertTrue(tailRow.tailBytes > 0)
    XCTAssertTrue(tailRow.corruptionReasons.contains { $0.contains("truncated") })
    let corruptRow = try XCTUnwrap(catalog.works.first { $0.work == nil })
    XCTAssertFalse(corruptRow.isAvailable)
    XCTAssertTrue(corruptRow.corruptionReasons.contains { $0.contains("first complete") })
    XCTAssertTrue(catalog.diagnostics.filter { $0.kind == "unavailable_work" }.count >= 2)
}

func test_localTimelineCatalogKeepsTailedSessionVisibleButNonProjectable() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("tailed-session")
    let journal = JournalRef.session(
        session, authority: TimelineAuthorityRef("session-service"))
    var data = try localCatalogEvent(
        id: "s1", journal: journal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: session)
    data.append(try localCatalogEvent(
        id: "s2", journal: journal, sequence: 2, previous: "s1",
        type: "future.session_context", session: session,
        declaredDomains: [.context]))
    data.append(Data("{\"unfinished\":".utf8))
    try localCatalogWrite(data, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let row = try XCTUnwrap(catalog.sessions.first)
    XCTAssertFalse(row.isAvailable)
    XCTAssertNil(row.summary)
    XCTAssertTrue(row.tailBytes > 0)
    XCTAssertTrue(row.corruptionReasons.contains { $0.contains("truncated") })
    XCTAssertEqual(row.unknownEventRefs.map(\.eventID), ["s2"])
    XCTAssertEqual(row.unknownDomains, [.context])
    XCTAssertTrue(catalog.sessionSummaries.isEmpty)
}

func test_localTimelineCatalogClassifiesUnterminatedFirstEventAsTail() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "unterminated-host", workID: "unterminated-work")
    let journal = JournalRef.work(work)
    var data = try localCatalogEvent(
        id: "w1", journal: journal, sequence: 1,
        type: TimelineEventType.workCreated, work: work,
        workHost: WorkHostRef(work.workHostID))
    data.removeLast()
    try localCatalogWrite(data, to: home.timelineV2WorkJournalURL(work))

    let row = try XCTUnwrap(LocalTimelineCatalog.scan(home: home).works.first)
    XCTAssertEqual(row.work, work)
    XCTAssertFalse(row.isAvailable)
    XCTAssertNil(row.cursor)
    XCTAssertNil(row.committedPrefixCursor)
    XCTAssertEqual(row.tailBytes, data.count)
    XCTAssertTrue(row.corruptionReasons.contains { $0.contains("truncated") })
    XCTAssertTrue(LocalTimelineCatalog.blocksLegacyAction(
        home: home, sessionID: work.workID) == false)
}

func test_localTimelineCatalogBlocksMalformedNativeSessionAtLegacyActionBoundary() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let sessionID = "malformed-native-session"
    try localCatalogWrite(
        Data("not-json\n".utf8),
        to: home.timelineV2SessionJournalURL(sessionID: sessionID))

    XCTAssertTrue(LocalTimelineCatalog.blocksLegacyAction(home: home, sessionID: sessionID))
    XCTAssertFalse(LocalTimelineCatalog.blocksLegacyAction(
        home: home, sessionID: "legacy-only-session"))
}

func test_localTimelineCatalogSuppressesFactsInUnknownDeclaredDomains() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "unknown-host", workID: "unknown-work")
    let journal = JournalRef.work(work)
    var data = try localCatalogEvent(
        id: "w1", journal: journal, sequence: 1,
        type: TimelineEventType.workCreated, work: work,
        workHost: WorkHostRef(work.workHostID))
    data.append(try localCatalogEvent(
        id: "w2", journal: journal, sequence: 2, previous: "w1",
        type: TimelineEventType.runStarted, work: work,
        workHost: WorkHostRef(work.workHostID), run: RunRef("run-unknown"),
        payload: .object(["model_id": .string("model-before-unknown")])))
    data.append(try localCatalogEvent(
        id: "w3", journal: journal, sequence: 3, previous: "w2",
        type: "future.work_semantics", work: work,
        workHost: WorkHostRef(work.workHostID), declaredDomains: [.work]))
    try localCatalogWrite(data, to: home.timelineV2WorkJournalURL(work))

    let session = SessionRef("unknown-session")
    let sessionJournal = JournalRef.session(
        session, authority: TimelineAuthorityRef("session-service"))
    let attachment = SessionAttachmentRef("unknown-attachment")
    var sessionData = try localCatalogEvent(
        id: "s1", journal: sessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: session)
    sessionData.append(try localCatalogEvent(
        id: "s2", journal: sessionJournal, sequence: 2, previous: "s1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        sessionAttachment: attachment))
    sessionData.append(try localCatalogEvent(
        id: "s3", journal: sessionJournal, sequence: 3, previous: "s2",
        type: TimelineEventType.sessionAttachmentCursorAdvanced, session: session,
        sessionAttachment: attachment,
        payload: .object([
            "cursor": try localCatalogCursorValue(JournalCursor(
                journal: journal, eventID: "w3", sequence: 3)),
        ])))
    try localCatalogWrite(sessionData, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let row = try XCTUnwrap(catalog.works.first)
    XCTAssertTrue(row.isAvailable, "the append chain remains readable")
    XCTAssertEqual(row.unknownDomains, [.work])
    XCTAssertEqual(row.unknownEventRefs.map(\.eventID), ["w3"])
    XCTAssertNil(row.lifecycle)
    XCTAssertNil(row.execution)
    XCTAssertNil(row.modelID)
    XCTAssertNil(row.activeRun)
    let joinedWork = try XCTUnwrap(catalog.sessionSummaries.first?.work.first)
    XCTAssertFalse(joinedWork.canProjectExecution)
    XCTAssertEqual(joinedWork.lifecycle, .unknown)
    XCTAssertNil(joinedWork.modelID)
}

func test_localTimelineCatalogReportsUnreadableCatalogDirectories() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    try FileManager.default.createDirectory(
        at: home.timelineV2Root, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: home.timelineV2SessionsDir)

    let catalog = LocalTimelineCatalog.scan(home: home)
    XCTAssertTrue(catalog.sessions.isEmpty)
    XCTAssertTrue(catalog.diagnostics.contains { $0.kind == "unavailable_directory" })
    XCTAssertFalse(catalog.diagnostics.contains { $0.message.contains(home.root.path) })
    XCTAssertTrue(LocalTimelineCatalog.blocksLegacyAction(
        home: home, sessionID: "possibly-hidden-native-session"))
}

func test_localTimelineCatalogRejectsSymlinkEscapes() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let outside = home.root.deletingLastPathComponent()
        .appending(path: "aviary-local-catalog-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideWork = WorkRef(workHostID: "escape-host", workID: "escape-work")
    let outsideJournal = outside.appending(path: "journal.jsonl")
    try localCatalogWrite(try localCatalogEvent(
        id: "escape", journal: .work(outsideWork), sequence: 1,
        type: TimelineEventType.workCreated, work: outsideWork,
        workHost: WorkHostRef(outsideWork.workHostID)), to: outsideJournal)
    let hostDir = home.timelineV2WorkHostsDir.appending(path: "escape-host")
    let worksDir = hostDir.appending(path: "works")
    try FileManager.default.createDirectory(at: worksDir, withIntermediateDirectories: true)
    let escapedDir = worksDir.appending(path: "escape-work")
    try FileManager.default.createSymbolicLink(at: escapedDir, withDestinationURL: outside)

    let catalog = LocalTimelineCatalog.scan(home: home)
    XCTAssertTrue(catalog.works.isEmpty)
    XCTAssertTrue(catalog.diagnostics.contains { $0.kind == "unsafe_locator" })
}

func test_localTimelineCatalogRejectsSymlinkedHomeRootAuthority() throws {
    let realHome = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: realHome.root) }
    let linkRoot = realHome.root.deletingLastPathComponent()
        .appending(path: "aviary-local-catalog-link-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: linkRoot) }
    try FileManager.default.createSymbolicLink(
        at: linkRoot, withDestinationURL: realHome.root)
    let linkedHome = AgentHome(root: linkRoot)
    let work = WorkRef(workHostID: "root-link-host", workID: "root-link-work")
    try localCatalogWrite(try localCatalogEvent(
        id: "w1", journal: .work(work), sequence: 1,
        type: TimelineEventType.workCreated, work: work,
        workHost: WorkHostRef(work.workHostID)),
        to: realHome.timelineV2WorkJournalURL(work))

    let catalog = LocalTimelineCatalog.scan(home: linkedHome)
    let row = try XCTUnwrap(catalog.works.first)
    XCTAssertNil(row.work)
    XCTAssertFalse(row.isAvailable)
    XCTAssertTrue(catalog.diagnostics.contains { $0.kind == "unavailable_work" })
    XCTAssertFalse(catalog.diagnostics.contains { $0.message.contains(linkRoot.path) })
}

func test_localTimelineCatalogReportsDuplicateEventIdentityWithoutTrapping() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "duplicate-host", workID: "duplicate-work")
    let journal = JournalRef.work(work)
    var data = try localCatalogEvent(
        id: "same", journal: journal, sequence: 1, type: TimelineEventType.workCreated,
        work: work, workHost: WorkHostRef(work.workHostID))
    data.append(try localCatalogEvent(
        id: "same", journal: journal, sequence: 2, previous: "same",
        type: TimelineEventType.hostOrderObserved, work: work,
        workHost: WorkHostRef(work.workHostID)))
    try localCatalogWrite(data, to: home.timelineV2WorkJournalURL(work))

    let row = try XCTUnwrap(LocalTimelineCatalog.scan(home: home).works.first)
    XCTAssertFalse(row.isAvailable)
    XCTAssertTrue(row.corruptionReasons.contains { $0.contains("quarantined") || $0.contains("duplicate") })
}

func test_localTimelineCatalogRoundTripsUnsafeEncodedWorkIDs() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "host/../encoded", workID: "work/with/slash")
    let journal = JournalRef.work(work)
    try localCatalogWrite(try localCatalogEvent(
        id: "encoded", journal: journal, sequence: 1, type: TimelineEventType.workCreated,
        work: work, workHost: WorkHostRef(work.workHostID)),
        to: home.timelineV2WorkJournalURL(work))

    let row = try XCTUnwrap(LocalTimelineCatalog.scan(home: home).works.first)
    XCTAssertTrue(row.isAvailable)
    XCTAssertEqual(row.work, work)
    XCTAssertEqual(row.journal, journal)
    XCTAssertTrue(row.id.contains(work.workHostID))
    XCTAssertFalse(row.corruptionReasons.contains { $0.contains("round-trip") })
}

func test_localTimelineCatalogWorkRowIDsAreInjectiveAcrossSlashBoundaries() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    // These collided under the old `host/work` display identity even though both WorkRefs are
    // distinct and both locator round trips are valid.
    let first = WorkRef(workHostID: "a/b", workID: "c")
    let second = WorkRef(workHostID: "a", workID: "b/c")
    for (index, work) in [first, second].enumerated() {
        try localCatalogWrite(try localCatalogEvent(
            id: "work-\(index)", journal: .work(work), sequence: 1,
            type: TimelineEventType.workCreated, work: work,
            workHost: WorkHostRef(work.workHostID)),
            to: home.timelineV2WorkJournalURL(work))
    }

    let catalog = LocalTimelineCatalog.scan(home: home)
    XCTAssertEqual(Set(catalog.works.compactMap(\.work)), Set([first, second]))
    XCTAssertTrue(catalog.works.allSatisfy(\.isAvailable))
    XCTAssertEqual(Set(catalog.works.map(\.id)).count, 2)
    XCTAssertFalse(catalog.diagnostics.contains { $0.kind == "duplicate_work" })
}

func test_localTimelineCatalogOrderingBoundsAndMetadataAreDeterministic() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    for index in ["z", "a", "m"] {
        let work = WorkRef(workHostID: "bound-host", workID: index)
        try localCatalogWrite(try localCatalogEvent(
            id: index, journal: .work(work), sequence: 1, type: TimelineEventType.workCreated,
            work: work, workHost: WorkHostRef(work.workHostID)),
            to: home.timelineV2WorkJournalURL(work))
    }
    let limits = LocalTimelineCatalog.Limits(maxWorkJournals: 2, maxDiagnostics: 4)
    let first = LocalTimelineCatalog.scan(home: home, limits: limits)
    let second = LocalTimelineCatalog.scan(home: home, limits: limits)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.works.count, 2)
    XCTAssertEqual(first.works.map(\.id), first.works.map(\.id).sorted())
    XCTAssertTrue(first.diagnostics.count <= 4)
    XCTAssertTrue(first.diagnostics.allSatisfy {
        $0.message.count <= LocalTimelineCatalog.Diagnostic.maxMessageCharacters
    })
    XCTAssertEqual(Set(first.diagnostics.map(\.id)).count, first.diagnostics.count)
    XCTAssertFalse(first.works.contains { $0.corruptionReasons.contains(home.root.path) })
    XCTAssertFalse(first.diagnostics.contains { $0.message.contains(home.root.path) })
}
