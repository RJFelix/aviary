import Foundation
@testable import AviaryCore

private let historyIndexSession = SessionRef("history-index-session")
private let historyIndexJournal = JournalRef.session(
    historyIndexSession, journalID: "history-index-journal",
    authority: TimelineAuthorityRef("history-index-authority"))
private let historyIndexActor = TimelineActor(actorID: "history-index-test", kind: "test")
private let historyIndexGeneration = String(repeating: "b", count: 64)

private struct HistoryIndexFixture {
    let events: [TimelineEvent]
    let rows: [DisposableTimelineProjectionStore.BucketRow]
    let source: PersistentSessionHistoryIndex.SourceProof
}

private enum HistoryIndexTestError: Error {
    case injectedBeforeHead
}

private func historyIndexDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "aviary-history-index-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return url
}

private func historyIndexEvent(
    _ type: String,
    id: String,
    sequence: Int,
    previous: String?,
    parent: EventRef? = nil,
    role: String = "assistant",
    text: String? = nil,
    domains: Set<TimelineDomain> = [.session]
) -> TimelineEvent {
    var payload: [String: JSONValue] = [:]
    if let text { payload["text"] = .string(text) }
    if type == TimelineEventType.messageCommitted { payload["role"] = .string(role) }
    return TimelineEvent(
        eventID: id, journal: historyIndexJournal, sequence: sequence,
        previousEventID: previous, conversationParent: parent,
        session: historyIndexSession, actor: historyIndexActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, declaredDomains: domains, payload: .object(payload))
}

private func historyIndexFixture(_ events: [TimelineEvent]) throws -> HistoryIndexFixture {
    var rows: [DisposableTimelineProjectionStore.BucketRow] = []
    var byteOffset = 0
    var rawPrefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(
        for: historyIndexJournal)
    var wirePrefix = PersistentSessionHistoryIndex.wirePrefixSeed(
        for: historyIndexJournal)
    for event in events {
        let line = try DisposableTimelineProjectionStore.canonicalJSON(event)
            + Data([UInt8(ascii: "\n")])
        let lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
        let rawAfter = DisposableTimelineProjectionStore.advancePrefixDigest(
            rawPrefix, lineDigest: lineDigest)
        let wireAfter = PersistentSessionHistoryIndex.advanceWirePrefix(
            wirePrefix, lineDigest: lineDigest)
        rows.append(.init(
            sequence: event.sequence, eventID: event.eventID,
            previousEventID: event.previousEventID,
            byteStart: byteOffset, byteEnd: byteOffset + line.count,
            prefixDigestBefore: rawPrefix, prefixDigestAfter: rawAfter,
            lineDigest: lineDigest))
        byteOffset += line.count
        rawPrefix = rawAfter
        wirePrefix = wireAfter
    }
    return HistoryIndexFixture(
        events: events, rows: rows,
        source: .init(
            session: historyIndexSession, journal: historyIndexJournal,
            sourceID: "history-index-source", sourceGeneration: historyIndexGeneration,
            sourceFingerprint: String(repeating: "d", count: 64),
            physicalCursor: JournalCursor(
                journal: historyIndexJournal, eventID: events.last?.eventID,
                sequence: events.count),
            prefixByteCount: byteOffset, prefixDigest: rawPrefix,
            wirePrefixDigest: wirePrefix))
}

private func historyIndexForkFixture(secret: String = "secret history body") throws
    -> HistoryIndexFixture
{
    let root = historyIndexEvent(
        TimelineEventType.inputAccepted, id: "message-root", sequence: 1,
        previous: nil, role: "user", text: secret)
    let child = historyIndexEvent(
        TimelineEventType.messageCommitted, id: "message-child", sequence: 2,
        previous: root.eventID,
        parent: EventRef(journal: historyIndexJournal, eventID: root.eventID),
        text: "unselected branch body")
    let sibling = historyIndexEvent(
        TimelineEventType.messageCommitted, id: "message-sibling", sequence: 3,
        previous: child.eventID,
        parent: EventRef(journal: historyIndexJournal, eventID: root.eventID),
        text: "selected response body")
    let select = historyIndexEvent(
        TimelineEventType.sessionTipSelected, id: "tip-selected", sequence: 4,
        previous: sibling.eventID,
        parent: EventRef(journal: historyIndexJournal, eventID: sibling.eventID))
    let unknown = historyIndexEvent(
        "future.session.instrumentation", id: "future-physical", sequence: 5,
        previous: select.eventID, domains: [.runtime])
    return try historyIndexFixture([root, child, sibling, select, unknown])
}

