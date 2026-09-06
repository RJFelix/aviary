import Foundation
@testable import AviaryCore

private func assertThrows(_ body: () throws -> Void, line: Int = #line) {
    do {
        try body()
        XCTFail("expected an error", line: line)
    } catch {
        Harness.countAssertion()
    }
}

func testAttachmentQualifiedIdentityKeepsSessionsIndependent() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-attachment-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory))
    let work = WorkRef(workHostID: "key-host", workID: "shared-work")
    let client = ClientRef("key-client")
    let sessionA = try XCTUnwrap(WorkSessionKey(
        work: work, session: SessionRef("session-a"),
        sessionJournal: .session(
            SessionRef("session-a"), journalID: "journal-a",
            authority: TimelineAuthorityRef("key-host")),
        sessionAttachment: SessionAttachmentRef("session-attachment-a")))
    let sessionB = try XCTUnwrap(WorkSessionKey(
        work: work, session: SessionRef("session-b"),
        sessionJournal: .session(
            SessionRef("session-b"), journalID: "journal-b",
            authority: TimelineAuthorityRef("key-host")),
        sessionAttachment: SessionAttachmentRef("session-attachment-b")))
    let keyA = try XCTUnwrap(ServiceAttachmentKey(
        client: client, clientAttachment: ClientAttachmentRef("client-attachment-a"),
        workSession: sessionA))
    let keyB = try XCTUnwrap(ServiceAttachmentKey(
        client: client, clientAttachment: ClientAttachmentRef("client-attachment-b"),
        workSession: sessionB))

    let intentA = try WorkServiceAttachedWorkIntentStore(home: home, key: keyA)
    let intentB = try WorkServiceAttachedWorkIntentStore(home: home, key: keyB)
    XCTAssertNotEqual(intentA.url, intentB.url)
    XCTAssertEqual(
        intentA.url,
        try WorkServiceAttachedWorkIntentStore(home: home, key: keyA).url)
    XCTAssertEqual(
        intentA.checkpointURL,
        try WorkServiceAttachedWorkCheckpointStore(home: home, key: keyA).url)
    XCTAssertNotEqual(
        intentA.checkpointURL,
        try WorkServiceAttachedWorkCheckpointStore(home: home, key: keyB).url)

    let workJournal = JournalRef.work(work, journalID: "shared-work-journal")
    let requestA = WorkServiceCommandRequest(
        work: work, journal: workJournal, attachment: keyA.clientAttachment,
        commandID: "command-a", client: client,
        sessionAttachment: keyA.workSession.sessionAttachment,
        causalWorkCursor: JournalCursor(journal: workJournal, sequence: 0),
        kind: .send, value: "session-a")
    let requestB = WorkServiceCommandRequest(
        work: work, journal: workJournal, attachment: keyB.clientAttachment,
        commandID: "command-b", client: client,
        sessionAttachment: keyB.workSession.sessionAttachment,
        causalWorkCursor: JournalCursor(journal: workJournal, sequence: 0),
        kind: .send, value: "session-b")
    try intentA.retain(requestA, state: .indeterminate)
    try intentB.retain(requestB, state: .indeterminate)
    XCTAssertEqual(try intentA.load()?.request, requestA)
    XCTAssertEqual(try intentB.load()?.request, requestB)
    assertThrows { try intentA.retain(requestB, state: .indeterminate) }

    var restoredByAttachment: [ServiceAttachmentKey: String] = [:]
    restoredByAttachment[keyA] = "session-a"
    restoredByAttachment[keyB] = "session-b"
    XCTAssertEqual(restoredByAttachment.count, 2)
    var hidden = Set<ServiceAttachmentKey>()
    hidden.insert(keyA)
    XCTAssertTrue(hidden.contains(keyA))
    XCTAssertFalse(hidden.contains(keyB))
    XCTAssertEqual(restoredByAttachment[keyB], "session-b")

    let startA = try ServiceBackedStartIntentStore(home: home, key: keyA)
    let startB = try ServiceBackedStartIntentStore(home: home, key: keyB)
    XCTAssertNotEqual(startA.url, startB.url)
    XCTAssertEqual(startA.url, try ServiceBackedStartIntentStore(home: home, key: keyA).url)
}

