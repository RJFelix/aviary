import Foundation
@testable import AviaryCore

private let serviceHost = WorkHostRef("service-host")
private let serviceWork = WorkRef(workHostID: serviceHost.workHostID, workID: "work-1")
private let serviceJournal = JournalRef.work(serviceWork, journalID: "work-journal")
private let serviceControlJournal = JournalRef.workHost(serviceHost)

private func serviceControlCursor(_ sequence: Int = 0, eventID: String? = nil) -> JournalCursor {
    JournalCursor(journal: serviceControlJournal, eventID: eventID, sequence: sequence)
}

private func serviceSessionJournal(
    _ session: SessionRef, host: WorkHostRef = serviceHost
) -> JournalRef {
    JournalRef.session(
        session, authority: TimelineAuthorityRef(host.workHostID))
}

private func serviceReadCursor(
    _ attachment: WorkServiceClientAttachment,
    journal: JournalRef
) -> JournalCursor? {
    attachment.readAcknowledgements.first { $0.target.journal == journal }?.cursor
}

private func describeRequest(
    work: WorkRef = serviceWork, journal: JournalRef = serviceJournal,
    client: ClientRef = ClientRef("gui")
) -> WorkServiceDescribeRequest {
    WorkServiceDescribeRequest(work: work, journal: journal, client: client)
}

private func listRequest(
    client: ClientRef = ClientRef("gui"), pageSize: Int,
    pageToken: String? = nil
) -> WorkServiceListRequest {
    WorkServiceListRequest(client: client, pageSize: pageSize, pageToken: pageToken)
}

private let allServiceCommands: Set<WorkServiceCapability> = [
    .observe, .control, .start, .send, .steer, .queue, .hold, .cancel, .end, .destroy, .complete,
    .inspectArtifacts,
]

private let allServiceClientIDs = [
    "gui-a", "gui-b", "gui-c", "gui", "read-only", "creator", "observe-only", "paired-client",
]

private func makeTestTerminalProof(
    _ request: WorkServiceTerminalCommitRequest,
    handlesQuiesced: Bool = true, pairingVerified: Bool = true,
    commandIDOverride: String? = nil,
    sessionOverride: SessionRef? = nil,
    sessionJournalOverride: JournalRef? = nil
) -> WorkServiceTerminalCommitProof {
    let proofCommand = CommandRef(
        commandID: commandIDOverride ?? request.command.commandID,
        client: request.client, sessionAttachment: request.sessionAttachment,
        causalCursor: request.causalWorkCursor)
    let cursor = JournalCursor(
        journal: request.journal, eventID: "terminal-event-\(request.command.commandID)",
        sequence: request.causalWorkCursor.sequence + 1)
    func component(_ value: String) -> String { "\(value.utf8.count):\(value)" }
    let type = request.operation == .complete
        ? TimelineEventType.workCompleted : TimelineEventType.workDestroyed
    let idempotencyKey = "work-terminal:v1/type:\(component(type))"
        + "/command:\(component(proofCommand.commandID))"
        + "/client:\(component(request.client.clientID))"
        + "/attachment:\(component(request.sessionAttachment.attachmentID))"
        + "/journal:\(component(request.causalWorkCursor.journal.stableKey))"
        + "/sequence:\(request.causalWorkCursor.sequence)"
        + "/event:\(component(request.causalWorkCursor.eventID ?? ""))"
        + "/detail:none"
    return WorkServiceTerminalCommitProof(
        operation: request.operation, work: request.work, journal: request.journal,
        command: proofCommand, causalWorkCursor: request.causalWorkCursor,
        resultingWorkCursor: cursor,
        terminalEvent: TimelineEvent(
            eventID: cursor.eventID!, journal: request.journal, sequence: cursor.sequence,
            idempotencyKey: idempotencyKey,
            command: proofCommand,
            previousEventID: request.causalWorkCursor.eventID,
            causedByEventID: request.causalWorkCursor.eventID.map {
                EventRef(journal: request.journal, eventID: $0)
            }, session: request.session, work: request.work,
            workHost: WorkHostRef(request.work.workHostID), client: request.client,
            sessionAttachment: request.sessionAttachment, run: nil,
            actor: TimelineActor(actorID: "test", kind: "test"), hostRecordedAt: Date(),
            type: request.operation == .complete
                ? TimelineEventType.workCompleted : TimelineEventType.workDestroyed),
        session: sessionOverride ?? request.session,
        sessionJournal: sessionJournalOverride ?? request.sessionJournal,
        sessionAttachment: request.sessionAttachment,
        pairedSessionCursor: pairingVerified
            ? JournalCursor(
                journal: sessionJournalOverride ?? request.sessionJournal,
                eventID: "session-event", sequence: 1) : nil,
        sessionPairingVerified: pairingVerified,
        outstandingHandleIDs: handlesQuiesced ? [] : [HandleRef("live-handle")],
        commitID: "terminal-commit-\(request.operation.rawValue)-\(request.client.clientID)")
}

private struct TestTerminalCommitter: WorkServiceTerminalCommitter {
    let handlesQuiesced: Bool
    let pairingVerified: Bool
    let commandIDOverride: String?

    init(handlesQuiesced: Bool = true, pairingVerified: Bool = true,
         commandIDOverride: String? = nil) {
        self.handlesQuiesced = handlesQuiesced
        self.pairingVerified = pairingVerified
        self.commandIDOverride = commandIDOverride
    }

    func commit(_ request: WorkServiceTerminalCommitRequest) async throws -> WorkServiceTerminalCommitProof {
        makeTestTerminalProof(
            request, handlesQuiesced: handlesQuiesced,
            pairingVerified: pairingVerified, commandIDOverride: commandIDOverride)
    }
}

