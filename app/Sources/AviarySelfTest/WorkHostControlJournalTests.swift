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

private actor ControlSourcePublicationCounters {
    private(set) var attempts = 0
    private(set) var claims = 0

    func recordAttempt(claim: Bool) {
        attempts += 1
        if claim { claims += 1 }
    }
}

private final class ControlEventIDBox: @unchecked Sendable {
    private var index = 0

    func next() -> String {
        index += 1
        return index == 8 ? "recovery-mirror" : "recovery-work-\(index)"
    }
}

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

private func controlTestReplacingSessionEnvelope(
    _ event: TimelineEvent,
    session: SessionRef,
    sessionAttachment: SessionAttachmentRef
) -> TimelineEvent {
    TimelineEvent(
        eventID: event.eventID, journal: event.journal, sequence: event.sequence,
        hostSequence: event.hostSequence, idempotencyKey: event.idempotencyKey,
        command: event.command, previousEventID: event.previousEventID,
        causedByEventID: event.causedByEventID, parentActivityID: event.parentActivityID,
        conversationParent: event.conversationParent, session: session, work: event.work,
        workHost: event.workHost, client: event.client, sessionAttachment: sessionAttachment,
        clientAttachment: event.clientAttachment, run: event.run, turn: event.turn,
        action: event.action, handle: event.handle, actor: event.actor,
        hostRecordedAt: event.hostRecordedAt, clientTimestamp: event.clientTimestamp,
        schemaVersion: event.schemaVersion, payloadVersion: event.payloadVersion,
        type: event.type, declaredDomains: event.declaredDomains,
        provenance: event.provenance, links: event.links, payload: event.payload)
}

private func controlTestReadNativeEvents(
    home: AgentHome, journal: JournalRef
) throws -> [TimelineEvent] {
    let url: URL
    switch journal.owner {
    case .workHost(let host):
        url = home.timelineV2WorkHostControlJournalURL(workHostID: host.workHostID)
    case .work(let work):
        url = home.timelineV2WorkJournalURL(work)
    case .session(let session):
        url = home.timelineV2SessionJournalURL(session)
    }
    let read = TimelineJournalReader.read(
        try Data(contentsOf: url), journal: journal, actor: controlTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        XCTFail("test fixture must be one complete native journal")
        return []
    }
    return read.records.map(\.event)
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
        capabilities: ["observe", "control"], requestedCapabilities: ["observe", "control"],
        command: attachCommand,
        causalControlCursor: emptyControlCursor)
    let duplicateAttach = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe", "control"], requestedCapabilities: ["observe", "control"],
        command: attachCommand,
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
        capabilities: ["observe"], requestedCapabilities: ["observe"],
        command: command, causalControlCursor: empty)

    do {
        _ = try await journal.attachClient(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: controlTestAttachment, client: controlTestClient,
            capabilities: ["control"], requestedCapabilities: ["control"],
            command: command, causalControlCursor: empty)
        XCTFail("changed request reused a client-qualified command identity")
    } catch {}

    let otherAttachment = ClientAttachmentRef("client-attachment-2")
    do {
        _ = try await journal.attachClient(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: otherAttachment, client: controlTestClient,
            capabilities: ["observe"], requestedCapabilities: ["observe"],
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
            capabilities: ["observe"], requestedCapabilities: ["observe"],
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
                requestedCapabilities: ["observe"],
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
                requestedCapabilities: ["observe"],
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
            capabilities: ["observe"], requestedCapabilities: ["observe"],
            command: command, causalControlCursor: empty)
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
            capabilities: ["observe"], requestedCapabilities: ["observe"],
            command: command, causalControlCursor: empty)
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
        capabilities: ["observe"], requestedCapabilities: ["observe"],
        command: command, causalControlCursor: empty)
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

func test_workHostControlJournalCacheTracksLocalAppends() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let first = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: first.journal, eventID: nil, sequence: 0)

    XCTAssertTrue(try await first.snapshot().clientAttachments.isEmpty,
                  "the empty projection is deliberately cached before the first mutation")
    _ = try await first.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe"], requestedCapabilities: ["observe"],
        command: CommandRef(
            commandID: "cache-first", client: controlTestClient, causalCursor: empty),
        causalControlCursor: empty)
    XCTAssertEqual(try await first.snapshot().clientAttachments.count, 1,
                   "a local append must invalidate the pre-append reducer cache")
    try await first.closeChecked()
}

