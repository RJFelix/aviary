import Foundation
@testable import AviaryCore

func test_museCodeEnvironmentUsesAccountLoginSemantics() {
    let environment = MuseCode.scrubbedEnvironment(base: [
        "META_API_KEY": "do-not-forward",
        "OPENAI_API_KEY": "do-not-forward",
        "ANTHROPIC_API_KEY": "do-not-forward",
        "PATH": "/fixture/bin",
        "MUSE_LOGIN": "preserve",
    ])
    XCTAssertNil(environment["META_API_KEY"])
    XCTAssertNil(environment["OPENAI_API_KEY"])
    XCTAssertNil(environment["ANTHROPIC_API_KEY"])
    XCTAssertEqual(environment["MUSE_LOGIN"], "preserve")
    XCTAssertEqual(environment["PATH"], "/fixture/bin")
}

func test_museCodeModelSpecDoesNotInventPricingOrContext() {
    let spec = MuseCode.modelSpec(for: "muse-spark-1.2")
    XCTAssertEqual(spec.id, "muse-spark-1.2")
    XCTAssertEqual(spec.providerID, "muse-code")
    XCTAssertNil(spec.contextWindow)
    XCTAssertNil(spec.costInput)
    XCTAssertNil(spec.costOutput)
    XCTAssertNil(spec.costCacheRead)
    XCTAssertNil(spec.costCacheWrite)
}

func test_museCodeRunEventCarriesAuthoritativeApprovalStage() {
    let requirement = MuseMSPApprovalRequirement(approvalID: "approval-1", sourceIndex: 3)
    let event = MuseCodeRun.Event.approvalPending(
        requirement: requirement,
        choices: ["allow-once", "deny"],
        labels: ["allow-once": "Allow once"],
        detail: "Run the host-provided command?")
    if case .approvalPending(let actual, let choices, let labels, let detail) = event {
        XCTAssertEqual(actual, requirement)
        XCTAssertEqual(choices, ["allow-once", "deny"])
        XCTAssertEqual(labels["allow-once"], "Allow once")
        XCTAssertEqual(detail, "Run the host-provided command?")
    } else {
        XCTFail("approval event lost its authoritative stage")
    }
}

func test_museCodeRunTerminalEventCarriesMatchingTurn() {
    let event = MuseCodeRun.Event.turnFinished(turnID: "turn-7", terminal: "cancelled")
    if case .turnFinished(let turnID, let terminal) = event {
        XCTAssertEqual(turnID, "turn-7")
        XCTAssertEqual(terminal, "cancelled")
    } else {
        XCTFail("terminal event shape changed")
    }
}

func test_museCodeRunUsesCurrentMuseToolAndApprovalViewShapes() throws {
    let tool = try MuseMSPViewEvent(.object([
        "method": .string("item/completed"),
        "params": .object([
            "sessionId": .string("session-1"),
            "viewCursor": .string("cursor-2"),
            "item": .object([
                "itemId": .string("item-1"),
                "kind": .string("toolCall"),
                "revision": .number(2),
                "status": .string("completed"),
                "tool": .string("shell"),
                "args": .string("{\"command\":\"pwd\"}"),
                "visibleOutput": .string("/tmp"),
            ]),
        ]),
    ]))
    XCTAssertEqual(tool.completedItem?["kind"]?.stringValue, "toolCall")
    XCTAssertEqual(tool.completedItem?["tool"]?.stringValue, "shell")
    XCTAssertEqual(tool.completedItem?["visibleOutput"]?.stringValue, "/tmp")

    let approval = try MuseMSPViewEvent(.object([
        "method": .string("approval/request"),
        "params": .object([
            "sessionId": .string("session-1"),
            "viewCursor": .string("cursor-3"),
            "approvalId": .string("approval-1"),
            "currentRequirementId": .object([
                "approvalId": .string("approval-1"), "sourceIndex": .number(1),
            ]),
            "availableChoices": .array([.object([
                "choiceId": .string("allow-once"), "label": .string("Allow once"),
            ])]),
            "toolName": .string("shell"),
            "rawArgs": .string("{\"command\":\"pwd\"}"),
        ]),
    ]))
    XCTAssertEqual(approval.params["currentRequirementId"]?["sourceIndex"]?.intValue, 1)
    XCTAssertEqual(approval.params["availableChoices"]?[0]?["choiceId"]?.stringValue, "allow-once")
}

