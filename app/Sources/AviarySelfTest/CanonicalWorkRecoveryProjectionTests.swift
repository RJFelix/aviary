import Foundation
@testable import AviaryCore

private let recoveryProjectionActor = TimelineActor(actorID: "recovery-projection-test", kind: "test")

private func recoveryProjectionHome() throws -> AgentHome {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-work-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AgentHome(root: root)
}

private func recoveryProjectionEvent(
    id: String, journal: JournalRef, sequence: Int, previous: String? = nil,
    type: String, session: SessionRef? = nil, work: WorkRef? = nil,
    workHost: WorkHostRef? = nil, sessionAttachment: SessionAttachmentRef? = nil,
    action: ActionRef? = nil,
    client: ClientRef? = nil, clientAttachment: ClientAttachmentRef? = nil,
    run: RunRef? = nil, handle: HandleRef? = nil,
    declaredDomains: Set<TimelineDomain> = [],
    payload: JSONValue = .object([:])
) throws -> Data {
    let event = TimelineEvent(
        eventID: id, journal: journal, sequence: sequence, previousEventID: previous,
        session: session, work: work, workHost: workHost,
        client: client, sessionAttachment: sessionAttachment,
        clientAttachment: clientAttachment, run: run, action: action, handle: handle,
        actor: recoveryProjectionActor, hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, declaredDomains: declaredDomains, payload: payload)
    var data = try JSONEncoder().encode(event)
    data.append(0x0A)
    return data
}

private func recoveryProjectionWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func recoveryProjectionJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(value)))
}

private func recoveryProjectionWorkData(
    work: WorkRef, journal: JournalRef, terminal: Bool = false,
    unknownRuntime: Bool = false, unknownSession: Bool = false,
    includeDetachedSecondClient: Bool = false
) throws -> Data {
    var data = try recoveryProjectionEvent(
        id: "w1", journal: journal, sequence: 1, type: TimelineEventType.workCreated,
        work: work, workHost: WorkHostRef(work.workHostID), declaredDomains: [.work])
    data.append(try recoveryProjectionEvent(
        id: "w2", journal: journal, sequence: 2, previous: "w1",
        type: TimelineEventType.sessionAttached, session: SessionRef("recovery-session"),
        work: work, workHost: WorkHostRef(work.workHostID),
        sessionAttachment: SessionAttachmentRef("recovery-attachment"),
        declaredDomains: [.work, .session],
        payload: .object(["capabilities": .array([.string("observe")])])))
    data.append(try recoveryProjectionEvent(
        id: "w3", journal: journal, sequence: 3, previous: "w2",
        type: TimelineEventType.clientAttached, work: work,
        workHost: WorkHostRef(work.workHostID), client: ClientRef("gui-a"),
        clientAttachment: ClientAttachmentRef("client-a"), declaredDomains: [.work],
        payload: .object(["capabilities": .array([.string("observe"), .string("control")])])))
    var lastID = "w3"
    var sequence = 3
    if includeDetachedSecondClient {
        sequence += 1
        data.append(try recoveryProjectionEvent(
            id: "w\(sequence)", journal: journal, sequence: sequence, previous: lastID,
            type: TimelineEventType.clientAttached, work: work,
            workHost: WorkHostRef(work.workHostID), client: ClientRef("gui-b"),
            clientAttachment: ClientAttachmentRef("client-b"), declaredDomains: [.work],
            payload: .object(["capabilities": .array([.string("observe"), .string("control")])])))
        lastID = "w\(sequence)"
        sequence += 1
        data.append(try recoveryProjectionEvent(
            id: "w\(sequence)", journal: journal, sequence: sequence, previous: lastID,
            type: TimelineEventType.clientDetached, work: work,
            workHost: WorkHostRef(work.workHostID), client: ClientRef("gui-b"),
            clientAttachment: ClientAttachmentRef("client-b"), declaredDomains: [.work]))
        lastID = "w\(sequence)"
    }
    sequence += 1
    let stateID = "w\(sequence)"
    if unknownRuntime {
        data.append(try recoveryProjectionEvent(
            id: stateID, journal: journal, sequence: sequence, previous: lastID,
            type: "future.runtime.fact", work: work,
            workHost: WorkHostRef(work.workHostID), declaredDomains: [.runtime]))
    } else if terminal {
        data.append(try recoveryProjectionEvent(
            id: stateID, journal: journal, sequence: sequence, previous: lastID,
            type: TimelineEventType.workCompleted, work: work,
            workHost: WorkHostRef(work.workHostID), declaredDomains: [.work]))
    } else {
        data.append(try recoveryProjectionEvent(
            id: stateID, journal: journal, sequence: sequence, previous: lastID,
            type: TimelineEventType.runStarted, work: work,
            workHost: WorkHostRef(work.workHostID), run: RunRef("recovery-run"),
            declaredDomains: [.work], payload: .object(["model_id": .string("recovery-model")])))
    }
    if unknownSession {
        sequence += 1
        data.append(try recoveryProjectionEvent(
            id: "w\(sequence)", journal: journal, sequence: sequence, previous: stateID,
            type: "future.session.attachment", work: work,
            workHost: WorkHostRef(work.workHostID), declaredDomains: [.session]))
    }
    return data
}

