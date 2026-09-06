import Foundation
@testable import AviaryCore

private let writerTestActor = TimelineActor(actorID: "writer-test", kind: "work-host")
private let writerTestWork = WorkRef(workHostID: "writer-host", workID: "writer-work")
private let writerTestWorkJournal = JournalRef.work(writerTestWork, journalID: "writer-work-journal")
private let writerTestSession = SessionRef("writer-session")
private let writerTestSessionJournal = JournalRef.session(
    writerTestSession, journalID: "writer-session-journal",
    authority: TimelineAuthorityRef("writer-service"))

private final class WriterTestSequence: @unchecked Sendable {
    private let mutex = NSLock()
    private var values: [String]

    init(_ values: [String]) { self.values = values }

    func next() -> String {
        mutex.lock()
        defer { mutex.unlock() }
        if values.isEmpty { return UUID().uuidString.lowercased() }
        return values.removeFirst()
    }
}

private final class WriterSyncProbe: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = 0

    func record() {
        mutex.lock()
        value += 1
        mutex.unlock()
    }

    var count: Int {
        mutex.lock()
        defer { mutex.unlock() }
        return value
    }
}

private func writerTestHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-timeline-writer-\(UUID().uuidString)",
                   directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AgentHome(root: root)
}

private func writerDraft(
    _ type: String = TimelineEventType.hostOrderObserved,
    session: SessionRef? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    links: [TimelineLink] = [],
    omittedEvidenceLinkCount: Int? = nil,
    payload: JSONValue = .object([:])
) -> TimelineEventDraft {
    TimelineEventDraft(
        session: session, work: work, workHost: workHost, type: type,
        links: links, omittedEvidenceLinkCount: omittedEvidenceLinkCount, payload: payload)
}

private func writerData(_ url: URL) throws -> Data {
    try Data(contentsOf: url)
}

private func writerEvents(
    _ data: Data, journal: JournalRef, actor: TimelineActor = writerTestActor
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        data, journal: journal, actor: actor, hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        throw TimelineJournalWriter.WriterError.invalidJournal(reason: "test fixture has a tail")
    }
    return read.records.map(\.event)
}

private func encodedWriterEvent(
    id: String,
    journal: JournalRef,
    sequence: Int,
    previous: String? = nil,
    session: SessionRef? = nil,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    schemaVersion: Int = TimelineEvent.currentSchemaVersion,
    provenance: TimelineEventProvenance = .native,
    type: String = TimelineEventType.hostOrderObserved
) throws -> Data {
    let event = TimelineEvent(
        eventID: id, journal: journal, sequence: sequence, previousEventID: previous,
        session: session, work: work, workHost: workHost, actor: writerTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
        schemaVersion: schemaVersion, type: type, provenance: provenance)
    var bytes = try JSONEncoder().encode(event)
    bytes.append(0x0A)
    return bytes
}

private func writeWriterFixture(_ data: Data, at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

private func writerRefusedReopen(at url: URL, journal: JournalRef) async -> Bool {
    do {
        let writer = try TimelineJournalWriter(
            reopening: url, journal: journal, actor: writerTestActor)
        try? await writer.closeChecked()
        return false
    } catch {
        return true
    }
}

private func writerReopenFailure(
    at url: URL, journal: JournalRef, home: AgentHome? = nil
) async -> TimelineJournalWriter.WriterError? {
    do {
        let writer = try TimelineJournalWriter(
            reopening: url, journal: journal, actor: writerTestActor, home: home)
        try? await writer.closeChecked()
        return nil
    } catch let error as TimelineJournalWriter.WriterError {
        return error
    } catch {
        XCTFail("unexpected reopen error: \(error)")
        return nil
    }
}

private func writerChildCanAcquireDataLock(_ url: URL) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c",
        "import fcntl, sys; f = open(sys.argv[1], 'r+'); "
            + "fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)",
        url.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private func writerSleepingChild() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import time; time.sleep(30)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
}

