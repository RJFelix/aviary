import Foundation
@testable import AviaryCore

private let creationTestHost = WorkHostRef("creation-test-host")
private let creationTestControlJournal = JournalRef.workHost(creationTestHost)
private let creationTestClient = ClientRef("creation-client")
private let creationTestWork = WorkRef(
    workHostID: creationTestHost.workHostID, workID: "work-created")
private let creationTestSession = SessionRef("session-created")
private let creationTestSessionAttachment = SessionAttachmentRef("session-attachment-created")
private let creationTestActor = TimelineActor(actorID: "creation-test", kind: "work-host")
private let creationTestBodyDigest = "sha256:" + String(repeating: "a", count: 64)
private let creationTestConfigurationDigest = "sha256:" + String(repeating: "b", count: 64)

private final class CreationIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [WorkHostControlMintedIdentity]
    private var index = 0

    init(_ values: [WorkHostControlMintedIdentity]) {
        self.values = values
    }

    func next() -> WorkHostControlMintedIdentity {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

private func creationTestJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

private func creationTestAppendEvent(_ event: TimelineEvent, to url: URL) throws {
    var data = try Data(contentsOf: url)
    var line = try JSONEncoder().encode(event)
    line.append(0x0A)
    data.append(line)
    try data.write(to: url, options: .atomic)
}

private func creationTestWorkJournal(_ id: String = "work-journal") -> JournalRef {
    JournalRef.work(creationTestWork, journalID: id)
}

private func creationTestSessionJournal(
    _ id: String = "session-journal",
    authority: TimelineAuthorityRef = TimelineAuthorityRef(creationTestHost.workHostID)
) -> JournalRef {
    JournalRef.session(
        creationTestSession, journalID: id, authority: authority)
}

private func creationTestCommand(
    id: String = "create-1",
    bodyDigest: String = creationTestBodyDigest,
    configurationDigest: String = creationTestConfigurationDigest,
    cursor: JournalCursor = JournalCursor(
        journal: creationTestControlJournal, eventID: nil, sequence: 0)
) -> WorkHostControlCreationRequest {
    WorkHostControlCreationRequest(
        client: creationTestClient, commandID: id, bodyDigest: bodyDigest,
        configurationDigest: configurationDigest, causalControlCursor: cursor)
}

private func creationTestReservationEvent(
    request: WorkHostControlCreationRequest = creationTestCommand(),
    eventID: String = "reserve-1",
    sequence: Int = 1,
    previousEventID: String? = nil,
    work: WorkRef = creationTestWork,
    session: SessionRef = creationTestSession,
    sessionAttachment: SessionAttachmentRef = creationTestSessionAttachment
) -> TimelineEvent {
    TimelineEvent(
        eventID: eventID, journal: creationTestControlJournal, sequence: sequence,
        command: request.command, previousEventID: previousEventID,
        session: session, work: work, workHost: creationTestHost, client: request.client,
        sessionAttachment: sessionAttachment, actor: creationTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: WorkHostControlEventType.creationReserved,
        declaredDomains: [.work, .session], payload: .object([
            "body_digest": .string(request.bodyDigest),
            "configuration_digest": .string(request.configurationDigest),
        ]))
}

private func creationTestRegistrationEvent(
    reservationEvent: TimelineEvent,
    workJournal: JournalRef = creationTestWorkJournal(),
    sessionJournal: JournalRef = creationTestSessionJournal(),
    workGenesisCursor: JournalCursor? = nil,
    sessionGenesisCursor: JournalCursor? = nil,
    causalControlCursor: JournalCursor? = nil,
    previousEventID: String? = nil,
    eventID: String = "register-1",
    sequence: Int = 2
) -> TimelineEvent {
    let workCursor = workGenesisCursor ?? JournalCursor(
        journal: workJournal, eventID: "work-genesis", sequence: 1)
    let sessionCursor = sessionGenesisCursor ?? JournalCursor(
        journal: sessionJournal, eventID: "session-genesis", sequence: 1)
    let causal = causalControlCursor ?? JournalCursor(
        journal: creationTestControlJournal,
        eventID: reservationEvent.eventID, sequence: reservationEvent.sequence)
    return TimelineEvent(
        eventID: eventID, journal: creationTestControlJournal, sequence: sequence,
        command: reservationEvent.command,
        previousEventID: previousEventID ?? reservationEvent.eventID,
        causedByEventID: EventRef(
            journal: creationTestControlJournal, eventID: reservationEvent.eventID),
        session: creationTestSession, work: creationTestWork, workHost: creationTestHost,
        client: creationTestClient, sessionAttachment: creationTestSessionAttachment,
        actor: creationTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: WorkHostControlEventType.workRegistered,
        declaredDomains: [.work, .session], payload: .object([
            "work_journal": creationTestJSON(workJournal),
            "session_journal": creationTestJSON(sessionJournal),
            "work_genesis_cursor": creationTestJSON(workCursor),
            "session_genesis_cursor": creationTestJSON(sessionCursor),
            "causal_control_cursor": creationTestJSON(causal),
            "reservation_event": creationTestJSON(EventRef(
                journal: creationTestControlJournal, eventID: reservationEvent.eventID)),
            "body_digest": reservationEvent.payload["body_digest"] ?? .null,
            "configuration_digest": reservationEvent.payload["configuration_digest"] ?? .null,
        ]))
}

func test_workHostControlCreationReducerProjectsExplicitCrashStates() throws {
    let request = creationTestCommand()
    let reservation = creationTestReservationEvent(request: request)
    let reserved = WorkHostControlReducer.reduce([reservation])
    let reservedRecord = try XCTUnwrap(
        reserved.creation(client: creationTestClient, commandID: request.command.commandID))
    XCTAssertEqual(reservedRecord.reservation.work, creationTestWork)
    XCTAssertEqual(reservedRecord.reservation.session, creationTestSession)
    XCTAssertEqual(
        reserved.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .none)?.state,
        .reservationOnly)
    XCTAssertEqual(
        reserved.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .workOnly)?.state,
        .sourceIncomplete)
    XCTAssertEqual(
        reserved.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .sessionOnly)?.state,
        .sourceIncomplete)
    XCTAssertEqual(
        reserved.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .both)?.state,
        .journalsUnregistered)
    XCTAssertEqual(
        reserved.creationProjection(
            client: creationTestClient, commandID: request.command.commandID)?.state,
        .recoveryRequired)

    let registered = WorkHostControlReducer.reduce([
        reservation, creationTestRegistrationEvent(reservationEvent: reservation),
    ])
    let fabricatedProjection = try XCTUnwrap(
        registered.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .both))
    XCTAssertEqual(fabricatedProjection.state, .recoveryRequired)
    XCTAssertFalse(fabricatedProjection.responseIsReconstructable)
    XCTAssertNotNil(fabricatedProjection.registration)
    XCTAssertEqual(
        registered.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .none)?.state,
        .recoveryRequired)
    XCTAssertFalse(
        registered.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .none)?.responseIsReconstructable == true)
    XCTAssertEqual(
        registered.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .notObserved)?.state,
        .recoveryRequired)
    XCTAssertEqual(
        registered.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .unverified)?.state,
        .recoveryRequired)
    XCTAssertFalse(
        registered.creationProjection(
            client: creationTestClient, commandID: request.command.commandID,
            sourcePresence: .unverified)?.responseIsReconstructable == true)
}