func test_canonicalWorkRecoveryProjectionUsesDurableWorkEvidenceAndScopesObservers() throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "recovery-host", workID: "active-work")
    let journal = JournalRef.work(work)
    try recoveryProjectionWrite(
        recoveryProjectionWorkData(
            work: work, journal: journal, includeDetachedSecondClient: true),
        to: home.timelineV2WorkJournalURL(work))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let row = try XCTUnwrap(catalog.works.first { $0.work == work })
    XCTAssertTrue(row.isAvailable)
    XCTAssertEqual(row.sessionAttachments.count, 1)
    XCTAssertEqual(row.sessionAttachments[0].session, SessionRef("recovery-session"))
    XCTAssertEqual(row.lifecycle, .active)
    XCTAssertEqual(row.activeRun, RunRef("recovery-run"))

    let observation = CanonicalWorkRecoveryObservation(
        work: work, workJournal: journal, session: SessionRef("recovery-session"),
        sessionAttachment: SessionAttachmentRef("recovery-attachment"), run: RunRef("recovery-run"),
        client: ClientRef("gui-a"), clientAttachment: ClientAttachmentRef("client-a"),
        presentation: .attached, canReattach: true, canControl: true)
    let global = CanonicalWorkRecoveryProjection(
        catalog: catalog, observations: [observation])
    XCTAssertEqual(global.rows.first?.disposition, .recordedActive)
    XCTAssertEqual(global.rows.first?.clientDisposition, .notRequested)
    XCTAssertFalse(global.rows.first?.clientCanControl ?? true)
    XCTAssertEqual(global.rows.first?.sessionAttachments.count, 1)
    XCTAssertFalse(global.rows.first?.sessionAttachments[0].isExact ?? true)

    let scoped = CanonicalWorkRecoveryProjection(
        catalog: catalog, observations: [observation], observingClient: ClientRef("gui-a"))
    XCTAssertEqual(scoped.rows.first?.disposition, .recordedActive)
    XCTAssertEqual(scoped.rows.first?.clientDisposition, .observedAttached)
    XCTAssertTrue(scoped.rows.first?.clientCanControl ?? false)

    let duplicate = CanonicalWorkRecoveryProjection(
        catalog: catalog, observations: [observation, observation],
        observingClient: ClientRef("gui-a"))
    XCTAssertNotEqual(duplicate.rows.first?.disposition, .ambiguous)
    XCTAssertEqual(duplicate.rows.first?.clientDisposition, .observedAttached)
    XCTAssertEqual(duplicate.rows.first?.omittedObservationCount, 1)
    let conflicting = CanonicalWorkRecoveryObservation(
        work: work, workJournal: journal, session: SessionRef("recovery-session"),
        sessionAttachment: SessionAttachmentRef("recovery-attachment"), run: RunRef("recovery-run"),
        client: ClientRef("gui-a"), clientAttachment: ClientAttachmentRef("client-a"),
        presentation: .detached, canReattach: false, canControl: false)
    let conflict = CanonicalWorkRecoveryProjection(
        catalog: catalog, observations: [observation, conflicting],
        observingClient: ClientRef("gui-a"))
    XCTAssertEqual(conflict.rows.first?.disposition, .recordedActive)
    XCTAssertEqual(conflict.rows.first?.clientDisposition, .ambiguous)
    XCTAssertEqual(conflict.rows.first?.omittedObservationCount, 1)

    let otherClientDetached = CanonicalWorkRecoveryObservation(
        work: work, workJournal: journal, session: SessionRef("recovery-session"),
        sessionAttachment: SessionAttachmentRef("recovery-attachment"), run: RunRef("recovery-run"),
        client: ClientRef("gui-b"), clientAttachment: ClientAttachmentRef("client-b"),
        presentation: .detached, canReattach: true, canControl: true)
    let independentClients = CanonicalWorkRecoveryProjection(
        catalog: catalog, observations: [observation, otherClientDetached],
        observingClient: ClientRef("gui-a"))
    XCTAssertEqual(independentClients.rows.first?.disposition, .recordedActive)
    XCTAssertEqual(independentClients.rows.first?.clientDisposition, .observedAttached)
    XCTAssertTrue(independentClients.rows.first?.clientCanControl ?? false)
    let secondClient = CanonicalWorkRecoveryProjection(
        catalog: catalog, observations: [observation, otherClientDetached],
        observingClient: ClientRef("gui-b"))
    XCTAssertEqual(secondClient.rows.first?.disposition, .recordedActive)
    XCTAssertEqual(secondClient.rows.first?.clientDisposition, .observedReattachable)
    XCTAssertTrue(secondClient.rows.first?.clientCanControl ?? false)

    let malformedOtherClient = CanonicalWorkRecoveryObservation(
        work: work, workJournal: journal, session: SessionRef("recovery-session"),
        sessionAttachment: SessionAttachmentRef("recovery-attachment"), run: RunRef("recovery-run"),
        client: ClientRef("gui-b"), clientAttachment: ClientAttachmentRef(""),
        presentation: .attached, canReattach: true, canControl: true)
    let isolatedMalformedClient = CanonicalWorkRecoveryProjection(
        catalog: catalog, observations: [observation, malformedOtherClient],
        observingClient: ClientRef("gui-a"))
    XCTAssertEqual(isolatedMalformedClient.rows.first?.disposition, .recordedActive)
    XCTAssertEqual(isolatedMalformedClient.rows.first?.clientDisposition, .observedAttached)
    XCTAssertTrue(isolatedMalformedClient.rows.first?.observationReasons.isEmpty == false)
}

