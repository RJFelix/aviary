import Foundation
@testable import AviaryCore

private let controlTestHost = WorkHostRef("control-test-host")
private let controlTestWork = WorkRef(workHostID: controlTestHost.workHostID, workID: "control-work")
private let controlTestWorkJournal = JournalRef.work(controlTestWork, journalID: "work-generation-1")
private let controlTestSession = SessionRef("control-session-1")
private let controlTestSessionJournal = JournalRef.session(
    controlTestSession, journalID: "session-journal",
    authority: TimelineAuthorityRef("session-service"))
private let controlTestAttachment = ClientAttachmentRef("client-attachment-1")
private let controlTestClient = ClientRef("client-1")
private let controlTestSessionAttachment = SessionAttachmentRef("session-attachment-1")
private let controlTestActor = TimelineActor(actorID: "control-test", kind: "work-host")

private func controlTestJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

private func controlTestPayload(
    workJournal: JournalRef = controlTestWorkJournal,
    sessionJournal: JournalRef? = nil,
    capabilities: Set<String>? = nil,
    targetJournal: JournalRef? = nil,
    cursor: JournalCursor? = nil
) -> JSONValue {
    var object: [String: JSONValue] = ["work_journal": controlTestJSON(workJournal)]
    if let sessionJournal { object["session_journal"] = controlTestJSON(sessionJournal) }
    if let capabilities {
        object["capabilities"] = .array(capabilities.sorted().map { .string($0) })
    }
    if let targetJournal { object["target_journal"] = controlTestJSON(targetJournal) }
    if let cursor { object["cursor"] = controlTestJSON(cursor) }
    return .object(object)
}

private func controlTestEvent(
    _ type: String,
    id: String,
    sequence: Int,
    previous: String? = nil,
    journal: JournalRef = JournalRef.workHost(controlTestHost),
    work: WorkRef? = controlTestWork,
    workHost: WorkHostRef? = controlTestHost,
    client: ClientRef? = controlTestClient,
    session: SessionRef? = nil,
    sessionAttachment: SessionAttachmentRef? = nil,
    clientAttachment: ClientAttachmentRef? = controlTestAttachment,
    hostSequence: Int? = nil,
    payload: JSONValue = .object([:]),
    declaredDomains: Set<TimelineDomain> = [.work]
) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: journal, sequence: sequence, hostSequence: hostSequence,
        previousEventID: previous, session: session, work: work, workHost: workHost,
        client: client, sessionAttachment: sessionAttachment,
        clientAttachment: clientAttachment, actor: controlTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)), type: type,
        declaredDomains: declaredDomains, payload: payload)
}

private func controlTestAttachmentEvent(
    _ type: String,
    id: String,
    sequence: Int,
    previous: String?,
    session: SessionRef? = controlTestSession,
    sessionAttachment: SessionAttachmentRef? = controlTestSessionAttachment,
    sessionJournal: JournalRef? = controlTestSessionJournal,
    capabilities: Set<String>? = ["observe", "control"]
) -> TimelineEvent {
    controlTestEvent(
        type, id: id, sequence: sequence, previous: previous,
        session: session, sessionAttachment: sessionAttachment,
        payload: controlTestPayload(
            sessionJournal: sessionJournal, capabilities: capabilities))
}

func test_workHostControlJournalIdentityIsHostBoundAndCodable() throws {
    let journal = JournalRef.workHost(controlTestHost)
    XCTAssertEqual(journal.kind, .workHost)
    XCTAssertEqual(journal.authority, TimelineAuthorityRef(controlTestHost.workHostID))
    if case .workHost(let owner) = journal.owner {
        XCTAssertEqual(owner, controlTestHost)
    } else {
        XCTFail("control journal must be owned by a Work Host")
    }

    let decoded = try JSONDecoder().decode(
        JournalRef.self, from: JSONEncoder().encode(journal))
    XCTAssertEqual(decoded, journal)
    XCTAssertTrue(journal.stableKey.contains("kind:work-host"))

    do {
        _ = try JournalRef(
            journalID: "control", authority: TimelineAuthorityRef("foreign"),
            owner: .workHost(controlTestHost))
        XCTFail("a Work Host control journal must reject a foreign authority")
    } catch let error as JournalRef.ConstructionError {
        XCTAssertEqual(
            error,
            .workHostAuthorityMismatch(expected: controlTestHost.workHostID, actual: "foreign"))
    } catch {
        XCTFail("unexpected construction error: \(error)")
    }
}