func test_workHostControlCreationReducerQuarantinesChangedRegistrationEvidence() throws {
    let reservation = creationTestReservationEvent()
    let registration = creationTestRegistrationEvent(reservationEvent: reservation)
    let changedWorkJournal = creationTestWorkJournal("replacement-generation")
    let conflicting = creationTestRegistrationEvent(
        reservationEvent: reservation, workJournal: changedWorkJournal,
        causalControlCursor: JournalCursor(
            journal: creationTestControlJournal, eventID: "register-1", sequence: 2),
        previousEventID: "register-1",
        eventID: "register-2", sequence: 3)
    let snapshot = WorkHostControlReducer.reduce([reservation, registration, conflicting])
    let creation = try XCTUnwrap(
        snapshot.creation(client: creationTestClient, commandID: "create-1"))
    XCTAssertTrue(creation.isConflicted)
    XCTAssertEqual(creation.conflictEventRefs.count, 1)
    XCTAssertFalse(snapshot.semanticProjectionValid)
    XCTAssertTrue(snapshot.corruptionReasons.contains {
        $0.contains("registration conflicts")
    })
    let conflictedProjection = try XCTUnwrap(snapshot.creationProjection(
        client: creationTestClient, commandID: "create-1", sourcePresence: .both))
    XCTAssertEqual(conflictedProjection.state, .conflicted)
    XCTAssertFalse(conflictedProjection.responseIsReconstructable)
}

