import Foundation
@testable import AviaryCore

private let inventoryHost = WorkHostRef("inventory-host")
private let inventoryWork = WorkRef(workHostID: inventoryHost.workHostID, workID: "inventory-work")
private let inventoryJournal = JournalRef.work(inventoryWork, journalID: "inventory-journal")
private let inventorySession = SessionRef("inventory-session")
private let inventoryAttachment = SessionAttachmentRef("inventory-attachment")
private let inventoryRun = RunRef("inventory-run")

private func inventoryAdmission() -> ProviderAdmission {
    ProviderAdmission(
        purpose: .normal,
        rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
            "id": .string("inventory-model"), "provider": .string("inventory-provider")]))))
}

private func inventoryEvent(
    _ sequence: Int, _ type: String, handle: HandleRef? = nil, cause: Int? = nil,
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: "inventory-\(sequence)", journal: inventoryJournal, sequence: sequence,
        previousEventID: sequence == 1 ? nil : "inventory-\(sequence - 1)",
        causedByEventID: cause.map { EventRef(journal: inventoryJournal, eventID: "inventory-\($0)") },
        session: inventorySession, work: inventoryWork, workHost: inventoryHost,
        sessionAttachment: inventoryAttachment, run: inventoryRun, handle: handle,
        actor: TimelineActor(actorID: "inventory-host", kind: "work-host"),
        hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)), type: type,
        declaredDomains: type.hasPrefix("agent_handle.")
            ? [.work, .runtime, .externalEffects] : [], payload: payload)
}

private func inventoryChildPrefix(
    _ id: String, queued: Int, started: Int,
    finality: ProviderUsage.ReportFinality = .finalReport,
    settle: Bool = true, terminalize: Bool = false
) throws -> [TimelineEvent] {
    let handle = HandleRef(id)
    let origin = WorkAgentHandleOrigin(
        work: inventoryWork, workHost: inventoryHost, session: inventorySession,
        sessionAttachment: inventoryAttachment, run: inventoryRun)
    let digest = "sha256:" + String(repeating: "a", count: 64)
    let queuedPayload = WorkAgentHandleQueuedPayload(
        origin: origin, label: "not exported", requestBody: TimelineBodyReference(
            authority: inventoryJournal, referenceID: digest, mediaType: "text/plain",
            byteCount: 1, digest: digest))
    let queuedValue = try XCTUnwrap(
        JSONValue.parse(JSONEncoder().encode(queuedPayload)))
    let admission = inventoryAdmission()
    let startValue = JSONValue.object([
        "ordinal": .string("1"), "admission": admission.timelineValue])
    let settlement = ProviderSettlement(
        admission: admission,
        report: ProviderUsage.RawReport(
            inputTokens: 3, outputTokens: 2, cacheReadTokens: 0, cacheWriteTokens: 0,
            reportedTotalTokens: 5, inputAccounting: .cacheInclusive),
        finality: finality)
    let settleValue = JSONValue.object([
        "ordinal": .string("1"), "settlement": settlement.timelineValue,
        "state": .string(finality == .finalReport ? "succeeded" : "indeterminate_effect")])
    var events = [
        inventoryEvent(queued, TimelineEventType.agentHandleQueued, handle: handle,
                       payload: queuedValue),
        inventoryEvent(started, TimelineEventType.agentHandleStarted, handle: handle,
                       cause: queued),
        inventoryEvent(started + 1, TimelineEventType.agentHandleProviderStarted,
                       handle: handle, cause: started, payload: startValue),
    ]
    if settle {
        events.append(inventoryEvent(
            started + 2, TimelineEventType.agentHandleProviderSettled,
            handle: handle, cause: started + 1, payload: settleValue))
    }
    if terminalize {
        let terminal = WorkAgentHandleTerminalPayload(
            outcome: .failed,
            cleanup: WorkAgentHandleCleanupProof(
                state: .quiesced,
                evidence: EventRef(
                    journal: inventoryJournal, eventID: "inventory-\(started + 2)")))
        let terminalValue = try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(terminal)))
        let terminalSequence = started + (settle ? 3 : 2)
        events.append(inventoryEvent(
            terminalSequence, TimelineEventType.agentHandleTerminal,
            handle: handle, cause: started,
            payload: terminalValue))
        let reap = WorkAgentHandleReapedPayload(reason: .explicitPolicy)
        let reapValue = try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(reap)))
        events.append(inventoryEvent(
            terminalSequence + 1, TimelineEventType.agentHandleReaped,
            handle: handle, cause: terminalSequence, payload: reapValue))
    }
    return events
}

