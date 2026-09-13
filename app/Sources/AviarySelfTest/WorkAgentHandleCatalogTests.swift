import Foundation
@testable import AviaryCore

private let catalogHandleWork = WorkRef(workHostID: "catalog-agent-host", workID: "catalog-agent-work")
private let catalogHandleHost = WorkHostRef(catalogHandleWork.workHostID)
private let catalogHandleJournal = JournalRef.work(catalogHandleWork, journalID: "catalog-agent-journal")
private let catalogHandleSession = SessionRef("catalog-agent-session")
private let catalogHandleAttachment = SessionAttachmentRef("catalog-agent-attachment")
private let catalogHandleRun = RunRef("catalog-agent-run")

private func catalogHandleEvent(_ id: String, handle: HandleRef) -> TimelineEvent {
    TimelineEvent(
        eventID: id, journal: catalogHandleJournal, sequence: 1,
        session: catalogHandleSession, work: catalogHandleWork, workHost: catalogHandleHost,
        sessionAttachment: catalogHandleAttachment, run: catalogHandleRun, handle: handle,
        actor: TimelineActor(actorID: "catalog-agent-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 1), type: TimelineEventType.agentHandleTerminal,
        declaredDomains: [.work, .runtime, .externalEffects])
}

private func catalogHandleSnapshot(
    id: String, state: WorkAgentHandleState,
    outcome: WorkAgentHandleTerminalOutcome? = nil,
    cleanup: WorkAgentHandleCleanupState? = nil,
    origin suppliedOrigin: WorkAgentHandleOrigin? = nil
) -> WorkAgentHandleSnapshot {
    let handle = HandleRef(id)
    let origin = suppliedOrigin ?? WorkAgentHandleOrigin(
        work: catalogHandleWork, workHost: catalogHandleHost, session: catalogHandleSession,
        sessionAttachment: catalogHandleAttachment, run: catalogHandleRun)
    let queued = EventRef(journal: catalogHandleJournal, eventID: "queued-\(id)")
    var value = WorkAgentHandleSnapshot(
        handle: handle, origin: origin, label: "private-\(id)",
        deadline: Date(timeIntervalSince1970: 100),
        requestBody: TimelineBodyReference(
            authority: catalogHandleJournal, referenceID: "body-\(id)",
            mediaType: "application/json", byteCount: 1, digest: "sha256:" + String(repeating: "a", count: 64)),
        queuedEvent: queued)
    value.state = state
    value.latestLifecycleEvent = EventRef(
        journal: catalogHandleJournal, eventID: "latest-\(id)")
    if let outcome, let cleanup {
        let event = catalogHandleEvent("terminal-\(id)", handle: handle)
        value.terminalEvidence = WorkAgentHandleTerminalEvidence(
            outcome: outcome, cleanup: WorkAgentHandleCleanupProof(state: cleanup),
            event: WorkAgentHandleEventEvidence(event))
    }
    return value
}

private func catalogHandleRow(
    _ snapshots: [WorkAgentHandleSnapshot], unknownDomains: Set<TimelineDomain> = []
) -> LocalTimelineCatalog.WorkRow {
    var snapshot = WorkSnapshot()
    snapshot.work = catalogHandleWork
    snapshot.journal = catalogHandleJournal
    snapshot.workHost = catalogHandleHost
    snapshot.lifecycle = .completed
    snapshot.execution = .idle
    snapshot.agentHandles = Dictionary(uniqueKeysWithValues: snapshots.map {
        ($0.handle.handleID, $0)
    })
    snapshot.unknownDomains = unknownDomains
    return LocalTimelineCatalog.WorkRow(
        locatorID: "catalog-agent-locator", work: catalogHandleWork,
        journal: catalogHandleJournal, snapshot: snapshot, read: nil, available: true,
        reasons: [], limit: 16)
}

func test_workAgentHandleCatalogFactIsPrivateAndCompletionAware() throws {
    let snapshot = catalogHandleSnapshot(
        id: "queued-child", state: .queued)
    let fact = LocalTimelineCatalog.AgentHandleFact(snapshot)
    XCTAssertEqual(fact.handleID, "queued-child")
    XCTAssertEqual(fact.origin.work, catalogHandleWork)
    XCTAssertTrue(fact.blocksWorkCompletion)
    XCTAssertNil(fact.terminalOutcome)
    XCTAssertNil(fact.cleanupState)
    let encoded = String(decoding: try JSONEncoder().encode(fact), as: UTF8.self)
    XCTAssertFalse(encoded.contains("private-queued-child"))
    XCTAssertFalse(encoded.contains("request_body"))
    XCTAssertEqual(fact.deadline, Date(timeIntervalSince1970: 100))
    let decoded = try JSONDecoder().decode(
        LocalTimelineCatalog.AgentHandleFact.self, from: Data(encoded.utf8))
    XCTAssertEqual(decoded, fact)
}

func test_workAgentHandleCatalogRetainsBlockersFirstAndReportsOmissions() throws {
    let row = catalogHandleRow([
        catalogHandleSnapshot(id: "z-terminal", state: .terminal,
                              outcome: .succeeded, cleanup: .quiesced),
        catalogHandleSnapshot(id: "a-running", state: .running),
        catalogHandleSnapshot(id: "m-indeterminate", state: .terminal,
                              outcome: .indeterminate, cleanup: .indeterminate),
    ])
    XCTAssertEqual(row.agentHandles.map(\.handleID), ["a-running", "m-indeterminate", "z-terminal"])
    let projection = CanonicalWorkRecoveryProjection(
        works: [row], limits: .init(maxAgentHandleFactsPerRow: 1))
    let recovered = try XCTUnwrap(projection.rows.first)
    XCTAssertEqual(recovered.agentHandles.map(\.handleID), ["a-running"])
    XCTAssertEqual(recovered.omittedAgentHandleCount, 2)
    XCTAssertEqual(recovered.completionBlockingAgentHandleIDs, ["a-running"])
    XCTAssertEqual(recovered.omittedCompletionBlockingAgentHandleCount, 1)
    XCTAssertEqual(recovered.disposition, .uncertain)
}

func test_workAgentHandleCatalogHidesUnknownDomainsAndDoesNotFlattenChildren() throws {
    let row = catalogHandleRow(
        [catalogHandleSnapshot(id: "hidden-child", state: .running)],
        unknownDomains: [.runtime])
    XCTAssertTrue(row.agentHandles.isEmpty)
    let projection = CanonicalWorkRecoveryProjection(works: [row])
    let recovered = try XCTUnwrap(projection.rows.first)
    XCTAssertTrue(recovered.agentHandles.isEmpty)
    XCTAssertTrue(recovered.completionBlockingAgentHandleIDs.isEmpty)
    XCTAssertEqual(recovered.disposition, .uncertain)
}

func test_workAgentHandleCatalogTerminalQuiescedAndReapedDoNotBlock() throws {
    let terminal = catalogHandleSnapshot(
        id: "terminal-child", state: .terminal, outcome: .succeeded, cleanup: .quiesced)
    let reaped = catalogHandleSnapshot(
        id: "reaped-child", state: .reaped, outcome: .canceled, cleanup: .quiesced)
    let row = catalogHandleRow([terminal, reaped])
    XCTAssertTrue(row.agentHandles.allSatisfy { !$0.blocksWorkCompletion })
    let projection = CanonicalWorkRecoveryProjection(works: [row])
    let recovered = try XCTUnwrap(projection.rows.first)
    XCTAssertTrue(recovered.completionBlockingAgentHandleIDs.isEmpty)
    XCTAssertEqual(recovered.disposition, .completedEvidence)
}

private struct CatalogFixtureProjection {
    let workRef: WorkRef
    let sessionRef: SessionRef
    let attachment: SessionAttachmentRef
    let session: SessionSnapshot
    let work: WorkSnapshot
    let sessionRead: TimelineJournalReadResult
    let workRead: TimelineJournalReadResult
    let sessionJournal: JournalRef
    let workJournal: JournalRef
    let cursor: JournalCursor
}

private func catalogFixtureRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/ReaderCensus")
}