func test_canonicalWorkRecoveryProjectionTerminalAndUnknownStatesFailClosed() throws {
    let terminalHome = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: terminalHome.root) }
    let terminalWork = WorkRef(workHostID: "recovery-host", workID: "terminal-work")
    let terminalJournal = JournalRef.work(terminalWork)
    try recoveryProjectionWrite(
        recoveryProjectionWorkData(work: terminalWork, journal: terminalJournal, terminal: true),
        to: terminalHome.timelineV2WorkJournalURL(terminalWork))
    let terminal = CanonicalWorkRecoveryProjection(catalog: LocalTimelineCatalog.scan(home: terminalHome))
    XCTAssertEqual(terminal.rows.first?.disposition, .completedEvidence)
    XCTAssertEqual(terminal.rows.first?.activeRun, nil)

    let unknownHome = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: unknownHome.root) }
    let unknownWork = WorkRef(workHostID: "recovery-host", workID: "unknown-work")
    let unknownJournal = JournalRef.work(unknownWork)
    try recoveryProjectionWrite(
        recoveryProjectionWorkData(work: unknownWork, journal: unknownJournal, unknownRuntime: true),
        to: unknownHome.timelineV2WorkJournalURL(unknownWork))
    let unknown = CanonicalWorkRecoveryProjection(catalog: LocalTimelineCatalog.scan(home: unknownHome))
    XCTAssertEqual(unknown.rows.first?.disposition, .uncertain)
    XCTAssertTrue(unknown.rows.first?.unknownDomains.contains(.runtime) ?? false)

    let unknownSessionHome = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: unknownSessionHome.root) }
    let unknownSessionWork = WorkRef(
        workHostID: "recovery-host", workID: "unknown-session-work")
    let unknownSessionJournal = JournalRef.work(unknownSessionWork)
    try recoveryProjectionWrite(
        recoveryProjectionWorkData(
            work: unknownSessionWork, journal: unknownSessionJournal, unknownSession: true),
        to: unknownSessionHome.timelineV2WorkJournalURL(unknownSessionWork))
    let unknownSessionCatalog = LocalTimelineCatalog.scan(home: unknownSessionHome)
    let unknownSessionRow = try XCTUnwrap(unknownSessionCatalog.works.first)
    XCTAssertTrue(unknownSessionRow.sessionAttachments.isEmpty)
    XCTAssertEqual(unknownSessionRow.clientAttachments.count, 1)
    let unknownSessionProjection = CanonicalWorkRecoveryProjection(catalog: unknownSessionCatalog)
    XCTAssertEqual(unknownSessionProjection.rows.first?.disposition, .recordedActive)
}

func test_canonicalWorkRecoveryProjectionDoesNotManufactureRecoveryWithoutCatalogEvidence() throws {
    let work = WorkRef(workHostID: "recovery-host", workID: "observation-only-work")
    let observation = CanonicalWorkRecoveryObservation(
        work: work, workJournal: JournalRef.work(work),
        session: SessionRef("observation-only-session"),
        sessionAttachment: SessionAttachmentRef("observation-only-session-attachment"),
        run: RunRef("observation-only-run"), client: ClientRef("gui-a"),
        clientAttachment: ClientAttachmentRef("observation-only-client-attachment"),
        presentation: .attached, canReattach: true, canControl: true)
    let projection = CanonicalWorkRecoveryProjection(
        works: [], observations: [observation], observingClient: ClientRef("gui-a"))
    let row = try XCTUnwrap(projection.rows.first)
    XCTAssertEqual(row.disposition, .uncertain)
    XCTAssertEqual(row.clientDisposition, .unverified)
    XCTAssertFalse(row.clientCanControl)
    XCTAssertNil(row.cursor)
    XCTAssertTrue(row.observationReasons.contains {
        $0.contains("no current canonical Work row")
    })
}

