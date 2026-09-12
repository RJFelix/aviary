import Foundation
@testable import AviaryCore

private struct ChildAccountingFixture {
    let work = WorkRef(workHostID: "child-accounting-host", workID: "child-accounting-work")
    let session = SessionRef("child-accounting-session")
    let attachment = SessionAttachmentRef("child-accounting-attachment")
    let run = RunRef("child-accounting-run")
    let handle = HandleRef("child-accounting-handle")
    var journal: JournalRef { .work(work, journalID: "work") }
    var origin: WorkAgentHandleOrigin {
        .init(work: work, workHost: WorkHostRef(work.workHostID), session: session,
              sessionAttachment: attachment, run: run)
    }
    var admission: ProviderAdmission {
        ProviderAdmission(purpose: .normal, rates: ProviderUsage.RateSnapshot(model:
            ModelSpec(rpc: .object(["id": .string("model"), "provider": .string("fixture")]))))
    }
    func ref(_ sequence: Int) -> EventRef { .init(journal: journal, eventID: "cp-\(sequence)") }
    func event(_ sequence: Int, _ type: String, cause: Int? = nil,
               payload: JSONValue = .object([:])) -> TimelineEvent {
        TimelineEvent(eventID: ref(sequence).eventID, journal: journal, sequence: sequence,
                      previousEventID: sequence > 1 ? ref(sequence - 1).eventID : nil,
                      causedByEventID: cause.map(ref), session: session, work: work,
                      workHost: WorkHostRef(work.workHostID), sessionAttachment: attachment,
                      run: run, handle: type.hasPrefix("agent_handle.") ? handle : nil,
                      actor: TimelineActor(actorID: "fixture", kind: "work-host"),
                      hostRecordedAt: Date(timeIntervalSince1970: Double(sequence)),
                      type: type, declaredDomains: type.hasPrefix("agent_handle.")
                        ? [.work, .runtime, .externalEffects] : [], payload: payload)
    }
    func prefix() throws -> [TimelineEvent] {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let payload = WorkAgentHandleQueuedPayload(origin: origin, label: "child", requestBody:
            TimelineBodyReference(authority: journal, referenceID: digest,
                                  mediaType: "text/plain", byteCount: 1, digest: digest))
        return [event(1, TimelineEventType.workCreated), event(2, TimelineEventType.sessionAttached),
                event(3, TimelineEventType.runStarted),
                event(4, TimelineEventType.agentHandleQueued,
                      payload: try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(payload)))),
                event(5, TimelineEventType.agentHandleStarted, cause: 4)]
    }
    func start(_ sequence: Int, cause: Int, ordinal: Int = 1,
               admission: ProviderAdmission? = nil) -> TimelineEvent {
        event(sequence, TimelineEventType.agentHandleProviderStarted, cause: cause,
              payload: .object(["ordinal": .string(String(ordinal)),
                                "admission": (admission ?? self.admission).timelineValue]))
    }
    func settle(_ sequence: Int, cause: Int, ordinal: Int = 1,
                admission: ProviderAdmission? = nil, final: Bool = true) -> TimelineEvent {
        let settlement = ProviderSettlement(admission: admission ?? self.admission,
            report: ProviderUsage.RawReport(inputTokens: 3, outputTokens: 2,
                cacheReadTokens: 0, cacheWriteTokens: 0, reportedTotalTokens: 5,
                inputAccounting: .cacheInclusive), finality: final ? .finalReport : .unconfirmed)
        return event(sequence, TimelineEventType.agentHandleProviderSettled, cause: cause,
            payload: .object(["ordinal": .string(String(ordinal)),
                              "settlement": settlement.timelineValue,
                              "state": .string(final ? "succeeded" : "indeterminate_effect")]))
    }
    func source(_ events: [TimelineEvent]) throws -> BoundedReducerProjectionSource {
        var prefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(for: journal)
        var count = 0
        for event in events {
            count += try DisposableTimelineProjectionStore.canonicalJSON(event).count + 1
            prefix = DisposableTimelineProjectionStore.advancePrefixDigest(prefix,
                lineDigest: try DisposableTimelineProjectionStore.canonicalEventLineDigest(event))
        }
        return .init(journal: journal,
            cursor: .init(journal: journal, eventID: events.last?.eventID, sequence: events.count),
            sourceID: "child-accounting-source", sourceGeneration: String(repeating: "b", count: 64),
            sourceFingerprint: String(repeating: "c", count: 64), sourceByteCount: count,
            prefixByteCount: count, prefixDigest: prefix)
    }
}

