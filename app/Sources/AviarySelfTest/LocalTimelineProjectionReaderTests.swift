import Foundation
@testable import AviaryCore

private let localReaderHost = WorkHostRef("local-reader-host")
private let localReaderWork = WorkRef(
    workHostID: localReaderHost.workHostID, workID: "local-reader-work")
private let localReaderWorkJournal = JournalRef.work(
    localReaderWork, journalID: "local-reader-work-journal")
private let localReaderSession = SessionRef("local-reader-session")
private let localReaderSessionJournal = JournalRef.session(
    localReaderSession, journalID: "local-reader-session-journal",
    authority: TimelineAuthorityRef(localReaderHost.workHostID))
private let localReaderActor = TimelineActor(actorID: "local-reader-test", kind: "self-test")

private func localReaderRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-local-reader-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    return root
}

private func localReaderEvent(
    journal: JournalRef,
    sequence: Int,
    type: String,
    work: WorkRef? = nil,
    workHost: WorkHostRef? = nil,
    session: SessionRef? = nil,
    text: String? = nil,
    conversationParent: EventRef? = nil,
    role: String = "user"
) -> TimelineEvent {
    let prefix = String(journal.stableKey.prefix(1))
    let id = "\(prefix)-\(sequence)"
    var payload: [String: JSONValue] = [:]
    if let text { payload["text"] = .string(text) }
    if type == TimelineEventType.messageCommitted { payload["role"] = .string(role) }
    return TimelineEvent(
        eventID: id, journal: journal, sequence: sequence,
        previousEventID: sequence == 1 ? nil : "\(prefix)-\(sequence - 1)",
        conversationParent: conversationParent,
        session: session, work: work, workHost: workHost,
        actor: localReaderActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, payload: .object(payload))
}

private func localReaderLine(_ event: TimelineEvent) throws -> Data {
    try DisposableTimelineProjectionStore.canonicalJSON(event) + Data([UInt8(ascii: "\n")])
}

private func localReaderWrite(_ events: [TimelineEvent], to file: URL) throws {
    var bytes = Data()
    for event in events { bytes.append(try localReaderLine(event)) }
    try bytes.write(to: file, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
}

private func localReaderAppend(_ data: Data, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
}

private func localReaderDetailedEvent(
    sequence: Int,
    type: String,
    previous: String?,
    run: RunRef? = nil,
    action: ActionRef? = nil,
    session: SessionRef? = nil,
    attachment: SessionAttachmentRef? = nil,
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: "w-\(sequence)", journal: localReaderWorkJournal,
        sequence: sequence, previousEventID: previous,
        session: session, work: localReaderWork, workHost: localReaderHost,
        sessionAttachment: attachment, run: run, action: action,
        actor: localReaderActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, payload: payload)
}

private func localReaderWorkJournalValue() throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(localReaderWorkJournal)))
}

private func localReaderValueFiles(
    in directory: URL, containingRecordKind expectedKind: String
) throws -> [URL] {
    let values = directory.appending(
        path: "work-exact-state/values", directoryHint: .isDirectory)
    return try FileManager.default.contentsOfDirectory(atPath: values.path).compactMap { name in
        let url = values.appending(path: name)
        let envelope = JSONValue.parse(try Data(contentsOf: url))
        guard let encoded = envelope?["body"]?["bytes"]?.stringValue,
              let bytes = Data(base64Encoded: encoded),
              JSONValue.parse(bytes)?["kind"]?.stringValue == expectedKind else { return nil }
        return url
    }
}

private final class LocalReaderOneShotSaboteur: @unchecked Sendable {
    private let lock = NSLock()
    private var didSabotage = false

    func removeObjectsOnce(at directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !didSabotage else { return }
        didSabotage = true
        try? FileManager.default.removeItem(at: directory.appending(
            path: "objects", directoryHint: .isDirectory))
    }
}

private struct LocalReaderFixture {
    let root: URL
    let home: AgentHome
    let file: URL
    let journal: JournalRef
    let store: DisposableTimelineProjectionStore
    let reader: LocalTimelineProjectionReader