func test_workHostControlReducerKeepsAttachmentAndReadStateSeparateFromWork() throws {
    let workJournal = controlTestWorkJournal
    let workCursor = JournalCursor(journal: workJournal, eventID: "work-42", sequence: 42)
    let sessionCursor = JournalCursor(
        journal: controlTestSessionJournal, eventID: "session-9", sequence: 9)
    let events = [
        controlTestAttachmentEvent(
            TimelineEventType.clientAttached, id: "c1", sequence: 1, previous: nil),
        controlTestAttachmentEvent(
            TimelineEventType.clientCapabilityChanged, id: "c2", sequence: 2, previous: "c1",
            capabilities: ["observe", "control", "queue"]),
        controlTestEvent(
            TimelineEventType.clientReadAcknowledged, id: "c3", sequence: 3, previous: "c2",
            session: controlTestSession, sessionAttachment: controlTestSessionAttachment,
            payload: controlTestPayload(
                sessionJournal: controlTestSessionJournal, targetJournal: workJournal,
                cursor: workCursor)),
        controlTestEvent(
            TimelineEventType.clientReadAcknowledged, id: "c4", sequence: 4, previous: "c3",
            session: controlTestSession, sessionAttachment: controlTestSessionAttachment,
            payload: controlTestPayload(
                sessionJournal: controlTestSessionJournal,
                targetJournal: controlTestSessionJournal, cursor: sessionCursor)),
        controlTestAttachmentEvent(
            TimelineEventType.clientDetached, id: "c5", sequence: 5, previous: "c4"),
    ]

    let snapshot = WorkHostControlReducer.reduce(events)
    XCTAssertEqual(snapshot.journal, JournalRef.workHost(controlTestHost))
    XCTAssertEqual(snapshot.workHost, controlTestHost)
    let attachment = try XCTUnwrap(snapshot.clientAttachments[controlTestAttachment.attachmentID])
    XCTAssertEqual(attachment.work, controlTestWork)
    XCTAssertEqual(attachment.workJournal, workJournal)
    XCTAssertEqual(attachment.capabilities, ["observe", "control", "queue"])
    XCTAssertFalse(attachment.isAttached, "only the explicit detach changed durable attachment state")
    XCTAssertEqual(snapshot.attachedClientIDs, [])

    let workKey = "client:\(controlTestClient.clientID.utf8.count):\(controlTestClient.clientID)/attachment:\(controlTestAttachment.attachmentID.utf8.count):\(controlTestAttachment.attachmentID)/target:\(workJournal.stableKey)"
    let sessionKey = "client:\(controlTestClient.clientID.utf8.count):\(controlTestClient.clientID)/attachment:\(controlTestAttachment.attachmentID.utf8.count):\(controlTestAttachment.attachmentID)/target:\(controlTestSessionJournal.stableKey)"
    XCTAssertEqual(snapshot.readAcknowledgements[workKey]?.cursor, workCursor)
    XCTAssertEqual(snapshot.readAcknowledgements[sessionKey]?.cursor, sessionCursor)
    XCTAssertTrue(snapshot.corruptionReasons.isEmpty)

    // A transport disconnect has no event representation and therefore cannot turn a durable
    // attachment into a detach. The prefix before c5 remains attached.
    let disconnectedPrefix = WorkHostControlReducer.reduce(Array(events.prefix(4)))
    XCTAssertTrue(disconnectedPrefix.clientAttachments[controlTestAttachment.attachmentID]?.isAttached == true)
    XCTAssertEqual(disconnectedPrefix.readAcknowledgements.count, 2)
}

