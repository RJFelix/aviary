import Foundation

@testable import AviaryCore

private func cancelServiceJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(value)))
}

private func cancelServiceDraft(
    _ type: String, origin: WorkAgentHandleOrigin, handle: HandleRef,
    cause: EventRef? = nil, command: CommandRef? = nil,
    payload: JSONValue = .object([:])
) -> TimelineEventDraft {
    TimelineEventDraft(
        command: command, causedByEventID: cause,
        session: origin.session, work: origin.work, workHost: origin.workHost,
        client: command?.client, sessionAttachment: origin.sessionAttachment,
        run: origin.run, handle: handle, type: type,
        declaredDomains: [.work, .runtime, .externalEffects], payload: payload)
}

private actor CancelServiceCanceller: WorkServiceAgentHandleCancelling {
    enum Mode {
        case commit(WorkAgentChildCoordinator.CancellationResult)
        case commitWithSessionAttachment(
            SessionAttachmentRef, WorkAgentChildCoordinator.CancellationResult)
        case noWrite
    }

    private var route: WorkAgentHandleJournal?
    private var origin: WorkAgentHandleOrigin?
    private var latest: EventRef?
    private var mode: Mode = .commit(.accepted)
    private var committed: TimelineJournalCommit?
    private var inFlight: Task<TimelineJournalCommit, Error>?
    private var calls = 0

    func configure(
        route: WorkAgentHandleJournal, origin: WorkAgentHandleOrigin,
        latest: EventRef, mode: Mode = .commit(.accepted)
    ) {
        self.route = route
        self.origin = origin
        self.latest = latest
        self.mode = mode
    }

    func setMode(_ mode: Mode) { self.mode = mode }
    var callCount: Int { calls }
    var cancellationCommit: TimelineJournalCommit? { committed }

    func cancel(
        work: WorkRef, handle: HandleRef, command: CommandRef
    ) async throws -> WorkAgentChildCoordinator.CancellationResult {
        calls += 1
        guard let route, let origin, origin.work == work, let latest else {
            return .unavailable
        }
        if committed != nil { return .alreadyRequested }
        if let inFlight {
            _ = try await inFlight.value
            return .alreadyRequested
        }
        switch mode {
        case .noWrite:
            return .ambiguous
        case .commit(let result), .commitWithSessionAttachment(_, let result):
            let recordedCommand: CommandRef
            switch mode {
            case .commit:
                recordedCommand = command
            case .commitWithSessionAttachment(let attachment, _):
                recordedCommand = CommandRef(
                    commandID: command.commandID, client: command.client,
                    sessionAttachment: attachment, causalCursor: command.causalCursor)
            case .noWrite:
                fatalError("handled above")
            }
            let draft = cancelServiceDraft(
                TimelineEventType.agentHandleCancelRequested, origin: origin,
                handle: handle, cause: latest, command: recordedCommand,
                payload: try cancelServiceJSON(
                    WorkAgentHandleCancelRequestedPayload(cause: .client)))
            let task = Task { try await route.append(draft) }
            inFlight = task
            committed = try await task.value
            inFlight = nil
            return result
        }
    }
}

private struct CancelServiceFixture {
    let home: AgentHome
    let service: JournalBackedWorkService
    let canceller: CancelServiceCanceller
    let route: WorkAgentHandleJournal
    let bundle: RunJournalBundle
    let creator: ClientRef
    let otherClient: ClientRef
    let work: WorkRef
    let journal: JournalRef
    let primaryAttachment: WorkServiceClientAttachment
    let secondaryAttachment: WorkServiceClientAttachment
    let otherClientAttachment: WorkServiceClientAttachment
    let origin: WorkAgentHandleOrigin
    let handle: HandleRef
    let requestBody: TimelineBodyReference
    let started: TimelineJournalCommit
}