private func catalogFixtureRead(
    _ url: URL, prefixLines: Int? = nil, journal: JournalRef
) throws -> TimelineJournalReadResult {
    let data = try Data(contentsOf: url)
    let selected: Data
    if let prefixLines {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        selected = Data(lines.prefix(prefixLines).flatMap { line in
            Array(line) + [0x0A]
        })
    } else {
        selected = data
    }
    return TimelineJournalReader.read(
        selected, journal: journal,
        actor: TimelineActor(actorID: "catalog-fixture-reader", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
}

private func catalogFixtureProjection() throws -> CatalogFixtureProjection {
    let root = catalogFixtureRoot()
    let workRef = WorkRef(workHostID: "census-host", workID: "census-work")
    let sessionRef = SessionRef("census-session")
    let attachment = SessionAttachmentRef("sa-main")
    let workJournal = JournalRef.work(
        workRef, journalID: "work-journal")
    let sessionJournal = JournalRef.session(
        sessionRef, journalID: "session-journal",
        authority: TimelineAuthorityRef("session-authority"))
    let workRead = try catalogFixtureRead(
        root.appending(path: "variants/work-agent-handle-lifecycle.jsonl"), journal: workJournal)
    let sessionRead = try catalogFixtureRead(
        root.appending(path: "session.jsonl"), prefixLines: 3, journal: sessionJournal)
    let work = WorkReducer.reduce(workRead.records.map(\.event))
    let session = SessionReducer.reduce(sessionRead.records.map(\.event))
    let last = try XCTUnwrap(workRead.records.last?.event)
    return CatalogFixtureProjection(
        workRef: workRef, sessionRef: sessionRef, attachment: attachment,
        session: session, work: work, sessionRead: sessionRead, workRead: workRead,
        sessionJournal: sessionJournal, workJournal: workJournal,
        cursor: JournalCursor(journal: workJournal, eventID: last.eventID, sequence: last.sequence))
}

private func catalogFixtureSummary(
    _ fixture: CatalogFixtureProjection,
    work: WorkSnapshot? = nil,
    session: SessionSnapshot? = nil,
    cursor: JournalCursor? = nil,
    includeWorkRead: Bool = true
) -> CanonicalSessionCatalogSummary? {
    SessionCatalog.summarizeCanonical(
        session: session ?? fixture.session,
        works: [work ?? fixture.work],
        cursors: [fixture.attachment.attachmentID: cursor ?? fixture.cursor],
        sessionRead: fixture.sessionRead,
        workReads: includeWorkRead ? [fixture.workJournal: fixture.workRead] : [:])
}

private func assertCatalogSummaryHidesAgentFacts(
    _ summary: CanonicalSessionCatalogSummary?, line: Int = #line
) throws {
    let summary = try XCTUnwrap(summary, line: line)
    let work = try XCTUnwrap(summary.work.first, line: line)
    XCTAssertTrue(work.agentHandles.isEmpty, line: line)
    XCTAssertTrue(work.completionBlockingAgentHandleIDs.isEmpty, line: line)
}

func test_workAgentHandleCatalogCanonicalSummaryRequiresExactReciprocalRead() throws {
    let fixture = try catalogFixtureProjection()
    let exact = try XCTUnwrap(catalogFixtureSummary(fixture))
    let exactWork = try XCTUnwrap(exact.work.first)
    XCTAssertEqual(exactWork.agentHandles.map(\.handleID), ["agent-b", "agent-a"])
    XCTAssertEqual(exactWork.completionBlockingAgentHandleIDs, ["agent-b"])

    let stale = JournalCursor(journal: fixture.workJournal, eventID: "b-started", sequence: 8)
    try assertCatalogSummaryHidesAgentFacts(
        catalogFixtureSummary(fixture, cursor: stale))
    try assertCatalogSummaryHidesAgentFacts(
        catalogFixtureSummary(fixture, includeWorkRead: false))
}

func test_workAgentHandleCatalogCanonicalSummaryRejectsForeignDetachedAndUnknownFacts() throws {
    let fixture = try catalogFixtureProjection()
    var foreign = fixture.work
    foreign.work = WorkRef(workHostID: "foreign-host", workID: "foreign-work")
    try assertCatalogSummaryHidesAgentFacts(catalogFixtureSummary(fixture, work: foreign))

    var missingReciprocal = fixture.work
    missingReciprocal.sessionAttachments = [:]
    try assertCatalogSummaryHidesAgentFacts(
        catalogFixtureSummary(fixture, work: missingReciprocal))

    var detachedSession = fixture.session
    if var attachment = detachedSession.attachments[fixture.attachment.attachmentID] {
        attachment.isAttached = false
        detachedSession.attachments[fixture.attachment.attachmentID] = attachment
    }
    try assertCatalogSummaryHidesAgentFacts(
        catalogFixtureSummary(fixture, session: detachedSession))

    for unknownDomain in [TimelineDomain.work, .session, .runtime, .externalEffects] {
        var unknown = fixture.work
        unknown.unknownDomains.insert(unknownDomain)
        try assertCatalogSummaryHidesAgentFacts(
            catalogFixtureSummary(fixture, work: unknown))
    }
    for unknownDomain in [TimelineDomain.work, .session] {
        var unknown = fixture.session
        unknown.unknownDomains.insert(unknownDomain)
        try assertCatalogSummaryHidesAgentFacts(
            catalogFixtureSummary(fixture, session: unknown))
    }
}

func test_workAgentHandleCatalogRejectsMalformedFactCodableStates() throws {
    let fact = LocalTimelineCatalog.AgentHandleFact(
        catalogHandleSnapshot(id: "decode-child", state: .queued))
    var object = try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(fact))?.objectValue)
    object["state"] = .string(WorkAgentHandleState.terminal.rawValue)
    var rejected = false
    do {
        _ = try JSONDecoder().decode(
            LocalTimelineCatalog.AgentHandleFact.self,
            from: try JSONEncoder().encode(JSONValue.object(object)))
    } catch {
        rejected = true
    }
    XCTAssertTrue(rejected)

    object = try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(fact))?.objectValue)
    object["state"] = .string(WorkAgentHandleState.terminal.rawValue)
    object["terminalOutcome"] = .string(WorkAgentHandleTerminalOutcome.succeeded.rawValue)
    object["cleanupState"] = .string(WorkAgentHandleCleanupState.notStarted.rawValue)
    rejected = false
    do {
        _ = try JSONDecoder().decode(
            LocalTimelineCatalog.AgentHandleFact.self,
            from: try JSONEncoder().encode(JSONValue.object(object)))
    } catch {
        rejected = true
    }
    XCTAssertTrue(rejected)

    object = try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(fact))?.objectValue)
    object["state"] = .string(WorkAgentHandleState.reaped.rawValue)
    object["terminalOutcome"] = .string(WorkAgentHandleTerminalOutcome.canceled.rawValue)
    object["cleanupState"] = .string(WorkAgentHandleCleanupState.indeterminate.rawValue)
    rejected = false
    do {
        _ = try JSONDecoder().decode(
            LocalTimelineCatalog.AgentHandleFact.self,
            from: try JSONEncoder().encode(JSONValue.object(object)))
    } catch {
        rejected = true
    }
    XCTAssertTrue(rejected)

    object = try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(fact))?.objectValue)
    var oversizedOrigin = try XCTUnwrap(object["origin"]?.objectValue)
    oversizedOrigin["session"] = .object([
        "sessionID": .string(String(repeating: "o", count: 1_025))
    ])
    object["origin"] = .object(oversizedOrigin)
    rejected = false
    do {
        _ = try JSONDecoder().decode(
            LocalTimelineCatalog.AgentHandleFact.self,
            from: try JSONEncoder().encode(JSONValue.object(object)))
    } catch {
        rejected = true
    }
    XCTAssertTrue(rejected)

    var malformedSnapshot = catalogHandleSnapshot(id: "internal-malformed", state: .queued)
    malformedSnapshot.state = .terminal
    do {
        _ = try JSONEncoder().encode(LocalTimelineCatalog.AgentHandleFact(malformedSnapshot))
        XCTFail("an invalid internal fact cannot serialize a non-round-trippable container")
    } catch {}
    let longOrigin = WorkAgentHandleOrigin(
        work: catalogHandleWork, workHost: catalogHandleHost,
        session: SessionRef(String(repeating: "s", count: 1_024)),
        sessionAttachment: catalogHandleAttachment, run: catalogHandleRun)
    let longFact = LocalTimelineCatalog.AgentHandleFact(
        catalogHandleSnapshot(id: "long-canonical-origin", state: .running, origin: longOrigin))
    let restored = try JSONDecoder().decode(
        LocalTimelineCatalog.AgentHandleFact.self, from: JSONEncoder().encode(longFact))
    XCTAssertEqual(restored, longFact, "catalog bounds must not reject canonical 1,024-byte identities")
    let malformedProjection = CanonicalWorkRecoveryProjection(
        works: [catalogHandleRow([malformedSnapshot])])
    let malformedRow = try XCTUnwrap(malformedProjection.rows.first)
    XCTAssertEqual(malformedRow.disposition, .uncertain)
    XCTAssertTrue(malformedRow.agentHandles.isEmpty)
    XCTAssertEqual(malformedRow.omittedAgentHandleCount, 1)
    XCTAssertEqual(malformedRow.omittedCompletionBlockingAgentHandleCount, 1)
}