func test_timelineJournalWriterFreshBatchReopenAndReducer() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let url = home.timelineV2WorkJournalURL(writerTestWork)
    let ids = WriterTestSequence(["event-1", "event-2", "event-3"])
    let fixedDate = Date(timeIntervalSince1970: 1_234.5)
    let writer = try TimelineJournalWriter.createFresh(
        at: url, journal: writerTestWorkJournal, actor: writerTestActor,
        eventIDProvider: { ids.next() }, now: { fixedDate })
    XCTAssertEqual(writer.lockFileURL, home.timelineV2JournalLockURL(for: writerTestWorkJournal))

    let first = writerDraft(
        TimelineEventType.workCreated, work: writerTestWork,
        workHost: WorkHostRef(writerTestWork.workHostID))
    let second = writerDraft(
        omittedEvidenceLinkCount: 3, payload: .object(["n": .number(2)]))
    let commits = try await writer.appendBatch([first, second])
    XCTAssertEqual(commits.map(\.cursor.sequence), [1, 2])
    XCTAssertEqual(await writer.synchronizeCallCount, 2)
    XCTAssertEqual(commits[0].eventRef, EventRef(journal: writerTestWorkJournal, eventID: "event-1"))
    XCTAssertEqual(commits[1].cursor.journal, writerTestWorkJournal)
    try await writer.closeChecked()

    let data = try writerData(url)
    let events = try writerEvents(data, journal: writerTestWorkJournal)
    XCTAssertEqual(events.map(\.eventID), ["event-1", "event-2"])
    XCTAssertEqual(events.map(\.sequence), [1, 2])
    XCTAssertNil(events[0].previousEventID)
    XCTAssertEqual(events[1].previousEventID, events[0].eventID)
    XCTAssertEqual(events.map(\.actor), [writerTestActor, writerTestActor])
    XCTAssertEqual(events.map(\.hostRecordedAt), [fixedDate, fixedDate])
    XCTAssertEqual(events.map(\.schemaVersion), [2, 2])
    XCTAssertEqual(events.map(\.provenance), [.native, .native])
    XCTAssertEqual(events[1].omittedEvidenceLinkCount, 3)

    // The bytes are exactly the encoded native events plus one newline each, not a best-effort
    // text rendering. This also proves the reader can consume the fresh output.
    var expected = Data()
    for record in TimelineJournalReader.read(
        data, journal: writerTestWorkJournal, actor: writerTestActor,
        hostRecordedAt: fixedDate).records {
        expected.append(record.rawLineBytes)
    }
    XCTAssertEqual(data, expected)

    let reduced = WorkReducer.reduce(events)
    XCTAssertEqual(reduced.work, writerTestWork)
    XCTAssertEqual(reduced.workHost, WorkHostRef(writerTestWork.workHostID))
    XCTAssertEqual(reduced.lastSequence, 2)
    XCTAssertEqual(reduced.lastEventID, "event-2")
    XCTAssertTrue(reduced.structuralIntegrityValid)

    let reopened = try TimelineJournalWriter.reopenExisting(
        at: url, journal: writerTestWorkJournal, actor: TimelineActor(actorID: "reopened"),
        eventIDProvider: { ids.next() })
    let third = try await reopened.append(writerDraft())
    XCTAssertEqual(third.cursor.sequence, 3)
    XCTAssertEqual(third.eventRef.eventID, "event-3")
    try await reopened.closeChecked()
    let all = try writerEvents(try writerData(url), journal: writerTestWorkJournal)
    XCTAssertEqual(all.map(\.sequence), [1, 2, 3])
    XCTAssertEqual(all[2].previousEventID, "event-2")
}

