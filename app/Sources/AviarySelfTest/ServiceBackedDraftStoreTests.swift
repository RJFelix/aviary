import Foundation
@testable import AviaryCore

private func draftFixtureKey(_ suffix: String = "a") throws -> ServiceAttachmentKey {
    let work = WorkRef(workHostID: "draft-host", workID: "draft-work-\(suffix)")
    let session = SessionRef("draft-session-\(suffix)")
    let workSession = try XCTUnwrap(WorkSessionKey(
        work: work, session: session,
        sessionJournal: .session(
            session, journalID: "draft-journal-\(suffix)",
            authority: TimelineAuthorityRef(work.workHostID)),
        sessionAttachment: SessionAttachmentRef("draft-session-attachment-\(suffix)")))
    return try XCTUnwrap(ServiceAttachmentKey(
        client: ClientRef("draft-client-\(suffix)"),
        clientAttachment: ClientAttachmentRef("draft-client-attachment-\(suffix)"),
        workSession: workSession))
}

private func draftFixtureHome(_ name: String = "fixture") -> (AgentHome, URL) {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-drafts-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    return (AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory)), root)
}

private func draftDispositionProjection(
    key: ServiceAttachmentKey,
    commandState: CommandDeliveryState? = nil,
    pendingState: WorkServiceAttachedWorkPendingState? = nil,
    pendingClient: ClientRef? = nil
) throws -> WorkServiceAttachedWorkProjection {
    let work = key.workSession.work
    let workJournal = JournalRef.work(work)
    let session = key.workSession.session
    let sessionJournal = key.workSession.sessionJournal
    let sessionAttachment = key.workSession.sessionAttachment
    let cursor = JournalCursor(journal: workJournal, eventID: "draft-work-1", sequence: 1)
    let sessionCursor = JournalCursor(
        journal: sessionJournal, eventID: "draft-session-1", sequence: 1)
    let authorization = WorkServiceAuthorizationOutcome(
        requested: Set(WorkServiceCapability.allCases),
        granted: Set(WorkServiceCapability.allCases), denied: [])
    let attachment = WorkServiceClientAttachment(
        attachment: key.clientAttachment, client: key.client, session: session,
        sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
        authorization: authorization)
    let relationship = WorkServiceSessionAttachmentDescriptor(
        session: session, sessionJournal: sessionJournal,
        sessionAttachment: sessionAttachment, publication: .mirrored,
        causalSessionCursor: sessionCursor, sessionCursor: sessionCursor,
        causalWorkCursor: cursor, resultingWorkCursor: cursor,
        capabilities: [.observe, .control])
    let observation = try WorkServiceHostObservation(
        instance: WorkHostInstanceRef(
            host: WorkHostRef(work.workHostID), instanceID: "draft-disposition-instance",
            startIdentity: "draft-disposition-start"),
        reachability: .observedReachable, currentRun: nil,
        currentRunSession: nil, currentRunSessionAttachment: nil,
        servedCursor: cursor, sourceCompleteness: .complete)
    let descriptor = try WorkServiceWorkDescriptor(
        work: work, journal: workJournal, recordedDisposition: .reusable,
        execution: .idle, currentRun: nil, currentRunSession: nil,
        currentRunSessionAttachment: nil, hostObservation: observation,
        attachments: [attachment], sessionAttachments: [relationship])
    var workSnapshot = WorkSnapshot()
    workSnapshot.journal = workJournal
    workSnapshot.work = work
    workSnapshot.workHost = WorkHostRef(work.workHostID)
    workSnapshot.lifecycle = .active
    workSnapshot.execution = .idle
    if let commandState {
        let canonicalID = WorkServiceCommandLedgerIdentity.commandID(
            client: key.client, commandID: "draft-command")
        workSnapshot.commands[canonicalID] = WorkCommandSnapshot(
            command: CommandRef(
                commandID: canonicalID, client: key.client,
                sessionAttachment: sessionAttachment, causalCursor: cursor),
            state: commandState, actor: TimelineActor(actorID: "draft-test", kind: "test"),
            hostSequence: 1)
    }
    var sessionSnapshot = SessionSnapshot()
    sessionSnapshot.journal = sessionJournal
    sessionSnapshot.session = session
    sessionSnapshot.lifecycle = .active
    let pending: WorkServiceAttachedWorkPendingCommand?
    if let pendingState {
        pending = WorkServiceAttachedWorkPendingCommand(
            state: pendingState, kind: .send, commandID: "draft-command",
            client: pendingClient ?? key.client, attachment: key.clientAttachment,
            sessionAttachment: sessionAttachment, causalWorkCursor: cursor,
            valueDigest: ServiceBackedDraftHandoff.digest(of: "draft command"))
    } else {
        pending = nil
    }
    return WorkServiceAttachedWorkProjection(
        descriptor: descriptor, attachment: attachment,
        capabilities: Set(WorkServiceCapability.allCases), workSnapshot: workSnapshot,
        sessionSnapshot: sessionSnapshot, workCursor: cursor, sessionCursor: sessionCursor,
        workSourceCompleteness: .complete, sessionSourceCompleteness: .complete,
        pendingCommand: pending)
}