func test_workAgentHandleCatalogRecoveryRejectsOversizedNestedOrigin() throws {
    let oversizedOrigin = WorkAgentHandleOrigin(
        work: catalogHandleWork, workHost: catalogHandleHost,
        session: SessionRef(String(repeating: "s", count: 64)),
        sessionAttachment: catalogHandleAttachment, run: catalogHandleRun)
    let row = catalogHandleRow([
        catalogHandleSnapshot(
            id: "oversized-origin", state: .running, origin: oversizedOrigin)
    ])
    let projection = CanonicalWorkRecoveryProjection(
        works: [row], limits: .init(maxIdentityCharacters: 40))
    let recovered = try XCTUnwrap(projection.rows.first)
    XCTAssertEqual(recovered.disposition, .uncertain)
    XCTAssertTrue(recovered.agentHandles.isEmpty)
    XCTAssertTrue(recovered.completionBlockingAgentHandleIDs.isEmpty)
    XCTAssertEqual(recovered.omittedAgentHandleCount, 1)

    let validProjection = CanonicalWorkRecoveryProjection(
        works: [catalogHandleRow([
            catalogHandleSnapshot(id: "valid-origin", state: .running)
        ])], limits: .init(maxIdentityCharacters: 40))
    let validRow = try XCTUnwrap(validProjection.rows.first)
    XCTAssertEqual(validRow.agentHandles.map(\.handleID), ["valid-origin"])
}