func test_canonicalWorkRecoveryProjectionDuplicateWorkRefsAcrossJournalsAreAmbiguous() throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "recovery-host", workID: "duplicate-work")
    let journal = JournalRef.work(work, journalID: "journal-a")
    try recoveryProjectionWrite(
        recoveryProjectionWorkData(work: work, journal: journal),
        to: home.timelineV2WorkJournalURL(work))
    let catalog = LocalTimelineCatalog.scan(home: home)
    let first = try XCTUnwrap(catalog.works.first { $0.work == work })
    let secondJournal = JournalRef.work(work, journalID: "journal-b")
    let second = LocalTimelineCatalog.WorkRow(
        locatorID: "synthetic-second-journal", work: work, journal: secondJournal,
        snapshot: nil, read: nil, available: false,
        reasons: ["duplicate test row"], limit: 16)
    let projection = CanonicalWorkRecoveryProjection(works: [first, second])
    XCTAssertEqual(projection.rows.count, 2)
    XCTAssertTrue(projection.rows.allSatisfy { $0.disposition == .ambiguous })
}

func test_canonicalWorkRecoveryProjectionCatalogRetainsRecordedRecoveryEnvelope() throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("coverage-session")
    let work = WorkRef(workHostID: "coverage-host", workID: "coverage-work")
    let sessionJournal = JournalRef.session(session, journalID: "coverage-session-journal",
                                            authority: TimelineAuthorityRef("coverage-service"))
    let workJournal = JournalRef.work(work, journalID: "coverage-work-journal")
    try recoveryProjectionWrite(
        recoveryProjectionWorkData(work: work, journal: workJournal),
        to: home.timelineV2WorkJournalURL(work))
    var sessionData = try recoveryProjectionEvent(
        id: "s1", journal: sessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: session, declaredDomains: [.session])
    sessionData.append(try recoveryProjectionEvent(
        id: "s2", journal: sessionJournal, sequence: 2, previous: "s1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        sessionAttachment: SessionAttachmentRef("recovery-attachment"),
        declaredDomains: [.session, .work]))
    let planes = Dictionary(uniqueKeysWithValues: RecoveryPlane.allCases.map { ($0, RecoveryCoverageStatus.preserved) })
    let coveragePayload: JSONValue = .object([
        "operation": .string(RecoveryOperation.coldResume.rawValue),
        "work_journal": try recoveryProjectionJSON(workJournal),
        "planes": .object(Dictionary(uniqueKeysWithValues: planes.map {
            ($0.key.rawValue, .string($0.value.rawValue))
        })),
        "caveats": .array([.string("source-prefix")])
    ])
    sessionData.append(try recoveryProjectionEvent(
        id: "s3", journal: sessionJournal, sequence: 3, previous: "s2",
        type: TimelineEventType.recoveryCoverage, session: session, work: work,
        workHost: WorkHostRef(work.workHostID),
        sessionAttachment: SessionAttachmentRef("recovery-attachment"), run: RunRef("recovery-run"),
        declaredDomains: [.session, .work, .context, .runtime, .externalEffects],
        payload: coveragePayload))
    try recoveryProjectionWrite(sessionData, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let summary = try XCTUnwrap(catalog.sessionSummaries.first)
    let record = try XCTUnwrap(summary.recordedRecoveryCoverage?.first)
    XCTAssertEqual(record.sourceEvent.eventID, "s3")
    XCTAssertEqual(record.work, work)
    XCTAssertEqual(record.workJournal, workJournal)
    XCTAssertEqual(record.run, RunRef("recovery-run"))
    XCTAssertEqual(record.sessionAttachment, SessionAttachmentRef("recovery-attachment"))
}

