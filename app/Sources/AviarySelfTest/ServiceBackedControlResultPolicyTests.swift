import AviaryCore
import Foundation

private let controlResultWork = WorkRef(
    workHostID: "control-result-host", workID: "control-result-work")
private let controlResultJournal = JournalRef.work(controlResultWork)
private let controlResultSession = SessionRef("control-result-session")
private let controlResultSessionJournal = JournalRef.session(
    controlResultSession, journalID: "control-result-session-journal",
    authority: TimelineAuthorityRef(controlResultWork.workHostID))
private let controlResultSessionAttachment = SessionAttachmentRef(
    "control-result-session-attachment")
private let controlResultClient = ClientRef("control-result-client")
private let controlResultClientAttachment = ClientAttachmentRef(
    "control-result-client-attachment")
private let controlResultRun = RunRef("control-result-run")

private struct ControlResultCommandFixture {
    let id: String
    let kind: CanonicalCommandKind?
    let state: CommandDeliveryState
    let client: ClientRef?
    let sessionAttachment: SessionAttachmentRef?
    let run: RunRef?
    let acceptanceSequence: Int
    let acceptanceHostSequence: Int
    let deliverySequence: Int?
    var acceptanceJournal = controlResultJournal
    var deliveryJournal = controlResultJournal
}

private func controlResultCommand(
    _ id: String, kind: CanonicalCommandKind, state: CommandDeliveryState = .delivered,
    client: ClientRef = controlResultClient,
    sessionAttachment: SessionAttachmentRef = controlResultSessionAttachment,
    run: RunRef? = controlResultRun,
    acceptanceSequence: Int, acceptanceHostSequence: Int? = nil,
    deliverySequence: Int? = nil
) -> ControlResultCommandFixture {
    ControlResultCommandFixture(
        id: id, kind: kind, state: state, client: client,
        sessionAttachment: sessionAttachment, run: run,
        acceptanceSequence: acceptanceSequence,
        acceptanceHostSequence: acceptanceHostSequence ?? acceptanceSequence,
        deliverySequence: deliverySequence ?? (state == .delivered
            ? acceptanceSequence + 1 : nil))
}

