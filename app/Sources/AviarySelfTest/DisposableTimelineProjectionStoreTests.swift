import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private let projectionStoreWork = WorkRef(workHostID: "projection-test-host", workID: "projection-test-work")
private let projectionStoreJournal = JournalRef.work(projectionStoreWork, journalID: "projection-test-journal")
private let projectionStoreActor = TimelineActor(actorID: "projection-test-actor", kind: "work-host")

private func projectionDigest(_ value: Int) -> String {
    String(format: "%064x", value)
}

private func projectionStoreRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-projection-store-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard chmod(root.path, mode_t(0o700)) == 0 else {
        throw DisposableTimelineProjectionStore.StoreError.invalidCommit(.insecurePermissions)
    }
    return root
}

private func projectionStoreSource(
    sourceID: String = "source-one",
    lastSequence: Int,
    byteCount: Int? = nil,
    journal: JournalRef = projectionStoreJournal
) -> DisposableTimelineProjectionStore.SourceFingerprint {
    let bytes = byteCount ?? max(0, lastSequence * 10)
    let rows = projectionStoreRows(start: 1, count: lastSequence, journal: journal)
    return DisposableTimelineProjectionStore.SourceFingerprint(
        journal: journal, sourceID: sourceID,
        sourceGeneration: projectionDigest(42),
        fingerprint: projectionDigest(bytes + 100),
        sourceByteCount: bytes, prefixByteCount: bytes,
        prefixDigest: rows.last?.prefixDigestAfter
            ?? DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal))
}

private func projectionStoreRows(
    start: Int, count: Int, byteWidth: Int = 10,
    journal: JournalRef = projectionStoreJournal
)
    -> [DisposableTimelineProjectionStore.BucketRow] {
    guard count > 0 else { return [] }
    var prefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(
        for: journal)
    if start > 1 {
        for sequence in 1..<start {
            prefix = DisposableTimelineProjectionStore.advancePrefixDigest(
                prefix, lineDigest: projectionDigest(sequence + 10_000))
        }
    }
    return (start..<(start + count)).map { sequence in
        let previous = sequence == 1 ? nil : "event-\(sequence - 1)"
        let lineDigest = projectionDigest(sequence + 10_000)
        let after = DisposableTimelineProjectionStore.advancePrefixDigest(
            prefix, lineDigest: lineDigest)
        let row = DisposableTimelineProjectionStore.BucketRow(
            sequence: sequence,
            eventID: "event-\(sequence)",
            previousEventID: previous,
            byteStart: (sequence - 1) * byteWidth,
            byteEnd: sequence * byteWidth,
            prefixDigestBefore: prefix,
            prefixDigestAfter: after,
            lineDigest: lineDigest)
        prefix = after
        return row
    }
}

private func projectionStoreCommit(
    rows: [DisposableTimelineProjectionStore.BucketRow],
    sealedBuckets: [DisposableTimelineProjectionStore.Bucket] = [],
    currentBucket: DisposableTimelineProjectionStore.Bucket? = nil,
    sourceID: String = "source-one",
    sourceByteCount: Int? = nil,
    fingerprintValue: Int? = nil,
    prefixSeed: DisposableTimelineProjectionStore.PrefixSeed? = nil,
    expectedGeneration: Int? = nil,
    anchors: [DisposableTimelineProjectionStore.AnchorRecord] = [],
    recentPages: [DisposableTimelineProjectionStore.RecentEventPage] = [],
    reducerHead: DisposableTimelineProjectionStore.OpaqueReducerHead? = nil,
    exactStateRoots: [DisposableTimelineProjectionStore.ExactStateRootDescriptor] = [],
    pendingAcknowledgements: [DisposableTimelineProjectionStore.PendingAcknowledgement] = [],
    journal: JournalRef = projectionStoreJournal
) -> DisposableTimelineProjectionStore.Commit {
    let lastSequence = rows.last?.sequence
        ?? sealedBuckets.last?.rows.last?.sequence
        ?? 0
    let bytes = sourceByteCount ?? max(0, lastSequence * 10)
    let terminalRow = currentBucket?.rows.last ?? sealedBuckets.last?.rows.last ?? rows.last
    let source = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: journal, sourceID: sourceID,
        sourceGeneration: projectionDigest(42),
        fingerprint: projectionDigest(fingerprintValue ?? (bytes + 100)),
        sourceByteCount: bytes, prefixByteCount: bytes,
        prefixDigest: terminalRow?.prefixDigestAfter
            ?? DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal))
    let seed = prefixSeed ?? DisposableTimelineProjectionStore.PrefixSeed(
        byteCount: 0,
        digest: DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal),
        sequence: 0)
    let cursor = JournalCursor(
        journal: journal, eventID: lastSequence == 0 ? nil : "event-\(lastSequence)",
        sequence: lastSequence)
    let exactStateCheckpoint = exactStateRoots.isEmpty ? nil :
        DisposableTimelineProjectionStore.ExactStateCheckpoint(
            namespaceID: exactStateRoots[0].namespaceID,
            journal: journal,
            sourceGeneration: projectionDigest(42),
            cursor: cursor,
            prefixByteCount: source.prefixByteCount,
            prefixDigest: source.prefixDigest,
            roots: exactStateRoots)
    return DisposableTimelineProjectionStore.Commit(
        source: source, cursor: cursor, prefixSeed: seed,
        nextSequence: lastSequence + 1,
        nextPreviousEventID: cursor.eventID,
        sealedBuckets: sealedBuckets, currentBucket: currentBucket,
        anchors: anchors, recentPages: recentPages, reducerHead: reducerHead,
        exactStateCheckpoint: exactStateCheckpoint,
        pendingAcknowledgements: pendingAcknowledgements,
        expectedGeneration: expectedGeneration)
}

private func projectionStorePage(
    events: [TimelineEvent], id: String = "recent-one"
) -> DisposableTimelineProjectionStore.RecentEventPage {
    DisposableTimelineProjectionStore.RecentEventPage(pageID: id, events: events)
}

private func projectionStoreEvents(
    count: Int, journal: JournalRef = projectionStoreJournal
) -> [TimelineEvent] {
    projectionStoreRows(start: 1, count: count, journal: journal).map { row in
        TimelineEvent(
            eventID: row.eventID, journal: journal,
            sequence: row.sequence, previousEventID: row.previousEventID,
            actor: projectionStoreActor,
            hostRecordedAt: Date(timeIntervalSince1970: Double(row.sequence)),
            type: TimelineEventType.messageCommitted,
            payload: .object(["text": .string("event \(row.sequence)")]))
    }
}

private func projectionStoreRows(for events: [TimelineEvent], byteWidth: Int = 10) throws
    -> [DisposableTimelineProjectionStore.BucketRow] {
    guard let journal = events.first?.journal else { return [] }
    var prefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(
        for: journal)
    return try events.map { event in
        let lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
        let after = DisposableTimelineProjectionStore.advancePrefixDigest(
            prefix, lineDigest: lineDigest)
        let row = DisposableTimelineProjectionStore.BucketRow(
            sequence: event.sequence, eventID: event.eventID,
            previousEventID: event.previousEventID,
            byteStart: (event.sequence - 1) * byteWidth,
            byteEnd: event.sequence * byteWidth,
            prefixDigestBefore: prefix, prefixDigestAfter: after,
            lineDigest: lineDigest)
        prefix = after
        return row
    }
}

private func projectionStoreAnchor(
    _ row: DisposableTimelineProjectionStore.BucketRow
) -> DisposableTimelineProjectionStore.AnchorRecord {
    DisposableTimelineProjectionStore.AnchorRecord(
        sequence: row.sequence, eventID: row.eventID,
        previousEventID: row.previousEventID,
        byteStart: row.byteStart, byteEnd: row.byteEnd,
        prefixDigestBefore: row.prefixDigestBefore,
        prefixDigestAfter: row.prefixDigestAfter,
        lineDigest: row.lineDigest)
}