func test_canonicalWorkRecoveryProjectionJoinsProductionRecoveryEnvelope() async throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "production-coverage-session",
        work: WorkRef(workHostID: hostID, workID: "production-coverage-work"),
        runID: "production-coverage-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "production-coverage-test",
        modelID: "coverage-model", makeAttachmentID: { "production-coverage-attachment" })
    let planes = Dictionary(uniqueKeysWithValues: RecoveryPlane.allCases.map {
        ($0, RecoveryCoverageStatus.preserved)
    })
    let commit = try await bundle.recordRecoveryCoverage(RecoveryCoverage(
        operation: .coldResume, planes: planes, caveats: ["exact production envelope"]))
    _ = try await bundle.finishRun(outcome: .completed)
    try await bundle.closeChecked()

    let catalog = LocalTimelineCatalog.scan(home: home)
    let projection = CanonicalWorkRecoveryProjection(catalog: catalog)
    let row = try XCTUnwrap(projection.rows.first { $0.work == identity.work })
    XCTAssertNil(row.activeRun)
    XCTAssertTrue(row.runHistory.contains(RunRef(identity.runID)))
    let attachment = try XCTUnwrap(row.sessionAttachments.first {
        $0.session == SessionRef(identity.sessionID)
            && $0.attachment == SessionAttachmentRef("production-coverage-attachment")
    })
    let recorded = try XCTUnwrap(attachment.recoveryCoverage.first)
    XCTAssertEqual(recorded.sourceEvent, commit.eventRef)
    XCTAssertEqual(recorded.session, SessionRef(identity.sessionID))
    XCTAssertEqual(recorded.work, identity.work)
    XCTAssertEqual(recorded.workJournal, bundle.workJournal)
    XCTAssertEqual(recorded.workHost, WorkHostRef(hostID))
    XCTAssertEqual(recorded.sessionAttachment,
                   SessionAttachmentRef("production-coverage-attachment"))
    XCTAssertEqual(recorded.run, RunRef(identity.runID))
    XCTAssertEqual(recorded.coverage.planes, planes)
}

func test_canonicalWorkRecoveryProjectionRejectsRecoveryFromAnotherWorkJournalGeneration() throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("aba-session")
    let work = WorkRef(workHostID: "aba-host", workID: "aba-work")
    let currentJournal = JournalRef.work(work, journalID: "work-journal-new")
    let replacedJournal = JournalRef.work(work, journalID: "work-journal-old")
    let sessionJournal = JournalRef.session(
        session, journalID: "aba-session-journal",
        authority: TimelineAuthorityRef("aba-session-service"))
    try recoveryProjectionWrite(
        recoveryProjectionWorkData(work: work, journal: currentJournal),
        to: home.timelineV2WorkJournalURL(work))
    var sessionData = try recoveryProjectionEvent(
        id: "aba-s1", journal: sessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: session, declaredDomains: [.session])
    sessionData.append(try recoveryProjectionEvent(
        id: "aba-s2", journal: sessionJournal, sequence: 2, previous: "aba-s1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        sessionAttachment: SessionAttachmentRef("recovery-attachment"),
        declaredDomains: [.session, .work]))
    sessionData.append(try recoveryProjectionEvent(
        id: "aba-s3", journal: sessionJournal, sequence: 3, previous: "aba-s2",
        type: TimelineEventType.recoveryCoverage, session: session, work: work,
        workHost: WorkHostRef(work.workHostID),
        sessionAttachment: SessionAttachmentRef("recovery-attachment"),
        run: RunRef("recovery-run"),
        declaredDomains: [.session, .work, .context, .runtime, .externalEffects],
        payload: .object([
            "operation": .string(RecoveryOperation.coldResume.rawValue),
            "work_journal": try recoveryProjectionJSON(replacedJournal),
            "planes": .object(Dictionary(uniqueKeysWithValues: RecoveryPlane.allCases.map {
                ($0.rawValue, JSONValue.string(RecoveryCoverageStatus.preserved.rawValue))
            })),
        ])))
    try recoveryProjectionWrite(sessionData, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.scan(home: home)
    XCTAssertEqual(catalog.sessionSummaries.first?.recordedRecoveryCoverage?.first?.workJournal,
                   replacedJournal)
    let row = try XCTUnwrap(CanonicalWorkRecoveryProjection(catalog: catalog).rows.first)
    XCTAssertEqual(row.journal, currentJournal)
    XCTAssertTrue(row.sessionAttachments.allSatisfy { $0.recoveryCoverage.isEmpty })
    XCTAssertEqual(row.sessionAttachments.first?.omittedRecoveryCoverageCount, 1)
    XCTAssertTrue(row.sessionAttachments.first?.reasons.contains {
        $0.contains("another Work generation or Run")
    } ?? false)
}