private func makeCancelServiceFixture(
    suffix: String = UUID().uuidString.lowercased(),
    secondaryCapabilities: Set<WorkServiceCapability> = [.observe, .control, .cancel],
    cancellerMode: CancelServiceCanceller.Mode = .commit(.accepted)
) async throws -> CancelServiceFixture {
    let home = scratchHome()
    let creator = ClientRef("cancel-service-client-\(suffix)")
    let otherClient = ClientRef("cancel-service-other-client-\(suffix)")
    let grants = Set(WorkServiceCapability.allCases)
    let canceller = CancelServiceCanceller()
    let service = try JournalBackedWorkService(
        home: home,
        actor: TimelineActor(actorID: "cancel-service-\(suffix)", kind: "work-host"),
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            creator: grants, otherClient: grants,
        ]),
        manifestStore: JournalBackedTestManifestStore())
    try await service.installAgentHandleCanceller(canceller)
    let control = try await service.handshake(.init(client: creator)).controlCursor
    let created = try await service.createWork(WorkServiceCreateWorkRequest(
        client: creator, commandID: "cancel-create-\(suffix)",
        causalControlCursor: control,
        requestedCapabilities: [.observe, .control, .cancel, .createSession]))
    let secondary = try await service.createSession(WorkServiceCreateSessionRequest(
        work: created.work.work, journal: created.work.journal,
        attachment: created.attachment.attachment, client: creator,
        commandID: "cancel-session-\(suffix)",
        causalControlCursor: created.controlCursor,
        causalWorkCursor: created.workCursor,
        requestedCapabilities: secondaryCapabilities))
    let secondaryAttachment = try XCTUnwrap(secondary.attachment)
    let secondarySession = try XCTUnwrap(secondary.session)
    let secondarySessionAttachment = try XCTUnwrap(secondary.sessionAttachment)
    XCTAssertEqual(secondaryAttachment.session, secondarySession)
    XCTAssertEqual(secondaryAttachment.sessionAttachment, secondarySessionAttachment)
    let otherAttached = try await service.attach(WorkServiceAttachRequest(
        work: created.work.work, journal: created.work.journal, client: otherClient,
        session: secondarySession, sessionJournal: try XCTUnwrap(secondary.sessionJournal),
        sessionAttachment: secondarySessionAttachment,
        commandID: "cancel-other-client-\(suffix)",
        causalControlCursor: secondary.controlCursor,
        requestedCapabilities: secondaryCapabilities))
    let otherClientAttachment = try XCTUnwrap(otherAttached.attachment)

    let work = created.work.work
    let route = try WorkAgentHandleJournal(
        home: home, work: work,
        actor: TimelineActor(actorID: "cancel-route-\(suffix)", kind: "work-host"))
    let run = RunRef("cancel-origin-run-\(suffix)")
    let bundle = try await route.openRun {
        try await RunJournalBundle.openForExecution(
            home: home,
            identity: SessionWorkIdentity(
                sessionID: created.session.sessionID, work: work, runID: run.runID),
            actorID: "cancel-origin-\(suffix)",
            makeAttachmentID: { created.sessionAttachment.attachmentID })
    }
    let origin = WorkAgentHandleOrigin(
        work: work, workHost: WorkHostRef(work.workHostID), session: created.session,
        sessionAttachment: created.sessionAttachment, run: run)
    let handle = HandleRef("cancel-handle-\(suffix)")
    let requestBody = try ContextBodyStore(home: home).retain(
        Data("private request \(suffix)".utf8), authority: created.work.journal,
        mediaType: "text/plain")
    let queued = try await route.append(cancelServiceDraft(
        TimelineEventType.agentHandleQueued, origin: origin, handle: handle,
        payload: try cancelServiceJSON(WorkAgentHandleQueuedPayload(
            origin: origin, label: "cancel child", deadline: Date().addingTimeInterval(300),
            requestBody: requestBody))))
    let started = try await route.append(cancelServiceDraft(
        TimelineEventType.agentHandleStarted, origin: origin, handle: handle,
        cause: queued.eventRef))
    // The service has no Hosted registry entry for this focused fixture. Release both writer
    // leases before it performs a canonical cold read; later Handle mutations use route-owned
    // short cold writers and do not pretend to prove a live interpreter.
    try await bundle.closeChecked()
    await canceller.configure(
        route: route, origin: origin, latest: started.eventRef, mode: cancellerMode)
    return CancelServiceFixture(
        home: home, service: service, canceller: canceller, route: route, bundle: bundle,
        creator: creator, otherClient: otherClient, work: work, journal: created.work.journal,
        primaryAttachment: created.attachment, secondaryAttachment: secondaryAttachment,
        otherClientAttachment: otherClientAttachment,
        origin: origin, handle: handle, requestBody: requestBody, started: started)
}