func test_timelineJournalWriterValidatesIdentityAndEvidenceBeforeWriting() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }

    let workWriter = try TimelineJournalWriter(
        freshAt: home.timelineV2WorkJournalURL(writerTestWork),
        journal: writerTestWorkJournal, actor: writerTestActor,
        eventIDProvider: { "work-valid" })
    let foreignWork = WorkRef(workHostID: "foreign-host", workID: "foreign-work")
    let invalidWork = writerDraft(work: foreignWork)
    let invalidHost = writerDraft(
        work: writerTestWork, workHost: WorkHostRef("foreign-host"))
    let invalidHostWithoutWork = writerDraft(workHost: WorkHostRef(writerTestWork.workHostID))
    let evidence = TimelineLink(
        kind: .supports, target: EventRef(journal: writerTestSessionJournal, eventID: "e"))
    let tooManyLinks = writerDraft(links: Array(repeating: evidence, count: TimelineEvent.maxEvidenceLinks + 1))
    let zeroOmissions = writerDraft(omittedEvidenceLinkCount: 0)
    let excessiveOmissions = writerDraft(
        omittedEvidenceLinkCount: TimelineEvent.maxOmittedEvidenceLinkCount + 1)
    let invalidType = writerDraft(" \n\t")
    for draft in [
        invalidWork, invalidHost, invalidHostWithoutWork, tooManyLinks,
        zeroOmissions, excessiveOmissions, invalidType,
    ] {
        do {
            _ = try await workWriter.append(draft)
            XCTFail("invalid draft should be rejected")
        } catch { }
    }
    if case .healthy = await workWriter.health {
        XCTAssertTrue(true, "validation failures do not make a write ambiguous")
    } else {
        XCTFail("draft validation must happen before any write")
    }
    XCTAssertEqual(try writerData(workWriter.fileURL), Data())
    _ = try await workWriter.append(writerDraft(TimelineEventType.workCreated, work: writerTestWork))
    try await workWriter.closeChecked()

    // Session ownership is strict for Session, while Work may be a remote attachment. The
    // remote Work Host is intentionally not required to equal the Session authority.
    let sessionWriter = try TimelineJournalWriter(
        freshAt: home.timelineV2SessionJournalURL(writerTestSession),
        journal: writerTestSessionJournal, actor: writerTestActor,
        eventIDProvider: { "session-1" })
    let remote = WorkRef(workHostID: "remote-host", workID: "remote-work")
    _ = try await sessionWriter.append(writerDraft(
        TimelineEventType.sessionAttached, session: writerTestSession, work: remote))
    do {
        _ = try await sessionWriter.append(writerDraft(
            TimelineEventType.hostOrderObserved, session: SessionRef("foreign-session")))
        XCTFail("foreign Session identity should be rejected")
    } catch { }
    try await sessionWriter.closeChecked()
    let sessionEvents = try writerEvents(
        try writerData(sessionWriter.fileURL), journal: writerTestSessionJournal)
    XCTAssertEqual(sessionEvents.first?.work, remote)
    XCTAssertEqual(sessionEvents.first?.session, writerTestSession)
}

func test_timelineJournalWriterRefusesEmptyLegacyForeignCorruptAndNoncontiguousReopen() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let base = home.timelineV2WorkJournalURL(writerTestWork)

    let missing = base.appendingPathExtension("missing")
    XCTAssertTrue(await writerRefusedReopen(at: missing, journal: writerTestWorkJournal))

    let empty = base.appendingPathExtension("empty")
    try writeWriterFixture(Data(), at: empty)
    let emptyWriter = try TimelineJournalWriter(
        reopening: empty, journal: writerTestWorkJournal, actor: writerTestActor,
        home: home, eventIDProvider: { "empty-genesis" })
    XCTAssertEqual(await emptyWriter.nextSequenceNumber, 1)
    let emptyCommit = try await emptyWriter.append(writerDraft())
    XCTAssertEqual(emptyCommit.cursor.sequence, 1)
    try await emptyWriter.closeChecked()
    XCTAssertEqual(
        try writerEvents(try writerData(empty), journal: writerTestWorkJournal).map(\.eventID),
        ["empty-genesis"])

    let legacy = base.appendingPathExtension("legacy")
    try writeWriterFixture(Data("{\"type\":\"message\",\"id\":\"legacy\"}\n".utf8), at: legacy)
    XCTAssertTrue(await writerRefusedReopen(at: legacy, journal: writerTestWorkJournal))

    let corrupt = base.appendingPathExtension("corrupt")
    try writeWriterFixture(Data("{not-json}\n".utf8), at: corrupt)
    XCTAssertTrue(await writerRefusedReopen(at: corrupt, journal: writerTestWorkJournal))

    let valid = try encodedWriterEvent(
        id: "valid", journal: writerTestWorkJournal, sequence: 1,
        work: writerTestWork, workHost: WorkHostRef(writerTestWork.workHostID),
        type: TimelineEventType.workCreated)
    let truncated = base.appendingPathExtension("truncated")
    try writeWriterFixture(Data(valid.dropLast()), at: truncated)
    XCTAssertTrue(await writerRefusedReopen(at: truncated, journal: writerTestWorkJournal))

    let foreign = base.appendingPathExtension("foreign")
    let foreignJournal = JournalRef.work(
        WorkRef(workHostID: "other-host", workID: "other-work"), journalID: "other")
    try writeWriterFixture(
        try encodedWriterEvent(id: "foreign", journal: foreignJournal, sequence: 1),
        at: foreign)
    XCTAssertTrue(await writerRefusedReopen(at: foreign, journal: writerTestWorkJournal))

    let duplicate = base.appendingPathExtension("duplicate")
    var duplicateBytes = valid
    duplicateBytes.append(try encodedWriterEvent(
        id: "valid", journal: writerTestWorkJournal, sequence: 2, previous: "valid"))
    try writeWriterFixture(duplicateBytes, at: duplicate)
    XCTAssertTrue(await writerRefusedReopen(at: duplicate, journal: writerTestWorkJournal))

    let gap = base.appendingPathExtension("gap")
    var gapBytes = valid
    gapBytes.append(try encodedWriterEvent(
        id: "gap", journal: writerTestWorkJournal, sequence: 3, previous: "valid"))
    try writeWriterFixture(gapBytes, at: gap)
    XCTAssertTrue(await writerRefusedReopen(at: gap, journal: writerTestWorkJournal))

    let wrongOwner = base.appendingPathExtension("wrong-owner")
    try writeWriterFixture(
        try encodedWriterEvent(
            id: "wrong-owner", journal: writerTestWorkJournal, sequence: 1,
            work: foreignWorkForWriterTest(), type: TimelineEventType.workCreated),
        at: wrongOwner)
    let wrongOwnerError = await writerReopenFailure(
        at: wrongOwner, journal: writerTestWorkJournal, home: home)
    guard case .invalidJournal = wrongOwnerError else {
        XCTFail("wrong owner must be an invalidJournal, got \(String(describing: wrongOwnerError))")
        return
    }
}

