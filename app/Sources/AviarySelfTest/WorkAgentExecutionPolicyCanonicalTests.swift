import Foundation
@testable import AviaryCore

private let policyWork = WorkRef(workHostID: "policy-host", workID: "policy-work")
private let policyHost = WorkHostRef(policyWork.workHostID)
private let policyJournal = JournalRef.work(policyWork, journalID: "policy-journal")
private let policySession = SessionRef("policy-session")
private let policyAttachment = SessionAttachmentRef("policy-attachment")
private let policyRun = RunRef("policy-run")
private let policyHandle = HandleRef("policy-handle")

private func policyBody(_ character: Character = "a") -> TimelineBodyReference {
    let digest = "sha256:" + String(repeating: character, count: 64)
    return TimelineBodyReference(
        authority: policyJournal, referenceID: digest, mediaType: "text/plain",
        byteCount: 1, digest: digest)
}

private func policyEvent(
    _ type: String, _ id: String, _ sequence: Int, previous: String?,
    handle: HandleRef? = nil, causedBy: EventRef? = nil,
    payload: JSONValue = .object([:]), at: TimeInterval? = nil
) -> TimelineEvent {
    let agentEvent = type.hasPrefix("agent_handle.")
    let sessionEvent = type == TimelineEventType.sessionAttached || type == TimelineEventType.runStarted
    return TimelineEvent(
        eventID: id, journal: policyJournal, sequence: sequence,
        previousEventID: previous, causedByEventID: causedBy,
        session: sessionEvent || agentEvent ? policySession : nil, work: policyWork,
        workHost: policyHost,
        sessionAttachment: sessionEvent || agentEvent ? policyAttachment : nil,
        run: type == TimelineEventType.runStarted || agentEvent ? policyRun : nil, handle: handle,
        actor: TimelineActor(actorID: "policy-test", kind: "self-test"),
        hostRecordedAt: Date(timeIntervalSince1970: at ?? Double(sequence)),
        type: type,
        declaredDomains: agentEvent ? [.work, .runtime, .externalEffects] : [],
        payload: payload)
}

private func policyJSON<T: Encodable>(_ value: T) -> JSONValue {
    JSONValue.parse(try! JSONEncoder().encode(value))!
}

private func policyPrefix() -> (events: [TimelineEvent], origin: WorkAgentHandleOrigin) {
    let origin = WorkAgentHandleOrigin(
        work: policyWork, workHost: policyHost, session: policySession,
        sessionAttachment: policyAttachment, run: policyRun)
    return (
        [
            policyEvent(TimelineEventType.workCreated, "policy-1", 1, previous: nil),
            policyEvent(TimelineEventType.sessionAttached, "policy-2", 2, previous: "policy-1"),
            policyEvent(
                TimelineEventType.runStarted, "policy-3", 3, previous: "policy-2"),
        ], origin)
}

private func policyQueued(
    _ origin: WorkAgentHandleOrigin, limits: WorkAgentExecutionLimits = .unlimited
) -> TimelineEvent {
    policyEvent(
        TimelineEventType.agentHandleQueued, "policy-4", 4, previous: "policy-3",
        handle: policyHandle,
        payload: policyJSON(WorkAgentHandleQueuedPayload(
            origin: origin, label: "bounded child", requestBody: policyBody(),
            executionLimits: limits)))
}

private func policyStarted(_ queued: TimelineEvent) -> TimelineEvent {
    policyEvent(
        TimelineEventType.agentHandleStarted, "policy-5", 5, previous: queued.eventID,
        handle: policyHandle,
        causedBy: EventRef(journal: policyJournal, eventID: queued.eventID))
}

private func policyProviderStarted(
    _ previous: TimelineEvent, _ admission: ProviderAdmission
) -> TimelineEvent {
    policyEvent(
        TimelineEventType.agentHandleProviderStarted, "policy-6", 6,
        previous: previous.eventID, handle: policyHandle,
        causedBy: EventRef(journal: policyJournal, eventID: previous.eventID),
        payload: .object([
            "ordinal": .string("1"), "admission": admission.timelineValue,
        ]))
}

private func policyProviderSettled(
    _ previous: TimelineEvent, _ admission: ProviderAdmission
) -> TimelineEvent {
    let settlement = ProviderSettlement(
        admission: admission,
        report: ProviderUsage.RawReport(
            inputTokens: 1, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
            reportedTotalTokens: 1, inputAccounting: .cacheInclusive),
        finality: .finalReport)
    return policyEvent(
        TimelineEventType.agentHandleProviderSettled, "policy-7", 7,
        previous: previous.eventID, handle: policyHandle,
        causedBy: EventRef(journal: policyJournal, eventID: previous.eventID),
        payload: .object([
            "ordinal": .string("1"), "settlement": settlement.timelineValue,
            "state": .string(ActionExecutionState.succeeded.rawValue),
        ]))
}