func test_canonicalWorkRecoveryProjectionBoundsClientCursorAndHandleMetadata() throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let work = WorkRef(workHostID: "bound-host", workID: "bound-work")
    let journal = JournalRef.work(work, journalID: "bound-journal")
    var data = try recoveryProjectionEvent(
        id: "b1", journal: journal, sequence: 1, type: TimelineEventType.workCreated,
        work: work, workHost: WorkHostRef(work.workHostID), declaredDomains: [.work])
    data.append(try recoveryProjectionEvent(
        id: "b2", journal: journal, sequence: 2, previous: "b1",
        type: TimelineEventType.runStarted, work: work,
        workHost: WorkHostRef(work.workHostID), run: RunRef("bound-run"),
        declaredDomains: [.work]))
    let longEventID = String(repeating: "e", count: 48)
    data.append(try recoveryProjectionEvent(
        id: longEventID, journal: journal, sequence: 3, previous: "b2",
        type: TimelineEventType.handleStarted, work: work,
        workHost: WorkHostRef(work.workHostID), run: RunRef("bound-run"),
        handle: HandleRef("bound-handle"),
        declaredDomains: [.runtime], payload: .object([
            "state": .string(String(repeating: "s", count: 48))
        ])))
    try recoveryProjectionWrite(data, to: home.timelineV2WorkJournalURL(work))

    let projection = CanonicalWorkRecoveryProjection(
        catalog: LocalTimelineCatalog.scan(home: home),
        limits: .init(maxIdentityCharacters: 32),
        observingClient: ClientRef(String(repeating: "c", count: 48)))
    let row = try XCTUnwrap(projection.rows.first)
    XCTAssertEqual(row.work, work)
    XCTAssertEqual(row.clientDisposition, .unverified)
    XCTAssertNil(row.observingClient)
    XCTAssertNil(row.cursor)
    XCTAssertNil(row.committedPrefixCursor)
    XCTAssertEqual(row.omittedCursorCount, 2)
    XCTAssertTrue(row.handles.isEmpty)
    XCTAssertEqual(row.omittedHandleCount, 1)
    XCTAssertTrue(row.observationReasons.contains {
        $0 == "invalid observing client"
    })
}

