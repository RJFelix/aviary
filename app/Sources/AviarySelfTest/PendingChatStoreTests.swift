import Foundation
@testable import AviaryCore

private func pendingChatTestHome() throws -> (AgentHome, URL) {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "aviary-pending-chats-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (AgentHome(root: root.appending(path: "home", directoryHint: .isDirectory)), root)
}

private func pendingChatTestKey(_ suffix: String = "a") throws -> ServiceAttachmentKey {
    let work = WorkRef(workHostID: "pending-host", workID: "pending-work")
    let session = SessionRef("pending-session-\(suffix)")
    let workSession = try XCTUnwrap(WorkSessionKey(
        work: work, session: session,
        sessionJournal: .session(session, journalID: "pending-journal-\(suffix)",
                                  authority: TimelineAuthorityRef("pending-host")),
        sessionAttachment: SessionAttachmentRef("pending-session-attachment-\(suffix)")))
    return try XCTUnwrap(ServiceAttachmentKey(
        client: ClientRef("pending-client"),
        clientAttachment: ClientAttachmentRef("pending-client-attachment-\(suffix)"),
        workSession: workSession))
}

private func pendingChatDeliveryProjection(
    key: ServiceAttachmentKey,
    externalCommandID: String,
    prompt: String,
    state: CommandDeliveryState,
    commandClient: ClientRef? = nil,
    commandSessionAttachment: SessionAttachmentRef? = nil,
    includeMessage: Bool = true,
    workOmissions: [WorkServiceOmission] = []
) throws -> WorkServiceAttachedWorkProjection {
    let work = key.workSession.work
    let workJournal = JournalRef.work(work)
    let session = key.workSession.session
    let sessionJournal = key.workSession.sessionJournal
    let sessionAttachment = key.workSession.sessionAttachment
    let client = commandClient ?? key.client
    let inputAttachment = commandSessionAttachment ?? sessionAttachment
    let workCursor = JournalCursor(
        journal: workJournal, eventID: "pending-work-cursor", sequence: 2)
    let sessionCursor = JournalCursor(
        journal: sessionJournal, eventID: "pending-session-cursor", sequence: 1)
    let authorization = WorkServiceAuthorizationOutcome(
        requested: Set(WorkServiceCapability.allCases),
        granted: Set(WorkServiceCapability.allCases), denied: [])
    let clientAttachment = WorkServiceClientAttachment(
        attachment: key.clientAttachment, client: key.client, session: session,
        sessionJournal: sessionJournal, sessionAttachment: sessionAttachment,
        authorization: authorization)
    let relationship = WorkServiceSessionAttachmentDescriptor(
        session: session, sessionJournal: sessionJournal,
        sessionAttachment: sessionAttachment, publication: .mirrored,
        causalSessionCursor: sessionCursor, sessionCursor: sessionCursor,
        causalWorkCursor: workCursor, resultingWorkCursor: workCursor,
        capabilities: [.observe, .control])
    let observation = try WorkServiceHostObservation(
        instance: WorkHostInstanceRef(
            host: WorkHostRef(work.workHostID), instanceID: "pending-delivery-instance",
            startIdentity: "pending-delivery-start"),
        reachability: .observedReachable, currentRun: nil,
        currentRunSession: nil, currentRunSessionAttachment: nil,
        servedCursor: workCursor, sourceCompleteness: .complete)
    let descriptor = try WorkServiceWorkDescriptor(
        work: work, journal: workJournal, recordedDisposition: .reusable,
        execution: .idle, currentRun: nil, currentRunSession: nil,
        currentRunSessionAttachment: nil, hostObservation: observation,
        attachments: [clientAttachment], sessionAttachments: [relationship])

    let run = RunRef("pending-delivery-run")
    let canonicalCommandID = WorkServiceCommandLedgerIdentity.commandID(
        client: client, commandID: externalCommandID)
    let acceptance = EventRef(journal: workJournal, eventID: "pending-start-accepted")
    let delivery = state == .accepted ? nil
        : EventRef(journal: workJournal, eventID: "pending-start-delivered")
    var workSnapshot = WorkSnapshot()
    workSnapshot.journal = workJournal
    workSnapshot.work = work
    workSnapshot.workHost = WorkHostRef(work.workHostID)
    workSnapshot.lifecycle = .active
    workSnapshot.execution = .idle
    workSnapshot.sessionAttachments[sessionAttachment.attachmentID] =
        WorkSessionAttachmentSnapshot(attachment: sessionAttachment, session: session)
    workSnapshot.sessionAttachments[inputAttachment.attachmentID] =
        WorkSessionAttachmentSnapshot(attachment: inputAttachment, session: session)
    workSnapshot.commands[canonicalCommandID] = WorkCommandSnapshot(
        command: CommandRef(
            commandID: canonicalCommandID, client: client,
            sessionAttachment: inputAttachment,
            causalCursor: JournalCursor(
                journal: workJournal, eventID: "pending-before-start", sequence: 0)),
        state: state, actor: TimelineActor(actorID: "pending-host", kind: "host"),
        hostSequence: 1, acceptanceEventRef: acceptance,
        deliveryEventRef: delivery,
        deliveryActor: delivery == nil ? nil
            : TimelineActor(actorID: "pending-runtime", kind: "runtime"),
        deliveryHostSequence: delivery == nil ? nil : 2,
        commandKind: .start, deliveryMode: .queued, acceptanceRun: run,
        carriesSessionInput: true)

    let message = SessionMessageSnapshot(
        eventID: "pending-user-message", role: "user", text: prompt,
        sourceEvent: EventRef(
            journal: sessionJournal, eventID: "pending-user-message"),
        run: run, actor: TimelineActor(actorID: "pending-client", kind: "client"),
        client: client, sessionAttachment: inputAttachment, causedBy: acceptance)
    var sessionSnapshot = SessionSnapshot()
    sessionSnapshot.journal = sessionJournal
    sessionSnapshot.session = session
    sessionSnapshot.lifecycle = .active
    sessionSnapshot.messages = includeMessage ? [message] : []
    sessionSnapshot.messageHistory = includeMessage ? [message] : []
    return WorkServiceAttachedWorkProjection(
        descriptor: descriptor, attachment: clientAttachment,
        capabilities: Set(WorkServiceCapability.allCases),
        workSnapshot: workSnapshot, sessionSnapshot: sessionSnapshot,
        workCursor: workCursor, sessionCursor: sessionCursor,
        workSourceCompleteness: .complete, sessionSourceCompleteness: .complete,
        workOmissions: workOmissions)
}

