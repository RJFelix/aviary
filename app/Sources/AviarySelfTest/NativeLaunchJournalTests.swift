import Foundation
@testable import AviaryCore

private struct NativeInitialStartFixture {
    let home: AgentHome
    let idle: IdleWorkCreation
    let identity: SessionWorkIdentity
    let legacyProjection: SessionWriter
    let bridge: NativeSessionCommandJournal
}

private func nativeInitialStartFixture() async throws -> NativeInitialStartFixture {
    let home = scratchHome()
    let host = try home.requirePersistedWorkHost()
    let suffix = UUID().uuidString.lowercased()
    let binding = WorkBinding(
        session: SessionRef("native-start-session-\(suffix)"),
        work: WorkRef(workHostID: host.workHostID, workID: "native-start-work-\(suffix)"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("native-start-attachment-\(suffix)"))
    let idle = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "native-start-control-\(suffix)")
    let identity = SessionWorkIdentity(
        sessionID: binding.session.sessionID, work: binding.work,
        runID: "native-start-run-\(suffix)")
    let legacyProjection = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    let bridge = try await NativeSessionCommandJournal.openForRun(
        home: home,
        binding: WorkRunBinding(workBinding: binding, run: RunRef(identity.runID)),
        legacyProjection: legacyProjection,
        actorID: "native-start-host-\(suffix)",
        modelID: fakeModel().qualifiedID,
        modelContextMode: .launchFresh)
    return NativeInitialStartFixture(
        home: home, idle: idle, identity: identity,
        legacyProjection: legacyProjection, bridge: bridge)
}

private func closeNativeInitialStartFixture(_ fixture: NativeInitialStartFixture) async {
    try? await fixture.bridge.nativeJournal.closeChecked()
    try? await fixture.legacyProjection.closeChecked()
    try? FileManager.default.removeItem(at: fixture.home.root)
}

private func nativeInitialStartIntent(
    _ fixture: NativeInitialStartFixture,
    commandID: String,
    command: SessionCommand,
    causalCursor: JournalCursor?
) -> SessionCommandIntent {
    SessionCommandIntent(admitted: AdmittedSessionCommand(
        identity: fixture.identity,
        commandID: commandID,
        sequence: 1,
        actorID: "native-start-client",
        command: command,
        previousState: .prepared,
        state: .preparing,
        causalCursor: causalCursor))
}

private func nativeInitialStartWorkEvents(
    _ fixture: NativeInitialStartFixture
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.identity.work)),
        journal: fixture.bridge.nativeJournal.workJournal,
        actor: TimelineActor(actorID: "native-start-reader", kind: "test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        throw RunJournalBundleError.invalidJournal(
            journal: fixture.bridge.nativeJournal.workJournal, reason: "test tail")
    }
    return read.records.map(\.event)
}

func test_nativeLaunchJournalRejectsLegacyOnlyExactColdResume() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let originalIdentity = SessionWorkIdentity(
        sessionID: "legacy-only-session",
        work: WorkRef(workHostID: hostID, workID: "legacy-only-work"),
        runID: "legacy-original-run")
    let original = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: originalIdentity)
    try await original.closeChecked()

    let resumedIdentity = try XCTUnwrap(
        SessionWriter.recoverIdentity(home: home, sessionID: originalIdentity.sessionID))
    let resumed = try SessionWriter(
        home: home, resuming: originalIdentity.sessionID, cwd: "/tmp",
        model: fakeModel(), identity: resumedIdentity)
    do {
        _ = try await NativeSessionCommandJournal.openForLaunch(
            home: home, identity: resumedIdentity, legacyProjection: resumed,
            actorID: "resume-test", modelID: fakeModel().qualifiedID,
            modelContextMode: .exactColdResume)
        XCTFail("exact cold resume must not fall back to the legacy projection")
    } catch let error as NativeColdResumeError {
        XCTAssertEqual(error, .noCompleteContextManifest)
    }
    XCTAssertFalse(FileManager.default.fileExists(
        atPath: home.timelineV2SessionJournalURL(sessionID: resumedIdentity.sessionID).path))
    XCTAssertFalse(FileManager.default.fileExists(
        atPath: home.timelineV2WorkJournalURL(resumedIdentity.work).path))
    try await resumed.closeChecked()
}