private func controlResultProjection(
    commands: [ControlResultCommandFixture],
    execution: WorkServiceExecutionState = .idle,
    currentRun: RunRef? = controlResultRun,
    activeTurn: TurnRef? = nil,
    hasActiveAction: Bool = false,
    canonical: Bool = true,
    pending: Bool = false,
    duplicateClientRelationship: Bool = false
) throws -> WorkServiceAttachedWorkProjection {
    let workCursor = JournalCursor(
        journal: controlResultJournal, eventID: "control-result-tip", sequence: 100)
    let sessionCursor = JournalCursor(
        journal: controlResultSessionJournal,
        eventID: "control-result-session-tip", sequence: 10)
    let authorization = WorkServiceAuthorizationOutcome(
        requested: Set(WorkServiceCapability.allCases),
        granted: Set(WorkServiceCapability.allCases), denied: [])
    let attachment = WorkServiceClientAttachment(
        attachment: controlResultClientAttachment, client: controlResultClient,
        session: controlResultSession, sessionJournal: controlResultSessionJournal,
        sessionAttachment: controlResultSessionAttachment,
        authorization: authorization)
    var descriptorAttachments = [attachment]
    if duplicateClientRelationship {
        descriptorAttachments.append(WorkServiceClientAttachment(
            attachment: ClientAttachmentRef("control-result-duplicate-attachment"),
            client: controlResultClient, session: controlResultSession,
            sessionJournal: controlResultSessionJournal,
            sessionAttachment: controlResultSessionAttachment,
            authorization: authorization))
    }
    let relationship = WorkServiceSessionAttachmentDescriptor(
        session: controlResultSession, sessionJournal: controlResultSessionJournal,
        sessionAttachment: controlResultSessionAttachment, publication: .mirrored,
        causalSessionCursor: sessionCursor, sessionCursor: sessionCursor,
        causalWorkCursor: workCursor, resultingWorkCursor: workCursor,
        capabilities: Set(WorkServiceCapability.allCases))
    let observation = try WorkServiceHostObservation(
        instance: WorkHostInstanceRef(
            host: WorkHostRef(controlResultWork.workHostID),
            instanceID: "control-result-instance", startIdentity: "control-result-start"),
        reachability: .observedReachable,
        currentRun: currentRun,
        currentRunSession: currentRun == nil ? nil : controlResultSession,
        currentRunSessionAttachment: currentRun == nil ? nil : controlResultSessionAttachment,
        servedCursor: workCursor,
        sourceCompleteness: canonical ? .complete : .incomplete)
    let descriptor = try WorkServiceWorkDescriptor(
        work: controlResultWork, journal: controlResultJournal,
        recordedDisposition: .reusable, execution: execution,
        currentRun: currentRun,
        currentRunSession: currentRun == nil ? nil : controlResultSession,
        currentRunSessionAttachment: currentRun == nil ? nil : controlResultSessionAttachment,
        hostObservation: observation, attachments: descriptorAttachments,
        sessionAttachments: [relationship])

    var work = WorkSnapshot()
    work.journal = controlResultJournal
    work.work = controlResultWork
    work.workHost = WorkHostRef(controlResultWork.workHostID)
    work.lifecycle = .active
    work.execution = execution == .idle ? .idle : .running
    work.activeRun = currentRun
    work.activeRunSession = currentRun == nil ? nil : controlResultSession
    work.activeRunSessionAttachment = currentRun == nil ? nil : controlResultSessionAttachment
    work.activeTurn = activeTurn
    if hasActiveAction { work.activeActionIDs.insert("control-result-action") }
    work.eventSequences["control-result-tip"] = workCursor.sequence
    for fixture in commands {
        let acceptanceID = "\(fixture.id)-accepted"
        let deliveryID = "\(fixture.id)-delivered"
        work.eventSequences[acceptanceID] = fixture.acceptanceSequence
        if let deliverySequence = fixture.deliverySequence {
            work.eventSequences[deliveryID] = deliverySequence
        }
        work.commands[fixture.id] = WorkCommandSnapshot(
            command: CommandRef(
                commandID: fixture.id, client: fixture.client,
                sessionAttachment: fixture.sessionAttachment,
                causalCursor: JournalCursor(journal: controlResultJournal, sequence: 0)),
            state: fixture.state,
            acceptanceActor: TimelineActor(actorID: "control-result-host", kind: "work-host"),
            acceptanceHostSequence: fixture.acceptanceHostSequence,
            acceptanceEventRef: EventRef(
                journal: fixture.acceptanceJournal, eventID: acceptanceID),
            deliveryEventRef: fixture.deliverySequence == nil ? nil : EventRef(
                journal: fixture.deliveryJournal, eventID: deliveryID),
            deliveryActor: fixture.deliverySequence == nil ? nil
                : TimelineActor(actorID: "control-result-host", kind: "work-host"),
            deliveryHostSequence: fixture.deliverySequence,
            commandKind: fixture.kind, acceptanceRun: fixture.run,
            carriesSessionInput: fixture.kind == .send || fixture.kind == .start)
    }

    var session = SessionSnapshot()
    session.journal = controlResultSessionJournal
    session.session = controlResultSession
    session.lifecycle = .active
    let pendingCommand = pending ? WorkServiceAttachedWorkPendingCommand(
        state: .awaitingCanonicalEvidence, kind: .send,
        commandID: "control-result-pending", client: controlResultClient,
        attachment: controlResultClientAttachment,
        sessionAttachment: controlResultSessionAttachment,
        causalWorkCursor: workCursor, valueDigest: nil) : nil
    return WorkServiceAttachedWorkProjection(
        descriptor: descriptor, attachment: attachment,
        capabilities: Set(WorkServiceCapability.allCases),
        workSnapshot: work, sessionSnapshot: session,
        workCursor: workCursor, sessionCursor: sessionCursor,
        workSourceCompleteness: canonical ? .complete : .incomplete,
        sessionSourceCompleteness: .complete,
        connectivity: .connected(observation.instance), pendingCommand: pendingCommand,
        requiresRefresh: !canonical)
}