func test_childProviderAccountingSurvivesEndAndColdReopen() throws {
    let f = ChildAccountingFixture()
    let compaction = ProviderAdmission(purpose: .compaction, rates: f.admission.rates)
    let events = try f.prefix() + [
        f.start(6, cause: 5), f.event(7, TimelineEventType.runFinished),
        f.settle(8, cause: 6), f.start(9, cause: 8, ordinal: 2, admission: compaction),
        f.settle(10, cause: 9, ordinal: 2, admission: compaction, final: false),
    ]
    let snapshot = WorkReducer.reduce(events)
    XCTAssertTrue(snapshot.semanticProjectionValid, snapshot.corruptionReasons.joined(separator: ";"))
    XCTAssertNil(snapshot.activeRun)
    XCTAssertTrue(snapshot.activeActionIDs.isEmpty)
    XCTAssertEqual(snapshot.providerUsage.started, 0, "child usage is not parent-direct usage")
    let accounting = try XCTUnwrap(snapshot.agentHandles[f.handle.handleID]?.providerAccounting)
    XCTAssertEqual(accounting.usage.started, 2)
    XCTAssertEqual(accounting.usage.settled, 2)
    XCTAssertEqual(accounting.usage.knownTokenFloor, 10)
    XCTAssertEqual(accounting.usage.unresolvedTotal, 1)
    XCTAssertNil(accounting.pending)
    XCTAssertEqual(snapshot.agentHandles[f.handle.handleID]?.latestLifecycleEvent, f.ref(5))
    let head = try BoundedWorkReducerHead.build(events: events, source: f.source(events))
    XCTAssertEqual(try head.agentHandle(for: f.handle.handleID).providerAccounting, accounting)
    XCTAssertEqual(try BoundedWorkReducerHead.decodeOpaqueReducerHead(head.opaqueReducerHead()), head)

    let directory = FileManager.default.temporaryDirectory.appending(path: "acp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let map = try PersistentProjectionRadixMap(directory: directory.appending(path: "map"),
        namespaceID: "child-provider-exact", journal: f.journal,
        sourceGeneration: String(repeating: "b", count: 64), mapKind: "work-exact-v8")
    var root: PersistentProjectionRadixMap.Root?
    for event in events {
        var exact = try PersistentWorkExactState(map: map, root: root)
        let result = try exact.apply(event)
        root = result.root
        XCTAssertTrue(result.eventLocalSnapshot.semanticProjectionValid,
                      result.eventLocalSnapshot.corruptionReasons.joined(separator: ";"))
        if event.handle == f.handle {
            XCTAssertEqual(result.eventLocalSnapshot.agentHandles[f.handle.handleID]?.providerAccounting,
                WorkReducer.reduce(events.prefix(event.sequence)).agentHandles[f.handle.handleID]?.providerAccounting)
        }
    }
}

func test_childProviderAccountingRejectsDuplicateAndUnknownExposure() throws {
    let f = ChildAccountingFixture()
    let prefix = try f.prefix()
    let started = prefix + [f.start(6, cause: 5)]
    let running = WorkReducer.reduce(started)
    XCTAssertTrue(running.semanticProjectionValid)
    XCTAssertEqual(running.agentHandles[f.handle.handleID]?.providerAccounting.usage.unresolvedTotal, 1)
    for invalid in [f.start(7, cause: 6, ordinal: 2),
                    f.settle(7, cause: 5), f.settle(7, cause: 6, ordinal: 2)] {
        let result = WorkReducer.reduce(started + [invalid])
        XCTAssertFalse(result.semanticProjectionValid)
        XCTAssertEqual(result.agentHandles[f.handle.handleID]?.providerAccounting.usage.settled, 0)
    }
    let settled = started + [f.settle(7, cause: 6)]
    XCTAssertTrue(WorkReducer.reduce(settled).semanticProjectionValid)
    XCTAssertFalse(WorkReducer.reduce(settled + [f.settle(8, cause: 6)]).semanticProjectionValid)
    let canceled = f.event(7, TimelineEventType.agentHandleCancelRequested, cause: 5,
                          payload: .object(["cause": .string("host_shutdown")]))
    let canceledSnapshot = WorkReducer.reduce(started + [canceled, f.settle(8, cause: 6, final: false)])
    XCTAssertTrue(canceledSnapshot.semanticProjectionValid)
    XCTAssertEqual(canceledSnapshot.agentHandles[f.handle.handleID]?.providerAccounting.usage.settled, 1)
}