    init(
        journal: JournalRef = localReaderWorkJournal,
        events: [TimelineEvent],
        limits: LocalTimelineProjectionReader.Limits = .standard,
        storeLimits: DisposableTimelineProjectionStore.Limits = .default,
        storeObserver: (@Sendable (DisposableTimelineProjectionStore.AccessOperation) -> Void)? = nil
    ) throws {
        root = try localReaderRoot()
        home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(
            at: home.root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        self.journal = journal
        switch journal.owner {
        case .work(let work):
            file = home.timelineV2WorkJournalURL(work)
        case .session(let session):
            file = home.timelineV2SessionJournalURL(session)
        case .workHost:
            throw LocalTimelineProjectionReader.ReaderError.unsupportedJournal
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try localReaderWrite(events, to: file)
        store = try DisposableTimelineProjectionStore(
            directory: root.appending(path: "projection", directoryHint: .isDirectory),
            journal: journal, limits: storeLimits, observer: storeObserver)
        reader = try LocalTimelineProjectionReader(
            store: store, home: home, limits: limits)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func localReaderWorkEvents(count: Int, start: Int = 1) -> [TimelineEvent] {
    (start..<(start + count)).map { sequence in
        localReaderEvent(
            journal: localReaderWorkJournal, sequence: sequence,
            type: TimelineEventType.workCreated,
            work: localReaderWork, workHost: localReaderHost)
    }
}

func testLocalTimelineProjectionReaderColdProjection() throws {
    let initial = localReaderWorkEvents(count: 3)
    let fixture = try LocalReaderFixture(events: initial)
    defer { fixture.remove() }
    let cold = try fixture.reader.read()
    XCTAssertTrue(cold.didRebuild)
    XCTAssertFalse(cold.metrics.cacheHit)
    XCTAssertTrue(cold.metrics.rebuiltIndex)
    XCTAssertTrue(cold.metrics.reducerReplayedFromZero)
    XCTAssertEqual(cold.snapshot.cursor.sequence, 3)
    XCTAssertEqual(cold.reducerHead.work?.lastSequence, 3)
    XCTAssertEqual(cold.snapshot.source.prefixByteCount, cold.snapshot.source.sourceByteCount)
    XCTAssertEqual(cold.metrics.reducerReplayBytesRead, cold.snapshot.source.sourceByteCount)
    XCTAssertTrue(cold.metrics.peakBufferedBytes <= 64 * 1_024 + 1 * 1_024 * 1_024)
}

func testLocalTimelineProjectionReaderCacheAndGrowth() throws {
    let initial = localReaderWorkEvents(count: 3)
    let fixture = try LocalReaderFixture(events: initial)
    defer { fixture.remove() }
    let cold = try fixture.reader.read()
    let cached = try fixture.reader.read()
    XCTAssertFalse(cached.didRebuild)
    XCTAssertTrue(cached.metrics.cacheHit)
    XCTAssertFalse(cached.metrics.reducerReplayedFromZero)
    XCTAssertEqual(cached.snapshot.generation, cold.snapshot.generation)
    XCTAssertTrue(cached.metrics.bytesRead <= 4 * 1_024 * 1_024 + 8 * 1_024)

    let fourth = localReaderWorkEvents(count: 1, start: 4)[0]
    try localReaderAppend(try localReaderLine(fourth), to: fixture.file)
    let grown = try fixture.reader.read()
    XCTAssertTrue(grown.didRebuild)
    XCTAssertTrue(grown.metrics.rebuiltIndex)
    XCTAssertTrue(grown.metrics.reducerReplayedFromZero)
    XCTAssertEqual(grown.appendedEventCount, 1)
    XCTAssertEqual(grown.snapshot.cursor.sequence, 4)
    XCTAssertEqual(grown.reducerHead.work?.lastEventID, fourth.eventID)
    // Work now carries a content-addressed exact reducer checkpoint.  Growth still rebuilds
    // the bounded index from byte zero, but the semantic Work reducer advances from the proven
    // persisted boundary and must report that bounded suffix read.
    XCTAssertTrue(grown.metrics.suffixBytesRead > 0)
    XCTAssertEqual(grown.metrics.reducerReplayBytesRead, grown.metrics.suffixBytesRead)
}

func testLocalTimelineProjectionReaderCacheValidationIsBounded() throws {
    let fixture = try LocalReaderFixture(events: localReaderWorkEvents(count: 128))
    defer { fixture.remove() }
    let cold = try fixture.reader.read()
    let cached = try fixture.reader.read()
    XCTAssertTrue(cached.metrics.cacheHit)
    // Root/scalar authentication is intentionally bounded by trie depth, not historical value
    // count. Full reachable-object audits are a separate repair operation.
    XCTAssertTrue(cached.metrics.exactStateValidationObjectsRead <= 2)
    XCTAssertTrue(cached.metrics.exactStateValidationBytesRead < cold.snapshot.source.sourceByteCount)
    XCTAssertEqual(cached.metrics.decodedEventCount, 0)
}

func testLocalTimelineProjectionReaderRejectsMiddleRewriteFollowedByAppend() throws {
    let padding = String(repeating: "p", count: 6 * 1_024)
    let original = [
        localReaderDetailedEvent(
            sequence: 1, type: TimelineEventType.workCreated, previous: nil,
            payload: .object(["padding": .string(padding)])),
        localReaderDetailedEvent(
            sequence: 2, type: TimelineEventType.modelChanged, previous: "w-1",
            payload: .object(["model_id": .string("aaaaaaaa"),
                              "padding": .string(padding)])),
        localReaderDetailedEvent(
            sequence: 3, type: TimelineEventType.modelChanged, previous: "w-2",
            payload: .object(["model_id": .string("cccccccc"),
                              "padding": .string(padding)])),
    ]
    let fixture = try LocalReaderFixture(events: original)
    defer { fixture.remove() }
    let first = try fixture.reader.read()
    let oldSource = first.snapshot.source

    let replacement = localReaderDetailedEvent(
        sequence: 2, type: TimelineEventType.modelChanged, previous: "w-1",
        payload: .object(["model_id": .string("bbbbbbbb"),
                          "padding": .string(padding)]))
    let originalLine = try localReaderLine(original[1])
    let replacementLine = try localReaderLine(replacement)
    XCTAssertEqual(replacementLine.count, originalLine.count)
    let firstLineBytes = try localReaderLine(original[0]).count
    let handle = try FileHandle(forWritingTo: fixture.file)
    try handle.seek(toOffset: UInt64(firstLineBytes))
    try handle.write(contentsOf: replacementLine)
    try handle.synchronize()
    try handle.close()
    let appended = localReaderDetailedEvent(
        sequence: 4, type: TimelineEventType.modelChanged, previous: "w-3",
        payload: .object(["model_id": .string("dddddddd")]))
    try localReaderAppend(try localReaderLine(appended), to: fixture.file)

    do {
        _ = try fixture.reader.read()
        XCTFail("a rewritten historical middle cannot share a suffix exact-state root")
    } catch LocalTimelineProjectionReader.ReaderError.sourceChanged {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(try fixture.store.load(proving: oldSource).cursor, first.snapshot.cursor)
}

func testLocalTimelineProjectionReaderBoundsExactStateValidationBeforeReuse() throws {
    let session = SessionRef("deep-validation-session")
    let attachment = SessionAttachmentRef("deep-validation-attachment")
    let run = RunRef("deep-run")
    let action = ActionRef("deep-action")
    let initial = [
        localReaderDetailedEvent(
            sequence: 1, type: TimelineEventType.workCreated, previous: nil),
        localReaderDetailedEvent(
            sequence: 2, type: TimelineEventType.sessionAttached, previous: "w-1",
            session: session, attachment: attachment),
        localReaderDetailedEvent(
            sequence: 3, type: TimelineEventType.runStarted, previous: "w-2", run: run,
            session: session, attachment: attachment,
            payload: .object(["model_id": .string("deep-model")])),
        localReaderDetailedEvent(
            sequence: 4, type: TimelineEventType.actionIntent, previous: "w-3",
            run: run, action: action, session: session, attachment: attachment,
            payload: .object(["state": .string("proposed"),
                              "kind": .string("python"),
                              "intent": .string("deep validation")]))
    ]
    let fixture = try LocalReaderFixture(events: initial)
    defer { fixture.remove() }
    _ = try fixture.reader.read()
    let actionFile = try XCTUnwrap(localReaderValueFiles(
        in: fixture.store.directory, containingRecordKind: "action").first)
    try FileManager.default.removeItem(at: actionFile)

    let cached = try fixture.reader.read()
    XCTAssertTrue(cached.metrics.cacheHit)
    XCTAssertTrue(cached.metrics.exactStateValidationObjectsRead <= 2)
    XCTAssertTrue(cached.metrics.exactStateValidationBytesRead > 0)
    let fourth = localReaderDetailedEvent(
        sequence: 5, type: TimelineEventType.modelChanged, previous: "w-4",
        payload: .object(["model_id": .string("deep-model-2")]))
    try localReaderAppend(try localReaderLine(fourth), to: fixture.file)
    do {
        _ = try fixture.reader.read()
        XCTFail("publication must audit the missing historical value")
    } catch LocalTimelineProjectionReader.ReaderError.storeRejected {
        XCTAssertEqual(try fixture.store.load(proving: cached.source).cursor.sequence, 4)
    }
}

func testLocalTimelineProjectionReaderRecoversAbandonedFirstNamespaceAfterGrowth() throws {
    let root = try localReaderRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(
        at: home.root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let file = home.timelineV2WorkJournalURL(localReaderWork)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    try localReaderWrite(localReaderWorkEvents(count: 1), to: file)
    let storeDirectory = root.appending(path: "projection", directoryHint: .isDirectory)
    let saboteur = LocalReaderOneShotSaboteur()
    let store = try DisposableTimelineProjectionStore(
        directory: storeDirectory, journal: localReaderWorkJournal,
        observer: { operation in
            if operation == .writePayload {
                saboteur.removeObjectsOnce(at: storeDirectory)
            }
        })
    let reader = try LocalTimelineProjectionReader(store: store, home: home)
    do {
        _ = try reader.read()
        XCTFail("first publication sabotage should fail before HEAD")
    } catch {
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storeDirectory.appending(path: "HEAD").path))
    }

    let second = localReaderWorkEvents(count: 1, start: 2)[0]
    try localReaderAppend(try localReaderLine(second), to: file)
    let recovered = try reader.read()
    XCTAssertEqual(recovered.snapshot.generation, 1)
    XCTAssertEqual(recovered.snapshot.cursor.sequence, 2)
    XCTAssertNotNil(recovered.snapshot.exactStateCheckpoint)
}

func testLocalTimelineProjectionReaderContinuesStatefulActionFromExactRoot() throws {
    let session = SessionRef("stateful-session")
    let attachment = SessionAttachmentRef("stateful-attachment")
    let run = RunRef("stateful-run")
    let action = ActionRef("stateful-action")
    let initial = [
        localReaderDetailedEvent(
            sequence: 1, type: TimelineEventType.workCreated, previous: nil),
        localReaderDetailedEvent(
            sequence: 2, type: TimelineEventType.sessionAttached, previous: "w-1",
            session: session, attachment: attachment),
        localReaderDetailedEvent(
            sequence: 3, type: TimelineEventType.runStarted, previous: "w-2", run: run,
            session: session, attachment: attachment,
            payload: .object(["model_id": .string("stateful-model")])),
        localReaderDetailedEvent(
            sequence: 4, type: TimelineEventType.actionIntent, previous: "w-3",
            run: run, action: action, session: session, attachment: attachment,
            payload: .object(["state": .string("proposed"),
                              "kind": .string("python"),
                              "intent": .string("stateful continuation")]))
    ]
    let fixture = try LocalReaderFixture(events: initial)
    defer { fixture.remove() }
    _ = try fixture.reader.read()
    let started = localReaderDetailedEvent(
        sequence: 5, type: TimelineEventType.actionStarted, previous: "w-4",
        run: run, action: action, session: session, attachment: attachment,
        payload: .object(["state": .string("running")]))
    try localReaderAppend(try localReaderLine(started), to: fixture.file)
    let grown = try fixture.reader.read()
    XCTAssertEqual(grown.appendedEventCount, 1)
    XCTAssertTrue(grown.reducerHead.work?.activeActionIDs.contains(action.actionID) == true)
    let checkpoint = try XCTUnwrap(
        try fixture.store.loadExactStateCheckpoint(proving: grown.snapshot.source))
    let map = try PersistentProjectionRadixMap(
        directory: fixture.store.directory.appending(
            path: "work-exact-state", directoryHint: .isDirectory),
        namespaceID: grown.snapshot.namespaceID, journal: localReaderWorkJournal,
        sourceGeneration: grown.snapshot.source.sourceGeneration,
        mapKind: "work-exact-v7")
    let state = try PersistentWorkExactState(map: map, root: checkpoint.roots[0].root)
    let outcome = localReaderDetailedEvent(
        sequence: 6, type: TimelineEventType.actionOutcome, previous: "w-5",
        run: run, action: action, session: session, attachment: attachment,
        payload: .object(["state": .string("succeeded"),
                          "retry_safety": .string("idempotent")]))
    var continued = state
    let result = try continued.apply(outcome)
    XCTAssertFalse(result.eventLocalSnapshot.activeActionIDs.contains(action.actionID))
    XCTAssertEqual(result.eventLocalSnapshot.actions[action.actionID]?.state, .succeeded)
}

func testLocalTimelineProjectionReaderBucketBoundary() throws {
    // A 256-row boundary seals exactly one bucket; the next row belongs to the current bucket.
    let boundaryRoot = try localReaderRoot()
    let boundaryHome = AgentHome(root: boundaryRoot.appending(path: "home", directoryHint: .isDirectory))
    try FileManager.default.createDirectory(
        at: boundaryHome.root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let boundaryFile = boundaryHome.timelineV2WorkJournalURL(localReaderWork)
    try FileManager.default.createDirectory(
        at: boundaryFile.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let boundaryEvents = localReaderWorkEvents(count: 257)
    try localReaderWrite(boundaryEvents, to: boundaryFile)
    let boundaryStore = try DisposableTimelineProjectionStore(
        directory: boundaryRoot.appending(path: "projection", directoryHint: .isDirectory),
        journal: localReaderWorkJournal)
    let boundaryReader = try LocalTimelineProjectionReader(
        store: boundaryStore, home: boundaryHome)
    let boundary = try boundaryReader.read()
    XCTAssertEqual(boundary.snapshot.sealedBucketCount, 1)
    XCTAssertEqual(boundary.snapshot.currentBucket?.rowCount, 1)
    XCTAssertEqual(boundary.snapshot.cursor.sequence, 257)
    try? FileManager.default.removeItem(at: boundaryRoot)
}

func testLocalTimelineProjectionReaderRejectsMalformedTailAndReplacementWithoutPublishing() throws {
    let initial = localReaderWorkEvents(count: 2)
    let fixture = try LocalReaderFixture(events: initial)
    defer { fixture.remove() }
    let first = try fixture.reader.read()
    let oldSource = first.snapshot.source

    try localReaderAppend(Data("{\"not\":\"an event\"}\n".utf8), to: fixture.file)
    do {
        _ = try fixture.reader.read()
        XCTFail("malformed growth must fail closed")
    } catch LocalTimelineProjectionReader.ReaderError.malformedLine {
        XCTAssertTrue(true)
    } catch {
        XCTFail("unexpected malformed-tail error: \(error)")
    }
    XCTAssertEqual(try fixture.store.load(proving: oldSource).cursor.sequence, 2)

    // Replacing the file changes its physical generation even when the content is valid.
    try localReaderWrite(initial, to: fixture.file)
    do {
        _ = try fixture.reader.read()
        XCTFail("replacement source must not publish over the old cache")
    } catch LocalTimelineProjectionReader.ReaderError.sourceChanged {
        XCTAssertTrue(true)
    }
    XCTAssertEqual(try fixture.store.load(proving: oldSource).cursor.sequence, 2)
}

func testLocalTimelineProjectionReaderStreamsWorkAndSessionWithBoundedMetrics() throws {
    let workFixture = try LocalReaderFixture(events: localReaderWorkEvents(count: 8))
    defer { workFixture.remove() }
    let work = try workFixture.reader.read()

    let sessionEvents = [
        localReaderEvent(
            journal: localReaderSessionJournal, sequence: 1,
            type: TimelineEventType.sessionCreated, session: localReaderSession),
        localReaderEvent(
            journal: localReaderSessionJournal, sequence: 2,
            type: TimelineEventType.messageCommitted, session: localReaderSession,
            text: "bounded session message"),
    ]
    let sessionFixture = try LocalReaderFixture(
        journal: localReaderSessionJournal, events: sessionEvents)
    defer { sessionFixture.remove() }
    let session = try sessionFixture.reader.read()

    XCTAssertEqual(work.snapshot.cursor.sequence, session.snapshot.cursor.sequence + 6)
    XCTAssertEqual(work.reducerHead.work?.lastSequence, 8)
    XCTAssertEqual(session.reducerHead.session?.lastSequence, 2)
    XCTAssertEqual(session.reducerHead.session?.messageHistory.count, 1)
    XCTAssertTrue(work.metrics.bytesRead >= work.metrics.decodedEventCount)
    XCTAssertTrue(session.metrics.peakBufferedBytes <= 64 * 1_024 + 1 * 1_024 * 1_024)
    XCTAssertTrue(work.metrics.readCalls <= work.metrics.bytesRead)
    XCTAssertTrue(session.metrics.reducerReplayBytesRead <= session.metrics.bytesRead)
}

func testLocalTimelineProjectionReaderPublishesAndContinuesExactSessionState() throws {
    let initial = [
        localReaderEvent(
            journal: localReaderSessionJournal, sequence: 1,
            type: TimelineEventType.sessionCreated, session: localReaderSession),
        localReaderEvent(
            journal: localReaderSessionJournal, sequence: 2,
            type: TimelineEventType.inputAccepted, session: localReaderSession,
            text: "session reader private prefix"),
    ]
    let fixture = try LocalReaderFixture(
        journal: localReaderSessionJournal, events: initial)
    defer { fixture.remove() }
    let cold = try fixture.reader.read()
    let checkpoint = try XCTUnwrap(
        try fixture.store.loadExactStateCheckpoint(proving: cold.snapshot.source))
    XCTAssertEqual(checkpoint.roots.count, 1)
    XCTAssertEqual(checkpoint.roots.first?.mapKind, "session-exact-v1")
    XCTAssertEqual(checkpoint.cursor, cold.snapshot.cursor)
    XCTAssertEqual(cold.reducerHead.session?.messageHistory.count, 1)
    XCTAssertEqual(cold.reducerHead.session?.messageHistory.first?.text.byteCount,
                   "session reader private prefix".utf8.count)
    XCTAssertTrue(cold.reducerHead.session?.messageHistory.first?.text.digest.hasPrefix("sha256:") == true)

    let appended = localReaderEvent(
        journal: localReaderSessionJournal, sequence: 3,
        type: TimelineEventType.messageCommitted, session: localReaderSession,
        text: "session reader private suffix")
    try localReaderAppend(try localReaderLine(appended), to: fixture.file)
    let grown = try fixture.reader.read()
    XCTAssertEqual(grown.appendedEventCount, 1)
    XCTAssertTrue(grown.metrics.suffixBytesRead > 0)
    XCTAssertEqual(grown.reducerHead.session?.messageHistory.count, 2)
    XCTAssertEqual(grown.reducerHead.session?.messageHistory.last?.text.byteCount,
                   "session reader private suffix".utf8.count)

    let reopened = try LocalTimelineProjectionReader(
        store: fixture.store, home: fixture.home).read()
    XCTAssertTrue(reopened.metrics.cacheHit)
    XCTAssertEqual(reopened.reducerHead.session?.messageHistory.count, 2)
    XCTAssertTrue(reopened.metrics.exactStateValidationObjectsRead > 0)
}

func testLocalTimelineProjectionReaderLinearSessionGrowthBeyondExactPrefetchBound() throws {
    let prefix = String(localReaderSessionJournal.stableKey.prefix(1))
    var initial: [TimelineEvent] = [localReaderEvent(
        journal: localReaderSessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: localReaderSession)]
    for sequence in 2...260 {
        let parent = sequence == 2 ? nil : EventRef(
            journal: localReaderSessionJournal, eventID: "\(prefix)-\(sequence - 1)")
        initial.append(localReaderEvent(
            journal: localReaderSessionJournal, sequence: sequence,
            type: sequence == 2 ? TimelineEventType.inputAccepted : TimelineEventType.messageCommitted,
            session: localReaderSession,
            text: sequence == 2 ? "linear-session-root" : "",
            conversationParent: parent,
            role: "assistant"))
    }
    let fixture = try LocalReaderFixture(
        journal: localReaderSessionJournal, events: initial,
        storeLimits: .init(maximumReducerHeadBytes: 512 * 1_024))
    defer { fixture.remove() }
    let cold = try fixture.reader.read()
    XCTAssertEqual(cold.snapshot.cursor.sequence, 260)
    XCTAssertEqual(cold.reducerHead.session?.messageHistory.count, 259)
    XCTAssertNotNil(cold.snapshot.exactStateCheckpoint)

    let appended = localReaderEvent(
        journal: localReaderSessionJournal, sequence: 261,
        type: TimelineEventType.messageCommitted, session: localReaderSession,
        text: "",
        conversationParent: EventRef(journal: localReaderSessionJournal, eventID: "\(prefix)-260"),
        role: "assistant")
    try localReaderAppend(try localReaderLine(appended), to: fixture.file)
    let grown = try fixture.reader.read()
    XCTAssertEqual(grown.snapshot.cursor.sequence, 261)
    XCTAssertEqual(grown.appendedEventCount, 1)
    XCTAssertTrue(grown.metrics.suffixBytesRead > 0)
    XCTAssertEqual(grown.metrics.decodedEventCount, 1)
    XCTAssertEqual(grown.metrics.reducerReplayBytesRead, grown.metrics.suffixBytesRead)
    XCTAssertFalse(grown.metrics.reducerReplayedFromZero)
    XCTAssertEqual(grown.reducerHead.session?.messageHistory.count, 260)

    let reopened = try LocalTimelineProjectionReader(
        store: fixture.store, home: fixture.home).read()
    XCTAssertTrue(reopened.metrics.cacheHit)
    XCTAssertEqual(reopened.reducerHead.session?.messageHistory.count, 260)

    // The selected node is older than the physical tail. A cold reader reopen must authenticate
    // that target from its exact SeenRecord/MessageRecord without walking the 259-message chain.
    let olderTip = localReaderEvent(
        journal: localReaderSessionJournal, sequence: 262,
        type: TimelineEventType.sessionTipSelected, session: localReaderSession,
        conversationParent: EventRef(journal: localReaderSessionJournal, eventID: "\(prefix)-259"))
    try localReaderAppend(try localReaderLine(olderTip), to: fixture.file)
    let tipped = try LocalTimelineProjectionReader(
        store: fixture.store, home: fixture.home).read()
    XCTAssertEqual(tipped.snapshot.cursor.sequence, 262)
    XCTAssertEqual(tipped.appendedEventCount, 1)
    XCTAssertEqual(tipped.metrics.decodedEventCount, 1)
    XCTAssertEqual(tipped.reducerHead.session?.semanticTip?.eventID, "\(prefix)-259")
}

func testLocalTimelineProjectionReaderSessionGrowthScalesPrefixAuthNotSuffixReduction() throws {
    let body = String(repeating: "SESSION-LARGE-BODY-", count: 5_000)
    func receipt(prefixMessageCount: Int) throws -> (
        sourceBytes: Int, suffixBytes: Int, replayBytes: Int, decodedEvents: Int,
        peakRecentBytes: Int, prefixAuthBytes: Int, appended: Int, metadata: Data
    ) {
        let prefix = String(localReaderSessionJournal.stableKey.prefix(1))
        var events: [TimelineEvent] = [localReaderEvent(
            journal: localReaderSessionJournal, sequence: 1,
            type: TimelineEventType.sessionCreated, session: localReaderSession)]
        for sequence in 2...(prefixMessageCount + 1) {
            let parent = sequence == 2 ? nil : EventRef(
                journal: localReaderSessionJournal, eventID: "\(prefix)-\(sequence - 1)")
            events.append(localReaderEvent(
                journal: localReaderSessionJournal, sequence: sequence,
                type: sequence == 2 ? TimelineEventType.inputAccepted : TimelineEventType.messageCommitted,
                session: localReaderSession, text: body, conversationParent: parent,
                role: "assistant"))
        }
        let fixture = try LocalReaderFixture(
            journal: localReaderSessionJournal, events: events,
            storeLimits: .init(maximumReducerHeadBytes: 2 * 1_024 * 1_024))
        defer { fixture.remove() }
        let cold = try fixture.reader.read()
        let nextSequence = prefixMessageCount + 2
        let suffix = localReaderEvent(
            journal: localReaderSessionJournal, sequence: nextSequence,
            type: TimelineEventType.messageCommitted, session: localReaderSession, text: body,
            conversationParent: EventRef(
                journal: localReaderSessionJournal, eventID: "\(prefix)-\(nextSequence - 1)"),
            role: "assistant")
        let suffixLine = try localReaderLine(suffix)
        try localReaderAppend(suffixLine, to: fixture.file)
        let grown = try fixture.reader.read()
        let metadata = try XCTUnwrap(grown.reducerHead.session).encodedMetadata()
        XCTAssertEqual(grown.appendedEventCount, 1)
        XCTAssertEqual(grown.metrics.suffixBytesRead, suffixLine.count)
        XCTAssertEqual(grown.reducerHead.session?.messageHistory.count, prefixMessageCount + 1)
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains(body))
        return (
            cold.snapshot.source.sourceByteCount, grown.metrics.suffixBytesRead,
            grown.metrics.reducerReplayBytesRead, grown.metrics.decodedEventCount,
            grown.metrics.peakRecentEventBytes,
            grown.metrics.prefixAuthenticationBytesRead, grown.appendedEventCount, metadata)
    }

    let n = try receipt(prefixMessageCount: 32)
    let twoN = try receipt(prefixMessageCount: 64)
    // Session growth authenticates the cached prefix through bounded lease evidence and decodes
    // exactly one suffix event. The suffix line is identical-sized here; any prefix-related work
    // is exposed separately rather than being counted as reducer replay.
    XCTAssertEqual(n.suffixBytes, twoN.suffixBytes)
    XCTAssertEqual(n.appended, 1)
    XCTAssertEqual(twoN.appended, 1)
    XCTAssertEqual(n.replayBytes, n.suffixBytes)
    XCTAssertEqual(twoN.replayBytes, twoN.suffixBytes)
    XCTAssertEqual(twoN.replayBytes, n.replayBytes)
    XCTAssertEqual(n.decodedEvents, 1)
    XCTAssertEqual(twoN.decodedEvents, 1)
    XCTAssertEqual(twoN.peakRecentBytes, n.peakRecentBytes)
    XCTAssertEqual(twoN.prefixAuthBytes, n.prefixAuthBytes)
    XCTAssertTrue(n.prefixAuthBytes > 0)
    XCTAssertTrue(twoN.sourceBytes > n.sourceBytes * 18 / 10)
}

func testLocalTimelineProjectionReaderStructuralSessionQuarantineReopens() throws {
    let prefix = String(localReaderSessionJournal.stableKey.prefix(1))
    let initial = [
        localReaderEvent(
            journal: localReaderSessionJournal, sequence: 1,
            type: TimelineEventType.sessionCreated, session: localReaderSession),
        // SessionReducerTransition quarantines this before stageSeenEvent, so the physical
        // source cursor advances while the exact scalar cursor remains at sequence one.
        localReaderEvent(
            journal: localReaderSessionJournal, sequence: 2,
            type: TimelineEventType.modelChanged, session: SessionRef("foreign")),
    ]
    let fixture = try LocalReaderFixture(
        journal: localReaderSessionJournal, events: initial)
    defer { fixture.remove() }
    let cold = try fixture.reader.read()
    XCTAssertEqual(cold.snapshot.cursor.sequence, 2)
    XCTAssertEqual(cold.reducerHead.session?.lastSequence, 2)
    XCTAssertEqual(cold.reducerHead.session?.coverage.corruptionCount, 1)
    XCTAssertFalse(cold.reducerHead.session?.structuralIntegrityValid ?? true)
    XCTAssertNotNil(cold.snapshot.exactStateCheckpoint)

    let continued = localReaderEvent(
        journal: localReaderSessionJournal, sequence: 3,
        type: TimelineEventType.modelChanged, session: localReaderSession)
    try localReaderAppend(try localReaderLine(continued), to: fixture.file)
    let grown = try fixture.reader.read()
    XCTAssertEqual(grown.snapshot.cursor.sequence, 3)
    XCTAssertEqual(grown.reducerHead.session?.coverage.corruptionCount, 2)
    XCTAssertFalse(grown.reducerHead.session?.structuralIntegrityValid ?? true)
    let reopened = try LocalTimelineProjectionReader(
        store: fixture.store, home: fixture.home).read()
    XCTAssertTrue(reopened.metrics.cacheHit)
    XCTAssertEqual(reopened.reducerHead.session?.lastSequence, 3)
    XCTAssertEqual(reopened.reducerHead.session?.coverage.corruptionCount, 2)
    XCTAssertEqual(reopened.reducerHead.session?.lastEventID, "\(prefix)-3")
}

func testLocalTimelineProjectionReaderCannotEraseExactStateWithRootlessHead() throws {
    let events = localReaderWorkEvents(count: 3)
    let fixture = try LocalReaderFixture(events: events)
    defer { fixture.remove() }
    let current = try fixture.reader.read().snapshot
    let bucket = try fixture.store.loadBucket(
        containingSequence: current.cursor.sequence, proving: current.source)
    let foreignSource = BoundedReducerProjectionSource(
        journal: current.source.journal,
        cursor: current.cursor,
        sourceID: "foreign-source",
        sourceGeneration: current.source.sourceGeneration,
        sourceFingerprint: current.source.fingerprint,
        sourceByteCount: current.source.sourceByteCount,
        prefixByteCount: current.source.prefixByteCount,
        prefixDigest: current.source.prefixDigest)
    let foreignHead = try BoundedWorkReducerHead.build(
        events: events, source: foreignSource).opaqueReducerHead()
    do {
        _ = try fixture.store.commit(.init(
            source: current.source, cursor: current.cursor,
            prefixSeed: current.prefixSeed,
            nextSequence: current.nextSequence,
            nextPreviousEventID: current.nextPreviousEventID,
            currentBucket: bucket,
            anchors: current.anchors,
            reducerHead: foreignHead,
            pendingAcknowledgements: current.pendingAcknowledgements,
            expectedGeneration: current.generation))
        XCTFail("a root-bearing Work cache must not be replaced by a rootless reducer head")
    } catch DisposableTimelineProjectionStore.StoreError.invalidCommit(
        .invalidExactStateCheckpoint
    ) {
        XCTAssertTrue(true)
    } catch {
        XCTFail("unexpected exact-state preservation error: \(error)")
    }
}

func testLocalTimelineProjectionReaderFramesAndRetainsRecentRowsLinearly() throws {
    var events = localReaderWorkEvents(count: 20)
    events[0] = localReaderEvent(
        journal: localReaderWorkJournal, sequence: 1,
        type: TimelineEventType.workCreated,
        work: localReaderWork, workHost: localReaderHost,
        text: String(repeating: "x", count: 4_096))
    let fixture = try LocalReaderFixture(
        events: events,
        limits: .init(
            maximumChunkBytes: 17, maximumLineBytes: 8_192,
            maximumSeenEventIDs: 100, maximumIndexedRows: 100,
            maximumRecentPageEvents: 4, maximumRecentEventBytes: 16 * 1_024,
            maximumBootstrapSourceBytes: 64 * 1_024))
    defer { fixture.remove() }

    let result = try fixture.reader.read()
    XCTAssertEqual(
        result.metrics.newlineBytesExamined,
        result.snapshot.source.sourceByteCount,
        "newline framing must inspect each index-pass source byte exactly once")
    XCTAssertTrue(result.metrics.newlineBytesExamined <= result.metrics.bytesRead)
    XCTAssertTrue(result.metrics.peakRecentEventBytes <= 16 * 1_024)
    let recent = try result.snapshot.recentPages.flatMap {
        try fixture.store.loadRecentPage(id: $0.pageID, proving: result.snapshot.source).events
    }
    XCTAssertEqual(recent.map(\.sequence), [17, 18, 19, 20])
    XCTAssertTrue(result.snapshot.recentEventsOmitted)

    let bounded = try LocalReaderFixture(
        events: localReaderWorkEvents(count: 1),
        limits: .init(maximumBootstrapSourceBytes: 128))
    defer { bounded.remove() }
    do {
        _ = try bounded.reader.read()
        XCTFail("the in-memory bootstrap reducer must have an aggregate source-byte bound")
    } catch LocalTimelineProjectionReader.ReaderError.sourceTooLarge {
        XCTAssertTrue(true)
    }
}

func testLocalTimelineProjectionReaderEmptyWork() throws {
    let empty = try LocalReaderFixture(journal: localReaderWorkJournal, events: [])
    defer { empty.remove() }
    let cold = try empty.reader.read()
    XCTAssertEqual(cold.snapshot.cursor.sequence, 0)
    XCTAssertNil(cold.snapshot.cursor.eventID)
    XCTAssertNil(cold.snapshot.currentBucket)
    XCTAssertTrue(cold.snapshot.recentPages.isEmpty)
    XCTAssertFalse(cold.snapshot.recentEventsOmitted)
    XCTAssertNil(cold.snapshot.exactStateCheckpoint)
    XCTAssertTrue(try empty.reader.read().metrics.cacheHit)
}

func testLocalTimelineProjectionReaderEmptySession() throws {
    let empty = try LocalReaderFixture(journal: localReaderSessionJournal, events: [])
    defer { empty.remove() }
    let cold = try empty.reader.read()
    XCTAssertEqual(cold.snapshot.cursor.sequence, 0)
    XCTAssertNil(cold.snapshot.cursor.eventID)
    XCTAssertNil(cold.snapshot.currentBucket)
    XCTAssertTrue(cold.snapshot.recentPages.isEmpty)
    XCTAssertFalse(cold.snapshot.recentEventsOmitted)
    XCTAssertNil(cold.snapshot.exactStateCheckpoint)
    XCTAssertTrue(try empty.reader.read().metrics.cacheHit)
}

func testLocalTimelineProjectionReaderBucketBoundaryGrowth() throws {
    let boundary = try LocalReaderFixture(events: localReaderWorkEvents(count: 255))
    defer { boundary.remove() }
    let before = try boundary.reader.read()
    XCTAssertEqual(before.snapshot.currentBucket?.rowCount, 255)
    XCTAssertEqual(before.snapshot.sealedBucketCount, 0)

    try localReaderAppend(
        try localReaderLine(localReaderWorkEvents(count: 1, start: 256)[0]),
        to: boundary.file)
    let sealed = try boundary.reader.read()
    XCTAssertEqual(sealed.snapshot.cursor.sequence, 256)
    XCTAssertNil(sealed.snapshot.currentBucket)
    XCTAssertEqual(sealed.snapshot.sealedBucketCount, 1)

    try localReaderAppend(
        try localReaderLine(localReaderWorkEvents(count: 1, start: 257)[0]),
        to: boundary.file)
    let after = try boundary.reader.read()
    XCTAssertEqual(after.snapshot.cursor.sequence, 257)
    XCTAssertEqual(after.snapshot.currentBucket?.rowCount, 1)
    XCTAssertEqual(after.snapshot.sealedBucketCount, 1)
}

func testLocalTimelineProjectionReaderRecentRichEventsRespectByteBudget() throws {
    let events = (1...12).map { sequence in
        localReaderEvent(
            journal: localReaderWorkJournal, sequence: sequence,
            type: TimelineEventType.workCreated,
            work: localReaderWork, workHost: localReaderHost,
            text: String(repeating: Character(UnicodeScalar(96 + sequence)!), count: 1_024))
    }
    let byteBudget = 4 * 1_024
    let fixture = try LocalReaderFixture(
        events: events,
        limits: .init(
            maximumChunkBytes: 113, maximumLineBytes: 4 * 1_024,
            maximumSeenEventIDs: 100, maximumIndexedRows: 100,
            maximumRecentPageEvents: 20, maximumRecentEventBytes: byteBudget,
            maximumBootstrapSourceBytes: 64 * 1_024))
    defer { fixture.remove() }

    let result = try fixture.reader.read()
    XCTAssertTrue(result.metrics.peakRecentEventBytes <= byteBudget)
    let recent = try result.snapshot.recentPages.flatMap {
        try fixture.store.loadRecentPage(id: $0.pageID, proving: result.snapshot.source).events
    }
    let retainedBytes = try recent.reduce(into: 0) { total, event in
        total += try localReaderLine(event).count
    }
    XCTAssertTrue(retainedBytes <= byteBudget)
    XCTAssertEqual(recent.last?.sequence, 12)
    XCTAssertTrue(recent.count < events.count)
    XCTAssertTrue(result.snapshot.recentEventsOmitted)
}

func testLocalTimelineProjectionReaderPublishesAndContinuesExactWorkState() throws {
    let fixture = try LocalReaderFixture(events: localReaderWorkEvents(count: 3))
    defer { fixture.remove() }

    let cold = try fixture.reader.read()
    let coldCheckpoint = try XCTUnwrap(
        try fixture.store.loadExactStateCheckpoint(proving: cold.snapshot.source))
    XCTAssertEqual(coldCheckpoint.cursor, cold.snapshot.cursor)
    XCTAssertEqual(coldCheckpoint.prefixByteCount, cold.snapshot.source.prefixByteCount)
    XCTAssertEqual(coldCheckpoint.prefixDigest, cold.snapshot.source.prefixDigest)
    XCTAssertEqual(coldCheckpoint.roots.count, 1)
    XCTAssertEqual(coldCheckpoint.roots[0].mapKind, "work-exact-v7")
    XCTAssertEqual(coldCheckpoint.roots[0].namespaceID, cold.snapshot.namespaceID)

    let fourth = localReaderWorkEvents(count: 1, start: 4)[0]
    let fourthBytes = try localReaderLine(fourth)
    try localReaderAppend(fourthBytes, to: fixture.file)
    let grown = try fixture.reader.read()
    let grownCheckpoint = try XCTUnwrap(
        try fixture.store.loadExactStateCheckpoint(proving: grown.snapshot.source))
    XCTAssertEqual(grownCheckpoint.cursor, grown.snapshot.cursor)
    XCTAssertEqual(grownCheckpoint.cursor.sequence, 4)
    XCTAssertNotEqual(grownCheckpoint.roots[0].objectID, coldCheckpoint.roots[0].objectID)
    XCTAssertTrue(grown.metrics.suffixBytesRead > 0)
    XCTAssertEqual(grown.metrics.suffixBytesRead, fourthBytes.count)
    XCTAssertTrue(grown.metrics.bytesRead > grown.metrics.suffixBytesRead)

    let map = try PersistentProjectionRadixMap(
        directory: fixture.store.directory.appending(
            path: "work-exact-state", directoryHint: .isDirectory),
        namespaceID: grown.snapshot.namespaceID,
        journal: localReaderWorkJournal,
        sourceGeneration: grown.snapshot.source.sourceGeneration,
        mapKind: "work-exact-v7")
    try map.validate(root: grownCheckpoint.roots[0].root)
    let state = try PersistentWorkExactState(
        map: map, root: grownCheckpoint.roots[0].root)
    XCTAssertEqual(state.eventLocalSnapshot.lastSequence, 4)
    XCTAssertEqual(state.eventLocalSnapshot.lastEventID, fourth.eventID)
}

func testLocalTimelineProjectionReaderRebuildsObsoleteWorkState(previousVersion: Int) throws {
    let session = SessionRef("reader-v2-session")
    let attachment = SessionAttachmentRef("reader-v2-attachment")
    let client = ClientRef("reader-v2-client")
    let command = CommandRef(
        commandID: "reader-v2-end", client: client, sessionAttachment: attachment,
        causalCursor: JournalCursor(
            journal: localReaderWorkJournal, eventID: "w-2", sequence: 2))
    let events = [
        localReaderDetailedEvent(
            sequence: 1, type: TimelineEventType.workCreated, previous: nil),
        localReaderDetailedEvent(
            sequence: 2, type: TimelineEventType.sessionAttached, previous: "w-1",
            session: session, attachment: attachment),
        TimelineEvent(
            eventID: "w-3", journal: localReaderWorkJournal, sequence: 3,
            hostSequence: 3, idempotencyKey: command.commandID, command: command,
            previousEventID: "w-2",
            causedByEventID: EventRef(journal: localReaderWorkJournal, eventID: "w-2"),
            session: session, work: localReaderWork, workHost: localReaderHost,
            client: client, sessionAttachment: attachment,
            actor: localReaderActor, hostRecordedAt: Date(timeIntervalSince1970: 3),
            type: TimelineEventType.commandAccepted,
            payload: .object([
                "command_kind": .string("end_run"),
                "delivery_mode": .string(RunInputDeliveryMode.queued.rawValue),
                "carries_session_input": .bool(false),
            ])),
    ]
    let sourceFixture = try LocalReaderFixture(events: events)
    defer { sourceFixture.remove() }
    let canonicalJournalBytes = try Data(contentsOf: sourceFixture.file)
    let current = try sourceFixture.reader.read()
    let currentBucket = try sourceFixture.store.loadBucket(
        containingSequence: current.snapshot.cursor.sequence, proving: current.source)
    let recentPages = try current.snapshot.recentPages.map {
        try sourceFixture.store.loadRecentPage(id: $0.pageID, proving: current.source)
    }
    let currentHead = try sourceFixture.store.loadReducerHead(proving: current.source)
    var legacyHeadObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: currentHead) as? [String: Any])
    legacyHeadObject["schemaVersion"] = previousVersion
    let legacyHead = try JSONSerialization.data(
        withJSONObject: legacyHeadObject, options: [.sortedKeys])

    // This is intentionally an obsolete disposable-cache fixture, not a second implementation
    // of an obsolete reducer. The reader must identify the prior map generation before validating its
    // typed root, discard the projection, and derive current semantics from the unchanged journal.
    let legacyDirectory = sourceFixture.root.appending(
        path: "legacy-projection", directoryHint: .isDirectory)
    let legacyKind = "work-exact-v\(previousVersion)"
    let legacyNamespace = legacyKind + "." + String(repeating: "a", count: 64)
    let legacyStore = try DisposableTimelineProjectionStore(
        directory: legacyDirectory, journal: localReaderWorkJournal)
    let legacyMap = try PersistentProjectionRadixMap(
        directory: legacyDirectory.appending(
            path: "work-exact-state", directoryHint: .isDirectory),
        namespaceID: legacyNamespace, journal: localReaderWorkJournal,
        sourceGeneration: current.source.sourceGeneration, mapKind: legacyKind)
    let legacyRoot = try XCTUnwrap(try legacyMap.setting(
        root: nil, key: legacyKind + "/scalar", value: Data("obsolete-scalar".utf8)).newRoot)
    let legacyCheckpoint = DisposableTimelineProjectionStore.ExactStateCheckpoint(
        namespaceID: legacyNamespace, journal: localReaderWorkJournal,
        sourceGeneration: current.source.sourceGeneration,
        cursor: current.snapshot.cursor,
        prefixByteCount: current.source.prefixByteCount,
        prefixDigest: current.source.prefixDigest,
        roots: [.init(root: legacyRoot)])
    let legacyCommit = DisposableTimelineProjectionStore.Commit(
        source: current.source, cursor: current.snapshot.cursor,
        prefixSeed: current.snapshot.prefixSeed,
        nextSequence: current.snapshot.nextSequence,
        nextPreviousEventID: current.snapshot.nextPreviousEventID,
        currentBucket: currentBucket, anchors: current.snapshot.anchors,
        recentPages: recentPages,
        reducerHead: .init(
            mediaType: BoundedWorkReducerHead.mediaType, schemaVersion: previousVersion,
            bytes: legacyHead),
        exactStateCheckpoint: legacyCheckpoint)
    _ = try legacyStore.commit(
        legacyCommit, validatingExactStateCheckpoint: { _, _ in })

    let migrated = try LocalTimelineProjectionReader(
        store: legacyStore, home: sourceFixture.home).read()
    XCTAssertTrue(migrated.didRebuild)
    XCTAssertFalse(migrated.metrics.cacheHit)
    XCTAssertEqual(try Data(contentsOf: sourceFixture.file), canonicalJournalBytes)
    XCTAssertEqual(migrated.snapshot.generation, 1)
    XCTAssertNotEqual(migrated.snapshot.namespaceID, legacyNamespace)
    let migratedCheckpoint = try XCTUnwrap(
        try legacyStore.loadExactStateCheckpoint(proving: migrated.source))
    XCTAssertEqual(migratedCheckpoint.roots.first?.mapKind, "work-exact-v7")
    let migratedMap = try PersistentProjectionRadixMap(
        directory: legacyDirectory.appending(
            path: "work-exact-state", directoryHint: .isDirectory),
        namespaceID: migrated.snapshot.namespaceID, journal: localReaderWorkJournal,
        sourceGeneration: migrated.source.sourceGeneration, mapKind: "work-exact-v7")
    var migratedState = try PersistentWorkExactState(
        map: migratedMap, root: try XCTUnwrap(migratedCheckpoint.roots.first).root)
    let delivered = TimelineEvent(
        eventID: "w-4", journal: localReaderWorkJournal, sequence: 4,
        hostSequence: 4, command: command, previousEventID: "w-3",
        causedByEventID: EventRef(journal: localReaderWorkJournal, eventID: "w-3"),
        session: session, work: localReaderWork, workHost: localReaderHost,
        client: client, sessionAttachment: attachment,
        actor: localReaderActor, hostRecordedAt: Date(timeIntervalSince1970: 4),
        type: TimelineEventType.commandDelivered)
    let continued = try migratedState.apply(delivered)
    XCTAssertEqual(
        continued.eventLocalSnapshot.commands[command.commandID]?.commandKind, .endRun)
}

func testLocalTimelineProjectionReaderPersistsChildAndRecoveryAcrossGrowth() throws {
    let session = SessionRef("reader-child-recovery-session")
    let attachment = SessionAttachmentRef("reader-child-recovery-attachment")
    let run = RunRef("reader-child-recovery-run")
    let initial = [
        localReaderDetailedEvent(sequence: 1, type: TimelineEventType.workCreated, previous: nil),
        localReaderDetailedEvent(sequence: 2, type: TimelineEventType.sessionAttached, previous: "w-1",
                                  session: session, attachment: attachment),
        localReaderDetailedEvent(
            sequence: 3, type: TimelineEventType.childLifecycle, previous: "w-2",
            payload: .object(["child_id": .string("reader-child"), "state": .string("running")])),
        localReaderDetailedEvent(
            sequence: 4, type: TimelineEventType.runStarted, previous: "w-3", run: run,
            session: session, attachment: attachment,
            payload: .object(["model_id": .string("reader-recovery-model")])),
        localReaderDetailedEvent(
            sequence: 5, type: TimelineEventType.recoveryCoverage, previous: "w-4", run: run,
            session: session, attachment: attachment,
            payload: .object([
                "operation": .string("cold_resume"),
                "planes": .object(["timeline": .string("preserved")]),
                "work_journal": try localReaderWorkJournalValue(),
                "caveats": .array([.string("PRIVATE-READER-CAVEAT")])
            ]))
    ]
    let fixture = try LocalReaderFixture(events: initial)
    defer { fixture.remove() }
    let cold = try fixture.reader.read()
    XCTAssertEqual(cold.snapshot.cursor.sequence, 5)
    XCTAssertEqual(cold.reducerHead.work?.children.first?.childID, "reader-child")
    XCTAssertEqual(cold.reducerHead.work?.recovery.first?.operation, .coldResume)
    XCTAssertEqual(cold.reducerHead.work?.recovery.first?.caveatCount, 1)

    let grownEvent = localReaderDetailedEvent(
        sequence: 6, type: TimelineEventType.childLifecycle, previous: "w-5", run: run,
        payload: .object(["child_id": .string("reader-child"), "state": .string("done")]))
    try localReaderAppend(try localReaderLine(grownEvent), to: fixture.file)
    let grown = try fixture.reader.read()
    XCTAssertEqual(grown.snapshot.cursor.sequence, 6)
    XCTAssertEqual(grown.reducerHead.work?.children.first?.state, .done)
    XCTAssertEqual(grown.reducerHead.work?.recovery.first?.caveatCount, 1)

    let reopenedReader = try LocalTimelineProjectionReader(
        store: fixture.store, home: fixture.home)
    let cached = try reopenedReader.read()
    XCTAssertTrue(cached.metrics.cacheHit)
    XCTAssertEqual(cached.reducerHead.work?.children.first?.state, .done)
    XCTAssertEqual(cached.reducerHead.work?.recovery.first?.operation, .coldResume)
    XCTAssertTrue(cached.metrics.exactStateValidationObjectsRead > 0)
    XCTAssertTrue(cached.metrics.exactStateValidationBytesRead > 0)
}

let casesLocalTimelineProjectionReader: [Case] = [
    ("phase3 local projection reader: cold projection", {
        try testLocalTimelineProjectionReaderColdProjection()
    }),
    ("phase3 local projection reader: cache and growth", {
        try testLocalTimelineProjectionReaderCacheAndGrowth()
    }),
    ("phase3 local projection reader: cache validation stays bounded", {
        try testLocalTimelineProjectionReaderCacheValidationIsBounded()
    }),
    ("phase3 local projection reader: middle rewrite plus append stays unpublished", {
        try testLocalTimelineProjectionReaderRejectsMiddleRewriteFollowedByAppend()
    }),
    ("phase3 local projection reader: exact state is deeply available before reuse", {
        try testLocalTimelineProjectionReaderBoundsExactStateValidationBeforeReuse()
    }),
    ("phase3 local projection reader: abandoned first namespace recovers after growth", {
        try testLocalTimelineProjectionReaderRecoversAbandonedFirstNamespaceAfterGrowth()
    }),
    ("phase3 local projection reader: stateful action continues from exact root", {
        try testLocalTimelineProjectionReaderContinuesStatefulActionFromExactRoot()
    }),
    ("phase3 local projection reader: bucket boundary", {
        try testLocalTimelineProjectionReaderBucketBoundary()
    }),
    ("phase3 local projection reader: malformed tail and replacement stay unpublished", {
        try testLocalTimelineProjectionReaderRejectsMalformedTailAndReplacementWithoutPublishing()
    }),
    ("phase3 local projection reader: Work and Session bounded streaming parity", {
        try testLocalTimelineProjectionReaderStreamsWorkAndSessionWithBoundedMetrics()
    }),
    ("phase3 local projection reader: Session exact state publishes and continues", {
        try testLocalTimelineProjectionReaderPublishesAndContinuesExactSessionState()
    }),
    ("phase3 local projection reader: linear Session growth and deep tips stay bounded", {
        try testLocalTimelineProjectionReaderLinearSessionGrowthBeyondExactPrefetchBound()
    }),
    ("phase3 local projection reader: Session growth scales prefix auth separately from suffix", {
        try testLocalTimelineProjectionReaderSessionGrowthScalesPrefixAuthNotSuffixReduction()
    }),
    ("phase3 local projection reader: structural Session quarantine reopens", {
        try testLocalTimelineProjectionReaderStructuralSessionQuarantineReopens()
    }),
    ("phase3 local projection reader: exact state cannot be erased", {
        try testLocalTimelineProjectionReaderCannotEraseExactStateWithRootlessHead()
    }),
    ("phase3 local projection reader: line framing and recent retention are linear", {
        try testLocalTimelineProjectionReaderFramesAndRetainsRecentRowsLinearly()
    }),
    ("phase3 local projection reader: empty Work stays exact", {
        try testLocalTimelineProjectionReaderEmptyWork()
    }),
    ("phase3 local projection reader: child and recovery survive growth and reopen", {
        try testLocalTimelineProjectionReaderPersistsChildAndRecoveryAcrossGrowth()
    }),
    ("phase3 local projection reader: empty Session stays exact", {
        try testLocalTimelineProjectionReaderEmptySession()
    }),
    ("phase3 local projection reader: empty bucket growth stays exact", {
        try testLocalTimelineProjectionReaderBucketBoundaryGrowth()
    }),
    ("phase3 local projection reader: rich recent events obey byte budget", {
        try testLocalTimelineProjectionReaderRecentRichEventsRespectByteBudget()
    }),
    ("phase3 local projection reader: Work exact state publishes and continues", {
        try testLocalTimelineProjectionReaderPublishesAndContinuesExactWorkState()
    }),
    ("phase3 local projection reader: v2 Work exact state rebuilds native End kind", {
        try testLocalTimelineProjectionReaderRebuildsObsoleteWorkState(previousVersion: 2)
    }),
    ("phase3 local projection reader: v3 Work exact state rebuilds agent Handle semantics", {
        try testLocalTimelineProjectionReaderRebuildsObsoleteWorkState(previousVersion: 3)
    }),
    ("phase5 local projection reader: v4 Work exact state rebuilds cancellation proof", {
        try testLocalTimelineProjectionReaderRebuildsObsoleteWorkState(previousVersion: 4)
    }),
    ("phase5 local projection reader: v5 Work exact state rebuilds optional deadline", {
        try testLocalTimelineProjectionReaderRebuildsObsoleteWorkState(previousVersion: 5)
    }),
    ("phase3 local projection reader rebuilds pre-settlement Work cache", {
        try testLocalTimelineProjectionReaderRebuildsObsoleteWorkState(previousVersion: 6)
    }),
]