func test_workHostControlReducerRejectsCrossSessionAndPartialSessionState() throws {
    let foreignSession = SessionRef("control-session-2")
    let foreignSessionJournal = JournalRef.session(
        foreignSession, journalID: "foreign-session-journal",
        authority: TimelineAuthorityRef("foreign-session-service"))
    let attach = controlTestAttachmentEvent(
        TimelineEventType.clientAttached, id: "x1", sequence: 1, previous: nil)
    let crossSessionAck = controlTestEvent(
        TimelineEventType.clientReadAcknowledged, id: "x2", sequence: 2, previous: "x1",
        session: foreignSession, sessionAttachment: controlTestSessionAttachment,
        payload: controlTestPayload(
            sessionJournal: foreignSessionJournal,
            targetJournal: foreignSessionJournal,
            cursor: JournalCursor(
                journal: foreignSessionJournal, eventID: "foreign-1", sequence: 1)))

    let crossSessionSnapshot = WorkHostControlReducer.reduce([attach, crossSessionAck])
    XCTAssertEqual(crossSessionSnapshot.readAcknowledgements.count, 0)
    XCTAssertFalse(crossSessionSnapshot.semanticProjectionValid)
    XCTAssertTrue(crossSessionSnapshot.corruptionReasons.contains {
        $0.contains("read acknowledgement")
    })

    let partialSession = controlTestEvent(
        TimelineEventType.clientAttached, id: "x3", sequence: 1,
        session: controlTestSession, sessionAttachment: nil,
        payload: controlTestPayload(
            sessionJournal: controlTestSessionJournal, capabilities: ["observe"]))
    let partialSnapshot = WorkHostControlReducer.reduce([partialSession])
    XCTAssertTrue(partialSnapshot.clientAttachments.isEmpty)
    XCTAssertFalse(partialSnapshot.semanticProjectionValid)
    XCTAssertTrue(partialSnapshot.corruptionReasons.contains {
        $0.contains("client attachment")
    })

    let replacedWorkJournal = JournalRef.work(
        controlTestWork, journalID: "work-generation-2")
    let replacedGenerationAck = controlTestEvent(
        TimelineEventType.clientReadAcknowledged, id: "x4", sequence: 2, previous: "x1",
        session: controlTestSession, sessionAttachment: controlTestSessionAttachment,
        payload: controlTestPayload(
            sessionJournal: controlTestSessionJournal,
            targetJournal: replacedWorkJournal,
            cursor: JournalCursor(
                journal: replacedWorkJournal, eventID: "replacement-1", sequence: 1)))
    let replacedSnapshot = WorkHostControlReducer.reduce([attach, replacedGenerationAck])
    XCTAssertTrue(replacedSnapshot.readAcknowledgements.isEmpty)
    XCTAssertFalse(replacedSnapshot.semanticProjectionValid)
}

func test_workHostControlJournalPersistsAcrossReopenAndSurvivesTerminalWork() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor,
        eventIDProvider: {
            // The writer calls this closure once per append; the values make the persisted
            // control prefix deterministic enough for this test without coupling the API to UUIDs.
            UUID().uuidString.lowercased()
        }, now: { Date(timeIntervalSince1970: 123) })

    let emptyControlCursor = JournalCursor(
        journal: journal.journal, eventID: nil, sequence: 0)
    let attachCommand = CommandRef(
        commandID: "attach-client-1", client: controlTestClient,
        causalCursor: emptyControlCursor)
    let attachCommit = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe", "control"], command: attachCommand,
        causalControlCursor: emptyControlCursor)
    let duplicateAttach = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe", "control"], command: attachCommand,
        causalControlCursor: emptyControlCursor)
    XCTAssertEqual(duplicateAttach, attachCommit)
    XCTAssertEqual(await journal.nextSequenceNumber, 2)

    let readCursor = JournalCursor(
        journal: controlTestWorkJournal, eventID: "terminal-work-event", sequence: 1)
    let targetEvent = TimelineEvent(
        eventID: "terminal-work-event", journal: controlTestWorkJournal, sequence: 1,
        work: controlTestWork, workHost: controlTestHost, actor: controlTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: 122), type: TimelineEventType.workCreated,
        declaredDomains: [.work])
    let targetURL = home.timelineV2WorkJournalURL(controlTestWork)
    try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var targetData = try JSONEncoder().encode(targetEvent)
    targetData.append(0x0A)
    try targetData.write(to: targetURL, options: .atomic)
    let acknowledgeCommand = CommandRef(
        commandID: "ack-work-1", client: controlTestClient,
        causalCursor: attachCommit.cursor)
    _ = try await journal.acknowledgeRead(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        targetJournal: controlTestWorkJournal, cursor: readCursor,
        command: acknowledgeCommand,
        causalControlCursor: attachCommit.cursor)
    XCTAssertEqual(attachCommit.cursor.sequence, 1)
    XCTAssertEqual(await journal.nextSequenceNumber, 3)
    try await journal.closeChecked()

    // Reopening does not consult Work lifecycle. A terminal Work can still be observed and its
    // client can advance a read acknowledgement in this separate control journal.
    let reopened = try WorkHostControlJournal.reopenExisting(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    try FileManager.default.removeItem(at: targetURL)
    let reconciledAck = try await reopened.acknowledgeRead(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        targetJournal: controlTestWorkJournal, cursor: readCursor,
        command: acknowledgeCommand, causalControlCursor: attachCommit.cursor)
    XCTAssertEqual(reconciledAck.cursor.sequence, 2,
                   "an exact lost-response retry must not re-read mutable target state")
    let snapshot = try await reopened.snapshot()
    XCTAssertTrue(snapshot.clientAttachments[controlTestAttachment.attachmentID]?.isAttached == true)
    XCTAssertEqual(snapshot.readAcknowledgements.count, 1)
    XCTAssertEqual(snapshot.readAcknowledgements.values.first?.cursor, readCursor)
    try await reopened.closeChecked()
}