func test_nativeCLIStartCommandIDsAreUniqueAcrossColdResumedRuns() async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let firstIdentity = SessionWorkIdentity(
        sessionID: "cli-resume-session",
        work: WorkRef(workHostID: hostID, workID: "cli-resume-work"),
        runID: "cli-run-1")
    let first = try await RunJournalBundle.openForExecution(
        home: home, identity: firstIdentity, actorID: "cli",
        makeAttachmentID: { "cli-resume-attachment" })
    let firstID = SessionCommandController.cliStartCommandID(for: firstIdentity)
    _ = try await first.commitInput(
        text: "first", deliveryMode: .queued,
        command: CommandRef(
            commandID: firstID, client: ClientRef("cli"),
            causalCursor: await first.latestWorkCursor))
    _ = try await first.markCommandDelivered(commandID: firstID)
    _ = try await first.finishRun()
    try await first.closeChecked()

    // This is the adversarial sequence: same Session/Work, a new cold Run, and the same CLI
    // Start operation. Reusing a literal cli-start id would fail in acceptCommandLocked.
    let resumedIdentity = SessionWorkIdentity(
        sessionID: firstIdentity.sessionID, work: firstIdentity.work, runID: "cli-run-2")
    let resumed = try await RunJournalBundle.openForExecution(
        home: home, identity: resumedIdentity, actorID: "cli")
    let resumedID = SessionCommandController.cliStartCommandID(for: resumedIdentity)
    XCTAssertNotEqual(firstID, resumedID)
    _ = try await resumed.commitInput(
        text: "second", deliveryMode: .queued,
        command: CommandRef(
            commandID: resumedID, client: ClientRef("cli"),
            causalCursor: await resumed.latestWorkCursor))
    _ = try await resumed.markCommandDelivered(commandID: resumedID)
    _ = try await resumed.finishRun()
    try await resumed.closeChecked()

    let journal = resumed.workJournal
    let events = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(resumed.work)),
        journal: journal,
        actor: TimelineActor(actorID: "test-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
    let acceptedIDs = events.filter { $0.type == TimelineEventType.commandAccepted }
        .compactMap { $0.command?.commandID }
    XCTAssertEqual(acceptedIDs, [firstID, resumedID])
}

func test_nativeFirstStartPreservesIdleCursorInCanonicalReceipt() async throws {
    let fixture = try await nativeInitialStartFixture()
    let idleCursor = fixture.idle.workCursor
    let intent = nativeInitialStartIntent(
        fixture, commandID: "native-initial-start",
        command: .start(prompt: "first prompt"), causalCursor: idleCursor)

    try await fixture.bridge.commitIntent(intent)
    let workEvents = try nativeInitialStartWorkEvents(fixture)
    XCTAssertEqual(
        workEvents.map(\.type),
        [TimelineEventType.workCreated, TimelineEventType.sessionAttached,
         TimelineEventType.runStarted, TimelineEventType.commandAccepted])
    let runStarted = try XCTUnwrap(workEvents.first { $0.type == TimelineEventType.runStarted })
    let accepted = try XCTUnwrap(
        workEvents.first { $0.type == TimelineEventType.commandAccepted })
    let expectedCommand = CommandRef(
        commandID: intent.commandID, client: ClientRef(intent.actorID),
        sessionAttachment: fixture.idle.binding.sessionAttachment,
        causalCursor: idleCursor)
    XCTAssertEqual(accepted.command, expectedCommand)
    XCTAssertEqual(
        accepted.causedByEventID,
        EventRef(journal: fixture.bridge.nativeJournal.workJournal,
                 eventID: idleCursor.eventID!))
    XCTAssertEqual(accepted.command?.causalCursor, idleCursor)
    XCTAssertEqual(accepted.sequence, idleCursor.sequence + 2)
    XCTAssertEqual(accepted.previousEventID, runStarted.eventID)

    // The exact-current rule remains in force for every command after the initial Start.
    let staleSend = nativeInitialStartIntent(
        fixture, commandID: "native-post-start-stale-send",
        command: .send(prompt: "must be rejected"), causalCursor: idleCursor)
    do {
        try await fixture.bridge.commitIntent(staleSend)
        XCTFail("post-Start Send with the idle cursor must be rejected")
    } catch let error as SessionCommandJournalError {
        if case .causalConflict = error {} else {
            XCTFail("unexpected stale post-Start error: \(error)")
        }
    }
    let current = try XCTUnwrap(await fixture.bridge.nativeJournal.latestWorkCursor)
    let currentSend = nativeInitialStartIntent(
        fixture, commandID: "native-post-start-current-send",
        command: .send(prompt: "current"), causalCursor: current)
    try await fixture.bridge.commitIntent(currentSend)
    XCTAssertEqual(await fixture.bridge.nativeJournal.commandState(
        for: currentSend.commandID), .accepted)
    await closeNativeInitialStartFixture(fixture)
}

