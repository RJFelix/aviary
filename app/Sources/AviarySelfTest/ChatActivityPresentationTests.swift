import Foundation
@testable import AviaryCore

private func activityRow(_ id: String, _ state: ActionExecutionState) -> WorkActionPresentation {
    WorkActionPresentation(WorkActionSnapshot(
        action: ActionRef(id), state: state, kind: .python,
        metadata: ["secret": .string("do-not-display")]))
}

func testChatActivitySectionsAndBounds() throws {
    let states: [ActionExecutionState] = [.running, .queued, .proposed, .cancelRequested,
                                          .unknown, .failed, .indeterminateEffect, .succeeded, .canceled]
    let rows = states.enumerated().map { activityRow("action-\($0.offset)", $0.element) }
    let view = ChatActivityPresentation(actions: rows, sourceIsComplete: true)
    XCTAssertEqual(view.current.map(\.state), Array(states.prefix(5)))
    XCTAssertEqual(view.problems.map(\.state), [.failed, .indeterminateEffect])
    XCTAssertEqual(view.completed.map(\.state), [.succeeded, .canceled])
    XCTAssertEqual(view.omittedCount, 0)
    XCTAssertTrue(view.sourceIsComplete)
    XCTAssertFalse(view.summary.contains("blocked"))
    XCTAssertFalse(view.summary.contains("retry"))
    XCTAssertFalse(view.summary.contains("do-not-display"))
    let duplicate = ChatActivityPresentation(
        actions: rows + [activityRow("action-0", .succeeded)], sourceIsComplete: true)
    XCTAssertEqual(duplicate.omittedCount, 2)
    XCTAssertFalse(duplicate.sourceIsComplete)
    XCTAssertFalse(duplicate.current.contains { $0.id == "action-0" })
    XCTAssertFalse(duplicate.completed.contains { $0.id == "action-0" })
    let large = ChatActivityPresentation(
        actions: (0..<300).map { activityRow("large-\($0)", .running) }, sourceIsComplete: true)
    XCTAssertEqual(large.current.count, 256)
    XCTAssertEqual(large.omittedCount, 44)
    XCTAssertFalse(large.sourceIsComplete)
    let tailDuplicate = ChatActivityPresentation(
        actions: (0..<256).map { activityRow("tail-\($0)", .running) }
            + [activityRow("tail-0", .failed)], sourceIsComplete: true)
    XCTAssertEqual(tailDuplicate.omittedCount, 2)
    XCTAssertEqual(tailDuplicate.current.count, 255)
    XCTAssertFalse(tailDuplicate.current.contains { $0.id == "tail-0" })
    let unknown = ChatActivityPresentation(actions: [], sourceIsComplete: false)
    XCTAssertTrue(unknown.summary.contains("unavailable"))
    XCTAssertFalse(unknown.summary.contains("No actions recorded yet"))
    XCTAssertFalse(ChatActivityPresentation(actions: rows, sourceIsComplete: false).sourceIsComplete)
}

private func activityProjection(
    base: WorkServiceAttachedWorkProjection, children: [String: String] = [:],
    connected: Bool = true, complete: Bool = true, unknown: Bool = false,
    refresh: Bool = false, diagnostic: Bool = false
) -> WorkServiceAttachedWorkProjection {
    var work = base.workSnapshot
    work.childStates = children
    if unknown { work.unknownDomains.insert(.runtime) }
    return WorkServiceAttachedWorkProjection(
        descriptor: base.descriptor, attachment: base.attachment, capabilities: base.capabilities,
        workSnapshot: work, sessionSnapshot: base.sessionSnapshot,
        workCursor: base.workCursor, sessionCursor: base.sessionCursor,
        workSourceCompleteness: complete ? .complete : .incomplete,
        sessionSourceCompleteness: .complete,
        readDiagnostics: diagnostic ? ["read unavailable"] : [],
        connectivity: connected ? base.connectivity : .disconnected, requiresRefresh: refresh)
}