private actor BlockingTerminalCommitter: WorkServiceTerminalCommitter {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func commit(
        _ request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof {
        started = true
        await withCheckedContinuation { releaseContinuation = $0 }
        return makeTestTerminalProof(request)
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum TerminalCommitterTestError: Error { case responseLost }

private actor DelayedRecoveryTerminalCommitter: WorkServiceTerminalCommitter {
    private var durableProof: WorkServiceTerminalCommitProof?
    private var recoveryEnabled = false
    private var commitCalls = 0

    func commit(
        _ request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof {
        commitCalls += 1
        durableProof = makeTestTerminalProof(request)
        throw TerminalCommitterTestError.responseLost
    }

    func committedProof(
        for request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof? {
        recoveryEnabled ? durableProof : nil
    }

    func enableRecovery() { recoveryEnabled = true }
    func callCount() -> Int { commitCalls }
}

private actor InvalidThenRecoveryTerminalCommitter: WorkServiceTerminalCommitter {
    private var durableProof: WorkServiceTerminalCommitProof?
    private var recoveryEnabled = false

    func commit(
        _ request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof {
        durableProof = makeTestTerminalProof(request)
        let other = SessionRef("invalid-proof-session")
        return makeTestTerminalProof(
            request, sessionOverride: other,
            sessionJournalOverride: serviceSessionJournal(other))
    }

    func committedProof(
        for request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof? {
        recoveryEnabled ? durableProof : nil
    }

    func enableRecovery() { recoveryEnabled = true }
}

private struct WrongSessionTerminalCommitter: WorkServiceTerminalCommitter {
    func commit(
        _ request: WorkServiceTerminalCommitRequest
    ) async throws -> WorkServiceTerminalCommitProof {
        let other = SessionRef("other-session")
        return makeTestTerminalProof(
            request, sessionOverride: other,
            sessionJournalOverride: serviceSessionJournal(other))
    }
}

private func permissiveServiceAuthorizer() -> WorkServiceCapabilityPolicy {
    WorkServiceCapabilityPolicy(grantsByClient: Dictionary(
        uniqueKeysWithValues: allServiceClientIDs.map { (ClientRef($0), allServiceCommands) }))
}

private func serviceCommand(
    _ kind: WorkServiceCommandKind,
    id: String,
    client: ClientRef,
    attachment: ClientAttachmentRef,
    cursor: JournalCursor,
    sessionAttachment: SessionAttachmentRef? = nil,
    value: String? = nil
) -> WorkServiceCommandRequest {
    WorkServiceCommandRequest(
        work: serviceWork, journal: serviceJournal, attachment: attachment,
        commandID: id, client: client, sessionAttachment: sessionAttachment,
        causalWorkCursor: cursor, kind: kind, value: value)
}

private func serviceFixture(
    source: WorkServiceSourceCompleteness = .complete,
    disposition: WorkServiceRecordedDisposition = .reusable
) async throws -> (InMemoryWorkService, JournalCursor) {
    let service = InMemoryWorkService(
        host: serviceHost, instanceID: "instance-a", startIdentity: "start-a",
        authorizer: permissiveServiceAuthorizer(), terminalCommitter: TestTerminalCommitter())
    let cursor = JournalCursor(journal: serviceJournal, sequence: 0)
    let body = Data("hello world!".utf8)
    let bodyDigest = "sha256:" + AviarySHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    let bodyReference = TimelineBodyReference(
        authority: serviceJournal, referenceID: "artifact-body", mediaType: "text/plain", byteCount: 12,
        digest: bodyDigest)
    let mismatchReference = TimelineBodyReference(
        authority: serviceJournal, referenceID: "artifact-body-mismatch", mediaType: "text/plain", byteCount: 12,
        digest: "sha256:" + String(repeating: "0", count: 64))
    try await service.register(.init(
        work: serviceWork, journal: serviceJournal, disposition: disposition, cursor: cursor,
        sourceCompleteness: source,
        artifacts: [
            WorkServiceArtifactDescriptor(
                artifactID: "artifact-1", work: serviceWork, label: "diff", mediaType: "text/plain",
                byteCount: 12, digest: "sha256:fixture", bodyReference: bodyReference),
        ], bodies: [bodyReference: body, mismatchReference: body]))
    return (service, cursor)
}

private func createCanonicalServiceWork(
    _ service: InMemoryWorkService,
    host: WorkHostRef,
    client: ClientRef,
    commandID: String
) async throws -> WorkServiceCreateWorkResponse {
    try await service.createWork(.init(
        client: client, commandID: commandID,
        causalControlCursor: JournalCursor(journal: .workHost(host), sequence: 0),
        requestedCapabilities: allServiceCommands))
}

func test_workServiceHandshakeIsVersionedAndHostIdentityIsOpaque() async throws {
    let (service, _) = try await serviceFixture()
    let response = try await service.handshake(.init(
        protocolVersion: WorkServiceProtocol.currentVersion, client: ClientRef("gui-a"), build: "test"))
    XCTAssertTrue(response.accepted)
    XCTAssertEqual(response.negotiatedVersion, WorkServiceProtocol.currentVersion)
    XCTAssertEqual(response.host, serviceHost)
    XCTAssertEqual(response.hostInstance.instanceID, "instance-a")
    XCTAssertEqual(response.hostInstance.startIdentity, "start-a")
    XCTAssertFalse(response.hostInstance.instanceID.contains("/"))
    XCTAssertNil(response.diagnostic)

    do {
        _ = try await service.handshake(.init(protocolVersion: 999, client: ClientRef("gui-a")))
        XCTFail("unsupported protocol version must not be accepted")
    } catch WorkServiceProtocolError.unsupportedVersion(let version) {
        XCTAssertEqual(version, 999)
    }
    do {
        _ = try await service.handshake(.init(protocolVersion: 1, client: ClientRef("gui-a")))
        XCTFail("protocol v1 must not survive the hard v2 cutover")
    } catch WorkServiceProtocolError.unsupportedVersion(let version) {
        XCTAssertEqual(version, 1)
    }

    // The advertised surface describes what this particular host instance can execute. A
    // host without the canonical terminal transaction seam must not claim complete/destroy.
    let noTerminal = InMemoryWorkService(
        host: WorkHostRef("no-terminal-handshake"), authorizer: permissiveServiceAuthorizer())
    let noTerminalResponse = try await noTerminal.handshake(.init(client: ClientRef("gui")))
    XCTAssertFalse(noTerminalResponse.capabilities.contains(.complete))
    XCTAssertFalse(noTerminalResponse.capabilities.contains(.destroy))
}

func test_workServiceManyToManyAttachmentsHaveIndependentCursorsAndCapabilities() async throws {
    let (service, initialCursor) = try await serviceFixture()
    let clientA = ClientRef("gui-a")
    let clientB = ClientRef("gui-b")
    let attachA = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: clientA,
        commandID: "attach-a", causalControlCursor: serviceControlCursor(),
        requestedCapabilities: allServiceCommands))
    let attachmentA = try XCTUnwrap(attachA.attachment)
    let attachARetry = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: clientA,
        commandID: "attach-a", causalControlCursor: serviceControlCursor(),
        requestedCapabilities: allServiceCommands))
    XCTAssertEqual(attachARetry.state, .duplicate)
    XCTAssertEqual(try XCTUnwrap(attachARetry.attachment).attachment, attachmentA.attachment)
    let staleAttachRequest = WorkServiceAttachRequest(
        work: serviceWork, journal: serviceJournal, client: ClientRef("gui-c"),
        commandID: "attach-stale", causalControlCursor: serviceControlCursor(),
        requestedCapabilities: [.observe])
    let staleAttach = try await service.attach(staleAttachRequest)
    XCTAssertEqual(staleAttach.state, .rejected)
    XCTAssertEqual(staleAttach.rejection, .staleCursor)
    XCTAssertNil(staleAttach.attachment)
    let staleAttachRetry = try await service.attach(staleAttachRequest)
    XCTAssertEqual(staleAttachRetry.state, .rejected)
    XCTAssertEqual(staleAttachRetry.rejection, .staleCursor)
    let staleAttachConflict = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: ClientRef("gui-c"),
        session: SessionRef("different"), commandID: "attach-stale", causalControlCursor: serviceControlCursor(),
        requestedCapabilities: [.observe]))
    XCTAssertEqual(staleAttachConflict.state, .rejected)
    XCTAssertEqual(staleAttachConflict.rejection, .conflictingCommand)
    let attachConflict = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: clientA,
        commandID: "attach-a", causalControlCursor: serviceControlCursor(),
        requestedCapabilities: [.observe]))
    XCTAssertEqual(attachConflict.state, .rejected)
    XCTAssertEqual(attachConflict.rejection, .conflictingCommand)
    let attachACursor = attachA.resultingControlCursor
    let attachB = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: clientB,
        commandID: "attach-b", causalControlCursor: attachACursor,
        requestedCapabilities: allServiceCommands))
    let attachmentB = try XCTUnwrap(attachB.attachment)
    XCTAssertTrue(attachmentA.readAcknowledgements.isEmpty)
    XCTAssertTrue(attachmentB.readAcknowledgements.isEmpty)
    // The rejection remains the durable result even after another client advances the Work
    // cursor; replaying the same network request cannot become an attach later.
    let staleAttachAfterAdvance = try await service.attach(staleAttachRequest)
    XCTAssertEqual(staleAttachAfterAdvance.state, .rejected)
    XCTAssertEqual(staleAttachAfterAdvance.rejection, .staleCursor)
    XCTAssertTrue(attachA.authorization.allows(.control))
    XCTAssertTrue(attachB.authorization.allows(.control))
    let updated = try await service.updateCapabilities(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachmentB.attachment,
        client: clientB, requestedCapabilities: allServiceCommands,
        commandID: "capabilities-b", causalControlCursor: attachB.resultingControlCursor))
    XCTAssertEqual(updated.state, .accepted)
    XCTAssertEqual(updated.receipt.operation, .updateCapabilities)
    XCTAssertEqual(updated.receipt.outcome, .capabilitiesUpdated)
    XCTAssertEqual(updated.receipt.causalControlCursor, attachB.resultingControlCursor)
    XCTAssertEqual(updated.receipt.resultingControlCursor, updated.resultingControlCursor)
    XCTAssertTrue(updated.attachment?.readAcknowledgements.isEmpty == true)
    let workTarget = WorkServiceReadTarget.work(journal: serviceJournal)
    let workSnapshot = try await service.snapshot(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachmentB.attachment,
        client: clientB, target: workTarget, afterCursor: nil))
    XCTAssertEqual(workSnapshot.target, workTarget)
    XCTAssertTrue(workSnapshot.events.isEmpty)
    XCTAssertEqual(workSnapshot.servedCursor,
                   JournalCursor(journal: serviceJournal, sequence: 0))
    let acknowledged = try await service.acknowledgeRead(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachmentB.attachment,
        client: clientB, target: workTarget,
        cursor: JournalCursor(journal: serviceJournal, sequence: 0),
        commandID: "ack-session-b", causalControlCursor: updated.resultingControlCursor))
    XCTAssertEqual(acknowledged.state, .accepted)
    XCTAssertEqual(acknowledged.receipt.operation, .acknowledgeRead)
    XCTAssertEqual(acknowledged.receipt.outcome, .readAcknowledged)
    XCTAssertEqual(acknowledged.receipt.resultingControlCursor,
                   acknowledged.resultingControlCursor)
    let afterAcknowledgement = try await service.describeWork(describeRequest())
    let acknowledgedAttachment = try XCTUnwrap(
        afterAcknowledgement.attachments.first {
            $0.attachment == attachmentB.attachment
        })
    XCTAssertEqual(acknowledgedAttachment.readAcknowledgements.count, 1)
    XCTAssertEqual(
        serviceReadCursor(acknowledgedAttachment, journal: serviceJournal),
        JournalCursor(journal: serviceJournal, sequence: 0))
    let controlCursorAfterAck = acknowledged.resultingControlCursor
    let attachmentCursor = try XCTUnwrap(
        attachA.work.hostObservation?.servedCursor)
    let bAttachmentCursor = try XCTUnwrap(
        attachB.work.hostObservation?.servedCursor)
    XCTAssertEqual(bAttachmentCursor, attachmentCursor)
    // Attachment control commits do not advance the execution journal cursor.
    XCTAssertEqual(attachmentCursor, initialCursor)
    XCTAssertNotEqual(attachmentA.attachment.attachmentID, attachmentB.attachment.attachmentID)
    let aSnapshot = try await service.snapshot(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachmentA.attachment,
        client: clientA, target: .work(journal: serviceJournal),
        afterCursor: attachmentCursor))
    let aCursor = try XCTUnwrap(aSnapshot.servedCursor)

    let started = try await service.command(serviceCommand(
        .start, id: "shared-local-command", client: clientA,
        attachment: attachmentA.attachment,
        cursor: aCursor, value: "first prompt"))
    XCTAssertEqual(started.state, .accepted)
    XCTAssertEqual(started.hostSequence, 1)
    let runningCursor = try XCTUnwrap(started.resultingWorkCursor)
    XCTAssertEqual(started.host, WorkHostInstanceRef(
        host: serviceHost, instanceID: "instance-a", startIdentity: "start-a"))

    // B still has its own cursor.  It cannot accidentally issue a command against A's newer view.
    let stale = try await service.command(serviceCommand(
        .send, id: "cmd-b-stale", client: clientB, attachment: attachmentB.attachment,
        cursor: initialCursor, value: "stale"))
    XCTAssertEqual(stale.state, .rejected)
    XCTAssertEqual(stale.rejection, .staleCursor)
    XCTAssertEqual(stale.resultingWorkCursor, runningCursor)

    let bSnapshot = try await service.snapshot(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachmentB.attachment,
        client: clientB, target: .work(journal: serviceJournal),
        afterCursor: bAttachmentCursor))
    XCTAssertEqual(bSnapshot.events.count, 2)
    XCTAssertEqual(bSnapshot.events.map(\.type), [
        TimelineEventType.runStarted, TimelineEventType.commandAccepted,
    ])
    XCTAssertEqual(bSnapshot.servedCursor, runningCursor)
    let sent = try await service.command(serviceCommand(
        .send, id: "shared-local-command", client: clientB,
        attachment: attachmentB.attachment,
        cursor: runningCursor, value: "current"))
    XCTAssertEqual(sent.state, .accepted)
    XCTAssertEqual(sent.outcome, .inputAccepted)
    XCTAssertEqual(started.commandID, sent.commandID)
    let canonical = try await service.snapshot(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachmentB.attachment,
        client: clientB, target: .work(journal: serviceJournal),
        afterCursor: JournalCursor(journal: serviceJournal, sequence: 0), limit: 8))
    let reduced = WorkReducer.reduce(canonical.events)
    XCTAssertTrue(reduced.structuralIntegrityValid)
    XCTAssertTrue(reduced.semanticProjectionValid)
    XCTAssertEqual(reduced.commands.count, 2)
    XCTAssertNotNil(reduced.commands[WorkServiceCommandLedgerIdentity.commandID(
        client: clientA, commandID: "shared-local-command")])
    XCTAssertNotNil(reduced.commands[WorkServiceCommandLedgerIdentity.commandID(
        client: clientB, commandID: "shared-local-command")])
    let staleDetachRequest = WorkServiceDetachRequest(
        work: serviceWork, journal: serviceJournal, attachment: attachmentA.attachment,
        client: clientA, commandID: "detach-stale", causalControlCursor: attachACursor)
    let staleDetach = try await service.detach(staleDetachRequest)
    XCTAssertEqual(staleDetach.state, .rejected)
    XCTAssertEqual(staleDetach.rejection, .staleCursor)
    let staleDetachRetry = try await service.detach(staleDetachRequest)
    XCTAssertEqual(staleDetachRetry.state, .rejected)
    XCTAssertEqual(staleDetachRetry.rejection, .staleCursor)
    let staleDetachConflict = try await service.detach(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachmentA.attachment,
        client: clientA, commandID: "detach-stale",
        causalControlCursor: attachB.resultingControlCursor))
    XCTAssertEqual(staleDetachConflict.state, .rejected)
    XCTAssertEqual(staleDetachConflict.rejection, .conflictingCommand)

    // Retrying the exact command is idempotent, while reusing the id for another request is an
    // explicit conflict rather than a second effect.
    let duplicate = try await service.command(serviceCommand(
        .send, id: "shared-local-command", client: clientB,
        attachment: attachmentB.attachment,
        cursor: runningCursor, value: "current"))
    XCTAssertEqual(duplicate.state, .duplicate)
    XCTAssertEqual(duplicate.resultingWorkCursor, sent.resultingWorkCursor)
    let conflict = try await service.command(serviceCommand(
        .steer, id: "shared-local-command", client: clientB,
        attachment: attachmentB.attachment,
        cursor: runningCursor, value: "different"))
    XCTAssertEqual(conflict.state, .rejected)
    XCTAssertEqual(conflict.rejection, .conflictingCommand)

    let detachRequest = WorkServiceDetachRequest(
        work: serviceWork, journal: serviceJournal, attachment: attachmentA.attachment,
        client: clientA, commandID: "detach-a", causalControlCursor: controlCursorAfterAck)
    let detached = try await service.detach(detachRequest)
    XCTAssertEqual(detached.state, .accepted)
    let detachedRetry = try await service.detach(detachRequest)
    XCTAssertEqual(detachedRetry.state, .duplicate)
    let staleDetachAfterAdvance = try await service.detach(staleDetachRequest)
    XCTAssertEqual(staleDetachAfterAdvance.state, .rejected)
    XCTAssertEqual(staleDetachAfterAdvance.rejection, .staleCursor)
    let afterDetach = try await service.describeWork(describeRequest())
    XCTAssertEqual(afterDetach.attachments.count, 1)
    XCTAssertEqual(afterDetach.attachments.first?.client, clientB)
    XCTAssertEqual(afterDetach.currentRun, RunRef("run-1"))

    // A real detach closes A's attachment epoch. Reattaching the same Client/Session tuple with
    // the next exact control cursor must mint a fresh ClientAttachment, while replaying that new
    // request (including a lost response retry) stays bound to the same B/epoch identity.
    let reattachRequest = WorkServiceAttachRequest(
        work: serviceWork, journal: serviceJournal, client: clientA,
        commandID: "attach-a-epoch-2", causalControlCursor: detached.resultingControlCursor,
        requestedCapabilities: allServiceCommands)
    let reattached = try await service.attach(reattachRequest)
    let reattachmentB = try XCTUnwrap(reattached.attachment)
    XCTAssertEqual(reattached.state, .accepted)
    XCTAssertNotEqual(reattachmentB.attachment, attachmentA.attachment)
    let reattachedRetry = try await service.attach(reattachRequest)
    XCTAssertEqual(reattachedRetry.state, .duplicate)
    XCTAssertEqual(try XCTUnwrap(reattachedRetry.attachment).attachment,
                   reattachmentB.attachment)

    XCTAssertNil(reattachmentB.sessionAttachment)
}