private func inventorySnapshot(
    firstFinality: ProviderUsage.ReportFinality = .finalReport,
    secondPending: Bool = false
) throws -> WorkSnapshot {
    let secondQueued = firstFinality == .unconfirmed ? 10 : 8
    let events = [
        inventoryEvent(1, TimelineEventType.workCreated),
        inventoryEvent(2, TimelineEventType.sessionAttached),
        inventoryEvent(3, TimelineEventType.runStarted),
    ] + (try inventoryChildPrefix(
        "child-a", queued: 4, started: 5, finality: firstFinality,
        terminalize: firstFinality == .unconfirmed))
        + (try inventoryChildPrefix(
            "child-b", queued: secondQueued, started: secondQueued + 1,
            settle: !secondPending))
    let snapshot = WorkReducer.reduce(events)
    XCTAssertTrue(snapshot.semanticProjectionValid, snapshot.corruptionReasons.joined(separator: ";"))
    return snapshot
}

private func inventoryDirectAggregate() -> ProviderUsageAggregate {
    ProviderUsageAggregate(
        started: 1, settled: 1,
        knownFloors: .init(inputTokens: 4, outputTokens: 2, totalTokens: 6))
}

private func unvalidatedInventoryProjection() throws -> WorkServiceAttachedWorkProjection {
    let client = ClientRef("unvalidated-inventory-client")
    let clientAttachment = ClientAttachmentRef("unvalidated-inventory-attachment")
    let session = SessionRef("unvalidated-inventory-session")
    let sessionJournal = JournalRef.session(
        session, journalID: "unvalidated-inventory-session-journal",
        authority: TimelineAuthorityRef(inventoryHost.workHostID))
    let attachment = WorkServiceClientAttachment(
        attachment: clientAttachment, client: client, session: nil, sessionJournal: nil,
        sessionAttachment: nil,
        authorization: WorkServiceAuthorizationOutcome(requested: [], granted: [], denied: []))
    let descriptor = try WorkServiceWorkDescriptor(
        work: inventoryWork, journal: inventoryJournal, recordedDisposition: .reusable,
        execution: .idle, currentRun: nil, currentRunSession: nil,
        currentRunSessionAttachment: nil, hostObservation: nil, attachments: [attachment])
    var work = WorkSnapshot()
    work.journal = inventoryJournal
    work.work = inventoryWork
    work.workHost = inventoryHost
    work.lifecycle = .active
    var sessionSnapshot = SessionSnapshot()
    sessionSnapshot.journal = sessionJournal
    sessionSnapshot.session = session
    sessionSnapshot.lifecycle = .active
    return WorkServiceAttachedWorkProjection(
        descriptor: descriptor, attachment: attachment, capabilities: [],
        workSnapshot: work, sessionSnapshot: sessionSnapshot,
        workCursor: JournalCursor(journal: inventoryJournal, sequence: 0),
        sessionCursor: JournalCursor(journal: sessionJournal, sequence: 0),
        workSourceCompleteness: .complete, sessionSourceCompleteness: .complete)
}

