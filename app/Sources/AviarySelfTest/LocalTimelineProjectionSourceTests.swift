import Foundation
@testable import AviaryCore

private let localProjectionSourceHost = WorkHostRef("local-projection-source-host")
private let localProjectionSourceWork = WorkRef(
    workHostID: localProjectionSourceHost.workHostID, workID: "local-projection-source-work")
private let localProjectionSourceJournal = JournalRef.work(
    localProjectionSourceWork, journalID: "local-projection-source-journal")
private let localProjectionSourceActor = TimelineActor(
    actorID: "local-projection-source-test", kind: "self-test")

private func localProjectionSourceRoot() throws -> URL {
    let root = URL(
        fileURLWithPath: "/tmp/lps-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return root
}

private func localProjectionSourceEvent(
    eventID: String = "source-event-1",
    sequence: Int = 1,
    previousEventID: String? = nil,
    text: String = "source event"
) -> TimelineEvent {
    TimelineEvent(
        eventID: eventID, journal: localProjectionSourceJournal, sequence: sequence,
        previousEventID: previousEventID, actor: localProjectionSourceActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: TimelineEventType.messageCommitted,
        payload: .object(["text": .string(text)]))
}

private func localProjectionSourceLine(_ event: TimelineEvent) throws -> Data {
    try DisposableTimelineProjectionStore.canonicalJSON(event) + Data([UInt8(ascii: "\n")])
}

private struct LocalProjectionFixture {
    let root: URL
    let file: URL
    let lease: LocalTimelineProjectionSourceLease
    let event: TimelineEvent
    let line: Data
    let row: DisposableTimelineProjectionStore.BucketRow
    let challenge: DisposableTimelineProjectionStore.SourceValidationChallenge

    init(text: String = "source event", limits: LocalTimelineProjectionSourceLease.Limits = .default) throws {
        root = try localProjectionSourceRoot()
        file = root.appending(path: "journal.jsonl", directoryHint: .notDirectory)
        event = localProjectionSourceEvent(text: text)
        line = try localProjectionSourceLine(event)
        try line.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
        lease = LocalTimelineProjectionSourceLease(
            fileURL: file, journal: localProjectionSourceJournal, limits: limits)

        let seed = DisposableTimelineProjectionStore.canonicalPrefixSeed(
            for: localProjectionSourceJournal)
        let lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
        let after = DisposableTimelineProjectionStore.advancePrefixDigest(
            seed, lineDigest: lineDigest)
        row = DisposableTimelineProjectionStore.BucketRow(
            sequence: event.sequence, eventID: event.eventID,
            previousEventID: event.previousEventID,
            byteStart: 0, byteEnd: line.count,
            prefixDigestBefore: seed, prefixDigestAfter: after, lineDigest: lineDigest)

        let observed = try lease.observe().source
        let stored = DisposableTimelineProjectionStore.SourceFingerprint(
            journal: observed.journal, sourceID: observed.sourceID,
            sourceGeneration: observed.sourceGeneration, fingerprint: observed.fingerprint,
            sourceByteCount: line.count, prefixByteCount: line.count, prefixDigest: after)
        challenge = DisposableTimelineProjectionStore.SourceValidationChallenge(
            storedSource: stored,
            cursor: JournalCursor(
                journal: localProjectionSourceJournal, eventID: event.eventID,
                sequence: event.sequence),
            prefixSeed: .init(byteCount: 0, digest: seed), terminalRow: row)
    }

    func deletingRoot() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func localProjectionChallenge(
    fixture: LocalProjectionFixture,
    row: DisposableTimelineProjectionStore.BucketRow? = nil,
    cursorEventID: String? = nil,
    sourceByteCount: Int? = nil
) -> DisposableTimelineProjectionStore.SourceValidationChallenge {
    let selectedRow = row ?? fixture.row
    let source = fixture.challenge.storedSource
    let stored = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: source.journal, sourceID: source.sourceID,
        sourceGeneration: source.sourceGeneration, fingerprint: source.fingerprint,
        sourceByteCount: sourceByteCount ?? source.sourceByteCount,
        prefixByteCount: selectedRow.byteEnd,
        prefixDigest: selectedRow.prefixDigestAfter)
    return DisposableTimelineProjectionStore.SourceValidationChallenge(
        storedSource: stored,
        cursor: JournalCursor(
            journal: localProjectionSourceJournal,
            eventID: cursorEventID ?? selectedRow.eventID, sequence: selectedRow.sequence),
        prefixSeed: fixture.challenge.prefixSeed, terminalRow: selectedRow)
}

func testLocalProjectionSourceValidatesUnchangedAndAppendedJournal() throws {
    let fixture = try LocalProjectionFixture()
    defer { fixture.deletingRoot() }

    let validated = try fixture.lease.validateWithMetrics(fixture.challenge)
    XCTAssertEqual(validated.source.sourceByteCount, fixture.line.count)
    XCTAssertEqual(validated.source.prefixByteCount, fixture.line.count)
    XCTAssertEqual(validated.source.prefixDigest, fixture.row.prefixDigestAfter)
    XCTAssertEqual(validated.source.sourceID, fixture.challenge.storedSource.sourceID)
    XCTAssertEqual(validated.source.sourceGeneration, fixture.challenge.storedSource.sourceGeneration)
    XCTAssertTrue(validated.metrics.bytesRead <= 8 * 1_024 + fixture.line.count)
    XCTAssertTrue(validated.metrics.peakReadBytes <= max(4 * 1_024, fixture.line.count))

    let projectionStore = try DisposableTimelineProjectionStore(
        directory: fixture.root.appending(path: "projection", directoryHint: .isDirectory),
        journal: localProjectionSourceJournal)
    let committed = try projectionStore.commit(.init(
        source: fixture.challenge.storedSource,
        cursor: JournalCursor(
            journal: localProjectionSourceJournal, eventID: fixture.event.eventID, sequence: 1),
        prefixSeed: fixture.challenge.prefixSeed,
        nextSequence: 2,
        nextPreviousEventID: fixture.event.eventID,
        currentBucket: .init(bucketStart: 1, rows: [fixture.row])))
    let loaded = try projectionStore.load(validatingSource: { challenge in
        try fixture.lease.validate(challenge)
    })
    XCTAssertEqual(loaded.snapshot, committed)
    XCTAssertEqual(loaded.observedSource, fixture.challenge.storedSource)

    let handle = try FileHandle(forWritingTo: fixture.file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("unterminated suffix".utf8))
    try handle.close()
    do {
        _ = try fixture.lease.validate(fixture.challenge)
        XCTFail("lock-free validation must not infer that changed source bytes are append-only")
    } catch LocalTimelineProjectionSourceLease.Error.sourceChanged {
        XCTAssertTrue(true)
    }
    // The test fixture is the sole cooperating writer. Production callers may select this mode
    // only while holding TimelineJournalWriter's canonical owner lock across validation and the
    // subsequent suffix read.
    let appended = try fixture.lease.validateWithMetrics(
        fixture.challenge, growthPolicy: .cooperatingAppendOnlyOwnerLock).source
    XCTAssertEqual(appended.sourceByteCount, fixture.line.count + "unterminated suffix".utf8.count)
    XCTAssertEqual(appended.prefixByteCount, fixture.line.count)
    XCTAssertEqual(appended.prefixDigest, fixture.row.prefixDigestAfter)
    XCTAssertNotEqual(appended.fingerprint, fixture.challenge.storedSource.fingerprint)
    let appendedLoad = try projectionStore.load(validatingSource: { challenge in
        try fixture.lease.validateWithMetrics(
            challenge, growthPolicy: .cooperatingAppendOnlyOwnerLock).source
    })
    XCTAssertEqual(appendedLoad.snapshot, committed)
    XCTAssertEqual(appendedLoad.observedSource.sourceByteCount, appended.sourceByteCount)
}

func testLocalProjectionSourceRejectsShorterReplacementSymlinkAndInsecureFiles() throws {
    let fixture = try LocalProjectionFixture()
    defer { fixture.deletingRoot() }

    let truncated = try FileHandle(forWritingTo: fixture.file)
    try truncated.truncate(atOffset: UInt64(fixture.line.count - 1))
    try truncated.close()
    do {
        _ = try fixture.lease.validate(fixture.challenge)
        XCTFail("a source shorter than the stored prefix must fail closed")
    } catch LocalTimelineProjectionSourceLease.Error.sourceChanged {
        XCTAssertTrue(true)
    }

    try fixture.line.write(to: fixture.file, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fixture.file.path)
    let replacement = fixture.root.appending(path: "replacement.jsonl", directoryHint: .notDirectory)
    try fixture.line.write(to: replacement, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: replacement.path)
    try FileManager.default.removeItem(at: fixture.file)
    try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: replacement)
    do {
        _ = try fixture.lease.observe()
        XCTFail("a symlinked source must not be followed")
    } catch LocalTimelineProjectionSourceLease.Error.symlinkOrNonRegularFile {
        XCTAssertTrue(true)
    }

    try FileManager.default.removeItem(at: fixture.file)
    try fixture.line.write(to: fixture.file, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: fixture.file.path)
    do {
        _ = try fixture.lease.observe()
        XCTFail("group/world-readable source files must fail closed")
    } catch LocalTimelineProjectionSourceLease.Error.insecurePermissions {
        XCTAssertTrue(true)
    }
}