func test_workHostControlCreationJournalReconcilesReservationAndRegistration() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-creation-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: creationTestHost, actor: creationTestActor,
        eventIDProvider: {
            "creation-event-\(UUID().uuidString.lowercased())"
        })
    let request = WorkHostControlCreationRequest(
        client: creationTestClient, commandID: "create-1",
        bodyDigest: creationTestBodyDigest,
        configurationDigest: creationTestConfigurationDigest,
        causalControlCursor: JournalCursor(
            journal: creationTestControlJournal, eventID: nil, sequence: 0))
    let reservation = try await journal.reserveCreation(request)
    XCTAssertEqual(reservation.client, creationTestClient)
    XCTAssertEqual(reservation.work.workHostID, creationTestHost.workHostID)
    XCTAssertNotEqual(reservation.work.workID, "")
    XCTAssertNotEqual(reservation.session.sessionID, "")
    XCTAssertNotEqual(reservation.sessionAttachment.attachmentID, "")
    let otherRequest = WorkHostControlCreationRequest(
        client: creationTestClient, commandID: "create-other",
        bodyDigest: creationTestBodyDigest,
        configurationDigest: creationTestConfigurationDigest,
        causalControlCursor: reservation.reservationCursor)
    let otherReservation = try await journal.reserveCreation(otherRequest)
    // The original response can be recovered even after another control mutation has advanced
    // the cursor: exact-command reconciliation precedes stale-cursor validation.
    let retry = try await journal.reserveCreation(request)
    XCTAssertEqual(retry, reservation)
    XCTAssertEqual(await journal.nextSequenceNumber, 3)

    let workJournal = JournalRef.work(reservation.work, journalID: "work-journal")
    let sessionJournal = JournalRef.session(
        reservation.session, journalID: "session-journal",
        authority: TimelineAuthorityRef(creationTestHost.workHostID))
    let registrationRequest = WorkHostControlWorkRegistrationRequest(
        reservation: reservation, workJournal: workJournal, sessionJournal: sessionJournal,
        workGenesisCursor: JournalCursor(
            journal: workJournal, eventID: "work-created", sequence: 1),
        sessionGenesisCursor: JournalCursor(
            journal: sessionJournal, eventID: "session-created", sequence: 1),
        causalControlCursor: otherReservation.reservationCursor)
    let registration = try await journal.registerWork(registrationRequest)
    XCTAssertEqual(registration.workJournal, workJournal)
    XCTAssertEqual(registration.sessionJournal, sessionJournal)
    XCTAssertEqual(await journal.nextSequenceNumber, 4)
    let registrationRetry = try await journal.registerWork(registrationRequest)
    XCTAssertEqual(registrationRetry, registration)
    XCTAssertEqual(await journal.nextSequenceNumber, 4)

    let projection = try await journal.snapshot().creationProjection(
        client: creationTestClient, commandID: "create-1", sourcePresence: .both)
    XCTAssertEqual(projection?.state, .recoveryRequired)
    XCTAssertFalse(projection?.responseIsReconstructable == true)
    XCTAssertEqual(projection?.registration?.workGenesisCursor.sequence, 1)
    try await journal.closeChecked()
}

func test_workHostControlCreationRejectsForeignSessionAuthorityAndUnverifiedSources() async throws {
    let reservationEvent = creationTestReservationEvent()
    let reservationSnapshot = WorkHostControlReducer.reduce([reservationEvent])
    let reservation = try XCTUnwrap(
        reservationSnapshot.creation(client: creationTestClient, commandID: "create-1")?.reservation)

    let foreignSessionJournal = creationTestSessionJournal(
        authority: TimelineAuthorityRef("foreign-session-authority"))
    let foreignRegistrationEvent = creationTestRegistrationEvent(
        reservationEvent: reservationEvent, sessionJournal: foreignSessionJournal)
    let foreignSnapshot = WorkHostControlReducer.reduce([
        reservationEvent, foreignRegistrationEvent,
    ])
    let foreignCreation = try XCTUnwrap(
        foreignSnapshot.creation(client: creationTestClient, commandID: "create-1"))
    XCTAssertNil(foreignCreation.registration)
    XCTAssertFalse(foreignSnapshot.semanticProjectionValid)
    XCTAssertTrue(foreignSnapshot.corruptionReasons.contains {
        $0.contains("registration journals are malformed")
    })

    let validRegistrationEvent = creationTestRegistrationEvent(
        reservationEvent: reservationEvent)
    let validSnapshot = WorkHostControlReducer.reduce([
        reservationEvent, validRegistrationEvent,
    ])
    let unobserved = try XCTUnwrap(validSnapshot.creationProjection(
        client: reservation.client, commandID: reservation.command.commandID))
    XCTAssertEqual(unobserved.state, .recoveryRequired)
    XCTAssertFalse(unobserved.responseIsReconstructable)
    XCTAssertEqual(validSnapshot.creationProjection(
        client: reservation.client, commandID: reservation.command.commandID,
        sourcePresence: .unverified)?.state, .recoveryRequired)
    XCTAssertFalse(validSnapshot.creationProjection(
        client: reservation.client, commandID: reservation.command.commandID,
        sourcePresence: .unverified)?.responseIsReconstructable == true)

    // The Work Host enforces the same authority rule at the mutation boundary. It intentionally
    // does not inspect AgentHome here: source existence/integrity belongs to the later composition
    // verifier, while this control actor records only bounded journal identities and cursors.
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-creation-source-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try WorkHostControlJournal.createFresh(
        home: AgentHome(root: root), workHost: creationTestHost, actor: creationTestActor)
    let empty = JournalCursor(journal: creationTestControlJournal, eventID: nil, sequence: 0)
    let actorReservation = try await journal.reserveCreation(creationTestCommand(cursor: empty))
    let workJournal = JournalRef.work(actorReservation.work, journalID: "actor-work-journal")
    let actorForeignSessionJournal = JournalRef.session(
        actorReservation.session, journalID: "actor-session-journal",
        authority: TimelineAuthorityRef("foreign-session-authority"))
    let foreignRequest = WorkHostControlWorkRegistrationRequest(
        reservation: actorReservation, workJournal: workJournal,
        sessionJournal: actorForeignSessionJournal,
        workGenesisCursor: JournalCursor(
            journal: workJournal, eventID: "work-genesis", sequence: 1),
        sessionGenesisCursor: JournalCursor(
            journal: actorForeignSessionJournal, eventID: "session-genesis", sequence: 1),
        causalControlCursor: actorReservation.reservationCursor)
    do {
        _ = try await journal.registerWork(foreignRequest)
        XCTFail("a Session journal under a foreign authority must be rejected")
    } catch {}
    XCTAssertEqual(await journal.nextSequenceNumber, 2)

    let validSessionJournal = JournalRef.session(
        actorReservation.session, journalID: "actor-session-journal",
        authority: TimelineAuthorityRef(creationTestHost.workHostID))
    let validRequest = WorkHostControlWorkRegistrationRequest(
        reservation: actorReservation, workJournal: workJournal,
        sessionJournal: validSessionJournal,
        workGenesisCursor: JournalCursor(
            journal: workJournal, eventID: "work-genesis", sequence: 1),
        sessionGenesisCursor: JournalCursor(
            journal: validSessionJournal, eventID: "session-genesis", sequence: 1),
        causalControlCursor: actorReservation.reservationCursor)
    _ = try await journal.registerWork(validRequest)
    let actorProjection = try await journal.snapshot().creationProjection(
        client: creationTestClient, commandID: "create-1")
    XCTAssertEqual(actorProjection?.state, .recoveryRequired)
    XCTAssertFalse(actorProjection?.responseIsReconstructable == true)
    try await journal.closeChecked()
}