private func projectionStoreRadixMap(
    directory: URL,
    namespaceID: String = "projection-root-namespace",
    journal: JournalRef = projectionStoreJournal,
    sourceGeneration: String = projectionDigest(42),
    mapKind: String = "exact-state"
) throws -> PersistentProjectionRadixMap {
    try PersistentProjectionRadixMap(
        directory: directory, namespaceID: namespaceID, journal: journal,
        sourceGeneration: sourceGeneration, mapKind: mapKind)
}

private func projectionStoreExactRoot(
    at directory: URL,
    namespaceID: String = "projection-root-namespace",
    journal: JournalRef = projectionStoreJournal,
    sourceGeneration: String = projectionDigest(42),
    mapKind: String = "exact-state"
) throws -> DisposableTimelineProjectionStore.ExactStateRootDescriptor {
    let map = try projectionStoreRadixMap(
        directory: directory, namespaceID: namespaceID, journal: journal,
        sourceGeneration: sourceGeneration, mapKind: mapKind)
    let result = try map.setting(root: nil, key: "private-key", value: Data("private-value".utf8))
    return .init(root: try XCTUnwrap(result.newRoot))
}

private func forgedProjectionStoreExactRoot(
    _ descriptor: DisposableTimelineProjectionStore.ExactStateRootDescriptor,
    mutate: (inout [String: Any]) -> Void
) throws -> DisposableTimelineProjectionStore.ExactStateRootDescriptor {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: DisposableTimelineProjectionStore.canonicalJSON(descriptor))
            as? [String: Any])
    mutate(&object)
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(
        DisposableTimelineProjectionStore.ExactStateRootDescriptor.self, from: data)
}

private func expectProjectionStoreInvalidExactRoot(
    _ expectedReason: DisposableTimelineProjectionStore.FailureReason,
    _ body: () throws -> Void,
    line: Int = #line
) {
    do {
        try body()
        XCTFail("expected exact-state root commit rejection", line: line)
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(let reason) {
        XCTAssertEqual(reason, expectedReason, line: line)
    } catch {
        XCTFail("unexpected exact-state root error: \(error)", line: line)
    }
}

func testDisposableProjectionStorePublishesExactStateRootsAtomically() throws {
    XCTAssertFalse(
        DisposableTimelineProjectionStore.ExactStateCheckpoint.self is any Decodable.Type,
        "an exact checkpoint must not be publicly constructible through JSONDecoder")
    XCTAssertFalse(
        DisposableTimelineProjectionStore.Commit.self is any Decodable.Type,
        "a commit carrying an exact checkpoint must not regain a public decode route")

    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let mapDirectory = root.appending(path: "exact-map", directoryHint: .isDirectory)
    let exactRoot = try projectionStoreExactRoot(at: mapDirectory)
    let map = try projectionStoreRadixMap(directory: mapDirectory)
    let rows = projectionStoreRows(start: 1, count: 2)
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let commit = projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
        exactStateRoots: [exactRoot])
    let snapshot = try store.commit(commit, validatingExactStateCheckpoint: { checkpoint, _ in
        try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
    })

    let missingObjectRoot = try forgedProjectionStoreExactRoot(exactRoot) { object in
        object["objectID"] = String(repeating: "0", count: 64)
    }
    do {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: snapshot.generation,
                exactStateRoots: [missingObjectRoot]),
            validatingExactStateCheckpoint: { checkpoint, _ in
                try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
            })
        XCTFail("a missing exact-map root object must not publish a new HEAD")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.invalidExactStateCheckpoint) {
        XCTAssertEqual(try store.load(proving: snapshot.source), snapshot)
    }

    let checkpointDescriptor = try XCTUnwrap(snapshot.exactStateCheckpoint)
    let checkpoint = try XCTUnwrap(
        try store.loadExactStateCheckpoint(proving: snapshot.source))
    XCTAssertEqual(checkpoint.roots, [exactRoot])
    XCTAssertEqual(checkpoint.roots.first?.root, exactRoot.root)
    XCTAssertEqual(checkpoint.namespaceID, snapshot.namespaceID)
    XCTAssertEqual(checkpoint.cursor, snapshot.cursor)
    XCTAssertEqual(
        try DisposableTimelineProjectionStore.canonicalJSON(commit),
        try DisposableTimelineProjectionStore.canonicalJSON(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                exactStateRoots: [exactRoot])))

    let headURL = store.directory.appending(path: "HEAD", directoryHint: .notDirectory)
    let headText = String(
        decoding: try Data(contentsOf: headURL), as: UTF8.self)
    XCTAssertFalse(headText.contains("private-key"))
    XCTAssertFalse(headText.contains("private-value"))
    XCTAssertFalse(headText.contains(mapDirectory.path))
    XCTAssertTrue(headText.contains(checkpointDescriptor.objectID))
    let checkpointObjectURL = store.directory.appending(
        path: "objects/\(checkpointDescriptor.objectID).exact-checkpoint",
        directoryHint: .notDirectory)
    let checkpointText = String(
        decoding: try Data(contentsOf: checkpointObjectURL), as: UTF8.self)
    XCTAssertFalse(checkpointText.contains("private-key"))
    XCTAssertFalse(checkpointText.contains("private-value"))
    XCTAssertFalse(checkpointText.contains(mapDirectory.path))
    XCTAssertEqual(try store.loadExactStateRoots(proving: snapshot.source), [exactRoot])

    let reloadedStore = try DisposableTimelineProjectionStore(
        directory: store.directory, journal: projectionStoreJournal)
    let reloaded = try reloadedStore.load(proving: snapshot.source)
    let reloadedCheckpoint = try XCTUnwrap(
        try reloadedStore.loadExactStateCheckpoint(proving: snapshot.source))
    XCTAssertEqual(reloadedCheckpoint, checkpoint)
    XCTAssertEqual(reloaded.exactStateCheckpoint, checkpointDescriptor)
    // The store has only carried the root envelope; object validation remains the map's concern.
    try map.validate(root: try XCTUnwrap(reloadedCheckpoint.roots.first?.root))

    let aliasedParent = root.appending(path: "store-parent-alias", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: aliasedParent, withDestinationURL: root)
    let aliasedStore = try DisposableTimelineProjectionStore(
        directory: aliasedParent.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    do {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: snapshot.generation, exactStateRoots: [exactRoot]),
            validatingExactStateCheckpoint: { checkpoint, _ in
                try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
                _ = try aliasedStore.load(proving: snapshot.source)
            })
        XCTFail("an exact-state validator must not re-enter its projection store")
    } catch DisposableTimelineProjectionStore.StoreError.cacheUnavailable(.reentrantAccess) {
        XCTAssertEqual(try store.load(proving: snapshot.source), snapshot)
    }

    let staleRoot = try projectionStoreExactRoot(
        at: root.appending(path: "stale-map", directoryHint: .isDirectory),
        mapKind: "exact-state")
    do {
        _ = try store.commit(projectionStoreCommit(
            rows: projectionStoreRows(start: 1, count: 3),
            currentBucket: .init(
                bucketStart: 1, rows: projectionStoreRows(start: 1, count: 3)),
            sourceByteCount: 30, fingerprintValue: 130,
            expectedGeneration: 99, exactStateRoots: [staleRoot]))
        XCTFail("a stale exact-root commit must not publish")
    } catch DisposableTimelineProjectionStore.StoreError.staleGeneration {
        XCTAssertEqual(try store.load(proving: snapshot.source), snapshot)
    }

    try FileManager.default.removeItem(at: checkpointObjectURL)
    do {
        _ = try store.load(validatingSource: { _ in
            XCTFail("source validation must not run after checkpoint resolution fails")
            return snapshot.source
        })
        XCTFail("a missing exact-state checkpoint must invalidate source-validated load")
    } catch DisposableTimelineProjectionStore.StoreError.cacheUnavailable(.missingPayload) {
        XCTAssertTrue(true)
    }
}

