import Foundation
@testable import AviaryCore

/// The transcript parser is the one piece where a silent mistake is invisible: a dropped
/// branch or a mispaired tool result still renders as a plausible conversation. These
/// tests pin the behaviours that are easy to get wrong and hard to notice.

func test_parsesLinearSessionWithToolPairing() throws {
    let jsonl = """
    {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/proj","git":{"branch":"main","commit":"abc"}}
    {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
    {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"toolCall","id":"tc1","name":"ipython","arguments":{"code":"print(1)"}}],"model":"m","provider":"p","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":0,"totalTokens":17,"cost":{"input":0.1,"output":0.2,"cacheRead":0,"cacheWrite":0,"total":0.3}},"stopReason":"toolUse"}}
    {"type":"message","id":"a3","parentId":"a2","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"toolResult","toolCallId":"tc1","toolName":"ipython","content":[{"type":"text","text":"1"}],"isError":false}}
    """
    let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))

    XCTAssertEqual(t.header.cwd, "/tmp/proj")
    XCTAssertEqual(t.header.gitBranch, "main")
    XCTAssertEqual(t.counts.user, 1)
    XCTAssertEqual(t.counts.assistant, 1)
    XCTAssertEqual(t.usage.totalTokens, 17)
    XCTAssertEqual(t.usage.cost.total, 0.3)

    // user, assistant, tool — the tool result folds into the call's row rather than
    // becoming a fourth item.
    XCTAssertEqual(t.items.count, 3)
    let tool = try XCTUnwrap(t.items.last)
    XCTAssertEqual(tool.kind, .tool)
    XCTAssertEqual(tool.toolCall?.pythonCode, "print(1)")
    XCTAssertEqual(tool.toolResultText, "1")
    XCTAssertFalse(tool.toolIsError)
    XCTAssertEqual(tool.toolDuration, 1)
}

func test_rendersOnlyTheActiveBranch() throws {
    // Two children of a1: the abandoned branch (b1) and the live one (c1, c2).
    // The active path is the chain from the LAST written entry back to the root.
    let jsonl = """
    {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}
    {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":"first"}}
    {"type":"message","id":"b1","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"user","content":"abandoned"}}
    {"type":"message","id":"c1","parentId":"a1","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"user","content":"kept"}}
    """
    let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
    let texts = t.items.map(\.plainText)
    XCTAssertEqual(texts, ["first", "kept"])
}

func test_collapsesAgentStatusToLatestOnly() throws {
    // A long session accumulates thousands of these; they are state, not conversation.
    let jsonl = """
    {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}
    {"type":"agent_status","id":"s_1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","status":{"summary":"early","taskState":"working","basedOnMessageCount":1}}
    {"type":"agent_status","id":"s_2","parentId":"s_1","timestamp":"2026-08-20T10:00:02.000Z","status":{"summary":"latest","taskState":"needs_input","basedOnMessageCount":9}}
    """
    let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
    XCTAssertTrue(t.items.isEmpty)
    XCTAssertEqual(t.status?.summary, "latest")
    XCTAssertEqual(t.status?.isAwaitingUser, true)
}

func test_survivesUnknownEntryTypesAndBadLines() throws {
    let jsonl = """
    {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}
    {"type":"a_type_from_the_future","id":"x1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","payload":{"anything":true}}
    not json at all
    {"type":"message","id":"x2","parentId":"x1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"user","content":"still here"}}
    """
    let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
    XCTAssertEqual(t.items.map(\.plainText), ["still here"])
    XCTAssertEqual(t.unparsedLines, 1)
}

func test_doesNotSplitRecordsOnUnicodeLineSeparators() throws {
    // U+2028 is legal inside a JSON string and appears in real tool output. A line
    // reader that treats it as a newline corrupts the record — the harness's own RPC
    // docs call this out.
    let jsonl = "{\"type\":\"session\",\"version\":3,\"id\":\"s1\",\"timestamp\":\"2026-08-20T10:00:00.000Z\",\"cwd\":\"/tmp\"}\n"
        + "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2026-08-20T10:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"before\u{2028}after\"}}"
    let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
    XCTAssertEqual(t.unparsedLines, 0)
    XCTAssertEqual(t.items.first?.plainText, "before\u{2028}after")
}

func test_stripsAnsiAndNormalizesCarriageReturns() {
    let raw = "total 8\r\n\u{1B}[34mdir\u{1B}[m\r\nfile\r"
    XCTAssertEqual(Ansi.strip(raw), "total 8\ndir\nfile\n")
    // An OSC sequence (terminal title) must also go.
    XCTAssertTrue(Ansi.strip("\u{1B}]0;title\u{07}ok") == "ok")
    // Plain text is returned untouched.
    XCTAssertEqual(Ansi.strip("plain"), "plain")
}

func test_classifiesApiKeyForms() {
    XCTAssertEqual(ApiKeyForm.classify("!zsh -ic 'echo hi'"), .command("zsh -ic 'echo hi'"))
    XCTAssertEqual(ApiKeyForm.classify("LITELLM_MASTER_KEY"), .environmentVariable("LITELLM_MASTER_KEY"))
    XCTAssertEqual(ApiKeyForm.classify("sk-abc123def"), .literal)
}

func test_namesTheMissingExportFailureExactly() async {
    // The trap: a bare variable name that is not set. The harness sends the *name* as
    // the credential and the provider answers 401, which reads like a config typo.
    let name = "AVIARY_TEST_DEFINITELY_UNSET_\(UUID().uuidString.prefix(8).uppercased())"
    let r = await ApiKeyResolver.resolve(name)
    guard case .fellBackToLiteralName(let reported) = r.outcome else {
        XCTFail("expected the literal-name fallback, got \(r.outcome)")
        return
    }
    XCTAssertEqual(reported, name)
    XCTAssertFalse(r.ok)
    XCTAssertTrue(r.explanation.contains("zsh -ic"))  // offers the launcher-independent fix
}

func test_resolvesAnEnvironmentVariableThatIsSet() async {
    let r = await ApiKeyResolver.resolve("HOME")
    XCTAssertTrue(r.ok)
    XCTAssertTrue(r.masked != nil)
    XCTAssertTrue(r.length > 0)
}

func test_parsesFrontmatter() {
    let text = """
    ---
    name: my-skill
    description: "Does a thing"
    allowed-tools: ipython, read
    ---
    Body text here.
    """
    let fm = Frontmatter.parse(text)
    XCTAssertEqual(fm.values["name"], "my-skill")
    XCTAssertEqual(fm.values["description"], "Does a thing")
    XCTAssertTrue(fm.body.contains("Body text here."))
}

func test_usageArithmeticAndCacheRate() {
    var a = Usage()
    a.input = 100; a.cacheRead = 300; a.output = 50; a.totalTokens = 450
    a.cost.total = 1.5
    var b = Usage()
    b.input = 100; b.output = 50; b.totalTokens = 150
    b.cost.total = 0.5
    let sum = a + b
    XCTAssertEqual(sum.totalTokens, 600)
    XCTAssertEqual(sum.cost.total, 2.0)
    XCTAssertEqual(a.cacheHitRate, 0.75)
    XCTAssertEqual(b.cacheHitRate, 0.0)
}

func test_jsonValueDottedPathsAndTextContent() {
    let v = JSONValue.parse(line: """
    {"a":{"b":[{"c":42}]},"content":[{"type":"text","text":"x"},{"type":"thinking","thinking":"y"}]}
    """)
    XCTAssertEqual(v?.path("a.b.0.c")?.intValue, 42)
    XCTAssertEqual(v?.path("a.b.9.c"), nil)
    XCTAssertEqual(v?["content"]?.textContent, "xy")
}

func test_formatsNumbersForDenseTables() {
    XCTAssertEqual(Fmt.tokens(999), "999")
    XCTAssertEqual(Fmt.tokens(1_500), "1.5K")
    XCTAssertEqual(Fmt.tokens(2_000), "2K")
    XCTAssertEqual(Fmt.tokens(2_500_000), "2.50M")
    XCTAssertEqual(Fmt.cost(0), "—")
    XCTAssertEqual(Fmt.cost(0.0004), "$0.0004")
    XCTAssertEqual(Fmt.cost(12.345), "$12.35")
}


func test_splitsHookInjectedContextFromTheRealPrompt() {
    // The failure this prevents: every session in the list titled with the same
    // multi-kilobyte preamble, and the actual question invisible.
    let text = "<duckbill-knowledge>\nCurated notes from ~/duckbill/knowledge/.\n  topic-a\n  topic-b\n</duckbill-knowledge>\n\nWhy is the discounts page looping?"
    let split = PromptText.split(text)
    XCTAssertEqual(split.injected.count, 1)
    XCTAssertEqual(split.injected.first?.tag, "duckbill-knowledge")
    XCTAssertEqual(split.userText, "Why is the discounts page looping?")
    XCTAssertEqual(PromptText.userFacing(text), "Why is the discounts page looping?")
}