private func pendingChatForDelivery(
    key: ServiceAttachmentKey,
    startCommandID: String = "pending-exact-start",
    prompt: String = "preserve this exact prompt"
) throws -> PendingChat {
    try PendingChat(
        prompt: prompt, cwd: "/tmp", phase: .awaitingAcceptance,
        startCommandID: startCommandID, createdAssociation: key)
}

private func assertPendingChatConflict(
    _ body: () throws -> Void, line: Int = #line
) {
    do {
        try body()
        XCTFail("expected a pending-chat conflict", line: line)
    } catch PendingChatError.conflict {
        Harness.countAssertion()
    } catch {
        XCTFail("expected conflict, got a different error", line: line)
    }
}

func test_pendingChatStoreRetainsExactPromptAndMetadataBeforePreflight() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let prompt = String(repeating: "🙂", count: PendingChat.maximumPromptBytes / 4)
    let chat = try store.create(
        prompt: prompt, cwd: "/tmp/project", providerID: "provider", modelID: "model",
        thinkingLevel: "high", title: "a title", noContextFiles: true, recordPayloads: true)
    let inventory = try store.load()
    let loaded = try XCTUnwrap(inventory.rows.first)
    XCTAssertTrue(loaded == chat, "exact saved chat round trip")
    XCTAssertEqual(loaded.prompt.utf8.count, PendingChat.maximumPromptBytes)
    XCTAssertEqual(loaded.startCommandID, "start-\(chat.id.uuidString.lowercased())")
    XCTAssertEqual(inventory.unavailable.count, 0)
    let attrs = try FileManager.default.attributesOfItem(
        atPath: store.directory.appending(path: "\(chat.id.uuidString.lowercased()).json").path)
    XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
}