func testDisposableProjectionStoreValidatesExactCheckpointTransitions() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mapDirectory = root.appending(path: "exact-map", directoryHint: .isDirectory)
    let map = try projectionStoreRadixMap(directory: mapDirectory)
    let firstRoot = try projectionStoreExactRoot(at: mapDirectory)
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let firstRows = projectionStoreRows(start: 1, count: 2)
    let first = try store.commit(
        projectionStoreCommit(
            rows: firstRows, currentBucket: .init(bucketStart: 1, rows: firstRows),
            exactStateRoots: [firstRoot]),
        validatingExactStateCheckpoint: { checkpoint, prior in
            XCTAssertNil(prior)
            try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
        })
    let firstCheckpoint = try XCTUnwrap(
        try store.loadExactStateCheckpoint(proving: first.source))

    let changed = try map.setting(
        root: firstRoot.root, key: "second-key", value: Data("second-value".utf8))
    let secondRoot = DisposableTimelineProjectionStore.ExactStateRootDescriptor(
        root: try XCTUnwrap(changed.newRoot))
    let secondRows = projectionStoreRows(start: 1, count: 3)
    let second = try store.commit(
        projectionStoreCommit(
            rows: secondRows, currentBucket: .init(bucketStart: 1, rows: secondRows),
            sourceByteCount: 30, fingerprintValue: 130,
            expectedGeneration: first.generation, exactStateRoots: [secondRoot]),
        validatingExactStateCheckpoint: { checkpoint, prior in
            XCTAssertEqual(prior, firstCheckpoint)
            XCTAssertEqual(checkpoint.cursor.sequence, 3)
            try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
        })
    let secondCheckpoint = try XCTUnwrap(
        try store.loadExactStateCheckpoint(proving: second.source))
    XCTAssertNotEqual(secondCheckpoint, firstCheckpoint)

    // A semantic no-op still publishes a new checkpoint bound to the new exact prefix while
    // reusing the unchanged content-addressed map root.
    let thirdRows = projectionStoreRows(start: 1, count: 4)
    let third = try store.commit(
        projectionStoreCommit(
            rows: thirdRows, currentBucket: .init(bucketStart: 1, rows: thirdRows),
            sourceByteCount: 40, fingerprintValue: 140,
            expectedGeneration: second.generation, exactStateRoots: [secondRoot]),
        validatingExactStateCheckpoint: { checkpoint, prior in
            XCTAssertEqual(prior, secondCheckpoint)
            XCTAssertEqual(checkpoint.roots, secondCheckpoint.roots)
            XCTAssertEqual(checkpoint.cursor.sequence, 4)
            try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
        })
    XCTAssertNotEqual(third.exactStateCheckpoint, second.exactStateCheckpoint)
    XCTAssertEqual(
        try store.loadExactStateCheckpoint(proving: third.source)?.roots,
        secondCheckpoint.roots)
}

func testDisposableProjectionStoreRejectsMalformedExactStateRootScopesAndBounds() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rows = projectionStoreRows(start: 1, count: 2)
    let exactRoot = try projectionStoreExactRoot(
        at: root.appending(path: "exact-map", directoryHint: .isDirectory))
    let exactMap = try projectionStoreRadixMap(
        directory: root.appending(path: "exact-map", directoryHint: .isDirectory))
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let first = try store.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
        exactStateRoots: [exactRoot]), validatingExactStateCheckpoint: { checkpoint, _ in
            try exactMap.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
        })

    expectProjectionStoreInvalidExactRoot(.invalidExactStateCheckpoint) {
        _ = try store.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
            expectedGeneration: first.generation))
    }

    let foreignNamespace = try projectionStoreExactRoot(
        at: root.appending(path: "foreign-namespace-map", directoryHint: .isDirectory),
        namespaceID: "foreign-root-namespace")
    expectProjectionStoreInvalidExactRoot(.invalidExactStateRoot) {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: [foreignNamespace]),
            validatingExactStateCheckpoint: { _, _ in })
    }

    let foreignJournal = JournalRef.work(
        projectionStoreWork, journalID: "foreign-root-journal")
    let foreignJournalRoot = try projectionStoreExactRoot(
        at: root.appending(path: "foreign-journal-map", directoryHint: .isDirectory),
        journal: foreignJournal)
    expectProjectionStoreInvalidExactRoot(.wrongJournal) {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: [foreignJournalRoot]),
            validatingExactStateCheckpoint: { _, _ in })
    }

    let foreignGeneration = try projectionStoreExactRoot(
        at: root.appending(path: "foreign-generation-map", directoryHint: .isDirectory),
        sourceGeneration: projectionDigest(43))
    expectProjectionStoreInvalidExactRoot(.wrongSource) {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: [foreignGeneration]),
            validatingExactStateCheckpoint: { _, _ in })
    }

    let foreignMapKind = try projectionStoreExactRoot(
        at: root.appending(path: "foreign-kind-map", directoryHint: .isDirectory),
        mapKind: "another-exact-state")
    expectProjectionStoreInvalidExactRoot(.invalidExactStateRoot) {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: [foreignMapKind]),
            validatingExactStateCheckpoint: { _, _ in })
    }

    let badSchema = try forgedProjectionStoreExactRoot(exactRoot) { object in
        object["schemaVersion"] = 99
    }
    expectProjectionStoreInvalidExactRoot(.schemaMismatch) {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: [badSchema]),
            validatingExactStateCheckpoint: { _, _ in })
    }

    let badObjectID = try forgedProjectionStoreExactRoot(exactRoot) { object in
        object["objectID"] = "not-a-digest"
    }
    expectProjectionStoreInvalidExactRoot(.invalidDigest) {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: [badObjectID]),
            validatingExactStateCheckpoint: { _, _ in })
    }

    let tooManyRoots = Array(repeating: exactRoot, count: 9)
    expectProjectionStoreInvalidExactRoot(.oversize) {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: tooManyRoots),
            validatingExactStateCheckpoint: { _, _ in })
    }

    let badEntryCount = try forgedProjectionStoreExactRoot(exactRoot) { object in
        object["entryCount"] = 2
    }
    let boundedStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "bounded-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        limits: .init(maximumExactStateRootEntries: 1))
    expectProjectionStoreInvalidExactRoot(.invalidExactStateRoot) {
        _ = try boundedStore.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                exactStateRoots: [badEntryCount]),
            validatingExactStateCheckpoint: { _, _ in })
    }

    XCTAssertEqual(try store.load(proving: first.source), first)
}