func test_peelsSeveralStackedInjections() {
    let text = "<system-reminder>a</system-reminder><duckbill-knowledge>b</duckbill-knowledge>\nreal question"
    let split = PromptText.split(text)
    XCTAssertEqual(split.injected.map(\.tag), ["system-reminder", "duckbill-knowledge"])
    XCTAssertEqual(split.userText, "real question")
}

func test_keepsTheMessageWhenTheWrapperIsAllThereIs() {
    // Peeling everything would leave an empty prompt, which is worse than showing the block.
    let split = PromptText.split("<note>only this</note>")
    XCTAssertEqual(split.userText, "only this")
    XCTAssertTrue(split.injected.isEmpty)
}

func test_leavesOrdinaryPromptsAlone() {
    XCTAssertEqual(PromptText.userFacing("just a normal question"), "just a normal question")
    // An unclosed angle bracket must not eat the message.
    XCTAssertEqual(PromptText.userFacing("<not closed and then text"), "<not closed and then text")
    // Inline markup is not an injection.
    XCTAssertEqual(PromptText.userFacing("use <T> generics"), "use <T> generics")
}

func test_decomposesAResponsesPayload() {
    // The shape the codex/responses routes actually send.
    let payload = JSONValue.parse(line: """
    {"model":"gpt-5.6-luna","instructions":"You are an agent.\\n# Project Context\\n## /repo/AGENTS.md\\nproject rules here\\n<available_skills><name>alpha</name><description>aaaa</description><name>beta</name><description>bbbbbbbb</description></available_skills>","input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}],"tools":[{"type":"function","name":"ipython","description":"run code"}],"stream":true}
    """)!
    let a = WireLog.analyse(payload: payload)
    XCTAssertEqual(a.shape, "openai-responses")

    let labels = a.segments.map(\.label)
    XCTAssertTrue(labels.contains("system prompt"), "got \(labels)")
    XCTAssertTrue(labels.contains { $0.hasPrefix("tools") })
    XCTAssertTrue(labels.contains { $0.hasPrefix("input") })

    // Shares must account for the payload, not a subset of it.
    let system = try? XCTUnwrap(a.segments.first { $0.kind == .systemPrompt })
    XCTAssertNotNil(system)
    XCTAssertTrue((system?.characters ?? 0) > 0)

    // The skills catalogue is broken out per skill, largest first — the whole point.
    let skills = a.segments.flatMap(\.flattened).first { $0.kind == .skills }
    XCTAssertNotNil(skills)
    XCTAssertEqual(skills?.children.count, 2)
    XCTAssertEqual(skills?.children.first?.label, "beta")  // the larger entry sorts first

    // A discovered context file is recognised as such, by basename.
    let file = a.segments.flatMap(\.flattened).first { $0.kind == .contextFile }
    XCTAssertEqual(file?.label, "AGENTS.md")
}

func test_decomposesAnAnthropicPayload() {
    let payload = JSONValue.parse(line: """
    {"model":"claude","system":"be brief","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"yo"}],"max_tokens":16}
    """)!
    let a = WireLog.analyse(payload: payload)
    XCTAssertEqual(a.shape, "anthropic-messages")
    let messages = a.segments.first { $0.kind == .message }
    XCTAssertEqual(messages?.children.count, 2)
}

func test_treatsALeadingSystemMessageAsTheSystemPrompt() {
    // Completions-style routes put the system prompt in messages[0].
    let payload = JSONValue.parse(line: """
    {"model":"m","messages":[{"role":"system","content":"rules"},{"role":"user","content":"hi"}]}
    """)!
    let a = WireLog.analyse(payload: payload)
    XCTAssertNotNil(a.segments.first { $0.kind == .systemPrompt })
    XCTAssertEqual(a.segments.first { $0.kind == .message }?.children.count, 1)
}

func test_scalesPartTokensToTheBilledTotal() {
    // A part's share is exact even though its token count is estimated, so scaling by the
    // provider's real input count is the honest per-part number.
    var seg = PayloadSegment(id: "x", label: "x", characters: 250)
    XCTAssertEqual(seg.estimatedTokens, 62)
    XCTAssertEqual(seg.scaledTokens(payloadCharacters: 1000, actualTokens: 400), 100)
    XCTAssertEqual(seg.share(of: 1000), 0.25)
    // Degrades to the estimate rather than to zero when nothing is known.
    seg.characters = 400
    XCTAssertEqual(seg.scaledTokens(payloadCharacters: 0, actualTokens: 0), 100)
}

func test_readsAWireLogAndFindsItsSession() throws {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "aviary-wire-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "wire.jsonl")
    let lines = [
        // sessionFile, not the payload's prompt_cache_key: that field looks exactly like a
        // session id and is not one — on a real run the key was 01a0222d-510c… while the
        // session on disk was 01a0222d-4ec9….
        #"{"v":1,"seq":0,"at":"2026-08-20T10:00:00.000Z","kind":"request","sessionFile":"/s/sess-1.jsonl","payload":{"model":"m","prompt_cache_key":"not-a-session-id","instructions":"hi"}}"#,
        #"{"v":1,"seq":1,"at":"2026-08-20T10:00:01.000Z","kind":"response","status":200}"#,
        "not json at all",
    ].joined(separator: "\n")
    try Data(lines.utf8).write(to: file)

    let records = WireLog.read(url: file)
    XCTAssertEqual(records.count, 2)  // the junk line is skipped, not fatal
    XCTAssertEqual(records.first?.kind, .request)
    XCTAssertEqual(records.first?.sessionID, "sess-1")
    // The lookalike cache key must not be mistaken for the session.
    XCTAssertEqual(records.first?.payload?["prompt_cache_key"]?.stringValue, "not-a-session-id")
    XCTAssertEqual(records.first?.modelID, "m")
    XCTAssertEqual(records.last?.status, 200)
    try? FileManager.default.removeItem(at: dir)
}

func test_usageReasoningIsABreakdownNotAnAddend() {
    var a = Usage()
    a.output = 100; a.reasoning = 80; a.totalTokens = 100
    var b = Usage()
    b.output = 50; b.totalTokens = 50   // route reported no reasoning at all
    let sum = a + b
    // Summing keeps what is known and does not invent zeros.
    XCTAssertEqual(sum.reasoning, 80)
    XCTAssertEqual(sum.output, 150)
    // Two unknowns stay unknown, which is different from zero.
    XCTAssertNil((b + b).reasoning)
}

func test_attributesContextFileBodyToItsFile() {
    // A context file's body is markdown and routinely opens with its own `# ` heading.
    // Splitting on that heading would credit the file's contents to a phantom section and
    // report the file as a few dozen characters — misplacing the largest thing a project
    // contributes to every request.
    let instructions = [
        "base rules",
        "# Project Context",
        "## /repo/AGENTS.md",
        "# My Project",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "## Layout",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    ].joined(separator: "\n")
    let seg = WireLog.systemPromptSegment(instructions)
    let file = seg.children.first { $0.kind == .contextFile }
    XCTAssertEqual(file?.label, "AGENTS.md")
    // The file must carry its whole body, headings included.
    XCTAssertTrue(file?.text?.contains("# My Project") == true)
    XCTAssertTrue(file?.text?.contains("bbbbbbbb") == true)
    // And no phantom section should have been created from the body's heading.
    XCTAssertNil(seg.children.first { $0.label == "My Project" })
}