private func policyAdmission() -> ProviderAdmission {
    fixtureProviderAdmission()
}

let casesWorkAgentExecutionPolicyCanonical: [Case] = [
    ("phase5 Work execution policy: omitted limits mean unlimited", {
        let prefix = policyPrefix()
        let payload = WorkAgentHandleQueuedPayload(
            origin: prefix.origin, label: "unlimited child", requestBody: policyBody())
        let value = try XCTUnwrap(JSONValue.parse(try JSONEncoder().encode(payload)))
        XCTAssertNil(value["execution_limits"])
        let decoded = try JSONDecoder().decode(
            WorkAgentHandleQueuedPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.executionLimits, .unlimited)

        let queued = policyEvent(
            TimelineEventType.agentHandleQueued, "policy-4", 4, previous: "policy-3",
            handle: policyHandle, payload: value)
        let snapshot = WorkReducer.reduce(prefix.events + [queued])
        XCTAssertTrue(snapshot.semanticProjectionValid)
        XCTAssertEqual(
            snapshot.agentHandles[policyHandle.handleID]?.executionLimits, .unlimited)
    }),
    ("phase5 Work execution policy: threshold and unknown refusal are canonical decisions", {
        let limits = try WorkAgentExecutionLimits(maximumTokens: 5)
        let reached = ProviderUsageAggregate(
            started: 1, settled: 1, knownFloors: .init(inputTokens: 5, totalTokens: 5))
        XCTAssertEqual(try limits.admissionDecision(for: reached), .tokenThresholdReached)
        let refusal = try WorkAgentExecutionLimitRefusal(
            decision: .tokenThresholdReached, admission: policyAdmission())
        XCTAssertNoThrow { try refusal.validate(limits: limits, usage: reached) }

        let unknown = ProviderUsageAggregate(
            started: 1, settled: 1, unresolved: .init(total: 1),
            knownFloors: .init(totalTokens: 4))
        XCTAssertEqual(try limits.admissionDecision(for: unknown), .tokenAccountingUnknown)
        XCTAssertTrue(
            (try? WorkAgentExecutionLimitRefusal(
                decision: .tokenThresholdReached, admission: policyAdmission()).validate(
                    limits: limits, usage: unknown)) == nil)
    }),
    ("phase5 Work execution policy: forged limited terminal proof is quarantined", {
        let prefix = policyPrefix()
        let limits = try WorkAgentExecutionLimits(maximumTokens: 1)
        let queued = policyQueued(prefix.origin, limits: limits)
        let started = policyStarted(queued)
        let forged = policyEvent(
            TimelineEventType.agentHandleTerminal, "policy-6", 6, previous: started.eventID,
            handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: started.eventID),
            payload: policyJSON(WorkAgentHandleTerminalPayload(
                outcome: .limited, cleanup: .init(state: .quiesced),
                limitRefusal: try WorkAgentExecutionLimitRefusal(
                    decision: .tokenThresholdReached, admission: policyAdmission()),
                executionSettledAt: Date(timeIntervalSince1970: 5.5))))
        let snapshot = WorkReducer.reduce(prefix.events + [queued, started, forged])
        XCTAssertEqual(snapshot.agentHandles[policyHandle.handleID]?.state, .running)
        XCTAssertNil(snapshot.agentHandles[policyHandle.handleID]?.terminalEvidence)
        XCTAssertEqual(snapshot.quarantinedEvents.map(\.eventID), [forged.eventID])
        XCTAssertFalse(snapshot.semanticProjectionValid)
    }),
    ("phase5 Work execution policy: pre-deadline limit settlement survives delayed terminal append", {
        let prefix = policyPrefix()
        let limits = try WorkAgentExecutionLimits(maximumTokens: 1)
        let queued = policyEvent(
            TimelineEventType.agentHandleQueued, "policy-4", 4, previous: "policy-3",
            handle: policyHandle,
            payload: policyJSON(WorkAgentHandleQueuedPayload(
                origin: prefix.origin, label: "deadline child",
                deadline: Date(timeIntervalSince1970: 7.5), requestBody: policyBody(),
                executionLimits: limits)))
        let started = policyStarted(queued)
        let admission = policyAdmission()
        let providerStarted = policyProviderStarted(started, admission)
        let providerSettled = policyProviderSettled(providerStarted, admission)
        let refusal = try WorkAgentExecutionLimitRefusal(
            decision: .tokenThresholdReached, admission: admission)
        let terminalPayload = WorkAgentHandleTerminalPayload(
            outcome: .limited, cleanup: .init(state: .quiesced), limitRefusal: refusal,
            executionSettledAt: Date(timeIntervalSince1970: 7.25))
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkAgentHandleTerminalPayload.self,
                from: JSONEncoder().encode(terminalPayload)),
            terminalPayload)
        let terminal = policyEvent(
            TimelineEventType.agentHandleTerminal, "policy-8", 8,
            previous: providerSettled.eventID, handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: started.eventID),
            payload: policyJSON(terminalPayload), at: 8)
        let snapshot = WorkReducer.reduce(
            prefix.events + [queued, started, providerStarted, providerSettled, terminal])
        let handle = try XCTUnwrap(snapshot.agentHandles[policyHandle.handleID])
        XCTAssertEqual(handle.state, .terminal)
        XCTAssertEqual(handle.executionStartedAt, started.hostRecordedAt)
        XCTAssertEqual(handle.terminalEvidence?.executionSettledAt,
                       Date(timeIntervalSince1970: 7.25))
        XCTAssertEqual(handle.terminalOutcome, .limited)
        XCTAssertTrue(snapshot.quarantinedEvents.isEmpty)
        XCTAssertTrue(snapshot.semanticProjectionValid)
        try snapshot.validateProviderUsageAgainstCompleteActions()

        let exactRoundTrip = try JSONDecoder().decode(
            WorkAgentHandleSnapshot.self, from: JSONEncoder().encode(handle))
        XCTAssertEqual(exactRoundTrip, handle)
        let bounded = BoundedWorkAgentHandleIndexRecord(handle)
        XCTAssertEqual(bounded.executionStartedAt, started.hostRecordedAt)
        XCTAssertEqual(bounded.terminalEvidence?.executionSettledAt,
                       Date(timeIntervalSince1970: 7.25))
        XCTAssertEqual(try JSONDecoder().decode(
            BoundedWorkAgentHandleIndexRecord.self, from: JSONEncoder().encode(bounded)), bounded)

        let tooEarly = policyEvent(
            TimelineEventType.agentHandleTerminal, "policy-8-early", 8,
            previous: providerSettled.eventID, handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: started.eventID),
            payload: policyJSON(WorkAgentHandleTerminalPayload(
                outcome: .limited, cleanup: .init(state: .quiesced), limitRefusal: refusal,
                executionSettledAt: Date(timeIntervalSince1970: 4.9))), at: 8)
        let earlySnapshot = WorkReducer.reduce(
            prefix.events + [queued, started, providerStarted, providerSettled, tooEarly])
        XCTAssertEqual(earlySnapshot.agentHandles[policyHandle.handleID]?.state, .running)
        XCTAssertEqual(earlySnapshot.quarantinedEvents.map(\.eventID), [tooEarly.eventID])

        let missingTimestamp = policyEvent(
            TimelineEventType.agentHandleTerminal, "policy-8-missing", 8,
            previous: providerSettled.eventID, handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: started.eventID),
            payload: policyJSON(WorkAgentHandleTerminalPayload(
                outcome: .limited, cleanup: .init(state: .quiesced), limitRefusal: refusal)), at: 8)
        let missingSnapshot = WorkReducer.reduce(
            prefix.events + [queued, started, providerStarted, providerSettled, missingTimestamp])
        XCTAssertEqual(missingSnapshot.agentHandles[policyHandle.handleID]?.state, .running)
        XCTAssertEqual(
            missingSnapshot.quarantinedEvents.map(\.eventID), [missingTimestamp.eventID])

        let afterTerminal = policyEvent(
            TimelineEventType.agentHandleTerminal, "policy-8-late", 8,
            previous: providerSettled.eventID, handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: started.eventID),
            payload: policyJSON(WorkAgentHandleTerminalPayload(
                outcome: .limited, cleanup: .init(state: .quiesced), limitRefusal: refusal,
                executionSettledAt: Date(timeIntervalSince1970: 8.1))), at: 8)
        let lateSnapshot = WorkReducer.reduce(
            prefix.events + [queued, started, providerStarted, providerSettled, afterTerminal])
        XCTAssertEqual(lateSnapshot.agentHandles[policyHandle.handleID]?.state, .running)
        XCTAssertEqual(lateSnapshot.quarantinedEvents.map(\.eventID), [afterTerminal.eventID])
    }),
    ("phase5 Work execution policy: reaped policy survives exact and bounded records", {
        let prefix = policyPrefix()
        let limits = try WorkAgentExecutionLimits(maximumTokens: 12)
        let queued = policyQueued(prefix.origin, limits: limits)
        let started = policyStarted(queued)
        let terminal = policyEvent(
            TimelineEventType.agentHandleTerminal, "policy-6", 6, previous: started.eventID,
            handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: started.eventID),
            payload: policyJSON(WorkAgentHandleTerminalPayload(
                outcome: .failed, cleanup: .init(state: .quiesced))))
        let reaped = policyEvent(
            TimelineEventType.agentHandleReaped, "policy-7", 7, previous: terminal.eventID,
            handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: terminal.eventID),
            payload: policyJSON(WorkAgentHandleReapedPayload(reason: .explicitPolicy)))
        let snapshot = WorkReducer.reduce(prefix.events + [queued, started, terminal, reaped])
        let exact = try XCTUnwrap(snapshot.agentHandles[policyHandle.handleID])
        XCTAssertEqual(exact.state, .reaped)
        XCTAssertEqual(exact.executionLimits, limits)
        XCTAssertEqual(exact.executionStartedAt, started.hostRecordedAt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkAgentHandleSnapshot.self, from: JSONEncoder().encode(exact)), exact)
        var missingPolicy = try XCTUnwrap(
            JSONValue.parse(try JSONEncoder().encode(exact))?.objectValue)
        missingPolicy.removeValue(forKey: "executionLimits")
        XCTAssertNil(try? JSONDecoder().decode(
            WorkAgentHandleSnapshot.self,
            from: JSONEncoder().encode(JSONValue.object(missingPolicy))))
        var missingAccounting = try XCTUnwrap(
            JSONValue.parse(try JSONEncoder().encode(exact))?.objectValue)
        missingAccounting.removeValue(forKey: "providerAccounting")
        XCTAssertNil(try? JSONDecoder().decode(
            WorkAgentHandleSnapshot.self,
            from: JSONEncoder().encode(JSONValue.object(missingAccounting))))
        let bounded = BoundedWorkAgentHandleIndexRecord(exact)
        XCTAssertEqual(bounded.executionLimits, limits)
        XCTAssertEqual(bounded.executionStartedAt, started.hostRecordedAt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                BoundedWorkAgentHandleIndexRecord.self, from: JSONEncoder().encode(bounded)),
            bounded)
    }),
    ("phase5 Work execution policy: never-started terminal retains no execution timestamps", {
        let prefix = policyPrefix()
        let queued = policyEvent(
            TimelineEventType.agentHandleQueued, "policy-4", 4, previous: "policy-3",
            handle: policyHandle,
            payload: policyJSON(WorkAgentHandleQueuedPayload(
                origin: prefix.origin, label: "queued deadline child",
                deadline: Date(timeIntervalSince1970: 4.5), requestBody: policyBody())))
        let terminal = policyEvent(
            TimelineEventType.agentHandleTerminal, "policy-5", 5, previous: queued.eventID,
            handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: queued.eventID),
            payload: policyJSON(WorkAgentHandleTerminalPayload(
                outcome: .expired, cleanup: .init(state: .notStarted))), at: 5)
        let reaped = policyEvent(
            TimelineEventType.agentHandleReaped, "policy-6", 6, previous: terminal.eventID,
            handle: policyHandle,
            causedBy: EventRef(journal: policyJournal, eventID: terminal.eventID),
            payload: policyJSON(WorkAgentHandleReapedPayload(reason: .explicitPolicy)))
        let snapshot = WorkReducer.reduce(prefix.events + [queued, terminal, reaped])
        let exact = try XCTUnwrap(snapshot.agentHandles[policyHandle.handleID])
        XCTAssertEqual(exact.state, .reaped)
        XCTAssertNil(exact.startedEvent)
        XCTAssertNil(exact.executionStartedAt)
        XCTAssertNil(exact.terminalEvidence?.executionSettledAt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkAgentHandleSnapshot.self, from: JSONEncoder().encode(exact)), exact)
        let bounded = BoundedWorkAgentHandleIndexRecord(exact)
        XCTAssertNil(bounded.startedEvent)
        XCTAssertNil(bounded.executionStartedAt)
        XCTAssertNil(bounded.terminalEvidence?.executionSettledAt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                BoundedWorkAgentHandleIndexRecord.self, from: JSONEncoder().encode(bounded)),
            bounded)
        try snapshot.validateProviderUsageAgainstCompleteActions()
    }),
]

private func XCTAssertNoThrow(_ body: () throws -> Void, line: Int = #line) {
    do { try body() }
    catch { XCTFail("unexpected error: \(error)", line: line) }
}