func testChatChildActivityUsesRecordedCanonicalStates() async throws {
    let host = WorkHostRef("chat-activity-host")
    let client = ClientRef("chat-activity-client")
    let grants = Set(WorkServiceCapability.allCases)
    let service = InMemoryWorkService(
        host: host, authorizer: WorkServiceCapabilityPolicy(grantsByClient: [client: grants]))
    let created = try await service.createWork(.init(
        client: client, commandID: "activity-create",
        causalControlCursor: JournalCursor(journal: .workHost(host), sequence: 0),
        requestedCapabilities: grants))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let key = try XCTUnwrap(ServiceAttachmentKey(work: created.work.work, attachment: created.attachment))
    let store = try WorkServiceAttachedWorkIntentStore(home: AgentHome(root: root), key: key)
    let controller = try WorkServiceAttachedWorkController(
        service: service, seed: .created(created), intentStore: store)
    let base = try await controller.refresh()
    XCTAssertTrue(ChatActivityPresentation.sourceIsCurrent(base))
    let states = ["private-name": "running", "done": "done", "failed": "failed",
                  "canceled": "canceled", "unknown": "credential-shaped-value"]
    let projection = activityProjection(base: base, children: states)
    let working = CanonicalWorkingStateProjection(projection: projection)
    XCTAssertTrue(working.isCanonical)
    let child = ChatChildActivityPresentation(workingState: working, sourceIsCurrent: true)
    XCTAssertTrue(child.isAvailable)
    XCTAssertTrue(child.hasRecords)
    XCTAssertEqual(child.running, 1)
    XCTAssertEqual(child.done, 1)
    XCTAssertEqual(child.failed, 1)
    XCTAssertEqual(child.canceled, 1)
    XCTAssertEqual(child.unknown, 1)
    XCTAssertTrue(child.summary.contains("recorded running"))
    XCTAssertTrue(child.disclosure.contains("Not proof"))
    XCTAssertFalse(child.summary.contains("private-name"))
    XCTAssertFalse(child.summary.contains("credential-shaped"))
    let stale = ChatChildActivityPresentation(workingState: working, sourceIsCurrent: false)
    XCTAssertEqual(stale.running, child.running)
    XCTAssertTrue(stale.hasRecords)
    XCTAssertFalse(stale.sourceIsCurrent)
    XCTAssertTrue(stale.disclosure.contains("not confirmed"))
    for invalid in [activityProjection(base: base, connected: false),
                    activityProjection(base: base, complete: false),
                    activityProjection(base: base, unknown: true),
                    activityProjection(base: base, refresh: true),
                    activityProjection(base: base, diagnostic: true)] {
        XCTAssertFalse(ChatActivityPresentation.sourceIsCurrent(invalid))
    }
    let unavailable = ChatChildActivityPresentation(
        workingState: CanonicalWorkingStateProjection(
            projection: activityProjection(base: base, children: states, complete: false)),
        sourceIsCurrent: true)
    XCTAssertFalse(unavailable.isAvailable)
    XCTAssertFalse(unavailable.sourceIsCurrent)
    XCTAssertFalse(unavailable.hasRecords)
    XCTAssertTrue(unavailable.summary.contains("unavailable"))
    XCTAssertFalse(ChatChildActivityPresentation(workingState: nil, sourceIsCurrent: true).isAvailable)
    let many = Dictionary(uniqueKeysWithValues: (0..<300).map { ("child-\($0)", "running") })
    let capped = ChatChildActivityPresentation(
        workingState: CanonicalWorkingStateProjection(
            projection: activityProjection(base: base, children: many)), sourceIsCurrent: true)
    XCTAssertEqual(capped.running, 256)
    XCTAssertEqual(capped.omittedCount, 44)
    XCTAssertTrue(capped.summary.contains("44 outside"))
}

let casesChatActivityPresentation: [Case] = [
    ("chat activity: section classification and bounded identity", { try testChatActivitySectionsAndBounds() }),
    ("chat activity: recorded child lifecycle and source freshness", { try await testChatChildActivityUsesRecordedCanonicalStates() }),
]