let casesWorkAgentHandleCatalog: [Case] = [
    ("phase5 catalog: decoded unknown-domain rows cannot expose child facts", {
        let original = catalogHandleRow([catalogHandleSnapshot(id: "running", state: .running)])
        for domain in [TimelineDomain.work, .runtime, .externalEffects] {
            var object = try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(original))?.objectValue)
            object["unknownDomains"] = .array([.string(domain.rawValue)])
            let row = try JSONDecoder().decode(LocalTimelineCatalog.WorkRow.self,
                from: JSONEncoder().encode(JSONValue.object(object)))
            let recovered = try XCTUnwrap(CanonicalWorkRecoveryProjection(works: [row]).rows.first)
            XCTAssertEqual(recovered.disposition, .uncertain)
            XCTAssertTrue(recovered.agentHandles.isEmpty)
            XCTAssertTrue(recovered.completionBlockingAgentHandleIDs.isEmpty)
            XCTAssertEqual(recovered.omittedAgentHandleCount, 1)
            XCTAssertEqual(recovered.omittedCompletionBlockingAgentHandleCount, 1)
        }
    }),
    ("phase5 catalog: Agent Handle facts are private and completion-aware", {
        try test_workAgentHandleCatalogFactIsPrivateAndCompletionAware()
    }),
    ("phase5 catalog: blockers survive recovery bounds first", {
        try test_workAgentHandleCatalogRetainsBlockersFirstAndReportsOmissions()
    }),
    ("phase5 catalog: unknown domains hide child facts", {
        try test_workAgentHandleCatalogHidesUnknownDomainsAndDoesNotFlattenChildren()
    }),
    ("phase5 catalog: quiescent terminal children do not block", {
        try test_workAgentHandleCatalogTerminalQuiescedAndReapedDoNotBlock()
    }),
    ("phase5 catalog: canonical summaries require reciprocal aligned reads", {
        try test_workAgentHandleCatalogCanonicalSummaryRequiresExactReciprocalRead()
    }),
    ("phase5 catalog: canonical summaries reject foreign detached and unknown facts", {
        try test_workAgentHandleCatalogCanonicalSummaryRejectsForeignDetachedAndUnknownFacts()
    }),
    ("phase5 catalog: malformed Codable states are rejected", {
        try test_workAgentHandleCatalogRejectsMalformedFactCodableStates()
    }),
    ("phase5 catalog: recovery rejects oversized nested origins", {
        try test_workAgentHandleCatalogRecoveryRejectsOversizedNestedOrigin()
    }),
]