func test_workHostControlJournalRejectsStaleConflictingAndUnprovenMutations() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-causality-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)
    let command = CommandRef(
        commandID: "causal-attach", client: controlTestClient, causalCursor: empty)
    let attachCommit = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe"], command: command, causalControlCursor: empty)

    do {
        _ = try await journal.attachClient(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: controlTestAttachment, client: controlTestClient,
            capabilities: ["control"], command: command, causalControlCursor: empty)
        XCTFail("changed request reused a client-qualified command identity")
    } catch {}

    let otherAttachment = ClientAttachmentRef("client-attachment-2")
    do {
        _ = try await journal.attachClient(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: otherAttachment, client: controlTestClient,
            capabilities: ["observe"],
            command: CommandRef(
                commandID: "stale-attach", client: controlTestClient, causalCursor: empty),
            causalControlCursor: empty)
        XCTFail("stale control cursor was accepted")
    } catch {}
    XCTAssertEqual(await journal.nextSequenceNumber, 2)

    let presentEvent = TimelineEvent(
        eventID: "present", journal: controlTestWorkJournal, sequence: 1,
        work: controlTestWork, workHost: controlTestHost, actor: controlTestActor,
        hostRecordedAt: Date(), type: TimelineEventType.workCreated,
        declaredDomains: [.work])
    let targetURL = home.timelineV2WorkJournalURL(controlTestWork)
    try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var targetData = try JSONEncoder().encode(presentEvent)
    targetData.append(0x0A)
    try targetData.write(to: targetURL, options: .atomic)
    let inventedCursor = JournalCursor(
        journal: controlTestWorkJournal, eventID: "not-present", sequence: 2)
    do {
        _ = try await journal.acknowledgeRead(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: controlTestAttachment, client: controlTestClient,
            targetJournal: controlTestWorkJournal, cursor: inventedCursor,
            command: CommandRef(
                commandID: "invented-read", client: controlTestClient,
                causalCursor: attachCommit.cursor),
            causalControlCursor: attachCommit.cursor)
        XCTFail("host accepted a cursor absent from the canonical target journal")
    } catch {}
    XCTAssertEqual(await journal.nextSequenceNumber, 2)

    let oneGraphemeOversizedID = "a" + String(repeating: "\u{0301}", count: 300)
    XCTAssertEqual(oneGraphemeOversizedID.count, 1)
    do {
        _ = try await journal.attachClient(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: ClientAttachmentRef("bounded-attachment"), client: controlTestClient,
            capabilities: ["observe"],
            command: CommandRef(
                commandID: oneGraphemeOversizedID, client: controlTestClient,
                causalCursor: attachCommit.cursor),
            causalControlCursor: attachCommit.cursor)
        XCTFail("UTF-8-unbounded command identity was accepted")
    } catch {}
    XCTAssertEqual(await journal.nextSequenceNumber, 2)
    try await journal.closeChecked()
}

func test_workHostControlJournalSerializesConcurrentCausalMutations() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-concurrent-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try WorkHostControlJournal.createFresh(
        home: AgentHome(root: root), workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)

    let first = Task { () -> Bool in
        do {
            _ = try await journal.attachClient(
                work: controlTestWork, workJournal: controlTestWorkJournal,
                attachment: ClientAttachmentRef("concurrent-attachment-1"),
                client: controlTestClient, capabilities: ["observe"],
                command: CommandRef(
                    commandID: "concurrent-attach-1", client: controlTestClient,
                    causalCursor: empty),
                causalControlCursor: empty)
            return true
        } catch { return false }
    }
    let second = Task { () -> Bool in
        do {
            _ = try await journal.attachClient(
                work: controlTestWork, workJournal: controlTestWorkJournal,
                attachment: ClientAttachmentRef("concurrent-attachment-2"),
                client: controlTestClient, capabilities: ["observe"],
                command: CommandRef(
                    commandID: "concurrent-attach-2", client: controlTestClient,
                    causalCursor: empty),
                causalControlCursor: empty)
            return true
        } catch { return false }
    }
    let firstSucceeded = await first.value
    let secondSucceeded = await second.value
    XCTAssertEqual([firstSucceeded, secondSucceeded].filter { $0 }.count, 1)
    XCTAssertEqual(await journal.nextSequenceNumber, 2)
    let read = try await journal.read()
    XCTAssertEqual(read.records.count, 1)
    XCTAssertNil(read.quarantinedSuffix)
    XCTAssertNil(read.truncatedTail)
    let snapshot = try await journal.snapshot()
    XCTAssertEqual(snapshot.clientAttachments.count, 1)
    XCTAssertTrue(snapshot.structuralIntegrityValid)
    XCTAssertTrue(snapshot.semanticProjectionValid)
    try await journal.closeChecked()
}