func test_workHostControlCreationVerifierRequiresCanonicalMirroredSources() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-creation-verify-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let host = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef("verified-session"),
        work: WorkRef(workHostID: host.workHostID, workID: "verified-work"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("verified-attachment"))
    let idle = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "creation-verifier")
    let client = ClientRef("verified-client")
    let control = try WorkHostControlJournal.createFresh(
        home: home, workHost: host, actor: TimelineActor(actorID: "creation-control", kind: "work-host"),
        creationIdentityMinter: {
            WorkHostControlMintedIdentity(
                workID: binding.work.workID,
                sessionID: binding.session.sessionID,
                sessionAttachmentID: binding.sessionAttachment.attachmentID)
        })
    let empty = JournalCursor(journal: control.journal, eventID: nil, sequence: 0)
    let request = WorkHostControlCreationRequest(
        client: client, commandID: "create-1", bodyDigest: creationTestBodyDigest,
        configurationDigest: creationTestConfigurationDigest, causalControlCursor: empty)
    let reservation = try await control.reserveCreation(request)
    XCTAssertEqual(reservation.work, binding.work)
    XCTAssertEqual(reservation.session, binding.session)
    XCTAssertEqual(reservation.sessionAttachment, binding.sessionAttachment)
    let registrationRequest = WorkHostControlWorkRegistrationRequest(
        reservation: reservation, workJournal: idle.binding.workJournal,
        sessionJournal: idle.binding.sessionJournal,
        workGenesisCursor: idle.workCursor, sessionGenesisCursor: idle.sessionCursor,
        causalControlCursor: reservation.reservationCursor)
    _ = try await control.registerWork(registrationRequest)

    let snapshot = try await control.snapshot()
    let fabricated = try XCTUnwrap(snapshot.creationProjection(
        client: client, commandID: request.command.commandID, sourcePresence: .both))
    XCTAssertEqual(fabricated.state, .recoveryRequired)
    XCTAssertFalse(fabricated.responseIsReconstructable)

    let verified = await control.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(verified.verification.sourcePresence, .verified)
    XCTAssertNil(verified.verification.failure)
    XCTAssertTrue(verified.verification.isVerified)
    XCTAssertNotNil(verified.verification.workSourceDigest)
    XCTAssertNotNil(verified.verification.sessionSourceDigest)
    let verifiedProjection = try XCTUnwrap(verified.projection)
    XCTAssertEqual(verifiedProjection.state, .registered)
    XCTAssertTrue(verifiedProjection.responseIsReconstructable)

    // Close the control writer and create a later execution generation through the real paired
    // journal API. The registration cursor remains the idle genesis cursor; later canonical
    // Work/Session events are a valid suffix, not evidence that the original registration was
    // lost.
    let firstWorkDigest = try XCTUnwrap(verified.verification.workSourceDigest)
    let firstSessionDigest = try XCTUnwrap(verified.verification.sessionSourceDigest)
    try await control.closeChecked()
    let later = try await RunJournalBundle.openForExecution(
        home: home,
        binding: WorkRunBinding(workBinding: idle.binding, run: RunRef("post-registration-run")),
        actorID: "creation-later")
    _ = try await later.commitInput(
        text: "a later input", deliveryMode: .delivered,
        command: CommandRef(commandID: "post-registration-command"))
    try await later.closeChecked()

    let workURL = home.timelineV2WorkJournalURL(binding.work)
    let sessionURL = home.timelineV2SessionJournalURL(binding.session)

    // Exercise the many-to-many attachment shape through the low-level journal owner APIs:
    // another Session attaches to this Work, and this Session also attaches to another Work.
    // Each new pair has a mirrored attachment event on both sides, while the registered source
    // cursors continue to name only the original idle prefix.
    let secondSession = SessionRef("second-suffix-session")
    let secondSessionAttachment = SessionAttachmentRef("second-suffix-attachment")
    let secondSessionJournal = JournalRef.session(
        secondSession, journalID: "session", authority: TimelineAuthorityRef(host.workHostID))
    let secondSessionURL = home.timelineV2SessionJournalURL(secondSession)
    let secondSessionWriter = try TimelineJournalWriter(
        freshAt: secondSessionURL, journal: secondSessionJournal,
        actor: TimelineActor(actorID: "second-session-creator", kind: "work-host"), home: home)
    _ = try await secondSessionWriter.append(TimelineEventDraft(
        session: secondSession, type: TimelineEventType.sessionCreated,
        declaredDomains: [.session]))
    let secondSessionAttached = try await secondSessionWriter.append(TimelineEventDraft(
        session: secondSession, work: binding.work,
        sessionAttachment: secondSessionAttachment,
        type: TimelineEventType.sessionAttached, declaredDomains: [.session, .work],
        payload: .object(["capabilities": .array([])])))
    try await secondSessionWriter.closeChecked()

    let originalWorkWriter = try TimelineJournalWriter(
        reopening: workURL, journal: idle.binding.workJournal,
        actor: TimelineActor(actorID: "second-session-work-mirror", kind: "work-host"), home: home)
    _ = try await originalWorkWriter.append(TimelineEventDraft(
        causedByEventID: secondSessionAttached.eventRef,
        session: secondSession, work: binding.work, workHost: host,
        sessionAttachment: secondSessionAttachment,
        type: TimelineEventType.sessionAttached, declaredDomains: [.work, .session],
        payload: .object(["capabilities": .array([])])))
    try await originalWorkWriter.closeChecked()

    let secondWork = WorkRef(workHostID: host.workHostID, workID: "second-suffix-work")
    let secondWorkAttachment = SessionAttachmentRef("second-work-attachment")
    let secondWorkJournal = JournalRef.work(secondWork, journalID: "work")
    let secondWorkURL = home.timelineV2WorkJournalURL(secondWork)
    let secondWorkWriter = try TimelineJournalWriter(
        freshAt: secondWorkURL, journal: secondWorkJournal,
        actor: TimelineActor(actorID: "second-work-creator", kind: "work-host"), home: home)
    _ = try await secondWorkWriter.append(TimelineEventDraft(
        work: secondWork, workHost: host, type: TimelineEventType.workCreated,
        declaredDomains: [.work]))
    let secondWorkAttached = try await secondWorkWriter.append(TimelineEventDraft(
        session: binding.session, work: secondWork, workHost: host,
        sessionAttachment: secondWorkAttachment,
        type: TimelineEventType.sessionAttached, declaredDomains: [.work, .session],
        payload: .object(["capabilities": .array([])])))
    try await secondWorkWriter.closeChecked()

    let originalSessionWriter = try TimelineJournalWriter(
        reopening: sessionURL, journal: idle.binding.sessionJournal,
        actor: TimelineActor(actorID: "second-work-session-mirror", kind: "work-host"), home: home)
    _ = try await originalSessionWriter.append(TimelineEventDraft(
        causedByEventID: secondWorkAttached.eventRef,
        session: binding.session, work: secondWork,
        sessionAttachment: secondWorkAttachment,
        type: TimelineEventType.sessionAttached, declaredDomains: [.session, .work],
        payload: .object(["capabilities": .array([])])))
    try await originalSessionWriter.closeChecked()

    let workDataWithSuffix = try Data(contentsOf: workURL)
    let sessionDataWithSuffix = try Data(contentsOf: sessionURL)
    let workReadWithSuffix = TimelineJournalReader.read(
        workDataWithSuffix, journal: idle.binding.workJournal,
        actor: creationTestActor, hostRecordedAt: Date(timeIntervalSince1970: 0))
    let sessionReadWithSuffix = TimelineJournalReader.read(
        sessionDataWithSuffix, journal: idle.binding.sessionJournal,
        actor: creationTestActor, hostRecordedAt: Date(timeIntervalSince1970: 0))
    XCTAssertNil(workReadWithSuffix.quarantinedSuffix)
    XCTAssertNil(sessionReadWithSuffix.quarantinedSuffix)
    XCTAssertTrue(workReadWithSuffix.records.count > idle.workCursor.sequence)
    XCTAssertTrue(sessionReadWithSuffix.records.count > idle.sessionCursor.sequence)
    XCTAssertTrue(workReadWithSuffix.records.contains {
        $0.event.type == TimelineEventType.sessionAttached
            && $0.event.session == secondSession
            && $0.event.sessionAttachment == secondSessionAttachment
    })
    XCTAssertTrue(sessionReadWithSuffix.records.contains {
        $0.event.type == TimelineEventType.sessionAttached
            && $0.event.work == secondWork
            && $0.event.sessionAttachment == secondWorkAttachment
    })

    // Reopen the control journal to model a new process with no in-memory verification receipt.
    let reopened = try WorkHostControlJournal.reopenExisting(
        home: home, workHost: host,
        actor: TimelineActor(actorID: "creation-control-reopened", kind: "work-host"))
    let afterSuffix = await reopened.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(afterSuffix.verification.sourcePresence, .verified)
    XCTAssertNil(afterSuffix.verification.failure)
    XCTAssertTrue(afterSuffix.verification.isVerified)
    XCTAssertEqual(afterSuffix.verification.workSourceDigest, firstWorkDigest)
    XCTAssertEqual(afterSuffix.verification.sessionSourceDigest, firstSessionDigest)
    XCTAssertEqual(afterSuffix.projection?.state, .registered)
    XCTAssertTrue(afterSuffix.projection?.responseIsReconstructable == true)

    // A previously successful result is not a reusable capability. Deleting the source and then
    // replacing it with an unreadable body must make each fresh actor-owned projection truthful.
    try FileManager.default.removeItem(at: sessionURL)
    let deleted = await reopened.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(deleted.verification.sourcePresence, .workOnly)
    XCTAssertEqual(deleted.verification.failure, .sessionSourceMissing)
    XCTAssertFalse(deleted.verification.isVerified)
    XCTAssertEqual(deleted.projection?.state, .recoveryRequired)
    try Data("replaced-source\n".utf8).write(to: sessionURL, options: .atomic)
    let replaced = await reopened.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(replaced.verification.sourcePresence, .workOnly)
    XCTAssertEqual(replaced.verification.failure, .sessionSourceIncomplete)
    XCTAssertFalse(replaced.verification.isVerified)
    XCTAssertEqual(replaced.projection?.state, .recoveryRequired)
    try sessionDataWithSuffix.write(to: sessionURL, options: .atomic)

    // An unknown suffix is addressable but not source-verifiable: this verifier promises current
    // canonical event semantics, so an unrecognized event cannot silently become a trusted
    // registration prefix merely because its append chain is well formed.
    let lastWork = try XCTUnwrap(workReadWithSuffix.records.last?.event)
    let unknownSuffix = TimelineEvent(
        eventID: "future-work-suffix", journal: idle.binding.workJournal,
        sequence: lastWork.sequence + 1, previousEventID: lastWork.eventID,
        session: binding.session, work: binding.work, workHost: host,
        sessionAttachment: binding.sessionAttachment, actor: creationTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: 10), type: "future.work.event",
        declaredDomains: [.work], payload: .object([:]))
    try creationTestAppendEvent(unknownSuffix, to: workURL)
    let unknown = await reopened.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(unknown.verification.sourcePresence, .sessionOnly)
    XCTAssertEqual(unknown.verification.failure, .workSourceMismatch)
    XCTAssertFalse(unknown.verification.isVerified)
    XCTAssertEqual(unknown.projection?.state, .recoveryRequired)

    // Restore the known suffix, then append a structurally foreign Work Host envelope. The
    // suffix may vary in Session/attachment identity, but it cannot claim another Work Host.
    try workDataWithSuffix.write(to: workURL, options: .atomic)
    let foreignSuffix = TimelineEvent(
        eventID: "foreign-work-host-suffix", journal: idle.binding.workJournal,
        sequence: lastWork.sequence + 1, previousEventID: lastWork.eventID,
        session: binding.session, work: binding.work,
        workHost: WorkHostRef("foreign-suffix-host"),
        sessionAttachment: binding.sessionAttachment, actor: creationTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: 11), type: TimelineEventType.workFailed,
        declaredDomains: [.work], payload: .object([:]))
    try creationTestAppendEvent(foreignSuffix, to: workURL)
    let foreign = await reopened.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(foreign.verification.sourcePresence, .sessionOnly)
    XCTAssertEqual(foreign.verification.failure, .workSourceMismatch)
    XCTAssertFalse(foreign.verification.isVerified)
    XCTAssertEqual(foreign.projection?.state, .recoveryRequired)

    // A known event with invalid reducer semantics is also not source-verifiable. In particular,
    // detaching an attachment that the Work reducer has never observed must not pass the manual
    // envelope checks merely because the event is otherwise well formed.
    try workDataWithSuffix.write(to: workURL, options: .atomic)
    let invalidDetach = TimelineEvent(
        eventID: "unknown-attachment-detach", journal: idle.binding.workJournal,
        sequence: lastWork.sequence + 1, previousEventID: lastWork.eventID,
        session: binding.session, work: binding.work, workHost: host,
        sessionAttachment: SessionAttachmentRef("never-attached"), actor: creationTestActor,
        hostRecordedAt: Date(timeIntervalSince1970: 12), type: TimelineEventType.sessionDetached,
        declaredDomains: [.work, .session], payload: .object([:]))
    try creationTestAppendEvent(invalidDetach, to: workURL)
    let invalid = await reopened.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(invalid.verification.sourcePresence, .sessionOnly)
    XCTAssertEqual(invalid.verification.failure, .workSourceMismatch)
    XCTAssertFalse(invalid.verification.isVerified)
    XCTAssertEqual(invalid.projection?.state, .recoveryRequired)

    // Restore the known suffix, then append a malformed line. A complete registered prefix does
    // not hide a quarantined tail.
    try workDataWithSuffix.write(to: workURL, options: .atomic)
    var corruptData = workDataWithSuffix
    corruptData.append(Data("not-json\n".utf8))
    try corruptData.write(to: workURL, options: .atomic)
    let corrupt = await reopened.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(corrupt.verification.sourcePresence, .sessionOnly)
    XCTAssertEqual(corrupt.verification.failure, .workSourceIncomplete)
    XCTAssertFalse(corrupt.verification.isVerified)
    XCTAssertEqual(corrupt.projection?.state, .recoveryRequired)
    try await reopened.closeChecked()
}