func test_workHostControlJournalExtendsCacheByAppendBytes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-incremental-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try WorkHostControlJournal.createFresh(
        home: AgentHome(root: root), workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)
    let attached = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe"], requestedCapabilities: ["observe"],
        command: CommandRef(
            commandID: "incremental-attach", client: controlTestClient,
            causalCursor: empty), causalControlCursor: empty)
    let afterAttach = await journal.journalReadMetrics()
    XCTAssertEqual(afterAttach.fullReads, 1)
    XCTAssertEqual(afterAttach.incrementalReads, 1)

    _ = try await journal.updateClientCapabilities(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe", "control"], requestedCapabilities: ["observe", "control"],
        command: CommandRef(
            commandID: "incremental-capability", client: controlTestClient,
            causalCursor: attached.cursor), causalControlCursor: attached.cursor)
    let afterSecond = await journal.journalReadMetrics()
    XCTAssertEqual(afterSecond.fullReads, afterAttach.fullReads,
                   "a normal mutation must not reparse the control history")
    XCTAssertEqual(afterSecond.incrementalReads, afterAttach.incrementalReads + 1)
    XCTAssertTrue(afterSecond.bytesScanned > 0)
    XCTAssertEqual(afterSecond.recordsApplied, 2)
    try await journal.closeChecked()
}

func test_workHostControlJournalTargetScanKeepsBoundedStateForLargeJournal() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-target-scale-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)
    let attached = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["observe"], requestedCapabilities: ["observe"],
        command: CommandRef(
            commandID: "target-scale-attach", client: controlTestClient,
            causalCursor: empty), causalControlCursor: empty)

    let targetURL = home.timelineV2WorkJournalURL(controlTestWork)
    try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let eventCount = 100_001
    var targetData = Data()
    targetData.reserveCapacity(eventCount * 480)
    var previous: String?
    for sequence in 1...eventCount {
        let eventID = "target-scale-\(sequence)"
        let event = TimelineEvent(
            eventID: eventID, journal: controlTestWorkJournal, sequence: sequence,
            previousEventID: previous, work: controlTestWork, workHost: controlTestHost,
            actor: controlTestActor, hostRecordedAt: Date(timeIntervalSince1970: 1),
            type: TimelineEventType.workCreated, declaredDomains: [.work])
        targetData.append(try JSONEncoder().encode(event))
        targetData.append(0x0A)
        previous = eventID
    }
    try targetData.write(to: targetURL, options: .atomic)
    let targetJournal = controlTestWorkJournal
    func targetCursor(_ sequence: Int) -> JournalCursor {
        JournalCursor(
            journal: targetJournal, eventID: "target-scale-\(sequence)", sequence: sequence)
    }

    let early = try await journal.acknowledgeRead(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        targetJournal: targetJournal, cursor: targetCursor(1),
        command: CommandRef(
            commandID: "target-scale-early", client: controlTestClient,
            causalCursor: attached.cursor), causalControlCursor: attached.cursor)
    let afterEarly = await journal.journalReadMetrics()
    XCTAssertTrue(afterEarly.targetVerificationBytesScanned < targetData.count)
    XCTAssertTrue(afterEarly.targetVerificationPeakChunkBytes <= 256 * 1024)
    XCTAssertEqual(afterEarly.targetVerificationChunks, 1)

    let middle = try await journal.acknowledgeRead(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        targetJournal: targetJournal, cursor: targetCursor(50_000),
        command: CommandRef(
            commandID: "target-scale-middle", client: controlTestClient,
            causalCursor: early.cursor), causalControlCursor: early.cursor)
    let afterMiddle = await journal.journalReadMetrics()
    XCTAssertTrue(afterMiddle.targetVerificationChunks > afterEarly.targetVerificationChunks)
    let tip = try await journal.acknowledgeRead(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        targetJournal: targetJournal, cursor: targetCursor(eventCount),
        command: CommandRef(
            commandID: "target-scale-tip", client: controlTestClient,
            causalCursor: middle.cursor), causalControlCursor: middle.cursor)
    XCTAssertEqual(tip.cursor.sequence, 4)
    let metrics = await journal.journalReadMetrics()
    XCTAssertTrue(metrics.targetVerificationChunks > afterMiddle.targetVerificationChunks)
    XCTAssertTrue(metrics.targetVerificationPeakChunkBytes <= 256 * 1024)
    try await journal.closeChecked()
}