func test_childProviderAccountingRejectsImpossibleLifecycleOrder() throws {
    let f = ChildAccountingFixture()
    let cancellation = f.event(
        7, TimelineEventType.agentHandleCancelRequested, cause: 5,
        payload: .object(["cause": .string("host_shutdown")]))
    let terminalPayload = WorkAgentHandleTerminalPayload(
        outcome: .canceled, resultBody: nil, cleanup: .init(state: .quiesced))
    let terminal = f.event(
        9, TimelineEventType.agentHandleTerminal, cause: 7,
        payload: try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(terminalPayload))))
    let events = try f.prefix() + [
        f.start(6, cause: 5), cancellation,
        f.settle(8, cause: 6, final: false), terminal,
    ]
    let snapshot = WorkReducer.reduce(events)
    XCTAssertTrue(snapshot.semanticProjectionValid, snapshot.corruptionReasons.joined(separator: ";"))
    try snapshot.validateProviderUsageAgainstCompleteActions()
    let accounting = try XCTUnwrap(
        snapshot.agentHandles[f.handle.handleID]?.providerAccounting)

    // Settlement may follow cancellation, but admission cannot, and neither provider proof can
    // be created after the Handle's write-once terminal boundary.
    try accounting.validateLifecycleOrder(
        executionSequence: 5, cancellationSequence: 7, terminalSequence: 9)
    for forged in [(6, 7, 9), (5, 6, 9), (5, 7, 8)] {
        do {
            try accounting.validateLifecycleOrder(
                executionSequence: forged.0,
                cancellationSequence: forged.1,
                terminalSequence: forged.2)
            XCTFail("forged provider/lifecycle order must be rejected")
        } catch WorkAgentProviderAccounting.Failure.invalidState {
            // Expected exact rejection.
        } catch {
            XCTFail("unexpected provider/lifecycle order error: \(error)")
        }
    }

    let afterCancellationStart = WorkReducer.reduce(
        try f.prefix() + [
            f.event(6, TimelineEventType.agentHandleCancelRequested, cause: 5,
                    payload: .object(["cause": .string("host_shutdown")])),
            f.start(7, cause: 5),
        ])
    XCTAssertFalse(afterCancellationStart.semanticProjectionValid)
    let afterTerminalSettlement = WorkReducer.reduce(events + [f.settle(10, cause: 6)])
    XCTAssertFalse(afterTerminalSettlement.semanticProjectionValid)
}

let casesWorkAgentProviderAccounting: [Case] = [
    ("child provider accounting: quiescent failure preserves unresolved billing", {
        let f = ChildAccountingFixture()
        let prefix = try f.prefix() + [f.start(6, cause: 5), f.event(7, TimelineEventType.runFinished)]
        func terminal(_ outcome: WorkAgentHandleTerminalOutcome) throws -> TimelineEvent {
            let digest = "sha256:" + String(repeating: "d", count: 64)
            let body = TimelineBodyReference(authority: f.journal, referenceID: digest,
                mediaType: "text/plain", byteCount: 1, digest: digest)
            let payload = WorkAgentHandleTerminalPayload(outcome: outcome,
                resultBody: outcome == .succeeded ? body : nil, cleanup: .init(state: .quiesced))
            return f.event(8, TimelineEventType.agentHandleTerminal, cause: 5,
                           payload: try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(payload))))
        }
        let reap = WorkAgentHandleReapedPayload(reason: .explicitPolicy)
        let failed = WorkReducer.reduce(prefix + [try terminal(.failed),
            f.event(9, TimelineEventType.workCompleted),
            f.event(10, TimelineEventType.agentHandleReaped, cause: 8,
                payload: try XCTUnwrap(JSONValue.parse(JSONEncoder().encode(reap))))])
        XCTAssertTrue(failed.semanticProjectionValid, failed.corruptionReasons.joined(separator: ";"))
        XCTAssertEqual(failed.lifecycle, .completed)
        XCTAssertEqual(failed.agentHandles[f.handle.handleID]?.state, .reaped)
        XCTAssertEqual(failed.agentHandles[f.handle.handleID]?.providerAccounting.usage.unresolvedTotal, 1)
        XCTAssertNotNil(failed.agentHandles[f.handle.handleID]?.providerAccounting.pending)
        XCTAssertFalse(WorkReducer.reduce(prefix + [try terminal(.succeeded)]).semanticProjectionValid)
    }),
    ("child provider accounting: End and cold exact continuation", {
        try test_childProviderAccountingSurvivesEndAndColdReopen()
    }),
    ("child provider accounting: duplicate and uncertainty boundaries", {
        try test_childProviderAccountingRejectsDuplicateAndUnknownExposure()
    }),
    ("child provider accounting: lifecycle order rejects forged evidence", {
        try test_childProviderAccountingRejectsImpossibleLifecycleOrder()
    }),
]