private final class MuseRunEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MuseCodeRun.Event] = []

    func append(_ event: MuseCodeRun.Event) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [MuseCodeRun.Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func museRunFixture() throws -> (AgentHome, SessionWriter, MuseCodeRun) {
    let home = scratchHome()
    let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
    let run = MuseCodeRun(
        settings: .init(home: home, cwd: "/tmp", model: "muse-spark-1.2"),
        writer: writer)
    return (home, writer, run)
}

private func museRunEvent(
    _ method: String, params: [String: JSONValue], cursor: String = UUID().uuidString
) throws -> MuseMSPViewEvent {
    var body = params
    body["sessionId"] = .string("muse-fixture-session")
    body["viewCursor"] = .string(cursor)
    return try MuseMSPViewEvent(.object([
        "method": .string(method), "params": .object(body),
    ]))
}

private func museItemEvent(
    _ method: String, item: JSONValue, cursor: String = UUID().uuidString
) throws -> MuseMSPViewEvent {
    try museRunEvent(method, params: ["item": item], cursor: cursor)
}

private func museAssistantItems(_ transcript: Transcript) -> [TranscriptItem] {
    transcript.items.filter {
        if case .assistant = $0.kind { return true }
        return false
    }
}

func test_museCodeRunFixtureDoesNotDuplicateUserMessage() async throws {
    let (home, writer, run) = try museRunFixture()
    defer { try? FileManager.default.removeItem(at: home.root) }
    _ = try await writer.appendUser("prompt")
    let item: JSONValue = .object([
        "itemId": .string("user-1"), "kind": .string("userMessage"),
        "revision": .number(1), "status": .string("completed"),
        "text": .string("prompt"),
    ])
    await run.ingestViewEvent(try museItemEvent("item/started", item: item))
    await run.ingestViewEvent(try museItemEvent("item/completed", item: item))
    try await writer.closeChecked()

    let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
    XCTAssertEqual(transcript.counts.user, 1)
    XCTAssertTrue(museAssistantItems(transcript).isEmpty)
}

func test_museCodeRunFixtureKeepsReasoningOutOfAssistantText() async throws {
    let (home, writer, run) = try museRunFixture()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let started: JSONValue = .object([
        "itemId": .string("reasoning-1"), "kind": .string("reasoning"),
        "revision": .number(1), "status": .string("inProgress"),
    ])
    let completed: JSONValue = .object([
        "itemId": .string("reasoning-1"), "kind": .string("reasoning"),
        "revision": .number(2), "status": .string("completed"),
        "summary": .array([.string("private reasoning")]),
    ])
    await run.ingestViewEvent(try museItemEvent("item/started", item: started))
    await run.ingestViewEvent(try museRunEvent("item/delta", params: [
        "itemId": .string("reasoning-1"), "field": .string("summary.0"),
        "delta": .string("private reasoning"),
    ]))
    await run.ingestViewEvent(try museItemEvent("item/completed", item: completed))
    try await writer.closeChecked()

    let assistant = try XCTUnwrap(museAssistantItems(
        XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))).first)
    XCTAssertTrue(assistant.blocks.contains {
        if case .thinking("private reasoning") = $0 { return true }
        return false
    })
    XCTAssertFalse(assistant.blocks.contains {
        if case .text = $0 { return true }
        return false
    })
}

func test_museCodeRunFixtureUsesAuthoritativeCompletedTextAndDeduplicatesRevision() async throws {
    let (home, writer, run) = try museRunFixture()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let started: JSONValue = .object([
        "itemId": .string("message-1"), "kind": .string("agentMessage"),
        "revision": .number(1), "status": .string("inProgress"),
    ])
    let completed: JSONValue = .object([
        "itemId": .string("message-1"), "kind": .string("agentMessage"),
        "revision": .number(2), "status": .string("completed"),
        "text": .string("authoritative final"),
    ])
    await run.ingestViewEvent(try museItemEvent("item/started", item: started))
    await run.ingestViewEvent(try museRunEvent("item/delta", params: [
        "itemId": .string("message-1"), "field": .string("text"),
        "delta": .string("stale partial"),
    ]))
    await run.ingestViewEvent(try museItemEvent("item/completed", item: completed))
    await run.ingestViewEvent(try museItemEvent("item/completed", item: completed))
    try await writer.closeChecked()

    let assistant = museAssistantItems(
        try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
    )
    XCTAssertEqual(assistant.count, 1)
    XCTAssertEqual(assistant[0].blocks.compactMap {
        if case .text(let text) = $0 { return text }
        return nil
    }, ["authoritative final"])
}