let casesServiceBackedControlResultPolicy: [Case] = [
    ("service control result presents an exact delivered Stop after settlement", {
        let projection = try controlResultProjection(commands: [
            // Host order may restart with a new Run; journal sequence remains authoritative.
            controlResultCommand(
                "earlier-send", kind: .send, acceptanceSequence: 10,
                acceptanceHostSequence: 90),
            controlResultCommand(
                "latest-cancel", kind: .cancel, acceptanceSequence: 20,
                acceptanceHostSequence: 1),
        ])
        XCTAssertEqual(
            ServiceBackedControlResultPolicy.latestResult(in: projection),
            .stopRequestDelivered)
    }),
    ("service control result withholds unsettled or incomplete evidence", {
        let delivered = controlResultCommand(
            "cancel", kind: .cancel, acceptanceSequence: 20)
        let variants = try [
            controlResultProjection(commands: [delivered], execution: .running),
            controlResultProjection(
                commands: [delivered], activeTurn: TurnRef("still-active")),
            controlResultProjection(commands: [delivered], hasActiveAction: true),
            controlResultProjection(commands: [delivered], canonical: false),
            controlResultProjection(commands: [delivered], pending: true),
            controlResultProjection(
                commands: [delivered], duplicateClientRelationship: true),
        ]
        for projection in variants {
            XCTAssertNil(ServiceBackedControlResultPolicy.latestResult(in: projection))
        }
    }),
    ("service control result requires delivered evidence for the current Run", {
        let variants = try [
            controlResultProjection(commands: [controlResultCommand(
                "accepted", kind: .cancel, state: .accepted,
                acceptanceSequence: 20, deliverySequence: nil)]),
            controlResultProjection(commands: [controlResultCommand(
                "old-run", kind: .cancel, run: RunRef("old-run"),
                acceptanceSequence: 20)]),
        ]
        for projection in variants {
            XCTAssertNil(ServiceBackedControlResultPolicy.latestResult(in: projection))
        }
    }),
    ("service control result is suppressed by every later owner command", {
        for (index, kind) in CanonicalCommandKind.allCases.enumerated() {
            let projection = try controlResultProjection(commands: [
                controlResultCommand("cancel", kind: .cancel, acceptanceSequence: 20),
                controlResultCommand(
                    "later-\(kind.rawValue)", kind: kind, state: .accepted,
                    client: ClientRef("other-client-\(index)"),
                    acceptanceSequence: 30, deliverySequence: nil),
            ])
            XCTAssertNil(
                ServiceBackedControlResultPolicy.latestResult(in: projection),
                "later \(kind.rawValue) must supersede Stop presentation")
        }
    }),
    ("service control result ignores commands for another Session relationship", {
        let projection = try controlResultProjection(commands: [
            controlResultCommand("cancel", kind: .cancel, acceptanceSequence: 20),
            controlResultCommand(
                "foreign-send", kind: .send,
                sessionAttachment: SessionAttachmentRef("foreign-session-attachment"),
                acceptanceSequence: 30),
        ])
        XCTAssertEqual(
            ServiceBackedControlResultPolicy.latestResult(in: projection),
            .stopRequestDelivered)
    }),
    ("service control result rejects foreign and ambiguous journal evidence", {
        var foreignAcceptance = controlResultCommand(
            "foreign-acceptance", kind: .cancel, acceptanceSequence: 20)
        foreignAcceptance.acceptanceJournal = controlResultSessionJournal
        var foreignDelivery = controlResultCommand(
            "foreign-delivery", kind: .cancel, acceptanceSequence: 20)
        foreignDelivery.deliveryJournal = controlResultSessionJournal
        let variants = try [
            controlResultProjection(commands: [foreignAcceptance]),
            controlResultProjection(commands: [foreignDelivery]),
            controlResultProjection(commands: [controlResultCommand(
                "future-delivery", kind: .cancel, acceptanceSequence: 20,
                deliverySequence: 101)]),
            controlResultProjection(commands: [
                controlResultCommand("first", kind: .cancel, acceptanceSequence: 20),
                controlResultCommand("tie", kind: .cancel, acceptanceSequence: 20),
            ]),
            controlResultProjection(commands: [controlResultCommand(
                "ended-run", kind: .cancel, acceptanceSequence: 20)], currentRun: nil),
        ]
        for projection in variants {
            XCTAssertNil(ServiceBackedControlResultPolicy.latestResult(in: projection))
        }
    }),
]