func test_workHostControlCreationVerifierRejectsWrongRegisteredPrefixCursor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-creation-wrong-prefix-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let host = try home.requirePersistedWorkHost()
    let binding = WorkBinding(
        session: SessionRef("wrong-prefix-session"),
        work: WorkRef(workHostID: host.workHostID, workID: "wrong-prefix-work"),
        workHost: host,
        sessionAttachment: SessionAttachmentRef("wrong-prefix-attachment"))
    let idle = try await RunJournalBundle.createIdleWork(
        home: home, binding: binding, actorID: "wrong-prefix-creator")
    let client = ClientRef("wrong-prefix-client")
    let control = try WorkHostControlJournal(
        freshAt: root.appending(path: "wrong-prefix-control.jsonl"),
        workHost: host,
        actor: TimelineActor(actorID: "wrong-prefix-control", kind: "work-host"),
        home: home,
        creationIdentityMinter: {
            WorkHostControlMintedIdentity(
                workID: binding.work.workID,
                sessionID: binding.session.sessionID,
                sessionAttachmentID: binding.sessionAttachment.attachmentID)
        })
    let empty = JournalCursor(journal: control.journal, eventID: nil, sequence: 0)
    let request = WorkHostControlCreationRequest(
        client: client, commandID: "wrong-prefix-create",
        bodyDigest: creationTestBodyDigest,
        configurationDigest: creationTestConfigurationDigest,
        causalControlCursor: empty)
    let reservation = try await control.reserveCreation(request)
    let wrongSessionCursor = JournalCursor(
        journal: idle.binding.sessionJournal,
        eventID: "not-the-registered-prefix",
        sequence: idle.sessionCursor.sequence)
    _ = try await control.registerWork(WorkHostControlWorkRegistrationRequest(
        reservation: reservation,
        workJournal: idle.binding.workJournal,
        sessionJournal: idle.binding.sessionJournal,
        workGenesisCursor: idle.workCursor,
        sessionGenesisCursor: wrongSessionCursor,
        causalControlCursor: reservation.reservationCursor))

    let result = await control.verifiedCreationProjection(
        client: client, commandID: request.command.commandID)
    XCTAssertEqual(result.verification.sourcePresence, .workOnly)
    XCTAssertEqual(result.verification.failure, .sessionSourceMismatch)
    XCTAssertFalse(result.verification.isVerified)
    XCTAssertEqual(result.projection?.state, .recoveryRequired)
    XCTAssertFalse(result.projection?.responseIsReconstructable == true)
    try await control.closeChecked()
}