func test_workHostControlJournalDurablyReconcilesExistingWorkSessionCreation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-session-creation-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)
    let attach = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["create_session", "observe"],
        requestedCapabilities: ["create_session", "observe"],
        command: CommandRef(
            commandID: "session-authorizer", client: controlTestClient, causalCursor: empty),
        causalControlCursor: empty)

    let newSession = SessionRef("session-for-existing-work")
    let newSessionJournal = JournalRef.session(
        newSession, journalID: "session-for-existing-work-journal",
        authority: TimelineAuthorityRef(controlTestHost.workHostID))
    let newSessionAttachment = SessionAttachmentRef("session-relationship-1")
    let newClientAttachment = ClientAttachmentRef("session-client-attachment-1")
    let workTip = JournalCursor(
        journal: controlTestWorkJournal, eventID: "work-tip-7", sequence: 7)
    let command = CommandRef(
        commandID: "session-create-1", client: controlTestClient,
        causalCursor: attach.cursor)
    let reservationRequest = WorkHostControlSessionCreationRequest(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        authorizingAttachment: controlTestAttachment, client: controlTestClient,
        command: command, causalControlCursor: attach.cursor,
        causalWorkCursor: workTip, requestedCapabilities: ["observe"],
        session: newSession, sessionJournal: newSessionJournal,
        sessionAttachment: newSessionAttachment, clientAttachment: newClientAttachment)
    let reservation = try await journal.reserveSessionCreation(reservationRequest)
    XCTAssertEqual(reservation.reservation, reservationRequest)
    XCTAssertEqual(reservation.reservationCursor.sequence, 2)

    // The exact request is reconciled before stale-cursor validation. The control cursor now
    // points at the reservation, but a lost response can safely retry the original envelope.
    let exactReservationRetry = try await journal.reserveSessionCreation(reservationRequest)
    XCTAssertEqual(exactReservationRetry, reservation)
    XCTAssertEqual(await journal.nextSequenceNumber, 3)

    let conflictingReservation = WorkHostControlSessionCreationRequest(
        work: reservationRequest.work, workJournal: reservationRequest.workJournal,
        authorizingAttachment: reservationRequest.authorizingAttachment,
        client: reservationRequest.client, command: reservationRequest.command,
        causalControlCursor: reservationRequest.causalControlCursor,
        causalWorkCursor: reservationRequest.causalWorkCursor,
        requestedCapabilities: ["control"], session: reservationRequest.session,
        sessionJournal: reservationRequest.sessionJournal,
        sessionAttachment: reservationRequest.sessionAttachment,
        clientAttachment: reservationRequest.clientAttachment)
    do {
        _ = try await journal.reserveSessionCreation(conflictingReservation)
        XCTFail("changed session creation evidence reused a client-qualified command")
    } catch {}
    XCTAssertEqual(await journal.nextSequenceNumber, 3)

    let sessionCreated = EventRef(journal: newSessionJournal, eventID: "session-created-1")
    let sessionAttached = EventRef(journal: newSessionJournal, eventID: "session-attached-1")
    let cursorAdvanced = EventRef(journal: newSessionJournal, eventID: "session-cursor-advanced-1")
    let workMirror = EventRef(journal: controlTestWorkJournal, eventID: "work-session-attached-8")
    let sessionCursor = JournalCursor(
        journal: newSessionJournal, eventID: cursorAdvanced.eventID, sequence: 3)
    let mirroredResultRequest = WorkHostControlSessionCreationResultRequest(
        reservationEvent: reservation.reservationEvent,
        commandID: command.commandID, causalControlCursor: reservation.reservationCursor,
        publication: "mirrored", capabilities: ["observe"],
        causalSessionCursor: JournalCursor(journal: newSessionJournal, eventID: nil, sequence: 0),
        sessionCursor: sessionCursor, causalWorkCursor: workTip,
        resultingWorkCursor: JournalCursor(
            journal: controlTestWorkJournal, eventID: workMirror.eventID, sequence: 8),
        sessionCreatedEvent: sessionCreated, sessionAttachedEvent: sessionAttached,
        workMirrorEvent: workMirror, cursorAdvancedEvent: cursorAdvanced)
    let mirroredResult = try await journal.completeSessionCreation(
        work: controlTestWork, client: controlTestClient, commandID: command.commandID,
        mirroredResultRequest)
    XCTAssertEqual(mirroredResult.causalControlCursor, reservation.reservationCursor)
    XCTAssertEqual(mirroredResult.resultEvent.journal, journal.journal)
    XCTAssertEqual(mirroredResult.sessionCursor, sessionCursor)
    XCTAssertEqual(await journal.nextSequenceNumber, 4)
    XCTAssertEqual(
        try await journal.completeSessionCreation(
            work: controlTestWork, client: controlTestClient, commandID: command.commandID,
            mirroredResultRequest), mirroredResult,
        "an exact result retry must not append or remint")
    XCTAssertEqual(await journal.nextSequenceNumber, 4)
    try await journal.closeChecked()

    let reopened = try WorkHostControlJournal.reopenExisting(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let recovered = try await reopened.snapshot()
    let recoveredSession = try XCTUnwrap(
        recovered.sessionCreation(
            work: controlTestWork, client: controlTestClient, commandID: command.commandID))
    XCTAssertEqual(recoveredSession.reservation, reservationRequest)
    XCTAssertEqual(recoveredSession.result, mirroredResult)
    XCTAssertFalse(recoveredSession.isConflicted)
    XCTAssertTrue(recoveredSession.conflictEventRefs.isEmpty)
    try await reopened.closeChecked()

    // A cold reducer must bind both typed Session envelope fields to the reservation. The
    // payload/event refs alone are insufficient because a forged control line could otherwise
    // publish an attachment under a different Session identity.
    let persisted = try controlTestReadNativeEvents(home: home, journal: journal.journal)
    let completionIndex = try XCTUnwrap(persisted.firstIndex {
        $0.type == WorkHostControlEventType.sessionCreationCompleted
    })
    let completion = persisted[completionIndex]
    let wrongSession = controlTestReplacingSessionEnvelope(
        completion, session: SessionRef("foreign-completed-session"),
        sessionAttachment: newSessionAttachment)
    let wrongSessionSnapshot = WorkHostControlReducer.reduce(
        Array(persisted[..<completionIndex]) + [wrongSession])
    XCTAssertNil(
        wrongSessionSnapshot.sessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: command.commandID)?.result)
    XCTAssertFalse(wrongSessionSnapshot.semanticProjectionValid)
    XCTAssertEqual(wrongSessionSnapshot.quarantinedEvents.last?.eventID, completion.eventID)

    let wrongAttachment = controlTestReplacingSessionEnvelope(
        completion, session: newSession,
        sessionAttachment: SessionAttachmentRef("foreign-completed-attachment"))
    let wrongAttachmentSnapshot = WorkHostControlReducer.reduce(
        Array(persisted[..<completionIndex]) + [wrongAttachment])
    XCTAssertNil(
        wrongAttachmentSnapshot.sessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: command.commandID)?.result)
    XCTAssertFalse(wrongAttachmentSnapshot.semanticProjectionValid)
    XCTAssertEqual(wrongAttachmentSnapshot.quarantinedEvents.last?.eventID, completion.eventID)
}