func test_museCodeRunFixturePairsToolOnceAndNeverTurnsOutputDeltaIntoAssistantText() async throws {
    let (home, writer, run) = try museRunFixture()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let sink = MuseRunEventSink()
    await run.observe { sink.append($0) }
    let started: JSONValue = .object([
        "itemId": .string("tool-1"), "kind": .string("toolCall"),
        "revision": .number(1), "status": .string("inProgress"),
        "tool": .string("shell"), "args": .string("{\"command\":\"pwd\"}"),
    ])
    let completed: JSONValue = .object([
        "itemId": .string("tool-1"), "kind": .string("toolCall"),
        "revision": .number(2), "status": .string("completed"),
        "tool": .string("shell"), "args": .string("{\"command\":\"pwd\"}"),
        "outputRef": .object(["id": .string("output-1")]),
    ])
    await run.ingestViewEvent(try museItemEvent("item/started", item: started))
    await run.ingestViewEvent(try museRunEvent("item/delta", params: [
        "itemId": .string("tool-1"), "field": .string("output"),
        "delta": .string("not an assistant response"),
    ]))
    await run.ingestViewEvent(try museItemEvent("item/completed", item: completed))
    await run.ingestViewEvent(try museItemEvent("item/completed", item: completed))
    try await writer.closeChecked()

    let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
    let tool = try XCTUnwrap(transcript.items.first { $0.toolCall != nil })
    XCTAssertEqual(tool.toolCall?.name, "shell")
    XCTAssertEqual(tool.toolCall?.arguments["command"]?.stringValue, "pwd")
    XCTAssertTrue(tool.toolResultText?.contains("not fetched") == true)
    XCTAssertFalse(tool.toolResultText?.contains("output-1") == true)
    XCTAssertEqual(sink.events.filter {
        if case .toolStarted("shell") = $0 { return true }
        return false
    }.count, 1)
    XCTAssertEqual(sink.events.filter {
        if case .toolFinished("shell", false) = $0 { return true }
        return false
    }.count, 1)
}

func test_museCodeRunFixtureRequiresMatchingApprovalStage() async throws {
    let (home, writer, run) = try museRunFixture()
    defer { try? FileManager.default.removeItem(at: home.root) }
    let sink = MuseRunEventSink()
    await run.observe { sink.append($0) }
    let choices: JSONValue = .array([.object([
        "choiceId": .string("allow-once"), "label": .string("Allow once"),
    ])])
    let missingStage = try museRunEvent("approval/request", params: [
        "approvalId": .string("approval-1"), "availableChoices": choices,
    ])
    await run.ingestViewEvent(missingStage)
    let mismatchedStage = try museRunEvent("approval/request", params: [
        "approvalId": .string("approval-1"),
        "currentRequirementId": .object([
            "approvalId": .string("other-approval"), "sourceIndex": .number(1),
        ]),
        "availableChoices": choices,
    ])
    await run.ingestViewEvent(mismatchedStage)
    XCTAssertTrue(sink.events.isEmpty)

    let validStage = try museRunEvent("approval/request", params: [
        "approvalId": .string("approval-1"),
        "currentRequirementId": .object([
            "approvalId": .string("approval-1"), "sourceIndex": .number(1),
        ]),
        "availableChoices": choices,
        "toolName": .string("shell"), "rawArgs": .string("{\"command\":\"pwd\"}"),
    ])
    await run.ingestViewEvent(validStage)
    XCTAssertEqual(sink.events.filter {
        if case .approvalPending(let requirement, let ids, let labels, let detail) = $0 {
            return requirement == MuseMSPApprovalRequirement(approvalID: "approval-1", sourceIndex: 1)
                && ids == ["allow-once"] && labels["allow-once"] == "Allow once"
                && detail?.contains("shell") == true
        }
        return false
    }.count, 1)
    try await writer.closeChecked()
}