private func foreignWorkForWriterTest() -> WorkRef {
    WorkRef(workHostID: "foreign-host", workID: "foreign-work")
}

func test_timelineJournalWriterLocksAndLatchesEveryFailureBoundary() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let url = home.timelineV2WorkJournalURL(writerTestWork)
    let first = try TimelineJournalWriter(
        freshAt: url, journal: writerTestWorkJournal, actor: writerTestActor,
        eventIDProvider: { "lock-1" })
    _ = try await first.append(writerDraft())
    XCTAssertTrue(await first.descriptorsCloseOnExec)
    XCTAssertFalse(
        try writerChildCanAcquireDataLock(url),
        "the journal inode must reject a writer in another process")
    let sleepingChild = try writerSleepingChild()
    defer {
        if sleepingChild.isRunning { sleepingChild.terminate() }
        sleepingChild.waitUntilExit()
    }
    XCTAssertTrue(sleepingChild.isRunning)
    do {
        _ = try TimelineJournalWriter(
            reopening: url, journal: writerTestWorkJournal, actor: writerTestActor)
        XCTFail("a competing writer must fail without waiting")
    } catch {
        XCTAssertTrue(error.localizedDescription.contains("held")
                      || error.localizedDescription.contains("already"))
    }
    try await first.closeChecked()
    XCTAssertTrue(
        try writerChildCanAcquireDataLock(url),
        "checked close must release the cross-process data lock")
    let afterRelease = try TimelineJournalWriter(
        reopening: url, journal: writerTestWorkJournal, actor: writerTestActor)
    XCTAssertTrue(
        sleepingChild.isRunning,
        "the inherited-descriptor regression requires the child to outlive writer close")
    try await afterRelease.closeChecked()

    for point in TimelineJournalWriter.FailurePoint.allCases
        where point != .close {
        let pointHome = try writerTestHome()
        let writer = try TimelineJournalWriter(
            freshAt: pointHome.timelineV2WorkJournalURL(writerTestWork),
            journal: writerTestWorkJournal, actor: writerTestActor,
            eventIDProvider: { "failure-\(point.rawValue)" })
        await writer.injectFailure(point)
        do {
            _ = try await writer.append(writerDraft())
            XCTFail("\(point.rawValue) must fail")
        } catch { }
        if case .failed = await writer.health {
            XCTAssertTrue(true)
        } else {
            XCTFail("\(point.rawValue) must latch unhealthy")
        }
        do {
            _ = try await writer.append(writerDraft())
            XCTFail("latched \(point.rawValue) writer must reject later appends")
        } catch { }
        let bytes = try writerData(writer.fileURL)
        if point == .partialWrite {
            XCTAssertFalse(bytes.last == 0x0A)
        } else if point == .beforeWrite {
            XCTAssertTrue(bytes.isEmpty)
        } else {
            XCTAssertTrue(bytes.last == 0x0A)
        }
        try? await writer.closeChecked()
        try? FileManager.default.removeItem(at: pointHome.root)
    }

    let closeHome = try writerTestHome()
    let closeURL = closeHome.timelineV2WorkJournalURL(writerTestWork)
    let closeWriter = try TimelineJournalWriter(
        freshAt: closeURL, journal: writerTestWorkJournal, actor: writerTestActor,
        eventIDProvider: { "close-1" })
    _ = try await closeWriter.append(writerDraft())
    await closeWriter.injectFailure(.close)
    do {
        try await closeWriter.closeChecked()
        XCTFail("injected close should report failure")
    } catch { }
    // Even a reported close failure must release the OS lock and close the descriptor.
    let reopened = try TimelineJournalWriter(
        reopening: closeURL, journal: writerTestWorkJournal, actor: writerTestActor)
    try await reopened.closeChecked()
    try? FileManager.default.removeItem(at: closeHome.root)
}