private func assertDraftError(
    _ expected: ServiceBackedDraftError? = nil,
    _ body: () throws -> Void,
    line: Int = #line
) {
    do {
        try body()
        XCTFail("expected draft store failure", line: line)
    } catch let error as ServiceBackedDraftError {
        if let expected { XCTAssertEqual(error, expected, line: line) }
        else { Harness.countAssertion() }
    } catch {
        XCTFail("unexpected draft store error", line: line)
    }
}

func testServiceBackedDraftStoreRoundTripReplacementAndCleanup() throws {
    let (home, root) = draftFixtureHome("roundtrip")
    defer { try? FileManager.default.removeItem(at: root) }
    let key = try draftFixtureKey()
    let store = try ServiceBackedDraftStore(home: home, key: key)
    XCTAssertTrue(store.url.lastPathComponent.hasPrefix("draft-v1."))
    XCTAssertFalse(store.url.lastPathComponent.contains("draft-client"))
    XCTAssertFalse(store.url.lastPathComponent.contains("draft-work"))
    XCTAssertFalse(store.url.lastPathComponent.contains("draft-session"))
    let directoryMode = (try FileManager.default.attributesOfItem(atPath: store.directory.path))[
        .posixPermissions] as? NSNumber
    XCTAssertEqual(directoryMode?.intValue, 0o700)
    XCTAssertNil(try store.load())

    try store.replace("first draft", expectedGeneration: nil)
    XCTAssertEqual(try store.load()?.text, "first draft")
    let before = try Data(contentsOf: store.url)
    try store.replace("first draft", expectedGeneration: 1)
    XCTAssertEqual(try Data(contentsOf: store.url), before)
    try store.replace("second draft", expectedGeneration: 1)
    XCTAssertEqual(try store.load()?.text, "second draft")
    // A GUI relaunch reconstructs the store from AgentHome + the durable attachment key;
    // no in-memory store or view identity participates in recovery.
    let relaunched = try ServiceBackedDraftStore(home: home, key: key)
    XCTAssertEqual(try relaunched.load()?.text, "second draft")
    try relaunched.replace("", expectedGeneration: 2)
    XCTAssertNil(try ServiceBackedDraftStore(home: home, key: key).load())
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    try store.clear(expectedGeneration: nil)
    XCTAssertNil(try store.load())
}

func testServiceBackedDraftStoreIsolatesExactAttachments() throws {
    let (home, root) = draftFixtureHome("isolation")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ServiceBackedDraftStore(home: home, key: draftFixtureKey("a"))
    let second = try ServiceBackedDraftStore(home: home, key: draftFixtureKey("b"))
    XCTAssertNotEqual(first.url, second.url)
    XCTAssertEqual(first.directory, second.directory)
    try first.replace("only attachment a", expectedGeneration: nil)
    XCTAssertEqual(try first.load()?.text, "only attachment a")
    XCTAssertNil(try second.load())
    try second.replace("only attachment b", expectedGeneration: nil)
    XCTAssertEqual(try first.load()?.text, "only attachment a")
    XCTAssertEqual(try second.load()?.text, "only attachment b")
}