func testDisposableProjectionStoreFreshCommitLoadAndBodies() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let events = projectionStoreEvents(count: 2)
    let indexedRows = try projectionStoreRows(for: events)
    let commit = projectionStoreCommit(
        rows: indexedRows,
        currentBucket: DisposableTimelineProjectionStore.Bucket(
            bucketStart: 1, rows: indexedRows),
        recentPages: [projectionStorePage(events: events)],
        reducerHead: DisposableTimelineProjectionStore.OpaqueReducerHead(
            mediaType: "application/x-aviary-reducer-head", schemaVersion: 3,
            bytes: Data([1, 2, 3])),
        pendingAcknowledgements: [
            .init(
                request: WorkServiceAcknowledgeReadRequest(
                    work: projectionStoreWork, journal: projectionStoreJournal,
                    attachment: ClientAttachmentRef("projection-attachment"),
                    client: ClientRef("projection-client"),
                    target: .work(journal: projectionStoreJournal),
                    cursor: JournalCursor(
                        journal: projectionStoreJournal, eventID: "event-2", sequence: 2),
                    commandID: "ack-one",
                    causalControlCursor: JournalCursor(
                        journal: .workHostControl(WorkHostRef("projection-test-host")),
                        sequence: 0))),
        ])
    let snapshot = try store.commit(commit)
    XCTAssertEqual(snapshot.generation, 1)
    XCTAssertEqual(snapshot.cursor.sequence, 2)
    XCTAssertEqual(snapshot.nextSequence, 3)
    XCTAssertEqual(snapshot.currentBucket?.rowCount, 2)
    XCTAssertEqual(snapshot.recentPages.count, 1)
    XCTAssertFalse(snapshot.recentEventsOmitted)
    XCTAssertNotNil(snapshot.reducerHead)
    XCTAssertEqual(snapshot.pendingAcknowledgements.count, 1)

    let loaded = try store.load(proving: snapshot.source)
    XCTAssertEqual(loaded, snapshot)
    XCTAssertEqual(
        try store.loadBucket(containingSequence: 2, proving: snapshot.source).rows.count, 2)
    XCTAssertEqual(
        try store.loadRecentPage(id: "recent-one", proving: snapshot.source).events, events)
    XCTAssertEqual(try store.loadReducerHead(proving: snapshot.source), Data([1, 2, 3]))
    let appendedObservation = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: snapshot.source.journal, sourceID: snapshot.source.sourceID,
        sourceGeneration: snapshot.source.sourceGeneration,
        fingerprint: projectionDigest(999),
        sourceByteCount: snapshot.source.sourceByteCount + 10,
        prefixByteCount: snapshot.source.prefixByteCount,
        prefixDigest: snapshot.source.prefixDigest)
    XCTAssertEqual(try store.load(proving: appendedObservation).cursor, snapshot.cursor)
    let validated = try store.load { challenge in
        XCTAssertEqual(challenge.storedSource, snapshot.source)
        XCTAssertEqual(challenge.cursor, snapshot.cursor)
        XCTAssertEqual(challenge.terminalRow, indexedRows.last)
        return appendedObservation
    }
    XCTAssertEqual(validated.snapshot, snapshot)
    XCTAssertEqual(validated.observedSource, appendedObservation)
    let replacedObservation = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: snapshot.source.journal, sourceID: snapshot.source.sourceID,
        sourceGeneration: projectionDigest(43),
        fingerprint: snapshot.source.fingerprint,
        sourceByteCount: snapshot.source.sourceByteCount,
        prefixByteCount: snapshot.source.prefixByteCount,
        prefixDigest: snapshot.source.prefixDigest)
    do {
        _ = try store.load(proving: replacedObservation)
        XCTFail("a replacement source generation must invalidate the projection")
    } catch DisposableTimelineProjectionStore.StoreError.rebuildRequired(.wrongSource) {
        XCTAssertTrue(true)
    }
    let malformedObservation = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: snapshot.source.journal, sourceID: snapshot.source.sourceID,
        sourceGeneration: snapshot.source.sourceGeneration,
        fingerprint: "not-a-digest",
        sourceByteCount: snapshot.source.sourceByteCount,
        prefixByteCount: snapshot.source.prefixByteCount,
        prefixDigest: snapshot.source.prefixDigest)
    do {
        _ = try store.load(proving: malformedObservation)
        XCTFail("an invalid source observation must never prove a projection")
    } catch DisposableTimelineProjectionStore.StoreError.rebuildRequired(.wrongSource) {
        XCTAssertTrue(true)
    }
    let shorterObservation = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: snapshot.source.journal, sourceID: snapshot.source.sourceID,
        sourceGeneration: snapshot.source.sourceGeneration,
        fingerprint: projectionDigest(777),
        sourceByteCount: snapshot.source.prefixByteCount - 1,
        prefixByteCount: snapshot.source.prefixByteCount - 1,
        prefixDigest: snapshot.source.prefixDigest)
    do {
        _ = try store.load(proving: shorterObservation)
        XCTFail("a source shorter than the committed prefix must invalidate the projection")
    } catch DisposableTimelineProjectionStore.StoreError.rebuildRequired(.prefixMismatch) {
        XCTAssertTrue(true)
    }
    let wrongAppendPrefix = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: snapshot.source.journal, sourceID: snapshot.source.sourceID,
        sourceGeneration: snapshot.source.sourceGeneration,
        fingerprint: projectionDigest(778),
        sourceByteCount: snapshot.source.sourceByteCount + 10,
        prefixByteCount: snapshot.source.prefixByteCount,
        prefixDigest: projectionDigest(779))
    do {
        _ = try store.load(proving: wrongAppendPrefix)
        XCTFail("a larger source must still prove the exact stored prefix")
    } catch DisposableTimelineProjectionStore.StoreError.rebuildRequired(.prefixMismatch) {
        XCTAssertTrue(true)
    }
    let sameSizeReplacement = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: snapshot.source.journal, sourceID: snapshot.source.sourceID,
        sourceGeneration: snapshot.source.sourceGeneration,
        fingerprint: projectionDigest(780),
        sourceByteCount: snapshot.source.sourceByteCount,
        prefixByteCount: snapshot.source.prefixByteCount,
        prefixDigest: snapshot.source.prefixDigest)
    do {
        _ = try store.load(proving: sameSizeReplacement)
        XCTFail("same-size source replacement must not reuse the projection")
    } catch DisposableTimelineProjectionStore.StoreError.rebuildRequired(.wrongSource) {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(
        try DisposableTimelineProjectionStore.canonicalJSON(commit),
        try DisposableTimelineProjectionStore.canonicalJSON(commit))
}

func testDisposableProjectionStoreRewritesPartialThenSealsImmutableBucket() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let firstRows = projectionStoreRows(start: 1, count: 2)
    let first = try store.commit(projectionStoreCommit(
        rows: firstRows, currentBucket: .init(bucketStart: 1, rows: firstRows)))
    let expandedRows = projectionStoreRows(start: 1, count: 3)
    let expanded = try store.commit(projectionStoreCommit(
        rows: expandedRows,
        currentBucket: .init(bucketStart: 1, rows: expandedRows),
        sourceByteCount: 30, fingerprintValue: 130,
        expectedGeneration: first.generation))
    XCTAssertEqual(expanded.generation, 2)
    XCTAssertEqual(
        try store.loadBucket(containingSequence: 3, proving: expanded.source).rows.count, 3)

    let sealedRows = projectionStoreRows(start: 1, count: DisposableTimelineProjectionStore.bucketWidth)
    let sealed = try store.commit(projectionStoreCommit(
        rows: sealedRows,
        sealedBuckets: [.init(bucketStart: 1, rows: sealedRows)],
        sourceByteCount: DisposableTimelineProjectionStore.bucketWidth * 10,
        fingerprintValue: 2_660,
        expectedGeneration: expanded.generation))
    XCTAssertNil(sealed.currentBucket)
    XCTAssertEqual(sealed.sealedThroughSequence, 256)
    XCTAssertEqual(sealed.sealedBucketCount, 1)
    let late = try store.loadBucket(containingSequence: 200, proving: sealed.source)
    XCTAssertEqual(late.bucketStart, 1)
    XCTAssertEqual(late.rows.count, DisposableTimelineProjectionStore.bucketWidth)
    let metadataOnly = try store.commit(.init(
        source: sealed.source, cursor: sealed.cursor, prefixSeed: sealed.prefixSeed,
        nextSequence: sealed.nextSequence,
        nextPreviousEventID: sealed.nextPreviousEventID,
        pendingAcknowledgements: [], expectedGeneration: sealed.generation))
    XCTAssertEqual(metadataOnly.cursor, sealed.cursor)
    XCTAssertEqual(metadataOnly.generation, sealed.generation + 1)
    XCTAssertEqual(
        try store.loadBucket(containingSequence: 200, proving: metadataOnly.source).rows.count,
        DisposableTimelineProjectionStore.bucketWidth)
}