func testAttachTargetKeyIsExactAndDoesNotCollapseSessionRelationships() throws {
    let work = WorkRef(workHostID: "target-host", workID: "target-work")
    let client = ClientRef("target-client")
    let firstSession = SessionRef("target-session-a")
    let secondSession = SessionRef("target-session-b")
    let firstJournal = JournalRef.session(
        firstSession, journalID: "target-journal-a", authority: TimelineAuthorityRef("target-host"))
    let secondJournal = JournalRef.session(
        secondSession, journalID: "target-journal-b", authority: TimelineAuthorityRef("target-host"))
    let first = try XCTUnwrap(AttachTargetKey(
        client: client, workSession: try XCTUnwrap(WorkSessionKey(
            work: work, session: firstSession, sessionJournal: firstJournal,
            sessionAttachment: SessionAttachmentRef("target-a")))))
    let second = try XCTUnwrap(AttachTargetKey(
        client: client, workSession: try XCTUnwrap(WorkSessionKey(
            work: work, session: secondSession, sessionJournal: secondJournal,
            sessionAttachment: SessionAttachmentRef("target-b")))))
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first.workSession.sessionAttachment, SessionAttachmentRef("target-a"))
}

func testConflictingSessionAttachmentFactsAreWithheld() throws {
    let work = WorkRef(workHostID: "conflict-host", workID: "conflict-work")
    let attachment = SessionAttachmentRef("reused-relationship")
    let firstSession = SessionRef("first-session")
    let secondSession = SessionRef("second-session")
    let firstJournal = JournalRef.session(
        firstSession, journalID: "first-journal", authority: TimelineAuthorityRef("conflict-host"))
    let secondJournal = JournalRef.session(
        secondSession, journalID: "second-journal", authority: TimelineAuthorityRef("conflict-host"))
    func relationship(
        session: SessionRef, journal: JournalRef, isAttached: Bool = true
    ) -> WorkServiceSessionAttachmentDescriptor {
        let cursor = JournalCursor(journal: journal, eventID: "cursor", sequence: 1)
        let workJournal = JournalRef.work(work, journalID: "conflict-work-journal")
        let workCursor = JournalCursor(journal: workJournal, eventID: "work-cursor", sequence: 1)
        return WorkServiceSessionAttachmentDescriptor(
            session: session, sessionJournal: journal, sessionAttachment: attachment,
            publication: .mirrored, causalSessionCursor: JournalCursor(journal: journal, sequence: 0),
            sessionCursor: cursor, causalWorkCursor: workCursor,
            resultingWorkCursor: workCursor, capabilities: [.observe], isAttached: isAttached)
    }
    let descriptor = try WorkServiceWorkDescriptor(
        work: work, journal: .work(work, journalID: "conflict-work-journal"),
        recordedDisposition: .reusable, execution: .idle, currentRun: nil,
        currentRunSession: nil, currentRunSessionAttachment: nil,
        hostObservation: nil,
        sessionAttachments: [relationship(session: firstSession, journal: firstJournal),
                             relationship(session: secondSession, journal: secondJournal)])
    XCTAssertTrue(descriptor.attachmentQualifiedSessionTargets.isEmpty)
    let conflictingTarget: WorkSessionKey? =
        descriptor.exactAttachmentQualifiedSessionTarget(attachment)
    XCTAssertNil(conflictingTarget)

    let detachedDescriptor = try WorkServiceWorkDescriptor(
        work: work, journal: .work(work, journalID: "conflict-work-journal"),
        recordedDisposition: .reusable, execution: .idle, currentRun: nil,
        currentRunSession: nil, currentRunSessionAttachment: nil,
        hostObservation: nil,
        sessionAttachments: [relationship(
            session: firstSession, journal: firstJournal, isAttached: false)])
    XCTAssertTrue(detachedDescriptor.attachmentQualifiedSessionTargets.isEmpty)
}