private func historyIndexBuild(
    _ index: PersistentSessionHistoryIndex,
    fixture: HistoryIndexFixture
) throws -> PersistentSessionHistoryIndex.Manifest {
    var builder = try index.makeBuilder(
        session: historyIndexSession, journal: historyIndexJournal,
        sourceGeneration: historyIndexGeneration)
    for (event, row) in zip(fixture.events, fixture.rows) {
        try builder.append(event: event, row: row)
    }
    return try builder.finalize(source: fixture.source)
}

private func historyIndexAllFileBytes(_ root: URL) throws -> Data {
    var bytes = Data()
    let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true { bytes.append(try Data(contentsOf: url)) }
    }
    return bytes
}

private func testPersistentSessionHistoryIndexSelectsExactBranchWithoutBodies() throws {
    let root = try historyIndexDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try historyIndexForkFixture()
    let index = try PersistentSessionHistoryIndex(
        directory: root, limits: .init(maximumChunkMessages: 2))
    let manifest = try historyIndexBuild(index, fixture: fixture)

    XCTAssertEqual(manifest.physicalEventCount, 5)
    XCTAssertEqual(manifest.indexedMessageCount, 3)
    XCTAssertEqual(manifest.selectedMessageCount, 2)
    XCTAssertEqual(manifest.semanticTip?.eventID, "message-sibling")
    XCTAssertEqual(manifest.anchors.map(\.cursor.sequence), [1])
    XCTAssertEqual(try index.loadManifest(proving: fixture.source), manifest)

    let latest = try index.loadPage(
        proving: fixture.source, semanticTip: manifest.semanticTip, limit: 1)
    XCTAssertEqual(latest.records.map(\.eventID), ["message-sibling"])
    XCTAssertTrue(latest.hasOlder)
    XCTAssertEqual(latest.nextBeforeCursor?.eventID, "message-sibling")
    XCTAssertEqual(latest.metrics.chunksRead, 1)
    XCTAssertTrue(latest.metrics.branchEntriesExamined <= 2)

    let older = try index.loadPage(
        proving: fixture.source, semanticTip: manifest.semanticTip,
        before: try XCTUnwrap(latest.nextBeforeCursor), limit: 1)
    XCTAssertEqual(older.records.map(\.eventID), ["message-root"])
    XCTAssertFalse(older.hasOlder)
    XCTAssertEqual(older.metrics.chunksRead, 1)

    let persisted = String(decoding: try historyIndexAllFileBytes(root), as: UTF8.self)
    XCTAssertFalse(persisted.contains("secret history body"))
    XCTAssertFalse(persisted.contains("unselected branch body"))
    XCTAssertFalse(persisted.contains("selected response body"))
    XCTAssertTrue(fixture.rows.allSatisfy {
        $0.lineDigest.utf8.count == 64 && !$0.lineDigest.hasPrefix("sha256:")
    })
}

private func testPersistentSessionHistoryIndexRejectsOffBranchAndSourceMismatch() throws {
    let root = try historyIndexDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try historyIndexForkFixture()
    let index = try PersistentSessionHistoryIndex(directory: root)
    let manifest = try historyIndexBuild(index, fixture: fixture)

    let offBranch = JournalCursor(
        journal: historyIndexJournal, eventID: "message-child", sequence: 2)
    do {
        _ = try index.loadPage(
            proving: fixture.source, semanticTip: manifest.semanticTip,
            before: offBranch, limit: 1)
        XCTFail("a physically real but unselected message must not be a branch boundary")
    } catch let error as PersistentSessionHistoryIndex.Error {
        XCTAssertEqual(error, .boundaryNotOnBranch)
    }

    let fabricated = JournalCursor(
        journal: historyIndexJournal, eventID: "fabricated", sequence: 3)
    do {
        _ = try index.loadPage(
            proving: fixture.source, semanticTip: manifest.semanticTip,
            before: fabricated, limit: 1)
        XCTFail("a fabricated boundary must fail closed")
    } catch let error as PersistentSessionHistoryIndex.Error {
        XCTAssertEqual(error, .boundaryNotOnBranch)
    }

    let wrongSource = PersistentSessionHistoryIndex.SourceProof(
        session: fixture.source.session, journal: fixture.source.journal,
        sourceID: fixture.source.sourceID,
        sourceGeneration: String(repeating: "c", count: 64),
        sourceFingerprint: fixture.source.sourceFingerprint,
        physicalCursor: fixture.source.physicalCursor,
        prefixByteCount: fixture.source.prefixByteCount,
        prefixDigest: fixture.source.prefixDigest,
        wirePrefixDigest: fixture.source.wirePrefixDigest)
    do {
        _ = try index.loadPage(
            proving: wrongSource, semanticTip: manifest.semanticTip, limit: 1)
        XCTFail("a different source generation must fail closed")
    } catch let error as PersistentSessionHistoryIndex.Error {
        XCTAssertEqual(error, .sourceMismatch)
    }
}