func test_timelineJournalWriterOwnerLockSurvivesJournalPathReplacement() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let url = home.timelineV2WorkJournalURL(writerTestWork)
    let alternateJournal = JournalRef.work(writerTestWork, journalID: "alternate-work-journal")
    XCTAssertEqual(
        home.timelineV2JournalLockURL(for: writerTestWorkJournal),
        home.timelineV2JournalLockURL(for: alternateJournal))

    let ids = WriterTestSequence(["replacement-1", "orphan-must-not-commit"])
    let first = try TimelineJournalWriter(
        freshAt: url, journal: writerTestWorkJournal, actor: writerTestActor, home: home,
        eventIDProvider: { ids.next() })
    _ = try await first.append(writerDraft())

    let ownerDirectory = url.deletingLastPathComponent()
    let parentDirectory = ownerDirectory.deletingLastPathComponent()
    let movedDirectory = parentDirectory.appending(
        path: "writer-work-moved", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: ownerDirectory, to: movedDirectory)
    try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
    try Data(contentsOf: movedDirectory.appending(path: "journal.jsonl"))
        .write(to: ownerDirectory.appending(path: "journal.jsonl"))

    do {
        _ = try TimelineJournalWriter(
            reopening: url, journal: alternateJournal, actor: writerTestActor, home: home)
        XCTFail("same owner must remain locked after its data path is replaced")
    } catch let error as TimelineJournalWriter.WriterError {
        guard case .competingWriter = error else {
            XCTFail("replacement lock should report competingWriter, got \(error)")
            return
        }
    }

    do {
        _ = try await first.append(writerDraft())
        XCTFail("the moved writer must not acknowledge an append on its orphaned inode")
    } catch let error as TimelineJournalWriter.WriterError {
        guard case .dataPathReplaced = error else {
            XCTFail("path replacement should be typed, got \(error)")
            return
        }
    }
    if case .failed = await first.health {
        XCTAssertTrue(true)
    } else {
        XCTFail("path replacement must latch writer failure")
    }
    try? await first.closeChecked()

    // The canonical replacement contains only the last verified prefix. Once the failed owner has
    // released both locks, the expected JournalRef can continue from that prefix without the
    // rejected orphan-inode append appearing in either branch.
    let canonical = try TimelineJournalWriter(
        reopening: url, journal: writerTestWorkJournal, actor: writerTestActor, home: home,
        eventIDProvider: { "replacement-2" })
    let continued = try await canonical.append(writerDraft())
    XCTAssertEqual(continued.cursor.sequence, 2)
    XCTAssertEqual(
        try writerEvents(
            try writerData(movedDirectory.appending(path: "journal.jsonl")),
            journal: writerTestWorkJournal).map(\.eventID),
        ["replacement-1"])
    try await canonical.closeChecked()

    let identityMismatch = await writerReopenFailure(at: url, journal: alternateJournal, home: home)
    guard case .invalidJournal = identityMismatch else {
        XCTFail("alternate JournalRef must fail closed, got \(String(describing: identityMismatch))")
        return
    }
}

func test_timelineJournalWriterReopensEmptyAfterFreshCrashWindow() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let url = home.timelineV2WorkJournalURL(writerTestWork)
    let fresh = try TimelineJournalWriter(
        freshAt: url, journal: writerTestWorkJournal, actor: writerTestActor, home: home)
    XCTAssertEqual(try writerData(url), Data())
    let foreignWork = WorkRef(workHostID: "foreign-host", workID: "foreign-work")
    let foreignJournal = JournalRef.work(foreignWork, journalID: "foreign-journal")
    let foreignError = await writerReopenFailure(at: url, journal: foreignJournal, home: home)
    guard case .competingWriter = foreignError else {
        XCTFail("an alternate owner must not reopen the same empty inode")
        return
    }
    // A crash immediately after fresh creation leaves this zero-event file. Closing here only
    // releases the test lock; recovery must treat the bytes as a valid genesis window.
    await fresh.close()

    let recovered = try TimelineJournalWriter(
        reopening: url, journal: writerTestWorkJournal, actor: writerTestActor, home: home,
        eventIDProvider: { "recovered-genesis" })
    let commit = try await recovered.append(writerDraft())
    XCTAssertEqual(commit.cursor.sequence, 1)
    try await recovered.closeChecked()
}