func test_pendingChatStoreUsesGenerationCASAndPreservesStableStartIdentity() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let original = try store.create(prompt: "hello", cwd: "/tmp")
    let changed = try PendingChat(
        id: original.id, createdAt: original.createdAt, prompt: original.prompt, cwd: original.cwd,
        phase: .preparing, attemptCommandID: original.attemptCommandID,
        startCommandID: original.startCommandID)
    let updated = try store.update(changed, expectedGeneration: original.generation)
    XCTAssertEqual(updated.generation, original.generation + 1)
    XCTAssertEqual(updated.startCommandID, original.startCommandID)
    do {
        _ = try store.update(original, expectedGeneration: original.generation)
        XCTFail("stale update unexpectedly succeeded")
    } catch PendingChatError.conflict { }
    catch { XCTFail("stale update returned an unexpected error") }
    do {
        try store.delete(id: updated.id, expectedGeneration: original.generation)
        XCTFail("stale delete unexpectedly succeeded")
    } catch PendingChatError.conflict { }
    catch { XCTFail("stale delete returned an unexpected error") }
    try store.delete(id: updated.id, expectedGeneration: updated.generation)
    XCTAssertTrue(try store.load().rows.isEmpty)
}

func test_pendingChatStoreReportsUnavailableRowsInsteadOfReturningEmpty() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let chat = try store.create(prompt: "good", cwd: "/tmp")
    let row = store.directory.appending(path: "\(chat.id.uuidString.lowercased()).json")
    try Data("not-json".utf8).write(to: row, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: row.path)
    let inventory = try store.load()
    XCTAssertTrue(inventory.rows.isEmpty)
    XCTAssertEqual(inventory.unavailable.count, 1)
    XCTAssertEqual(inventory.unavailable.first?.kind, .malformed)
}

func test_pendingChatStoreRejectsPromptOver64KiBAndCapsRows() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    do {
        _ = try store.create(prompt: String(repeating: "x", count: PendingChat.maximumPromptBytes + 1), cwd: "/tmp")
        XCTFail("oversized prompt unexpectedly accepted")
    } catch PendingChatError.invalid { }
    catch { XCTFail("oversized prompt returned an unexpected error") }
    for index in 0..<PendingChatStore.maximumRows {
        _ = try store.create(prompt: "chat-\(index)", cwd: "/tmp")
    }
    do {
        _ = try store.create(prompt: "one too many", cwd: "/tmp")
        XCTFail("capacity unexpectedly exceeded")
    } catch PendingChatError.capacity { }
    catch { XCTFail("capacity returned an unexpected error") }
    XCTAssertEqual(try store.load().rows.count, PendingChatStore.maximumRows)
}