func test_nativeFirstStartRejectsOlderForeignAndInterveningCursors() async throws {
    // A real but older canonical cursor is durably rejected.
    do {
        let fixture = try await nativeInitialStartFixture()
        let events = try nativeInitialStartWorkEvents(fixture)
        let older = JournalCursor(
            journal: fixture.bridge.nativeJournal.workJournal,
            eventID: events[0].eventID, sequence: events[0].sequence)
        let intent = nativeInitialStartIntent(
            fixture, commandID: "native-start-older",
            command: .start(prompt: "older"), causalCursor: older)
        do {
            try await fixture.bridge.commitIntent(intent)
            XCTFail("an older cursor must not admit Start")
        } catch let error as SessionCommandJournalError {
            if case .causalConflict = error {} else {
                XCTFail("unexpected older cursor error: \(error)")
            }
        }
        XCTAssertEqual(
            await fixture.bridge.nativeJournal.commandState(for: intent.commandID), .rejected)
        await closeNativeInitialStartFixture(fixture)
    }

    // A cursor from another Work journal is never linked into this Work chain.
    do {
        let fixture = try await nativeInitialStartFixture()
        let foreign = JournalCursor(
            journal: .work(WorkRef(workHostID: "foreign-host", workID: "foreign-work")),
            eventID: "foreign-event", sequence: fixture.idle.workCursor.sequence)
        let intent = nativeInitialStartIntent(
            fixture, commandID: "native-start-foreign",
            command: .start(prompt: "foreign"), causalCursor: foreign)
        do {
            try await fixture.bridge.commitIntent(intent)
            XCTFail("a foreign cursor must not admit Start")
        } catch let error as SessionCommandJournalError {
            if case .causalConflict = error {} else {
                XCTFail("unexpected foreign cursor error: \(error)")
            }
        }
        XCTAssertNil(await fixture.bridge.nativeJournal.commandState(for: intent.commandID))
        XCTAssertEqual(try nativeInitialStartWorkEvents(fixture).count, 3)
        await closeNativeInitialStartFixture(fixture)
    }

    // An intervening turn makes the saved idle cursor ineligible even though it is canonical.
    do {
        let fixture = try await nativeInitialStartFixture()
        _ = try await fixture.bridge.nativeJournal.startTurn(TurnRef("native-intervening-turn"))
        let intent = nativeInitialStartIntent(
            fixture, commandID: "native-start-intervening",
            command: .start(prompt: "intervening"), causalCursor: fixture.idle.workCursor)
        do {
            try await fixture.bridge.commitIntent(intent)
            XCTFail("a cursor followed by an intervening turn must not admit Start")
        } catch let error as SessionCommandJournalError {
            if case .causalConflict = error {} else {
                XCTFail("unexpected intervening cursor error: \(error)")
            }
        }
        XCTAssertEqual(
            await fixture.bridge.nativeJournal.commandState(for: intent.commandID), .rejected)
        await closeNativeInitialStartFixture(fixture)
    }
}

let casesNativeLaunchJournal: [Case] = [
    ("phase1 native launch: exact cold resume requires native context", {
        try await test_nativeLaunchJournalRejectsLegacyOnlyExactColdResume()
    }),
    ("phase1 native launch: CLI Start ids survive cold resume", {
        try await test_nativeCLIStartCommandIDsAreUniqueAcrossColdResumedRuns()
    }),
    ("phase1 native launch: first Start preserves the idle causal cursor", {
        try await test_nativeFirstStartPreservesIdleCursorInCanonicalReceipt()
    }),
    ("phase1 native launch: first Start rejects noncanonical cursors", {
        try await test_nativeFirstStartRejectsOlderForeignAndInterveningCursors()
    }),
]