func testLocalProjectionSourceRejectsWrongTerminalBytesDigestIdentityAndPrefix() throws {
    let fixture = try LocalProjectionFixture()
    defer { fixture.deletingRoot() }

    var wrongDigest = fixture.row
    wrongDigest = .init(
        sequence: wrongDigest.sequence, eventID: wrongDigest.eventID,
        previousEventID: wrongDigest.previousEventID, byteStart: wrongDigest.byteStart,
        byteEnd: wrongDigest.byteEnd, prefixDigestBefore: wrongDigest.prefixDigestBefore,
        prefixDigestAfter: wrongDigest.prefixDigestAfter,
        lineDigest: String(repeating: "0", count: 64))
    do {
        _ = try fixture.lease.validate(localProjectionChallenge(fixture: fixture, row: wrongDigest))
        XCTFail("a terminal payload with the wrong canonical digest must fail")
    } catch LocalTimelineProjectionSourceLease.Error.invalidTerminal {
        XCTAssertTrue(true)
    }

    var wrongIdentity = fixture.row
    wrongIdentity = .init(
        sequence: wrongIdentity.sequence, eventID: "not-the-event",
        previousEventID: wrongIdentity.previousEventID, byteStart: wrongIdentity.byteStart,
        byteEnd: wrongIdentity.byteEnd, prefixDigestBefore: wrongIdentity.prefixDigestBefore,
        prefixDigestAfter: wrongIdentity.prefixDigestAfter, lineDigest: wrongIdentity.lineDigest)
    do {
        _ = try fixture.lease.validate(
            localProjectionChallenge(fixture: fixture, row: wrongIdentity, cursorEventID: "not-the-event"))
        XCTFail("a terminal payload with the wrong event identity must fail")
    } catch LocalTimelineProjectionSourceLease.Error.invalidTerminal {
        XCTAssertTrue(true)
    }

    var wrongPrefix = fixture.row
    wrongPrefix = .init(
        sequence: wrongPrefix.sequence, eventID: wrongPrefix.eventID,
        previousEventID: wrongPrefix.previousEventID, byteStart: wrongPrefix.byteStart,
        byteEnd: wrongPrefix.byteEnd, prefixDigestBefore: wrongPrefix.prefixDigestBefore,
        prefixDigestAfter: String(repeating: "1", count: 64), lineDigest: wrongPrefix.lineDigest)
    do {
        _ = try fixture.lease.validate(localProjectionChallenge(fixture: fixture, row: wrongPrefix))
        XCTFail("a terminal payload with the wrong prefix-after must fail")
    } catch LocalTimelineProjectionSourceLease.Error.invalidTerminal {
        XCTAssertTrue(true)
    }
}