func testAttachmentQualifiedIdentityRejectsForgedAndOversizedKeys() throws {
    let work = WorkRef(workHostID: "identity-host", workID: "identity-work")
    let session = SessionRef("identity-session")
    let attachment = SessionAttachmentRef("identity-session-attachment")
    let foreignAuthority = JournalRef.session(
        session, journalID: "identity-journal", authority: TimelineAuthorityRef("foreign-host"))
    XCTAssertNil(WorkSessionKey(
        work: work, session: session, sessionJournal: foreignAuthority,
        sessionAttachment: attachment))

    let foreignOwner = JournalRef.session(
        SessionRef("different-session"), journalID: "identity-journal",
        authority: TimelineAuthorityRef("identity-host"))
    XCTAssertNil(WorkSessionKey(
        work: work, session: session, sessionJournal: foreignOwner,
        sessionAttachment: attachment))

    let oversized = String(repeating: "x", count: WorkServiceBounds.maxIdentityCharacters + 1)
    let oversizedWork = WorkRef(workHostID: "identity-host", workID: oversized)
    let validJournal = JournalRef.session(
        session, journalID: "identity-journal", authority: TimelineAuthorityRef("identity-host"))
    XCTAssertNil(WorkSessionKey(
        work: oversizedWork, session: session, sessionJournal: validJournal,
        sessionAttachment: attachment))
    XCTAssertNil(WorkSessionKey(
        work: work, session: session, sessionJournal: validJournal,
        sessionAttachment: SessionAttachmentRef(oversized)))
    XCTAssertNil(ServiceAttachmentKey(
        client: ClientRef("identity-client"), clientAttachment: ClientAttachmentRef(oversized),
        work: work, session: session, sessionJournal: validJournal,
        sessionAttachment: attachment))
    XCTAssertNil(WorkSessionKey(
        work: work, session: session, sessionJournal: validJournal,
        sessionAttachment: SessionAttachmentRef("")))

    let validKey = try XCTUnwrap(ServiceAttachmentKey(
        client: ClientRef("identity-client"), clientAttachment: ClientAttachmentRef("identity-client-attachment"),
        work: work, session: session, sessionJournal: validJournal,
        sessionAttachment: attachment))
    var forgedJSON = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(validKey)) as? [String: Any])
    var forgedWorkSession = try XCTUnwrap(forgedJSON["workSession"] as? [String: Any])
    var forgedJournal = try XCTUnwrap(forgedWorkSession["sessionJournal"] as? [String: Any])
    forgedJournal["authority"] = ["authorityID": "foreign-host"]
    forgedWorkSession["sessionJournal"] = forgedJournal
    forgedJSON["workSession"] = forgedWorkSession
    let forgedData = try JSONSerialization.data(withJSONObject: forgedJSON)
    assertThrows { _ = try JSONDecoder().decode(ServiceAttachmentKey.self, from: forgedData) }
    var unknownFieldJSON = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(validKey)) as? [String: Any])
    unknownFieldJSON["futureField"] = true
    let unknownFieldData = try JSONSerialization.data(withJSONObject: unknownFieldJSON)
    assertThrows { _ = try JSONDecoder().decode(ServiceAttachmentKey.self, from: unknownFieldData) }
    var futureVersionJSON = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(validKey)) as? [String: Any])
    futureVersionJSON["schemaVersion"] = ServiceAttachmentKey.schemaVersion + 1
    let futureVersionData = try JSONSerialization.data(withJSONObject: futureVersionJSON)
    assertThrows { _ = try JSONDecoder().decode(ServiceAttachmentKey.self, from: futureVersionData) }
}