private func cancelServiceRequest(
    _ fixture: CancelServiceFixture, commandID: String,
    attachment: WorkServiceClientAttachment? = nil,
    client: ClientRef? = nil, handle: HandleRef? = nil,
    cursor: JournalCursor? = nil
) -> WorkServiceAgentHandleCancelRequest {
    let caller = attachment ?? fixture.secondaryAttachment
    return WorkServiceAgentHandleCancelRequest(
        work: fixture.work, journal: fixture.journal,
        attachment: caller.attachment, handle: handle ?? fixture.handle,
        commandID: commandID, client: client ?? fixture.creator,
        sessionAttachment: caller.sessionAttachment!,
        causalWorkCursor: cursor ?? fixture.started.cursor)
}

private func closeCancelServiceFixture(_ fixture: CancelServiceFixture) async {
    try? await fixture.bundle.closeChecked()
    await fixture.service.controlJournal.close()
    try? FileManager.default.removeItem(at: fixture.home.root)
}

func testWorkAgentHandleCancelAllowsSecondSessionAndColdDuplicate() async throws {
    let fixture = try await makeCancelServiceFixture(suffix: "second-session")
    let request = cancelServiceRequest(fixture, commandID: "cancel-shared-id")
    let accepted = try await fixture.service.cancelAgentHandle(request)
    XCTAssertEqual(accepted.disposition, .accepted)
    XCTAssertEqual(accepted.cancellationEvidence?.command?.sessionAttachment,
                   fixture.secondaryAttachment.sessionAttachment)
    XCTAssertEqual(accepted.cancellationEvidence?.event.sessionAttachment,
                   fixture.origin.sessionAttachment)
    XCTAssertNotEqual(fixture.secondaryAttachment.sessionAttachment,
                      fixture.origin.sessionAttachment)
    let acceptedCalls = await fixture.canceller.callCount
    XCTAssertEqual(acceptedCalls, 1)

    let duplicate = try await fixture.service.cancelAgentHandle(request)
    XCTAssertEqual(duplicate.disposition, .duplicate)
    XCTAssertEqual(duplicate.resultingWorkCursor, accepted.resultingWorkCursor)
    let duplicateCalls = await fixture.canceller.callCount
    XCTAssertEqual(duplicateCalls, 1)

    let conflictingHandle = try await fixture.service.cancelAgentHandle(
        cancelServiceRequest(
            fixture, commandID: request.command.commandID,
            handle: HandleRef("another-handle")))
    XCTAssertEqual(conflictingHandle.disposition, .rejected)
    XCTAssertEqual(conflictingHandle.rejection, .conflictingCommand)

    let latest = try XCTUnwrap(accepted.resultingWorkCursor)
    let runCommand = WorkServiceCommandRequest(
        work: fixture.work, journal: fixture.journal,
        attachment: fixture.primaryAttachment.attachment,
        commandID: request.command.commandID, client: fixture.creator,
        sessionAttachment: fixture.primaryAttachment.sessionAttachment,
        causalWorkCursor: latest, kind: .cancel)
    let runConflict = try await fixture.service.command(runCommand)
    XCTAssertEqual(runConflict.state, .rejected)
    XCTAssertEqual(runConflict.rejection, .conflictingCommand)
    await closeCancelServiceFixture(fixture)
}

func testWorkAgentHandleCancelRequiresControlAndCancelCapabilities() async throws {
    for (suffix, capabilities, missing) in [
        ("missing-cancel", Set([WorkServiceCapability.observe, .control]),
         WorkServiceCapability.cancel),
        ("missing-control", Set([WorkServiceCapability.observe, .cancel]),
         WorkServiceCapability.control),
    ] {
        let fixture = try await makeCancelServiceFixture(
            suffix: suffix, secondaryCapabilities: capabilities)
        do {
            _ = try await fixture.service.cancelAgentHandle(
                cancelServiceRequest(fixture, commandID: "unauthorized-\(suffix)"))
            XCTFail("missing \(missing) must refuse the cancellation")
        } catch WorkServiceProtocolError.capabilityDenied(let denied) {
            XCTAssertEqual(denied, missing)
        }
        let calls = await fixture.canceller.callCount
        XCTAssertEqual(calls, 0)
        await closeCancelServiceFixture(fixture)
    }
}