private func testPersistentSessionHistoryIndexRejectsUnsafeSessionSemantics() throws {
    let root = try historyIndexDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let valid = historyIndexEvent(
        TimelineEventType.inputAccepted, id: "semantic-root", sequence: 1,
        previous: nil, role: "user", text: "hello")
    let index = try PersistentSessionHistoryIndex(directory: root)
    for (suffix, domains) in [
        ("session", Set([TimelineDomain.session])),
        ("work", Set([TimelineDomain.work])),
    ] {
        let unknown = historyIndexEvent(
            "future.\(suffix).selection", id: "semantic-unknown-\(suffix)", sequence: 2,
            previous: valid.eventID, domains: domains)
        let fixture = try historyIndexFixture([valid, unknown])
        var builder = try index.makeBuilder(
            session: historyIndexSession, journal: historyIndexJournal,
            sourceGeneration: historyIndexGeneration)
        try builder.append(event: fixture.events[0], row: fixture.rows[0])
        do {
            try builder.append(event: fixture.events[1], row: fixture.rows[1])
            XCTFail("an unknown \(suffix)-domain event must make history authority unavailable")
        } catch let error as PersistentSessionHistoryIndex.Error {
            XCTAssertEqual(error, .invalidRecord)
        }
    }

    let malformed = historyIndexEvent(
        TimelineEventType.sessionAttention, id: "semantic-attention", sequence: 2,
        previous: valid.eventID)
    let malformedFixture = try historyIndexFixture([valid, malformed])
    var malformedBuilder = try index.makeBuilder(
        session: historyIndexSession, journal: historyIndexJournal,
        sourceGeneration: historyIndexGeneration)
    try malformedBuilder.append(
        event: malformedFixture.events[0], row: malformedFixture.rows[0])
    do {
        try malformedBuilder.append(
            event: malformedFixture.events[1], row: malformedFixture.rows[1])
        XCTFail("a canonically quarantined Session event must fail history closed")
    } catch let error as PersistentSessionHistoryIndex.Error {
        XCTAssertEqual(error, .invalidRecord)
    }
}

private func testPersistentSessionHistoryIndexRetainsRelationshipWithoutCapabilityText() throws {
    let root = try historyIndexDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = WorkRef(
        workHostID: historyIndexJournal.authority.authorityID,
        workID: "history-index-work")
    let attachment = SessionAttachmentRef("history-index-attachment")
    let secretClient = "credential-like-client-do-not-persist"
    let created = historyIndexEvent(
        TimelineEventType.sessionCreated, id: "relationship-created",
        sequence: 1, previous: nil)
    let secretCapability = "credential-like-capability-do-not-persist"
    let attached = TimelineEvent(
        eventID: "relationship-attached", journal: historyIndexJournal,
        sequence: 2, previousEventID: created.eventID,
        session: historyIndexSession, work: work,
        workHost: WorkHostRef(work.workHostID), client: ClientRef(secretClient),
        sessionAttachment: attachment,
        actor: historyIndexActor, hostRecordedAt: Date(timeIntervalSince1970: 2),
        type: TimelineEventType.sessionAttached, declaredDomains: [.session],
        payload: .object([
            "capabilities": .array([.string(secretCapability)])
        ]))
    let detached = TimelineEvent(
        eventID: "relationship-detached", journal: historyIndexJournal,
        sequence: 3, previousEventID: attached.eventID,
        session: historyIndexSession, work: work,
        workHost: WorkHostRef(work.workHostID), client: ClientRef(secretClient),
        sessionAttachment: attachment,
        actor: historyIndexActor, hostRecordedAt: Date(timeIntervalSince1970: 3),
        type: TimelineEventType.sessionDetached, declaredDomains: [.session, .work],
        payload: .object([:]))
    let fixture = try historyIndexFixture([created, attached, detached])
    let index = try PersistentSessionHistoryIndex(directory: root)
    let manifest = try historyIndexBuild(index, fixture: fixture)
    XCTAssertEqual(manifest.sessionAttachments.count, 1)
    XCTAssertEqual(manifest.sessionAttachments[0].attachment, attachment)
    XCTAssertEqual(manifest.sessionAttachments[0].work, work)
    XCTAssertFalse(manifest.sessionAttachments[0].isAttached)
    XCTAssertEqual(
        manifest.relationshipEvents.map(\.type),
        [TimelineEventType.sessionCreated, TimelineEventType.sessionAttached,
         TimelineEventType.sessionDetached])
    let persisted = String(
        decoding: try historyIndexAllFileBytes(root), as: UTF8.self)
    XCTAssertFalse(persisted.contains(secretCapability))
    XCTAssertFalse(persisted.contains(secretClient))
}