func test_workServiceRunFinishedIsReusableEndIsTerminalizingAndCompletionIsSeparate() async throws {
    let (service, _) = try await serviceFixture()
    let client = ClientRef("gui")
    let attached = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: client,
        commandID: "attach-run",
        causalControlCursor: serviceControlCursor(),
        requestedCapabilities: allServiceCommands))
    let attachment = try XCTUnwrap(attached.attachment)
    let attachmentCursor = try XCTUnwrap(
        attached.work.hostObservation?.servedCursor)
    let started = try await service.command(serviceCommand(
        .start, id: "start-1", client: client, attachment: attachment.attachment,
        cursor: attachmentCursor))
    let run = try XCTUnwrap((try await service.describeWork(describeRequest())).currentRun)
    try await service.finishRun(run, for: serviceWork)
    var descriptor = try await service.describeWork(describeRequest())
    XCTAssertEqual(started.outcome, .started)
    XCTAssertEqual(descriptor.recordedDisposition, .reusable)
    XCTAssertEqual(descriptor.execution, .idle)
    XCTAssertNil(descriptor.currentRun)

    let restart = try await service.command(serviceCommand(
        .start, id: "start-2", client: client, attachment: attachment.attachment,
        cursor: try XCTUnwrap(descriptor.hostObservation?.servedCursor)))
    XCTAssertEqual(restart.state, .accepted)
    let secondRun = try XCTUnwrap((try await service.describeWork(describeRequest())).currentRun)
    let end = try await service.command(serviceCommand(
        .end, id: "end-1", client: client, attachment: attachment.attachment,
        cursor: try XCTUnwrap(restart.resultingWorkCursor)))
    XCTAssertEqual(end.state, .accepted)
    descriptor = try await service.describeWork(describeRequest())
    XCTAssertEqual(descriptor.execution, .ending)
    XCTAssertEqual(descriptor.recordedDisposition, .reusable)

    try await service.finishRun(secondRun, for: serviceWork)
    descriptor = try await service.describeWork(describeRequest())
    let idleEnd = try await service.command(serviceCommand(
        .end, id: "end-idle", client: client, attachment: attachment.attachment,
        cursor: try XCTUnwrap(descriptor.hostObservation?.servedCursor)))
    XCTAssertEqual(idleEnd.state, .rejected)
    XCTAssertEqual(idleEnd.rejection, .invalidState)
    XCTAssertEqual((try await service.describeWork(describeRequest())).execution, .idle)

    // Once the ending run has finished, Work is reusable again; End does not strand it in a
    // permanently non-startable state or rewrite reusable Work into completed Work.
    let reusableStart = try await service.command(serviceCommand(
        .start, id: "start-after-end", client: client, attachment: attachment.attachment,
        cursor: try XCTUnwrap(descriptor.hostObservation?.servedCursor)))
    XCTAssertEqual(reusableStart.state, .accepted)
    XCTAssertEqual(reusableStart.outcome, .started)
    let reusableRun = try XCTUnwrap((try await service.describeWork(describeRequest())).currentRun)
    try await service.finishRun(reusableRun, for: serviceWork)

    // The host's explicit completion transition is separate from End and is immutable.
    do {
        try await service.finishRun(RunRef("run-unused"), for: serviceWork)
        XCTFail("an unknown run must not finish the Work")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }
}

