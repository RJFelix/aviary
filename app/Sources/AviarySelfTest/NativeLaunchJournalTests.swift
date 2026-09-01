import Foundation
@testable import AviaryCore

func test_nativeLaunchJournalDoesNotCreatePartialHistoryForLegacyResume() async throws {
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
    let bridge = try await NativeSessionCommandJournal.openForLaunch(
        home: home, identity: resumedIdentity, legacyProjection: resumed,
        actorID: "resume-test", modelID: fakeModel().qualifiedID,
        resumingLegacySession: true)
    XCTAssertNil(bridge)
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
        command: CommandRef(commandID: firstID, client: ClientRef("cli")))
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
        command: CommandRef(commandID: resumedID, client: ClientRef("cli")))
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

let casesNativeLaunchJournal: [Case] = [
    ("phase1 native launch: legacy-only resume does not invent partial history", {
        try await test_nativeLaunchJournalDoesNotCreatePartialHistoryForLegacyResume()
    }),
    ("phase1 native launch: CLI Start ids survive cold resume", {
        try await test_nativeCLIStartCommandIDsAreUniqueAcrossColdResumedRuns()
    }),
]