func testWorkAgentHandleCancelConcurrentDuplicateHasOneEffect() async throws {
    let fixture = try await makeCancelServiceFixture(suffix: "concurrent")
    let request = cancelServiceRequest(fixture, commandID: "concurrent-cancel")
    async let first = fixture.service.cancelAgentHandle(request)
    async let second = fixture.service.cancelAgentHandle(request)
    let (firstResponse, secondResponse) = try await (first, second)
    let responses = [firstResponse, secondResponse]
    XCTAssertEqual(Set(responses.map(\.disposition)), Set([.accepted, .duplicate]))
    XCTAssertEqual(Set(responses.compactMap(\.resultingWorkCursor)).count, 1)
    let durable = TimelineJournalReader.read(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work)),
        journal: fixture.journal,
        actor: TimelineActor(actorID: "cancel-concurrent-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(durable.records.filter {
        $0.event.type == TimelineEventType.agentHandleCancelRequested
            && $0.event.command?.commandID == WorkServiceCommandLedgerIdentity.commandID(
                client: fixture.creator, commandID: request.command.commandID)
    }.count, 1)
    let calls = await fixture.canceller.callCount
    XCTAssertEqual(calls, 1)
    await closeCancelServiceFixture(fixture)
}

func testWorkAgentHandleCancelRejectsPostEffectCommandAttachmentConflict() async throws {
    let fixture = try await makeCancelServiceFixture(suffix: "attachment-conflict")
    await fixture.canceller.setMode(.commitWithSessionAttachment(
        fixture.primaryAttachment.sessionAttachment!, .accepted))
    let response = try await fixture.service.cancelAgentHandle(cancelServiceRequest(
        fixture, commandID: "attachment-conflict"))
    XCTAssertEqual(response.disposition, .rejected)
    XCTAssertEqual(response.rejection, .conflictingCommand)
    XCTAssertNil(response.cancellationEvidence)
    let cancellationCommit = await fixture.canceller.cancellationCommit
    let commit = try XCTUnwrap(cancellationCommit)
    let durable = TimelineJournalReader.read(
        try Data(contentsOf: fixture.home.timelineV2WorkJournalURL(fixture.work)),
        journal: fixture.journal,
        actor: TimelineActor(actorID: "attachment-conflict-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    let event = try XCTUnwrap(durable.records.first {
        $0.event.eventID == commit.eventRef.eventID
    }?.event)
    XCTAssertEqual(event.command?.sessionAttachment,
                   fixture.primaryAttachment.sessionAttachment)
    XCTAssertNotEqual(event.command?.sessionAttachment,
                      fixture.secondaryAttachment.sessionAttachment)
    await closeCancelServiceFixture(fixture)
}

func testWorkAgentHandleCancelCommandIdentityIsClientQualified() async throws {
    let fixture = try await makeCancelServiceFixture(suffix: "client-qualified")
    let externalID = "shared-external-cancel-id"
    let creatorRequest = cancelServiceRequest(fixture, commandID: externalID)
    let accepted = try await fixture.service.cancelAgentHandle(creatorRequest)
    XCTAssertEqual(accepted.disposition, .accepted)

    let otherRequest = cancelServiceRequest(
        fixture, commandID: externalID, attachment: fixture.otherClientAttachment,
        client: fixture.otherClient)
    let observed = try await fixture.service.cancelAgentHandle(otherRequest)
    XCTAssertEqual(observed.disposition, .alreadyRequested)
    XCTAssertNil(observed.rejection)
    let firstCanonicalID = try XCTUnwrap(accepted.cancellationEvidence?.command?.commandID)
    XCTAssertEqual(firstCanonicalID, WorkServiceCommandLedgerIdentity.commandID(
        client: fixture.creator, commandID: externalID))
    XCTAssertNotEqual(firstCanonicalID, WorkServiceCommandLedgerIdentity.commandID(
        client: fixture.otherClient, commandID: externalID))
    await closeCancelServiceFixture(fixture)
}

