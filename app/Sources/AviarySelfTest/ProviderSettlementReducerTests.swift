import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AviaryCore

private let settlementReducerWork = WorkRef(
    workHostID: "provider-settlement-host", workID: "provider-settlement-work")
private let settlementReducerHost = WorkHostRef(settlementReducerWork.workHostID)
private let settlementReducerJournal = JournalRef.work(
    settlementReducerWork, journalID: "provider-settlement-journal")
private let settlementReducerActor = TimelineActor(
    actorID: "provider-settlement-host", kind: "work-host")

private func settlementReducerEvent(
    _ sequence: Int, _ type: String, action: ActionRef? = nil,
    payload: JSONValue = .object([:])
) -> TimelineEvent {
    TimelineEvent(
        eventID: "ps\(sequence)", journal: settlementReducerJournal, sequence: sequence,
        previousEventID: sequence > 1 ? "ps\(sequence - 1)" : nil,
        work: settlementReducerWork, workHost: settlementReducerHost, action: action,
        actor: settlementReducerActor,
        hostRecordedAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        type: type, payload: payload)
}

private func settlementReducerSource(
    _ events: [TimelineEvent]
) throws -> BoundedReducerProjectionSource {
    var prefix = DisposableTimelineProjectionStore.canonicalPrefixSeed(
        for: settlementReducerJournal)
    var bytes = 0
    for event in events {
        let encoded = try DisposableTimelineProjectionStore.canonicalJSON(event)
        bytes += encoded.count + 1
        prefix = DisposableTimelineProjectionStore.advancePrefixDigest(
            prefix,
            lineDigest: try DisposableTimelineProjectionStore.canonicalEventLineDigest(event))
    }
    return BoundedReducerProjectionSource(
        journal: settlementReducerJournal,
        cursor: JournalCursor(
            journal: settlementReducerJournal, eventID: events.last?.eventID,
            sequence: events.last?.sequence ?? 0),
        sourceID: "provider-settlement-source",
        sourceGeneration: String(repeating: "a", count: 64),
        sourceFingerprint: String(repeating: "b", count: 64),
        sourceByteCount: bytes, prefixByteCount: bytes, prefixDigest: prefix)
}

private func settlementReducerAdmission(
    purpose: ProviderAdmission.Purpose = .normal
) -> ProviderAdmission {
    ProviderAdmission(
        purpose: purpose,
        rates: ProviderUsage.RateSnapshot(model: ModelSpec(rpc: .object([
            "id": .string("provider/model"), "provider": .string("provider"),
        ]))))
}

private func settlementReducerReport() -> ProviderUsage.RawReport {
    ProviderUsage.RawReport(
        inputTokens: 2, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 0,
        reasoningTokens: 1, reportedTotalTokens: 5, inputAccounting: .cacheInclusive)
}