func testServiceBackedDraftStoreRejectsMalformedWrongAndOversizeRecords() throws {
    let (home, root) = draftFixtureHome("corruption")
    defer { try? FileManager.default.removeItem(at: root) }
    let key = try draftFixtureKey()
    let otherKey = try draftFixtureKey("other")
    let store = try ServiceBackedDraftStore(home: home, key: key)
    try store.replace("safe", expectedGeneration: nil)

    var unknownObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
    unknownObject["unexpected"] = true
    let unknownData = try JSONSerialization.data(withJSONObject: unknownObject, options: [.sortedKeys])
    try unknownData.write(to: store.url, options: .atomic)
    assertDraftError(.corrupt) { _ = try store.load() }

    try Data("not json".utf8).write(to: store.url, options: .atomic)
    assertDraftError(.corrupt) { _ = try store.load() }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let wrongRecord: [String: Any] = [
        "schemaVersion": ServiceBackedDraftStore.schemaVersion,
        "key": try JSONSerialization.jsonObject(with: encoder.encode(otherKey)),
        "text": "wrong attachment",
    ]
    let wrongData = try JSONSerialization.data(withJSONObject: wrongRecord, options: [.sortedKeys])
    try wrongData.write(to: store.url, options: .atomic)
    assertDraftError(.corrupt) { _ = try store.load() }

    try Data("{\"key\":{},\"schemaVersion\":1,\"text\":\"x\"}".utf8)
        .write(to: store.url, options: .atomic)
    assertDraftError(.corrupt) { _ = try store.load() }
    assertDraftError(.tooLarge) {
        try store.replace(
            String(repeating: "x", count: WorkServiceBounds.maxCommandValueCharacters + 1),
            expectedGeneration: 1)
    }
    XCTAssertTrue(store.url.lastPathComponent.contains("draft-v1."))
}

func testServiceBackedDraftStoreRejectsUnboundedGenerationWithoutTrapping() throws {
    let (home, root) = draftFixtureHome("generation-bound")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ServiceBackedDraftStore(home: home, key: draftFixtureKey())
    _ = try store.replace("bounded", expectedGeneration: nil)
    var record = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
    var snapshot = try XCTUnwrap(record["snapshot"] as? [String: Any])
    snapshot["generation"] = Int.max
    record["snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        .write(to: store.url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: store.url.path)
    assertDraftError(.corrupt) { _ = try store.load() }
    _ = try store.replace("repaired", expectedGeneration: nil)
    XCTAssertEqual(try store.load()?.generation, 1)
    XCTAssertEqual(try store.load()?.text, "repaired")
}

func testServiceBackedDraftStoreKeepsCorruptionRowLocalAndAllowsExplicitRepair() throws {
    let (home, root) = draftFixtureHome("row-local")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ServiceBackedDraftStore(home: home, key: draftFixtureKey("first"))
    let second = try ServiceBackedDraftStore(home: home, key: draftFixtureKey("second"))
    try first.replace("first draft", expectedGeneration: nil)
    try second.replace("second draft", expectedGeneration: nil)

    // A corrupt sibling must not make the exact first attachment unavailable.
    try Data("not json".utf8).write(to: second.url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: second.url.path)
    XCTAssertEqual(try first.load()?.text, "first draft")
    assertDraftError(.corrupt) { _ = try second.load() }

    // Explicit user editing may replace a malformed regular 0600 record in disposable Aviary
    // state. The normal load remains fail-closed until that explicit edit occurs.
    try Data("still not json".utf8).write(to: first.url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: first.url.path)
    assertDraftError(.corrupt) { _ = try first.load() }
    assertDraftError(.conflict) {
        _ = try first.replace("stale repair", expectedGeneration: 1)
    }
    try first.replace("repaired draft", expectedGeneration: nil)
    XCTAssertEqual(try first.load()?.text, "repaired draft")
}

func testServiceBackedDraftStoreRejectsSymlinkAndInsecureMode() throws {
    let (home, root) = draftFixtureHome("filesystem")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ServiceBackedDraftStore(home: home, key: draftFixtureKey())
    try store.replace("protected draft", expectedGeneration: nil)

    let real = store.directory.appending(path: "real-draft.json", directoryHint: .notDirectory)
    try FileManager.default.moveItem(at: store.url, to: real)
    try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: real)
    assertDraftError(.corrupt) { _ = try store.load() }
    assertDraftError(.corrupt) {
        try store.replace("must not follow symlink", expectedGeneration: 1)
    }
    try FileManager.default.removeItem(at: store.url)
    try FileManager.default.moveItem(at: real, to: store.url)

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: store.url.path)
    assertDraftError(.corrupt) { _ = try store.load() }
    assertDraftError(.corrupt) {
        try store.replace("must not repair insecure file", expectedGeneration: 1)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: store.url.path)
    XCTAssertEqual(try store.load()?.text, "protected draft")

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: store.directory.path)
    assertDraftError(.corrupt) { _ = try store.load() }
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: store.directory.path)
}