func testWorkAgentHandleCancelReconcilesAmbiguousProofWithoutReplay() async throws {
    let committed = try await makeCancelServiceFixture(
        suffix: "ambiguous-committed", cancellerMode: .commit(.ambiguous))
    let committedResponse = try await committed.service.cancelAgentHandle(
        cancelServiceRequest(committed, commandID: "ambiguous-committed"))
    XCTAssertEqual(committedResponse.disposition, .accepted)
    XCTAssertNotNil(committedResponse.cancellationEvidence)
    let committedCalls = await committed.canceller.callCount
    XCTAssertEqual(committedCalls, 1)
    await closeCancelServiceFixture(committed)

    let absent = try await makeCancelServiceFixture(
        suffix: "ambiguous-absent", cancellerMode: .noWrite)
    let absentResponse = try await absent.service.cancelAgentHandle(
        cancelServiceRequest(absent, commandID: "ambiguous-absent"))
    XCTAssertEqual(absentResponse.disposition, .ambiguous)
    XCTAssertNil(absentResponse.resultingWorkCursor)
    XCTAssertNil(absentResponse.cancellationEvidence)
    let absentCalls = await absent.canceller.callCount
    XCTAssertEqual(absentCalls, 1)
    await closeCancelServiceFixture(absent)
}

func testWorkAgentHandleCancelEvidenceSurvivesTerminalReapAndColdService() async throws {
    let fixture = try await makeCancelServiceFixture(suffix: "cold-terminal")
    let request = cancelServiceRequest(fixture, commandID: "cold-terminal-cancel")
    let accepted = try await fixture.service.cancelAgentHandle(request)
    let cancellation = try XCTUnwrap(accepted.cancellationEvidence)
    let terminal = try await fixture.route.append(cancelServiceDraft(
        TimelineEventType.agentHandleTerminal, origin: fixture.origin, handle: fixture.handle,
        cause: cancellation.event.event,
        payload: try cancelServiceJSON(WorkAgentHandleTerminalPayload(
            outcome: .canceled, cleanup: .init(state: .quiesced)))))
    _ = try await fixture.route.append(cancelServiceDraft(
        TimelineEventType.agentHandleReaped, origin: fixture.origin, handle: fixture.handle,
        cause: terminal.eventRef,
        payload: try cancelServiceJSON(
            WorkAgentHandleReapedPayload(reason: .explicitPolicy))))

    let duplicate = try await fixture.service.cancelAgentHandle(request)
    XCTAssertEqual(duplicate.disposition, .duplicate)
    XCTAssertEqual(duplicate.cancellationEvidence, accepted.cancellationEvidence)
    XCTAssertEqual(duplicate.terminalEvidence?.outcome, .canceled)
    let terminalObservation = try await fixture.service.cancelAgentHandle(
        cancelServiceRequest(fixture, commandID: "observe-terminal"))
    XCTAssertEqual(terminalObservation.disposition, .alreadyTerminal)
    XCTAssertEqual(terminalObservation.cancellationEvidence, accepted.cancellationEvidence)
    XCTAssertEqual(terminalObservation.terminalEvidence, duplicate.terminalEvidence)

    await fixture.service.controlJournal.close()
    let cold = try JournalBackedWorkService(
        home: fixture.home,
        authorizer: WorkServiceCapabilityPolicy(grantsByClient: [
            fixture.creator: Set(WorkServiceCapability.allCases),
        ]), manifestStore: JournalBackedTestManifestStore())
    let coldDuplicate = try await cold.cancelAgentHandle(request)
    XCTAssertEqual(coldDuplicate.disposition, .duplicate)
    XCTAssertEqual(coldDuplicate.cancellationEvidence, accepted.cancellationEvidence)
    XCTAssertEqual(coldDuplicate.terminalEvidence, duplicate.terminalEvidence)
    await cold.controlJournal.close()
    try? await fixture.bundle.closeChecked()
    try? FileManager.default.removeItem(at: fixture.home.root)
}