func test_workServiceExplicitCompletionAndDestroyRemainSeparateCommands() async throws {
    let client = ClientRef("gui")
    let service = InMemoryWorkService(
        host: serviceHost, authorizer: permissiveServiceAuthorizer(),
        terminalCommitter: TestTerminalCommitter())
    let created = try await createCanonicalServiceWork(
        service, host: serviceHost, client: client, commandID: "create-complete")
    let serviceWork = created.work.work
    let serviceJournal = created.work.journal
    let attachment = created.attachment
    let completion = try await service.completeWork(.init(
        work: serviceWork, journal: serviceJournal,
        attachment: attachment.attachment, commandID: "complete-1", client: client,
        sessionAttachment: created.sessionAttachment,
        causalWorkCursor: created.workCursor))
    XCTAssertEqual(completion.state, .accepted)
    XCTAssertEqual(completion.outcome, .completed)
    XCTAssertEqual(completion.resultingWorkCursor, completion.terminalProof?.resultingWorkCursor)
    XCTAssertEqual(
        completion.terminalProof?.command.commandID,
        WorkServiceCommandLedgerIdentity.commandID(
            client: client, commandID: "complete-1"))
    let completionEvents = try await service.eventsAfterCursor(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        target: .work(journal: serviceJournal),
        afterCursor: created.workCursor, limit: 1))
    XCTAssertEqual(completionEvents.events.count, 1)
    XCTAssertEqual(completionEvents.events[0], completion.terminalProof?.terminalEvent)
    XCTAssertEqual(completionEvents.events[0].type, TimelineEventType.workCompleted)
    let completed = try await service.describeWork(.init(
        work: serviceWork, journal: serviceJournal, client: client))
    XCTAssertEqual(completed.recordedDisposition, .completed)
    XCTAssertEqual(completed.execution, .idle)
    XCTAssertTrue(completed.hostObservation?.currentRun == nil)

    let refused = try await service.command(.init(
        work: serviceWork, journal: serviceJournal,
        attachment: attachment.attachment, commandID: "send-completed", client: client,
        sessionAttachment: created.sessionAttachment,
        causalWorkCursor: try XCTUnwrap(completed.hostObservation?.servedCursor),
        kind: .send))
    XCTAssertEqual(refused.state, .rejected)
    XCTAssertEqual(refused.rejection, .terminalWork)

    let refusedDestroy = try await service.command(.init(
        work: serviceWork, journal: serviceJournal,
        attachment: attachment.attachment, commandID: "destroy-completed", client: client,
        sessionAttachment: created.sessionAttachment,
        causalWorkCursor: try XCTUnwrap(completed.hostObservation?.servedCursor),
        kind: .destroy))
    XCTAssertEqual(refusedDestroy.state, .rejected)
    XCTAssertEqual(refusedDestroy.rejection, .terminalWork)

    // Destruction is an alternative terminal transition for a separate reusable Work, not a
    // mutation available after immutable completion.
    let destroyHost = WorkHostRef("destroy-host")
    let destroyService = InMemoryWorkService(
        host: destroyHost, authorizer: permissiveServiceAuthorizer(),
        terminalCommitter: TestTerminalCommitter())
    let destroyCreated = try await createCanonicalServiceWork(
        destroyService, host: destroyHost, client: client, commandID: "create-destroy")
    let destroyWork = destroyCreated.work.work
    let destroyJournal = destroyCreated.work.journal
    let destroyAttachmentValue = destroyCreated.attachment
    let destroy = try await destroyService.command(WorkServiceCommandRequest(
        work: destroyWork, journal: destroyJournal,
        attachment: destroyAttachmentValue.attachment, commandID: "destroy-1", client: client,
        sessionAttachment: destroyCreated.sessionAttachment,
        causalWorkCursor: destroyCreated.workCursor, kind: .destroy))
    XCTAssertEqual(destroy.state, .accepted)
    let destroyEvents = try await destroyService.eventsAfterCursor(.init(
        work: destroyWork, journal: destroyJournal,
        attachment: destroyAttachmentValue.attachment,
        client: client,
        target: .work(journal: destroyJournal),
        afterCursor: destroyCreated.workCursor, limit: 1))
    XCTAssertEqual(destroyEvents.events.count, 1)
    XCTAssertEqual(destroyEvents.events[0], destroy.terminalProof?.terminalEvent)
    XCTAssertEqual(destroyEvents.events[0].type, TimelineEventType.workDestroyed)
    let destroyed = try await destroyService.describeWork(describeRequest(
        work: destroyWork, journal: destroyJournal, client: client))
    XCTAssertEqual(destroyed.recordedDisposition, .destroyed)
}

