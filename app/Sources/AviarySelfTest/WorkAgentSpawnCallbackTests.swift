import Foundation

@testable import AviaryCore

let casesWorkAgentSpawnCallback: [Case] = [
    ("phase5 Work agent spawn: callback replay retains one Handle", {
        try await testWorkAgentSpawnCallbackReplayRetainsHandleAfterJournalFailure()
    }),
    ("phase5 Work agent spawn: callback replay retains explicit no deadline", {
        try await testWorkAgentSpawnCallbackReplayRetainsHandleAfterJournalFailure(deadline: nil)
    }),
]

private struct WorkSpawnUnusedProvider: ChatProvider {
    let id = "work-spawn-callback-test"

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private actor WorkSpawnReplayDelegate: WorkAgentSpawnDelegate {
    private let bundle: RunJournalBundle
    private let handleID: String
    private let deadline: Date?
    private var admissionCountStorage = 0
    private var admitted = false
    private var admittedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(bundle: RunJournalBundle, handleID: String, deadline: Date?) {
        self.bundle = bundle
        self.handleID = handleID
        self.deadline = deadline
    }

    var admissionCount: Int { admissionCountStorage }

    func waitUntilAdmitted() async {
        if admitted { return }
        await withCheckedContinuation { admittedWaiters.append($0) }
    }

    func releaseWithTerminalWriteFailure() async {
        await bundle.injectWriterFailure(.beforeWrite, in: .work)
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func startWorkChild(
        callbackID: String, prompt: String, name: String?, model: String?, depth: Int
    ) async -> Agent.SpawnStartResult {
        admissionCountStorage += 1
        if !admitted {
            admitted = true
            let waiters = admittedWaiters
            admittedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return .workOwned(
            handleID: handleID, name: name ?? "child", deadline: deadline,
            admissionUncertain: false)
    }

    func startBackground(
        prompt: String, name: String?, model: String?, depth: Int
    ) async -> Agent.SpawnStartResult {
        await startWorkChild(
            callbackID: "unused", prompt: prompt, name: name, model: model, depth: depth)
    }

    func children() async -> [Agent.ChildStatus] { [] }

    func handleStatus(id: String) async -> JSONValue { .object(["id": .string(id)]) }

    func handleResult(id: String, offset: Int) async -> JSONValue {
        .object(["id": .string(id), "offset": .number(Double(offset))])
    }

    func handleAwaitInterest(
        id: String, observerID: String, awaited: Bool
    ) async -> JSONValue {
        .object(["accepted": .bool(true)])
    }
}

private func workSpawnCallbackEvents(
    home: AgentHome, bundle: RunJournalBundle
) throws -> [TimelineEvent] {
    let read = TimelineJournalReader.read(
        try Data(contentsOf: home.timelineV2WorkJournalURL(bundle.work)),
        journal: bundle.workJournal,
        actor: TimelineActor(actorID: "work-spawn-callback-reader", kind: "reader"),
        hostRecordedAt: Date(timeIntervalSince1970: 0))
    guard read.quarantinedSuffix == nil, read.truncatedTail == nil else {
        throw RunJournalBundleError.invalidJournal(
            journal: bundle.workJournal, reason: "callback replay fixture has an invalid tail")
    }
    return read.records.map(\.event)
}

private func testWorkAgentSpawnCallbackReplayRetainsHandleAfterJournalFailure(
    deadline: Date? = Date().addingTimeInterval(60)
) async throws {
    let home = scratchHome()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let hostID = try home.requirePersistedWorkHostID()
    let identity = SessionWorkIdentity(
        sessionID: "work-spawn-replay-session",
        work: WorkRef(workHostID: hostID, workID: "work-spawn-replay-work"),
        runID: "work-spawn-replay-run")
    let bundle = try await RunJournalBundle.openForExecution(
        home: home, identity: identity, actorID: "work-spawn-replay-test",
        modelID: fakeModel().qualifiedID,
        makeAttachmentID: { "work-spawn-replay-attachment" })
    let writer = try SessionWriter(
        home: home, cwd: "/tmp", model: fakeModel(), identity: identity)
    let agent = Agent(
        provider: WorkSpawnUnusedProvider(),
        host: RuntimeHost(executable: "/usr/bin/true", arguments: []),
        writer: writer, hostSession: "work-spawn-replay-runtime",
        config: .init(
            model: fakeModel(), cwd: "/tmp", systemPrompt: "callback replay test",
            maxIterations: 1, maxDepth: 1),
        nativeJournal: bundle)
    let handleID = "agent-child-retained-after-replay"
    let delegate = WorkSpawnReplayDelegate(
        bundle: bundle, handleID: handleID, deadline: deadline)
    await agent.setSpawnDelegate(delegate)

    let payload: JSONValue = .object([
        "prompt": .string("perform one retained child task"),
        "name": .string("retained-child"),
    ])
    let first = Task {
        await agent.serveCallback(rid: "work-spawn-replay-rid", kind: "spawn", payload: payload)
    }
    await delegate.waitUntilAdmitted()
    let concurrentReplay = Task {
        await agent.serveCallback(rid: "work-spawn-replay-rid", kind: "spawn", payload: payload)
    }
    // Keep the first admission gated long enough for the duplicate delivery to join its memoized
    // task. Correctness does not depend on which waiter resumes first.
    try await Task.sleep(nanoseconds: 20_000_000)
    await delegate.releaseWithTerminalWriteFailure()

    let firstReply = await first.value
    let concurrentReply = await concurrentReplay.value
    XCTAssertEqual(firstReply, concurrentReply)
    XCTAssertEqual(firstReply["id"]?.stringValue, handleID)
    XCTAssertEqual(firstReply["ownership"]?.stringValue, "work")
    XCTAssertEqual(firstReply["deadline"], deadline.map { .number($0.timeIntervalSince1970) } ?? .null)
    XCTAssertNotNil(firstReply["warning"], "failed action terminalization must remain visible")
    XCTAssertEqual(await delegate.admissionCount, 1)
    if case .failed = (await bundle.status).health {} else {
        XCTFail("the injected child action outcome failure must latch journal health")
    }

    // The journal is now failed. Replay must still return the exact retained response instead of
    // re-entering journal preflight and losing the admitted Handle.
    let lateReplay = await agent.serveCallback(
        rid: "work-spawn-replay-rid", kind: "spawn", payload: payload)
    XCTAssertEqual(lateReplay, firstReply)
    XCTAssertEqual(await delegate.admissionCount, 1)

    let beforeConflict = try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work))
    let conflict = await agent.serveCallback(
        rid: "work-spawn-replay-rid", kind: "spawn",
        payload: .object([
            "prompt": .string("a different request must not share this identity"),
            "name": .string("retained-child"),
        ]))
    XCTAssertNotNil(conflict["error"])
    XCTAssertNil(conflict["id"])
    XCTAssertEqual(await delegate.admissionCount, 1)
    XCTAssertEqual(
        try Data(contentsOf: home.timelineV2WorkJournalURL(identity.work)), beforeConflict,
        "a conflicting payload must be rejected before any journal write")

    let events = try workSpawnCallbackEvents(home: home, bundle: bundle)
    XCTAssertEqual(
        events.filter {
            $0.type == TimelineEventType.actionStarted
                && $0.payload["kind"]?.stringValue == ActionKind.child.rawValue
        }.count,
        1,
        "all deliveries of one RID must share one durable child action")

    try? await bundle.closeChecked()
    try? await writer.closeChecked()
}