func testLocalProjectionSourceKeepsReadsBoundedAndRejectsNonRegularPaths() throws {
    let limits = LocalTimelineProjectionSourceLease.Limits(
        maximumSourceBytes: 8 * 1_024 * 1_024,
        maximumBoundaryBytes: 64,
        maximumTerminalBytes: 256 * 1_024)
    let fixture = try LocalProjectionFixture(text: String(repeating: "x", count: 8_192), limits: limits)
    defer { fixture.deletingRoot() }
    let observed = try fixture.lease.observe()
    XCTAssertTrue(observed.metrics.bytesRead <= 2 * limits.maximumBoundaryBytes)
    XCTAssertTrue(observed.metrics.peakReadBytes <= limits.maximumBoundaryBytes)

    let directory = fixture.root.appending(path: "directory", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let directoryLease = LocalTimelineProjectionSourceLease(
        fileURL: directory, journal: localProjectionSourceJournal, limits: limits)
    do {
        _ = try directoryLease.observe()
        XCTFail("a directory must not be accepted as a canonical journal")
    } catch LocalTimelineProjectionSourceLease.Error.symlinkOrNonRegularFile {
        XCTAssertTrue(true)
    }
}

func testLocalProjectionSourceRejectsMismatchedJournalAndReplacementGeneration() throws {
    let fixture = try LocalProjectionFixture()
    defer { fixture.deletingRoot() }
    let foreignJournal = JournalRef.work(
        WorkRef(workHostID: localProjectionSourceHost.workHostID, workID: "foreign-work"),
        journalID: "foreign-journal")
    let foreignLease = LocalTimelineProjectionSourceLease(
        fileURL: fixture.file, journal: foreignJournal)
    do {
        _ = try foreignLease.validate(fixture.challenge)
        XCTFail("a challenge from another journal must not be accepted")
    } catch LocalTimelineProjectionSourceLease.Error.invalidChallenge {
        XCTAssertTrue(true)
    }

    let replacement = fixture.root.appending(path: "generation.jsonl", directoryHint: .notDirectory)
    try fixture.line.write(to: replacement, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: replacement.path)
    try FileManager.default.removeItem(at: fixture.file)
    try FileManager.default.moveItem(at: replacement, to: fixture.file)
    do {
        _ = try fixture.lease.validate(fixture.challenge)
        XCTFail("a replacement inode must not satisfy an old source generation")
    } catch LocalTimelineProjectionSourceLease.Error.invalidChallenge {
        XCTAssertTrue(true)
    }
}

func testLocalProjectionSourceRejectsUnprovenNonzeroSeedWithoutTerminal() throws {
    let fixture = try LocalProjectionFixture()
    defer { fixture.deletingRoot() }
    let observed = fixture.challenge.storedSource
    let seed = DisposableTimelineProjectionStore.canonicalPrefixSeed(
        for: localProjectionSourceJournal)
    let stored = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: observed.journal, sourceID: observed.sourceID,
        sourceGeneration: observed.sourceGeneration, fingerprint: observed.fingerprint,
        sourceByteCount: observed.sourceByteCount, prefixByteCount: 0, prefixDigest: seed)
    let unproven = DisposableTimelineProjectionStore.SourceValidationChallenge(
        storedSource: stored,
        cursor: JournalCursor(journal: localProjectionSourceJournal, eventID: nil, sequence: 256),
        prefixSeed: .init(
            byteCount: 0, digest: seed, sequence: 256, previousEventID: "event-256"),
        terminalRow: nil)
    do {
        _ = try fixture.lease.validate(unproven)
        XCTFail("a nonzero seed without a terminal byte proof must fail closed")
    } catch LocalTimelineProjectionSourceLease.Error.invalidChallenge {
        XCTAssertTrue(true)
    }
    let terminalClaim = DisposableTimelineProjectionStore.SourceValidationChallenge(
        storedSource: observed,
        cursor: fixture.challenge.cursor,
        prefixSeed: .init(
            byteCount: 1, digest: seed, sequence: 1, previousEventID: "seed-event"),
        terminalRow: fixture.challenge.terminalRow)
    do {
        _ = try fixture.lease.validate(terminalClaim)
        XCTFail("a terminal row must not authenticate an omitted nonzero prefix")
    } catch LocalTimelineProjectionSourceLease.Error.invalidChallenge {
        XCTAssertTrue(true)
    }
}