let casesCanonicalWorkUsageInventory: [Case] = [
    ("work usage inventory: public projection construction cannot inject inventory", {
        let projection = try unvalidatedInventoryProjection()
        XCTAssertNil(projection.usageInventory)
    }),
    ("work usage inventory: direct and child totals remain separate", {
        var snapshot = try inventorySnapshot()
        snapshot.providerUsage = inventoryDirectAggregate()
        let inventory = try CanonicalWorkUsageInventory(
            snapshot: snapshot, expectedWork: inventoryWork,
            expectedJournal: inventoryJournal, omittedChildCount: 0)
        XCTAssertEqual(inventory.direct?.startedCrossings, 1)
        XCTAssertEqual(inventory.children.count, 2)
        XCTAssertEqual(inventory.combinedAvailability, .complete)
        XCTAssertEqual(inventory.childrenTotal?.startedCrossings, 2)
        XCTAssertEqual(inventory.childrenTotal?.knownTokenFloor, 10)
        XCTAssertEqual(inventory.combined?.startedCrossings, 3)
        XCTAssertEqual(inventory.combined?.knownTokenFloor, 16)
        XCTAssertEqual(inventory.combined?.settledCrossings, 3)
        // A second Session attachment would receive this same Work-qualified value, not a
        // second contribution to the aggregate.
        let secondRead = try CanonicalWorkUsageInventory(
            snapshot: snapshot, expectedWork: inventoryWork,
            expectedJournal: inventoryJournal, omittedChildCount: 0)
        XCTAssertEqual(inventory, secondRead)
    }),
    ("work usage inventory: pending, unknown, and reaped child evidence stays explicit", {
        let snapshot = try inventorySnapshot(firstFinality: .unconfirmed, secondPending: true)
        // The real reducer supplies the provider continuation; the inventory retains its
        // lower-bound shape and never infers a zero for a child whose terminal report is absent.
        let inventory = try CanonicalWorkUsageInventory(
            snapshot: snapshot, expectedWork: inventoryWork,
            expectedJournal: inventoryJournal, omittedChildCount: 0)
        XCTAssertEqual(inventory.children.count, 2)
        XCTAssertTrue(inventory.children.contains { $0.usage.hasUnresolvedAccounting })
        XCTAssertEqual(inventory.combinedAvailability, .complete)
    }),
    ("work usage inventory: omission, unknown domain, invalid child, and overflow fail closed", {
        let snapshot = try inventorySnapshot()
        let omitted = try CanonicalWorkUsageInventory(
            snapshot: snapshot, expectedWork: inventoryWork,
            expectedJournal: inventoryJournal, omittedChildCount: 1)
        XCTAssertNil(omitted.combined)
        XCTAssertEqual(omitted.combinedAvailability, .childFactsOmitted)
        XCTAssertEqual(omitted.direct?.startedCrossings, 0)

        var unknown = snapshot
        unknown.unknownDomains.insert(.runtime)
        let unknownInventory = try CanonicalWorkUsageInventory(
            snapshot: unknown, expectedWork: inventoryWork,
            expectedJournal: inventoryJournal, omittedChildCount: 0)
        XCTAssertEqual(unknownInventory.children.count, 0)
        XCTAssertEqual(unknownInventory.combinedAvailability, .childFactsUnavailable)
        XCTAssertNil(unknownInventory.direct)
        XCTAssertEqual(unknownInventory.directAvailability, .unavailable)

        var unknownEvent = snapshot
        unknownEvent.unknownEvents = [UnknownTimelineEvent(
            event: inventoryEvent(12, "future.work.fact"), journalOffset: 12,
            affectedDomains: [.work])]
        do {
            _ = try CanonicalWorkUsageInventory(
                snapshot: unknownEvent, expectedWork: inventoryWork,
                expectedJournal: inventoryJournal, omittedChildCount: 0)
            XCTFail("unknown Work events must not be treated as canonical usage")
        } catch CanonicalWorkUsageInventory.Error.notCanonical {
            // expected
        }

        var invalid = snapshot
        let child = try XCTUnwrap(invalid.agentHandles.removeValue(forKey: "child-a"))
        invalid.agentHandles["forged-key"] = child
        let invalidInventory = try CanonicalWorkUsageInventory(
            snapshot: invalid, expectedWork: inventoryWork,
            expectedJournal: inventoryJournal, omittedChildCount: 0)
        XCTAssertEqual(invalidInventory.invalidChildCount, 1)
        XCTAssertEqual(invalidInventory.combinedAvailability, .childFactsInvalid)

        var overflowing = snapshot
        overflowing.providerUsage = ProviderUsageAggregate(
            started: 1, settled: 1,
            knownFloors: .init(inputTokens: Int.max, totalTokens: Int.max))
        let overflowInventory = try CanonicalWorkUsageInventory(
            snapshot: overflowing, expectedWork: inventoryWork,
            expectedJournal: inventoryJournal, omittedChildCount: 0)
        XCTAssertNil(overflowInventory.combined)
        XCTAssertEqual(overflowInventory.combinedAvailability, .arithmeticOverflow)
        XCTAssertEqual(overflowInventory.childrenTotal?.knownTokenFloor, 10)
        XCTAssertTrue(overflowInventory.childUsageComplete)
        XCTAssertEqual(overflowInventory.direct?.knownTokenFloor, Int.max)
    }),
]