func test_timelineJournalRefPublicConstructionCannotTrap() throws {
    let work = WorkRef(workHostID: "ref-host", workID: "ref-work")
    do {
        _ = try JournalRef(
            journalID: "bad", authority: TimelineAuthorityRef("wrong-host"), owner: .work(work))
        XCTFail("mismatched Work authority must throw")
    } catch {
        guard case .workAuthorityMismatch(let expected, let actual) =
            error as? JournalRef.ConstructionError else {
            XCTFail("unexpected JournalRef construction error: \(error)")
            return
        }
        XCTAssertEqual(expected, "ref-host")
        XCTAssertEqual(actual, "wrong-host")
    }
    let valid = JournalRef.work(work, journalID: "valid")
    XCTAssertEqual(valid.authority.authorityID, work.workHostID)

    let delimiterBearingAuthority = JournalRef.session(
        SessionRef("c"), authority: TimelineAuthorityRef("a/kind:session/session:b"))
    let delimiterBearingSession = JournalRef.session(
        SessionRef("b/kind:session/session:c"), authority: TimelineAuthorityRef("a"))
    XCTAssertNotEqual(
        delimiterBearingAuthority.stableKey, delimiterBearingSession.stableKey,
        "structured journal identities must remain distinct when IDs contain key delimiters")

    let mismatchedWire = Data(
        #"{"authority":{"authorityID":"wrong-host"},"kind":"work","journal_id":"bad","owner":{"kind":"work","work_host_id":"ref-host","work_id":"ref-work"}}"#.utf8)
    do {
        _ = try JSONDecoder().decode(JournalRef.self, from: mismatchedWire)
        XCTFail("mismatched wire authority must fail decoding")
    } catch is DecodingError {
        XCTAssertTrue(true)
    }
}

func test_timelineJournalWriterDeterministicSeamsAndAgentHomeAuthority() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let traversal = home.timelineV2SessionJournalURL(sessionID: "../escape/\u{0}session")
    XCTAssertTrue(traversal.path.contains("/timeline-v2/sessions/"))
    XCTAssertFalse(traversal.path.contains("/../"))
    XCTAssertTrue(traversal.path.hasSuffix("/journal.jsonl"))
    XCTAssertEqual(
        home.timelineV2WorkJournalURL(workHostID: "host/a", workID: "..").lastPathComponent,
        "journal.jsonl")
    XCTAssertTrue(home.timelineV2WorkJournalURL(workHostID: "host/a", workID: "..").path
        .contains("/works/~2e2e/"))

    XCTAssertNil(home.persistedWorkHostID)
    let authority = try home.requirePersistedWorkHostID()
    XCTAssertEqual(authority, home.persistedWorkHostID)
    XCTAssertEqual(try home.requirePersistedWorkHost().workHostID, authority)
    // Creation publishes a complete record before the directory sync receipt is returned.
    XCTAssertEqual(
        try String(contentsOf: home.workHostIDFile, encoding: .utf8), authority + "\n")
    let nativeWorkURL = try home.timelineV2WorkJournalURL(workID: "native-work")
    XCTAssertTrue(nativeWorkURL.path.contains("/work-hosts/\(authority)/"))

    // Concurrent first-use callers must all observe the one value that won the exclusive
    // create-if-absent write.
    let raceRoot = FileManager.default.temporaryDirectory
        .appending(path: "aviary-timeline-host-race-\(UUID().uuidString)",
                   directoryHint: .isDirectory)
    let raceHome = AgentHome(root: raceRoot)
    let raceIDs = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
        for _ in 0..<8 {
            group.addTask { try? raceHome.requirePersistedWorkHostID() }
        }
        var values: [String?] = []
        for await value in group { values.append(value) }
        return values
    }
    XCTAssertEqual(Set(raceIDs.compactMap { $0 }).count, 1)
    XCTAssertEqual(raceIDs.compactMap { $0 }.first, raceHome.persistedWorkHostID)

    // A fallback may remain available to old compatibility callers, but native authority must
    // fail explicitly when the home cannot persist anything.
    let unwritable = AgentHome(root: URL(fileURLWithPath: "/dev/null/aviary-native-host"))
    XCTAssertTrue(unwritable.workHostID.hasPrefix("host-unpersisted-"))
    do {
        _ = try unwritable.requirePersistedWorkHostID()
        XCTFail("native authority must not accept the hashValue fallback")
    } catch { }
    try? FileManager.default.removeItem(at: raceRoot)

    let url = home.timelineV2WorkJournalURL(writerTestWork)
    let ids = WriterTestSequence(["deterministic-id"])
    let date = Date(timeIntervalSince1970: 42)
    let writer = try TimelineJournalWriter(
        freshAt: url, journal: writerTestWorkJournal, actor: writerTestActor,
        eventIDProvider: { ids.next() }, now: { date })
    let commit = try await writer.append(writerDraft())
    XCTAssertEqual(commit.eventRef.eventID, "deterministic-id")
    let event = try XCTUnwrap(try writerEvents(
        writerData(url), journal: writerTestWorkJournal).first)
    XCTAssertEqual(event.hostRecordedAt, date)
    XCTAssertEqual(event.actor, writerTestActor)
    try await writer.closeChecked()

    let probeHome = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: probeHome.root) }
    let probe = WriterSyncProbe()
    let probeWriter = try TimelineJournalWriter(
        freshAt: probeHome.timelineV2WorkJournalURL(writerTestWork),
        journal: writerTestWorkJournal, actor: writerTestActor, home: probeHome,
        didSynchronize: { probe.record() })
    _ = try await probeWriter.append(writerDraft())
    XCTAssertEqual(probe.count, 1)
    XCTAssertEqual(await probeWriter.synchronizeCallCount, 1)
    try await probeWriter.closeChecked()
    XCTAssertEqual(probe.count, 2)

    let sessionAlternative = JournalRef.session(
        writerTestSession, journalID: "alternative-session-journal",
        authority: TimelineAuthorityRef("alternative-service"))
    XCTAssertEqual(
        probeHome.timelineV2JournalLockURL(for: writerTestSessionJournal),
        probeHome.timelineV2JournalLockURL(for: sessionAlternative))

    let malformedHome = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: malformedHome.root) }
    try Data("malformed\nidentity".utf8).write(to: malformedHome.workHostIDFile)
    do {
        _ = try malformedHome.requirePersistedWorkHostID()
        XCTFail("malformed authority must fail closed")
    } catch let error as AgentHomeError {
        XCTAssertEqual(error, .invalidPersistedWorkHostID)
        XCTAssertEqual(
            try String(contentsOf: malformedHome.workHostIDFile, encoding: .utf8),
            "malformed\nidentity")
    }

    // Persisted authority is deliberately stricter than a trimmed display string. Reject path,
    // control, Unicode, and oversized values rather than allowing an external file to become the
    // Work Host authority for this home.
    let validUUID = "abcdefab-cdef-4abc-8def-abcdefabcdef"
    let malformedIdentities = [
        "not-host-\(validUUID)",
        "host-\(validUUID.uppercased())",
        " host-\(validUUID)",
        "host-\(validUUID) ",
        "host-\(validUUID)\nsecond",
        String(repeating: "é", count: 100), // 200 UTF-8 bytes before framing
    ]
    for identity in malformedIdentities {
        try Data((identity + "\n").utf8).write(to: malformedHome.workHostIDFile)
        do {
            _ = try malformedHome.requirePersistedWorkHostID()
            XCTFail("malformed persisted authority must fail closed: \(identity.debugDescription)")
        } catch let error as AgentHomeError {
            XCTAssertEqual(error, .invalidPersistedWorkHostID)
        }
    }

    // The reader has a bounded admission read: a hostile multi-megabyte authority record is
    // rejected without loading its complete contents into a String.
    let multiMegabyteAuthority = Data(repeating: 0x78, count: 4 * 1024 * 1024)
    try multiMegabyteAuthority.write(to: malformedHome.workHostIDFile)
    do {
        _ = try malformedHome.requirePersistedWorkHostID()
        XCTFail("oversized persisted authority must fail closed")
    } catch let error as AgentHomeError {
        XCTAssertEqual(error, .invalidPersistedWorkHostID)
    }
}