private func testPersistentSessionHistoryIndexSupportsLinearHistoryAndRejectsTampering() throws {
    let root = try historyIndexDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rootEvent = historyIndexEvent(
        TimelineEventType.inputAccepted, id: "only-message", sequence: 1,
        previous: nil, role: "user", text: "body")
    let linear = try historyIndexFixture([rootEvent])
    let index = try PersistentSessionHistoryIndex(directory: root)
    let linearManifest = try historyIndexBuild(index, fixture: linear)
    XCTAssertNil(linearManifest.semanticTip)
    XCTAssertEqual(linearManifest.selectedMessageCount, 1)
    XCTAssertEqual(try index.loadPage(
        proving: linear.source, semanticTip: nil, limit: 1).records.map(\.eventID),
        ["only-message"])

    let fixture = try historyIndexForkFixture()
    let manifest = try historyIndexBuild(index, fixture: fixture)
    let reference = try XCTUnwrap(manifest.chunks.first)
    let object = root.appending(path: "objects/\(reference.objectID)")
    try Data("tampered".utf8).write(to: object, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: object.path)
    do {
        _ = try index.loadPage(
            proving: fixture.source, semanticTip: manifest.semanticTip, limit: 1)
        XCTFail("tampered chunk bytes must fail closed")
    } catch let error as PersistentSessionHistoryIndex.Error {
        XCTAssertEqual(error, .checksumMismatch)
    }

    // A disposable cache repair must remove the damaged content-addressed object as well as its
    // moving pointers; otherwise an identical rebuild would collide with the corrupt bytes.
    try index.quarantineCache()
    let rebuilt = try historyIndexBuild(index, fixture: fixture)
    XCTAssertEqual(
        try index.loadPage(
            proving: fixture.source, semanticTip: rebuilt.semanticTip, limit: 1).records.map(\.eventID),
        ["message-sibling"])
}