func test_workHostControlCreationMinterRetriesReservedCollisionsAndRejectsExhaustion() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-creation-mint-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let fixed = WorkHostControlMintedIdentity(
        workID: "fixed-work", sessionID: "fixed-session", sessionAttachmentID: "fixed-attachment")
    let alternate = WorkHostControlMintedIdentity(
        workID: "retry-work", sessionID: "retry-session", sessionAttachmentID: "retry-attachment")
    let minter = CreationIdentitySequence([fixed, fixed, alternate, alternate])
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: creationTestHost, actor: creationTestActor,
        creationIdentityMinter: { minter.next() })
    let empty = JournalCursor(journal: creationTestControlJournal, eventID: nil, sequence: 0)
    let first = try await journal.reserveCreation(creationTestCommand(cursor: empty))
    XCTAssertEqual(first.work.workID, fixed.workID)
    XCTAssertEqual(first.session.sessionID, fixed.sessionID)
    XCTAssertEqual(first.sessionAttachment.attachmentID, fixed.sessionAttachmentID)

    let secondRequest = creationTestCommand(id: "create-2", cursor: first.reservationCursor)
    let second = try await journal.reserveCreation(secondRequest)
    XCTAssertEqual(second.work.workID, alternate.workID)
    XCTAssertEqual(second.session.sessionID, alternate.sessionID)
    XCTAssertEqual(second.sessionAttachment.attachmentID, alternate.sessionAttachmentID)
    XCTAssertEqual(await journal.nextSequenceNumber, 3)

    let thirdRequest = creationTestCommand(id: "create-3", cursor: second.reservationCursor)
    do {
        _ = try await journal.reserveCreation(thirdRequest)
        XCTFail("a minter collision with an already-reserved identity must not be accepted")
    } catch {
        // The injected minter repeats the second identity: the journal retries within its bound,
        // then rejects rather than silently reusing any Work/Session/attachment identity.
    }
    XCTAssertEqual(await journal.nextSequenceNumber, 3)
    XCTAssertEqual(try await journal.snapshot().creations.count, 2)
    try await journal.closeChecked()
}