func testLocalProjectionSourceFingerprintChangesForSameSizeMiddleMutation() throws {
    let root = try localProjectionSourceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "multi.jsonl", directoryHint: .notDirectory)
    let e1 = localProjectionSourceEvent(
        eventID: "middle-event-1", sequence: 1,
        text: String(repeating: "a", count: 6_000))
    let e2 = localProjectionSourceEvent(
        eventID: "middle-event-2", sequence: 2, previousEventID: e1.eventID,
        text: String(repeating: "b", count: 6_000))
    let e3 = localProjectionSourceEvent(
        eventID: "middle-event-3", sequence: 3, previousEventID: e2.eventID,
        text: String(repeating: "c", count: 6_000))
    let events = [e1, e2, e3]
    let lines = try events.map(localProjectionSourceLine)
    let allBytes = lines.reduce(into: Data()) { $0.append($1) }
    try allBytes.write(to: file, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
    let lease = LocalTimelineProjectionSourceLease(
        fileURL: file, journal: localProjectionSourceJournal)

    var prefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(
        for: localProjectionSourceJournal)
    var offset = 0
    var rows: [DisposableTimelineProjectionStore.BucketRow] = []
    for (event, line) in zip(events, lines) {
        let lineDigest = try DisposableTimelineProjectionStore.canonicalEventLineDigest(event)
        let after = DisposableTimelineProjectionStore.advancePrefixDigest(
            prefix, lineDigest: lineDigest)
        rows.append(.init(
            sequence: event.sequence, eventID: event.eventID,
            previousEventID: event.previousEventID,
            byteStart: offset, byteEnd: offset + line.count,
            prefixDigestBefore: prefix, prefixDigestAfter: after, lineDigest: lineDigest))
        prefix = after
        offset += line.count
    }
    let observed = try lease.observe().source
    let terminal = rows[2]
    let stored = DisposableTimelineProjectionStore.SourceFingerprint(
        journal: observed.journal, sourceID: observed.sourceID,
        sourceGeneration: observed.sourceGeneration, fingerprint: observed.fingerprint,
        sourceByteCount: allBytes.count, prefixByteCount: terminal.byteEnd,
        prefixDigest: terminal.prefixDigestAfter)
    let challenge = DisposableTimelineProjectionStore.SourceValidationChallenge(
        storedSource: stored,
        cursor: JournalCursor(
            journal: localProjectionSourceJournal, eventID: terminal.eventID,
            sequence: terminal.sequence),
        prefixSeed: .init(
            byteCount: 0,
            digest: DisposableTimelineProjectionStore.canonicalPrefixSeed(
                for: localProjectionSourceJournal)),
        terminalRow: terminal)
    let original = try lease.validate(challenge)

    let middleOffset = lines[0].count + (try XCTUnwrap(lines[1].firstIndex(of: UInt8(ascii: "b"))))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seek(toOffset: UInt64(middleOffset))
    try handle.write(contentsOf: Data([UInt8(ascii: "d")]))
    try handle.close()

    do {
        _ = try lease.validate(challenge)
        XCTFail("strict validation must reject a same-size changed observation")
    } catch LocalTimelineProjectionSourceLease.Error.sourceChanged {
        XCTAssertTrue(true)
    }
    let changed = try lease.validateWithMetrics(
        challenge, growthPolicy: .cooperatingAppendOnlyOwnerLock).source
    XCTAssertEqual(changed.sourceByteCount, original.sourceByteCount)
    XCTAssertNotEqual(changed.fingerprint, original.fingerprint)
    XCTAssertEqual(changed.prefixByteCount, original.prefixByteCount)
}

