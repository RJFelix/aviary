import Foundation
@testable import AviaryCore

/// Journal-boundary tests for direct shell commands. Every fixture owns a fresh AgentHome under
/// the system temporary directory; no service, user transcript, or real workspace is touched.
let casesDirectShellCommandJournal: [Case] = [
    ("Direct shell journal: nonzero exit leaves the agent available", {
        let fixture = try await directShellJournalFixture("nonzero")
        let request = try await directShellJournalRequest(
            fixture, commandID: "nonzero-command", source: Data("exit 7".utf8))
        let permit = try await fixture.bundle.admitDirectShell(request: request, commandID: request.command.commandID)
        _ = try await fixture.bundle.finishAction(permit, state: .failed,
            retrySafety: .unknown, failureKind: .task)
        let events = try directShellJournalEvents(fixture.home, fixture.bundle.workJournal,
            fixture.home.timelineV2WorkJournalURL(fixture.bundle.work))
        let snapshot = WorkReducer.reduce(events)
        XCTAssertEqual(snapshot.execution, .idle)
        XCTAssertEqual(snapshot.actions[permit.action.actionID]?.state, .failed)
        XCTAssertEqual(snapshot.activeRun, fixture.bundle.run)
        XCTAssertTrue(snapshot.corruptionReasons.isEmpty)
        try await fixture.bundle.closeChecked()
        try? FileManager.default.removeItem(at: fixture.home.root)
    }),
    ("Direct shell journal: admission is durable before execution", {
        let fixture = try await directShellJournalFixture("admission")
        // Close and remove synchronously at the end of this async case.

        let source = Data("printf durable-source".utf8)
        let request = try await directShellJournalRequest(
            fixture, commandID: "direct-admit", source: source)
        let staleCursor = JournalCursor(
            journal: fixture.bundle.workJournal,
            eventID: request.causalWorkCursor.eventID,
            sequence: max(1, request.causalWorkCursor.sequence - 1))
        let stale = WorkServiceDirectShellRequest(
            work: request.work, journal: request.journal, attachment: request.attachment,
            command: CommandRef(
                commandID: "direct-stale", client: request.command.client,
                sessionAttachment: request.command.sessionAttachment, causalCursor: staleCursor),
            causalWorkCursor: staleCursor, run: request.run, operation: .run,
            language: request.language, source: request.source)
        do {
            _ = try await fixture.bundle.admitDirectShell(request: stale, commandID: "direct-stale")
            XCTAssertTrue(false, "a stale Work cursor must be rejected before launch")
        } catch {
            XCTAssertTrue(true)
        }
        XCTAssertEqual(try await fixture.bundle.directShellEntries(), [])

        let permit = try await fixture.bundle.admitDirectShell(
            request: request, commandID: request.command.commandID)
        let entries = try await fixture.bundle.directShellEntries(
            including: request.command.commandID, action: permit.action)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.command.commandID, request.command.commandID)
        XCTAssertEqual(entry.source, source)
        XCTAssertEqual(entry.action, permit.action)
        XCTAssertEqual(entry.state, .running)

        let workEvents = try directShellJournalEvents(
            fixture.home, fixture.bundle.workJournal,
            fixture.home.timelineV2WorkJournalURL(fixture.bundle.work))
        XCTAssertTrue(workEvents.contains { $0.type == TimelineEventType.commandAccepted
            && $0.command?.commandID == request.command.commandID })
        XCTAssertTrue(workEvents.contains { $0.type == TimelineEventType.actionIntent
            && $0.action == permit.action })
        XCTAssertTrue(workEvents.contains { $0.type == TimelineEventType.actionStarted
            && $0.action == permit.action })
        XCTAssertTrue(workEvents.contains { $0.type == TimelineEventType.commandAccepted
            && $0.payload["command_kind"]?.stringValue == "direct_shell" })
        try await fixture.bundle.closeChecked()
        try? FileManager.default.removeItem(at: fixture.home.root)
    }),
    ("Direct shell journal: result artifact and pending context survive settlement", {
        let fixture = try await directShellJournalFixture("settlement")
        // Close and remove synchronously at the end of this async case.

        let source = Data("printf journal-result".utf8)
        let request = try await directShellJournalRequest(
            fixture, commandID: "direct-result", source: source)
        let permit = try await fixture.bundle.admitDirectShell(
            request: request, commandID: request.command.commandID)
        let worker = DirectShellCommandWorker(request: DirectShellCommandRequest(
            commandID: request.command.commandID, actionID: permit.action.actionID,
            language: try XCTUnwrap(request.language), source: source,
            workingDirectory: fixture.home.root,
            environment: ["PATH": "/usr/bin:/bin"]))
        let result = await worker.wait()
        if case .exited(let code) = result.status { XCTAssertEqual(code, 0) }
        else { XCTAssertTrue(false, "fixture command must exit successfully") }
        XCTAssertEqual(result.stdout.head, Data("journal-result".utf8))

        let artifact = try await fixture.bundle.recordArtifact(
            artifactID: permit.action.actionID + "-output", label: "Command output",
            mediaType: DirectShellJournalFormat.resultMediaType,
            body: try DirectShellJournalFormat.encoded(result), action: permit.action,
            provenance: permit.startedCommit.eventRef)
        XCTAssertEqual(artifact.action, Optional(permit.action))
        _ = try await fixture.bundle.finishAction(
            permit, state: .succeeded, retrySafety: .unknown)

        let entries = try await fixture.bundle.directShellEntries(
            including: request.command.commandID, action: permit.action)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.source, source)
        XCTAssertEqual(entry.result, result)
        XCTAssertEqual(entry.artifact?.artifactID, artifact.descriptor.artifactID)
        XCTAssertTrue(entry.pendingContext)
        XCTAssertEqual(entry.artifact?.bodyReference?.digest, artifact.descriptor.bodyReference?.digest)
        try await fixture.bundle.closeChecked()
        try? FileManager.default.removeItem(at: fixture.home.root)
    }),
    ("Direct shell journal: input consumes pending output once and preserves user text", {
        let fixture = try await directShellJournalFixture("consumption")
        // Close and remove synchronously at the end of this async case.

        let request = try await directShellJournalRequest(
            fixture, commandID: "direct-consume", source: Data("printf attach-me".utf8))
        let permit = try await fixture.bundle.admitDirectShell(
            request: request, commandID: request.command.commandID)
        let result = await DirectShellCommandWorker(request: DirectShellCommandRequest(
            commandID: request.command.commandID, actionID: permit.action.actionID,
            language: .sh, source: request.source!, workingDirectory: fixture.home.root,
            environment: ["PATH": "/usr/bin:/bin"])) .wait()
        _ = try await fixture.bundle.recordArtifact(
            artifactID: permit.action.actionID + "-output", label: "Command output",
            mediaType: DirectShellJournalFormat.resultMediaType,
            body: try DirectShellJournalFormat.encoded(result), action: permit.action,
            provenance: permit.startedCommit.eventRef)
        _ = try await fixture.bundle.finishAction(
            permit, state: .succeeded, retrySafety: .unknown)

        let inputCommandID = "direct-consume-input"
        let input = try await fixture.bundle.commitInput(
            text: "please continue", deliveryMode: .queued,
            command: CommandRef(
                commandID: inputCommandID, client: request.command.client,
                sessionAttachment: fixture.bundle.sessionAttachment,
                causalCursor: await fixture.bundle.latestWorkCursor))
        XCTAssertTrue(input.count >= 3)
        let delivered = try await fixture.bundle.effectiveInputText(
            commandID: inputCommandID, fallback: "fallback")
        let reconstructed = try await fixture.bundle.effectiveInputText(
            commandID: inputCommandID, fallback: "must not replace committed text")
        XCTAssertEqual(reconstructed, delivered)
        let split = PromptText.split(delivered)
        XCTAssertEqual(split.userText, "please continue")
        XCTAssertEqual(split.injected.first?.tag, "aviary-command-output")
        XCTAssertTrue(split.injected.first?.body.contains("attach-me") == true)

        do {
            _ = try await fixture.bundle.commitInput(
                text: "duplicate", deliveryMode: .queued,
                command: CommandRef(
                    commandID: inputCommandID, client: request.command.client,
                    sessionAttachment: fixture.bundle.sessionAttachment,
                    causalCursor: await fixture.bundle.latestWorkCursor))
            XCTAssertTrue(false, "the consumed input command must be exactly-once")
        } catch {
            XCTAssertTrue(true)
        }
        let entries = try await fixture.bundle.directShellEntries(action: permit.action)
        XCTAssertFalse(try XCTUnwrap(entries.first).pendingContext)
        let sessionEvents = try directShellJournalEvents(
            fixture.home, fixture.bundle.sessionJournal,
            fixture.home.timelineV2SessionJournalURL(fixture.bundle.session))
        let accepted = try XCTUnwrap(sessionEvents.first {
            $0.type == TimelineEventType.inputAccepted && $0.command?.commandID == inputCommandID })
        XCTAssertEqual(accepted.payload["text"]?.stringValue, delivered)
        XCTAssertEqual(accepted.payload["direct_shell_consumed"]?.arrayValue?.count, 1)
        _ = try await fixture.bundle.markCommandDelivered(commandID: request.command.commandID)
        _ = try await fixture.bundle.markCommandDelivered(commandID: inputCommandID)
        _ = try await fixture.bundle.finishRun()
        try await fixture.bundle.closeChecked()
        let reopened = try await RunJournalBundle.reopen(
            home: fixture.home, session: fixture.bundle.session, work: fixture.bundle.work,
            workHost: fixture.bundle.workHost, sessionAuthority: fixture.bundle.sessionJournal.authority,
            sessionAttachment: fixture.bundle.sessionAttachment, run: RunRef("reopened-consumption"),
            actor: TimelineActor(actorID: "direct-cold-reader", kind: "self-test"))
        XCTAssertEqual(try await reopened.effectiveInputText(
            commandID: inputCommandID, fallback: "cold fallback must not replace committed text"), delivered)
        XCTAssertFalse(try XCTUnwrap(try await reopened.directShellEntries(action: permit.action).first).pendingContext)
        try await reopened.closeChecked()
        try? FileManager.default.removeItem(at: fixture.home.root)
    }),
    ("Direct shell journal: dismiss hides pending state but preserves artifact", {
        let fixture = try await directShellJournalFixture("dismiss")
        // Close and remove synchronously at the end of this async case.

        let request = try await directShellJournalRequest(
            fixture, commandID: "direct-dismiss", source: Data("printf dismiss-me".utf8))
        let permit = try await fixture.bundle.admitDirectShell(
            request: request, commandID: request.command.commandID)
        let result = await DirectShellCommandWorker(request: DirectShellCommandRequest(
            commandID: request.command.commandID, actionID: permit.action.actionID,
            language: .sh, source: request.source!, workingDirectory: fixture.home.root,
            environment: ["PATH": "/usr/bin:/bin"])) .wait()
        _ = try await fixture.bundle.recordArtifact(
            artifactID: permit.action.actionID + "-output", label: "Command output",
            mediaType: DirectShellJournalFormat.resultMediaType,
            body: try DirectShellJournalFormat.encoded(result), action: permit.action,
            provenance: permit.startedCommit.eventRef)
        _ = try await fixture.bundle.finishAction(
            permit, state: .succeeded, retrySafety: .unknown)
        let before = try XCTUnwrap(
            try await fixture.bundle.directShellEntries(action: permit.action).first)
        let cursor = try XCTUnwrap(await fixture.bundle.latestWorkCursor)
        let staleCursor = JournalCursor(
            journal: fixture.bundle.workJournal, eventID: cursor.eventID,
            sequence: max(1, cursor.sequence - 1))
        let staleDismiss = WorkServiceDirectShellRequest(
            work: request.work, journal: request.journal, attachment: request.attachment,
            command: CommandRef(
                commandID: "direct-stale-dismiss", client: request.command.client,
                sessionAttachment: request.command.sessionAttachment, causalCursor: staleCursor),
            causalWorkCursor: staleCursor, run: request.run, operation: .dismiss,
            action: permit.action)
        do {
            try await fixture.bundle.recordDirectShellControl(
                request: staleDismiss, commandID: "direct-stale-dismiss")
            XCTAssertTrue(false, "stale dismissal must not consume pending context")
        } catch { XCTAssertTrue(true) }
        XCTAssertTrue(try XCTUnwrap(
            try await fixture.bundle.directShellEntries(action: permit.action).first).pendingContext)
        let dismiss = WorkServiceDirectShellRequest(
            work: request.work, journal: request.journal, attachment: request.attachment,
            command: CommandRef(
                commandID: "direct-dismiss-control", client: request.command.client,
                sessionAttachment: request.command.sessionAttachment, causalCursor: cursor),
            causalWorkCursor: cursor, run: request.run, operation: .dismiss,
            action: permit.action)
        try await fixture.bundle.recordDirectShellControl(
            request: dismiss, commandID: "direct-dismiss-control")
        let after = try XCTUnwrap(
            try await fixture.bundle.directShellEntries(action: permit.action).first)
        XCTAssertFalse(after.pendingContext)
        XCTAssertEqual(after.artifact?.artifactID, before.artifact?.artifactID)
        XCTAssertEqual(after.result, before.result)
        try await fixture.bundle.closeChecked()
        try? FileManager.default.removeItem(at: fixture.home.root)
    }),
    ("Direct shell journal: foreign attachment, Work, and stale requests are denied", {
        let fixture = try await directShellJournalFixture("authorization")
        // Close and remove synchronously at the end of this async case.
        let source = Data("printf should-not-run".utf8)
        let base = try await directShellJournalRequest(
            fixture, commandID: "direct-foreign", source: source)

        let foreignAttachment = WorkServiceDirectShellRequest(
            work: base.work, journal: base.journal, attachment: base.attachment,
            command: CommandRef(
                commandID: "direct-foreign-attachment", client: base.command.client,
                sessionAttachment: SessionAttachmentRef("other-session"),
                causalCursor: base.causalWorkCursor),
            causalWorkCursor: base.causalWorkCursor, run: base.run, operation: .run,
            language: base.language, source: base.source)
        do {
            _ = try await fixture.bundle.admitDirectShell(
                request: foreignAttachment, commandID: "direct-foreign-attachment")
            XCTAssertTrue(false, "a foreign Session attachment must not admit execution")
        } catch { XCTAssertTrue(true) }

        let foreignWork = WorkRef(workHostID: base.work.workHostID, workID: "foreign-work")
        let foreign = WorkServiceDirectShellRequest(
            work: foreignWork, journal: JournalRef.work(foreignWork), attachment: base.attachment,
            command: base.command, causalWorkCursor: base.causalWorkCursor, run: base.run,
            operation: .run, language: base.language, source: base.source)
        do {
            _ = try await fixture.bundle.admitDirectShell(request: foreign, commandID: base.command.commandID)
            XCTAssertTrue(false, "a foreign Work must not admit execution")
        } catch { XCTAssertTrue(true) }
        XCTAssertEqual(try await fixture.bundle.directShellEntries(), [])
        try await fixture.bundle.closeChecked()
        try? FileManager.default.removeItem(at: fixture.home.root)
    })
]