func test_timelineJournalWriterRejectsOversizedBatchBeforeWriting() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let url = home.timelineV2WorkJournalURL(writerTestWork)
    let ids = WriterTestSequence(["batch-small", "batch-oversized", "after-rejection"])
    let fixedDate = Date(timeIntervalSince1970: 1)
    let oversized = writerDraft(payload: .object([
        "body": .string(String(repeating: "x", count: 128)),
    ]))
    let boundaryEvent = TimelineEvent(
        eventID: "batch-oversized", journal: writerTestWorkJournal, sequence: 2,
        previousEventID: "batch-small", actor: writerTestActor, hostRecordedAt: fixedDate,
        type: oversized.type, declaredDomains: oversized.declaredDomains, provenance: .native,
        links: oversized.links, payload: oversized.payload)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let recordLimitWithoutNewline = try encoder.encode(boundaryEvent).count
    let writer = try TimelineJournalWriter(
        freshAt: url, journal: writerTestWorkJournal, actor: writerTestActor, home: home,
        eventIDProvider: { ids.next() }, now: { fixedDate },
        maximumRecordBytes: recordLimitWithoutNewline)

    do {
        _ = try await writer.appendBatch([writerDraft(), oversized])
        XCTFail("an oversized record must reject the complete batch before its first write")
    } catch let error as TimelineJournalWriter.WriterError {
        guard case .invalidDraft = error else {
            XCTFail("wrong oversized record error: \(error)")
            return
        }
    }
    XCTAssertEqual(try writerData(url), Data())
    XCTAssertEqual(await writer.nextSequenceNumber, 1)
    if case .healthy = await writer.health {
        XCTAssertTrue(true)
    } else {
        XCTFail("pre-write size rejection must leave the writer healthy")
    }

    let committed = try await writer.append(writerDraft())
    XCTAssertEqual(committed.cursor.sequence, 1)
    try await writer.closeChecked()
    let events = try TimelineJournalWriter.readNativeEventsStreaming(
        at: url, journal: writerTestWorkJournal, actor: writerTestActor,
        maximumChunkBytes: 7, maximumRecordBytes: recordLimitWithoutNewline)
    XCTAssertEqual(events.map(\.eventID), ["after-rejection"])

    let oversizedURL = url.appendingPathExtension("oversized-record")
    let oversizedEvent = TimelineEvent(
        eventID: "oversized-fixture", journal: writerTestWorkJournal, sequence: 1,
        work: writerTestWork, workHost: WorkHostRef(writerTestWork.workHostID),
        actor: writerTestActor, hostRecordedAt: Date(timeIntervalSince1970: 1),
        type: TimelineEventType.workCreated, provenance: .native,
        payload: .object(["body": .string(String(repeating: "x", count: 2_048))]))
    var oversizedBytes = try JSONEncoder().encode(oversizedEvent)
    oversizedBytes.append(UInt8(ascii: "\n"))
    try writeWriterFixture(oversizedBytes, at: oversizedURL)
    do {
        _ = try TimelineJournalWriter(
            reopeningStreaming: oversizedURL, journal: writerTestWorkJournal,
            actor: writerTestActor, home: home, maximumChunkBytes: 31,
            maximumRecordBytes: recordLimitWithoutNewline)
        XCTFail("streaming reopen must enforce the same configured record ceiling")
    } catch let error as TimelineJournalWriter.WriterError {
        guard case .invalidJournal = error else {
            XCTFail("wrong oversized reopen error: \(error)")
            return
        }
    }
}