func testWorkAgentHandleBodiesUseExistingAuthorizedBodyTransport() async throws {
    let fixture = try await makeCancelServiceFixture(suffix: "body-read")
    let requestChunk = try await fixture.service.fetchBody(WorkServiceBodyRequest(
        work: fixture.work, journal: fixture.journal,
        attachment: fixture.secondaryAttachment.attachment, client: fixture.creator,
        reference: fixture.requestBody, offset: 0, limit: 4))
    XCTAssertEqual(requestChunk.status, .retained)
    XCTAssertEqual(requestChunk.data, Data("priv".utf8))
    XCTAssertNotNil(requestChunk.nextOffset)

    let cancel = try await fixture.service.cancelAgentHandle(
        cancelServiceRequest(fixture, commandID: "body-cancel"))
    let resultBody = try ContextBodyStore(home: fixture.home).retain(
        Data("private result".utf8), authority: fixture.journal, mediaType: "text/plain")
    _ = try await fixture.route.append(cancelServiceDraft(
        TimelineEventType.agentHandleTerminal, origin: fixture.origin, handle: fixture.handle,
        cause: try XCTUnwrap(cancel.cancellationEvidence?.event.event),
        payload: try cancelServiceJSON(WorkAgentHandleTerminalPayload(
            outcome: .canceled, resultBody: resultBody,
            cleanup: .init(state: .quiesced)))))
    let result = try await fixture.service.fetchBody(WorkServiceBodyRequest(
        work: fixture.work, journal: fixture.journal,
        attachment: fixture.secondaryAttachment.attachment, client: fixture.creator,
        reference: resultBody, offset: 0, limit: WorkServiceBounds.maxBodyChunkBytes))
    XCTAssertEqual(result.status, .retained)
    XCTAssertEqual(result.data, Data("private result".utf8))
    XCTAssertNil(result.nextOffset)
    await closeCancelServiceFixture(fixture)
}

func testWorkAgentHandleBodyClassifierRefusesUnrelatedNestedReference() async throws {
    let fixture = try await makeCancelServiceFixture(suffix: "nested-body")
    let unrelated = try ContextBodyStore(home: fixture.home).retain(
        Data("unrelated nested body".utf8), authority: fixture.journal,
        mediaType: "text/plain")
    let writer = try TimelineJournalWriter(
        reopening: fixture.home.timelineV2WorkJournalURL(fixture.work),
        journal: fixture.journal,
        actor: TimelineActor(actorID: "nested-body-writer", kind: "self-test"),
        home: fixture.home)
    _ = try await writer.append(TimelineEventDraft(
        work: fixture.work, workHost: WorkHostRef(fixture.work.workHostID),
        type: TimelineEventType.modelChanged, declaredDomains: [.work], payload: .object([
            "model_id": .string("nested-body-model"),
            "metadata": .object([
                "body_reference": try XCTUnwrap(
                    JSONValue.parse(JSONEncoder().encode(unrelated))),
            ]),
        ])))
    try await writer.closeChecked()
    let canonical = try await fixture.route.read()
    XCTAssertTrue(canonical.coverage.isControlling)
    do {
        _ = try await fixture.service.fetchBody(WorkServiceBodyRequest(
            work: fixture.work, journal: fixture.journal,
            attachment: fixture.secondaryAttachment.attachment, client: fixture.creator,
            reference: unrelated))
        XCTFail("an unrelated nested body reference must not become a fetch capability")
    } catch WorkServiceProtocolError.sourceIncomplete {
        XCTAssertTrue(true)
    }
    await closeCancelServiceFixture(fixture)
}

let casesWorkAgentHandleCancelService: [Case] = [
    ("phase5 Handle cancel: second Session authority and cold duplicate", {
        try await testWorkAgentHandleCancelAllowsSecondSessionAndColdDuplicate()
    }),
    ("phase5 Handle cancel: requires control and cancel", {
        try await testWorkAgentHandleCancelRequiresControlAndCancelCapabilities()
    }),
    ("phase5 Handle cancel: concurrent duplicate has one append", {
        try await testWorkAgentHandleCancelConcurrentDuplicateHasOneEffect()
    }),
    ("phase5 Handle cancel: post-effect attachment conflict", {
        try await testWorkAgentHandleCancelRejectsPostEffectCommandAttachmentConflict()
    }),
    ("phase5 Handle cancel: command identity is client-qualified", {
        try await testWorkAgentHandleCancelCommandIdentityIsClientQualified()
    }),
    ("phase5 Handle cancel: ambiguity reconciles only from canonical proof", {
        try await testWorkAgentHandleCancelReconcilesAmbiguousProofWithoutReplay()
    }),
    ("phase5 Handle cancel: terminal and reap preserve cold proof", {
        try await testWorkAgentHandleCancelEvidenceSurvivesTerminalReapAndColdService()
    }),
    ("phase5 Handle cancel: child bodies reuse authorized body chunks", {
        try await testWorkAgentHandleBodiesUseExistingAuthorizedBodyTransport()
    }),
    ("phase5 Handle cancel: unrelated nested body reference is refused", {
        try await testWorkAgentHandleBodyClassifierRefusesUnrelatedNestedReference()
    }),
]