let casesLocalTimelineProjectionSource: [Case] = [
    ("phase3 local projection source validates unchanged and appended journal", {
        try testLocalProjectionSourceValidatesUnchangedAndAppendedJournal()
    }),
    ("phase3 local projection source rejects shorter replacement symlink and insecure files", {
        try testLocalProjectionSourceRejectsShorterReplacementSymlinkAndInsecureFiles()
    }),
    ("phase3 local projection source rejects wrong terminal bytes digest identity and prefix", {
        try testLocalProjectionSourceRejectsWrongTerminalBytesDigestIdentityAndPrefix()
    }),
    ("phase3 local projection source keeps reads bounded and rejects nonregular paths", {
        try testLocalProjectionSourceKeepsReadsBoundedAndRejectsNonRegularPaths()
    }),
    ("phase3 local projection source rejects mismatched journal and replacement generation", {
        try testLocalProjectionSourceRejectsMismatchedJournalAndReplacementGeneration()
    }),
    ("phase3 local projection source rejects unproven nonzero seed without terminal", {
        try testLocalProjectionSourceRejectsUnprovenNonzeroSeedWithoutTerminal()
    }),
    ("phase3 local projection source fingerprint changes for same-size middle mutation", {
        try testLocalProjectionSourceFingerprintChangesForSameSizeMiddleMutation()
    }),
]