func test_sessionIdentityIsTheFilenameNotTheHeaderField() throws {
    // Real sessions disagree: 68 of 80 in one checkout had a header `id` that was not the
    // filename. The filename is what session-artifacts/, the spawn ledger's
    // parentSessionId, and `list --json` all key on, so it is the identity. Using the
    // header field silently breaks live-state matching, sub-agent grouping, kernel lookup
    // and payload attribution — each of which then looks like missing data.
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "aviary-id-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "file-stem-id.jsonl")
    let jsonl = [
        #"{"type":"session","version":3,"id":"a-different-header-id","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}"#,
        #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":"hi"}}"#,
    ].joined(separator: "\n")
    try Data(jsonl.utf8).write(to: file)

    let summary = try XCTUnwrap(SessionCatalog.summarize(fileURL: file))
    XCTAssertEqual(summary.id, "file-stem-id")
    XCTAssertEqual(summary.headerID, "a-different-header-id")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Runner




/// A spawn delegate that should never be reached — used to prove the depth ceiling refuses
/// before any child is created.
struct RefusingDelegate: Agent.SpawnDelegate {
    func spawn(
        prompt: String, name: String?, model: String?, depth: Int
    ) async -> (answer: String, isError: Bool, childID: String, name: String) {
        ("a child should not have been started", true, "sub-none", "none")
    }
}


/// A skill entry with just the fields the gate reads.
func fakeSkill(_ name: String, _ description: String) -> SkillEntry {
    SkillEntry(
        name: name, description: description,
        url: URL(fileURLWithPath: "/tmp/skills/\(name)/SKILL.md"),
        sourceLabel: "test", precedence: 0, bodyLength: description.count,
        hasPythonBacking: false, allowedTools: [])
}

// MARK: - Agent test helpers

/// A scripted openai-completions server, so the loop can be asserted without a provider.
///
/// Testing the loop against a live model is not possible in any useful sense — you cannot
/// assert that a model will decide to call a tool — and paying for a round trip to find out is
/// a bad test. This serves a fixed script, which makes the interesting path assertable: request
/// encoding, SSE framing, tool-call reassembly, execution in the runtime host, and the result
/// going back for a second turn.
final class FakeProviderServer {
    let port: Int
    private let process: Process
    private let scriptURL: URL

    init?(script: [[String: Any]]) throws {
        guard let root = EngineLocator.repoRoot() else { return nil }
        let fixture = root.appending(path: "test-fixtures/fake-openai.py")
        guard FileManager.default.fileExists(atPath: fixture.path) else { return nil }

        // A port from the ephemeral range, chosen per instance so concurrent cases cannot
        // collide on a fixed one.
        port = Int.random(in: 41000..<48000)
        scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-fake-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: script).write(to: scriptURL)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", fixture.path, "\(port)", scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()

        // Wait for the readiness line rather than sleeping: a fixed sleep is either flaky or
        // slow, and this is neither.
        let handle = out.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
                if String(data: buffer, encoding: .utf8)?.contains("listening") == true { return }
            }
        }
        process.terminate()
        return nil
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// Exactly what the client sent, so encoding is asserted rather than assumed.
    func recordedRequests() throws -> [JSONValue] {
        let url = URL(string: "http://127.0.0.1:\(port)/_requests")!
        let data = try Data(contentsOf: url)
        return JSONValue.parse(data)?.arrayValue ?? []
    }

    func stop() {
        process.terminate()
        try? FileManager.default.removeItem(at: scriptURL)
    }
}

/// A model pointed at the fake server.
func fakeModel() -> ModelSpec {
    var m = ModelSpec(rpc: .object([
        "id": .string("test-model"),
        "provider": .string("fake"),
    ]))
    m.contextWindow = 100_000
    return m
}

/// A session writer in a throwaway agent directory, so tests never touch the real store.
func scratchHome() -> AgentHome {
    AgentHome(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aviary-agent-test-\(UUID().uuidString)"))
}

/// Collects agent events off whatever task emits them.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var text = ""

    func record(_ event: Agent.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .started: events.append("started")
        case .textDelta(let t): text += t
        case .thinkingDelta: events.append("thinking")
        case .toolStarted(_, let name, _): events.append("tool:\(name)")
        case .toolFinished(_, _, _, let isError): events.append(isError ? "tool-error" : "tool-ok")
        case .turnFinished: events.append("turn")
        case .compacted(let before, _, _): events.append("compacted:\(before)")
        case .childStarted(_, let name, _): events.append("child:\(name)")
        case .childFinished(_, _, _, let isError): events.append(isError ? "child-error" : "child-ok")
        case .finished(let reason): events.append("finished:\(reason)")
        case .failed: events.append("failed")
        }
    }

    var names: [String] { lock.lock(); defer { lock.unlock() }; return events }
    var assistantText: String { lock.lock(); defer { lock.unlock() }; return text }
}

// MARK: - Runtime host test helpers

enum HostVariant: String {
    case reference = "python3"
    case shared = "python3-shared"
}

/// Build a client for one of the bundled hosts, or nil if this machine cannot run it.
///
/// Returning nil rather than failing keeps the suite honest on a machine without Python: a
/// skipped integration test is information, a red one that means "you lack an interpreter" is
/// noise. The skip is printed so it cannot pass silently.
func makeHost(_ variant: HostVariant) throws -> RuntimeHost? {
    guard let root = EngineLocator.repoRoot() else {
        print("      skipped: no repo root found")
        return nil
    }
    let script = root.appending(path: "runtime-hosts/\(variant.rawValue)/host.py")
    guard FileManager.default.fileExists(atPath: script.path) else {
        print("      skipped: \(script.lastPathComponent) missing for \(variant.rawValue)")
        return nil
    }
    return RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", script.path])
}

/// Collects streamed output events from a host. Locked because the events arrive on the
/// client's reader task, not the test's.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    private var seen: [String] = []

    func record(stream: String, text: String) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(text)
        seen.append(stream)
    }

    var text: String { lock.lock(); defer { lock.unlock() }; return chunks.joined() }
    var streams: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}