func testAttachmentQualifiedDurableEnvelopesRejectUnknownKeys() throws {
    let work = WorkRef(workHostID: "envelope-host", workID: "envelope-work")
    let workJournal = JournalRef.work(work, journalID: "envelope-work-journal")
    let session = SessionRef("envelope-session")
    let sessionJournal = JournalRef.session(
        session, journalID: "envelope-session-journal",
        authority: TimelineAuthorityRef(work.workHostID))
    let sessionAttachment = SessionAttachmentRef("envelope-session-attachment")
    let client = ClientRef("envelope-client")
    let clientAttachment = ClientAttachmentRef("envelope-client-attachment")
    let cursor = JournalCursor(journal: workJournal, sequence: 0)
    let request = WorkServiceCommandRequest(
        work: work, journal: workJournal, attachment: clientAttachment,
        commandID: "envelope-command", client: client,
        sessionAttachment: sessionAttachment, causalWorkCursor: cursor,
        kind: .send, value: "payload")
    let record = WorkServiceAttachedWorkIntentStore.Record(
        request: request, state: .indeterminate)
    var recordObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    recordObject["futureField"] = true
    let recordData = try JSONSerialization.data(withJSONObject: recordObject)
    assertThrows {
        _ = try JSONDecoder().decode(
            WorkServiceAttachedWorkIntentStore.Record.self, from: recordData)
    }

    let start = try ServiceBackedStartIntent(
        client: client, work: work, session: session, sessionJournal: sessionJournal,
        sessionAttachment: sessionAttachment, clientAttachment: clientAttachment,
        causalWorkCursor: cursor, commandID: "envelope-start", prompt: "start")
    var startObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as? [String: Any])
    startObject["futureField"] = true
    let startData = try JSONSerialization.data(withJSONObject: startObject)
    assertThrows { _ = try JSONDecoder().decode(ServiceBackedStartIntent.self, from: startData) }

    let authorization = WorkServiceAuthorizationOutcome(
        requested: [.observe], granted: [.observe], denied: [])
    let attachment = WorkServiceClientAttachment(
        attachment: clientAttachment, client: client, session: session,
        sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
        authorization: authorization)
    let descriptor = try WorkServiceWorkDescriptor(
        work: work, journal: workJournal, recordedDisposition: .reusable, execution: .idle,
        currentRun: nil, currentRunSession: nil, currentRunSessionAttachment: nil,
        hostObservation: nil, attachments: [attachment])
    let controlJournal = JournalRef.workHost(WorkHostRef(work.workHostID))
    let ack = WorkServiceAcknowledgeReadRequest(
        work: work, journal: workJournal, attachment: clientAttachment, client: client,
        target: .work(journal: workJournal), cursor: cursor, commandID: "envelope-ack",
        causalControlCursor: JournalCursor(journal: controlJournal, sequence: 0))
    let checkpointRecord = WorkServiceAttachedWorkCheckpointStore.Record(
        client: client, work: work, journal: workJournal, session: session,
        sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
        attachment: clientAttachment, hostInstance: nil, descriptor: descriptor,
        attachmentProjection: attachment, controlCursor: nil, committedWorkCursor: cursor,
        committedWorkPrefixDigest: nil, committedWorkSnapshot: nil,
        committedSessionCursor: JournalCursor(journal: sessionJournal, sequence: 0),
        committedSessionPrefixDigest: nil, committedSessionSnapshot: nil,
        stagedWorkCursor: nil, stagedWorkPrefixDigest: nil, stagedWorkSnapshot: nil,
        stagedWorkOmissions: [], stagedSessionCursor: nil, stagedSessionPrefixDigest: nil,
        stagedSessionSnapshot: nil, stagedSessionOmissions: [],
        pendingAcknowledgements: [.init(request: ack)])
    var checkpointRecordObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpointRecord)) as? [String: Any])
    checkpointRecordObject["futureField"] = true
    let checkpointRecordData = try JSONSerialization.data(withJSONObject: checkpointRecordObject)
    assertThrows {
        _ = try JSONDecoder().decode(
            WorkServiceAttachedWorkCheckpointStore.Record.self, from: checkpointRecordData)
    }
    var pendingObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(
            WorkServiceAttachedWorkCheckpointStore.PendingAcknowledgement(request: ack)))
            as? [String: Any])
    pendingObject["futureField"] = true
    let pendingData = try JSONSerialization.data(withJSONObject: pendingObject)
    assertThrows {
        _ = try JSONDecoder().decode(
            WorkServiceAttachedWorkCheckpointStore.PendingAcknowledgement.self, from: pendingData)
    }

    // DiskEnvelope is private by design; exercise its strict decoder through the real durable
    // path.  The existing file mode is restored after the atomic test mutation so a mode error
    // cannot mask the unknown-envelope-key rejection.
    let checkpointRoot = FileManager.default.temporaryDirectory.appending(
        path: "aviary-invalid-checkpoint-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: checkpointRoot, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let checkpointURL = checkpointRoot.appending(
        path: "record.json", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: checkpointRoot) }
    let checkpointStore = try WorkServiceAttachedWorkCheckpointStore(url: checkpointURL)
    try checkpointStore.save(checkpointRecord)
    var envelopeObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try Data(contentsOf: checkpointURL)) as? [String: Any])
    envelopeObject["futureField"] = true
    try JSONSerialization.data(withJSONObject: envelopeObject).write(
        to: checkpointURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                          ofItemAtPath: checkpointURL.path)
    assertThrows { _ = try checkpointStore.load() }
}

let casesAttachmentQualifiedIdentity: [Case] = [
    ("phase3 attachment identity keeps Sessions independent", {
        try testAttachmentQualifiedIdentityKeepsSessionsIndependent()
    }),
    ("phase3 Attach target identity is exact", {
        try testAttachTargetKeyIsExactAndDoesNotCollapseSessionRelationships()
    }),
    ("phase3 conflicting Session attachment facts are withheld", {
        try testConflictingSessionAttachmentFactsAreWithheld()
    }),
    ("phase3 forged and oversized identity keys are rejected", {
        try testAttachmentQualifiedIdentityRejectsForgedAndOversizedKeys()
    }),
    ("phase3 durable attachment envelopes reject unknown keys", {
        try testAttachmentQualifiedDurableEnvelopesRejectUnknownKeys()
    }),
]