func test_museCodeRunFixtureProjectsCumulativeUsageWithoutInventingInputOrCost() async throws {
    let (home, writer, run) = try museRunFixture()
    defer { try? FileManager.default.removeItem(at: home.root) }
    func usageEvent(_ cursor: String, prompt: Int, output: Int, total: Int) throws -> MuseMSPViewEvent {
        try museRunEvent("session/tokenUsage", params: [
            "cumulative": .object([
                "promptTokens": .number(Double(prompt)),
                "outputTokens": .number(Double(output)),
                "totalTokens": .number(Double(total)),
            ]),
        ], cursor: cursor)
    }
    await run.ingestViewEvent(try museItemEvent("item/completed", item: .object([
        "itemId": .string("assistant-1"), "kind": .string("agentMessage"),
        "revision": .number(1), "status": .string("completed"),
        "text": .string("first answer"),
    ])))
    await run.ingestViewEvent(try usageEvent("usage-1", prompt: 20, output: 5, total: 25))
    let firstSnapshotCount = await writer.count
    await run.ingestViewEvent(try usageEvent("usage-1-repeat", prompt: 20, output: 5, total: 25))
    XCTAssertEqual(await writer.count, firstSnapshotCount)
    await run.ingestViewEvent(try museItemEvent("item/completed", item: .object([
        "itemId": .string("assistant-2"), "kind": .string("agentMessage"),
        "revision": .number(1), "status": .string("completed"),
        "text": .string("second answer"),
    ])))
    await run.ingestViewEvent(try usageEvent("usage-2", prompt: 40, output: 10, total: 50))
    let afterSecond = await writer.count
    await run.ingestViewEvent(try usageEvent("usage-regression", prompt: 10, output: 2, total: 12))
    XCTAssertEqual(await writer.count, afterSecond)
    let projected = await run.totalUsage
    XCTAssertEqual(projected.totalTokens, 50)
    XCTAssertEqual(projected.output, 10)
    XCTAssertEqual(projected.cost.total, 0)
    try await writer.closeChecked()

    let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
    XCTAssertEqual(museAssistantItems(transcript).count, 2)
    XCTAssertEqual(transcript.usage.totalTokens, 50)
    XCTAssertEqual(transcript.usage.output, 10)
    XCTAssertEqual(transcript.usage.completeness.cost, .unavailable)
    XCTAssertEqual(transcript.usage.completeness.inputAccounting, .unknown)
}

let casesMuseCodeRun: [Case] = [
    ("Muse run fixture: exact cumulative integers survive persistence", {
        let (home, writer, _) = try museRunFixture()
        defer { try? FileManager.default.removeItem(at: home.root) }
        var usage = Usage()
        usage.totalTokens = 9_007_199_254_740_993
        usage.completeness = .init(tokenTotal: .complete, breakdown: .unavailable,
                                   cost: .unavailable, inputAccounting: .unknown)
        try await writer.appendUsageSnapshot(usage, source: "muse-code")
        try await writer.closeChecked()
        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(transcript.usage.totalTokens, usage.totalTokens)
        XCTAssertEqual(transcript.usage.completeness.tokenTotal, .complete)
    }),
    ("Muse run fixture: housekeeping is retained outside conversation", {
        let (home, writer, run) = try museRunFixture()
        defer { try? FileManager.default.removeItem(at: home.root) }
        await run.ingestViewEvent(try museItemEvent("item/completed", item: .object([
            "itemId": .string("reminder-1"), "kind": .string("reminderChild"),
            "revision": .number(1), "status": .string("completed"),
            "fallbackText": .string("Reminder child session"),
        ])))
        try await writer.closeChecked()
        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertFalse(transcript.items.contains { $0.plainText.contains("Reminder child") })
        let bytes = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(bytes.contains("aviary.muse.housekeeping.v1"))
    }),
    ("Muse run fixture: user messages are not duplicated", test_museCodeRunFixtureDoesNotDuplicateUserMessage),
    ("Muse run fixture: reasoning is not assistant text", test_museCodeRunFixtureKeepsReasoningOutOfAssistantText),
    ("Muse run fixture: completed text is authoritative and deduplicated", test_museCodeRunFixtureUsesAuthoritativeCompletedTextAndDeduplicatesRevision),
    ("Muse run fixture: tool lifecycle and output omission are truthful", test_museCodeRunFixturePairsToolOnceAndNeverTurnsOutputDeltaIntoAssistantText),
    ("Muse run fixture: approval requires the current stage", test_museCodeRunFixtureRequiresMatchingApprovalStage),
    ("Muse run fixture: cumulative usage does not invent input or cost", test_museCodeRunFixtureProjectsCumulativeUsageWithoutInventingInputOrCost),
]