func test_workServiceTerminalMutationRequiresCanonicalQuiescenceAndSessionPair() async throws {
    func makeService(
        _ hostID: String, committer: (any WorkServiceTerminalCommitter)?
    ) async throws -> (InMemoryWorkService, WorkRef, JournalRef, WorkServiceClientAttachment) {
        let host = WorkHostRef(hostID)
        let service = InMemoryWorkService(
            host: host, authorizer: permissiveServiceAuthorizer(), terminalCommitter: committer)
        let created = try await createCanonicalServiceWork(
            service, host: host, client: ClientRef("gui"), commandID: "create")
        return (service, created.work.work, created.work.journal, created.attachment)
    }

    func complete(
        _ service: InMemoryWorkService, work: WorkRef, journal: JournalRef,
        attachment: WorkServiceClientAttachment, commandID: String
    ) async throws -> WorkServiceCommandReceipt {
        let cursor = try XCTUnwrap(try await service.describeWork(.init(
            work: work, journal: journal, client: ClientRef("gui")))
            .hostObservation?.servedCursor)
        return try await service.command(.init(
            work: work, journal: journal, attachment: attachment.attachment,
            commandID: commandID, client: ClientRef("gui"),
            sessionAttachment: attachment.sessionAttachment,
            causalWorkCursor: cursor, kind: .complete))
    }

    let noCommitter = try await makeService("terminal-no-committer", committer: nil)
    let noProof = try await complete(
        noCommitter.0, work: noCommitter.1, journal: noCommitter.2,
        attachment: noCommitter.3, commandID: "complete-no-committer")
    XCTAssertEqual(noProof.state, .rejected)
    XCTAssertEqual(noProof.rejection, .terminalProofUnavailable)
    XCTAssertNil(noProof.terminalProof)
    XCTAssertEqual(
        try await noCommitter.0.describeWork(describeRequest(
            work: noCommitter.1, journal: noCommitter.2)).recordedDisposition,
        .reusable)

    let liveHandle = try await makeService(
        "terminal-live-handle", committer: TestTerminalCommitter(handlesQuiesced: false))
    let liveProof = try await complete(
        liveHandle.0, work: liveHandle.1, journal: liveHandle.2,
        attachment: liveHandle.3, commandID: "complete-live-handle")
    XCTAssertEqual(liveProof.state, .rejected)
    XCTAssertEqual(liveProof.rejection, .terminalProofUnavailable)
    XCTAssertEqual(
        try await liveHandle.0.describeWork(describeRequest(
            work: liveHandle.1, journal: liveHandle.2)).recordedDisposition,
        .reusable)

    let unpaired = try await makeService(
        "terminal-unpaired", committer: TestTerminalCommitter(pairingVerified: false))
    let unpairedProof = try await complete(
        unpaired.0, work: unpaired.1, journal: unpaired.2,
        attachment: unpaired.3, commandID: "complete-unpaired")
    XCTAssertEqual(unpairedProof.state, .rejected)
    XCTAssertEqual(unpairedProof.rejection, .terminalProofUnavailable)
    XCTAssertEqual(
        try await unpaired.0.describeWork(describeRequest(
            work: unpaired.1, journal: unpaired.2)).recordedDisposition,
        .reusable)

    // Even a valid committer cannot be used to smuggle an unrelated Session attachment through
    // a command envelope; it must match the durable relationship on the client attachment.
    let mismatched = try await makeService(
        "terminal-mismatched-session", committer: TestTerminalCommitter())
    let mismatchCursor = try XCTUnwrap(try await mismatched.0.describeWork(.init(
        work: mismatched.1, journal: mismatched.2, client: ClientRef("gui")))
        .hostObservation?.servedCursor)
    do {
        _ = try await mismatched.0.command(.init(
            work: mismatched.1, journal: mismatched.2, attachment: mismatched.3.attachment,
            commandID: "complete-mismatched-session", client: ClientRef("gui"),
            sessionAttachment: SessionAttachmentRef("other-session-work"),
            causalWorkCursor: mismatchCursor, kind: .complete))
        XCTFail("command accepted a Session attachment different from its client attachment")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    let proofReplay = try await makeService(
        "terminal-proof-replay", committer: TestTerminalCommitter(commandIDOverride: "other-command"))
    let replayProof = try await complete(
        proofReplay.0, work: proofReplay.1, journal: proofReplay.2,
        attachment: proofReplay.3, commandID: "complete-replay")
    XCTAssertEqual(replayProof.state, .rejected)
    XCTAssertEqual(replayProof.rejection, .terminalProofUnavailable)

    let wrongSession = try await makeService(
        "terminal-wrong-session", committer: WrongSessionTerminalCommitter())
    let wrongSessionProof = try await complete(
        wrongSession.0, work: wrongSession.1, journal: wrongSession.2,
        attachment: wrongSession.3, commandID: "complete-wrong-session")
    XCTAssertEqual(wrongSessionProof.state, .rejected)
    XCTAssertEqual(wrongSessionProof.rejection, .terminalProofUnavailable)
    XCTAssertEqual(
        try await wrongSession.0.describeWork(describeRequest(
            work: wrongSession.1, journal: wrongSession.2))
            .hostObservation?.sourceCompleteness,
        .unknown)
}

func test_workServiceTerminalReservationSerializesConcurrentCommands() async throws {
    let host = WorkHostRef("terminal-reservation-host")
    let client = ClientRef("gui")
    let committer = BlockingTerminalCommitter()
    let service = InMemoryWorkService(
        host: host, authorizer: permissiveServiceAuthorizer(), terminalCommitter: committer)
    let created = try await createCanonicalServiceWork(
        service, host: host, client: client, commandID: "create")
    let work = created.work.work
    let journal = created.work.journal
    let sessionAttachment = created.sessionAttachment
    let attachment = created.attachment
    let cursor = created.workCursor
    let terminalRequest = WorkServiceCommandRequest(
        work: work, journal: journal, attachment: attachment.attachment,
        commandID: "complete", client: client, sessionAttachment: sessionAttachment,
        causalWorkCursor: cursor, kind: .complete)

    let first = Task { try await service.command(terminalRequest) }
    await committer.waitUntilStarted()
    let exactRetry = Task { try await service.command(terminalRequest) }
    let conflicting = try await service.command(.init(
        work: work, journal: journal, attachment: attachment.attachment,
        commandID: "start-during-complete", client: client,
        sessionAttachment: sessionAttachment,
        causalWorkCursor: cursor, kind: .start))
    XCTAssertEqual(conflicting.state, .rejected)
    XCTAssertEqual(conflicting.rejection, .terminalProofUnavailable)

    let attachDuringCommit = try await service.attach(.init(
        work: work, journal: journal, client: client,
        commandID: "attach-during-complete",
        causalControlCursor: created.controlCursor,
        requestedCapabilities: [.observe]))
    XCTAssertEqual(attachDuringCommit.state, .rejected)
    XCTAssertEqual(attachDuringCommit.rejection, .terminalProofUnavailable)
    let detachDuringCommit = try await service.detach(.init(
        work: work, journal: journal, attachment: attachment.attachment,
        client: client, commandID: "detach-during-complete",
        causalControlCursor: created.controlCursor))
    XCTAssertEqual(detachDuringCommit.state, .rejected)
    XCTAssertEqual(detachDuringCommit.rejection, .terminalProofUnavailable)

    await committer.release()
    let receipts = try await [first.value, exactRetry.value]
    XCTAssertEqual(Set(receipts.map(\.state)), [.accepted, .duplicate])
    XCTAssertEqual(Set(receipts.compactMap(\.resultingWorkCursor)).count, 1)
    XCTAssertEqual(Set(receipts.compactMap(\.terminalProof)).count, 1)
    XCTAssertEqual(
        try await service.describeWork(.init(work: work, journal: journal, client: client))
            .recordedDisposition,
        .completed)
}

func test_workServiceAmbiguousTerminalCommitReconcilesExactRetry() async throws {
    let host = WorkHostRef("terminal-recovery-host")
    let client = ClientRef("gui")
    let committer = DelayedRecoveryTerminalCommitter()
    let service = InMemoryWorkService(
        host: host, authorizer: permissiveServiceAuthorizer(), terminalCommitter: committer)
    let created = try await createCanonicalServiceWork(
        service, host: host, client: client, commandID: "create")
    let work = created.work.work
    let journal = created.work.journal
    let sessionAttachment = created.sessionAttachment
    let attachment = created.attachment
    let request = WorkServiceCompleteWorkRequest(
        work: work, journal: journal, attachment: attachment.attachment,
        commandID: "complete-lost-response", client: client,
        sessionAttachment: sessionAttachment,
        causalWorkCursor: created.workCursor)

    let unavailable = try await service.completeWork(request)
    XCTAssertEqual(unavailable.state, .rejected)
    XCTAssertEqual(unavailable.rejection, .terminalProofUnavailable)
    XCTAssertEqual(await committer.callCount(), 1)
    XCTAssertEqual(
        try await service.describeWork(.init(work: work, journal: journal, client: client))
            .hostObservation?.sourceCompleteness,
        .unknown)

    await committer.enableRecovery()
    let reconciled = try await service.completeWork(request)
    XCTAssertEqual(reconciled.state, .accepted)
    XCTAssertEqual(reconciled.outcome, .completed)
    XCTAssertNotNil(reconciled.terminalProof)
    XCTAssertEqual(await committer.callCount(), 1)
    let duplicate = try await service.completeWork(request)
    XCTAssertEqual(duplicate.state, .duplicate)
    XCTAssertEqual(duplicate.resultingWorkCursor, reconciled.resultingWorkCursor)
    XCTAssertEqual(duplicate.terminalProof, reconciled.terminalProof)
}

func test_workServiceInvalidTerminalProofReconcilesExactRetry() async throws {
    let host = WorkHostRef("terminal-invalid-proof-host")
    let client = ClientRef("gui")
    let committer = InvalidThenRecoveryTerminalCommitter()
    let service = InMemoryWorkService(
        host: host, authorizer: permissiveServiceAuthorizer(), terminalCommitter: committer)
    let created = try await createCanonicalServiceWork(
        service, host: host, client: client, commandID: "create")
    let work = created.work.work
    let journal = created.work.journal
    let session = created.session
    let sessionJournal = created.sessionJournal
    let sessionAttachment = created.sessionAttachment
    let attachment = created.attachment
    let request = WorkServiceCompleteWorkRequest(
        work: work, journal: journal, attachment: attachment.attachment,
        commandID: "complete-invalid-proof", client: client,
        sessionAttachment: sessionAttachment,
        causalWorkCursor: created.workCursor)

    let invalid = try await service.completeWork(request)
    XCTAssertEqual(invalid.state, .rejected)
    XCTAssertEqual(invalid.rejection, .terminalProofUnavailable)
    await committer.enableRecovery()
    let reconciled = try await service.completeWork(request)
    XCTAssertEqual(reconciled.state, .accepted)
    XCTAssertEqual(reconciled.terminalProof?.session, session)
    XCTAssertEqual(reconciled.terminalProof?.sessionJournal, sessionJournal)
}

func test_workServiceAuthorizationIsSeparateFromWorkIdentity() async throws {
    let service = InMemoryWorkService(host: serviceHost, authorizer: WorkServiceCapabilityPolicy(
        grantsByClient: [ClientRef("read-only"): [.observe, .control]]))
    try await service.register(.init(work: serviceWork, journal: serviceJournal))
    let client = ClientRef("read-only")
    let attached = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: client,
        commandID: "attach-auth",
        causalControlCursor: serviceControlCursor(),
        requestedCapabilities: [.observe, .control, .send]))
    let attachment = try XCTUnwrap(attached.attachment)
    XCTAssertTrue(attached.authorization.allows(.observe))
    XCTAssertTrue(attached.authorization.allows(.control))
    XCTAssertFalse(attached.authorization.allows(.send))
    XCTAssertTrue(attached.authorization.denied.contains(.send))
    let receipt = try await service.command(serviceCommand(
        .send, id: "unauthorized", client: client, attachment: attachment.attachment,
        cursor: try XCTUnwrap(attached.work.hostObservation?.servedCursor), value: "no"))
    XCTAssertEqual(receipt.state, .rejected)
    XCTAssertEqual(receipt.rejection, .authorizationDenied)
    XCTAssertFalse(receipt.authorization.allows(.send))
}

func test_workServiceListAndDescribeAuthorizeEveryPrincipal() async throws {
    let reader = ClientRef("reader")
    let intruder = ClientRef("intruder")
    let service = InMemoryWorkService(
        host: serviceHost,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [reader: [.observe]]))
    try await service.register(.init(work: serviceWork, journal: serviceJournal))
    XCTAssertEqual(try await service.listWorks(.init(client: reader)).works.count, 1)
    XCTAssertEqual(
        try await service.describeWork(.init(
            work: serviceWork, journal: serviceJournal, client: reader)).work,
        serviceWork)

    do {
        _ = try await service.listWorks(.init(client: intruder))
        XCTFail("list must authorize the requesting principal")
    } catch WorkServiceProtocolError.capabilityDenied(.observe) { }
    do {
        _ = try await service.describeWork(.init(
            work: serviceWork, journal: serviceJournal, client: intruder))
        XCTFail("describe must authorize the requesting principal")
    } catch WorkServiceProtocolError.capabilityDenied(.observe) { }
}