func test_workHostControlJournalRecordsTerminalSessionReferenceWithoutWorkMirror() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-terminal-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)
    let attach = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["create_session", "observe"],
        requestedCapabilities: ["create_session", "observe"],
        command: CommandRef(
            commandID: "terminal-session-authorizer", client: controlTestClient,
            causalCursor: empty), causalControlCursor: empty)
    let terminalSession = SessionRef("terminal-session-reference")
    let terminalJournal = JournalRef.session(
        terminalSession, journalID: "terminal-session-journal",
        authority: TimelineAuthorityRef(controlTestHost.workHostID))
    let terminalWorkCursor = JournalCursor(
        journal: controlTestWorkJournal, eventID: "canonical-terminal-42", sequence: 42)
    let command = CommandRef(
        commandID: "terminal-session-create", client: controlTestClient,
        causalCursor: attach.cursor)
    let reservationRequest = WorkHostControlSessionCreationRequest(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        authorizingAttachment: controlTestAttachment, client: controlTestClient,
        command: command, causalControlCursor: attach.cursor,
        causalWorkCursor: terminalWorkCursor, requestedCapabilities: ["control", "observe"],
        session: terminalSession, sessionJournal: terminalJournal,
        sessionAttachment: SessionAttachmentRef("terminal-session-relationship"),
        clientAttachment: ClientAttachmentRef("terminal-client-attachment"))
    let reservation = try await journal.reserveSessionCreation(reservationRequest)
    let sessionCreated = EventRef(journal: terminalJournal, eventID: "terminal-session-created")
    let sessionAttached = EventRef(journal: terminalJournal, eventID: "terminal-session-attached")
    let cursorAdvanced = EventRef(journal: terminalJournal, eventID: "terminal-session-advanced")
    let resultRequest = WorkHostControlSessionCreationResultRequest(
        reservationEvent: reservation.reservationEvent,
        commandID: command.commandID, causalControlCursor: reservation.reservationCursor,
        publication: "terminal_reference", capabilities: ["observe"],
        causalSessionCursor: JournalCursor(journal: terminalJournal, eventID: nil, sequence: 0),
        sessionCursor: JournalCursor(journal: terminalJournal, eventID: cursorAdvanced.eventID, sequence: 3),
        causalWorkCursor: terminalWorkCursor, resultingWorkCursor: terminalWorkCursor,
        sessionCreatedEvent: sessionCreated, sessionAttachedEvent: sessionAttached,
        workMirrorEvent: nil, cursorAdvancedEvent: cursorAdvanced)
    let result = try await journal.completeSessionCreation(
        work: controlTestWork, client: controlTestClient, commandID: command.commandID,
        resultRequest)
    XCTAssertEqual(result.publication, "terminal_reference")
    XCTAssertNil(result.workMirrorEvent)
    XCTAssertEqual(result.causalWorkCursor, result.resultingWorkCursor)
    XCTAssertEqual((try await journal.snapshot()).sessionCreations.count, 1)
    try await journal.closeChecked()
}