func test_providerSettlementReducerStrictLifecycleAndBoundedParity() throws {
    let action = ActionRef("provider-action")
    let admission = settlementReducerAdmission()
    let settlement = ProviderSettlement(
        admission: admission, report: settlementReducerReport(), finality: .finalReport)
    let events = [
        settlementReducerEvent(1, TimelineEventType.workCreated),
        settlementReducerEvent(2, TimelineEventType.actionIntent, action: action, payload: .object([
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "intent": .string("provider request"),
            "provider_admission": admission.timelineValue,
        ])),
        settlementReducerEvent(3, TimelineEventType.actionStarted, action: action, payload: .object([
            "state": .string(ActionExecutionState.running.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
        ])),
        settlementReducerEvent(4, TimelineEventType.actionOutcome, action: action, payload: .object([
            "state": .string(ActionExecutionState.succeeded.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "retry_safety": .string(ActionRetrySafety.unsafe.rawValue),
            "provider_settlement": settlement.timelineValue,
        ])),
        settlementReducerEvent(5, TimelineEventType.workCompleted),
    ]

    let snapshot = WorkReducer.reduce(events)
    XCTAssertTrue(snapshot.semanticProjectionValid)
    XCTAssertEqual(snapshot.lifecycle, .completed)
    XCTAssertEqual(snapshot.actions[action.actionID]?.providerAdmission, admission)
    XCTAssertEqual(snapshot.actions[action.actionID]?.providerSettlement, settlement)
    XCTAssertEqual(snapshot.providerUsage.started, 1)
    XCTAssertEqual(snapshot.providerUsage.settled, 1)
    XCTAssertEqual(snapshot.providerUsage.unresolvedTotal, 0)
    XCTAssertEqual(snapshot.providerUsage.knownTokenFloor, 5)
    try snapshot.validateProviderUsageAgainstCompleteActions()
    XCTAssertEqual(
        try rebuildCompleteProviderUsage(from: [
            .settled(sequence: 4, actionID: action.actionID, settlement: settlement),
            .started(sequence: 3, actionID: action.actionID),
        ]),
        snapshot.providerUsage,
        "complete-history validation must replay canonical sequence, not collection order")

    var forgedSnapshot = snapshot
    forgedSnapshot.providerUsage = ProviderUsageAggregate()
    do {
        try forgedSnapshot.validateProviderUsageAgainstCompleteActions()
        XCTFail("a full Work snapshot must not authenticate a neutral aggregate over usage")
    } catch {}
    let checkpointCursor = JournalCursor(
        journal: settlementReducerJournal, eventID: events.last?.eventID,
        sequence: events.last?.sequence ?? 0)
    XCTAssertTrue(WorkServiceAttachedWorkController.validCommittedWork(
        snapshot, cursor: checkpointCursor, work: settlementReducerWork,
        journal: settlementReducerJournal))
    XCTAssertFalse(WorkServiceAttachedWorkController.validCommittedWork(
        forgedSnapshot, cursor: checkpointCursor, work: settlementReducerWork,
        journal: settlementReducerJournal))

    let head = try BoundedWorkReducerHead.build(
        events: events, source: settlementReducerSource(events))
    XCTAssertEqual(head.providerUsage, snapshot.providerUsage)
    XCTAssertEqual(try head.action(for: action.actionID).providerAdmission, admission)
    XCTAssertEqual(try head.action(for: action.actionID).providerSettlement, settlement)
    XCTAssertEqual(
        try BoundedWorkReducerHead.decodeOpaqueReducerHead(head.opaqueReducerHead()), head)

    let encoder = JSONEncoder()
    let headObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoder.encode(head)) as? [String: Any])
    var forgedHeadObject = headObject
    forgedHeadObject["providerUsage"] = try JSONSerialization.jsonObject(
        with: encoder.encode(ProviderUsageAggregate()))
    let forgedHead = try JSONDecoder().decode(
        BoundedWorkReducerHead.self,
        from: JSONSerialization.data(withJSONObject: forgedHeadObject))
    do {
        try forgedHead.validate()
        XCTFail("a complete action index must not authenticate a neutral aggregate over usage")
    } catch {}
}