func testServiceBackedDraftStoreEnforcesBoundedRecordCount() throws {
    let (home, root) = draftFixtureHome("capacity")
    defer { try? FileManager.default.removeItem(at: root) }
    var stores: [ServiceBackedDraftStore] = []
    for index in 0..<ServiceBackedDraftStore.maximumRecords {
        let store = try ServiceBackedDraftStore(home: home, key: draftFixtureKey(String(index)))
        try store.replace("draft \(index)", expectedGeneration: nil)
        stores.append(store)
    }
    let overflow = try ServiceBackedDraftStore(home: home, key: draftFixtureKey("overflow"))
    assertDraftError(.capacity) {
        try overflow.replace("one more", expectedGeneration: nil)
    }
    // Existing records remain readable and an idempotent retry is allowed at capacity.
    try stores[0].replace("draft 0", expectedGeneration: 1)
    XCTAssertEqual(try stores[0].load()?.text, "draft 0")
}

func testServiceBackedDraftStoreBoundsNonRecordDirectoryEntries() throws {
    let (home, root) = draftFixtureHome("directory-bound")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ServiceBackedDraftStore(home: home, key: draftFixtureKey())
    for index in 0...ServiceBackedDraftStore.maximumDirectoryEntries {
        let junk = store.directory.appending(path: "junk-\(index)", directoryHint: .notDirectory)
        try Data("junk".utf8).write(to: junk)
    }
    assertDraftError(.capacity) {
        try store.replace("bounded", expectedGeneration: nil)
    }
    XCTAssertNil(try store.load())
}

func testServiceBackedDraftStoreAcceptsReadableHomeAndRejectsWritableHome() throws {
    let (home, root) = draftFixtureHome("home-permissions")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: home.root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: home.root.path)
    let store = try ServiceBackedDraftStore(home: home, key: draftFixtureKey())
    try store.replace("readable home is acceptable", expectedGeneration: nil)
    XCTAssertEqual(try store.load()?.text, "readable home is acceptable")
    let subtreeMode = (try FileManager.default.attributesOfItem(atPath: store.directory.path))[
        .posixPermissions] as? NSNumber
    XCTAssertEqual(subtreeMode?.intValue, 0o700)

    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o775))], ofItemAtPath: home.root.path)
    assertDraftError(.corrupt) {
        _ = try ServiceBackedDraftStore(home: home, key: draftFixtureKey("writable"))
    }
}

func testServiceBackedDraftStoreUsesGenerationCASAcrossInstances() throws {
    let (home, root) = draftFixtureHome("generation-cas")
    defer { try? FileManager.default.removeItem(at: root) }
    let key = try draftFixtureKey()
    let first = try ServiceBackedDraftStore(home: home, key: key)
    let second = try ServiceBackedDraftStore(home: home, key: key)
    let pending = try first.beginHandoff(
        text: "submitted", kind: .send, commandID: "cas-command", expectedGeneration: nil)
    XCTAssertEqual(pending.generation, 1)
    let edited = try XCTUnwrap(
        second.replace("newer", expectedGeneration: pending.generation))
    XCTAssertEqual(edited.generation, 2)

    // A stale resolver cannot unlink or replace the newer value, even when it supplies the old
    // text and accepted outcome. The newer marker remains durable for explicit reconciliation.
    assertDraftError(.conflict) {
        _ = try first.resolveHandoff(
            commandID: "cas-command", accepted: true, currentText: "submitted",
            expectedGeneration: pending.generation)
    }
    XCTAssertEqual(try first.load()?.text, "newer")
    XCTAssertEqual(try first.load()?.generation, edited.generation)
    XCTAssertEqual(try first.load()?.handoff?.commandID, "cas-command")
    assertDraftError(.conflict) {
        _ = try first.replace("stale overwrite", expectedGeneration: pending.generation)
    }
}