func test_pendingChatStoreFreezesAwaitingMetadataButPublishesAssociationOnce() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let original = try store.create(prompt: "exact", cwd: "/tmp")
    let awaiting = try PendingChat(
        id: original.id, createdAt: original.createdAt, prompt: original.prompt, cwd: original.cwd,
        phase: .awaitingAcceptance, attemptCommandID: original.attemptCommandID,
        startCommandID: original.startCommandID)
    let accepted = try store.update(awaiting, expectedGeneration: original.generation)
    let edited = try PendingChat(
        id: accepted.id, createdAt: accepted.createdAt, prompt: "changed", cwd: accepted.cwd,
        phase: .awaitingAcceptance, attemptCommandID: accepted.attemptCommandID,
        startCommandID: accepted.startCommandID)
    assertPendingChatConflict {
        _ = try store.update(edited, expectedGeneration: accepted.generation)
    }
    let associated = try PendingChat(
        id: accepted.id, createdAt: accepted.createdAt, prompt: accepted.prompt, cwd: accepted.cwd,
        phase: .awaitingAcceptance, attemptCommandID: accepted.attemptCommandID,
        startCommandID: accepted.startCommandID, createdAssociation: try pendingChatTestKey())
    let published = try store.update(associated, expectedGeneration: accepted.generation)
    XCTAssertEqual(published.createdAssociation, try pendingChatTestKey())
    let secondAssociation = try PendingChat(
        id: published.id, createdAt: published.createdAt, prompt: published.prompt, cwd: published.cwd,
        phase: .awaitingAcceptance, attemptCommandID: published.attemptCommandID,
        startCommandID: published.startCommandID, createdAssociation: try pendingChatTestKey("b"))
    assertPendingChatConflict {
        _ = try store.update(secondAssociation, expectedGeneration: published.generation)
    }
}

func test_pendingChatStoreAllowsDefinitiveRejectionThenFreshAttempt() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let original = try store.create(prompt: "retry me", cwd: "/tmp")
    let awaiting = try PendingChat(
        id: original.id, createdAt: original.createdAt, prompt: original.prompt, cwd: original.cwd,
        phase: .awaitingAcceptance, attemptCommandID: original.attemptCommandID,
        startCommandID: original.startCommandID)
    let acceptedPending = try store.update(awaiting, expectedGeneration: original.generation)
    let rejected = try PendingChat(
        id: acceptedPending.id, createdAt: acceptedPending.createdAt,
        prompt: acceptedPending.prompt, cwd: acceptedPending.cwd, phase: .blocked,
        failureKind: .invalidRequest, attemptCommandID: acceptedPending.attemptCommandID,
        startCommandID: acceptedPending.startCommandID)
    let blocked = try store.update(rejected, expectedGeneration: acceptedPending.generation)
    let freshAttempt = try PendingChat(
        id: blocked.id, createdAt: blocked.createdAt, prompt: blocked.prompt, cwd: blocked.cwd,
        phase: .preparing, attemptCommandID: UUID(), startCommandID: blocked.startCommandID)
    let preparing = try store.update(freshAttempt, expectedGeneration: blocked.generation)
    XCTAssertNotEqual(preparing.attemptCommandID, original.attemptCommandID)
    XCTAssertEqual(preparing.startCommandID, original.startCommandID)
    XCTAssertEqual(preparing.failureKind, nil)
}

func test_pendingChatStorePersistsStaleCreateClassificationUntilFreshAttempt() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let original = try store.create(prompt: "retry unchanged", cwd: "/tmp")
    let stale = try PendingChat(
        id: original.id, createdAt: original.createdAt, prompt: original.prompt, cwd: original.cwd,
        phase: .blocked, failureKind: .staleCreate,
        attemptCommandID: original.attemptCommandID, startCommandID: original.startCommandID)
    let blocked = try store.update(stale, expectedGeneration: original.generation)
    let loaded = try XCTUnwrap(try store.load().rows.first)
    XCTAssertEqual(loaded.failureKind, .staleCreate)
    XCTAssertEqual(loaded.prompt, original.prompt)

    let freshAttempt = try PendingChat(
        id: blocked.id, createdAt: blocked.createdAt, prompt: blocked.prompt, cwd: blocked.cwd,
        phase: .preparing, attemptCommandID: UUID(), startCommandID: blocked.startCommandID)
    let preparing = try store.update(freshAttempt, expectedGeneration: blocked.generation)
    XCTAssertNil(preparing.failureKind)
    XCTAssertEqual(preparing.prompt, original.prompt)
}