func test_workServiceCreateCarriesBoundedHostPolicyAndFreshIdentity() async throws {
    let host = WorkHostRef("create-host")
    let service = InMemoryWorkService(
        host: host, instanceID: "create-instance", startIdentity: "create-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [ClientRef("creator"): [.observe, .control]]))
    let controlCursor = try await service.handshake(.init(client: ClientRef("creator"))).controlCursor
    let created = try await service.createWork(.init(
        client: ClientRef("creator"), commandID: "create-1",
        causalControlCursor: controlCursor,
        configuration: .init(modelID: "model-id", contextPolicy: "workspace-policy")))
    let work = WorkRef(workHostID: host.workHostID, workID: "work-1")
    let journal = JournalRef.work(work)
    let session = SessionRef("session-1")
    let sessionJournal = JournalRef.session(
        session, authority: TimelineAuthorityRef(host.workHostID))
    XCTAssertEqual(created.work.work, work)
    XCTAssertEqual(created.work.journal, journal)
    XCTAssertEqual(created.session, session)
    XCTAssertEqual(created.sessionJournal, sessionJournal)
    XCTAssertEqual(created.sessionAttachment, SessionAttachmentRef("session-attachment-1"))
    XCTAssertEqual(created.attachment.attachment, ClientAttachmentRef("attachment-1"))
    XCTAssertEqual(created.attachment.client, ClientRef("creator"))
    XCTAssertEqual(created.work.configuration.modelID, "model-id")
    _ = try await service.createWork(.init(
        client: ClientRef("creator"), commandID: "create-1",
        causalControlCursor: controlCursor,
        configuration: .init(modelID: "model-id", contextPolicy: "workspace-policy")))
    do {
        _ = try await service.createWork(.init(
            client: ClientRef("creator"), commandID: "create-1",
            causalControlCursor: controlCursor,
            configuration: .init(modelID: "model-id", contextPolicy: "changed-policy")))
        XCTFail("redaction must not discard the host's retained request used for exact retry")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("different contents"))
    }
    XCTAssertTrue(created.authorization.allows(.control))
    XCTAssertNil(created.work.hostObservation?.currentRun)
    XCTAssertEqual(created.receipt.outcome, .created)
    XCTAssertEqual(created.receipt.causalControlCursor, controlCursor)
    XCTAssertEqual(created.receipt.resultingControlCursor.sequence, 3)
    XCTAssertEqual(created.workCursor.journal, journal)
    XCTAssertEqual(created.workCursor.sequence, 2)
    XCTAssertEqual(created.sessionCursor.journal, sessionJournal)
    XCTAssertEqual(created.sessionCursor.sequence, 3)
    XCTAssertEqual(created.work.sessionAttachments.count, 1)
    XCTAssertEqual(created.work.sessionAttachments.first?.publication, .mirrored)
    XCTAssertTrue(created.attachment.readAcknowledgements.isEmpty)
    XCTAssertEqual(created.controlCursor.journal, JournalRef.workHost(host))

    let wrongCreateCursor = JournalCursor(
        journal: JournalRef.workHost(host), eventID: "not-current", sequence: 1)
    do {
        _ = try await service.createWork(.init(
            client: ClientRef("creator"), commandID: "create-wrong-cursor",
            causalControlCursor: wrongCreateCursor))
        XCTFail("creation must require the exact current control cursor")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("current"))
    }

    let oversized = String(repeating: "x", count: WorkServiceBounds.maxCommandValueCharacters + 1)
    do {
        _ = try await service.createWork(.init(
            client: ClientRef("creator"), commandID: "create-2",
            causalControlCursor: created.controlCursor,
            configuration: .init(providerID: oversized)))
        XCTFail("oversized creation body must be rejected explicitly")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("bounded"))
    }

    // Codable input is adversarial at the transport boundary: a peer can claim that an
    // oversized value was not truncated. The host must inspect actual decoded lengths before
    // creating durable Work rather than trusting the marker.
    let oversizedJSON = try JSONSerialization.data(withJSONObject: [
        "providerID": oversized,
        "wasTruncated": false,
    ])
    let decoded = try JSONDecoder().decode(WorkServiceWorkConfiguration.self, from: oversizedJSON)
    XCTAssertFalse(decoded.wasTruncated)
    do {
        _ = try await service.createWork(.init(
            client: ClientRef("creator"), commandID: "create-decoded",
            causalControlCursor: created.controlCursor,
            configuration: decoded))
        XCTFail("decoded oversized creation body must be rejected explicitly")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("bounded"))
    }
    let decodeService = InMemoryWorkService(
        host: WorkHostRef("decode-host"), authorizer: WorkServiceCapabilityPolicy())
    let registerWork = WorkRef(workHostID: "decode-host", workID: "registered-too-large")
    let registerJournal = JournalRef.work(registerWork, journalID: "registered-too-large-journal")
    do {
        try await decodeService.register(.init(work: registerWork, journal: registerJournal,
                                                configuration: decoded))
        XCTFail("decoded oversized seed configuration must be rejected explicitly")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("identity"))
    }
}

func test_workServiceCreateRequiresAnAdvertisedAvailableWorkspaceID() async throws {
    let host = WorkHostRef("workspace-selection-host")
    let client = ClientRef("workspace-creator")
    let availableID = try WorkHostWorkspaceID(
        "workspace-00000000-0000-0000-0000-000000000011")
    let unavailableID = try WorkHostWorkspaceID(
        "workspace-00000000-0000-0000-0000-000000000012")
    let catalog = try WorkHostWorkspaceCatalog(entries: [
        try WorkHostWorkspaceDescriptor(
            workspaceID: availableID, label: "Available", availability: .available,
            capabilities: [.directory, .resolve]),
        try WorkHostWorkspaceDescriptor(
            workspaceID: unavailableID, label: "Unavailable", availability: .unavailable,
            capabilities: [.directory]),
    ], revision: 2)
    let service = InMemoryWorkService(
        host: host,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: [.observe, .control]]),
        workspaceCatalog: catalog)
    let cursor = try await service.handshake(.init(client: client)).controlCursor

    for (label, workspaceID) in [
        ("missing", nil), ("unknown", try? WorkHostWorkspaceID(
            "workspace-00000000-0000-0000-0000-000000000013")),
        ("unavailable", unavailableID),
    ] as [(String, WorkHostWorkspaceID?)] {
        do {
            _ = try await service.createWork(.init(
                client: client, commandID: "create-" + label,
                causalControlCursor: cursor,
                configuration: .init(workspaceID: workspaceID)))
            XCTFail(label + " workspace selection must fail closed")
        } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
            XCTAssertTrue(diagnostic.contains("workspaceID"))
        }
    }

    let created = try await service.createWork(.init(
        client: client, commandID: "create-available", causalControlCursor: cursor,
        configuration: .init(workspaceID: availableID)))
    XCTAssertEqual(created.work.configuration.workspaceID, availableID)

    let encoded = try JSONSerialization.data(withJSONObject: [
        "workspaceID": availableID.rawValue,
        "path": "/private/host-secret/workspace",
    ])
    do {
        _ = try JSONDecoder().decode(WorkServiceWorkConfiguration.self, from: encoded)
        XCTFail("raw path must not accompany an opaque workspaceID")
    } catch is DecodingError {
        XCTAssertTrue(true)
    }
}

func test_workServiceCreateIdempotencyKeyIsTypedAndInjective() async throws {
    let host = WorkHostRef("typed-create-host")
    let clientA = ClientRef("right")
    let clientB = ClientRef("client")
    let service = InMemoryWorkService(
        host: host,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            clientA: [.observe, .control], clientB: [.observe, .control],
        ]))
    let controlCursor = try await service.handshake(.init(client: clientA)).controlCursor
    let first = try await service.createWork(.init(
        client: clientA, commandID: "client\u{1F}command",
        causalControlCursor: controlCursor))
    let duplicate = try await service.createWork(.init(
        client: clientA, commandID: "client\u{1F}command",
        causalControlCursor: controlCursor))
    XCTAssertEqual(duplicate, first)
    let second = try await service.createWork(.init(
        client: clientB, commandID: "command",
        causalControlCursor: first.controlCursor))
    XCTAssertEqual(first.receipt.state, .accepted)
    XCTAssertEqual(second.receipt.state, .accepted)
    XCTAssertNotEqual(first.work.work, second.work.work)
    XCTAssertNotEqual(first.session, second.session)
}

func test_workServiceNonzeroSeedDeclaresMissingHistoryOrRejectsCompleteness() async throws {
    let host = WorkHostRef("seed-history-host")
    let work = WorkRef(workHostID: host.workHostID, workID: "work")
    let journal = JournalRef.work(work, journalID: "journal")
    let cursor = JournalCursor(journal: journal, eventID: "retained-tip", sequence: 7)
    let service = InMemoryWorkService(
        host: host,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [ClientRef("gui"): [.observe]]))
    do {
        try await service.register(.init(
            work: work, journal: journal, cursor: cursor, sourceCompleteness: .complete))
        XCTFail("a nonzero seed without retained events cannot claim complete source history")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("retained event history"))
    }

    try await service.register(.init(
        work: work, journal: journal, cursor: cursor, sourceCompleteness: .incomplete))
    let described = try await service.describeWork(.init(
        work: work, journal: journal, client: ClientRef("gui")))
    XCTAssertEqual(described.hostObservation?.servedCursor, cursor)
    XCTAssertEqual(
        described.omissions.first(where: { $0.category == "event_history" })?.count,
        cursor.sequence)
}