func test_workHostControlJournalBlocksMutationsBehindFailedSessionCreationAndRecoversAfterReopen() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-session-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let empty = JournalCursor(journal: journal.journal, eventID: nil, sequence: 0)
    let attach = try await journal.attachClient(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["create_session", "observe"],
        requestedCapabilities: ["create_session", "observe"],
        command: CommandRef(
            commandID: "recovery-authorizer", client: controlTestClient, causalCursor: empty),
        causalControlCursor: empty)

    let session = SessionRef("recovery-session")
    let sessionJournal = JournalRef.session(
        session, journalID: "recovery-session-journal",
        authority: TimelineAuthorityRef(controlTestHost.workHostID))
    let sessionAttachment = SessionAttachmentRef("recovery-session-relationship")
    let clientAttachment = ClientAttachmentRef("recovery-client-attachment")
    let workTip = JournalCursor(
        journal: controlTestWorkJournal, eventID: "recovery-work-tip", sequence: 7)
    let command = CommandRef(
        commandID: "recovery-session-create", client: controlTestClient,
        causalCursor: attach.cursor)
    let request = WorkHostControlSessionCreationRequest(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        authorizingAttachment: controlTestAttachment, client: controlTestClient,
        command: command, causalControlCursor: attach.cursor, causalWorkCursor: workTip,
        requestedCapabilities: ["observe"], session: session, sessionJournal: sessionJournal,
        sessionAttachment: sessionAttachment, clientAttachment: clientAttachment)

    @Sendable func sourcePublication(
        _ request: WorkHostControlSessionCreationRequest
    ) -> RunJournalBundleSessionPublication {
        let created = TimelineJournalCommit(
            eventRef: EventRef(journal: request.sessionJournal, eventID: "recovery-created"),
            cursor: JournalCursor(
                journal: request.sessionJournal, eventID: "recovery-created", sequence: 1))
        let attached = TimelineJournalCommit(
            eventRef: EventRef(journal: request.sessionJournal, eventID: "recovery-attached"),
            cursor: JournalCursor(
                journal: request.sessionJournal, eventID: "recovery-attached", sequence: 2))
        let advanced = TimelineJournalCommit(
            eventRef: EventRef(journal: request.sessionJournal, eventID: "recovery-advanced"),
            cursor: JournalCursor(
                journal: request.sessionJournal, eventID: "recovery-advanced", sequence: 3))
        let mirror = TimelineJournalCommit(
            eventRef: EventRef(journal: request.workJournal, eventID: "recovery-mirror"),
            cursor: JournalCursor(
                journal: request.workJournal, eventID: "recovery-mirror", sequence: 8))
        return RunJournalBundleSessionPublication(
            session: request.session, sessionJournal: request.sessionJournal,
            sessionAttachment: request.sessionAttachment, publication: "mirrored",
            capabilities: ["observe"],
            causalSessionCursor: JournalCursor(
                journal: request.sessionJournal, eventID: nil, sequence: 0),
            sessionCursor: advanced.cursor, causalWorkCursor: request.causalWorkCursor,
            resultingWorkCursor: mirror.cursor, sessionCreated: created, sessionAttached: attached,
            workMirror: mirror, cursorAdvanced: advanced)
    }

    let counters = ControlSourcePublicationCounters()
    do {
        _ = try await journal.publishSessionCreation(request) { failedRequest in
            await counters.recordAttempt(claim: false)
            // Model an indeterminate source failure after a partial Session write. Automatic
            // abort must refuse this outcome, leaving the reservation retryable.
            let partialURL = home.timelineV2SessionJournalURL(failedRequest.session)
            try FileManager.default.createDirectory(
                at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x7b]).write(to: partialURL)
            throw TimelineJournalWriter.WriterError.injected(.beforeWrite)
        }
        XCTFail("the first source publication must fail")
    } catch {
        XCTAssertEqual(await counters.attempts, 1)
    }
    XCTAssertEqual(await journal.nextSequenceNumber, 3)
    let pending = try await journal.snapshot()
    let pendingCreation = try XCTUnwrap(
        pending.sessionCreation(
            work: controlTestWork, client: controlTestClient, commandID: command.commandID))
    XCTAssertNil(pendingCreation.result)

    // The failed source saga owns the current control cursor. An unrelated mutation must be
    // rejected before it can overtake the reservation and make an exact retry publish bytes
    // which completion would later reject.
    do {
        _ = try await journal.updateClientCapabilities(
            work: controlTestWork, workJournal: controlTestWorkJournal,
            attachment: controlTestAttachment, client: controlTestClient,
            capabilities: ["create_session", "observe"],
            requestedCapabilities: ["create_session", "observe"],
            command: CommandRef(
                commandID: "overtaking-capability-change", client: controlTestClient,
                causalCursor: pendingCreation.reservationCursor),
            causalControlCursor: pendingCreation.reservationCursor)
        XCTFail("an unrelated mutation must not overtake an incomplete Session creation")
    } catch let error as TimelineJournalWriter.WriterError {
        XCTAssertEqual(
            error,
            .invalidDraft(
                reason: "control mutation is blocked by an incomplete Session creation reservation"))
    } catch {
        XCTFail("unexpected overtaking-mutation error: \(error)")
    }
    XCTAssertEqual(await journal.nextSequenceNumber, 3)
    try await journal.closeChecked()

    // The reservation survives restart, and the matching retry can complete at its original
    // cursor. Only the successful retry makes one source claim and one completion record.
    let reopened = try WorkHostControlJournal.reopenExisting(
        home: home, workHost: controlTestHost, actor: controlTestActor)
    let publication = try await reopened.publishSessionCreation(request) { retry in
        await counters.recordAttempt(claim: true)
        return sourcePublication(retry)
    }
    XCTAssertEqual(await counters.attempts, 2)
    XCTAssertEqual(await counters.claims, 1)
    XCTAssertEqual(publication.result.resultingControlCursor.sequence, 3)
    XCTAssertEqual(await reopened.nextSequenceNumber, 4)
    let recovered = try await reopened.snapshot()
    let completed = try XCTUnwrap(
        recovered.sessionCreation(
            work: controlTestWork, client: controlTestClient, commandID: command.commandID))
    XCTAssertNotNil(completed.result)
    XCTAssertFalse(completed.isConflicted)

    // A source failure with no Session bytes can be explicitly and durably resolved. Partial or
    // indeterminate source outcomes remain blocked and retryable; this path never guesses.
    let abortedSession = SessionRef("recovery-aborted-session")
    let abortedSessionJournal = JournalRef.session(
        abortedSession, journalID: "recovery-aborted-session-journal",
        authority: TimelineAuthorityRef(controlTestHost.workHostID))
    let abortedCommand = CommandRef(
        commandID: "recovery-aborted-session-create", client: controlTestClient,
        causalCursor: publication.resultingControlCursor)
    let abortedRequest = WorkHostControlSessionCreationRequest(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        authorizingAttachment: controlTestAttachment, client: controlTestClient,
        command: abortedCommand, causalControlCursor: publication.resultingControlCursor,
        causalWorkCursor: publication.result.resultingWorkCursor,
        requestedCapabilities: ["observe"], session: abortedSession,
        sessionJournal: abortedSessionJournal,
        sessionAttachment: SessionAttachmentRef("recovery-aborted-relationship"),
        clientAttachment: ClientAttachmentRef("recovery-aborted-client"))
    do {
        _ = try await reopened.publishSessionCreation(abortedRequest) { failedRequest in
            let partialURL = home.timelineV2SessionJournalURL(failedRequest.session)
            try FileManager.default.createDirectory(
                at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x7b]).write(to: partialURL)
            throw TimelineJournalWriter.WriterError.injected(.beforeWrite)
        }
        XCTFail("the second source publication must fail")
    } catch {}
    let abortedBefore = try await reopened.snapshot()
    let abortedPending = try XCTUnwrap(
        abortedBefore.sessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: abortedCommand.commandID))
    XCTAssertNil(abortedPending.result)
    XCTAssertNil(abortedPending.abort)
    let workURL = home.timelineV2WorkJournalURL(controlTestWork)
    try FileManager.default.createDirectory(
        at: workURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let workEventIDs = ControlEventIDBox()
    let workWriter = try TimelineJournalWriter.createFresh(
        at: workURL, journal: controlTestWorkJournal, actor: controlTestActor, home: home,
        eventIDProvider: { workEventIDs.next() })
    for _ in 0..<8 {
        _ = try await workWriter.append(TimelineEventDraft(
            work: controlTestWork, workHost: controlTestHost,
            type: TimelineEventType.workCreated, declaredDomains: [.work], payload: .object([:])))
    }
    try await workWriter.closeChecked()
    let partialSourceURL = home.timelineV2SessionJournalURL(abortedSession)
    try FileManager.default.createDirectory(
        at: partialSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x7b]).write(to: partialSourceURL)
    do {
        _ = try await reopened.abortSessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: abortedCommand.commandID)
        XCTFail("a partial Session source must not be classified as absent")
    } catch {}
    try FileManager.default.removeItem(at: partialSourceURL)
    try FileManager.default.removeItem(at: partialSourceURL.deletingLastPathComponent())
    try FileManager.default.createDirectory(
        at: partialSourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let foreignEmptySource = root.appending(path: "foreign-empty-session.jsonl")
    try Data().write(to: foreignEmptySource)
    try FileManager.default.createSymbolicLink(
        at: partialSourceURL, withDestinationURL: foreignEmptySource)
    do {
        _ = try await reopened.abortSessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: abortedCommand.commandID)
        XCTFail("an empty symlink target must not be accepted as the canonical Session file")
    } catch {}
    try FileManager.default.removeItem(at: partialSourceURL)
    let abort = try await reopened.abortSessionCreation(
        work: controlTestWork, client: controlTestClient,
        commandID: abortedCommand.commandID)
    XCTAssertEqual(abort.sourcePresence, .none)
    XCTAssertEqual(abort.causalControlCursor.sequence, 4)
    XCTAssertEqual(abort.resultingControlCursor.sequence, 5)
    XCTAssertEqual(
        try await reopened.abortSessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: abortedCommand.commandID), abort)
    let abortedAfter = try await reopened.snapshot()
    let resolved = try XCTUnwrap(
        abortedAfter.sessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: abortedCommand.commandID))
    XCTAssertNil(resolved.result)
    XCTAssertEqual(resolved.abort, abort)
    do {
        _ = try await reopened.publishSessionCreation(abortedRequest) { _ in
            XCTFail("an aborted source operation must not be replayed")
            throw TimelineJournalWriter.WriterError.injected(.beforeWrite)
        }
        XCTFail("an aborted Session creation must not be retried")
    } catch {}
    let released = try await reopened.updateClientCapabilities(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["create_session", "observe"],
        requestedCapabilities: ["create_session", "observe"],
        command: CommandRef(
            commandID: "mutation-after-session-abort", client: controlTestClient,
            causalCursor: abort.resultingControlCursor),
        causalControlCursor: abort.resultingControlCursor)
    XCTAssertEqual(released.cursor.sequence, abort.resultingControlCursor.sequence + 1)

    // When the source closure fails before creating any Session bytes, publishSessionCreation
    // performs the same explicit absence proof automatically. The original source error is still
    // delivered, but the adjacent abort lets the next ordinary mutation proceed without a manual
    // recovery call.
    let automaticSession = SessionRef("recovery-automatic-abort-session")
    let automaticSessionJournal = JournalRef.session(
        automaticSession, journalID: "recovery-automatic-abort-session-journal",
        authority: TimelineAuthorityRef(controlTestHost.workHostID))
    let automaticCommand = CommandRef(
        commandID: "recovery-automatic-abort-create", client: controlTestClient,
        causalCursor: released.cursor)
    let automaticRequest = WorkHostControlSessionCreationRequest(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        authorizingAttachment: controlTestAttachment, client: controlTestClient,
        command: automaticCommand, causalControlCursor: released.cursor,
        causalWorkCursor: publication.result.resultingWorkCursor,
        requestedCapabilities: ["observe"], session: automaticSession,
        sessionJournal: automaticSessionJournal,
        sessionAttachment: SessionAttachmentRef("recovery-automatic-relationship"),
        clientAttachment: ClientAttachmentRef("recovery-automatic-client"))
    var sourceErrorDelivered = false
    do {
        _ = try await reopened.publishSessionCreation(automaticRequest) { request in
            // Faithfully model the real publisher's pre-write state: opening a fresh Session
            // writer creates the canonical owner directory and zero-byte journal before the
            // first append. A failure at that boundary has made no Session source claim.
            let emptyWriter = try TimelineJournalWriter.createFresh(
                at: home.timelineV2SessionJournalURL(request.session),
                journal: request.sessionJournal, actor: controlTestActor, home: home)
            try await emptyWriter.closeChecked()
            throw TimelineJournalWriter.WriterError.injected(.beforeWrite)
        }
        XCTFail("the automatic-abort source publication must fail")
    } catch let error as TimelineJournalWriter.WriterError {
        sourceErrorDelivered = error == .injected(.beforeWrite)
    } catch {
        XCTFail("unexpected source failure: \(error)")
    }
    XCTAssertTrue(sourceErrorDelivered)
    let automaticSnapshot = try await reopened.snapshot()
    let automaticCreation = try XCTUnwrap(
        automaticSnapshot.sessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: automaticCommand.commandID))
    XCTAssertNil(automaticCreation.result)
    XCTAssertNotNil(automaticCreation.abort)
    XCTAssertEqual(
        automaticCreation.abort?.sourcePresence,
        WorkHostControlCreationSourcePresence.none)
    let afterAutomaticAbort = try XCTUnwrap(automaticCreation.abort)
    let automaticMutation = try await reopened.updateClientCapabilities(
        work: controlTestWork, workJournal: controlTestWorkJournal,
        attachment: controlTestAttachment, client: controlTestClient,
        capabilities: ["create_session", "observe"],
        requestedCapabilities: ["create_session", "observe"],
        command: CommandRef(
            commandID: "mutation-after-automatic-session-abort", client: controlTestClient,
            causalCursor: afterAutomaticAbort.resultingControlCursor),
        causalControlCursor: afterAutomaticAbort.resultingControlCursor)
    XCTAssertEqual(
        automaticMutation.cursor.sequence,
        afterAutomaticAbort.resultingControlCursor.sequence + 1)
    try await reopened.closeChecked()

    let persisted = try controlTestReadNativeEvents(home: home, journal: journal.journal)
    let abortIndex = try XCTUnwrap(persisted.lastIndex {
        $0.type == WorkHostControlEventType.sessionCreationAborted
    })
    let abortEvent = persisted[abortIndex]
    let wrongAbortSession = controlTestReplacingSessionEnvelope(
        abortEvent, session: SessionRef("foreign-aborted-session"),
        sessionAttachment: automaticRequest.sessionAttachment)
    let wrongAbortSessionSnapshot = WorkHostControlReducer.reduce(
        Array(persisted[..<abortIndex]) + [wrongAbortSession])
    XCTAssertNil(
        wrongAbortSessionSnapshot.sessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: automaticCommand.commandID)?.abort)
    XCTAssertFalse(wrongAbortSessionSnapshot.semanticProjectionValid)
    XCTAssertEqual(wrongAbortSessionSnapshot.quarantinedEvents.last?.eventID, abortEvent.eventID)

    let wrongAbortAttachment = controlTestReplacingSessionEnvelope(
        abortEvent, session: automaticSession,
        sessionAttachment: SessionAttachmentRef("foreign-aborted-attachment"))
    let wrongAbortAttachmentSnapshot = WorkHostControlReducer.reduce(
        Array(persisted[..<abortIndex]) + [wrongAbortAttachment])
    XCTAssertNil(
        wrongAbortAttachmentSnapshot.sessionCreation(
            work: controlTestWork, client: controlTestClient,
            commandID: automaticCommand.commandID)?.abort)
    XCTAssertFalse(wrongAbortAttachmentSnapshot.semanticProjectionValid)
    XCTAssertEqual(wrongAbortAttachmentSnapshot.quarantinedEvents.last?.eventID, abortEvent.eventID)
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
    ("phase3 Work Host control: cache follows local appends", {
        try await test_workHostControlJournalCacheTracksLocalAppends()
    }),
    ("phase3 Work Host control: appends extend the actor cache", {
        try await test_workHostControlJournalExtendsCacheByAppendBytes()
    }),
    ("phase3 Work Host control: large target scans retain bounded state", {
        try await test_workHostControlJournalTargetScanKeepsBoundedStateForLargeJournal()
    }),
    ("phase3 Work Host control: existing Work Session creation is durably idempotent", {
        try await test_workHostControlJournalDurablyReconcilesExistingWorkSessionCreation()
    }),
    ("phase3 Work Host control: terminal Session reference has no Work mirror", {
        try await test_workHostControlJournalRecordsTerminalSessionReferenceWithoutWorkMirror()
    }),
    ("phase3 Work Host control: failed Session creation blocks overtaking and recovers", {
        try await test_workHostControlJournalBlocksMutationsBehindFailedSessionCreationAndRecoversAfterReopen()
    }),
]
