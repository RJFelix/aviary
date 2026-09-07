import Foundation
@testable import AviaryCore

private let localHistorySession = SessionRef("local-history-session")
private let localHistoryJournal = JournalRef.session(
    localHistorySession, journalID: "local-history-journal",
    authority: TimelineAuthorityRef("local-history-host"))
private let localHistoryActor = TimelineActor(actorID: "local-history-test", kind: "self-test")

private func localHistoryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-local-history-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return root
}

private func localHistoryEvent(
    type: String, id: String, sequence: Int, previous: String?,
    parent: EventRef? = nil, text: String? = nil, role: String = "assistant",
    domains: Set<TimelineDomain> = [.session]
) -> TimelineEvent {
    var payload: [String: JSONValue] = [:]
    if let text { payload["text"] = .string(text) }
    if type == TimelineEventType.messageCommitted { payload["role"] = .string(role) }
    return TimelineEvent(
        eventID: id, journal: localHistoryJournal, sequence: sequence,
        previousEventID: previous, conversationParent: parent,
        session: localHistorySession, actor: localHistoryActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, declaredDomains: domains, payload: .object(payload))
}

private func localHistoryWrite(_ events: [TimelineEvent], to file: URL) throws -> Int {
    var bytes = Data()
    for event in events {
        bytes.append(try DisposableTimelineProjectionStore.canonicalJSON(event))
        bytes.append(0x0A)
    }
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    try bytes.write(to: file, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
    return bytes.count
}

private func localHistoryPersistedIndexBytes(_ root: URL) throws -> Data {
    let indexRoot = root.appending(path: "history-index", directoryHint: .isDirectory)
    var bytes = Data()
    let enumerator = FileManager.default.enumerator(
        at: indexRoot, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true { bytes.append(try Data(contentsOf: url)) }
    }
    return bytes
}

private struct LocalHistoryFixture {
    let root: URL
    let home: AgentHome
    let file: URL
    let indexDirectory: URL
    let events: [TimelineEvent]
    let byteCount: Int
    let reader: LocalSessionHistoryProjectionReader

    init(events: [TimelineEvent], limits: LocalSessionHistoryProjectionReader.Limits = .standard) throws {
        root = try localHistoryRoot()
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        file = home.timelineV2SessionJournalURL(localHistorySession)
        byteCount = try localHistoryWrite(events, to: file)
        self.events = events
        let indexDirectory = root.appending(path: "history-index", directoryHint: .isDirectory)
        self.indexDirectory = indexDirectory
        reader = try LocalSessionHistoryProjectionReader(
            home: home, session: localHistorySession, journal: localHistoryJournal,
            indexDirectory: indexDirectory, limits: limits)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func localHistoryCacheFile(_ fixture: LocalHistoryFixture, _ name: String) -> URL {
    fixture.indexDirectory.appending(path: name, directoryHint: .notDirectory)
}

private func localHistoryOverwriteCache(_ url: URL, with data: Data) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
}

private func localHistoryRewriteInPlace(_ url: URL, with data: Data) throws {
    let handle = try FileHandle(forUpdating: url)
    try handle.truncate(atOffset: 0)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: data)
    try handle.close()
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
}

private func localHistoryBranchEvents() -> [TimelineEvent] {
    let root = localHistoryEvent(
        type: TimelineEventType.inputAccepted, id: "message-root", sequence: 1,
        previous: nil, text: "user prompt")
    let reply = localHistoryEvent(
        type: TimelineEventType.messageCommitted, id: "message-reply", sequence: 2,
        previous: root.eventID,
        parent: EventRef(journal: localHistoryJournal, eventID: root.eventID),
        text: "assistant response")
    let tip = localHistoryEvent(
        type: TimelineEventType.sessionTipSelected, id: "tip", sequence: 3,
        previous: reply.eventID,
        parent: EventRef(journal: localHistoryJournal, eventID: reply.eventID))
    return [root, reply, tip]
}

func testLocalSessionHistoryReaderColdCacheAndBoundedPage() throws {
    let fixture = try LocalHistoryFixture(
        events: localHistoryBranchEvents(),
        limits: .init(maximumChunkBytes: 64 * 1_024, maximumLineBytes: 64 * 1_024,
                      maximumPhysicalEvents: 64, maximumPageRecords: 8))
    defer { fixture.remove() }
    let first = try fixture.reader.read(limit: 1)
    XCTAssertEqual(first.events.map(\.eventID), ["message-reply"])
    XCTAssertTrue(first.hasOlder)
    XCTAssertEqual(first.nextBeforeCursor?.eventID, "message-reply")
    XCTAssertTrue(first.didBuildIndex)
    XCTAssertEqual(first.metrics.historyIndexBuilds, 1)
    XCTAssertEqual(first.metrics.decodedPhysicalEvents, 3)
    XCTAssertEqual(first.metrics.sourceBytesScanned, fixture.byteCount)
    let persistedIndex = String(
        decoding: try localHistoryPersistedIndexBytes(fixture.root), as: UTF8.self)
    XCTAssertFalse(persistedIndex.contains("user prompt"))
    XCTAssertFalse(persistedIndex.contains("assistant response"))
    XCTAssertTrue(first.metrics.historyCanonicalRangeBytes <= first.events.reduce(0) {
        $0 + (try! DisposableTimelineProjectionStore.canonicalJSON($1)).count + 1
    })

    let older = try fixture.reader.read(
        before: try XCTUnwrap(first.nextBeforeCursor), limit: 1)
    XCTAssertEqual(older.events.map(\.eventID), ["message-root"])
    XCTAssertFalse(older.hasOlder)
    XCTAssertEqual(older.metrics.historyCacheHits, 1)
    XCTAssertEqual(older.metrics.decodedPhysicalEvents, 0)
    XCTAssertTrue(older.metrics.metadataLookups <= 2)

    let cached = try fixture.reader.read(limit: 1)
    XCTAssertFalse(cached.didBuildIndex)
    XCTAssertEqual(cached.metrics.historyCacheHits, 1)
    XCTAssertEqual(cached.events.first?.payload["text"]?.stringValue, "assistant response")
}

func testLocalSessionHistoryReaderRejectsFabricatedAndTamperedRanges() throws {
    let fixture = try LocalHistoryFixture(events: localHistoryBranchEvents())
    defer { fixture.remove() }
    let first = try fixture.reader.read(limit: 1)
    let fabricated = JournalCursor(
        journal: localHistoryJournal, eventID: "not-on-branch", sequence: 2)
    do {
        _ = try fixture.reader.read(before: fabricated, limit: 1)
        XCTFail("fabricated history boundary must fail closed")
    } catch LocalSessionHistoryProjectionReader.ReaderError.sourceIncomplete {
        XCTAssertTrue(true)
    }

    let original = try Data(contentsOf: fixture.file)
    guard let response = String(data: original, encoding: .utf8)?.range(of: "assistant response")
    else { throw LocalSessionHistoryProjectionReader.ReaderError.canonicalMismatch }
    var replacement = String(data: original, encoding: .utf8)!
    // Keep the line length unchanged so the persisted source fence, not only a size check, is
    // responsible for rejecting a same-sized in-place rewrite.
    replacement.replaceSubrange(response, with: "new assistant text")
    try Data(replacement.utf8).write(to: fixture.file, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fixture.file.path)
    do {
        _ = try fixture.reader.read(limit: 1)
        XCTFail("tampered canonical message must fail closed")
    } catch LocalSessionHistoryProjectionReader.ReaderError.canonicalMismatch,
            LocalSessionHistoryProjectionReader.ReaderError.sourceChanged {
        XCTAssertTrue(true)
    }
    _ = first
}

func testLocalSessionHistoryReaderRepairsCorruptDisposableCache() throws {
    let fixture = try LocalHistoryFixture(events: localHistoryBranchEvents())
    defer { fixture.remove() }
    let originalJournal = try Data(contentsOf: fixture.file)
    let first = try fixture.reader.read(limit: 1)
    XCTAssertEqual(first.events.map(\.eventID), ["message-reply"])

    // A canonical rewrite with the same shape must never be accepted as a cache repair. The
    // source lease remains authoritative even while the cache is otherwise healthy.
    var forgedJournal = originalJournal
    guard let needle = forgedJournal.range(of: Data("assistant response".utf8)) else {
        throw LocalSessionHistoryProjectionReader.ReaderError.canonicalMismatch
    }
    forgedJournal.replaceSubrange(needle, with: Data("forged response!!!".utf8))
    XCTAssertEqual(forgedJournal.count, originalJournal.count)
    try localHistoryRewriteInPlace(fixture.file, with: forgedJournal)
    do {
        _ = try LocalSessionHistoryProjectionReader(
            home: fixture.home, session: localHistorySession, journal: localHistoryJournal,
            indexDirectory: fixture.indexDirectory).read(limit: 1)
        XCTFail("a forged canonical source must not be repaired from disposable cache")
    } catch LocalSessionHistoryProjectionReader.ReaderError.sourceChanged,
            LocalSessionHistoryProjectionReader.ReaderError.canonicalMismatch {
        XCTAssertTrue(true)
    }
    try localHistoryRewriteInPlace(fixture.file, with: originalJournal)

    // HEAD is only a moving cache pointer. A malformed pointer is repairable while the canonical
    // journal remains intact, and the repaired publication must be usable by a fresh reader.
    try localHistoryOverwriteCache(localHistoryCacheFile(fixture, "HEAD"), with: Data("{".utf8))
    let repairedHead = try LocalSessionHistoryProjectionReader(
        home: fixture.home, session: localHistorySession, journal: localHistoryJournal,
        indexDirectory: fixture.indexDirectory).read(limit: 1)
    XCTAssertEqual(repairedHead.events.map(\.eventID), ["message-reply"])
    XCTAssertTrue(repairedHead.didBuildIndex)

    // Corrupt the manifest object itself, then a selected chunk. Both are disposable graph
    // objects; quarantine removes the entire graph before rebuilding so identical object IDs do
    // not collide with the damaged bytes.
    let index = try PersistentSessionHistoryIndex(directory: fixture.indexDirectory)
    var manifest = try index.loadManifest()
    let manifestObject = localHistoryCacheFile(fixture, "objects/\(manifest.manifestDigest)")
    try localHistoryOverwriteCache(manifestObject, with: Data("truncated-manifest".utf8))
    let repairedManifest = try LocalSessionHistoryProjectionReader(
        home: fixture.home, session: localHistorySession, journal: localHistoryJournal,
        indexDirectory: fixture.indexDirectory).read(limit: 1)
    XCTAssertEqual(repairedManifest.events.map(\.eventID), ["message-reply"])
    XCTAssertTrue(repairedManifest.didBuildIndex)

    manifest = try index.loadManifest()
    let chunk = try XCTUnwrap(manifest.chunks.first)
    let chunkObject = localHistoryCacheFile(fixture, "objects/\(chunk.objectID)")
    try localHistoryOverwriteCache(chunkObject, with: Data("corrupt-chunk".utf8))
    let repairedChunk = try LocalSessionHistoryProjectionReader(
        home: fixture.home, session: localHistorySession, journal: localHistoryJournal,
        indexDirectory: fixture.indexDirectory).read(limit: 1)
    XCTAssertEqual(repairedChunk.events.map(\.eventID), ["message-reply"])
    XCTAssertTrue(repairedChunk.didBuildIndex)
}

func testLocalSessionHistoryReaderRejectsReplacementAndScalesWithoutEventArray() throws {
    var events: [TimelineEvent] = []
    events.reserveCapacity(96)
    var previous: String?
    var lastMessageID: String?
    for sequence in 1...96 {
        let event: TimelineEvent
        if sequence.isMultiple(of: 3) {
            let parentID = lastMessageID
            event = localHistoryEvent(
                type: TimelineEventType.messageCommitted, id: "scale-\(sequence)",
                sequence: sequence, previous: previous,
                parent: parentID.map { EventRef(journal: localHistoryJournal, eventID: $0) },
                text: "message-\(sequence)")
        } else {
            event = localHistoryEvent(
                type: "session.progress", id: "scale-\(sequence)", sequence: sequence,
                previous: previous, domains: [.runtime])
        }
        events.append(event)
        previous = event.eventID
        if sequence.isMultiple(of: 3) { lastMessageID = event.eventID }
    }
    let tip = localHistoryEvent(
        type: TimelineEventType.sessionTipSelected, id: "scale-tip", sequence: 97,
        previous: previous,
        parent: EventRef(journal: localHistoryJournal, eventID: "scale-96"))
    events.append(tip)
    let fixture = try LocalHistoryFixture(
        events: events,
        limits: .init(maximumChunkBytes: 64 * 1_024, maximumLineBytes: 64 * 1_024,
                      maximumPhysicalEvents: 128, maximumPageRecords: 16))
    defer { fixture.remove() }
    let result = try fixture.reader.read(limit: 8)
    XCTAssertEqual(result.events.count, 8)
    XCTAssertEqual(result.metrics.decodedPhysicalEvents, 97)
    XCTAssertEqual(result.metrics.historyCanonicalRangeReads, 8)
    XCTAssertTrue(result.metrics.metadataLookups <= 9)
    XCTAssertTrue(result.metrics.parentLinks <= 9)
    XCTAssertTrue(result.metrics.peakBufferBytes <= 64 * 1_024 + 1_024 * 1_024)

    let replacement = fixture.root.appending(path: "replacement.jsonl")
    try Data(contentsOf: fixture.file).write(to: replacement, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: replacement.path)
    try FileManager.default.removeItem(at: fixture.file)
    try FileManager.default.moveItem(at: replacement, to: fixture.file)
    do {
        _ = try fixture.reader.read(limit: 1)
        XCTFail("replacement generation must fail closed")
    } catch LocalSessionHistoryProjectionReader.ReaderError.sourceChanged {
        XCTAssertTrue(true)
    }
}

func testLocalSessionHistoryReaderKeepsFrozenBranchAcrossAppendAndHonorsByteBound() throws {
    let rootMessage = localHistoryEvent(
        type: TimelineEventType.inputAccepted, id: "append-root", sequence: 1,
        previous: nil, text: "small prompt")
    let padding = localHistoryEvent(
        type: "session.padding", id: "padding-a", sequence: 2,
        previous: rootMessage.eventID, domains: [.runtime])
    let reply = localHistoryEvent(
        type: TimelineEventType.messageCommitted, id: "append-reply", sequence: 3,
        previous: padding.eventID,
        parent: EventRef(journal: localHistoryJournal, eventID: rootMessage.eventID),
        text: "small response")
    let tip = localHistoryEvent(
        type: TimelineEventType.sessionTipSelected, id: "append-tip", sequence: 4,
        previous: reply.eventID,
        parent: EventRef(journal: localHistoryJournal, eventID: reply.eventID))
    let fixture = try LocalHistoryFixture(events: [rootMessage, padding, reply, tip])
    defer { fixture.remove() }
    let first = try fixture.reader.read(limit: 1)
    XCTAssertEqual(first.events.map(\.eventID), [reply.eventID])
    XCTAssertEqual(first.semanticTip?.eventID, reply.eventID)
    let before = try XCTUnwrap(first.nextBeforeCursor)

    let later = localHistoryEvent(
        type: TimelineEventType.messageCommitted, id: "append-later", sequence: 5,
        previous: tip.eventID,
        parent: EventRef(journal: localHistoryJournal, eventID: reply.eventID),
        text: "newer response")
    let laterTip = localHistoryEvent(
        type: TimelineEventType.sessionTipSelected, id: "append-later-tip", sequence: 6,
        previous: later.eventID,
        parent: EventRef(journal: localHistoryJournal, eventID: later.eventID))
    let appendHandle = try FileHandle(forWritingTo: fixture.file)
    try appendHandle.seekToEnd()
    for event in [later, laterTip] {
        try appendHandle.write(contentsOf:
            try DisposableTimelineProjectionStore.canonicalJSON(event) + Data([0x0A]))
    }
    try appendHandle.close()

    // A caller cannot use a random frozen cursor/digest as permission to quarantine this
    // Session's shared cache. The valid older boundary and the moving HEAD must remain usable.
    let forgedFrozenTip = JournalCursor(
        journal: localHistoryJournal, eventID: "not-a-real-frozen-tip", sequence: 9_999)
    do {
        _ = try fixture.reader.read(
            frozenTip: forgedFrozenTip,
            frozenTipDigest: String(repeating: "f", count: 64),
            branchTip: first.semanticTip, limit: 1)
        XCTFail("a random frozen boundary must fail closed")
    } catch LocalSessionHistoryProjectionReader.ReaderError.sourceIncomplete {
        XCTAssertTrue(true)
    }

    let continued = try fixture.reader.read(
        before: before, frozenTip: first.source.physicalCursor,
        frozenTipDigest: first.source.wirePrefixDigest,
        branchTip: first.semanticTip, limit: 1)
    XCTAssertEqual(continued.events.map(\.eventID), [rootMessage.eventID])
    XCTAssertFalse(continued.hasOlder)
    XCTAssertEqual(continued.source, first.source)
    XCTAssertEqual(
        continued.metrics.decodedPhysicalEvents, 6,
        "the first continuation after growth must authenticate current relationship semantics")
    XCTAssertTrue(continued.metrics.sourceBytesScanned >= first.source.prefixByteCount)

    let latest = try fixture.reader.read(limit: 1)
    XCTAssertEqual(latest.events.map(\.eventID), [later.eventID])
    XCTAssertEqual(latest.source.physicalCursor.sequence, 6)
    XCTAssertEqual(latest.metrics.decodedPhysicalEvents, 0)
    XCTAssertEqual(latest.metrics.historyCacheHits, 1)

    let replyBytes = try DisposableTimelineProjectionStore.canonicalJSON(reply).count
    let byteBounded = try fixture.reader.read(
        frozenTip: first.source.physicalCursor,
        frozenTipDigest: first.source.wirePrefixDigest,
        branchTip: first.semanticTip, limit: 2, maxBytes: replyBytes)
    XCTAssertEqual(byteBounded.events.map(\.eventID), [reply.eventID])
    XCTAssertTrue(byteBounded.hasOlder)
    XCTAssertEqual(byteBounded.nextBeforeCursor?.eventID, reply.eventID)
    do {
        _ = try fixture.reader.read(
            frozenTip: first.source.physicalCursor,
            frozenTipDigest: first.source.wirePrefixDigest,
            branchTip: first.semanticTip, limit: 1, maxBytes: replyBytes - 1)
        XCTFail("an oversized next history row must report no progress")
    } catch let LocalSessionHistoryProjectionReader.ReaderError.pageCannotProgress(
        requiredBytes, maximumBytes
    ) {
        XCTAssertEqual(requiredBytes, replyBytes)
        XCTAssertEqual(maximumBytes, replyBytes - 1)
    }

    // Mutate a non-message physical event inside the old frozen prefix without replacing the
    // inode. The sparse-prefix proof must reject the old continuation rather than trusting the
    // content-addressed index by itself.
    let bytes = try Data(contentsOf: fixture.file)
    let needle = Data("padding-a".utf8)
    let replacement = Data("padding-b".utf8)
    let position = try XCTUnwrap(bytes.range(of: needle)?.lowerBound)
    let update = try FileHandle(forUpdating: fixture.file)
    try update.seek(toOffset: UInt64(position))
    try update.write(contentsOf: replacement)
    try update.close()
    do {
        _ = try fixture.reader.read(
            before: before, frozenTip: first.source.physicalCursor,
            frozenTipDigest: first.source.wirePrefixDigest,
            branchTip: first.semanticTip, limit: 1)
        XCTFail("a mutated event inside the frozen anchor interval must fail closed")
    } catch LocalSessionHistoryProjectionReader.ReaderError.canonicalMismatch,
            LocalSessionHistoryProjectionReader.ReaderError.sourceChanged,
            LocalSessionHistoryProjectionReader.ReaderError.sourceIncomplete,
            LocalSessionHistoryProjectionReader.ReaderError.malformedLine {
        XCTAssertTrue(true)
    }
}

func testLocalSessionHistoryReaderPagesOneHundredThousandEventsWithoutLifetimeEventBodies() throws {
    let root = try localHistoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    let file = home.timelineV2SessionJournalURL(localHistorySession)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    XCTAssertTrue(FileManager.default.createFile(
        atPath: file.path, contents: nil,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]))
    let handle = try FileHandle(forWritingTo: file)
    var buffered = Data()
    var previousEventID: String?
    let writeBufferLimit = 1 * 1_024 * 1_024
    for sequence in 1...100_000 {
        let eventID = "scale-100k-\(sequence)"
        let event: TimelineEvent
        if sequence.isMultiple(of: 10) {
            let priorMessageID = sequence == 10 ? nil : "scale-100k-\(sequence - 10)"
            event = localHistoryEvent(
                type: TimelineEventType.messageCommitted, id: eventID,
                sequence: sequence, previous: previousEventID,
                parent: priorMessageID.map {
                    EventRef(journal: localHistoryJournal, eventID: $0)
                },
                text: "scale-message-\(sequence)")
        } else {
            event = localHistoryEvent(
                type: "session.scale.instrumentation", id: eventID,
                sequence: sequence, previous: previousEventID, domains: [.runtime])
        }
        buffered.append(try DisposableTimelineProjectionStore.canonicalJSON(event))
        buffered.append(0x0A)
        if buffered.count >= writeBufferLimit {
            try handle.write(contentsOf: buffered)
            buffered.removeAll(keepingCapacity: true)
        }
        previousEventID = eventID
    }
    if !buffered.isEmpty { try handle.write(contentsOf: buffered) }
    try handle.close()

    let indexDirectory = root.appending(path: "history-index", directoryHint: .isDirectory)
    let limits = LocalSessionHistoryProjectionReader.Limits(
        maximumChunkBytes: 64 * 1_024, maximumLineBytes: 64 * 1_024,
        maximumPhysicalEvents: 100_000, maximumPageRecords: 64)
    let reader = try LocalSessionHistoryProjectionReader(
        home: home, session: localHistorySession, journal: localHistoryJournal,
        indexDirectory: indexDirectory, limits: limits)
    let first = try reader.read(limit: 32)
    XCTAssertEqual(first.events.count, 32)
    XCTAssertEqual(first.metrics.decodedPhysicalEvents, 100_000)
    XCTAssertEqual(first.source.physicalCursor.sequence, 100_000)
    XCTAssertEqual(first.metrics.historyCanonicalRangeReads, 32)
    XCTAssertTrue(first.metrics.metadataLookups <= 33)
    XCTAssertTrue(first.metrics.parentLinks <= 33)
    XCTAssertTrue(first.metrics.peakBufferBytes <= 128 * 1_024)
    XCTAssertEqual(first.events.last?.eventID, "scale-100k-100000")
    let firstCanonicalBytes = try first.events.reduce(into: 0) { total, event in
        total += try DisposableTimelineProjectionStore.canonicalJSON(event).count + 1
    }
    XCTAssertTrue(first.metrics.historyCanonicalRangeBytes <= firstCanonicalBytes)

    // A new reader instance simulates another GUI or a restarted Work-service process. It must
    // use only the immutable metadata objects and selected canonical line ranges for page two.
    let reopened = try LocalSessionHistoryProjectionReader(
        home: home, session: localHistorySession, journal: localHistoryJournal,
        indexDirectory: indexDirectory, limits: limits)
    let second = try reopened.read(before: try XCTUnwrap(first.nextBeforeCursor), limit: 32)
    XCTAssertEqual(second.events.count, 32)
    XCTAssertEqual(second.metrics.decodedPhysicalEvents, 0)
    XCTAssertEqual(second.metrics.sourceBytesScanned, 0)
    XCTAssertEqual(second.metrics.historyCacheHits, 1)
    XCTAssertEqual(second.metrics.historyCanonicalRangeReads, 32)
    XCTAssertTrue(second.metrics.metadataLookups <= 33)
    XCTAssertTrue(second.metrics.parentLinks <= 33)
    XCTAssertTrue(second.metrics.historyMapObjects <= 4)
    let secondCanonicalBytes = try second.events.reduce(into: 0) { total, event in
        total += try DisposableTimelineProjectionStore.canonicalJSON(event).count + 1
    }
    XCTAssertTrue(second.metrics.historyCanonicalRangeBytes <= secondCanonicalBytes)

    let persisted = String(
        decoding: try localHistoryPersistedIndexBytes(root), as: UTF8.self)
    XCTAssertFalse(persisted.contains("scale-message-"))
}

let casesLocalSessionHistoryProjectionReader: [(String, () async throws -> Void)] = [
    ("phase4 local Session history reader cold cache and bounded page",
     { try testLocalSessionHistoryReaderColdCacheAndBoundedPage() }),
    ("phase4 local Session history reader repairs corrupt disposable cache",
     { try testLocalSessionHistoryReaderRepairsCorruptDisposableCache() }),
    ("phase4 local Session history reader rejects fabricated and tampered ranges",
     { try testLocalSessionHistoryReaderRejectsFabricatedAndTamperedRanges() }),
    ("phase4 local Session history reader rejects replacement and scales",
     { try testLocalSessionHistoryReaderRejectsReplacementAndScalesWithoutEventArray() }),
    ("phase4 local Session history reader keeps frozen branch across append",
     { try testLocalSessionHistoryReaderKeepsFrozenBranchAcrossAppendAndHonorsByteBound() }),
    ("phase4 local Session history reader pages 100k events without lifetime event bodies",
     { try testLocalSessionHistoryReaderPagesOneHundredThousandEventsWithoutLifetimeEventBodies() }),
]