func test_workServiceIncompleteSourceIsVisibleButCannotAcceptControl() async throws {
    let (service, _) = try await serviceFixture(source: .incomplete)
    let client = ClientRef("gui")
    let attached = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: client,
        commandID: "attach-incomplete",
        causalControlCursor: serviceControlCursor(),
        requestedCapabilities: allServiceCommands))
    let listed = try await service.listWorks(listRequest(pageSize: 1000))
    XCTAssertEqual(listed.works.count, 1)
    XCTAssertEqual(listed.works[0].hostObservation?.sourceCompleteness, .incomplete)
    XCTAssertEqual(attached.state, .rejected)
    XCTAssertEqual(attached.rejection, .sourceIncomplete)
    XCTAssertNil(attached.attachment)

    let runningHost = WorkHostRef("incomplete-running-host")
    let runningWork = WorkRef(workHostID: runningHost.workHostID, workID: "work")
    let runningJournal = JournalRef.work(runningWork, journalID: "journal")
    let runningRun = RunRef("run")
    let runningService = InMemoryWorkService(
        host: runningHost,
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [client: [.observe]]))
    try await runningService.register(.init(
        work: runningWork, journal: runningJournal,
        execution: .running, currentRun: runningRun,
        sourceCompleteness: .incomplete))
    do {
        try await runningService.finishRun(runningRun, for: runningWork)
        XCTFail("an incomplete source cannot synthesize a durable run.finished mutation")
    } catch WorkServiceProtocolError.sourceIncomplete { }
    let stillRunning = try await runningService.describeWork(.init(
        work: runningWork, journal: runningJournal, client: client))
    XCTAssertEqual(stillRunning.execution, .running)
    XCTAssertEqual(stillRunning.currentRun, runningRun)

    // Recovery-required and unknown are explicit non-actionable states, including for the
    // in-memory conformance service. They are valid read seeds for compatibility tests, but no
    // lifecycle or terminal command may treat either as idle.
    for (index, execution) in [
        (0, WorkServiceExecutionState.recoveryRequired),
        (1, WorkServiceExecutionState.unknown),
    ] {
        let host = WorkHostRef("non-actionable-seed-host-\(index)")
        let work = WorkRef(workHostID: host.workHostID, workID: "non-actionable-seed-work-\(index)")
        let journal = JournalRef.work(work, journalID: "non-actionable-seed-journal-\(index)")
        let seeded = InMemoryWorkService(
            host: host,
            authorizer: WorkServiceCapabilityPolicy(
                grantsByClient: [client: allServiceCommands]),
            terminalCommitter: TestTerminalCommitter())
        try await seeded.register(.init(
            work: work, journal: journal, execution: execution))
        let attached = try await seeded.attach(.init(
            work: work, journal: journal, client: client,
            commandID: "attach-non-actionable-\(index)",
            causalControlCursor: JournalCursor(
                journal: .workHost(host), sequence: 0),
            requestedCapabilities: allServiceCommands))
        let clientAttachment = try XCTUnwrap(attached.attachment)
        let descriptor = try await seeded.describeWork(.init(
            work: work, journal: journal, client: client))
        XCTAssertEqual(descriptor.execution, execution)
        let cursor = try XCTUnwrap(descriptor.hostObservation?.servedCursor)
        for (kind, commandID) in [
            (WorkServiceCommandKind.start, "start-non-actionable-\(index)"),
            (.complete, "complete-non-actionable-\(index)"),
            (.destroy, "destroy-non-actionable-\(index)"),
        ] {
            let receipt = try await seeded.command(WorkServiceCommandRequest(
                work: work, journal: journal, attachment: clientAttachment.attachment,
                commandID: commandID, client: client,
                causalWorkCursor: cursor, kind: kind,
                value: kind == .start ? "must not start" : nil))
            XCTAssertEqual(receipt.state, .rejected)
            XCTAssertEqual(receipt.rejection, .invalidState)
        }
    }
}

func test_workServiceEventsAndArtifactsAreBoundedDescriptors() async throws {
    let unboundedBodyWork = WorkRef(
        workHostID: serviceHost.workHostID, workID: "unbounded-body-work")
    let unboundedBodyJournal = JournalRef.work(unboundedBodyWork, journalID: "unbounded-body-journal")
    let unboundedBodyReference = TimelineBodyReference(
        authority: unboundedBodyJournal, referenceID: "unbounded-body",
        mediaType: "text/plain", byteCount: nil)
    let unboundedBodyService = InMemoryWorkService(
        host: serviceHost, authorizer: permissiveServiceAuthorizer())
    do {
        try await unboundedBodyService.register(.init(
            work: unboundedBodyWork, journal: unboundedBodyJournal,
            bodies: [unboundedBodyReference: Data("body".utf8)]))
        XCTFail("a retained seed body without an exact byte count was accepted")
    } catch WorkServiceProtocolError.invalidRequest {
        XCTAssertTrue(true)
    }

    let (service, _) = try await serviceFixture()
    let client = ClientRef("gui")
    let attached = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: client,
        commandID: "attach-events",
        causalControlCursor: serviceControlCursor(),
        requestedCapabilities: allServiceCommands))
    let attachment = try XCTUnwrap(attached.attachment)
    let attachmentCursor = try XCTUnwrap(
        attached.work.hostObservation?.servedCursor)
    let started = try await service.command(serviceCommand(
        .start, id: "bounded-start", client: client, attachment: attachment.attachment,
        cursor: attachmentCursor))
    let running = try XCTUnwrap(started.resultingWorkCursor)
    let sent = try await service.command(serviceCommand(
        .send, id: "bounded-send", client: client, attachment: attachment.attachment,
        cursor: running, value: "page two"))
    let sentCursor = try XCTUnwrap(sent.resultingWorkCursor)
    let firstPage = try await service.eventsAfterCursor(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        target: .work(journal: serviceJournal),
        afterCursor: attachmentCursor, limit: 1))
    XCTAssertEqual(firstPage.events.count, 1)
    XCTAssertEqual(
        JournalCursor(journal: firstPage.events[0].journal,
                      eventID: firstPage.events[0].eventID,
                      sequence: firstPage.events[0].sequence),
        JournalCursor(
            journal: serviceJournal, eventID: firstPage.events[0].eventID,
            sequence: attachmentCursor.sequence + 1))
    XCTAssertEqual(firstPage.events[0].type, TimelineEventType.runStarted)
    XCTAssertFalse(firstPage.events[0].type.isEmpty)
    XCTAssertEqual(firstPage.events[0].payload, .object([:]))
    XCTAssertEqual(firstPage.events[0].provenance, .native)
    XCTAssertEqual(firstPage.omissions.first?.category, "events")
    XCTAssertEqual(firstPage.omissions.first?.count, 2)
    do {
        _ = try await service.eventsAfterCursor(.init(
            work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
            client: client, target: .work(journal: serviceJournal),
            afterCursor: attachmentCursor, limit: 8, maxBytes: 1))
        XCTFail("a page that cannot fit its first event must report explicit non-progress")
    } catch WorkServiceProtocolError.eventPageCannotProgress(
        let requiredBytes, let maximumBytes
    ) {
        XCTAssertTrue(requiredBytes > maximumBytes)
        XCTAssertEqual(maximumBytes, 1)
    }
    let secondPage = try await service.eventsAfterCursor(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        target: .work(journal: serviceJournal),
        afterCursor: try XCTUnwrap(firstPage.nextCursor), limit: 1))
    XCTAssertEqual(secondPage.events.count, 1)
    XCTAssertEqual(
        JournalCursor(journal: secondPage.events[0].journal,
                      eventID: secondPage.events[0].eventID,
                      sequence: secondPage.events[0].sequence), running)
    XCTAssertEqual(secondPage.events[0].type, TimelineEventType.commandAccepted)
    XCTAssertNotEqual(firstPage.events[0].eventID, secondPage.events[0].eventID)
    let thirdPage = try await service.eventsAfterCursor(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        target: .work(journal: serviceJournal),
        afterCursor: try XCTUnwrap(secondPage.nextCursor), limit: 1))
    XCTAssertEqual(thirdPage.events.count, 1)
    XCTAssertEqual(
        JournalCursor(journal: thirdPage.events[0].journal,
                      eventID: thirdPage.events[0].eventID,
                      sequence: thirdPage.events[0].sequence), sentCursor)
    let eventBodyReference: TimelineBodyReference
    if case .object(let payload) = thirdPage.events[0].payload,
       let bodyReferenceValue = payload["body_reference"] {
        XCTAssertNil(payload["value"])
        eventBodyReference = try JSONDecoder().decode(
            TimelineBodyReference.self, from: JSONEncoder().encode(bodyReferenceValue))
    } else {
        throw UnwrapFailure(description: "send event must retain its body reference")
    }
    let eventBody = try await service.fetchBody(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        reference: eventBodyReference))
    XCTAssertEqual(eventBody.status, .retained)
    XCTAssertEqual(eventBody.data, Data("page two".utf8))
    XCTAssertNil(thirdPage.nextCursor)
    XCTAssertEqual(thirdPage.servedCursor, sentCursor)
    XCTAssertTrue(try await service.describeWork(describeRequest())
        .attachments.first(where: { $0.attachment == attachment.attachment })?
        .readAcknowledgements.isEmpty == true)
    let forgedCursor = JournalCursor(
        journal: serviceJournal, eventID: "different-event-at-same-sequence", sequence: running.sequence)
    do {
        _ = try await service.eventsAfterCursor(.init(
            work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
            client: client,
            target: .work(journal: serviceJournal),
            afterCursor: forgedCursor, limit: 1))
        XCTFail("a cursor with a foreign event identity must be rejected")
    } catch WorkServiceProtocolError.invalidRequest(let diagnostic) {
        XCTAssertTrue(diagnostic.contains("identity"))
    }
    let artifact = try await service.fetchArtifact(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client, artifactID: "artifact-1"))
    XCTAssertEqual(artifact.artifactID, "artifact-1")
    XCTAssertEqual(artifact.byteCount, 12)
    XCTAssertFalse(artifact.digest?.contains("secret") == true)
    let bodyReference = try XCTUnwrap(artifact.bodyReference)
    let bodyPage = try await service.fetchBody(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        reference: bodyReference, limit: 5))
    XCTAssertEqual(bodyPage.status, .retained)
    XCTAssertEqual(bodyPage.offset, 0)
    XCTAssertEqual(bodyPage.data, Data("hello".utf8))
    XCTAssertEqual(bodyPage.nextOffset, 5)
    let bodyTail = try await service.fetchBody(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        reference: bodyReference, offset: try XCTUnwrap(bodyPage.nextOffset), limit: 64))
    XCTAssertEqual(bodyTail.status, .retained)
    XCTAssertEqual(bodyTail.data, Data(" world!".utf8))
    XCTAssertNil(bodyTail.nextOffset)
    let mismatchReference = TimelineBodyReference(
        authority: serviceJournal, referenceID: "artifact-body-mismatch", mediaType: "text/plain", byteCount: 12,
        digest: "sha256:" + String(repeating: "0", count: 64))
    let mismatch = try await service.fetchBody(.init(
        work: serviceWork, journal: serviceJournal, attachment: attachment.attachment,
        client: client,
        reference: mismatchReference))
    XCTAssertEqual(mismatch.status, .unavailable)
    XCTAssertTrue(mismatch.diagnostic?.contains("digest") == true)
    let observeOnlyResponse = try await service.attach(.init(
        work: serviceWork, journal: serviceJournal, client: ClientRef("observe-only"),
        commandID: "attach-observe-only", causalControlCursor: attached.resultingControlCursor,
        requestedCapabilities: [.observe, .control]))
    let observeOnly = try XCTUnwrap(observeOnlyResponse.attachment)
    // Attachment IDs are addressable projection identities, never bearer authority. Even a
    // directly embedded client must name the principal that owns the attachment on every read.
    do {
        _ = try await service.snapshot(.init(
            work: serviceWork, journal: serviceJournal,
            attachment: attachment.attachment, client: ClientRef("observe-only"),
            target: .work(journal: serviceJournal),
            afterCursor: sentCursor, limit: 1))
        XCTFail("another client reused a visible attachment for snapshot")
    } catch WorkServiceProtocolError.attachmentNotFound {
        XCTAssertTrue(true)
    }
    do {
        _ = try await service.eventsAfterCursor(.init(
            work: serviceWork, journal: serviceJournal,
            attachment: attachment.attachment, client: ClientRef("observe-only"),
            target: .work(journal: serviceJournal),
            afterCursor: sentCursor, limit: 1))
        XCTFail("another client reused a visible attachment for event reads")
    } catch WorkServiceProtocolError.attachmentNotFound {
        XCTAssertTrue(true)
    }
    do {
        _ = try await service.fetchArtifact(.init(
            work: serviceWork, journal: serviceJournal,
            attachment: attachment.attachment, client: ClientRef("observe-only"),
            artifactID: "artifact-1"))
        XCTFail("another client inherited artifact inspection capability")
    } catch WorkServiceProtocolError.attachmentNotFound {
        XCTAssertTrue(true)
    }
    do {
        _ = try await service.fetchBody(.init(
            work: serviceWork, journal: serviceJournal,
            attachment: attachment.attachment, client: ClientRef("observe-only"),
            reference: bodyReference))
        XCTFail("another client reused a visible attachment for retained body")
    } catch WorkServiceProtocolError.attachmentNotFound {
        XCTAssertTrue(true)
    }
    do {
        _ = try await service.fetchBody(.init(
            work: serviceWork, journal: serviceJournal, attachment: observeOnly.attachment,
            client: ClientRef("observe-only"),
            reference: bodyReference))
        XCTFail("observe-only clients must not recover artifact bodies")
    } catch WorkServiceProtocolError.capabilityDenied(.inspectArtifacts) {
        XCTAssertTrue(true)
    }

    let oversized = String(repeating: "p", count: WorkServiceBounds.maxCommandValueCharacters + 1)
    let oversizedRequest = serviceCommand(
        .send, id: "oversized", client: client, attachment: attachment.attachment,
        cursor: sentCursor, value: oversized)
    XCTAssertEqual(oversizedRequest.value, oversized)
    XCTAssertTrue(oversizedRequest.valueWasTruncated)
    let rejected = try await service.command(oversizedRequest)
    XCTAssertTrue(rejected.state == .rejected)
    XCTAssertEqual(rejected.rejection, .malformedRequest)
}