func testServiceBackedDraftStoreClassifiesOnlyExactCanonicalHandoffs() throws {
    let key = try draftFixtureKey()
    let handoff = try ServiceBackedDraftHandoff(
        text: "draft command", kind: .send, commandID: "draft-command")
    let commandExpectations: [(CommandDeliveryState, ServiceBackedDraftHandoffDisposition)] = [
        (.accepted, .accepted), (.delivered, .accepted),
        (.rejected, .rejected), (.notDelivered, .rejected),
        (.indeterminate, .unresolved)
    ]
    for (state, expected) in commandExpectations {
        let projection = try draftDispositionProjection(key: key, commandState: state)
        XCTAssertEqual(
            ServiceBackedDraftHandoffDisposition.classify(
                handoff, key: key, projection: projection), expected)
    }
    let absent = try draftDispositionProjection(key: key)
    XCTAssertEqual(
        ServiceBackedDraftHandoffDisposition.classify(handoff, key: key, projection: absent),
        .unresolved)

    let pendingExpectations: [(WorkServiceAttachedWorkPendingState, ServiceBackedDraftHandoffDisposition)] = [
        (.stale, .rejected), (.indeterminate, .unresolved),
        (.awaitingCanonicalEvidence, .unresolved)
    ]
    for (state, expected) in pendingExpectations {
        let projection = try draftDispositionProjection(key: key, pendingState: state)
        XCTAssertEqual(
            ServiceBackedDraftHandoffDisposition.classify(
                handoff, key: key, projection: projection), expected)
    }

    let foreignKey = try draftFixtureKey("foreign")
    let localProjection = try draftDispositionProjection(key: key, pendingState: .stale)
    XCTAssertEqual(
        ServiceBackedDraftHandoffDisposition.classify(
            handoff, key: foreignKey, projection: localProjection), .unresolved)
    let foreignPending = try draftDispositionProjection(
        key: key, pendingState: .stale, pendingClient: ClientRef("foreign-client"))
    XCTAssertEqual(
        ServiceBackedDraftHandoffDisposition.classify(
            handoff, key: key, projection: foreignPending), .unresolved)
}