private struct DirectShellJournalFixture {
    let home: AgentHome
    let bundle: RunJournalBundle
}

private func directShellJournalFixture(_ suffix: String) async throws -> DirectShellJournalFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-direct-journal-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let home = AgentHome(root: root)
    let host = try home.requirePersistedWorkHost()
    let session = SessionRef("direct-journal-session-\(suffix)")
    let work = WorkRef(workHostID: host.workHostID, workID: "direct-journal-work-\(suffix)")
    let bundle = try await RunJournalBundle.createFresh(
        home: home, session: session, work: work, workHost: host,
        sessionAuthority: TimelineAuthorityRef("direct-journal-service-\(suffix)"),
        sessionAttachment: SessionAttachmentRef("direct-journal-attachment-\(suffix)"),
        run: RunRef("direct-journal-run-\(suffix)"),
        actor: TimelineActor(actorID: "direct-journal-test-\(suffix)", kind: "self-test"),
        modelID: "test/model")
    return DirectShellJournalFixture(home: home, bundle: bundle)
}

private func directShellJournalRequest(
    _ fixture: DirectShellJournalFixture,
    commandID: String,
    source: Data
) async throws -> WorkServiceDirectShellRequest {
    let cursor = try XCTUnwrap(await fixture.bundle.latestWorkCursor)
    return WorkServiceDirectShellRequest(
        work: fixture.bundle.work, journal: fixture.bundle.workJournal,
        attachment: ClientAttachmentRef("direct-journal-client-attachment"),
        command: CommandRef(
            commandID: commandID, client: ClientRef("direct-journal-client"),
            sessionAttachment: fixture.bundle.sessionAttachment, causalCursor: cursor),
        causalWorkCursor: cursor, run: fixture.bundle.run, operation: .run,
        language: .sh, source: source)
}

private func directShellJournalEvents(
    _ home: AgentHome, _ journal: JournalRef, _ url: URL
) throws -> [TimelineEvent] {
    TimelineJournalReader.read(
        try Data(contentsOf: url), journal: journal,
        actor: TimelineActor(actorID: "direct-journal-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0)).records.map(\.event)
}