func test_workServiceRetainsSeedArtifactOverflowAsAnExplicitOmission() async throws {
    let host = WorkHostRef("artifact-overflow-host")
    let work = WorkRef(workHostID: host.workHostID, workID: "artifact-overflow-work")
    let journal = JournalRef.work(work, journalID: "artifact-overflow-journal")
    let service = InMemoryWorkService(host: host, authorizer: permissiveServiceAuthorizer())
    let longLabel = String(
        repeating: "m", count: WorkServiceBounds.maxDiagnosticCharacters + 1)
    let encodedArtifact = try JSONEncoder().encode(WorkServiceArtifactDescriptor(
        artifactID: "decoded-artifact", work: work, label: "short"))
    var hostileArtifactJSON = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encodedArtifact) as? [String: Any])
    hostileArtifactJSON["label"] = longLabel
    hostileArtifactJSON["metadataWasTruncated"] = false
    let decodedArtifact = try JSONDecoder().decode(
        WorkServiceArtifactDescriptor.self,
        from: JSONSerialization.data(withJSONObject: hostileArtifactJSON))
    XCTAssertTrue(decodedArtifact.metadataWasTruncated)
    XCTAssertEqual(decodedArtifact.label.count, WorkServiceBounds.maxDiagnosticCharacters)
    let artifacts = (0...WorkServiceBounds.maxArtifactsPerWork).map { index in
        WorkServiceArtifactDescriptor(
            artifactID: "artifact-\(index)", work: work,
            label: index == 0 ? longLabel : "artifact \(index)")
    }
    try await service.register(.init(work: work, journal: journal, artifacts: artifacts))
    let descriptor = try await service.describeWork(describeRequest(work: work, journal: journal))
    XCTAssertEqual(descriptor.artifacts.count, WorkServiceBounds.maxArtifactsPerWork)
    XCTAssertEqual(
        descriptor.omissions.first(where: { $0.category == "artifacts" })?.count, 1)
    XCTAssertTrue(descriptor.artifacts[0].metadataWasTruncated)
    XCTAssertEqual(descriptor.artifacts[0].label.count, WorkServiceBounds.maxDiagnosticCharacters)
    XCTAssertEqual(
        descriptor.omissions.first(where: { $0.category == "artifact_metadata" })?.count, 1)
    let page = try await service.listWorks(listRequest(pageSize: 1))
    XCTAssertEqual(page.works.first?.omissions.first(where: { $0.category == "artifacts" })?.count, 1)
}

func test_workServiceRegistryMarksOmittedUnavailableHostsBeyondBound() async throws {
    let registry = InMemoryWorkServiceRegistry()
    for index in 0...WorkServiceBounds.maxOmissions {
        let host = WorkHostRef("unavailable-host-\(index)")
        let service = InMemoryWorkService(
            host: host, authorizer: WorkServiceCapabilityPolicy())
        await service.setReachable(false)
        await registry.register(service)
    }
    let page = await registry.listWorks(.init(client: ClientRef("gui")))
    XCTAssertTrue(page.works.isEmpty)
    XCTAssertEqual(page.omissions.count, WorkServiceBounds.maxOmissions)
    XCTAssertEqual(
        page.omissions.filter { $0.category == "host_unavailable" }.count,
        WorkServiceBounds.maxOmissions - 1)
    XCTAssertEqual(page.omissions.last?.category, "omission_records")
    XCTAssertEqual(page.omissions.last?.count, 2)
}

func test_workServiceRegistryDoesNotLetUnavailableHostPoisonOtherRows() async throws {
    let good = InMemoryWorkService(
        host: WorkHostRef("good-host"), instanceID: "good-instance", startIdentity: "good-start",
        authorizer: WorkServiceCapabilityPolicy(
            grantsByClient: [ClientRef("gui"): [.observe]]))
    let goodWork = WorkRef(workHostID: "good-host", workID: "good-work")
    try await good.register(.init(work: goodWork, journal: .work(goodWork)))
    let goodWork2 = WorkRef(workHostID: "good-host", workID: "good-work-2")
    try await good.register(.init(work: goodWork2, journal: .work(goodWork2)))
    let bad = InMemoryWorkService(
        host: WorkHostRef("bad-host"), instanceID: "bad-instance", startIdentity: "bad-start",
        authorizer: WorkServiceCapabilityPolicy())
    let badWork = WorkRef(workHostID: "bad-host", workID: "bad-work")
    try await bad.register(.init(work: badWork, journal: .work(badWork)))
    await bad.setReachable(false)
    let registry = InMemoryWorkServiceRegistry()
    await registry.register(good)
    await registry.register(bad)
    let page = await registry.listWorks(listRequest(pageSize: 1))
    XCTAssertEqual(page.works.count, 1)
    XCTAssertEqual(page.works.first?.work, goodWork)
    XCTAssertNotNil(page.nextPageToken)
    XCTAssertTrue(page.omissions.contains { $0.category == "host_unavailable" })
    XCTAssertEqual(page.works.first?.hostObservation?.reachability, .observedReachable)
    let secondPage = await registry.listWorks(listRequest(
        pageSize: 1, pageToken: page.nextPageToken))
    XCTAssertEqual(secondPage.works.count, 1)
    XCTAssertEqual(secondPage.works.first?.work, goodWork2)
    XCTAssertNil(secondPage.nextPageToken)
}