func testServiceBackedDraftStoreHandoffSurvivesCrashAndResolvesSafely() throws {
    let (home, root) = draftFixtureHome("handoff")
    defer { try? FileManager.default.removeItem(at: root) }
    let key = try draftFixtureKey()
    let store = try ServiceBackedDraftStore(home: home, key: key)

    let pending = try store.beginHandoff(
        text: "submitted once", kind: .send, commandID: "cmd-1", expectedGeneration: nil)
    XCTAssertEqual(pending.text, "submitted once")
    XCTAssertEqual(pending.handoff?.commandID, "cmd-1")
    XCTAssertEqual(
        pending.handoff?.submittedTextDigest,
        ServiceBackedDraftHandoff.digest(of: "submitted once"))
    // A relaunch sees the durable marker before any transport response arrives.
    XCTAssertEqual(try ServiceBackedDraftStore(home: home, key: key).load(), pending)
    XCTAssertEqual(
        try store.beginHandoff(
            text: "submitted once", kind: .send, commandID: "cmd-1", expectedGeneration: 1),
        pending)
    assertDraftError(.conflict) {
        _ = try store.beginHandoff(
            text: "other command", kind: .send, commandID: "cmd-2", expectedGeneration: 1)
    }

    // The GUI may edit the next draft while the command is in flight. Supplying that current
    // value directly to resolution persists it in the same lock transaction; it must survive an
    // accepted response rather than being lost by an unlink followed by a later editor flush.
    let afterEditedAccept = try XCTUnwrap(
        try store.resolveHandoff(
            commandID: "cmd-1", accepted: true, currentText: "next draft", expectedGeneration: 1))
    XCTAssertEqual(afterEditedAccept.text, "next draft")
    XCTAssertNil(afterEditedAccept.handoff)
    let persisted = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
    XCTAssertFalse(persisted.contains("submitted once"))
    // A duplicate response has no marker to prove what happened; it must not be interpreted as
    // successful delivery or overwrite the newer editor value.
    assertDraftError(.conflict) {
        _ = try store.resolveHandoff(
            commandID: "cmd-1", accepted: true, currentText: "ignored", expectedGeneration: 1)
    }

    // Rejected delivery also removes only the marker and persists the GUI's current value.
    _ = try store.beginHandoff(
        text: "submitted reject", kind: .send, commandID: "cmd-2", expectedGeneration: 2)
    let afterReject = try XCTUnwrap(
        try store.resolveHandoff(
            commandID: "cmd-2", accepted: false, currentText: "newer after reject",
            expectedGeneration: 3))
    XCTAssertEqual(afterReject.text, "newer after reject")
    XCTAssertNil(afterReject.handoff)
    XCTAssertNil(try store.load()?.handoff)
    assertDraftError(.conflict) {
        _ = try store.resolveHandoff(
            commandID: "cmd-2", accepted: false, currentText: "ignored", expectedGeneration: 4)
    }

    // Accepted delivery clears a current value only when its digest still matches the submitted
    // command. This is the one case where resolution removes the record entirely.
    _ = try store.beginHandoff(
        text: "clear me", kind: .send, commandID: "cmd-clear", expectedGeneration: 4)
    XCTAssertNil(try store.resolveHandoff(
        commandID: "cmd-clear", accepted: true, currentText: "clear me", expectedGeneration: 5))
    XCTAssertNil(try store.load())

    _ = try store.beginHandoff(
        text: "tampered draft", kind: .send, commandID: "cmd-3", expectedGeneration: nil)
    var tampered = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
    var tamperedSnapshot = try XCTUnwrap(tampered["snapshot"] as? [String: Any])
    var tamperedHandoff = try XCTUnwrap(tamperedSnapshot["handoff"] as? [String: Any])
    tamperedHandoff["submittedTextDigest"] = "sha256:bad"
    tamperedSnapshot["handoff"] = tamperedHandoff
    tampered["snapshot"] = tamperedSnapshot
    try JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
        .write(to: store.url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: store.url.path)
    assertDraftError(.corrupt) { _ = try store.load() }
    try store.replace("repaired after tamper", expectedGeneration: nil)
    XCTAssertEqual(try store.load()?.text, "repaired after tamper")
    XCTAssertNil(try store.load()?.handoff)
    _ = try store.beginHandoff(
        text: "final draft", kind: .send, commandID: "cmd-4", expectedGeneration: 1)
    XCTAssertNil(try store.resolveHandoff(
        commandID: "cmd-4", accepted: true, currentText: "final draft", expectedGeneration: 2))
    XCTAssertNil(try store.load())
    assertDraftError(.corrupt) {
        _ = try store.resolveHandoff(
            commandID: "cmd-4", accepted: true, currentText: "ignored", expectedGeneration: 1)
    }
}

/// Registration is intentionally left to the owning SelfTest integration lane.
let casesServiceBackedDraftStore: [(String, () async throws -> Void)] = [
    ("phase2 service-backed draft roundtrip", { try testServiceBackedDraftStoreRoundTripReplacementAndCleanup() }),
    ("phase2 service-backed draft attachment isolation", { try testServiceBackedDraftStoreIsolatesExactAttachments() }),
    ("phase2 service-backed draft rejects malformed records", { try testServiceBackedDraftStoreRejectsMalformedWrongAndOversizeRecords() }),
    ("phase2 service-backed draft rejects unbounded generation", { try testServiceBackedDraftStoreRejectsUnboundedGenerationWithoutTrapping() }),
    ("phase2 service-backed draft keeps corruption row-local", { try testServiceBackedDraftStoreKeepsCorruptionRowLocalAndAllowsExplicitRepair() }),
    ("phase2 service-backed draft rejects filesystem tampering", { try testServiceBackedDraftStoreRejectsSymlinkAndInsecureMode() }),
    ("phase2 service-backed draft record cap", { try testServiceBackedDraftStoreEnforcesBoundedRecordCount() }),
    ("phase2 service-backed draft bounds directory entries", { try testServiceBackedDraftStoreBoundsNonRecordDirectoryEntries() }),
    ("phase2 service-backed draft home permissions", { try testServiceBackedDraftStoreAcceptsReadableHomeAndRejectsWritableHome() }),
    ("phase2 service-backed draft generation CAS", { try testServiceBackedDraftStoreUsesGenerationCASAcrossInstances() }),
    ("phase2 service-backed draft handoff disposition", { try testServiceBackedDraftStoreClassifiesOnlyExactCanonicalHandoffs() }),
    ("phase2 service-backed draft handoff recovery", { try testServiceBackedDraftStoreHandoffSurvivesCrashAndResolvesSafely() }),
]