func test_timelineJournalStreamingReadFencesSymlinkAndReplacement() async throws {
    let home = try writerTestHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let url = home.timelineV2WorkJournalURL(writerTestWork)
    let writer = try TimelineJournalWriter(
        freshAt: url, journal: writerTestWorkJournal, actor: writerTestActor, home: home,
        eventIDProvider: { "stable-read-event" })
    _ = try await writer.append(writerDraft(
        TimelineEventType.workCreated, work: writerTestWork,
        workHost: WorkHostRef(writerTestWork.workHostID)))
    try await writer.closeChecked()

    let symlink = url.appendingPathExtension("symlink")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
    do {
        _ = try TimelineJournalWriter.readNativeEventsStreaming(
            at: symlink, journal: writerTestWorkJournal, actor: writerTestActor)
        XCTFail("a symlink must not be accepted as canonical journal proof")
    } catch {
        XCTAssertTrue(true)
    }

    let moved = url.appendingPathExtension("opened-inode")
    var replaced = false
    do {
        _ = try TimelineJournalWriter.readNativeEventsStreaming(
            at: url, journal: writerTestWorkJournal, actor: writerTestActor,
            maximumChunkBytes: 8,
            afterReadChunk: { _ in
                guard !replaced else { return }
                replaced = true
                try FileManager.default.moveItem(at: url, to: moved)
                try FileManager.default.copyItem(at: moved, to: url)
            })
        XCTFail("a path replacement during proof collection must be rejected")
    } catch let error as TimelineJournalWriter.WriterError {
        guard case .dataPathReplaced = error else {
            XCTFail("wrong path replacement error: \(error)")
            return
        }
    }
    XCTAssertTrue(replaced)
}