func test_pendingChatStoreEditsBlockedChatWithoutChangingIdentity() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let original = try store.create(prompt: "old", cwd: "/old", providerID: "p", modelID: "m")
    let blocked = try PendingChat(
        id: original.id, createdAt: original.createdAt, prompt: original.prompt, cwd: original.cwd,
        providerID: original.providerID, modelID: original.modelID, phase: .blocked,
        failureKind: .workspaceUnavailable, attemptCommandID: original.attemptCommandID,
        startCommandID: original.startCommandID)
    let savedBlocked = try store.update(blocked, expectedGeneration: original.generation)
    let edited = try savedBlocked.edited(
        prompt: "new", cwd: "/new", providerID: "new-p", modelID: "new-m",
        thinkingLevel: "high", title: "edited", noContextFiles: true, recordPayloads: true)
    let saved = try store.update(edited, expectedGeneration: savedBlocked.generation)
    XCTAssertEqual(saved.prompt, "new")
    XCTAssertEqual(saved.cwd, "/new")
    XCTAssertEqual(saved.providerID, "new-p")
    XCTAssertEqual(saved.generation, savedBlocked.generation + 1)
    XCTAssertEqual(saved.id, original.id)
    XCTAssertEqual(saved.startCommandID, original.startCommandID)
    XCTAssertEqual(saved.attemptCommandID, original.attemptCommandID)
    XCTAssertEqual(saved.phase, .saved)
}

func test_pendingChatStoreKeepsHealthyRowsVisibleAroundCorruptionAndSymlinks() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PendingChatStore(home: home)
    let healthy = try store.create(prompt: "healthy", cwd: "/tmp")
    let corrupt = try store.create(prompt: "corrupt", cwd: "/tmp")
    let corruptURL = store.directory.appending(path: "\(corrupt.id.uuidString.lowercased()).json")
    try Data("not-json".utf8).write(to: corruptURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: corruptURL.path)
    let symlink = store.directory.appending(path: "unsafe.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: corruptURL)
    let inventory = try store.load()
    XCTAssertEqual(inventory.rows.map(\.id), [healthy.id])
    XCTAssertEqual(inventory.unavailable.count, 2)
    XCTAssertTrue(inventory.unavailable.contains { $0.kind == .malformed })
    XCTAssertTrue(inventory.unavailable.contains { $0.kind == .unsafeEntry })
}

func test_pendingChatStoreRejectsSymlinkedPendingDirectory() throws {
    let (home, root) = try pendingChatTestHome()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
    let target = root.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let pending = home.root.appending(path: "pending-chats", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: target)
    do {
        _ = try PendingChatStore(home: home)
        XCTFail("symlinked pending directory unexpectedly accepted")
    } catch PendingChatError.corrupt { }
    catch { XCTFail("symlinked pending directory returned an unexpected error") }
}

func test_pendingChatCanonicalDeliveryRejectsUnrelatedUserInput() throws {
    let key = try pendingChatTestKey()
    let chat = try pendingChatForDelivery(key: key)
    let projection = try pendingChatDeliveryProjection(
        key: key, externalCommandID: "another-start", prompt: "another user input",
        state: .delivered)
    XCTAssertFalse(chat.hasCanonicalDelivery(in: projection))
}

func test_pendingChatCanonicalDeliveryRejectsAcceptedOnlyStart() throws {
    let key = try pendingChatTestKey()
    let chat = try pendingChatForDelivery(key: key)
    let projection = try pendingChatDeliveryProjection(
        key: key, externalCommandID: chat.startCommandID, prompt: chat.prompt,
        state: .accepted)
    XCTAssertFalse(chat.hasCanonicalDelivery(in: projection))
}