func test_workHostControlCreationRejectsConflictingBodyAndUnboundedIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-control-creation-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    let journal = try WorkHostControlJournal.createFresh(
        home: home, workHost: creationTestHost, actor: creationTestActor)
    let emptyCursor = JournalCursor(
        journal: creationTestControlJournal, eventID: nil, sequence: 0)
    let request = WorkHostControlCreationRequest(
        client: creationTestClient, commandID: "create-1",
        bodyDigest: creationTestBodyDigest,
        configurationDigest: creationTestConfigurationDigest,
        causalControlCursor: emptyCursor)
    _ = try await journal.reserveCreation(request)
    do {
        _ = try await journal.reserveCreation(WorkHostControlCreationRequest(
            client: creationTestClient, commandID: "create-1",
            bodyDigest: "sha256:" + String(repeating: "c", count: 64),
            configurationDigest: creationTestConfigurationDigest,
            causalControlCursor: emptyCursor))
        XCTFail("same client/command with another body digest must conflict")
    } catch {}
    let oversizedID = "a" + String(repeating: "\u{0301}", count: 300)
    XCTAssertEqual(oversizedID.count, 1)
    do {
        _ = try await journal.reserveCreation(WorkHostControlCreationRequest(
            client: creationTestClient, commandID: oversizedID,
            bodyDigest: creationTestBodyDigest,
            configurationDigest: creationTestConfigurationDigest,
            causalControlCursor: emptyCursor))
        XCTFail("UTF-8-unbounded command identity must be rejected")
    } catch {}
    let data = try Data(contentsOf: journal.fileURL)
    let serialized = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(serialized.contains("cwd"))
    XCTAssertFalse(serialized.contains("prompt body"))
    try await journal.closeChecked()
}