await Harness.run([
    ("parsesLinearSessionWithToolPairing", { try test_parsesLinearSessionWithToolPairing() }),
    ("rendersOnlyTheActiveBranch", { try test_rendersOnlyTheActiveBranch() }),
    ("collapsesAgentStatusToLatestOnly", { try test_collapsesAgentStatusToLatestOnly() }),
    ("survivesUnknownEntryTypesAndBadLines", { try test_survivesUnknownEntryTypesAndBadLines() }),
    ("doesNotSplitRecordsOnUnicodeLineSeparators", { try test_doesNotSplitRecordsOnUnicodeLineSeparators() }),
    ("stripsAnsiAndNormalizesCarriageReturns", { test_stripsAnsiAndNormalizesCarriageReturns() }),
    ("classifiesApiKeyForms", { test_classifiesApiKeyForms() }),
    ("namesTheMissingExportFailureExactly", { await test_namesTheMissingExportFailureExactly() }),
    ("resolvesAnEnvironmentVariableThatIsSet", { await test_resolvesAnEnvironmentVariableThatIsSet() }),
    ("parsesFrontmatter", { test_parsesFrontmatter() }),
    ("usageArithmeticAndCacheRate", { test_usageArithmeticAndCacheRate() }),
    ("jsonValueDottedPathsAndTextContent", { test_jsonValueDottedPathsAndTextContent() }),
    ("formatsNumbersForDenseTables", { test_formatsNumbersForDenseTables() }),
    ("splitsHookInjectedContextFromTheRealPrompt", { test_splitsHookInjectedContextFromTheRealPrompt() }),
    ("peelsSeveralStackedInjections", { test_peelsSeveralStackedInjections() }),
    ("keepsTheMessageWhenTheWrapperIsAllThereIs", { test_keepsTheMessageWhenTheWrapperIsAllThereIs() }),
    ("leavesOrdinaryPromptsAlone", { test_leavesOrdinaryPromptsAlone() }),
    ("decomposesAResponsesPayload", { test_decomposesAResponsesPayload() }),
    ("decomposesAnAnthropicPayload", { test_decomposesAnAnthropicPayload() }),
    ("treatsALeadingSystemMessageAsTheSystemPrompt", { test_treatsALeadingSystemMessageAsTheSystemPrompt() }),
    ("scalesPartTokensToTheBilledTotal", { test_scalesPartTokensToTheBilledTotal() }),
    ("readsAWireLogAndFindsItsSession", { try test_readsAWireLogAndFindsItsSession() }),
    ("usageReasoningIsABreakdownNotAnAddend", { test_usageReasoningIsABreakdownNotAnAddend() }),
    ("attributesContextFileBodyToItsFile", { test_attributesContextFileBodyToItsFile() }),
    ("sessionIdentityIsTheFilenameNotTheHeaderField", { try test_sessionIdentityIsTheFilenameNotTheHeaderField() }),

    ("workshop: fold builds a request from a created event", {
        let line = #"{"v":1,"at":"2026-08-21T10:00:00.000Z","event":"created","id":"wr-1","title":"Fix the thing","body":"detail","kind":"bug"}"#
        let out = WorkshopLog.fold(lines: [line])
        XCTAssertEqual(out.count, 1)
        let r = try XCTUnwrap(out.first)
        XCTAssertEqual(r.id, "wr-1")
        XCTAssertEqual(r.title, "Fix the thing")
        XCTAssertEqual(r.kind, .bug)
        XCTAssertEqual(r.status, .open)
        XCTAssertFalse(r.delivered)
    }),

    ("workshop: later status events win and accumulate notes", {
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"status","id":"a","at":"2026-08-21T10:05:00.000Z","status":"claimed","note":"looking","by":"agent"}"#,
            #"{"event":"status","id":"a","at":"2026-08-21T10:09:00.000Z","status":"done","note":"shipped","by":"agent"}"#,
        ]
        let r = try XCTUnwrap(WorkshopLog.fold(lines: lines).first)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(r.notes.count, 2, "both status notes are kept, not just the last")
        XCTAssertEqual(r.notes.last?.text, "shipped")
    }),

    ("workshop: a malformed line is skipped, not fatal", {
        // The agent hand-writes into this file. One bad line must not cost the board.
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"kept","kind":"idea"}"#,
            "{ this is not json",
            "",
            #"{"event":"created","id":"b","at":"2026-08-21T11:00:00.000Z","title":"also kept","kind":"idea"}"#,
        ]
        XCTAssertEqual(WorkshopLog.fold(lines: lines).count, 2)
    }),

    ("workshop: events for an unknown id are ignored", {
        let lines = [
            #"{"event":"status","id":"ghost","at":"2026-08-21T10:00:00.000Z","status":"done"}"#,
        ]
        XCTAssertEqual(WorkshopLog.fold(lines: lines).count, 0)
    }),

    ("workshop: newest request sorts first", {
        let lines = [
            #"{"event":"created","id":"old","at":"2026-08-20T10:00:00.000Z","title":"o","kind":"change"}"#,
            #"{"event":"created","id":"new","at":"2026-08-21T10:00:00.000Z","title":"n","kind":"change"}"#,
        ]
        XCTAssertEqual(WorkshopLog.fold(lines: lines).first?.id, "new")
    }),

    ("workshop: delivered and link events fold in", {
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"delivered","id":"a","at":"2026-08-21T10:00:01.000Z","session":"01a0-abc"}"#,
            #"{"event":"link","id":"a","at":"2026-08-21T10:30:00.000Z","commit":"deadbee"}"#,
            #"{"event":"link","id":"a","at":"2026-08-21T10:31:00.000Z","commit":"deadbee"}"#,
        ]
        let r = try XCTUnwrap(WorkshopLog.fold(lines: lines).first)
        XCTAssertTrue(r.delivered)
        XCTAssertEqual(r.sessions, ["01a0-abc"])
        XCTAssertEqual(r.commits.count, 1, "a repeated commit link is not duplicated")
    }),

    ("workshop: context survives a round trip through the log", {
        var ctx = WorkshopContext(section: "sessions", sectionSubtitle: "3 of 80")
        ctx.facts = [
            .init(group: "Screen", label: "Tab", value: "Sessions"),
            .init(group: "State", label: "Daemon", value: "healthy"),
        ]
        ctx.screenshot = "shots/wr-1.png"
        let encoded = WorkshopLog.encode(ctx)
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let payload = JSONValue.object([
            "event": .string("created"), "id": .string("wr-1"),
            "at": .string("2026-08-21T10:00:00.000Z"),
            "title": .string("t"), "kind": .string("change"),
            "context": encoded,
        ])
        let line = String(data: try enc.encode(payload), encoding: .utf8) ?? ""
        let r = try XCTUnwrap(WorkshopLog.fold(lines: [line]).first)
        let back = try XCTUnwrap(r.context)
        XCTAssertEqual(back.section, "sessions")
        XCTAssertEqual(back.facts.count, 2)
        XCTAssertEqual(back.screenshot, "shots/wr-1.png")
        XCTAssertEqual(back.groups, ["Screen", "State"], "group order is preserved")
    }),

    ("workshop: status maps onto four board columns", {
        XCTAssertEqual(WorkshopStatus.open.column, .inbox)
        XCTAssertEqual(WorkshopStatus.claimed.column, .working)
        XCTAssertEqual(WorkshopStatus.building.column, .working)
        XCTAssertEqual(WorkshopStatus.done.column, .done)
        XCTAssertEqual(WorkshopStatus.declined.column, .shelved)
        XCTAssertEqual(WorkshopStatus.parked.column, .shelved)
    }),

    ("workshop: undelivered counts only open requests never sent", {
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"created","id":"b","at":"2026-08-21T10:01:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"delivered","id":"b","at":"2026-08-21T10:01:01.000Z"}"#,
            #"{"event":"created","id":"c","at":"2026-08-21T10:02:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"status","id":"c","at":"2026-08-21T10:03:00.000Z","status":"done"}"#,
        ]
        let board = WorkshopBoard(requests: WorkshopLog.fold(lines: lines))
        XCTAssertEqual(board.undeliveredCount, 1, "only 'a' is open and unsent")
        XCTAssertEqual(board.openCount, 2)
        XCTAssertEqual(board.doneCount, 1)
    }),

    ("workshop: the prompt envelope names the id and both paths", {
        var r = WorkshopRequest(
            id: "wr-42", createdAt: Date(), title: "Tighten the inspector",
            body: "It clips.", kind: .bug, status: .open, statusChangedAt: Date())
        r.context = WorkshopContext(
            section: "sessions", facts: [.init(group: "Screen", label: "Tab", value: "Sessions")],
            screenshot: "shots/wr-42.png")
        let text = r.promptEnvelope(logPath: "workshop/requests.jsonl", briefPath: "workshop/AGENT.md")
        XCTAssertTrue(text.contains("wr-42"), "the agent must be able to address the request")
        XCTAssertTrue(text.contains("workshop/requests.jsonl"))
        XCTAssertTrue(text.contains("workshop/AGENT.md"))
        XCTAssertTrue(text.contains("shots/wr-42.png"))
        XCTAssertTrue(text.contains("Tab: Sessions"), "context renders as markdown")
        XCTAssertTrue(text.contains("Append only"))
    }),

    ("workshop: ids are sortable and distinct", {
        var n: UInt32 = 0
        let a = Workshop.newID(date: Date(timeIntervalSince1970: 1_770_000_000), random: { n += 1; return n })
        let b = Workshop.newID(date: Date(timeIntervalSince1970: 1_770_000_000), random: { n += 1; return n })
        XCTAssertTrue(a.hasPrefix("wr-"))
        XCTAssertFalse(a == b, "two ids minted in the same second differ")
    }),

    ("workshop: append then load round-trips through a real file", {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-workshop-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try WorkshopLog.append(
            WorkshopEvent(event: "created", id: "wr-x", fields: [
                "title": .string("round trip"), "kind": .string("question"),
            ]), repoRoot: dir)
        try WorkshopLog.append(
            WorkshopEvent(event: "status", id: "wr-x", fields: [
                "status": .string("declined"), "note": .string("out of scope"), "by": .string("agent"),
            ]), repoRoot: dir)
        let out = WorkshopLog.load(repoRoot: dir)
        XCTAssertEqual(out.count, 1)
        let r = try XCTUnwrap(out.first)
        XCTAssertEqual(r.status, .declined)
        XCTAssertEqual(r.kind, .question)
        XCTAssertEqual(r.notes.first?.text, "out of scope")
        // Two appends, two lines — the second must not have rewritten the first.
        let text = try String(contentsOf: Workshop.logURL(repoRoot: dir), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }),

    ("fmt: relative time is terse", {
        let now = Date()
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-600), now: now), "10m")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-172800), now: now), "2d")
    }),

    ("workshop: an aviary-written claimed event moves the card out of the inbox", {
        // Regression: the first real request sat in Inbox while a session visibly worked on
        // it, because only the agent could change status. Delivery now records the hand-off.
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"delivered","id":"a","at":"2026-08-21T10:00:05.000Z","session":"01a0-x"}"#,
            #"{"event":"status","id":"a","at":"2026-08-21T10:00:05.100Z","status":"claimed","note":"Handed to the workshop agent.","by":"aviary"}"#,
        ]
        let board = WorkshopBoard(requests: WorkshopLog.fold(lines: lines))
        XCTAssertEqual(board.openCount, 0, "no longer waiting")
        XCTAssertEqual(board.workingCount, 1)
        XCTAssertEqual(board.undeliveredCount, 0)
        let r = try XCTUnwrap(board.requests.first)
        XCTAssertTrue(r.delivered)
        XCTAssertEqual(r.notes.first?.by, "aviary", "the hand-off is attributed, not anonymous")
    }),

    ("workshop: an agent status supersedes aviary's claim", {
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"status","id":"a","at":"2026-08-21T10:00:05.000Z","status":"claimed","by":"aviary"}"#,
            #"{"event":"status","id":"a","at":"2026-08-21T10:02:00.000Z","status":"building","note":"editing","by":"agent"}"#,
            #"{"event":"status","id":"a","at":"2026-08-21T10:40:00.000Z","status":"done","note":"shipped","by":"agent"}"#,
        ]
        let r = try XCTUnwrap(WorkshopLog.fold(lines: lines).first)
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(r.notes.count, 2, "aviary's note had no text; both agent notes kept")
    }),

    ("workshop: a link event can carry the session id on its own", {
        // The session id does not exist until the engine has booted, so it arrives after
        // delivery rather than with it.
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"change"}"#,
            #"{"event":"delivered","id":"a","at":"2026-08-21T10:00:05.000Z"}"#,
            #"{"event":"link","id":"a","at":"2026-08-21T10:00:40.000Z","session":"01a0-late"}"#,
        ]
        let r = try XCTUnwrap(WorkshopLog.fold(lines: lines).first)
        XCTAssertTrue(r.delivered)
        XCTAssertEqual(r.sessions, ["01a0-late"])
    }),

    ("workshop: a daemon-conflict failure is turned into an instruction", {
        // The real failure text from the first request that silently did not deliver.
        let output = "daemon-launch: running daemon on /tmp/prime-agent-501/daemon.sock is "
            + "stale: daemon v0.7.4-beta.531.1.c75a637 vs client v0.7.4\n"
            + "daemon-launch: refusing to replace stale daemon: busy session(s) present"
        let remedy = try XCTUnwrap(Workshop.remedy(for: output))
        XCTAssertTrue(remedy.contains("daemon-reset"), "names the recipe that fixes it")
        XCTAssertNil(Workshop.remedy(for: "ECONNREFUSED"), "unknown failures get no false advice")
    }),

    ("workshop: a failed delivery leaves the request open with a note", {
        // Aviary writes a note, not a status: nothing about the request changed, only our
        // attempt to hand it over.
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"bug"}"#,
            #"{"event":"note","id":"a","at":"2026-08-21T10:00:20.000Z","text":"Delivery failed — the engine did not start (exit 1).","by":"aviary"}"#,
        ]
        let board = WorkshopBoard(requests: WorkshopLog.fold(lines: lines))
        let r = try XCTUnwrap(board.requests.first)
        XCTAssertEqual(r.status, .open, "still waiting, not falsely in progress")
        XCTAssertFalse(r.delivered, "and not falsely marked delivered")
        XCTAssertEqual(board.undeliveredCount, 1, "so the banner can say so")
        XCTAssertEqual(r.notes.first?.by, "aviary")
    }),

    ("workshop: a delivery can be retracted by a later event", {
        let lines = [
            #"{"event":"created","id":"a","at":"2026-08-21T10:00:00.000Z","title":"t","kind":"bug"}"#,
            #"{"event":"delivered","id":"a","at":"2026-08-21T10:00:05.000Z"}"#,
            #"{"event":"delivered","id":"a","at":"2026-08-21T10:30:00.000Z","retracted":true}"#,
        ]
        let board = WorkshopBoard(requests: WorkshopLog.fold(lines: lines))
        let r = try XCTUnwrap(board.requests.first)
        XCTAssertFalse(r.delivered, "the retraction wins because it is later")
        XCTAssertEqual(board.undeliveredCount, 1)
    }),

    // ---------------------------------------------------------------- runtime host
    //
    // These drive the real host process rather than a mock. The protocol is the whole
    // contract between Aviary and any runtime, so a test that stubs it proves nothing about
    // whether a runtime actually behaves. Both hosts are run through the same assertions
    // wherever the assertion is part of the contract — that is what makes "swappable" a
    // claim rather than a hope.

    ("runtimeHost: starts, declares capabilities, and stops", {
        guard let host = try makeHost(.reference) else { return }
        let caps = try await host.start()
        XCTAssertEqual(caps.protocolVersion, 2)
        XCTAssertEqual(caps.runtime, "cpython")
        XCTAssertFalse(caps.runtimeVersion.isEmpty)
        XCTAssertTrue(caps.has("namespaceInspection"))
        // An undeclared feature must read as absent, never as unknown-so-probably-fine.
        XCTAssertFalse(caps.has("teleportation"))
        await host.stop()
    }),

    ("runtimeHost: state persists across separate executions", {
        // The premise of the whole design: work accumulates instead of being rebuilt.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession(id: "persist")
        _ = try await host.execute("x = 41", in: s)
        _ = try await host.execute("y = x + 1", in: s)
        let r = try await host.execute("y", in: s)
        XCTAssertEqual(r.value, "42")
        XCTAssertNil(r.exception)
        await host.stop()
    }),

    ("runtimeHost: a trailing expression is echoed like a REPL", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession()
        let r = try await host.execute("print('hi')\n2 ** 10", in: s)
        XCTAssertEqual(r.value, "1024")
        XCTAssertEqual(r.stdout, "hi\n")
        // A statement-only cell has no value to echo, and must not invent one.
        let q = try await host.execute("q = 1", in: s)
        XCTAssertNil(q.value)
        await host.stop()
    }),

    ("runtimeHost: agent exceptions are data, not host failures", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession()
        let r = try await host.execute("1/0", in: s)
        XCTAssertTrue(r.failed)
        XCTAssertTrue((r.exception ?? "").contains("ZeroDivisionError"))
        // And the session is still usable afterwards — a raise is not a death.
        let after = try await host.execute("'alive'", in: s)
        XCTAssertEqual(after.value, "'alive'")
        await host.stop()
    }),

    ("runtimeHost: SystemExit in agent code does not take the host down", {
        // The failure mode that would otherwise turn one bad cell into a lost session.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession()
        let r = try await host.execute("raise SystemExit(3)", in: s)
        XCTAssertTrue((r.exception ?? "").contains("SystemExit"))
        let after = try await host.execute("1 + 1", in: s)
        XCTAssertEqual(after.value, "2")
        await host.stop()
    }),

    ("runtimeHost: sessions cannot see each other's names", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let a = try await host.createSession(id: "a")
        let b = try await host.createSession(id: "b")
        _ = try await host.execute("secret = 'a-only'", in: a)
        let leak = try await host.execute("'secret' in dir()", in: b)
        XCTAssertEqual(leak.value, "False")
        let list = try await host.sessions()
        XCTAssertTrue(list.contains("a") && list.contains("b"))
        try await host.destroySession(a)
        XCTAssertFalse(try await host.sessions().contains("a"))
        await host.stop()
    }),

    ("runtimeHost: inspect reads the namespace and leaves no trace in it", {
        // The capability a Jupyter kernel could not offer: listing names there meant running
        // a cell, which mutated In/Out and could shadow the names being listed.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession()
        _ = try await host.execute("nums = [1, 2, 3]\nlabel = 'hi'", in: s)
        let first = try await host.inspect(s)
        XCTAssertEqual(first.bindings.map(\.name), ["label", "nums"])
        XCTAssertEqual(first.bindings.first { $0.name == "nums" }?.type, "list")
        XCTAssertEqual(first.bindings.first { $0.name == "nums" }?.length, 3)
        // Nothing the host used may be visible to the agent, and inspecting twice must not
        // grow the namespace.
        for b in first.bindings {
            XCTAssertFalse(b.name.hasPrefix("__aviary"), "host name leaked: \(b.name)")
            XCTAssertFalse(b.name.hasPrefix("__AVIARY"), "host name leaked: \(b.name)")
        }
        let second = try await host.inspect(s)
        XCTAssertEqual(first.bindings.map(\.name), second.bindings.map(\.name))
        await host.stop()
    }),

    ("runtimeHost: cd and export persist across calls", {
        // The measured 19.7%: cells doing working-directory bookkeeping by hand because
        // subprocess starts every child in the same place.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession(cwd: "/usr")
        _ = try await host.execute("sh('cd /usr/lib')", in: s)
        let where1 = try await host.execute("cwd()", in: s)
        XCTAssertEqual(where1.value, "'/usr/lib'")
        let where2 = try await host.execute("sh('pwd')['stdout'].strip()", in: s)
        XCTAssertEqual(where2.value, "'/usr/lib'")
        _ = try await host.execute("sh('export AVIARY_SUITE=7')", in: s)
        let env = try await host.execute("sh('echo $AVIARY_SUITE')['stdout'].strip()", in: s)
        XCTAssertEqual(env.value, "'7'")
        await host.stop()
    }),

    ("runtimeHost: output arrives as events before the result settles", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let collector = OutputCollector()
        await host.onOutput { _, stream, text in collector.record(stream: stream, text: text) }
        let s = try await host.createSession()
        _ = try await host.execute("print('streamed')", in: s)
        XCTAssertTrue(collector.text.contains("streamed"), "expected a streamed output event")
        XCTAssertEqual(collector.streams.first, "stdout")
        await host.stop()
    }),

    ("runtimeHost: a bad request is rejected without killing the host", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        do {
            _ = try await host.execute("1", in: "no-such-session")
            XCTFail("expected a rejection for an unknown session")
        } catch let error as RuntimeHost.HostError {
            guard case .rejected(let code, _) = error else {
                XCTFail("expected .rejected, got \(error)"); return
            }
            XCTAssertEqual(code, "no_session")
        }
        // Still serving.
        let s = try await host.createSession()
        XCTAssertEqual(try await host.execute("'ok'", in: s).value, "'ok'")
        await host.stop()
    }),

    ("runtimeHost: the two hosts declare their trade-off honestly", {
        // Swappability is only real if a caller can tell what it is getting. These are the
        // capabilities Aviary would route on.
        guard let ref = try makeHost(.reference), let shared = try makeHost(.shared) else { return }
        let a = try await ref.start()
        let b = try await shared.start()
        XCTAssertTrue(a.has("perSessionGIL"), "reference host isolates interpreters")
        XCTAssertTrue(a.has("isolatedSessions"))
        XCTAssertFalse(b.has("perSessionGIL"), "shared host trades parallelism for compatibility")
        XCTAssertFalse(b.has("isolatedSessions"))
        // Both must still honour the parts of the contract that are not optional.
        XCTAssertTrue(a.has("namespaceInspection") && b.has("namespaceInspection"))
        XCTAssertTrue(a.has("persistentShellState") && b.has("persistentShellState"))
        XCTAssertEqual(a.protocolVersion, b.protocolVersion)
        await ref.stop()
        await shared.stop()
    }),

    ("runtimeHost: the documented numpy trade-off is real in both directions", {
        // numpy declares Py_mod_multiple_interpreters = NOT_SUPPORTED, so CPython refuses to
        // load it in a sub-interpreter. Asserted rather than described, because if a future
        // numpy lifts the restriction the shared host stops being necessary and this test is
        // how we find out.
        guard let ref = try makeHost(.reference), let shared = try makeHost(.shared) else { return }
        _ = try await ref.start()
        _ = try await shared.start()
        let s1 = try await ref.createSession()
        let s2 = try await shared.createSession()
        let onRef = try await ref.execute("import numpy", in: s1)
        let onShared = try await shared.execute("import numpy; int(numpy.arange(4).sum())", in: s2)
        if onRef.exception == nil {
            print("      NOTE: numpy now imports in a sub-interpreter — the shared host may be redundant")
        } else {
            XCTAssertTrue((onRef.exception ?? "").contains("subinterpreter"),
                          "expected the documented refusal, got: \((onRef.exception ?? "").suffix(120))")
        }
        // The shared host must work regardless; that is its whole reason to exist.
        XCTAssertNil(onShared.exception, "numpy must import in the shared host")
        XCTAssertEqual(onShared.value, "6")
        await ref.stop()
        await shared.stop()
    }),

    ("runtimeHost: sessions in the reference host run in parallel", {
        // Per-interpreter GIL is the reason to prefer the reference host. Measured, because
        // "isolated" that does not actually run concurrently is just bookkeeping.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let ids = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for i in 0..<4 { group.addTask { try await host.createSession(id: "p\(i)") } }
            var out: [String] = []
            for try await id in group { out.append(id) }
            return out
        }
        let busy = "n = 0\nfor _ in range(4_000_000): n += 1\nn"
        let serialStart = Date()
        _ = try await host.execute(busy, in: ids[0])
        let serialOne = Date().timeIntervalSince(serialStart)

        let parallelStart = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { _ = try await host.execute(busy, in: id) } }
            try await group.waitForAll()
        }
        let parallel = Date().timeIntervalSince(parallelStart)
        // Four GIL-bound loops concurrently should cost far less than four times one. A
        // shared GIL would make this ~4x; the threshold is loose so a busy CI box does not
        // fail it spuriously.
        XCTAssertTrue(parallel < serialOne * 3.0,
                      "4 sessions took \(String(format: "%.2f", parallel))s vs \(String(format: "%.2f", serialOne))s for one — GIL looks shared")
        await host.stop()
    }),

    ("runtimeHost: capability parsing defaults missing features to false", {
        // Pure parsing, no process: the one place a wrong default would silently promise a
        // capability the runtime does not have.
        let v = try XCTUnwrap(JSONValue.parse(Data(#"""
        {"protocol":2,"runtime":"lua","runtimeVersion":"5.4","features":{"snapshot":true}}
        """#.utf8)))
        let caps = RuntimeHost.capabilities(from: v)
        XCTAssertEqual(caps.protocolVersion, 2)
        XCTAssertEqual(caps.runtime, "lua")
        XCTAssertTrue(caps.has("snapshot"))
        XCTAssertFalse(caps.has("perSessionGIL"))
        XCTAssertEqual(caps.summary, "lua 5.4 · protocol 2")
    }),

    // ------------------------------------------------------------------ provider
    ("provider: SSE framing joins multi-line data and passes [DONE] through", {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(line: ":keep-alive"))
        XCTAssertNil(parser.feed(line: "data: {\"a\":1}"))
        XCTAssertEqual(parser.feed(line: ""), "{\"a\":1}")
        // Several data: lines in one event concatenate with newlines, per the SSE spec —
        // getting this wrong truncates tool arguments and looks like model misbehaviour.
        XCTAssertNil(parser.feed(line: "data: line1"))
        XCTAssertNil(parser.feed(line: "data: line2"))
        XCTAssertEqual(parser.feed(line: ""), "line1\nline2")
        XCTAssertNil(parser.feed(line: "data: [DONE]"))
        XCTAssertEqual(parser.feed(line: ""), "[DONE]")
    }),

    ("provider: usage keeps reasoning absent when the provider is silent", {
        // Absent and zero mean different things on an encrypted-reasoning route, and this is
        // the distinction the harness fork existed to preserve.
        let quiet = try XCTUnwrap(JSONValue.parse(Data(
            #"{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}"#.utf8)))
        XCTAssertNil(OpenAICompletionsProvider.usage(from: quiet).reasoning)

        let loud = try XCTUnwrap(JSONValue.parse(Data(
            #"{"prompt_tokens":10,"completion_tokens":9,"completion_tokens_details":{"reasoning_tokens":0},"prompt_tokens_details":{"cached_tokens":6}}"#.utf8)))
        let u = OpenAICompletionsProvider.usage(from: loud)
        XCTAssertEqual(u.reasoning, 0, "a reported zero is data, not silence")
        XCTAssertEqual(u.cacheRead, 6)
        XCTAssertEqual(u.totalTokens, 19, "computed when the provider omits a total")
    }),

    ("provider: request encoding puts tools, calls and results where they belong", {
        let messages: [ChatMessage] = [
            .system("be brief"),
            .user("hello"),
            ChatMessage(role: .assistant, content: [
                .thinking("secret"),
                .text("calling"),
                .toolCall(id: "c1", name: "python", arguments: .object(["code": .string("1+1")])),
            ]),
            ChatMessage(role: .tool, content: [
                .toolResult(id: "c1", name: "python", text: "2", isError: false),
            ]),
        ]
        let body = OpenAICompletionsProvider.body(for: ChatRequest(
            model: "m", messages: messages, tools: Agent.tools(cwd: "/tmp"), maxTokens: 99))
        let wire = try XCTUnwrap(body["messages"]?.arrayValue)
        guard wire.count == 4 else { XCTFail("expected 4 wire messages, got \(wire.count)"); return }
        XCTAssertEqual(wire[2]["role"]?.stringValue, "assistant")
        XCTAssertEqual(wire[2]["content"]?.stringValue, "calling",
                       "thinking must not be echoed back — providers reject foreign reasoning")
        XCTAssertFalse((wire[2]["content"]?.stringValue ?? "").contains("secret"))
        XCTAssertEqual(wire[2].path("tool_calls.0.function.name")?.stringValue, "python")
        XCTAssertEqual(wire[3]["role"]?.stringValue, "tool", "a result is its own message here")
        XCTAssertEqual(wire[3]["tool_call_id"]?.stringValue, "c1")
        XCTAssertEqual(body.path("tools.0.function.name")?.stringValue, "python")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body.path("stream_options.include_usage")?.boolValue, true,
                       "without this most servers omit usage while streaming")
        XCTAssertEqual(body["max_tokens"]?.intValue, 99)
    }),

    ("agent: tool output rendering puts the traceback last", {
        var r = RuntimeHost.ExecResult(stdout: "printed\n", stderr: "", value: "42", exception: nil)
        XCTAssertEqual(Agent.render(r), "printed\n42")
        r = RuntimeHost.ExecResult(stdout: "", stderr: "", value: nil, exception: nil)
        XCTAssertEqual(Agent.render(r), "(no output)",
                       "a blank result reads as a broken tool, so say it explicitly")
        r = RuntimeHost.ExecResult(stdout: "a\n", stderr: "warn\n", value: nil,
                                   exception: "Traceback…\nValueError: no\n")
        let rendered = Agent.render(r)
        XCTAssertTrue(rendered.hasPrefix("a\n"))
        XCTAssertTrue(rendered.hasSuffix("ValueError: no"), "most actionable part nearest the end")
    }),

    // ------------------------------------------------------------------ the loop
    ("agent: runs a full tool-calling loop against a scripted provider", {
        // The whole spine, end to end and in-house: encode a request, stream SSE, reassemble a
        // split tool call, execute it in the runtime host, feed the result back, finish.
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "python", "arguments": ["code": "answer = 6 * 7\nanswer"]],
             "thinking": "let me compute", "reasoning_tokens": 11],
            ["text": "The answer is 42.", "input_tokens": 250, "output_tokens": 8],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let provider = OpenAICompletionsProvider(
            id: "fake", baseURL: server.baseURL, apiKey: "test-key")
        let agent = Agent(
            provider: provider, host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "be brief"))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("what is six times seven?")

        XCTAssertEqual(log.names, ["started", "thinking", "turn", "tool:python", "tool-ok",
                                   "turn", "finished:stop"])
        XCTAssertEqual(log.assistantText, "The answer is 42.")

        // Usage accumulates across turns, and a reported reasoning count survives.
        let usage = await agent.totalUsage
        XCTAssertEqual(usage.input, 350, "100 from turn one plus 250 from turn two")
        XCTAssertEqual(usage.reasoning, 11)

        // The second request must carry the first turn's tool call *and* its result, or the
        // model has no idea what happened.
        let sent = try server.recordedRequests()
        XCTAssertEqual(sent.count, 2)
        let second = try XCTUnwrap(sent.last?["messages"]?.arrayValue)
        // Guarded rather than indexed: this harness's assertions record and continue, so a
        // bare subscript after a count check traps the whole suite instead of failing one case.
        guard second.count == 4 else {
            XCTFail("expected system, user, assistant-with-call, tool-result; got \(second.count): "
                + second.map { $0["role"]?.stringValue ?? "?" }.joined(separator: ","))
            return
        }
        XCTAssertEqual(second[3]["role"]?.stringValue, "tool")
        XCTAssertEqual(second[3]["content"]?.stringValue, "42",
                       "the tool's echoed value went back to the model")

        await writer.close()
    }),

    ("agent: the transcript it writes is one Aviary can already read", {
        // The reason to reuse the harness's on-disk format rather than invent one: the parser,
        // renderer, catalog and analytics all keep working.
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "python", "arguments": ["code": "print('side effect')"]]],
            ["text": "Done."],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "sys"))
        await agent.send("go")
        await writer.close()

        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(parsed.items.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(parsed.counts.toolCalls, 1)
        XCTAssertEqual(parsed.counts.toolErrors, 0)
        // A tool call and its result must have been paired into one renderable row, with the
        // output attached — the thing the renderer depends on.
        let tool = try XCTUnwrap(parsed.items.first { $0.kind == .tool })
        XCTAssertEqual(tool.toolCall?.name, "python")
        XCTAssertTrue((tool.toolResultText ?? "").contains("side effect"))
        XCTAssertTrue(parsed.items.contains { $0.kind == .assistant })
        XCTAssertTrue(parsed.usage.totalTokens > 0, "usage survived the round trip to disk")
        // And the catalog can summarise it, which is what the Sessions list is built on.
        let summary = try XCTUnwrap(SessionCatalog.summarize(fileURL: writer.fileURL))
        XCTAssertEqual(summary.id, writer.fileURL.deletingPathExtension().lastPathComponent)
        XCTAssertFalse(summary.firstPrompt.isEmpty)
    }),

    ("agent: a provider failure ends the run and says so in the transcript", {
        guard let server = try FakeProviderServer(script: [
            ["status": 401, "message": "Incorrect API key provided: LITELLM_MASTER_KEY"],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: "x"),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "sys"))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("hello")
        await writer.close()

        XCTAssertTrue(log.names.contains("failed"))
        XCTAssertFalse(log.names.contains { $0.hasPrefix("finished") },
                       "a failure is not a completion")
        // The transcript must carry the reason. The body matters more than the status: this
        // one names an unexpanded variable, which is a config bug rather than a bad key.
        let text = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("401"))
        XCTAssertTrue(text.contains("LITELLM_MASTER_KEY"))
    }),

    ("agent: the iteration ceiling stops a non-converging loop and records it", {
        // A model that keeps calling tools forever must stop, and the transcript must say why
        // — a run that quietly stopped looks identical to one that finished.
        let script = (0..<6).map { _ in
            ["tool": ["name": "python", "arguments": ["code": "1"]]] as [String: Any]
        }
        guard let server = try FakeProviderServer(script: script) else {
            print("      skipped: no fixture"); return
        }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "sys", maxIterations: 3))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("loop forever")
        await writer.close()

        XCTAssertEqual(log.names.filter { $0 == "tool:python" }.count, 3, "stopped at the ceiling")
        XCTAssertTrue(log.names.contains("finished:iteration limit"))
        let text = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Stopped after 3 model calls"))
    }),

    ("agent: an unknown tool name is answered, not fatal", {
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "read_file", "arguments": ["path": "/etc/hosts"]]],
            ["text": "Understood, I'll use python."],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "sys"))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("read a file")
        await writer.close()

        XCTAssertTrue(log.names.contains("tool-error"))
        XCTAssertTrue(log.names.contains("finished:stop"), "the run continued and completed")
        let sent = try server.recordedRequests()
        let second = try XCTUnwrap(sent.last?["messages"]?.arrayValue)
        XCTAssertTrue((second.last?["content"]?.stringValue ?? "").contains("only tool is"),
                      "the model was told what went wrong")
    }),

    ("agent: compacts when the context window fills, and records what it dropped", {
        // Six tool round trips against a tiny window forces a compaction mid-run. The point
        // is not the summary's quality but that the run survives and the transcript says a
        // compaction happened — a lossy step that leaves no marker is unauditable.
        // Four tool turns to grow the conversation past the compaction guard, then two text
        // turns: the first is consumed by the summariser's own model call — which is easy to
        // forget, and if it lands on a tool-shaped entry the summary comes back empty and no
        // compaction happens at all.
        var script: [[String: Any]] = []
        for i in 0..<4 {
            script.append(["tool": ["name": "python", "arguments": ["code": "step = \(i)"]],
                           "input_tokens": 900] as [String: Any])
        }
        script.append(["text": "Earlier: four steps ran, values 0-3 stored.", "input_tokens": 50])
        script.append(["text": "All done.", "input_tokens": 100])
        guard let server = try FakeProviderServer(script: script) else {
            print("      skipped: no fixture"); return
        }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        var model = fakeModel()
        model.contextWindow = 1000          // so 900 reported input tokens is over 70%
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: model)
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: model, cwd: "/tmp", systemPrompt: "sys", maxIterations: 12))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("do six things")
        await writer.close()

        XCTAssertTrue(log.names.contains { $0.hasPrefix("compacted:") },
                      "expected a compaction; events were \(log.names)")
        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertTrue(parsed.counts.compactions >= 1, "the transcript records the compaction")
        // And the entries from before the compaction are still in the file — the model
        // forgets, the record does not.
        XCTAssertTrue(parsed.counts.toolCalls >= 4, "history above the marker is intact")
    }),

    ("agent: a compaction failure does not end the run", {
        // The summariser is a model call and can fail. When it does the next real call may
        // still fit, so failing the whole run would be the wrong trade.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        var model = fakeModel()
        model.contextWindow = 1000

        // The script gives a normal first turn, then 500s — so the compaction call fails while
        // the run is still able to make progress.
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "python", "arguments": ["code": "a = 1"]], "input_tokens": 950],
            ["status": 500, "message": "summariser exploded"],
            ["text": "Recovered.", "input_tokens": 100],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }

        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: model)
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: model, cwd: "/tmp", systemPrompt: "sys", maxIterations: 6))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("go")
        await writer.close()
        // Not asserting which of the two happens — a 500 may land on the compaction or the
        // next turn depending on ordering. Asserting the thing that must hold either way:
        // the process did not crash and the transcript is readable.
        XCTAssertNotNil(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertTrue(log.names.contains { $0.hasPrefix("finished") || $0 == "failed" })
    }),

    ("agent: the tool description mentions spawn only when spawning is possible", {
        // Learned from a real run: spawn() existed in the namespace and not in the schema, and
        // the agent spent twenty turns grepping the codebase for it before giving up. An
        // undocumented capability reads as a broken environment.
        let without = Agent.tools(cwd: "/tmp", canSpawn: false)
        XCTAssertFalse(without[0].description.contains("spawn("),
                       "must not advertise what this run cannot do")
        XCTAssertTrue(without[0].description.contains("conversation("),
                      "conversation is always available")
        let with = Agent.tools(cwd: "/tmp", canSpawn: true, spawnBudget: 2)
        XCTAssertTrue(with[0].description.contains("spawn("))
        XCTAssertTrue(with[0].description.contains("2 more level"),
                      "the remaining depth is stated, not implied")
        XCTAssertTrue(with[0].description.contains("self-contained"),
                      "a child gets none of the parent's context, so say so")
    }),

    ("agent: spawn is refused at the depth ceiling, in words the agent can act on", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "fake", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s",
                          maxDepth: 2, depth: 2))
        await agent.setSpawnDelegate(RefusingDelegate())

        let atCeiling = await agent.serveCallback(
            kind: "spawn", payload: .object(["prompt": .string("do a thing")]))
        XCTAssertTrue((atCeiling["error"]?.stringValue ?? "").contains("maximum sub-agent depth"))
        XCTAssertTrue((atCeiling["error"]?.stringValue ?? "").contains("yourself"),
                      "tells it what to do instead, not just no")

        // And an unknown callback kind is refused rather than hanging the caller.
        let unknown = await agent.serveCallback(kind: "teleport", payload: .object([:]))
        XCTAssertTrue((unknown["error"]?.stringValue ?? "").contains("teleport"))
        await writer.close()
    }),

    ("agent: conversation() hands back the history programmatically", {
        // The capability that makes the runtime more than a calculator: the agent can query
        // what it already tried instead of re-deriving it, and can hand a child exactly the
        // slice it needs rather than all or nothing.
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "python", "arguments": ["code": "x = 1"]]],
            ["text": "done"],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "sys"))
        await agent.send("remember this phrase: albatross")

        let history = await agent.serveCallback(
            kind: "conversation", payload: .object(["limit": .number(10)]))
        let entries = try XCTUnwrap(history["messages"]?.arrayValue)
        XCTAssertTrue(entries.count >= 3, "system, user and at least one assistant turn")
        let text = entries.map { $0["text"]?.stringValue ?? "" }.joined(separator: " ")
        XCTAssertTrue(text.contains("albatross"), "the user's own words are readable")
        XCTAssertTrue(entries.contains { ($0["toolCalls"]?.arrayValue ?? []).count > 0 },
                      "tool calls are visible, so it can see what it ran")
        await writer.close()
    }),

    ("subAgents: records land where Flock reads them", {
        // Reusing the harness's ledger layout means an in-house child appears in the existing
        // Flock screen with no new UI at all — the same reasoning as reusing the transcript
        // format.
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let recorder = SubAgentRecorder(home: home, parentSessionID: "parent-1")
        let childID = SubAgentRecorder.newChildID()
        XCTAssertTrue(childID.hasPrefix("sub-"), "the shape other readers key on")
        let childFile = recorder.childDirectory(childID: childID).appending(path: "c.jsonl")
        try FileManager.default.createDirectory(
            at: childFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: childFile.path, contents: nil)

        try recorder.record(
            childID: childID, name: "counter", sessionFile: childFile, prompt: "count things",
            spawnCode: "spawn(\"count things\")", depth: 1, maxDepth: 3, status: "running",
            provider: "litellm", model: "m", createdAt: Date())
        try recorder.record(
            childID: childID, name: "counter", sessionFile: childFile, prompt: "count things",
            spawnCode: "", depth: 1, maxDepth: 3, status: "completed",
            provider: "litellm", model: "m", createdAt: Date())

        let tree = AgentTreeReader.read(home: home)
        let node = try XCTUnwrap(tree.allNodes.first { $0.id == childID })
        XCTAssertEqual(node.name, "counter")
        XCTAssertEqual(node.status, "completed", "the later record supersedes the earlier one")
        XCTAssertTrue(node.isComplete)
        XCTAssertEqual(node.depth, 1)
        XCTAssertEqual(node.prompt, "count things")
        XCTAssertEqual(node.modelLabel, "litellm/m")
    }),

    ("subAgents: a child is told its answer is the whole deliverable", {
        let prompt = AgentRunner.childPrompt(base: "BASE", depth: 1, maxDepth: 3)
        XCTAssertTrue(prompt.hasPrefix("BASE"), "the shared prompt still applies")
        XCTAssertTrue(prompt.contains("depth 1 of 3"))
        XCTAssertTrue(prompt.contains("does not see your"),
                      "a child's transcript is invisible to its parent, so say so")
        XCTAssertTrue(prompt.contains("Spawn a sub-agent only for genuinely separable"))
        // At the ceiling the advice must flip rather than dangle.
        let deep = AgentRunner.childPrompt(base: "BASE", depth: 3, maxDepth: 3)
        XCTAssertTrue(deep.contains("cannot spawn further"))
        XCTAssertFalse(deep.contains("only for genuinely separable"))
    }),

    // ------------------------------------------------------------------ anthropic
    ("anthropic: the system prompt is a field, not a message", {
        // The first thing that differs from chat-completions, and sending it as a message is
        // a 400 rather than a warning.
        let body = AnthropicMessagesProvider.body(for: ChatRequest(
            model: "claude", messages: [.system("be terse"), .user("hi")], maxTokens: 100))
        XCTAssertEqual(body["system"]?.stringValue, "be terse")
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 1, "the system message must not appear here")
        XCTAssertEqual(messages[0]["role"]?.stringValue, "user")
        XCTAssertEqual(body["max_tokens"]?.intValue, 100, "required by this API")
    }),

    ("anthropic: tool results are user blocks, and same-role turns merge", {
        // Two more differences that produce a 400 if missed: a result is not its own role, and
        // consecutive same-role messages must be merged into one.
        let wire = AnthropicMessagesProvider.encode([
            ChatMessage(role: .assistant, content: [
                .text("running it"),
                .toolCall(id: "t1", name: "python", arguments: .object(["code": .string("1")])),
            ]),
            ChatMessage(role: .tool, content: [
                .toolResult(id: "t1", name: "python", text: "1", isError: false),
            ]),
            ChatMessage(role: .tool, content: [
                .toolResult(id: "t2", name: "python", text: "2", isError: true),
            ]),
        ])
        XCTAssertEqual(wire.count, 2, "assistant turn, then one merged user turn")
        XCTAssertEqual(wire[0]["role"]?.stringValue, "assistant")
        XCTAssertEqual(wire[0].path("content.1.type")?.stringValue, "tool_use")
        XCTAssertEqual(wire[1]["role"]?.stringValue, "user")
        let blocks = try XCTUnwrap(wire[1]["content"]?.arrayValue)
        XCTAssertEqual(blocks.count, 2, "two results merged into one user message")
        XCTAssertEqual(blocks[0]["type"]?.stringValue, "tool_result")
        XCTAssertEqual(blocks[1]["is_error"]?.boolValue, true)
    }),

    ("anthropic: thinking is a budget, and it must fit inside max_tokens", {
        let none = AnthropicMessagesProvider.body(for: ChatRequest(
            model: "c", messages: [.user("hi")], maxTokens: 100, reasoningEffort: "minimal"))
        XCTAssertNil(none["thinking"], "an effort this API cannot express is omitted, not faked")

        let high = AnthropicMessagesProvider.body(for: ChatRequest(
            model: "c", messages: [.user("hi")], maxTokens: 100, reasoningEffort: "high"))
        XCTAssertEqual(high.path("thinking.budget_tokens")?.intValue, 24_000)
        // A budget larger than max_tokens is rejected by the API, so the ceiling is raised
        // rather than left for the caller to trip over.
        XCTAssertTrue((high["max_tokens"]?.intValue ?? 0) > 24_000)
    }),

    // ------------------------------------------------------------------ skill gate
    ("skillGate: an unrelated prompt earns no descriptions at all", {
        // The measured failure this replaces: the harness sent all 68 skill descriptions on
        // every request, 62.7% of input tokens on a two-message run.
        let skills = [
            fakeSkill("clickhouse-quirks", "ClickHouse server behaviours and Identifier params"),
            fakeSkill("gig-worker-temporal", "Temporal activity prefixing and org exports"),
            fakeSkill("preview-envs", "Spinning up preview environments"),
        ]
        let gate = SkillGate()
        let idle = gate.select(skills: skills, prompt: "what is 2+2?", cwd: "/tmp")
        XCTAssertEqual(idle.included.count, 0, "nothing relevant, so nothing described")
        XCTAssertEqual(idle.listed.count, 3, "but everything is still listed")
        XCTAssertTrue(idle.savedCharacters > 0)

        let relevant = gate.select(
            skills: skills, prompt: "debug a ClickHouse Identifier parameter error", cwd: "/tmp")
        XCTAssertEqual(relevant.included.map(\.name), ["clickhouse-quirks"])
        XCTAssertEqual(relevant.listed.count, 2)
    }),

    ("skillGate: the working directory counts for less than the prompt", {
        // Weighting them equally meant every skill mentioning the project matched everything:
        // "what is 2+2?" in the Skyway checkout pulled in fifteen skills.
        let skills = (0..<12).map { fakeSkill("skyway-thing-\($0)", "Notes about skyway internals") }
        let gate = SkillGate()
        let trivial = gate.select(
            skills: skills, prompt: "what is 2+2?", cwd: "/Users/x/duckbill/skyway")
        XCTAssertEqual(trivial.included.count, 0,
                       "the directory alone must not make everything relevant")
        let real = gate.select(
            skills: skills, prompt: "explain skyway internals", cwd: "/Users/x/duckbill/skyway")
        XCTAssertTrue(real.included.count > 0, "an actual mention still matches")
    }),

    ("skillGate: nothing is hidden, and pinned skills always make it", {
        // A pruned skill the model cannot see and cannot ask for is silent capability loss,
        // and the failure looks like the model being stupid rather than the gate being wrong.
        let skills = (0..<40).map { fakeSkill("skill-\($0)", "does thing \($0) with widgets") }
        var gate = SkillGate(budget: 200)
        gate.pinned = ["skill-39"]
        let selection = gate.select(skills: skills, prompt: "widgets widgets widgets", cwd: "/tmp")
        XCTAssertTrue(selection.included.contains { $0.name == "skill-39" },
                      "pinned survives a budget that could not otherwise fit it")
        XCTAssertTrue(selection.listed.count > 0, "the budget was exceeded, so some are listed")
        let rendered = gate.render(selection)
        for skill in skills {
            XCTAssertTrue(rendered.contains(skill.name), "\(skill.name) vanished entirely")
        }
        XCTAssertTrue(rendered.contains("Read the file for the full"),
                      "and it says how to read the ones that were only listed")
    }),

    ("skillGate: a name match outranks a description match", {
        let skills = [
            fakeSkill("mentions-compaction-in-passing", "a note that also discusses compaction"),
            fakeSkill("compaction", "how context compaction works"),
        ]
        let gate = SkillGate(budget: 60)
        let selection = gate.select(skills: skills, prompt: "compaction", cwd: "/tmp")
        XCTAssertEqual(selection.included.first?.name, "compaction",
                       "the skill actually named for the topic wins")
    }),
])