func testDisposableProjectionStoreDirectBucketReadIsBounded() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let operations = LockedProjectionOperations()
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        observer: { operations.append($0) })
    let buckets = stride(from: 1, through: 769, by: DisposableTimelineProjectionStore.bucketWidth)
        .map {
            DisposableTimelineProjectionStore.Bucket(
                bucketStart: $0,
                rows: projectionStoreRows(
                    start: $0, count: DisposableTimelineProjectionStore.bucketWidth))
        }
    let direct = try store.commit(projectionStoreCommit(
        rows: buckets.last!.rows, sealedBuckets: buckets,
        sourceByteCount: 10 * 1_024, fingerprintValue: 10_124,
        anchors: buckets.compactMap { $0.rows.last.map(projectionStoreAnchor) }))
    operations.reset()
    let metadata = try store.commit(projectionStoreCommit(
        rows: buckets.last!.rows,
        sourceByteCount: 10 * 1_024, fingerprintValue: 10_124,
        expectedGeneration: direct.generation, anchors: direct.anchors))
    let commitOperations = operations.values
    XCTAssertTrue(commitOperations.filter { $0 == .readPayload }.count <= 1)
    XCTAssertTrue(commitOperations.filter { $0 == .readBucketReference }.count <= 1)
    operations.reset()
    let bucket = try store.loadBucket(containingSequence: 900, proving: metadata.source)
    XCTAssertEqual(bucket.bucketStart, 769)
    let seen = operations.values
    XCTAssertFalse(seen.contains(.readRecentPage))
    XCTAssertFalse(seen.contains(.readReducerHead))
    // One bounded terminal proof plus the requested direct bucket lookup; never a history walk.
    XCTAssertTrue(seen.filter { $0 == .readPayload }.count <= 2)
    XCTAssertTrue(seen.filter { $0 == .readBucketReference }.count <= 2)
    XCTAssertTrue(seen.count <= 10)
}

func testDisposableProjectionStoreRejectsWrongJournalSourceCursorAndPrefix() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let rows = projectionStoreRows(start: 1, count: 2)
    let first = try store.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))

    do {
        _ = try store.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
            expectedGeneration: first.generation,
            journal: JournalRef.work(projectionStoreWork, journalID: "foreign-journal")))
        XCTFail("a foreign JournalRef must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.wrongJournal) {
        XCTAssertTrue(true)
    }
    do {
        _ = try store.commit(projectionStoreCommit(
            rows: projectionStoreRows(start: 1, count: 3),
            currentBucket: .init(bucketStart: 1, rows: projectionStoreRows(start: 1, count: 3)),
            sourceID: "different-source", sourceByteCount: 30, fingerprintValue: 130,
            expectedGeneration: first.generation))
        XCTFail("a source identity change must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.wrongSource) {
        XCTAssertTrue(true)
    }
    var badCursor = projectionStoreCommit(
        rows: projectionStoreRows(start: 1, count: 3),
        currentBucket: .init(bucketStart: 1, rows: projectionStoreRows(start: 1, count: 3)),
        sourceByteCount: 30, fingerprintValue: 130,
        expectedGeneration: first.generation)
    badCursor = .init(
        source: badCursor.source,
        cursor: JournalCursor(journal: projectionStoreJournal, eventID: "event-2", sequence: 2),
        prefixSeed: badCursor.prefixSeed, nextSequence: 3,
        nextPreviousEventID: "event-2", currentBucket: badCursor.currentBucket,
        expectedGeneration: first.generation)
    do {
        _ = try store.commit(badCursor)
        XCTFail("a cursor that regresses the supplied bucket must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.prefixMismatch) {
        XCTAssertTrue(true)
    }
    let differentSeed = DisposableTimelineProjectionStore.PrefixSeed(
        byteCount: 0, digest: projectionDigest(99), sequence: 0)
    do {
        _ = try store.commit(projectionStoreCommit(
            rows: projectionStoreRows(start: 1, count: 3),
            currentBucket: .init(bucketStart: 1, rows: projectionStoreRows(start: 1, count: 3)),
            sourceByteCount: 30, fingerprintValue: 130, prefixSeed: differentSeed,
            expectedGeneration: first.generation))
        XCTFail("the seed identity must remain stable after the first commit")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.prefixMismatch) {
        XCTAssertTrue(true)
    }
}

func testDisposableProjectionStoreDetectsTamperedOrMissingHeadAndPayload() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let headStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "head-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let rows = projectionStoreRows(start: 1, count: 2)
    let headSnapshot = try headStore.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
    let head = headStore.directory.appending(path: "HEAD", directoryHint: .notDirectory)
    try Data("{\"schema_version\":1}".utf8).write(to: head, options: .atomic)
    do {
        _ = try headStore.load(proving: headSnapshot.source)
        XCTFail("a tampered HEAD must fail closed")
    } catch DisposableTimelineProjectionStore.StoreError.cacheUnavailable {
        XCTAssertTrue(true)
    }

    let payloadStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "payload-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let snapshot = try payloadStore.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
    let payload = payloadStore.directory.appending(
        path: "objects/\(snapshot.currentBucket!.objectID).bucket",
        directoryHint: .notDirectory)
    try FileManager.default.removeItem(at: payload)
    do {
        _ = try payloadStore.load(proving: snapshot.source)
        XCTFail("a missing current payload must fail closed")
    } catch DisposableTimelineProjectionStore.StoreError.cacheUnavailable(.missingPayload) {
        XCTAssertTrue(true)
    }
}

func testDisposableProjectionStoreRejectsSymlinksAndInsecureModes() throws {
    let root = try projectionStoreRoot()
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: root.appending(path: "mode-store").path)
        try? FileManager.default.removeItem(at: root)
    }
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "symlink-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let rows = projectionStoreRows(start: 1, count: 2)
    let snapshot = try store.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
    let realHead = store.directory.appending(path: "HEAD", directoryHint: .notDirectory)
    let movedHead = root.appending(path: "moved-head", directoryHint: .notDirectory)
    try FileManager.default.moveItem(at: realHead, to: movedHead)
    try FileManager.default.createSymbolicLink(at: realHead, withDestinationURL: movedHead)
    do {
        _ = try store.load(proving: snapshot.source)
        XCTFail("HEAD symlinks must not be followed")
    } catch DisposableTimelineProjectionStore.StoreError.cacheUnavailable(.symlinkOrNonRegularFile) {
        XCTAssertTrue(true)
    }

    let modeStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "mode-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: modeStore.directory.path)
    do {
        _ = try modeStore.load(proving: projectionStoreSource(lastSequence: 0))
        XCTFail("world-readable projection directories must fail closed")
    } catch DisposableTimelineProjectionStore.StoreError.cacheUnavailable(.insecurePermissions) {
        XCTAssertTrue(true)
    }
}

func testDisposableProjectionStoreEnforcesHeadObjectPageAndReducerBounds() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let rows = projectionStoreRows(start: 1, count: 2)
    let tinyHead = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "tiny-head", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        limits: .init(maximumHeadBytes: 1))
    do {
        _ = try tinyHead.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
        XCTFail("an oversized HEAD must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.oversize) {
        XCTAssertTrue(true)
    }
    XCTAssertFalse(
        FileManager.default.fileExists(
            atPath: tinyHead.directory.appending(path: "HEAD").path),
        "a pre-publication failure must not publish a partial HEAD")
    let tinyObject = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "tiny-object", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        limits: .init(maximumObjectBytes: 1))
    do {
        _ = try tinyObject.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
        XCTFail("an oversized bucket object must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.oversize) {
        XCTAssertTrue(true)
    }
    let tinyPage = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "tiny-page", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        limits: .init(maximumRecentPageEvents: 1))
    do {
        _ = try tinyPage.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
            recentPages: [projectionStorePage(events: projectionStoreEvents(count: 2))]))
        XCTFail("an oversized recent page must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.oversize) {
        XCTAssertTrue(true)
    }
    let tinyReducer = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "tiny-reducer", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        limits: .init(maximumReducerHeadBytes: 1))
    do {
        _ = try tinyReducer.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
            reducerHead: .init(bytes: Data([1, 2]))))
        XCTFail("an oversized reducer head must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.oversize) {
        XCTAssertTrue(true)
    }
    let checkpointMapDirectory = root.appending(
        path: "tiny-checkpoint-map", directoryHint: .isDirectory)
    let checkpointRoot = try projectionStoreExactRoot(at: checkpointMapDirectory)
    let checkpointMap = try projectionStoreRadixMap(directory: checkpointMapDirectory)
    let tinyCheckpoint = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "tiny-checkpoint", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        limits: .init(maximumExactStateCheckpointBytes: 1))
    do {
        _ = try tinyCheckpoint.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                exactStateRoots: [checkpointRoot]),
            validatingExactStateCheckpoint: { checkpoint, _ in
                try checkpointMap.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
            })
        XCTFail("an oversized exact-state checkpoint must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.oversize) {
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tinyCheckpoint.directory.appending(path: "HEAD").path))
    }
}