func test_canonicalWorkRecoveryProjectionUsesCompleteRunMembershipBeyondDisplayCap() throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("run-cap-session")
    let work = WorkRef(workHostID: "run-cap-host", workID: "run-cap-work")
    let workJournal = JournalRef.work(work, journalID: "run-cap-work-journal")
    let attachment = SessionAttachmentRef("run-cap-attachment")
    var workData = try recoveryProjectionEvent(
        id: "cap-w1", journal: workJournal, sequence: 1,
        type: TimelineEventType.workCreated, work: work,
        workHost: WorkHostRef(work.workHostID), declaredDomains: [.work])
    workData.append(try recoveryProjectionEvent(
        id: "cap-w2", journal: workJournal, sequence: 2, previous: "cap-w1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        workHost: WorkHostRef(work.workHostID), sessionAttachment: attachment,
        declaredDomains: [.session, .work]))
    var sequence = 2
    var previous = "cap-w2"
    for index in 0..<300 {
        let run = RunRef(String(format: "run-%04d", index))
        sequence += 1
        let started = "cap-w\(sequence)"
        workData.append(try recoveryProjectionEvent(
            id: started, journal: workJournal, sequence: sequence, previous: previous,
            type: TimelineEventType.runStarted, work: work,
            workHost: WorkHostRef(work.workHostID), run: run,
            declaredDomains: [.work]))
        sequence += 1
        let finished = "cap-w\(sequence)"
        workData.append(try recoveryProjectionEvent(
            id: finished, journal: workJournal, sequence: sequence, previous: started,
            type: TimelineEventType.runFinished, work: work,
            workHost: WorkHostRef(work.workHostID), run: run,
            declaredDomains: [.work], payload: .object(["state": .string("completed")])))
        previous = finished
    }
    try recoveryProjectionWrite(workData, to: home.timelineV2WorkJournalURL(work))

    let sessionJournal = JournalRef.session(
        session, journalID: "run-cap-session-journal",
        authority: TimelineAuthorityRef("run-cap-session-service"))
    var sessionData = try recoveryProjectionEvent(
        id: "cap-s1", journal: sessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: session, declaredDomains: [.session])
    sessionData.append(try recoveryProjectionEvent(
        id: "cap-s2", journal: sessionJournal, sequence: 2, previous: "cap-s1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        sessionAttachment: attachment, declaredDomains: [.session, .work]))
    sessionData.append(try recoveryProjectionEvent(
        id: "cap-s3", journal: sessionJournal, sequence: 3, previous: "cap-s2",
        type: TimelineEventType.recoveryCoverage, session: session, work: work,
        workHost: WorkHostRef(work.workHostID), sessionAttachment: attachment,
        run: RunRef("run-0299"),
        declaredDomains: [.session, .work, .context, .runtime, .externalEffects],
        payload: .object([
            "operation": .string(RecoveryOperation.coldResume.rawValue),
            "work_journal": try recoveryProjectionJSON(workJournal),
            "planes": .object(Dictionary(uniqueKeysWithValues: RecoveryPlane.allCases.map {
                ($0.rawValue, JSONValue.string(RecoveryCoverageStatus.preserved.rawValue))
            })),
        ])))
    try recoveryProjectionWrite(sessionData, to: home.timelineV2SessionJournalURL(session))

    let row = try XCTUnwrap(
        CanonicalWorkRecoveryProjection(catalog: LocalTimelineCatalog.scan(home: home))
            .rows.first)
    XCTAssertEqual(row.runHistory.count, 256)
    XCTAssertEqual(row.omittedRunCount, 44)
    XCTAssertFalse(row.runHistory.contains(RunRef("run-0299")))
    let sessionFact = try XCTUnwrap(row.sessionAttachments.first)
    XCTAssertEqual(sessionFact.recoveryCoverage.map(\.run), [RunRef("run-0299")])
}

func test_canonicalWorkRecoveryProjectionRequiresReciprocalWorkSessionAttachment() throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let session = SessionRef("reciprocal-session")
    let work = WorkRef(workHostID: "reciprocal-host", workID: "reciprocal-work")
    let sessionAttachment = SessionAttachmentRef("reciprocal-attachment")
    let run = RunRef("reciprocal-run")
    let action = ActionRef("reciprocal-action")
    let workJournal = JournalRef.work(work, journalID: "reciprocal-work-journal")
    let sessionJournal = JournalRef.session(
        session, journalID: "reciprocal-session-journal",
        authority: TimelineAuthorityRef("reciprocal-session-service"))

    // The Work page has exact Run/action evidence but deliberately has no
    // session.attached record for this Session attachment.
    var workData = try recoveryProjectionEvent(
        id: "rw1", journal: workJournal, sequence: 1,
        type: TimelineEventType.workCreated, work: work,
        workHost: WorkHostRef(work.workHostID), declaredDomains: [.work])
    workData.append(try recoveryProjectionEvent(
        id: "rw2", journal: workJournal, sequence: 2, previous: "rw1",
        type: TimelineEventType.runStarted, work: work,
        workHost: WorkHostRef(work.workHostID), run: run,
        declaredDomains: [.work], payload: .object(["model_id": .string("reciprocal-model")])))
    workData.append(try recoveryProjectionEvent(
        id: "rw3", journal: workJournal, sequence: 3, previous: "rw2",
        type: TimelineEventType.actionIntent, work: work,
        workHost: WorkHostRef(work.workHostID), action: action,
        declaredDomains: [.work, .externalEffects],
        payload: .object(["state": .string("proposed"), "action_kind": .string("tool")])))
    workData.append(try recoveryProjectionEvent(
        id: "rw4", journal: workJournal, sequence: 4, previous: "rw3",
        type: TimelineEventType.actionStarted, work: work,
        workHost: WorkHostRef(work.workHostID), action: action,
        declaredDomains: [.work, .externalEffects],
        payload: .object(["state": .string("running"), "action_kind": .string("tool")])))
    workData.append(try recoveryProjectionEvent(
        id: "rw5", journal: workJournal, sequence: 5, previous: "rw4",
        type: TimelineEventType.actionOutcome, work: work,
        workHost: WorkHostRef(work.workHostID), action: action,
        declaredDomains: [.work, .externalEffects],
        payload: .object([
            "state": .string(ActionExecutionState.indeterminateEffect.rawValue),
            "failure_kind": .string(ActionFailureKind.indeterminateEffect.rawValue),
            "retry_safety": .string(ActionRetrySafety.unknown.rawValue),
        ])))
    try recoveryProjectionWrite(
        workData, to: home.timelineV2WorkJournalURL(work))

    var sessionData = try recoveryProjectionEvent(
        id: "rs1", journal: sessionJournal, sequence: 1,
        type: TimelineEventType.sessionCreated, session: session,
        declaredDomains: [.session])
    sessionData.append(try recoveryProjectionEvent(
        id: "rs2", journal: sessionJournal, sequence: 2, previous: "rs1",
        type: TimelineEventType.sessionAttached, session: session, work: work,
        sessionAttachment: sessionAttachment, declaredDomains: [.session, .work],
        payload: .object(["capabilities": .array([.string("observe"), .string("control")])])))
    let workCursor = JournalCursor(journal: workJournal, eventID: "rw5", sequence: 5)
    sessionData.append(try recoveryProjectionEvent(
        id: "rs3", journal: sessionJournal, sequence: 3, previous: "rs2",
        type: TimelineEventType.sessionAttachmentCursorAdvanced, session: session,
        work: work, sessionAttachment: sessionAttachment, declaredDomains: [.session, .work],
        payload: .object(["cursor": try recoveryProjectionJSON(workCursor)])))
    let planes = Dictionary(uniqueKeysWithValues: RecoveryPlane.allCases.map {
        ($0.rawValue, JSONValue.string(RecoveryCoverageStatus.preserved.rawValue))
    })
    sessionData.append(try recoveryProjectionEvent(
        id: "rs4", journal: sessionJournal, sequence: 4, previous: "rs3",
        type: TimelineEventType.recoveryCoverage, session: session, work: work,
        workHost: WorkHostRef(work.workHostID), sessionAttachment: sessionAttachment, run: run,
        declaredDomains: [.session, .work, .context, .runtime, .externalEffects],
        payload: .object([
            "operation": .string(RecoveryOperation.coldResume.rawValue),
            "work_journal": try recoveryProjectionJSON(workJournal),
            "planes": .object(planes),
        ])))
    sessionData.append(try recoveryProjectionEvent(
        id: "rs5", journal: sessionJournal, sequence: 5, previous: "rs4",
        type: TimelineEventType.sessionAttention, session: session,
        declaredDomains: [.session],
        payload: .object(["attention": .string(SessionAttention.error.rawValue)])))
    try recoveryProjectionWrite(
        sessionData, to: home.timelineV2SessionJournalURL(session))

    let catalog = LocalTimelineCatalog.scan(home: home)
    let notification = CanonicalNotificationProjection(
        summaries: catalog.sessionSummaries,
        sourceComplete: catalog.canonicalNotificationSourceComplete)
    let candidate = try XCTUnwrap(notification.candidates.first)
    XCTAssertEqual(candidate.kind, .failedRecovery)
    XCTAssertEqual(candidate.actionIdentity.action, action)

    let projection = CanonicalWorkRecoveryProjection(catalog: catalog)
    let row = try XCTUnwrap(projection.rows.first { $0.work == work })
    let attachment = try XCTUnwrap(row.sessionAttachments.first {
        $0.session == session && $0.attachment == sessionAttachment
    })
    XCTAssertEqual(row.actions.first?.actionID, action.actionID)
    XCTAssertEqual(row.activeRun, run)
    XCTAssertFalse(attachment.isExact,
                   "Session evidence cannot be exact without the reciprocal Work attachment")
    XCTAssertTrue(attachment.recoveryCoverage.isEmpty)
    XCTAssertEqual(attachment.omittedRecoveryCoverageCount, 1)
    XCTAssertTrue(attachment.reasons.contains {
        $0.contains("reciprocal Work session attachment")
    })
    let reconciliation = try XCTUnwrap(
        projection.reconcile(notificationRoute: candidate.route))
    XCTAssertTrue(reconciliation.matchesWorkCursor)
    XCTAssertEqual(reconciliation.action?.actionID, action.actionID)
    XCTAssertFalse(reconciliation.matchesSessionEvidence)
    XCTAssertFalse(reconciliation.exact,
                   "failed-recovery route must refuse non-reciprocal Session evidence")
}