func test_workHostControlJournalDoesNotPromoteUnsynchronizedRetry() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-unsynced-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try WorkHostControlJournal.createFresh(
        home: AgentHome(root: root), workHost: controlTestHost, actor: controlTestActor,
        failurePlan: .init(point: .afterWriteBeforeSync),
        eventIDProvider: { "unsynchronized-control-event" })
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)
    let command = CommandRef(
        commandID: "unsynchronized-attach", client: controlTestClient, causalCursor: empty)

    do {
        _ = try await journal.attachClient(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: controlTestAttachment, client: controlTestClient,
            capabilities: ["observe"], command: command, causalControlCursor: empty)
        XCTFail("injected pre-sync failure was accepted")
    } catch {}
    if case .failed = await journal.health {} else {
        XCTFail("writer did not retain failed health after the uncertain write")
    }
    let readableButUnsealed = TimelineJournalReader.read(
        try Data(contentsOf: journal.fileURL), journal: journal.journal,
        actor: controlTestActor, hostRecordedAt: Date())
    XCTAssertEqual(readableButUnsealed.records.count, 1)
    XCTAssertTrue(try await journal.read().records.isEmpty,
                  "live reads must project only the previously sealed prefix")
    XCTAssertEqual(await journal.nextSequenceNumber, 1)

    do {
        _ = try await journal.attachClient(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: controlTestAttachment, client: controlTestClient,
            capabilities: ["observe"], command: command, causalControlCursor: empty)
        XCTFail("exact retry promoted an unsynchronized readable line")
    } catch {}
    XCTAssertEqual(await journal.nextSequenceNumber, 1)
    await journal.close()
    let recovered = try WorkHostControlJournal.reopenExisting(
        home: AgentHome(root: root), workHost: controlTestHost, actor: controlTestActor,
        eventIDProvider: { "recovered-control-event" })
    XCTAssertTrue(try await recovered.read().records.isEmpty,
                  "cold reopen must recover only the previously sealed prefix")
    let committedRetry = try await recovered.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe"], command: command, causalControlCursor: empty)
    XCTAssertEqual(committedRetry.cursor.sequence, 1)
    XCTAssertEqual(committedRetry.eventRef.eventID, "recovered-control-event")
    XCTAssertEqual(try await recovered.read().records.count, 1)
    try await recovered.closeChecked()
}

func test_workHostControlJournalRecoversEmptySealCrashWindow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-empty-seal-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let initial = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let journalURL = initial.fileURL
    try await initial.closeChecked()
    try FileManager.default.removeItem(
        at: WorkHostControlJournal.durabilitySealURL(for: journalURL))

    let recovered = try WorkHostControlJournal.reopenExisting(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    XCTAssertTrue(try await recovered.read().records.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(
        atPath: WorkHostControlJournal.durabilitySealURL(for: journalURL).path))
    XCTAssertEqual(await recovered.nextSequenceNumber, 1)
    try await recovered.closeChecked()
}

let casesWorkHostControlJournal: [Case] = [
    ("phase3 Work Host control: owner authority and coding are explicit", {
        try test_workHostControlJournalIdentityIsHostBoundAndCodable()
    }),
    ("phase3 Work Host control: attachments and per-journal reads are durable", {
        try test_workHostControlReducerKeepsAttachmentAndReadStateSeparateFromWork()
    }),
    ("phase3 Work Host control: cross-Session and partial state fail closed", {
        try test_workHostControlReducerRejectsCrossSessionAndPartialSessionState()
    }),
    ("phase3 Work Host control: reopen preserves state after terminal Work", {
        try await test_workHostControlJournalPersistsAcrossReopenAndSurvivesTerminalWork()
    }),
    ("phase3 Work Host control: mutations are causal idempotent and target-proven", {
        try await test_workHostControlJournalRejectsStaleConflictingAndUnprovenMutations()
    }),
    ("phase3 Work Host control: concurrent mutations serialize at one cursor", {
        try await test_workHostControlJournalSerializesConcurrentCausalMutations()
    }),
    ("phase3 Work Host control: unsynchronized retries stay unavailable", {
        try await test_workHostControlJournalDoesNotPromoteUnsynchronizedRetry()
    }),
    ("phase3 Work Host control: empty seal crash window recovers", {
        try await test_workHostControlJournalRecoversEmptySealCrashWindow()
    }),
]