func testDisposableProjectionStoreIgnoresCrashOrphansAndRebuildsAfterClear() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "store", directoryHint: .isDirectory)
    let store = try DisposableTimelineProjectionStore(directory: directory, journal: projectionStoreJournal)
    let orphan = directory.appending(
        path: "objects/\(projectionDigest(999)).bucket", directoryHint: .notDirectory)
    try Data(repeating: 0x7f, count: 20).write(to: orphan)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: orphan.path)
    let rows = projectionStoreRows(start: 1, count: 2)
    let first = try store.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
    XCTAssertEqual(try store.load(proving: first.source).generation, 1)
    let cleared = try store.clear()
    XCTAssertTrue(cleared.rebuildRequired)
    XCTAssertTrue(cleared.retainedImmutablePayloads)
    do {
        _ = try store.load(proving: first.source)
        XCTFail("a cleared cache must require rebuild")
    } catch DisposableTimelineProjectionStore.StoreError.rebuildRequired(.missingHead) {
        XCTAssertTrue(true)
    }
    let rebuilt = try store.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
    XCTAssertEqual(rebuilt.generation, 1)
    XCTAssertNotEqual(rebuilt.namespaceID, first.namespaceID)
    XCTAssertEqual(
        try store.loadBucket(containingSequence: 2, proving: rebuilt.source).rows.count, 2)
    var generation = rebuilt.generation
    for count in 3...20 {
        let expanded = projectionStoreRows(start: 1, count: count)
        generation = try store.commit(projectionStoreCommit(
            rows: expanded, currentBucket: .init(bucketStart: 1, rows: expanded),
            expectedGeneration: generation)).generation
    }
    let objectCount = try FileManager.default.contentsOfDirectory(
        at: store.directory.appending(path: "objects", directoryHint: .isDirectory),
        includingPropertiesForKeys: nil).count
    XCTAssertTrue(objectCount <= 2, "routine partial commits must reclaim replaced payloads")
}

func testDisposableProjectionStoreRetiresExactNamespaceAcrossClear() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "store", directoryHint: .isDirectory)
    let store = try DisposableTimelineProjectionStore(
        directory: directory, journal: projectionStoreJournal)
    let rows = projectionStoreRows(
        start: 1, count: DisposableTimelineProjectionStore.bucketWidth)
    let firstMapDirectory = root.appending(path: "exact-map-one", directoryHint: .isDirectory)
    let firstRoot = try projectionStoreExactRoot(at: firstMapDirectory)
    let firstMap = try projectionStoreRadixMap(directory: firstMapDirectory)
    let firstCommit = projectionStoreCommit(
        rows: rows,
        sealedBuckets: [.init(bucketStart: 1, rows: rows)],
        exactStateRoots: [firstRoot])
    let first = try store.commit(
        firstCommit,
        validatingExactStateCheckpoint: { checkpoint, _ in
            try firstMap.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
        })
    XCTAssertEqual(first.namespaceID, firstRoot.namespaceID)
    XCTAssertEqual(
        try store.loadBucket(containingSequence: 1, proving: first.source).rows.count,
        DisposableTimelineProjectionStore.bucketWidth)

    _ = try store.clear()
    do {
        _ = try store.commit(
            firstCommit,
            validatingExactStateCheckpoint: { checkpoint, _ in
                try firstMap.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
            })
        XCTFail("clear must permanently retire an exact-state namespace")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.invalidExactStateCheckpoint) {
        XCTAssertTrue(true)
    }

    let secondNamespace = "projection-root-namespace-two"
    let secondMapDirectory = root.appending(path: "exact-map-two", directoryHint: .isDirectory)
    let secondRoot = try projectionStoreExactRoot(
        at: secondMapDirectory, namespaceID: secondNamespace)
    let secondMap = try projectionStoreRadixMap(
        directory: secondMapDirectory, namespaceID: secondNamespace)
    let rebuilt = try store.commit(
        projectionStoreCommit(
            rows: rows,
            sealedBuckets: [.init(bucketStart: 1, rows: rows)],
            exactStateRoots: [secondRoot]),
        validatingExactStateCheckpoint: { checkpoint, prior in
            XCTAssertNil(prior)
            try secondMap.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
        })
    XCTAssertEqual(rebuilt.generation, 1)
    XCTAssertEqual(rebuilt.namespaceID, secondNamespace)
    XCTAssertNotEqual(rebuilt.namespaceID, first.namespaceID)
    XCTAssertEqual(
        try store.loadBucket(containingSequence: 256, proving: rebuilt.source).rows.count,
        DisposableTimelineProjectionStore.bucketWidth)
}

func testDisposableProjectionStoreReportsIndeterminateHeadPublication() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "store", directoryHint: .isDirectory)
    let movedDirectory = root.appending(path: "published-store", directoryHint: .isDirectory)
    let store = try DisposableTimelineProjectionStore(
        directory: directory, journal: projectionStoreJournal,
        observer: { operation in
            if operation == .publishHead {
                try? FileManager.default.moveItem(at: directory, to: movedDirectory)
            }
        })
    let rows = projectionStoreRows(start: 1, count: 2)
    let commit = projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows))
    do {
        _ = try store.commit(commit)
        XCTFail("a post-rename directory-sync failure must be reported as indeterminate")
    } catch DisposableTimelineProjectionStore.StoreError.cacheUnavailable(.publicationIndeterminate) {
        XCTAssertTrue(true)
    }

    // The rename already made the complete new generation visible. Reconciliation must load the
    // moved store and observe that generation rather than retrying the old expected generation.
    let published = try DisposableTimelineProjectionStore(
        directory: movedDirectory, journal: projectionStoreJournal)
    let reconciled = try published.load(proving: commit.source)
    XCTAssertEqual(reconciled.generation, 1)
    XCTAssertEqual(reconciled.cursor, commit.cursor)
}

func testDisposableProjectionStoreClearRetiresFailedExactUpgradeReservation() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal,
        limits: .init(maximumExactStateCheckpointBytes: 1))
    let rows = projectionStoreRows(start: 1, count: 2)
    let first = try store.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
    let mapDirectory = root.appending(path: "upgrade-map", directoryHint: .isDirectory)
    let rootDescriptor = try projectionStoreExactRoot(
        at: mapDirectory, namespaceID: first.namespaceID)
    let map = try projectionStoreRadixMap(
        directory: mapDirectory, namespaceID: first.namespaceID)
    do {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                expectedGeneration: first.generation, exactStateRoots: [rootDescriptor]),
            validatingExactStateCheckpoint: { checkpoint, _ in
                try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
            })
        XCTFail("the deliberately tiny checkpoint bound must reject the exact upgrade")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.oversize) {
        XCTAssertEqual(try store.load(proving: first.source), first)
    }

    _ = try store.clear()
    do {
        _ = try store.commit(
            projectionStoreCommit(
                rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
                exactStateRoots: [rootDescriptor]),
            validatingExactStateCheckpoint: { checkpoint, _ in
                try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
            })
        XCTFail("clear must retire a reservation left by a failed rootless-to-exact upgrade")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.invalidExactStateCheckpoint) {
        XCTAssertTrue(true)
    }
}