let casesWorkHostControlCreation: [Case] = [
    ("phase3 Work Host creation: crash windows are explicit", {
        try test_workHostControlCreationReducerProjectsExplicitCrashStates()
    }),
    ("phase3 Work Host creation: changed registration evidence is quarantined", {
        try test_workHostControlCreationReducerQuarantinesChangedRegistrationEvidence()
    }),
    ("phase3 Work Host creation: reservation and registration reconcile", {
        try await test_workHostControlCreationJournalReconcilesReservationAndRegistration()
    }),
    ("phase3 Work Host creation: body conflicts and bounds fail closed", {
        try await test_workHostControlCreationRejectsConflictingBodyAndUnboundedIdentity()
    }),
    ("phase3 Work Host creation: authority and source verification are explicit", {
        try await test_workHostControlCreationRejectsForeignSessionAuthorityAndUnverifiedSources()
    }),
    ("phase3 Work Host creation: canonical source verifier gates registration", {
        try await test_workHostControlCreationVerifierRequiresCanonicalMirroredSources()
    }),
    ("phase3 Work Host creation: wrong registered prefix is rejected", {
        try await test_workHostControlCreationVerifierRejectsWrongRegisteredPrefixCursor()
    }),
    ("phase3 Work Host creation: identity minting rejects reserved collisions", {
        try await test_workHostControlCreationMinterRetriesReservedCollisionsAndRejectsExhaustion()
    }),
]