func test_pendingChatCanonicalDeliveryAcceptsExactDeliveredStart() throws {
    let key = try pendingChatTestKey()
    let chat = try pendingChatForDelivery(key: key)
    let projection = try pendingChatDeliveryProjection(
        key: key, externalCommandID: chat.startCommandID, prompt: chat.prompt,
        state: .delivered)
    XCTAssertTrue(chat.hasCanonicalDelivery(in: projection))

    let wrongPrompt = try pendingChatForDelivery(
        key: key, startCommandID: chat.startCommandID, prompt: "different prompt")
    XCTAssertFalse(wrongPrompt.hasCanonicalDelivery(in: projection))
    let missingMessage = try pendingChatDeliveryProjection(
        key: key, externalCommandID: chat.startCommandID, prompt: chat.prompt,
        state: .delivered, includeMessage: false)
    XCTAssertFalse(chat.hasCanonicalDelivery(in: missingMessage))
    let omittedEvidence = try pendingChatDeliveryProjection(
        key: key, externalCommandID: chat.startCommandID, prompt: chat.prompt,
        state: .delivered,
        workOmissions: [WorkServiceOmission(category: "commands", count: 1)])
    XCTAssertFalse(chat.hasCanonicalDelivery(in: omittedEvidence))
}

func test_pendingChatCanonicalDeliveryRejectsWrongClientOrSessionAttachment() throws {
    let key = try pendingChatTestKey()
    let chat = try pendingChatForDelivery(key: key)
    let wrongClient = try pendingChatDeliveryProjection(
        key: key, externalCommandID: chat.startCommandID, prompt: chat.prompt,
        state: .delivered, commandClient: ClientRef("pending-other-client"))
    XCTAssertFalse(chat.hasCanonicalDelivery(in: wrongClient))

    let wrongAttachment = try pendingChatDeliveryProjection(
        key: key, externalCommandID: chat.startCommandID, prompt: chat.prompt,
        state: .delivered,
        commandSessionAttachment: SessionAttachmentRef("pending-other-session-attachment"))
    XCTAssertFalse(chat.hasCanonicalDelivery(in: wrongAttachment))
}

let casesPendingChatStore: [Case] = [
    ("pending chat store: exact prompt and metadata survive", {
        try test_pendingChatStoreRetainsExactPromptAndMetadataBeforePreflight()
    }),
    ("pending chat store: generation CAS protects updates and deletes", {
        try test_pendingChatStoreUsesGenerationCASAndPreservesStableStartIdentity()
    }),
    ("pending chat store: unavailable rows are diagnosed", {
        try test_pendingChatStoreReportsUnavailableRowsInsteadOfReturningEmpty()
    }),
    ("pending chat store: prompt and row bounds are enforced", {
        try test_pendingChatStoreRejectsPromptOver64KiBAndCapsRows()
    }),
    ("pending chat store: awaiting metadata is frozen and association is one-shot", {
        try test_pendingChatStoreFreezesAwaitingMetadataButPublishesAssociationOnce()
    }),
    ("pending chat store: rejected attempt can be retried with a new command", {
        try test_pendingChatStoreAllowsDefinitiveRejectionThenFreshAttempt()
    }),
    ("pending chat store: stale Create classification persists until retry", {
        try test_pendingChatStorePersistsStaleCreateClassificationUntilFreshAttempt()
    }),
    ("pending chat store: blocked edits retain identity", {
        try test_pendingChatStoreEditsBlockedChatWithoutChangingIdentity()
    }),
    ("pending chat store: corruption does not hide healthy rows", {
        try test_pendingChatStoreKeepsHealthyRowsVisibleAroundCorruptionAndSymlinks()
    }),
    ("pending chat store: symlinked directory is rejected", {
        try test_pendingChatStoreRejectsSymlinkedPendingDirectory()
    }),
    ("pending chat delivery: unrelated user input is insufficient", {
        try test_pendingChatCanonicalDeliveryRejectsUnrelatedUserInput()
    }),
    ("pending chat delivery: accepted start is not delivered", {
        try test_pendingChatCanonicalDeliveryRejectsAcceptedOnlyStart()
    }),
    ("pending chat delivery: exact delivered start is proven", {
        try test_pendingChatCanonicalDeliveryAcceptsExactDeliveredStart()
    }),
    ("pending chat delivery: client and Session attachment are exact", {
        try test_pendingChatCanonicalDeliveryRejectsWrongClientOrSessionAttachment()
    }),
]