func test_canonicalWorkRecoveryProjectionReconcilesOnlyCurrentFailedRecoveryRoute() async throws {
    let home = try recoveryProjectionHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "route-session",
        work: WorkRef(workHostID: hostID, workID: "route-work"),
        runID: "route-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "route-test", modelID: "route-model",
        makeAttachmentID: { "route-attachment" })
    let turn = TurnRef("route-turn")
    _ = try await bundle.startTurn(turn)
    let permit = try await bundle.beginAction(
        action: ActionRef("route-action"), kind: .python, intent: "uncertain effect")
    _ = try await bundle.finishAction(
        permit, state: .indeterminateEffect, retrySafety: .unknown,
        failureKind: .indeterminateEffect)
    _ = try await bundle.finishTurn(turn, outcome: .failed)

    let firstCatalog = LocalTimelineCatalog.scan(home: home)
    let firstNotification = CanonicalNotificationProjection(
        summaries: firstCatalog.sessionSummaries,
        sourceComplete: firstCatalog.canonicalNotificationSourceComplete)
    let candidate = try XCTUnwrap(firstNotification.candidates.first)
    XCTAssertEqual(candidate.kind, .failedRecovery)
    let firstRecovery = CanonicalWorkRecoveryProjection(catalog: firstCatalog)
    let current = try XCTUnwrap(firstRecovery.reconcile(notificationRoute: candidate.route))
    XCTAssertTrue(current.exact)
    XCTAssertEqual(current.action?.actionID, permit.action.actionID)

    _ = try await bundle.changeModel("route-model-new")
    let secondCatalog = LocalTimelineCatalog.scan(home: home)
    let secondNotification = CanonicalNotificationProjection(
        summaries: secondCatalog.sessionSummaries,
        sourceComplete: secondCatalog.canonicalNotificationSourceComplete)
    XCTAssertNil(secondNotification.candidate(matching: candidate.route))
    let stale = try XCTUnwrap(
        CanonicalWorkRecoveryProjection(catalog: secondCatalog)
            .reconcile(notificationRoute: candidate.route))
    XCTAssertFalse(stale.exact)
    XCTAssertFalse(stale.matchesWorkCursor)

    _ = try await bundle.finishRun(outcome: .failed)
    try await bundle.closeChecked()
}