func testDisposableProjectionStoreClearRetiresFailedInitialExactReservation() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "store", directoryHint: .isDirectory)
    let tinyStore = try DisposableTimelineProjectionStore(
        directory: directory, journal: projectionStoreJournal,
        limits: .init(maximumExactStateCheckpointBytes: 1))
    let rows = projectionStoreRows(start: 1, count: 2)
    let mapDirectory = root.appending(path: "initial-map", directoryHint: .isDirectory)
    let rootDescriptor = try projectionStoreExactRoot(at: mapDirectory)
    let map = try projectionStoreRadixMap(directory: mapDirectory)
    let commit = projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
        exactStateRoots: [rootDescriptor])
    do {
        _ = try tinyStore.commit(
            commit,
            validatingExactStateCheckpoint: { checkpoint, _ in
                try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
            })
        XCTFail("the deliberately tiny checkpoint bound must reject first publication")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.oversize) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appending(path: "HEAD").path))
    }

    let cleared = try tinyStore.clear()
    XCTAssertFalse(cleared.hadHead)
    let reopened = try DisposableTimelineProjectionStore(
        directory: directory, journal: projectionStoreJournal)
    do {
        _ = try reopened.commit(
            commit,
            validatingExactStateCheckpoint: { checkpoint, _ in
                try map.validate(root: try XCTUnwrap(checkpoint.roots.first).root)
            })
        XCTFail("clear must retire a reservation even when first publication never made HEAD")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.invalidExactStateCheckpoint) {
        XCTAssertTrue(true)
    }
}

func testDisposableProjectionStoreRejectsStaleGenerationAndPartialChains() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let rows = projectionStoreRows(start: 1, count: 2)
    let first = try store.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows)))
    do {
        _ = try store.commit(projectionStoreCommit(
            rows: projectionStoreRows(start: 1, count: 3),
            currentBucket: .init(bucketStart: 1, rows: projectionStoreRows(start: 1, count: 3)),
            sourceByteCount: 30, expectedGeneration: 99))
        XCTFail("a stale generation must not publish")
    } catch DisposableTimelineProjectionStore.StoreError.staleGeneration(let expected, let actual) {
        XCTAssertEqual(expected, 99)
        XCTAssertEqual(actual, first.generation)
    }
    var brokenRows = projectionStoreRows(start: 1, count: 2)
    let second = brokenRows[1]
    brokenRows[1] = .init(
        sequence: second.sequence, eventID: second.eventID,
        previousEventID: "not-event-1", byteStart: second.byteStart,
        byteEnd: second.byteEnd, prefixDigestBefore: second.prefixDigestBefore,
        prefixDigestAfter: second.prefixDigestAfter, lineDigest: second.lineDigest)
    let broken = DisposableTimelineProjectionStore.Bucket(
        bucketStart: 1, rows: brokenRows)
    do {
        _ = try store.commit(projectionStoreCommit(
            rows: broken.rows, currentBucket: broken,
            sourceByteCount: 20, expectedGeneration: first.generation))
        XCTFail("a broken previous-event chain must be rejected")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.chainMismatch) {
        XCTAssertTrue(true)
    }

    let fullRows = projectionStoreRows(
        start: 1, count: DisposableTimelineProjectionStore.bucketWidth)
    let fullStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "cross-bucket", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let full = try fullStore.commit(projectionStoreCommit(
        rows: fullRows,
        sealedBuckets: [.init(bucketStart: 1, rows: fullRows)],
        sourceByteCount: DisposableTimelineProjectionStore.bucketWidth * 10,
        fingerprintValue: 2_660))
    var nextRows = projectionStoreRows(start: 257, count: 1)
    nextRows[0] = .init(
        sequence: 257, eventID: "event-257", previousEventID: "missing-event-256",
        byteStart: 2_560, byteEnd: 2_570,
        prefixDigestBefore: nextRows[0].prefixDigestBefore,
        prefixDigestAfter: nextRows[0].prefixDigestAfter,
        lineDigest: nextRows[0].lineDigest)
    do {
        _ = try fullStore.commit(projectionStoreCommit(
            rows: nextRows, sealedBuckets: [],
            currentBucket: .init(bucketStart: 257, rows: nextRows),
            sourceByteCount: 2_570, fingerprintValue: 2_770,
            expectedGeneration: full.generation))
        XCTFail("a current bucket may not skip the sealed terminal row")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.chainMismatch) {
        XCTAssertTrue(true)
    }

    let skippedStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "skipped-bucket", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let skippedRows = projectionStoreRows(start: 513, count: 1)
    do {
        _ = try skippedStore.commit(projectionStoreCommit(
            rows: skippedRows,
            sealedBuckets: [.init(bucketStart: 1, rows: fullRows)],
            currentBucket: .init(bucketStart: 513, rows: skippedRows),
            sourceByteCount: 5_130))
        XCTFail("a fresh projection may not skip an entire middle bucket")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.chainMismatch) {
        XCTAssertTrue(true)
    }
}

