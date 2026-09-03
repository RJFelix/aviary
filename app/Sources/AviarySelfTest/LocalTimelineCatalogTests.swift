import Foundation
import CryptoKit
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
    run: RunRef? = nil, client: ClientRef? = nil,
    clientAttachment: ClientAttachmentRef? = nil,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) throws -> Data {
    let event = TimelineEvent(
        eventID: id, journal: journal, sequence: sequence, previousEventID: previous,
        session: session, work: work, workHost: workHost,
        client: client, sessionAttachment: sessionAttachment,
        clientAttachment: clientAttachment, run: run,
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

private struct LocalCatalogControlDurabilitySeal: Codable {
    let schemaVersion: Int
    let journal: JournalRef
    let cursor: JournalCursor
    let byteCount: Int
    let sha256: String
}

private func localCatalogWriteControl(
    _ data: Data, journal: JournalRef, to url: URL, sealed: Bool = true
) throws {
    try localCatalogWrite(data, to: url)
    guard sealed else { return }
    let read = TimelineJournalReader.read(
        data, journal: journal, actor: localCatalogActor,
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let last = read.records.last?.event
    let cursor = JournalCursor(
        journal: journal, eventID: last?.eventID, sequence: last?.sequence ?? 0)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let seal = LocalCatalogControlDurabilitySeal(
        schemaVersion: 1, journal: journal, cursor: cursor,
        byteCount: data.count, sha256: digest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var sealData = try encoder.encode(seal)
    sealData.append(0x0A)
    try sealData.write(
        to: WorkHostControlJournal.durabilitySealURL(for: url), options: .atomic)
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
    XCTAssertTrue(catalog.canonicalNotificationSourceComplete)
    XCTAssertTrue(catalog.workHostControls.isEmpty,
                  "this fixture intentionally has no Work Host control journal")
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

func test_localTimelineCatalogRejectsOwnerAuthorityAndLocatorMismatchesLocally() throws {
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
    XCTAssertTrue(catalog.canonicalNotificationSourceComplete,
                  "row-local unavailable facts must not block unrelated notification rows")
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
    let corruptControlHost = WorkHostRef("corrupt-control-host")
    try localCatalogWrite(
        try localCatalogString("not-json\n"),
        to: home.timelineV2WorkHostControlJournalURL(corruptControlHost))
    let missingSealHost = WorkHostRef("missing-seal-host")
    let missingSealJournal = JournalRef.workHost(missingSealHost)
    try localCatalogWrite(
        try localCatalogEvent(
            id: "missing-seal", journal: missingSealJournal, sequence: 1,
            type: TimelineEventType.hostOrderObserved, workHost: missingSealHost),
        to: home.timelineV2WorkHostControlJournalURL(missingSealHost))
    let mismatchedSealHost = WorkHostRef("mismatched-seal-host")
    let mismatchedSealJournal = JournalRef.workHost(mismatchedSealHost)
    let mismatchedSealURL = home.timelineV2WorkHostControlJournalURL(mismatchedSealHost)
    try localCatalogWriteControl(
        try localCatalogEvent(
            id: "mismatched-seal", journal: mismatchedSealJournal, sequence: 1,
            type: TimelineEventType.hostOrderObserved, workHost: mismatchedSealHost),
        journal: mismatchedSealJournal, to: mismatchedSealURL)
    try localCatalogWrite(
        try localCatalogString("{\"schemaVersion\":1}\n"),
        to: WorkHostControlJournal.durabilitySealURL(for: mismatchedSealURL))
    let unsealedSuffixHost = WorkHostRef("unsealed-suffix-host")
    let unsealedSuffixJournal = JournalRef.workHost(unsealedSuffixHost)
    let unsealedSuffixURL = home.timelineV2WorkHostControlJournalURL(unsealedSuffixHost)
    let sealedPrefix = try localCatalogEvent(
        id: "sealed-prefix", journal: unsealedSuffixJournal, sequence: 1,
        type: TimelineEventType.hostOrderObserved, workHost: unsealedSuffixHost)
    try localCatalogWriteControl(
        sealedPrefix, journal: unsealedSuffixJournal, to: unsealedSuffixURL)
    let uncommittedSuffix = try localCatalogEvent(
        id: "uncommitted-suffix", journal: unsealedSuffixJournal, sequence: 2,
        previous: "sealed-prefix", type: TimelineEventType.hostOrderObserved,
        workHost: unsealedSuffixHost)
    try localCatalogWrite(sealedPrefix + uncommittedSuffix, to: unsealedSuffixURL)

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
    let corruptControlRow = try XCTUnwrap(catalog.workHostControls.first {
        $0.workHost == nil && !$0.isAvailable
    })
    XCTAssertTrue(corruptControlRow.corruptionReasons.contains {
        $0.contains("Work Host control")
    })
    let missingSealRow = try XCTUnwrap(catalog.workHostControls.first {
        $0.workHost == missingSealHost
    })
    XCTAssertFalse(missingSealRow.isAvailable)
    XCTAssertTrue(missingSealRow.corruptionReasons.contains {
        $0.contains("durability seal")
    })
    let mismatchedSealRow = try XCTUnwrap(catalog.workHostControls.first {
        $0.workHost == mismatchedSealHost
    })
    XCTAssertFalse(mismatchedSealRow.isAvailable)
    XCTAssertTrue(mismatchedSealRow.corruptionReasons.contains {
        $0.contains("durability seal")
    })
    let recoveredPrefixRow = try XCTUnwrap(catalog.workHostControls.first {
        $0.workHost == unsealedSuffixHost
    })
    XCTAssertTrue(recoveredPrefixRow.isAvailable)
    XCTAssertEqual(recoveredPrefixRow.cursor?.eventID, "sealed-prefix")
    XCTAssertEqual(recoveredPrefixRow.unsealedSuffixBytes, uncommittedSuffix.count)
    XCTAssertEqual(recoveredPrefixRow.tailBytes, uncommittedSuffix.count)
    XCTAssertTrue(catalog.diagnostics.contains {
        $0.kind == "unsealed_work_host_control_suffix"
    })
    XCTAssertTrue(catalog.diagnostics.contains { $0.kind == "unavailable_work_host_control" })
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

func test_localTimelineCatalogKeepsSemanticallyInvalidSessionVisibleButWithholdsSummary() throws {
    let home = try localCatalogHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("semantic-invalid-session")
    let journal = JournalRef.session(session, authority: TimelineAuthorityRef("session-service"))
    var data = try localCatalogEvent(
        id: "s1", journal: journal, sequence: 1, type: TimelineEventType.sessionCreated,
        session: session)
    // The event is structurally valid but cannot be semantically projected by SessionReducer.
    let malformedPayload: JSONValue = .object([
        "components": .array([.object(["bad": .bool(true)])]),
    ])
    data.append(try localCatalogEvent(
        id: "s2", journal: journal, sequence: 2, previous: "s1",
        type: TimelineEventType.contextAssembled, session: session,
        declaredDomains: [.context],
        payload: malformedPayload))
    try localCatalogWrite(data, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let row = try XCTUnwrap(catalog.sessions.first)
    XCTAssertFalse(row.isAvailable)
    XCTAssertNil(row.summary)
    XCTAssertTrue(row.corruptionReasons.contains { $0.contains("semantic") })
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

    let controlJournal = JournalRef.workHost(WorkHostRef(work.workHostID))
    try localCatalogWriteControl(
        try localCatalogEvent(
            id: "c1", journal: controlJournal, sequence: 1,
            type: "future.control_semantics", workHost: WorkHostRef(work.workHostID),
            declaredDomains: [.externalEffects]),
        journal: controlJournal,
        to: home.timelineV2WorkHostControlJournalURL(workHostID: work.workHostID))

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
    let controlRow = try XCTUnwrap(catalog.workHostControls.first)
    XCTAssertFalse(controlRow.isAvailable)
    XCTAssertEqual(controlRow.unknownEventRefs.map(\.eventID), ["c1"])
    XCTAssertEqual(controlRow.unknownDomains, [.externalEffects])
    XCTAssertTrue(controlRow.clientAttachments.isEmpty)
    XCTAssertTrue(controlRow.readAcknowledgements.isEmpty)
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

func test_localTimelineCatalogReportsDuplicateEventIdentityWithoutBlockingOtherRows() throws {
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
    XCTAssertTrue(LocalTimelineCatalog.scan(home: home).canonicalNotificationSourceComplete,
                  "a duplicate row is omitted without making global discovery uncertain")
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
    let boundedWork = WorkRef(workHostID: "bound-host", workID: "a")
    let boundedWorkJournal = JournalRef.work(boundedWork)
    let controlHost = WorkHostRef("bound-host")
    let controlJournal = JournalRef.workHost(controlHost)
    let controlPayload: (JournalRef, Set<String>) -> JSONValue = { journal, capabilities in
        .object([
            "work_journal": JSONValue.parse(try! JSONEncoder().encode(journal))!,
            "capabilities": .array(capabilities.sorted().map(JSONValue.string)),
        ])
    }
    var controlData = try localCatalogEvent(
        id: "c1", journal: controlJournal, sequence: 1,
        type: TimelineEventType.clientAttached, work: boundedWork,
        workHost: controlHost, client: ClientRef("client-a"),
        clientAttachment: ClientAttachmentRef("attachment-a"),
        payload: controlPayload(boundedWorkJournal, ["observe"]))
    controlData.append(try localCatalogEvent(
        id: "c2", journal: controlJournal, sequence: 2, previous: "c1",
        type: TimelineEventType.clientAttached, work: boundedWork,
        workHost: controlHost, client: ClientRef("client-b"),
        clientAttachment: ClientAttachmentRef("attachment-b"),
        payload: controlPayload(boundedWorkJournal, ["observe", "control"])))
    let boundedCursor = JournalCursor(
        journal: boundedWorkJournal, eventID: "a", sequence: 1)
    func acknowledgementPayload() -> JSONValue {
        .object([
            "work_journal": JSONValue.parse(try! JSONEncoder().encode(boundedWorkJournal))!,
            "target_journal": JSONValue.parse(try! JSONEncoder().encode(boundedWorkJournal))!,
            "cursor": JSONValue.parse(try! JSONEncoder().encode(boundedCursor))!,
        ])
    }
    controlData.append(try localCatalogEvent(
        id: "c3", journal: controlJournal, sequence: 3, previous: "c2",
        type: TimelineEventType.clientReadAcknowledged, work: boundedWork,
        workHost: controlHost, client: ClientRef("client-a"),
        clientAttachment: ClientAttachmentRef("attachment-a"),
        payload: acknowledgementPayload()))
    controlData.append(try localCatalogEvent(
        id: "c4", journal: controlJournal, sequence: 4, previous: "c3",
        type: TimelineEventType.clientReadAcknowledged, work: boundedWork,
        workHost: controlHost, client: ClientRef("client-b"),
        clientAttachment: ClientAttachmentRef("attachment-b"),
        payload: acknowledgementPayload()))
    try localCatalogWriteControl(
        controlData, journal: controlJournal,
        to: home.timelineV2WorkHostControlJournalURL(controlHost))

    let limits = LocalTimelineCatalog.Limits(
        maxWorkJournals: 2, maxDiagnostics: 4, maxWorkHostControlJournals: 1,
        maxClientAttachmentsPerControl: 1, maxReadAcknowledgementsPerControl: 1)
    let first = LocalTimelineCatalog.scan(home: home, limits: limits)
    let second = LocalTimelineCatalog.scan(home: home, limits: limits)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.works.count, 2)
    XCTAssertEqual(first.works.map(\.id), first.works.map(\.id).sorted())
    XCTAssertTrue(first.diagnostics.count <= 4)
    XCTAssertTrue(first.diagnostics.allSatisfy {
        $0.message.count <= LocalTimelineCatalog.Diagnostic.maxMessageCharacters
    })
    let control = try XCTUnwrap(first.workHostControls.first)
    XCTAssertTrue(control.isAvailable)
    XCTAssertEqual(control.clientAttachments.count, 1)
    XCTAssertEqual(control.omittedClientAttachmentCount, 1)
    XCTAssertEqual(control.readAcknowledgements.count, 1)
    XCTAssertEqual(control.omittedReadAcknowledgementCount, 1)
    let workRow = try XCTUnwrap(first.works.first { $0.work == boundedWork })
    XCTAssertEqual(workRow.clientAttachments.count, 1)
    XCTAssertEqual(workRow.omittedClientAttachmentCount, 1)
    XCTAssertEqual(Set(first.diagnostics.map(\.id)).count, first.diagnostics.count)
    XCTAssertFalse(first.works.contains { $0.corruptionReasons.contains(home.root.path) })
    XCTAssertFalse(first.diagnostics.contains { $0.message.contains(home.root.path) })
    XCTAssertFalse(first.canonicalNotificationSourceComplete,
                   "bounded discovery cannot advance notification delivery state")
}