func test_providerSettlementReducerRetainsUnknownTerminalAccountingWithoutBlockingCompletion() {
    let action = ActionRef("failed-provider-action")
    let admission = settlementReducerAdmission()
    let settlement = ProviderSettlement(
        admission: admission, report: nil, finality: .unconfirmed)
    let events = [
        settlementReducerEvent(1, TimelineEventType.workCreated),
        settlementReducerEvent(2, TimelineEventType.actionIntent, action: action, payload: .object([
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "intent": .string("provider request"),
            "provider_admission": admission.timelineValue,
        ])),
        settlementReducerEvent(3, TimelineEventType.actionStarted, action: action, payload: .object([
            "state": .string(ActionExecutionState.running.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
        ])),
        settlementReducerEvent(4, TimelineEventType.actionOutcome, action: action, payload: .object([
            "state": .string(ActionExecutionState.failed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "failure_kind": .string(ActionFailureKind.infrastructure.rawValue),
            "retry_safety": .string(ActionRetrySafety.unknown.rawValue),
            "provider_settlement": settlement.timelineValue,
        ])),
        settlementReducerEvent(5, TimelineEventType.workCompleted),
    ]

    let snapshot = WorkReducer.reduce(events)
    XCTAssertTrue(snapshot.semanticProjectionValid)
    XCTAssertEqual(snapshot.lifecycle, .completed)
    XCTAssertEqual(snapshot.providerUsage.started, 1)
    XCTAssertEqual(snapshot.providerUsage.settled, 1)
    XCTAssertEqual(snapshot.providerUsage.unresolvedTotal, 1)
    XCTAssertEqual(snapshot.providerUsage.unresolvedBreakdown, 1)
    XCTAssertEqual(snapshot.providerUsage.unresolvedCost, 1)
}

func test_providerSettlementReducerRejectsRedefinedLifecycleEvidence() {
    let action = ActionRef("redefined-provider-action")
    let admission = settlementReducerAdmission()
    let missingAdmission = WorkReducer.reduce([
        settlementReducerEvent(1, TimelineEventType.workCreated),
        settlementReducerEvent(2, TimelineEventType.actionIntent, action: action, payload: .object([
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "intent": .string("missing admission"),
        ])),
    ])
    XCTAssertFalse(missingAdmission.semanticProjectionValid)
    XCTAssertNil(missingAdmission.actions[action.actionID])
    XCTAssertEqual(missingAdmission.providerUsage.started, 0)

    let redefinedStart = WorkReducer.reduce([
        settlementReducerEvent(1, TimelineEventType.workCreated),
        settlementReducerEvent(2, TimelineEventType.actionIntent, action: action, payload: .object([
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "intent": .string("provider request"),
            "provider_admission": admission.timelineValue,
        ])),
        settlementReducerEvent(3, TimelineEventType.actionStarted, action: action, payload: .object([
            "state": .string(ActionExecutionState.running.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "provider_admission": admission.timelineValue,
        ])),
    ])
    XCTAssertFalse(redefinedStart.semanticProjectionValid)
    XCTAssertEqual(redefinedStart.actions[action.actionID]?.state, .proposed)
    XCTAssertEqual(redefinedStart.providerUsage.started, 0)

    let missingSettlement = WorkReducer.reduce([
        settlementReducerEvent(1, TimelineEventType.workCreated),
        settlementReducerEvent(2, TimelineEventType.actionIntent, action: action, payload: .object([
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "intent": .string("provider request"),
            "provider_admission": admission.timelineValue,
        ])),
        settlementReducerEvent(3, TimelineEventType.actionStarted, action: action, payload: .object([
            "state": .string(ActionExecutionState.running.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
        ])),
        settlementReducerEvent(4, TimelineEventType.actionOutcome, action: action, payload: .object([
            "state": .string(ActionExecutionState.failed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "failure_kind": .string(ActionFailureKind.infrastructure.rawValue),
            "retry_safety": .string(ActionRetrySafety.unknown.rawValue),
        ])),
    ])
    XCTAssertFalse(missingSettlement.semanticProjectionValid)
    XCTAssertEqual(missingSettlement.actions[action.actionID]?.state, .running)
    XCTAssertEqual(missingSettlement.providerUsage.started, 1)
    XCTAssertEqual(missingSettlement.providerUsage.settled, 0)

    let outcomeStartBypass = WorkReducer.reduce([
        settlementReducerEvent(1, TimelineEventType.workCreated),
        settlementReducerEvent(2, TimelineEventType.actionIntent, action: action, payload: .object([
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "intent": .string("provider request"),
            "provider_admission": admission.timelineValue,
        ])),
        settlementReducerEvent(3, TimelineEventType.actionOutcome, action: action, payload: .object([
            "state": .string(ActionExecutionState.running.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
        ])),
    ])
    XCTAssertFalse(outcomeStartBypass.semanticProjectionValid)
    XCTAssertEqual(outcomeStartBypass.actions[action.actionID]?.state, .proposed)
    XCTAssertFalse(outcomeStartBypass.activeActionIDs.contains(action.actionID))
    XCTAssertEqual(outcomeStartBypass.providerUsage.started, 0)
}

func test_providerSettlementReducerExactStateParityAndDuplicateRejection() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "aviary-provider-settlement-\(UUID().uuidString.lowercased())",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard chmod(directory.path, mode_t(0o700)) == 0 else {
        throw PersistentProjectionRadixMap.MapError.ioFailure
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let map = try PersistentProjectionRadixMap(
        directory: directory.appending(path: "map", directoryHint: .isDirectory),
        namespaceID: "provider-settlement-exact", journal: settlementReducerJournal,
        sourceGeneration: String(repeating: "c", count: 64), mapKind: "work-exact-v9")

    let action = ActionRef("exact-provider-action")
    let admission = settlementReducerAdmission()
    let settlement = ProviderSettlement(
        admission: admission, report: settlementReducerReport(), finality: .finalReport)
    let events = [
        settlementReducerEvent(1, TimelineEventType.workCreated),
        settlementReducerEvent(2, TimelineEventType.actionIntent, action: action, payload: .object([
            "state": .string(ActionExecutionState.proposed.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "intent": .string("provider request"),
            "provider_admission": admission.timelineValue,
        ])),
        settlementReducerEvent(3, TimelineEventType.actionStarted, action: action, payload: .object([
            "state": .string(ActionExecutionState.running.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
        ])),
        settlementReducerEvent(4, TimelineEventType.actionOutcome, action: action, payload: .object([
            "state": .string(ActionExecutionState.succeeded.rawValue),
            "kind": .string(ActionKind.provider.rawValue),
            "retry_safety": .string(ActionRetrySafety.unsafe.rawValue),
            "provider_settlement": settlement.timelineValue,
        ])),
    ]

    let proposed = try XCTUnwrap(WorkReducer.reduce(events.prefix(2)).actions[action.actionID])
    let proposedBytes = try JSONEncoder().encode(proposed)
    let restoredProposed = try JSONDecoder().decode(WorkActionSnapshot.self, from: proposedBytes)
    XCTAssertEqual(restoredProposed, proposed)
    XCTAssertTrue(restoredProposed.hasValidProviderEvidence)
    let completed = try XCTUnwrap(WorkReducer.reduce(events).actions[action.actionID])
    let completedBytes = try JSONEncoder().encode(completed)
    let restoredCompleted = try JSONDecoder().decode(
        WorkActionSnapshot.self, from: completedBytes)
    XCTAssertEqual(restoredCompleted, completed)
    XCTAssertEqual(restoredCompleted.providerAdmission, admission)
    XCTAssertEqual(restoredCompleted.providerSettlement, settlement)
    XCTAssertTrue(restoredCompleted.hasValidProviderEvidence)

    var root: PersistentProjectionRadixMap.Root?
    for offset in events.indices {
        let exact: PersistentWorkExactState
        do {
            exact = try PersistentWorkExactState(map: map, root: root)
        } catch {
            throw UnwrapFailure(
                description: "exact provider settlement open before ps\(offset + 1) failed: \(error)")
        }
        var applying = exact
        do {
            let result = try applying.apply(events[offset])
            root = result.root
            XCTAssertEqual(
                result.eventLocalSnapshot.providerUsage,
                WorkReducer.reduce(events.prefix(offset + 1)).providerUsage)
        } catch {
            throw UnwrapFailure(
                description: "exact provider settlement apply ps\(offset + 1) failed: \(error)")
        }
    }
    let finalRoot = try XCTUnwrap(root)
    let opened: PersistentWorkExactState
    do {
        opened = try PersistentWorkExactState(map: map, root: finalRoot)
    } catch {
        throw UnwrapFailure(description: "exact provider settlement reopen failed: \(error)")
    }
    var reopened = opened
    XCTAssertEqual(reopened.eventLocalSnapshot.providerUsage, WorkReducer.reduce(events).providerUsage)
    let priorRoot = reopened.currentRoot
    do {
        _ = try reopened.apply(events[3])
        XCTFail("an exact replay must reject a duplicate provider settlement event")
    } catch let error as PersistentWorkExactState.Error {
        guard case .duplicateEvent("ps4") = error else {
            XCTFail("unexpected exact-state duplicate error: \(error)")
            return
        }
    }
    XCTAssertEqual(reopened.currentRoot, priorRoot)
}

let casesProviderSettlementReducer: [(String, () async throws -> Void)] = [
    ("provider settlement reducer strict lifecycle and bounded parity", {
        try test_providerSettlementReducerStrictLifecycleAndBoundedParity()
    }),
    ("provider settlement reducer retains terminal unknowns without blocking completion", {
        test_providerSettlementReducerRetainsUnknownTerminalAccountingWithoutBlockingCompletion()
    }),
    ("provider settlement reducer rejects lifecycle evidence redefinition", {
        test_providerSettlementReducerRejectsRedefinedLifecycleEvidence()
    }),
    ("provider settlement reducer exact state parity and duplicate rejection", {
        try test_providerSettlementReducerExactStateParityAndDuplicateRejection()
    }),
]