func testDisposableProjectionStoreBindsPagesAnchorsSeedsAndSessionAcknowledgements() throws {
    let root = try projectionStoreRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let events = projectionStoreEvents(count: 2)
    let rows = try projectionStoreRows(for: events)
    let tamperedEvent = TimelineEvent(
        eventID: events[1].eventID, journal: events[1].journal,
        sequence: events[1].sequence, previousEventID: events[1].previousEventID,
        actor: events[1].actor, hostRecordedAt: events[1].hostRecordedAt,
        type: events[1].type,
        payload: .object(["text": .string("different canonical bytes")]))
    let pageStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "page-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    do {
        _ = try pageStore.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
            recentPages: [projectionStorePage(events: [events[0], tamperedEvent])]))
        XCTFail("recent pages must be exact views of their indexed canonical events")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.chainMismatch) {
        XCTAssertTrue(true)
    }

    let gapEvents = projectionStoreEvents(count: 3)
    let gapRows = try projectionStoreRows(for: gapEvents)
    let gapPageStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "gap-page-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    do {
        _ = try gapPageStore.commit(projectionStoreCommit(
            rows: gapRows, currentBucket: .init(bucketStart: 1, rows: gapRows),
            recentPages: [
                projectionStorePage(events: [gapEvents[0]], id: "recent-one"),
                projectionStorePage(events: [gapEvents[2]], id: "recent-three"),
            ]))
        XCTFail("recent pages may not silently omit an event between pages")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.chainMismatch) {
        XCTAssertTrue(true)
    }

    let first = rows[0]
    let validAnchor = projectionStoreAnchor(first)
    let anchorStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "anchor-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let anchored = try anchorStore.commit(projectionStoreCommit(
        rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
        anchors: [validAnchor]))
    XCTAssertEqual(try anchorStore.load(proving: anchored.source).anchors, [validAnchor])
    XCTAssertEqual(
        try anchorStore.loadAnchor(at: validAnchor.sequence, proving: anchored.source),
        validAnchor)

    let foreignLine = projectionDigest(98_765)
    let invalidAnchor = DisposableTimelineProjectionStore.AnchorRecord(
        sequence: first.sequence, eventID: first.eventID,
        previousEventID: first.previousEventID,
        byteStart: first.byteStart, byteEnd: first.byteEnd,
        prefixDigestBefore: first.prefixDigestBefore,
        prefixDigestAfter: DisposableTimelineProjectionStore.advancePrefixDigest(
            first.prefixDigestBefore, lineDigest: foreignLine),
        lineDigest: foreignLine)
    let invalidAnchorStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "invalid-anchor-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    do {
        _ = try invalidAnchorStore.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
            anchors: [invalidAnchor]))
        XCTFail("a self-consistent anchor must still match its exact indexed row")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.invalidBucket) {
        XCTAssertTrue(true)
    }

    let seededRows = projectionStoreRows(start: 257, count: 2)
    let seededPrefix = DisposableTimelineProjectionStore.PrefixSeed(
        byteCount: seededRows[0].byteStart,
        digest: seededRows[0].prefixDigestBefore,
        sequence: 256,
        previousEventID: "event-256")
    let seededStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "seeded-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    let seeded = try seededStore.commit(projectionStoreCommit(
        rows: seededRows,
        currentBucket: .init(bucketStart: 257, rows: seededRows),
        prefixSeed: seededPrefix))
    XCTAssertEqual(seeded.sealedThroughSequence, 256)
    XCTAssertEqual(seeded.sealedBucketCount, 0)
    XCTAssertEqual(
        try seededStore.loadBucket(containingSequence: 257, proving: seeded.source).rows.first,
        seededRows.first)
    do {
        _ = try seededStore.loadBucket(containingSequence: 256, proving: seeded.source)
        XCTFail("the cache must not claim events preceding its explicit prefix seed")
    } catch DisposableTimelineProjectionStore.StoreError.notFound {
        XCTAssertTrue(true)
    }
    let seededFullRows = projectionStoreRows(
        start: 257, count: DisposableTimelineProjectionStore.bucketWidth)
    let seededSealed = try seededStore.commit(projectionStoreCommit(
        rows: seededFullRows,
        sealedBuckets: [.init(bucketStart: 257, rows: seededFullRows)],
        prefixSeed: seededPrefix, expectedGeneration: seeded.generation))
    XCTAssertEqual(seededSealed.sealedThroughSequence, 512)
    XCTAssertEqual(seededSealed.sealedBucketCount, 1)
    XCTAssertEqual(
        try seededStore.loadBucket(containingSequence: 500, proving: seededSealed.source)
            .bucketStart,
        257)

    let skippedBase = projectionStoreRows(start: 513, count: 1)[0]
    let skippedAfter = DisposableTimelineProjectionStore.advancePrefixDigest(
        seededPrefix.digest, lineDigest: skippedBase.lineDigest)
    let skippedRow = DisposableTimelineProjectionStore.BucketRow(
        sequence: 513, eventID: skippedBase.eventID,
        previousEventID: seededPrefix.previousEventID,
        byteStart: seededPrefix.byteCount, byteEnd: seededPrefix.byteCount + 10,
        prefixDigestBefore: seededPrefix.digest,
        prefixDigestAfter: skippedAfter, lineDigest: skippedBase.lineDigest)
    let skippedSeedStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "skipped-seed-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    do {
        _ = try skippedSeedStore.commit(projectionStoreCommit(
            rows: [skippedRow], currentBucket: .init(bucketStart: 513, rows: [skippedRow]),
            sourceByteCount: skippedRow.byteEnd, prefixSeed: seededPrefix))
        XCTFail("a lone current bucket may not skip forward from a nonzero prefix seed")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.invalidBucket) {
        XCTAssertTrue(true)
    }

    let session = SessionRef("projection-session")
    let sessionJournal = JournalRef.session(
        session, journalID: "projection-session-journal",
        authority: TimelineAuthorityRef(projectionStoreWork.workHostID))
    let sessionRows = projectionStoreRows(start: 1, count: 1, journal: sessionJournal)
    let sessionStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "session-store", directoryHint: .isDirectory),
        journal: sessionJournal)
    let acknowledgement = DisposableTimelineProjectionStore.PendingAcknowledgement(
        request: WorkServiceAcknowledgeReadRequest(
            work: projectionStoreWork, journal: projectionStoreJournal,
            attachment: ClientAttachmentRef("projection-session-attachment"),
            client: ClientRef("projection-session-client"),
            target: .session(session: session, journal: sessionJournal),
            cursor: JournalCursor(
                journal: sessionJournal, eventID: "event-1", sequence: 1),
            commandID: "projection-session-ack",
            causalControlCursor: JournalCursor(
                journal: .workHostControl(WorkHostRef(projectionStoreWork.workHostID)),
                sequence: 0)))
    let sessionSnapshot = try sessionStore.commit(projectionStoreCommit(
        rows: sessionRows,
        currentBucket: .init(bucketStart: 1, rows: sessionRows),
        pendingAcknowledgements: [acknowledgement], journal: sessionJournal))
    XCTAssertEqual(sessionSnapshot.pendingAcknowledgements, [acknowledgement])
    XCTAssertEqual(try sessionStore.load(proving: sessionSnapshot.source), sessionSnapshot)

    let foreignWork = WorkRef(
        workHostID: projectionStoreWork.workHostID, workID: "projection-foreign-work")
    let foreignWorkJournal = JournalRef.work(
        foreignWork, journalID: "projection-foreign-work-journal")
    let crossWorkAcknowledgement = DisposableTimelineProjectionStore.PendingAcknowledgement(
        request: WorkServiceAcknowledgeReadRequest(
            work: foreignWork, journal: foreignWorkJournal,
            attachment: ClientAttachmentRef("projection-foreign-attachment"),
            client: ClientRef("projection-foreign-client"),
            target: .work(journal: projectionStoreJournal),
            cursor: JournalCursor(
                journal: projectionStoreJournal, eventID: "event-2", sequence: 2),
            commandID: "projection-cross-work-ack",
            causalControlCursor: JournalCursor(
                journal: .workHostControl(WorkHostRef(projectionStoreWork.workHostID)),
                sequence: 0)))
    let crossWorkStore = try DisposableTimelineProjectionStore(
        directory: root.appending(path: "cross-work-store", directoryHint: .isDirectory),
        journal: projectionStoreJournal)
    do {
        _ = try crossWorkStore.commit(projectionStoreCommit(
            rows: rows, currentBucket: .init(bucketStart: 1, rows: rows),
            pendingAcknowledgements: [crossWorkAcknowledgement]))
        XCTFail("a Work-target acknowledgement must bind request and target to one Work")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(.invalidIdentity) {
        XCTAssertTrue(true)
    }
}

private final class LockedProjectionOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DisposableTimelineProjectionStore.AccessOperation] = []

    func append(_ value: DisposableTimelineProjectionStore.AccessOperation) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    var values: [DisposableTimelineProjectionStore.AccessOperation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

let casesDisposableTimelineProjectionStore: [Case] = [
    ("phase3 projection store publishes exact-state checkpoint roots atomically", {
        try testDisposableProjectionStorePublishesExactStateRootsAtomically()
    }),
    ("phase3 projection store validates exact-state checkpoint transitions", {
        try testDisposableProjectionStoreValidatesExactCheckpointTransitions()
    }),
    ("phase3 projection store rejects malformed exact-state checkpoint roots", {
        try testDisposableProjectionStoreRejectsMalformedExactStateRootScopesAndBounds()
    }),
    ("phase3 projection store fresh commit/load and bodies", {
        try testDisposableProjectionStoreFreshCommitLoadAndBodies()
    }),
    ("phase3 projection store rewrites partial then seals immutable bucket", {
        try testDisposableProjectionStoreRewritesPartialThenSealsImmutableBucket()
    }),
    ("phase3 projection store direct bucket lookup stays bounded", {
        try testDisposableProjectionStoreDirectBucketReadIsBounded()
    }),
    ("phase3 projection store rejects wrong source cursor and prefix", {
        try testDisposableProjectionStoreRejectsWrongJournalSourceCursorAndPrefix()
    }),
    ("phase3 projection store detects tampered or missing files", {
        try testDisposableProjectionStoreDetectsTamperedOrMissingHeadAndPayload()
    }),
    ("phase3 projection store rejects symlinks and insecure modes", {
        try testDisposableProjectionStoreRejectsSymlinksAndInsecureModes()
    }),
    ("phase3 projection store enforces centralized bounds", {
        try testDisposableProjectionStoreEnforcesHeadObjectPageAndReducerBounds()
    }),
    ("phase3 projection store ignores crash orphans and rebuilds after clear", {
        try testDisposableProjectionStoreIgnoresCrashOrphansAndRebuildsAfterClear()
    }),
    ("phase3 projection store retires exact namespace across clear", {
        try testDisposableProjectionStoreRetiresExactNamespaceAcrossClear()
    }),
    ("phase3 projection store reports indeterminate HEAD publication", {
        try testDisposableProjectionStoreReportsIndeterminateHeadPublication()
    }),
    ("phase3 projection store clear retires failed exact-upgrade reservation", {
        try testDisposableProjectionStoreClearRetiresFailedExactUpgradeReservation()
    }),
    ("phase3 projection store clear retires failed initial exact reservation", {
        try testDisposableProjectionStoreClearRetiresFailedInitialExactReservation()
    }),
    ("phase3 projection store rejects stale generations and broken chains", {
        try testDisposableProjectionStoreRejectsStaleGenerationAndPartialChains()
    }),
    ("phase3 projection store binds pages anchors seeds and Session acknowledgements", {
        try testDisposableProjectionStoreBindsPagesAnchorsSeedsAndSessionAcknowledgements()
    }),
]