private func testPersistentSessionHistoryIndexPublishesHeadLastAndRejectsSymlink() throws {
    let root = try historyIndexDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try historyIndexForkFixture(secret: "original body")
    let stable = try PersistentSessionHistoryIndex(directory: root)
    let originalManifest = try historyIndexBuild(stable, fixture: original)

    let failing = try PersistentSessionHistoryIndex(
        directory: root,
        beforeHeadPublication: { throw HistoryIndexTestError.injectedBeforeHead })
    let replacement = try historyIndexForkFixture(secret: "replacement body")
    do {
        _ = try historyIndexBuild(failing, fixture: replacement)
        XCTFail("injected publication failure must escape")
    } catch HistoryIndexTestError.injectedBeforeHead {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(try stable.loadManifest(proving: original.source), originalManifest)
    let boundaryEntries = try FileManager.default.contentsOfDirectory(
        atPath: root.appending(path: "boundaries", directoryHint: .isDirectory).path)
    XCTAssertTrue(boundaryEntries.allSatisfy { !$0.hasPrefix(".boundary-") })

    let target = root.appending(path: "symlink-target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = root.appending(path: "symlink", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    do {
        _ = try PersistentSessionHistoryIndex(directory: link)
        XCTFail("a symlinked projection root must fail closed")
    } catch let error as PersistentSessionHistoryIndex.Error {
        XCTAssertEqual(error, .symlinkOrNonRegularFile)
    }
}

private func testPersistentSessionHistoryIndexKeepsFrozenContinuationAfterAppend() throws {
    let root = try historyIndexDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = historyIndexEvent(
        TimelineEventType.inputAccepted, id: "frozen-root", sequence: 1,
        previous: nil, role: "user", text: "first prompt")
    let second = historyIndexEvent(
        TimelineEventType.messageCommitted, id: "frozen-response", sequence: 2,
        previous: first.eventID,
        parent: EventRef(journal: historyIndexJournal, eventID: first.eventID),
        text: "first response")
    let original = try historyIndexFixture([first, second])
    let publisher = try PersistentSessionHistoryIndex(
        directory: root, limits: .init(maximumChunkMessages: 2))
    let originalManifest = try historyIndexBuild(publisher, fixture: original)
    let firstPage = try publisher.loadPage(
        proving: original.source, semanticTip: originalManifest.semanticTip, limit: 1)
    let frozenBoundary = try XCTUnwrap(firstPage.nextBeforeCursor)

    let third = historyIndexEvent(
        TimelineEventType.messageCommitted, id: "later-response", sequence: 3,
        previous: second.eventID,
        parent: EventRef(journal: historyIndexJournal, eventID: second.eventID),
        text: "later response")
    let selectLater = historyIndexEvent(
        TimelineEventType.sessionTipSelected, id: "later-tip", sequence: 4,
        previous: third.eventID,
        parent: EventRef(journal: historyIndexJournal, eventID: third.eventID))
    let later = try historyIndexFixture([first, second, third, selectLater])
    let laterManifest = try historyIndexBuild(publisher, fixture: later)
    XCTAssertNotEqual(laterManifest.source.physicalCursor, original.source.physicalCursor)
    XCTAssertNotEqual(laterManifest.manifestDigest, originalManifest.manifestDigest)

    // A fresh process instance must use the boundary pointer derived from X, not Y's moving HEAD.
    let restarted = try PersistentSessionHistoryIndex(
        directory: root, limits: .init(maximumChunkMessages: 2))
    XCTAssertEqual(try restarted.loadManifest(), laterManifest)
    XCTAssertEqual(try restarted.loadManifest(provingFrozen: original.source), originalManifest)
    let older = try restarted.loadPage(
        proving: original.source, semanticTip: originalManifest.semanticTip,
        before: frozenBoundary, limit: 1)
    XCTAssertEqual(older.records.map(\.eventID), ["frozen-root"])
    XCTAssertFalse(older.hasOlder)
    XCTAssertTrue(older.metrics.headBytesRead > 0)
    XCTAssertTrue(older.metrics.manifestBytesRead > 0)
    XCTAssertTrue(older.metrics.boundaryRecordsExamined > 0)
}

let casesPersistentSessionHistoryIndex: [(String, () async throws -> Void)] = [
    ("phase4 persistent Session history selects exact branch without bodies",
     { try testPersistentSessionHistoryIndexSelectsExactBranchWithoutBodies() }),
    ("phase4 persistent Session history rejects off-branch and mismatched source",
     { try testPersistentSessionHistoryIndexRejectsOffBranchAndSourceMismatch() }),
    ("phase4 persistent Session history rejects unsafe Session semantics",
     { try testPersistentSessionHistoryIndexRejectsUnsafeSessionSemantics() }),
    ("phase4 persistent Session history keeps relationship evidence body-free",
     { try testPersistentSessionHistoryIndexRetainsRelationshipWithoutCapabilityText() }),
    ("phase4 persistent Session history supports linear history and rejects tampering",
     { try testPersistentSessionHistoryIndexSupportsLinearHistoryAndRejectsTampering() }),
    ("phase4 persistent Session history publishes HEAD last and rejects symlink",
     { try testPersistentSessionHistoryIndexPublishesHeadLastAndRejectsSymlink() }),
    ("phase4 persistent Session history keeps frozen continuation after append",
     { try testPersistentSessionHistoryIndexKeepsFrozenContinuationAfterAppend() }),
]
