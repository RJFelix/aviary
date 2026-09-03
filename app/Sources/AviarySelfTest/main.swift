import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

func test_recognizesCurrentAndLegacyPythonToolNames() {
    let arguments = JSONValue.object(["code": .string("print(1)")])
    XCTAssertEqual(ToolCall(id: "new", name: "python", arguments: arguments).pythonCode, "print(1)")
    XCTAssertEqual(ToolCall(id: "old", name: "ipython", arguments: arguments).pythonCode, "print(1)")
    XCTAssertNil(ToolCall(id: "other", name: "shell", arguments: arguments).pythonCode)
}

func test_rejectsUnsupportedChildModelInsteadOfSilentlyUsingParent() {
    let parent = fakeModel()
    XCTAssertNil(Agent.childModelRejection(requested: nil, parent: parent))
    XCTAssertNil(Agent.childModelRejection(requested: parent.id, parent: parent))
    XCTAssertNil(Agent.childModelRejection(requested: parent.qualifiedID, parent: parent))
    let rejection = Agent.childModelRejection(requested: "other/model", parent: parent)
    XCTAssertTrue(rejection?.contains("cannot route a child") == true)
    XCTAssertTrue(rejection?.contains(parent.qualifiedID) == true)
}

func test_claudePromptCanTruthfullySkipProjectContextFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "aviary-context-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "unique project instruction".write(
        to: directory.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)

    let included = ClaudeCodePrompt.build(cwd: directory.path)
    let skipped = ClaudeCodePrompt.build(cwd: directory.path, includeContextFiles: false)
    XCTAssertTrue(included.contains("unique project instruction"))
    XCTAssertFalse(skipped.contains("unique project instruction"))
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

/// Batch Trash records an error for an already-missing session instead of throwing away the
/// rest of the batch. This needs no real Trash round-trip, so it leaves no test files behind.
func test_batchTrashReportsIndividualFailures() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "aviary-batch-trash-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "missing-after-summary.jsonl")
    let jsonl = [
        #"{"type":"session","version":3,"id":"header","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}"#,
        #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":"hi"}}"#,
    ].joined(separator: "\n")
    try Data(jsonl.utf8).write(to: file)
    let summary = try XCTUnwrap(SessionCatalog.summarize(fileURL: file))
    try FileManager.default.removeItem(at: file)

    let catalog = SessionCatalog(home: AgentHome(root: dir))
    let result = await catalog.trash(sessions: [summary])
    XCTAssertTrue(result.trashedIDs.isEmpty)
    XCTAssertNotNil(result.failures[summary.id])
}

/// A moved transcript plus an artifact failure is a partial success, never a clean success or
/// a retryable catalog row whose transcript no longer exists.
func test_batchTrashReportsArtifactPartialFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-partial-trash-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    try FileManager.default.createDirectory(at: home.sessionsDir, withIntermediateDirectories: true)
    let file = home.sessionFile(id: "partial-session")
    try Data(
        #"{"type":"session","version":3,"id":"header","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}"#.utf8
    ).write(to: file)
    let artifacts = home.artifacts(forSession: "partial-session")
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try Data("keep me".utf8).write(to: artifacts.appending(path: "result.txt"))
    let summary = try XCTUnwrap(SessionCatalog.summarize(fileURL: file))

    let catalog = SessionCatalog(home: home) { url in
        if url.standardizedFileURL == artifacts.standardizedFileURL {
            throw NSError(domain: "AviarySelfTest", code: 73,
                          userInfo: [NSLocalizedDescriptionKey: "artifact move denied"])
        }
        try FileManager.default.removeItem(at: url)
    }
    let result = await catalog.trash(sessions: [summary])
    XCTAssertTrue(result.trashedIDs.contains(summary.id))
    XCTAssertTrue(result.failures.isEmpty)
    XCTAssertTrue(result.partialFailures[summary.id]?.contains("artifact move denied") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.path))
}

/// Archive is reversible catalog state, not transcript mutation or deletion.
func test_archiveRoundTripsWithoutTouchingTranscript() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "aviary-archive-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = AgentHome(root: root)
    try FileManager.default.createDirectory(at: home.sessionsDir, withIntermediateDirectories: true)
    let file = home.sessionFile(id: "session-one")
    let jsonl = [
        #"{"type":"session","version":3,"id":"header","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}"#,
        #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":"hi"}}"#,
    ].joined(separator: "\n")
    try Data(jsonl.utf8).write(to: file)
    let original = try Data(contentsOf: file)

    let catalog = SessionCatalog(home: home)
    try await catalog.setArchived(true, sessionIDs: ["session-one"])
    var rows = await catalog.scan()
    XCTAssertTrue(try XCTUnwrap(rows.first).isArchived)
    XCTAssertEqual(try Data(contentsOf: file), original)

    try await catalog.setArchived(false, sessionIDs: ["session-one"])
    rows = await catalog.scan()
    XCTAssertFalse(try XCTUnwrap(rows.first).isArchived)
    XCTAssertEqual(try Data(contentsOf: file), original)
}

// MARK: - Runner




/// A spawn delegate that should never be reached — used to prove the depth ceiling refuses
/// before any child is created.
struct RefusingDelegate: Agent.SpawnDelegate {
    func startBackground(
        prompt: String, name: String?, model: String?, depth: Int
    ) async -> Agent.SpawnStartResult {
        .refused(name: name ?? "none", reason: "test refusal")
    }

    func children() async -> [Agent.ChildStatus] { [] }
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


/// A `ModelsConfig` built in memory, so catalogue tests need no `models.json`.
func testModelsConfig(_ providers: [String: [String]]) -> ModelsConfig {
    var obj: [String: JSONValue] = [:]
    for (pid, models) in providers {
        obj[pid] = .object([
            "apiKey": .string("sk-test"),
            "models": .array(models.map { .object(["id": .string($0)]) }),
        ])
    }
    let raw = JSONValue.object(["providers": .object(obj)])
    let specs: [ProviderSpec] = providers.keys.sorted().map { pid in
        var p = ProviderSpec(
            id: pid, name: nil, baseURL: nil, api: nil, apiKeyExpression: "sk-test",
            authHeader: nil, headers: [:], models: [])
        p.models = (providers[pid] ?? []).map { mid in
            ModelSpec(id: mid, providerID: pid, json: .object(["id": .string(mid)]), provider: .object([:]))
        }
        return p
    }
    return ModelsConfig(
        providers: specs, raw: raw,
        fileURL: URL(fileURLWithPath: "/tmp/models.json"), exists: true)
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
        case .imageAttached: events.append("imageAttached")
        case .modelChanged: events.append("modelChanged")
        case .awaitingDispatched: events.append("awaitingDispatched")
        case .started: events.append("started")
        case .inputCommitted: events.append("inputCommitted")
        case .steered: events.append("steered")
        case .goalExhausted: events.append("goal-exhausted")
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

/// A provider that deliberately ignores Agent cancellation until the test releases it with a
/// tool call. This pins the boundary after a provider returns: End must still prevent the tool
/// from touching a runtime that teardown is about to close.
final class CancellationIgnoringToolProvider: ChatProvider, @unchecked Sendable {
    let id = "cancellation-ignoring"
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation?

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    var hasStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return continuation != nil
    }

    func releaseTool(code: String) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.yield(.toolCall(
            id: "late-tool", name: "python",
            arguments: .object(["code": .string(code)])))
        continuation?.yield(.done(stopReason: "tool_use"))
        continuation?.finish()
    }
}

/// A provider whose suspended stream throws `CancellationError` when its consumer task is
/// cancelled, matching the normal cooperative URLSession/provider path.
final class CooperativeCancellationProvider: ChatProvider, @unchecked Sendable {
    let id = "cooperative-cancellation"
    private let lock = NSLock()
    private var started = false

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream(unfolding: { [self] in
            markStarted()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .done(stopReason: "stop")
        })
    }

    private func markStarted() {
        lock.lock(); started = true; lock.unlock()
    }

    var hasStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }
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

/// One case: a name and a body.
///
/// The suite is split into several arrays rather than one literal, and the annotation is not
/// decoration. As a single expression of two hundred closures, Swift's type-checker exceeded
/// its time limit — and it reported that as an error on an arbitrary innocent line in an
/// unrelated case, which reads as a broken test rather than as a file that got too big. Adding
/// a case would break a different one at random.
typealias Case = (String, () async throws -> Void)

let cases0: [Case] = [
    ("parsesLinearSessionWithToolPairing", { try test_parsesLinearSessionWithToolPairing() }),
    ("recognizesCurrentAndLegacyPythonToolNames", {
        test_recognizesCurrentAndLegacyPythonToolNames()
    }),
    ("rejectsUnsupportedChildModelInsteadOfSilentlyUsingParent", {
        test_rejectsUnsupportedChildModelInsteadOfSilentlyUsingParent()
    }),
    ("claudePromptCanTruthfullySkipProjectContextFiles", {
        try test_claudePromptCanTruthfullySkipProjectContextFiles()
    }),
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
    ("batchTrashReportsIndividualFailures", { try await test_batchTrashReportsIndividualFailures() }),
    ("batchTrashReportsArtifactPartialFailure", {
        try await test_batchTrashReportsArtifactPartialFailure()
    }),
    ("archiveRoundTripsWithoutTouchingTranscript", {
        try await test_archiveRoundTripsWithoutTouchingTranscript()
    }),

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

    ("workshop: edits overlay the original without losing omitted fields", {
        let lines = [
            #"{"v":1,"at":"2026-08-21T10:00:00.000Z","event":"created","id":"wr-1","title":"First title","body":"Original detail","kind":"bug"}"#,
            #"{"v":1,"at":"2026-08-21T10:01:00.000Z","event":"edited","id":"wr-1","title":"Amended title","kind":"idea"}"#,
            #"{"v":1,"at":"2026-08-21T10:02:00.000Z","event":"edited","id":"wr-1","body":"Rewritten detail"}"#,
        ]
        let request = try XCTUnwrap(WorkshopLog.fold(lines: lines).first)
        XCTAssertEqual(request.title, "Amended title", "the latest supplied title wins")
        XCTAssertEqual(request.body, "Rewritten detail", "a later supplied body wins")
        XCTAssertEqual(request.kind, .idea, "the earlier edit survives when the later one omits kind")
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

]

let cases1: [Case] = [
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

    ("runtimeHost: cd and export persist across awaited calls", {
        // The measured 19.7%: cells doing working-directory bookkeeping by hand because
        // subprocess starts every child in the same place.
        //
        // `.result()` is load-bearing now that sh() is a Future. Persistence is a property of
        // commands that have *finished*, and this is the test that says so: without the await
        // the next call can start before the `cd` has landed. That is the price of being able
        // to start a slow command and keep working, and it is why the description spells the
        // sequential idiom with .result() in it.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession(cwd: "/usr")
        _ = try await host.execute("sh('cd /usr/lib').result()", in: s)
        let where1 = try await host.execute("cwd()", in: s)
        XCTAssertEqual(where1.value, "'/usr/lib'")
        let where2 = try await host.execute(
            "sh('pwd').result()['stdout'].strip()", in: s)
        XCTAssertEqual(where2.value, "'/usr/lib'")
        _ = try await host.execute("sh('export AVIARY_SUITE=7').result()", in: s)
        let env = try await host.execute(
            "sh('echo $AVIARY_SUITE').result()['stdout'].strip()", in: s)
        XCTAssertEqual(env.value, "'7'")
        await host.stop()
    }),

    ("runtimeHost: sh returns before the command does, and can be awaited later", {
        // The whole point of the change: start the slow thing, do something else, collect.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        let s = try await host.createSession(cwd: "/tmp")
        // Started, not awaited — the cell returns while the command is still sleeping.
        let started = try await host.execute(
            "import time\nt0 = time.time()\njob = sh('sleep 1; echo late')\n"
                + "round(time.time() - t0, 1) < 0.5", in: s)
        XCTAssertEqual(started.value, "True", "sh() did not block")
        // The Future is still in the namespace a cell later, and resolves to the output.
        let collected = try await host.execute("job.result()['stdout'].strip()", in: s)
        XCTAssertEqual(collected.value, "'late'")
        // And it carries the deliver-later affordance every long builtin shares.
        let hasNotify = try await host.execute("hasattr(job, 'notify')", in: s)
        XCTAssertEqual(hasNotify.value, "True")
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

]

let cases2: [Case] = [
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
        let onShared = try await shared.execute("import numpy; int(numpy.arange(4).sum())", in: s2)
        if onShared.exception?.contains("No module named 'numpy'") == true {
            print("      skipped: numpy is not installed for the active Python")
            await ref.stop()
            await shared.stop()
            return
        }
        let onRef = try await ref.execute("import numpy", in: s1)
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

        XCTAssertEqual(log.names, ["started", "inputCommitted", "thinking", "turn", "tool:python", "tool-ok",
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
        let toolItems: [TranscriptItem] = parsed.items.filter { $0.kind == .tool }
        let tool = try XCTUnwrap(toolItems.first)
        XCTAssertEqual(tool.toolCall?.name, "python")
        XCTAssertTrue((tool.toolResultText ?? "").contains("side effect"))
        XCTAssertTrue(parsed.items.contains { $0.kind == .assistant })
        XCTAssertTrue(parsed.usage.totalTokens > 0, "usage survived the round trip to disk")
        // And the catalog can summarise it, which is what the Sessions list is built on.
        let summary = try XCTUnwrap(SessionCatalog.summarize(fileURL: writer.fileURL))
        XCTAssertEqual(summary.id, writer.fileURL.deletingPathExtension().lastPathComponent)
        XCTAssertFalse(summary.firstPrompt.isEmpty)
    }),

    ("resume: a second run continues the same file and sends the prior turns", {
        // The end-to-end claim, asserted on the wire rather than inferred: the resumed run's
        // request must actually contain the earlier exchange, and the file must still be one
        // conversation rather than two stapled together.
        guard let first = try FakeProviderServer(script: [["text": "The number is 8891."]])
        else { print("      skipped: no fixture"); return }
        guard let host = try makeHost(.reference) else { first.stop(); return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        // Turn one, through the runner so the writer and session id come from the real path.
        let runnerOne = AgentRunner(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: first.baseURL, apiKey: nil),
            host: host,
            settings: .init(home: home, cwd: "/tmp", model: fakeModel(), systemPrompt: "sys"))
        let (writerOne, _) = try await runnerOne.run(prompt: "pick a number")
        let sessionID = writerOne.sessionID
        await writerOne.close()
        first.stop()

        // Turn two: same session, a new server so its recorded requests are only this run's.
        guard let second = try FakeProviderServer(script: [["text": "8891"]])
        else { print("      skipped: no fixture"); return }
        defer { second.stop() }
        let runnerTwo = AgentRunner(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: second.baseURL, apiKey: nil),
            host: host,
            settings: .init(
                home: home, cwd: "/tmp", model: fakeModel(),
                systemPrompt: "a freshly built prompt", resume: sessionID))
        let (writerTwo, _) = try await runnerTwo.run(prompt: "what was it?")
        // Same session, not a new one.
        XCTAssertEqual(writerTwo.sessionID, sessionID)
        XCTAssertEqual(writerTwo.fileURL, writerOne.fileURL)
        await writerTwo.close()

        // What went over the wire on the resumed run.
        let requests = try second.recordedRequests()
        let sent = try XCTUnwrap(requests.first)
        let messages = try XCTUnwrap(sent["messages"]?.arrayValue)
        let roles = messages.compactMap { $0["role"]?.stringValue }
        // system, the earlier user turn, the earlier assistant turn, then the new prompt.
        XCTAssertEqual(roles, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages[0]["content"]?.stringValue, "a freshly built prompt")
        let texts = messages.map { $0["content"]?.stringValue ?? "" }
        XCTAssertTrue(texts.contains("pick a number"), "prior prompt was not replayed")
        XCTAssertTrue(texts.contains { $0.contains("8891") }, "prior reply was not replayed")
        XCTAssertTrue(texts.contains("what was it?"))
        // Exactly one system message, and it is the new one — not the recorded run's.
        XCTAssertEqual(roles.filter { $0 == "system" }.count, 1)

        // And the file is still one conversation: the parser's active branch reaches the
        // original turn, which is what `parentId` threading on resume exists for.
        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writerTwo.fileURL))
        let prompts = parsed.items.filter { $0.kind == .user }.map(\.plainText)
        XCTAssertEqual(prompts, ["pick a number", "what was it?"])
        // Only one session header, so a reader does not see the tail as a different session.
        let lines = try String(contentsOf: writerTwo.fileURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains("\"type\":\"session\"") }.count, 1)
        // The resume was recorded in the transcript, not just shown once in the UI.
        XCTAssertTrue(
            parsed.items.contains { $0.customType == "aviary.resume" },
            "no resume note was written")
    }),

    ("resume: preparing a run sends nothing until asked", {
        // How the UI resumes: continuing a session opens a run whose conversation is already
        // there and waits. An empty first prompt would be a real, and rejectable, empty turn.
        guard let server = try FakeProviderServer(script: [["text": "ok"]])
        else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let runner = AgentRunner(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host,
            settings: .init(home: home, cwd: "/tmp", model: fakeModel(), systemPrompt: "sys"))
        let (writer, agent) = try await runner.prepare()
        XCTAssertEqual(try server.recordedRequests().count, 0, "prepare must not call the model")

        // Then the first real prompt goes through the same agent.
        await agent.send("now go")
        XCTAssertEqual(try server.recordedRequests().count, 1)
        await writer.close()
        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(parsed.items.filter { $0.kind == .user }.map(\.plainText), ["now go"])
    }),

    ("resume: preparing a resumed run seeds history without sending", {
        // The workshop's attach path: reopen the long-lived session, replay what it said, and
        // wait. Both halves have their own test; this is the combination, which is what
        // actually runs when a request is filed against an existing workshop session.
        guard let first = try FakeProviderServer(script: [["text": "noted: 5150"]])
        else { print("      skipped: no fixture"); return }
        guard let host = try makeHost(.reference) else { first.stop(); return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }

        let one = AgentRunner(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: first.baseURL, apiKey: nil),
            host: host,
            settings: .init(home: home, cwd: "/tmp", model: fakeModel(), systemPrompt: "sys"))
        let (writerOne, _) = try await one.run(prompt: "remember 5150")
        let sessionID = writerOne.sessionID
        await writerOne.close()
        first.stop()

        guard let second = try FakeProviderServer(script: [["text": "5150"]])
        else { print("      skipped: no fixture"); return }
        defer { second.stop() }
        let two = AgentRunner(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: second.baseURL, apiKey: nil),
            host: host,
            settings: .init(
                home: home, cwd: "/tmp", model: fakeModel(), systemPrompt: "sys",
                resume: sessionID))
        let (writerTwo, agent) = try await two.prepare()
        XCTAssertEqual(writerTwo.sessionID, sessionID)
        XCTAssertEqual(try second.recordedRequests().count, 0, "prepare must not call the model")

        await agent.send("what was it?")
        let sent = try XCTUnwrap(try second.recordedRequests().first)
        let texts = (sent["messages"]?.arrayValue ?? []).map { $0["content"]?.stringValue ?? "" }
        XCTAssertTrue(texts.contains("remember 5150"), "history was not seeded")
        XCTAssertTrue(texts.contains { $0.contains("5150") })
        XCTAssertTrue(texts.contains("what was it?"))
        await writerTwo.close()
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
        XCTAssertTrue((second.last?["content"]?.stringValue ?? "").contains("No tool named"),
                      "the model was told what went wrong, and what it could call instead")
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

]

let cases3: [Case] = [
    ("agent: a second prompt continues the same conversation and interpreter", {
        // What makes a session worth more than a request: the variables from turn one are
        // still there in turn two, and the model can see what it already said.
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "python", "arguments": ["code": "treasure = 'buried'"]]],
            ["text": "Stored it."],
            ["tool": ["name": "python", "arguments": ["code": "treasure"]]],
            ["text": "It is still buried."],
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
        await agent.send("hide something")
        await agent.send("what did you hide?")
        await writer.close()

        // The interpreter kept the variable across prompts, not just across turns.
        let sent = try server.recordedRequests()
        XCTAssertEqual(sent.count, 4)
        let last = try XCTUnwrap(sent.last?["messages"]?.arrayValue)
        let flat = last.map { $0["content"]?.stringValue ?? "" }.joined(separator: " ")
        XCTAssertTrue(flat.contains("'buried'"),
                      "the second prompt's tool result proves the variable survived")
        XCTAssertTrue(flat.contains("hide something"),
                      "and the first prompt is still in the conversation")

        // One transcript, both exchanges, still readable.
        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        XCTAssertEqual(parsed.items.filter { $0.kind == .user }.count, 2)
        XCTAssertEqual(parsed.counts.toolCalls, 2)
    }),

    // ------------------------------------------------------------------ MCP
    ("mcp: starts a server, lists its tools, and calls one", {
        // Driven against a real stdio server rather than a mock, for the same reason the
        // runtime-host tests are: the protocol is the contract, and a stub proves nothing
        // about whether a server on the other end behaves.
        guard let root = EngineLocator.repoRoot() else { return }
        let fixture = root.appending(path: "test-fixtures/mcp-echo.py")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            print("      skipped: no mcp fixture"); return
        }
        let client = MCPClient(
            name: "echo", executable: "/usr/bin/env",
            arguments: ["python3", fixture.path])
        let tools = try await client.start()
        XCTAssertEqual(tools.map(\.name).sorted(), ["echo", "explode"])
        let echo = try XCTUnwrap(tools.first { $0.name == "echo" })
        // Namespaced, so two servers offering the same name do not collide silently.
        XCTAssertEqual(echo.qualifiedName, "mcp__echo__echo")
        XCTAssertEqual(echo.schema.path("properties.text.type")?.stringValue, "string")

        let ok = try await client.callTool("echo", arguments: .object(["text": .string("hello")]))
        XCTAssertEqual(ok.text, "hello")
        XCTAssertFalse(ok.isError)

        // A tool that reports failure is a result, not a thrown error: the agent needs to read
        // it and try something else.
        let bad = try await client.callTool("explode", arguments: .object([:]))
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("deliberate"))
        await client.stop()
    }),

    ("mcp: a missing server fails at start rather than at first call", {
        let client = MCPClient(
            name: "nope", executable: "/usr/bin/env",
            arguments: ["python3", "/nonexistent/definitely-not-here.py"])
        do {
            _ = try await client.start(timeout: 6)
            XCTFail("expected a failure from a server that cannot run")
        } catch {
            // Either shape is correct — what matters is that it fails now, with something
            // readable, rather than looking healthy until a tool is called.
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        await client.stop()
    }),

    ("mcp: configuration is read from the harness's own settings", {
        // An existing config should just work rather than needing a second one.
        let config = try XCTUnwrap(JSONValue.parse(Data(#"""
        {"mcpServers":{
          "files":{"command":"npx","args":["-y","server-filesystem","/tmp"],"env":{"A":"1"}},
          "remote":{"type":"sse","url":"https://example.com"},
          "off":{"command":"foo","disabled":true}
        }}
        """#.utf8)))
        let servers = MCPConfiguration.parse(config)
        XCTAssertEqual(servers.map(\.name), ["files", "off"],
                       "sse is skipped: this client speaks stdio, and half-starting it would "
                           + "fail at the first call instead of at load")
        let files = try XCTUnwrap(servers.first)
        XCTAssertEqual(files.command, "npx")
        XCTAssertEqual(files.arguments.count, 3)
        XCTAssertEqual(files.environment["A"], "1")
        XCTAssertTrue(files.enabled)
        XCTAssertFalse(try XCTUnwrap(servers.last).enabled, "`disabled` is honoured")
    }),

    ("agent: MCP tools are declared individually and dispatched by name", {
        guard let root = EngineLocator.repoRoot() else { return }
        let fixture = root.appending(path: "test-fixtures/mcp-echo.py")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            print("      skipped: no mcp fixture"); return
        }
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "mcp__echo__echo", "arguments": ["text": "via mcp"]]],
            ["text": "Echoed."],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let mcp = MCPClient(
            name: "echo", executable: "/usr/bin/env", arguments: ["python3", fixture.path])
        let tools = try await mcp.start()
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "sys"))
        await agent.addMCPTools(tools, from: mcp)
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("echo something")
        await writer.close()
        await mcp.stop()

        XCTAssertTrue(log.names.contains("tool:mcp__echo__echo"))
        XCTAssertTrue(log.names.contains("tool-ok"))
        // Each MCP tool gets its own schema in the request, rather than hiding behind one
        // dispatcher — a model picks a tool by reading its schema.
        let sent = try server.recordedRequests()
        let declared = (sent.first?["tools"]?.arrayValue ?? [])
            .compactMap { $0.path("function.name")?.stringValue }
        XCTAssertTrue(declared.contains("python"))
        XCTAssertTrue(declared.contains("mcp__echo__echo"))
        XCTAssertTrue(declared.contains("mcp__echo__explode"))
        // And the result reached the model.
        let second = try XCTUnwrap(sent.last?["messages"]?.arrayValue)
        XCTAssertTrue(second.contains { $0["content"]?.stringValue == "via mcp" })
    }),

    ("agent: an unknown tool name lists what is actually available", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "f", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s"))
        let (text, isError) = await agent.executeForTesting(
            id: "x", name: "read_file", arguments: .object([:]))
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("python"), "says what it could have called instead")
        await writer.close()
    }),

    // ------------------------------------------------------------------ memory
    ("memory: an append-only log folds into current beliefs", {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(repoRoot: root, home: AgentHome(root: root), cwd: "/tmp/proj")

        let first = MemoryEntry(
            id: "m1", scope: .project, text: "the test suite is an executable, not swift test",
            tags: ["testing"], createdAt: Date(), updatedAt: Date(),
            sessionID: "s1", provenance: "how do I run tests?")
        try store.append(first, sessionID: "s1")
        let live = store.load(sessionID: "s1")
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.provenance, "how do I run tests?",
                       "why it believes this is answerable, unlike the harness's version")

        // Correction is an append, not an edit: the mistake stays visible in the file.
        var retraction = first
        retraction.retired = true
        retraction.updatedAt = Date().addingTimeInterval(60)
        try store.append(retraction, sessionID: "s1")
        XCTAssertEqual(store.load(sessionID: "s1").count, 0, "retired, and by a later event")
        let raw = try String(contentsOf: try XCTUnwrap(store.url(for: .project)), encoding: .utf8)
        XCTAssertEqual(raw.split(separator: "\n").count, 2, "both events are still on disk")
    }),

    ("memory: an expiry stops something being recalled without deleting it", {
        // The tier the harness had no concept of: true for now, not forever.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(repoRoot: root, home: AgentHome(root: root), cwd: "/tmp/proj")
        try store.append(MemoryEntry(
            id: "old", scope: .project, text: "the staging box is down",
            tags: [], createdAt: Date(), updatedAt: Date(),
            expiresAt: Date().addingTimeInterval(-3600)), sessionID: nil)
        try store.append(MemoryEntry(
            id: "new", scope: .project, text: "prod is on the new schema",
            tags: [], createdAt: Date(), updatedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600)), sessionID: nil)
        let live = store.load(sessionID: nil)
        XCTAssertEqual(live.map(\.id), ["new"], "the expired one is not recalled")
        let raw = try String(contentsOf: try XCTUnwrap(store.url(for: .project)), encoding: .utf8)
        XCTAssertTrue(raw.contains("staging box"), "but it is still on disk to read")
    }),

    ("memory: session scope is written where the session's own artifacts live", {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = AgentHome(root: root)
        let store = MemoryStore(repoRoot: nil, home: home, cwd: "/tmp/proj")
        try store.append(MemoryEntry(
            id: "s", scope: .session, text: "mid-investigation: the flake is in fixture teardown",
            tags: [], createdAt: Date(), updatedAt: Date()), sessionID: "sess-9")
        let url = try XCTUnwrap(store.url(for: .session, sessionID: "sess-9"))
        XCTAssertTrue(url.path.contains("session-artifacts/sess-9"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // And a different session cannot see it — that is what makes the scope meaningful.
        XCTAssertEqual(store.load(sessionID: "sess-other").count, 0)
        XCTAssertEqual(store.load(sessionID: "sess-9").count, 1)
    }),

    ("memory: the gate lists what it cannot fit, with subjects rather than a count", {
        // The specific failure this replaces: the harness injected 6 entries per kind at 180
        // characters, sorted alphabetically, and rendered the rest as "+N more" — a number the
        // model could do nothing with, hiding the most recent entry behind the sort.
        let entries = (0..<30).map { i in
            MemoryEntry(
                id: "m\(i)", scope: .project, text: String(repeating: "detail \(i) ", count: 20),
                tags: ["topic-\(i)"], createdAt: Date(),
                updatedAt: Date().addingTimeInterval(Double(i)))
        }
        let gate = MemoryGate(budget: 600)
        let selection = gate.select(entries, prompt: "unrelated question")
        XCTAssertTrue(selection.included.count < entries.count, "the budget bit")
        XCTAssertFalse(selection.listed.isEmpty)
        // Recency decides ties, so the newest entry is included rather than hidden.
        XCTAssertEqual(selection.included.first?.id, "m29",
                       "newest first — the harness's alphabetical sort hid exactly this one")
        let rendered = gate.render(selection)
        XCTAssertTrue(rendered.contains("detail 29"), "the newest entry is shown in full")
        // The ones that missed the budget are named by subject, not counted — "+N more" told
        // the model a number it could do nothing with.
        let listedTag = try XCTUnwrap(selection.listed.first?.tags.first)
        XCTAssertTrue(rendered.contains(listedTag), "a listed entry is identified, not tallied")
        XCTAssertTrue(rendered.contains("recall(query)"), "says how to reach the rest")
        XCTAssertTrue(rendered.contains("remember(text"), "and how to add to it")
    }),

    ("memory: relevance beats recency, and session scope gets a thumb on the scale", {
        let old = MemoryEntry(
            id: "relevant", scope: .project, text: "clickhouse Identifier params cannot be dotted",
            tags: ["clickhouse"], createdAt: Date(), updatedAt: Date().addingTimeInterval(-9999))
        let recent = MemoryEntry(
            id: "irrelevant", scope: .project, text: "the icon script needs python3",
            tags: ["icons"], createdAt: Date(), updatedAt: Date())
        let working = MemoryEntry(
            id: "session", scope: .session, text: "currently bisecting the parser",
            tags: [], createdAt: Date(), updatedAt: Date().addingTimeInterval(-500))
        let gate = MemoryGate(budget: 10_000)
        let selection = gate.select([recent, old, working], prompt: "a clickhouse Identifier bug")
        XCTAssertEqual(selection.included.first?.id, "relevant",
                       "an older entry that matches beats a newer one that does not")
        // Session-scoped working state is nearly always relevant and always short-lived, so it
        // outranks an unrelated project note.
        let ids = selection.included.map(\.id)
        XCTAssertTrue(ids.firstIndex(of: "session")! < ids.firstIndex(of: "irrelevant")!)
    }),

    ("agent: remember and recall round-trip through the callback channel", {
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "f", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s"))

        // Without a store, the verbs refuse rather than silently doing nothing.
        let refused = await agent.serveCallback(
            kind: "remember", payload: .object(["text": .string("x")]))
        XCTAssertTrue((refused["error"]?.stringValue ?? "").contains("no memory store"))

        await agent.setMemory(MemoryStore(repoRoot: root, home: home, cwd: "/tmp/proj"))
        let empty = await agent.serveCallback(kind: "remember", payload: .object([:]))
        XCTAssertNotNil(empty["error"], "empty text is refused")

        let saved = await agent.serveCallback(kind: "remember", payload: .object([
            "text": .string("the fixture server records requests at /_requests"),
            "scope": .string("project"), "days": .number(7),
            "tags": .array([.string("testing")]),
        ]))
        XCTAssertNotNil(saved["id"]?.stringValue)
        XCTAssertEqual(saved["scope"]?.stringValue, "project")

        let found = await agent.serveCallback(
            kind: "recall", payload: .object(["query": .string("fixture requests")]))
        let hits = try XCTUnwrap(found["memories"]?.arrayValue)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue((hits[0]["text"]?.stringValue ?? "").contains("_requests"))

        // And the decision is visible in the transcript, at the moment it was made.
        await writer.close()
        let text = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Remembered (project)"))
    }),

    ("agent: memory verbs are only advertised when there is a store", {
        XCTAssertFalse(Agent.tools(cwd: "/tmp")[0].description.contains("remember("))
        let withMemory = Agent.tools(cwd: "/tmp", hasMemory: true)[0].description
        XCTAssertTrue(withMemory.contains("remember(text"))
        XCTAssertTrue(withMemory.contains("recall(query)"))
        XCTAssertTrue(withMemory.contains("'project'"), "names the scope it should usually pick")
        XCTAssertTrue(withMemory.contains("Not things the repository already says"),
                      "and what not to record, which is the harder half")
    }),

    ("pricing: rates are per million tokens, and silence is not zero", {
        var model = fakeModel()
        var usage = Usage()
        usage.input = 1_000_000
        usage.output = 500_000
        usage.cacheRead = 2_000_000
        // No rates published: cost must stay empty so `sessionsWithoutPricing` keeps meaning
        // "nothing published" rather than "free".
        XCTAssertEqual(model.priced(usage).cost.total, 0)

        model.costInput = 3
        model.costOutput = 15
        model.costCacheRead = 0.3
        let priced = model.priced(usage)
        XCTAssertEqual(priced.cost.input, 3, "1M input at $3/Mtok")
        XCTAssertEqual(priced.cost.output, 7.5, "0.5M output at $15/Mtok")
        XCTAssertEqual(priced.cost.cacheRead, 0.6, "2M cache reads at $0.30/Mtok")
        XCTAssertEqual(priced.cost.total, 11.1)

        // A route that publishes no cache rate still charges something, so the input rate is
        // the fallback rather than zero.
        model.costCacheRead = nil
        XCTAssertEqual(model.priced(usage).cost.cacheRead, 6, "2M cache reads at the input rate")
    }),

    ("agent: recorded payloads land in the shape the breakdown screen reads", {
        // The harness could only offer this through an extension, and even then the payload was
        // whatever the harness had already built. Owning the provider makes it a first-class
        // event.
        guard let server = try FakeProviderServer(script: [["text": "hi"]]) else {
            print("      skipped: no fixture"); return
        }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let logURL = home.root.appending(path: "wire/run.jsonl")
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "fake", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp",
                          systemPrompt: "a distinctive system prompt"))
        await agent.recordPayloads(to: logURL)
        await agent.send("hello")
        await writer.close()

        let records = WireLog.read(url: logURL)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.kind, .request)
        // Attributed by session *file*, which is the canonical id — the harness's own
        // prompt_cache_key looked like a session id and was a different one.
        XCTAssertEqual(record.sessionFile, writer.fileURL.path)
        let analysis = try XCTUnwrap(record.payload.map { WireLog.analyse(payload: $0) })
        XCTAssertTrue(analysis.totalCharacters > 0)
        XCTAssertTrue(analysis.segments.contains { $0.text?.contains("distinctive") == true },
                      "the system prompt is decomposable, which is the point of recording it")
    }),

    ("agent: nothing is recorded unless recording was asked for", {
        // It writes the full system prompt and conversation to disk, so it must never be
        // implicit.
        guard let server = try FakeProviderServer(script: [["text": "hi"]]) else { return }
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
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s"))
        await agent.send("hello")
        await writer.close()
        let wireDir = home.root.appending(path: "wire")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wireDir.path),
                       "no recording was requested, so nothing should exist")
    }),

    // ------------------------------------------------------------------ parity
    ("steering: a queued message lands at the next turn, not mid-turn", {
        // Mid-turn is impossible, not merely awkward: a tool call in flight has to be answered
        // before the model can be told anything, and injecting between a call and its result
        // makes a conversation the provider rejects.
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "python", "arguments": ["code": "a = 1"]]],
            ["text": "First answer."],
            ["text": "Adjusted."],
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
            provider: OpenAICompletionsProvider(id: "f", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s"))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.steer("actually, do it differently")
        await agent.send("do a thing")
        await writer.close()

        XCTAssertTrue(log.names.contains("steered"))
        // The steer was injected before the first model call, so it is in the first request.
        let sent = try server.recordedRequests()
        let first = try XCTUnwrap(sent.first?["messages"]?.arrayValue)
        let text = first.map { $0["content"]?.stringValue ?? "" }.joined(separator: " ")
        XCTAssertTrue(text.contains("do it differently"))
        // And a queue drained mid-run keeps the loop going rather than ending it.
        XCTAssertTrue(log.names.contains("finished:stop"))
    }),

    ("steering: a follow-up continues the run instead of ending it", {
        guard let server = try FakeProviderServer(script: [
            ["text": "Done with the first."],
            ["text": "Done with the second."],
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
            provider: OpenAICompletionsProvider(id: "f", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s"))
        await agent.queueFollowUp("and now the second thing")
        await agent.send("the first thing")
        let acceptedAfterReturn = await agent.queueFollowUp("too late for that generation")
        await writer.close()
        XCTAssertEqual(try server.recordedRequests().count, 2,
                       "the follow-up produced a second model call in the same run")
        let queued = await agent.queued
        XCTAssertTrue(queued.followUps.isEmpty, "and the queue drained")
        XCTAssertFalse(
            acceptedAfterReturn,
            "a quiescent agent rejects input that the completed generation cannot consume")
    }),

    ("goals: the budget is stated to the agent and enforced against it", {
        let goal = Goal(text: "audit the parser", tokenBudget: 1000)
        XCTAssertEqual(goal.status(spent: 999), .running)
        XCTAssertEqual(goal.status(spent: 1000), .tokensExhausted(spent: 1000, budget: 1000))
        // Stated, because a budget the agent cannot see is one it cannot plan against — it
        // spends the whole allowance exploring and gets cut off mid-thought.
        let briefing = goal.briefing(spent: 400)
        XCTAssertTrue(briefing.contains("audit the parser"))
        XCTAssertTrue(briefing.contains("600"), "remaining, not just the total")
        XCTAssertTrue(briefing.contains("what remains"), "and what to do when it runs short")

        let timed = Goal(
            text: "t", timeBudget: 600, startedAt: Date().addingTimeInterval(-601))
        guard case .timeExhausted = timed.status(spent: 0) else {
            XCTFail("expected the time budget to bite"); return
        }
        XCTAssertNotNil(timed.exhaustionNote(timed.status(spent: 0)))
        XCTAssertNil(goal.exhaustionNote(.running), "a running goal has nothing to report")
    }),

    ("goals: exhaustion stops the run and is recorded distinctly", {
        // A run that ran out of allowance and one that finished must not look alike.
        let script = (0..<6).map { _ in
            ["tool": ["name": "python", "arguments": ["code": "1"]], "input_tokens": 400]
                as [String: Any]
        }
        guard let server = try FakeProviderServer(script: script) else { return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(id: "f", baseURL: server.baseURL, apiKey: nil),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s",
                          maxIterations: 10, goal: Goal(text: "t", tokenBudget: 500)))
        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("go")
        await writer.close()
        XCTAssertTrue(log.names.contains("goal-exhausted"))
        XCTAssertTrue(log.names.contains("finished:goal budget"),
                      "distinct from a normal stop and from the iteration ceiling")
        let text = try String(contentsOf: writer.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Goal stopped"))
    }),

    ("promptTemplates: a slash command expands, and a wrong one is refused", {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-prompts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "review.md")
        try "Review $ARGUMENTS for correctness.".write(to: file, atomically: true, encoding: .utf8)
        let template = PromptTemplate(
            name: "review", url: file, sourceLabel: "test",
            firstLine: "Review", byteSize: 30)
        let expander = PromptExpander(templates: [template])

        let expanded = expander.expand("/review app/Sources/Agent.swift")
        XCTAssertEqual(expanded.prompt, "Review app/Sources/Agent.swift for correctness.")
        XCTAssertEqual(expanded.template?.name, "review")

        // A mistyped command must not reach the model as a literal slash — that reads as the
        // model ignoring an instruction.
        XCTAssertEqual(expander.expand("/revieww x").missing, "revieww")
        // A path in the middle of a sentence is not a command.
        XCTAssertNil(expander.expand("look at app/Sources /review").template)
        // Ordinary prompts pass through untouched.
        XCTAssertEqual(expander.expand("just do the thing").prompt, "just do the thing")
    }),

    ("promptTemplates: an argument with nowhere to go is appended, not dropped", {
        XCTAssertEqual(
            PromptExpander.substitute("Do the thing.", argument: "on file.swift"),
            "Do the thing.\n\non file.swift")
        XCTAssertEqual(
            PromptExpander.substitute("Check {{args}} twice.", argument: "x"),
            "Check x twice.")
        XCTAssertEqual(PromptExpander.substitute("Nothing to add.", argument: ""),
                       "Nothing to add.")
    }),

    ("schedules: a job is due on its interval and its counter advances", {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ScheduleStore(home: home, sessionID: "s1")
        XCTAssertTrue(store.load().isEmpty)

        try store.add(ScheduledJob(
            id: "j1", prompt: "check CI", everySeconds: 600,
            createdAt: Date().addingTimeInterval(-601)))
        var jobs = store.load()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertTrue(try XCTUnwrap(jobs.first).isDue(), "created long enough ago")

        try store.markRun(id: "j1")
        jobs = store.load()
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.runCount, 1)
        XCTAssertFalse(job.isDue(), "the counter advanced, so it is not due again yet")
        XCTAssertTrue(job.summary.contains("every 10m"))

        // Disabled jobs never fire, and removal is by id.
        try store.save([ScheduledJob(
            id: "j1", prompt: "check CI", everySeconds: 1, enabled: false,
            createdAt: Date().addingTimeInterval(-999))])
        XCTAssertFalse(try XCTUnwrap(store.load().first).isDue())
        try store.remove(id: "j1")
        XCTAssertTrue(store.load().isEmpty)
    }),

    ("schedules: they live with the session, so they cannot outlive it", {
        // The harness keyed cron jobs on a stable attachment id instead, which is why forking
        // a session silently moved its parent's schedule to the child.
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let a = ScheduleStore(home: home, sessionID: "session-a")
        let b = ScheduleStore(home: home, sessionID: "session-b")
        try a.add(ScheduledJob(prompt: "a's job", everySeconds: 60))
        XCTAssertEqual(a.load().count, 1)
        XCTAssertEqual(b.load().count, 0, "another session sees nothing of it")
        XCTAssertTrue(a.fileURL.path.contains("session-artifacts/session-a"))
    }),

    ("hooks: a hook can block a tool call and say why", {
        // Because `python` is the only built-in tool, one hook here is a complete permission
        // system — and it can rewrite rather than only veto, which is the difference between a
        // gate and a wall.
        guard let host = try makeHost(.reference) else { return }
        let capabilities = try await host.start()
        defer { Task { await host.stop() } }
        guard capabilities.has("hooks") else { print("      skipped: host has no hooks"); return }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hook = dir.appending(path: "guard.py")
        try """
            def on_before_tool(payload):
                if "forbidden" in payload["code"]:
                    return {"block": True, "reason": "Not that. Try the other thing."}
                if "widen" in payload["code"]:
                    return {"code": payload["code"] + "\\nwidened = True"}
                return None
            """.write(to: hook, atomically: true, encoding: .utf8)

        let result = try await host.loadHooks([hook.path])
        XCTAssertEqual(result.failed.count, 0)
        XCTAssertEqual(result.loaded.first?.events, ["on_before_tool"],
                       "a hook declares itself by defining on_<event>; nothing to register")

        let blocked = try await host.callHook("before_tool", payload: .object([
            "code": .string("do something forbidden"),
        ]))
        XCTAssertEqual(blocked?["block"]?.boolValue, true)
        XCTAssertTrue((blocked?["reason"]?.stringValue ?? "").contains("Try the other thing"))

        let rewritten = try await host.callHook("before_tool", payload: .object([
            "code": .string("widen this"),
        ]))
        XCTAssertTrue((rewritten?["code"]?.stringValue ?? "").contains("widened = True"))

        // An event no hook handles returns nil, so the loop pays nothing for it.
        let ignored = try await host.callHook("after_response", payload: .object([:]))
        XCTAssertNil(ignored)
    }),

    ("hooks: a broken hook is reported and does not stop anything", {
        // One bad extension must never take the run with it.
        guard let host = try makeHost(.reference) else { return }
        let capabilities = try await host.start()
        defer { Task { await host.stop() } }
        guard capabilities.has("hooks") else { return }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // One that cannot even import.
        let broken = dir.appending(path: "broken.py")
        try "import a_module_that_does_not_exist\n".write(
            to: broken, atomically: true, encoding: .utf8)
        // One with no events, which is a mistake worth naming rather than loading silently.
        let empty = dir.appending(path: "empty.py")
        try "x = 1\n".write(to: empty, atomically: true, encoding: .utf8)
        // One that loads and then throws when called.
        let throwing = dir.appending(path: "throwing.py")
        try "def on_before_tool(payload):\n    raise ValueError('boom')\n".write(
            to: throwing, atomically: true, encoding: .utf8)

        let result = try await host.loadHooks([broken.path, empty.path, throwing.path])
        XCTAssertEqual(result.failed.count, 2, "the unimportable one and the eventless one")
        XCTAssertTrue(result.failed.contains { $0.detail.contains("ModuleNotFound") })
        XCTAssertTrue(result.failed.contains { $0.detail.contains("on_<event>") },
                      "and it says what a hook file is supposed to look like")
        XCTAssertEqual(result.loaded.count, 1)

        // The throwing hook does not block, does not crash, and the host still serves.
        let decision = try await host.callHook("before_tool", payload: .object([
            "code": .string("anything"),
        ]))
        XCTAssertNil(decision, "a hook that raised decided nothing")
        let session = try await host.createSession(cwd: "/tmp")
        let alive = try await host.execute("'still here'", in: session)
        XCTAssertEqual(alive.value, "'still here'")
    }),

    ("hooks: they cannot see a session's variables", {
        // Their own interpreter, so a hook cannot read one session's state while running on
        // behalf of another.
        guard let host = try makeHost(.reference) else { return }
        let capabilities = try await host.start()
        defer { Task { await host.stop() } }
        guard capabilities.has("hooks") else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hook = dir.appending(path: "peek.py")
        try """
            def on_before_tool(payload):
                return {"saw": "secret_value" in globals()}
            """.write(to: hook, atomically: true, encoding: .utf8)
        _ = try await host.loadHooks([hook.path])

        let session = try await host.createSession(cwd: "/tmp")
        _ = try await host.execute("secret_value = 'hunter2'", in: session)
        let decision = try await host.callHook("before_tool", payload: .object([
            "code": .string("x"), "session": .string(session),
        ]))
        XCTAssertEqual(decision?["saw"]?.boolValue, false,
                       "the hook interpreter is separate from every session")
    }),

    ("hooks: discovery is ordered and ignores disabled files", {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-repo-\(UUID().uuidString)")
        let hooks = dir.appending(path: "hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["20-second.py", "10-first.py", "example.py.disabled", "README.md"] {
            FileManager.default.createFile(atPath: hooks.appending(path: name).path, contents: nil)
        }
        let found = HookDiscovery.paths(repoRoot: dir).map { URL(fileURLWithPath: $0).lastPathComponent }
        // Sorted, because load order decides how a chain of hooks refines a decision and
        // filesystem order is not a decision anyone made.
        XCTAssertEqual(found, ["10-first.py", "20-second.py"])
        XCTAssertEqual(HookDiscovery.paths(repoRoot: nil), [])
    }),

    // ------------------------------------------------------------------ codex auth
    //
    // These assert *fidelity to the harness*, not correctness in the abstract. Every constant
    // here was transcribed from harness/packages/ai/src/utils/oauth/openai-codex.ts and
    // providers/openai-codex-responses.ts. A failure means the two clients now differ, which is
    // the thing to avoid — third-party harness use is tolerated, and looking like a *novel*
    // client is what risks being mistaken for credential resale.

    ("codex: the constants match the reference exactly", {
        XCTAssertEqual(CodexAuth.clientID, "app_EMoamEEZ73f0CkXaXp7hrann")
        XCTAssertEqual(CodexAuth.authorizeURL, "https://auth.openai.com/oauth/authorize")
        XCTAssertEqual(CodexAuth.tokenURL, "https://auth.openai.com/oauth/token")
        // The port is registered against the client id; any other value is rejected.
        XCTAssertEqual(CodexAuth.redirectURI, "http://localhost:1455/auth/callback")
        XCTAssertEqual(CodexAuth.callbackPort, 1455)
        XCTAssertEqual(CodexAuth.scope, "openid profile email offline_access")
        XCTAssertEqual(CodexAuth.jwtClaimPath, "https://api.openai.com/auth")
        // The client's identity to OpenAI. A different originator is exactly the anomaly to
        // avoid.
        XCTAssertEqual(CodexAuth.originator, "pi")
    }),

]

let cases4: [Case] = [
    ("codex: the authorize URL carries all ten parameters in the reference's order", {
        let url = CodexAuth.authorizationURL(challenge: "CH", state: "ST")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), [
            "response_type", "client_id", "redirect_uri", "scope",
            "code_challenge", "code_challenge_method", "state",
            // Codex-specific and not optional in practice: without them the consent screen
            // differs and the token lacks organization claims.
            "id_token_add_organizations", "codex_cli_simplified_flow", "originator",
        ])
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(items.first { $0.name == "id_token_add_organizations" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "codex_cli_simplified_flow" }?.value, "true")
        XCTAssertEqual(items.first { $0.name == "originator" }?.value, "pi")
    }),

    ("codex: PKCE hashes the encoded verifier, not the raw bytes", {
        // Getting this backwards produces a challenge the server rejects, and the failure is a
        // generic invalid_grant that says nothing about why.
        let (verifier, challenge) = CodexAuth.generatePKCE()
        XCTAssertEqual(verifier.count, 43, "32 bytes, base64url, unpadded")
        for token in ["+", "/", "="] {
            XCTAssertFalse(verifier.contains(token), "base64url, not base64")
            XCTAssertFalse(challenge.contains(token))
        }
        // Recomputing over the verifier *string* must reproduce the challenge.
        let expected = CodexAuth.base64URLEncode(
            Data(SHA256.hash(data: Data(verifier.utf8))))
        XCTAssertEqual(challenge, expected)
        let (other, _) = CodexAuth.generatePKCE()
        XCTAssertNotEqual(verifier, other, "fresh randomness each time")
    }),

    ("codex: form encoding matches URLSearchParams", {
        // The token endpoint takes x-www-form-urlencoded, and a wrongly-escaped verifier fails
        // with the same opaque error as a wrong challenge.
        let encoded = CodexAuth.formEncode(["grant_type": "refresh_token", "a b": "c+d/e=f"])
        XCTAssertTrue(encoded.contains("grant_type=refresh_token"))
        XCTAssertTrue(encoded.contains("a%20b=c%2Bd%2Fe%3Df"),
                      "reserved characters escaped, got: \(encoded)")
    }),

    ("codex: the account id comes from the right JWT claim", {
        // Nested under "https://api.openai.com/auth", which is not a path a generic JWT reader
        // would find.
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"},"sub":"x"}"#
        let encoded = CodexAuth.base64URLEncode(Data(payload.utf8))
        let token = "header.\(encoded).signature"
        XCTAssertEqual(CodexAuth.accountID(fromAccessToken: token), "acct-123")
        // Absent claim, wrong shape, and a non-JWT all return nil rather than something wrong.
        let empty = CodexAuth.base64URLEncode(Data(#"{"sub":"x"}"#.utf8))
        XCTAssertNil(CodexAuth.accountID(fromAccessToken: "h.\(empty).s"))
        XCTAssertNil(CodexAuth.accountID(fromAccessToken: "not-a-jwt"))
    }),

    ("codex: expiry uses the same comparison as the harness", {
        // `>=` on milliseconds, with no early-refresh window: a different threshold would mean
        // the two clients disagree about whether a stored token is still usable.
        let now = Int(Date().timeIntervalSince1970 * 1000)
        XCTAssertTrue(CodexAuth.Credentials(
            access: "a", refresh: "r", expires: now - 1, accountId: "x").isExpired)
        XCTAssertFalse(CodexAuth.Credentials(
            access: "a", refresh: "r", expires: now + 60_000, accountId: "x").isExpired)
    }),

    ("codex: pasted input is accepted in all four shapes", {
        let url = CodexAuth.parseAuthorizationInput(
            "http://localhost:1455/auth/callback?code=C1&state=S1")
        XCTAssertEqual(url.code, "C1")
        XCTAssertEqual(url.state, "S1")
        let hashed = CodexAuth.parseAuthorizationInput("C2#S2")
        XCTAssertEqual(hashed.code, "C2")
        XCTAssertEqual(hashed.state, "S2")
        let query = CodexAuth.parseAuthorizationInput("code=C3&state=S3")
        XCTAssertEqual(query.code, "C3")
        XCTAssertEqual(query.state, "S3")
        XCTAssertEqual(CodexAuth.parseAuthorizationInput("  C4  ").code, "C4")
        XCTAssertNil(CodexAuth.parseAuthorizationInput("   ").code)
    }),

    ("codex: the credential store shares auth.json without disturbing other providers", {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        // Something the harness put there that Aviary must not lose.
        try #"{"anthropic":{"type":"api_key","key":"sk-keep-me"}}"#
            .write(to: home.authFile, atomically: true, encoding: .utf8)

        let store = CodexAuth.Store(home: home)
        XCTAssertNil(store.credentials(), "nothing stored for codex yet")
        try store.save(CodexAuth.Credentials(
            access: "at", refresh: "rt", expires: 1_700_000_000_000, accountId: "acct"))

        let read = try XCTUnwrap(store.credentials())
        XCTAssertEqual(read.access, "at")
        XCTAssertEqual(read.accountId, "acct")
        XCTAssertEqual(read.expires, 1_700_000_000_000, "milliseconds, as the harness stores it")

        let raw = try XCTUnwrap(JSONValue.parse(
            try Data(contentsOf: home.authFile)))
        XCTAssertEqual(raw.path("anthropic.key")?.stringValue, "sk-keep-me",
                       "the other provider survived a read-modify-write")
        XCTAssertEqual(raw.path("openai-codex.type")?.stringValue, "oauth")
        // 0600, like the harness — an atomic replace does not inherit the old mode.
        let mode = try FileManager.default.attributesOfItem(
            atPath: home.authFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }),

    // ------------------------------------------------------------------ codex requests
    ("codex: the URL is <base>/codex/responses, however the base is written", {
        XCTAssertEqual(
            CodexResponsesProvider.resolveURL(nil).absoluteString,
            "https://chatgpt.com/backend-api/codex/responses")
        for base in ["https://x.test", "https://x.test/", "https://x.test/codex",
                     "https://x.test/codex/responses"] {
            XCTAssertEqual(
                CodexResponsesProvider.resolveURL(base).absoluteString,
                "https://x.test/codex/responses", "base \(base)")
        }
    }),

    ("codex: the header set matches the reference, spellings included", {
        let headers = CodexResponsesProvider.headers(
            token: "TK", accountID: "ACC", sessionID: "SID")
        XCTAssertEqual(headers["Authorization"], "Bearer TK")
        XCTAssertEqual(headers["chatgpt-account-id"], "ACC")
        XCTAssertEqual(headers["originator"], "pi")
        XCTAssertEqual(headers["OpenAI-Beta"], "responses=experimental")
        // Lowercase, because that is how the reference sets them.
        XCTAssertEqual(headers["accept"], "text/event-stream")
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertEqual(headers["session_id"], "SID")
        XCTAssertEqual(headers["x-client-request-id"], "SID")
        // `pi (<platform> <release>; <arch>)`, and Node reports x64 rather than x86_64.
        let agent = try XCTUnwrap(headers["User-Agent"])
        XCTAssertTrue(agent.hasPrefix("pi (darwin "), "got \(agent)")
        XCTAssertFalse(agent.contains("x86_64"), "Node reports x64")
        // Without a session id, neither correlation header is invented.
        let bare = CodexResponsesProvider.headers(token: "T", accountID: "A", sessionID: nil)
        XCTAssertNil(bare["session_id"])
        XCTAssertNil(bare["x-client-request-id"])
    }),

    ("codex: the request body matches a captured harness payload field for field", {
        // Verified empirically against a real recorded harness request on 2026-08-22: every
        // field below was compared and found identical.
        let body = CodexResponsesProvider.body(
            for: ChatRequest(
                model: "gpt-5.6-terra",
                messages: [.system("SYS"), .user("hello")],
                tools: Agent.tools(cwd: "/tmp")),
            sessionID: "sess-1", model: nil)
        XCTAssertEqual(body["model"]?.stringValue, "gpt-5.6-terra")
        // The endpoint rejects store: true ("Store must be set to false").
        XCTAssertEqual(body["store"]?.boolValue, false)
        XCTAssertEqual(body["stream"]?.boolValue, true)
        // The system prompt is `instructions`, not a message.
        XCTAssertEqual(body["instructions"]?.stringValue, "SYS")
        XCTAssertEqual(body.path("text.verbosity")?.stringValue, "low")
        // How reasoning survives a turn on this route.
        XCTAssertEqual(body["include"]?.arrayValue?.first?.stringValue,
                       "reasoning.encrypted_content")
        XCTAssertEqual(body["tool_choice"]?.stringValue, "auto")
        XCTAssertEqual(body["parallel_tool_calls"]?.boolValue, true)
        XCTAssertEqual(body["prompt_cache_key"]?.stringValue, "sess-1")
        XCTAssertEqual(body["service_tier"]?.stringValue, "default")
        // Present by default, because it is present on a harness request.
        XCTAssertEqual(body.path("reasoning.effort")?.stringValue, "medium")
        XCTAssertEqual(body.path("reasoning.summary")?.stringValue, "auto")
        // `strict: null` for this provider — not false, and not absent.
        let tool = try XCTUnwrap(body["tools"]?.arrayValue?.first)
        XCTAssertEqual(tool["type"]?.stringValue, "function")
        XCTAssertTrue(tool["strict"]?.isNull ?? false)
        XCTAssertNotNil(tool["parameters"])
        // No system message in `input`.
        let input = try XCTUnwrap(body["input"]?.arrayValue)
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"]?.stringValue, "user")
        XCTAssertEqual(input[0].path("content.0.type")?.stringValue, "input_text")
    }),

    ("codex: an empty system prompt still sends the reference's fallback", {
        let body = CodexResponsesProvider.body(
            for: ChatRequest(model: "m", messages: [.user("hi")]),
            sessionID: nil, model: nil)
        XCTAssertEqual(body["instructions"]?.stringValue, "You are a helpful assistant.")
        XCTAssertNil(body["prompt_cache_key"], "not invented when there is no session")
    }),

    ("codex: a thinking level the model maps to null omits reasoning entirely", {
        // The map's values are optional for exactly this: gpt-5.6 sends `minimal` to null, and
        // sending a default instead would be a request the route did not ask for.
        var model = fakeModel()
        model.thinkingLevelMap = ["xhigh": "xhigh", "minimal": nil, "max": "max"]
        let omitted = CodexResponsesProvider.body(
            for: ChatRequest(model: "m", messages: [.user("x")], reasoningEffort: "minimal"),
            sessionID: nil, model: model)
        XCTAssertNil(omitted["reasoning"])
        let mapped = CodexResponsesProvider.body(
            for: ChatRequest(model: "m", messages: [.user("x")], reasoningEffort: "xhigh"),
            sessionID: nil, model: model)
        XCTAssertEqual(mapped.path("reasoning.effort")?.stringValue, "xhigh")
    }),

    ("codex: tool calls and results use call_id and encoded arguments", {
        let body = CodexResponsesProvider.body(
            for: ChatRequest(model: "m", messages: [
                ChatMessage(role: .assistant, content: [
                    // The harness's ids can be `callId|itemId`; only the call id is sent.
                    .toolCall(id: "call_1|fc_abc", name: "python",
                              arguments: .object(["code": .string("1+1")])),
                ]),
                ChatMessage(role: .tool, content: [
                    .toolResult(id: "call_1|fc_abc", name: "python", text: "2", isError: false),
                ]),
            ]), sessionID: nil, model: nil)
        let input = try XCTUnwrap(body["input"]?.arrayValue)
        XCTAssertEqual(input[0]["type"]?.stringValue, "function_call")
        XCTAssertEqual(input[0]["call_id"]?.stringValue, "call_1")
        // A JSON *string*, which is what the Responses API takes here.
        XCTAssertEqual(input[0]["arguments"]?.stringValue, #"{"code":"1+1"}"#)
        XCTAssertEqual(input[1]["type"]?.stringValue, "function_call_output")
        XCTAssertEqual(input[1]["call_id"]?.stringValue, "call_1")
        XCTAssertEqual(input[1]["output"]?.stringValue, "2")
    }),

    ("codex: retry classification matches the reference", {
        for status in [429, 500, 502, 503, 504] {
            XCTAssertTrue(CodexResponsesProvider.isRetryable(status: status, body: ""), "\(status)")
        }
        XCTAssertFalse(CodexResponsesProvider.isRetryable(status: 400, body: "bad request"))
        XCTAssertFalse(CodexResponsesProvider.isRetryable(status: 401, body: "unauthorized"))
        // And the body patterns, which catch a 200-with-error and an upstream failure.
        XCTAssertTrue(CodexResponsesProvider.isRetryable(status: 400, body: "Rate limit hit"))
        XCTAssertTrue(CodexResponsesProvider.isRetryable(status: 400, body: "upstream connect error"))
        XCTAssertTrue(CodexResponsesProvider.isRetryable(status: 400, body: "service unavailable"))
    }),

    ("codex: a usage-limit error becomes something a person can act on", {
        let resets = Date().addingTimeInterval(1800).timeIntervalSince1970
        let friendly = CodexResponsesProvider.friendlyError(
            #"{"error":{"code":"usage_limit_reached","plan_type":"Plus","resets_at":\#(Int(resets))}}"#)
        let text = try XCTUnwrap(friendly)
        XCTAssertTrue(text.contains("usage limit"))
        XCTAssertTrue(text.contains("plus plan"))
        XCTAssertTrue(text.contains("29 minutes") || text.contains("30 minutes"), "got \(text)")
        // An ordinary error passes its message through rather than being dressed up.
        XCTAssertEqual(
            CodexResponsesProvider.friendlyError(#"{"error":{"message":"nope"}}"#), "nope")
        XCTAssertNil(CodexResponsesProvider.friendlyError("not json"))
    }),

    // MARK: The reachable-model catalogue
    //
    // This replaced booting the harness over RPC to ask what models exist. The rules that
    // matter are about *stability*: a catalogue that reshuffles when a provider adds a model,
    // or that makes a disabled model unresumable, is worse than the RPC call it replaced.

    ("catalog: only providers with working credentials are reachable", {
        let config = testModelsConfig([
            "gateway": ["a", "b"],
            "nokey": ["c"],
        ])
        let catalog = ModelCatalogBuilder.build(
            config: config, auth: nil, credentialed: ["gateway"],
            preferences: ModelPreferences())
        XCTAssertEqual(catalog.reachable.map(\.id), ["gateway"])
        XCTAssertEqual(catalog.models.map(\.id), ["a", "b"])
        // The unreachable one is kept, not dropped: "you configured this and it is not working"
        // is more useful than showing nothing.
        XCTAssertTrue(catalog.unreachable.contains { $0.id == "nokey" })
    }),

    ("catalog: a built-in provider is reachable exactly when its login is stored", {
        var auth = AuthInfo()
        let empty = ModelCatalogBuilder.build(
            config: testModelsConfig([:]), auth: auth, credentialed: [],
            preferences: ModelPreferences())
        XCTAssertTrue(empty.models.isEmpty, "codex must not be offered without a login")

        auth.providers.insert("openai-codex")
        let logged = ModelCatalogBuilder.build(
            config: testModelsConfig([:]), auth: auth, credentialed: [],
            preferences: ModelPreferences())
        XCTAssertEqual(logged.reachable.map(\.id), ["openai-codex"])
        XCTAssertTrue(logged.models.contains { $0.id == "gpt-5.6-terra" })
        // Every codex model comes through, which is the count the RPC catalogue reported.
        XCTAssertEqual(logged.models.count, BuiltInProviders.openAICodex().models.count)
    }),

    ("catalog: a models.json provider beats a built-in with the same id", {
        // Same precedence as `AgentCLI.resolve`: configuring a provider explicitly means it.
        var auth = AuthInfo()
        auth.providers.insert("openai-codex")
        let config = testModelsConfig(["openai-codex": ["my-own-model"]])
        let catalog = ModelCatalogBuilder.build(
            config: config, auth: auth, credentialed: ["openai-codex"],
            preferences: ModelPreferences())
        XCTAssertEqual(catalog.reachable.count, 1)
        XCTAssertEqual(catalog.models.map(\.id), ["my-own-model"])
    }),

    ("catalog: an explicit order is honoured and unlisted models keep catalogue order", {
        // The stability rule. A model that shows up in models.json tomorrow must neither jump
        // to the top nor disappear — it lands after the pinned ones, where it came in.
        let config = testModelsConfig(["p": ["a", "b", "c", "d"]])
        let prefs = ModelPreferences(order: ["p/c", "p/a"])
        let catalog = ModelCatalogBuilder.build(
            config: config, auth: nil, credentialed: ["p"], preferences: prefs)
        XCTAssertEqual(catalog.models.map(\.id), ["c", "a", "b", "d"])
    }),

    ("catalog: a disabled model is offered nowhere but is still findable", {
        // Disabling hides a model from pickers. It must not break resuming a session that
        // already uses it, which is why `find` ignores the preference.
        let config = testModelsConfig(["p": ["keep", "hide"]])
        let prefs = ModelPreferences(disabled: ["p/hide"])
        let catalog = ModelCatalogBuilder.build(
            config: config, auth: nil, credentialed: ["p"], preferences: prefs)
        XCTAssertEqual(catalog.models.count, 2)
        XCTAssertEqual(catalog.enabled.map(\.id), ["keep"])
        XCTAssertEqual(catalog.disabledCount, 1)
        XCTAssertEqual(catalog.find("p/hide")?.id, "hide")
        XCTAssertEqual(catalog.find("hide")?.id, "hide")
    }),

    ("catalog: disabling is keyed on the qualified id, not the bare model", {
        // The same model id can be reachable directly and through a gateway; those are
        // different routes at different prices, and hiding one must not hide the other.
        let config = testModelsConfig(["direct": ["shared"], "gateway": ["shared"]])
        let prefs = ModelPreferences(disabled: ["gateway/shared"])
        let catalog = ModelCatalogBuilder.build(
            config: config, auth: nil, credentialed: ["direct", "gateway"], preferences: prefs)
        XCTAssertEqual(catalog.enabled.map(\.qualifiedID), ["direct/shared"])
    }),

    ("catalog: each provider's own list matches the flat order", {
        // A per-provider picker and the flat switcher must not disagree.
        let config = testModelsConfig(["p": ["a", "b"], "q": ["x", "y"]])
        let prefs = ModelPreferences(order: ["p/b", "q/y", "p/a"])
        let catalog = ModelCatalogBuilder.build(
            config: config, auth: nil, credentialed: ["p", "q"], preferences: prefs)
        XCTAssertEqual(catalog.models.map(\.qualifiedID), ["p/b", "q/y", "p/a", "q/x"])
        let p = try XCTUnwrap(catalog.reachable.first { $0.id == "p" })
        XCTAssertEqual(p.models.map(\.id), ["b", "a"])
        let q = try XCTUnwrap(catalog.reachable.first { $0.id == "q" })
        XCTAssertEqual(q.models.map(\.id), ["y", "x"])
    }),

    ("catalog: pinning a group leaves other groups where they were", {
        // Reordering one provider's models must not scramble another's.
        let config = testModelsConfig(["p": ["a", "b"], "q": ["x", "y"]])
        var prefs = ModelPreferences(order: ["q/y", "q/x", "p/a", "p/b"])
        let pModels = ModelCatalogBuilder.build(
            config: config, auth: nil, credentialed: ["p", "q"], preferences: prefs)
            .models.filter { $0.providerID == "p" }
        // Reverse p's two models.
        prefs.pin(pModels.reversed())
        let after = ModelCatalogBuilder.build(
            config: config, auth: nil, credentialed: ["p", "q"], preferences: prefs)
        // p's pair flipped and stayed after q's pair, which was untouched.
        XCTAssertEqual(after.models.map(\.qualifiedID), ["q/y", "q/x", "p/b", "p/a"])
    }),

    ("catalog: a full round trip through the preferences store", {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-prefs-\(UUID().uuidString)")
        let store = ModelPreferencesStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(store.load(), ModelPreferences(), "a missing file is not an error")
        let prefs = ModelPreferences(order: ["p/b", "p/a"], disabled: ["p/c"])
        store.save(prefs)
        XCTAssertEqual(store.load(), prefs)
    }),

    ("catalog: an api key expression that resolves to nothing is not a credential", {
        // A provider whose `!command` fails silently would otherwise look reachable and then
        // fail on the first request, which is a much worse place to find out.
        XCTAssertNil(await ModelCatalogBuilder.resolveSecret(nil))
        XCTAssertNil(await ModelCatalogBuilder.resolveSecret(""))
        XCTAssertEqual(await ModelCatalogBuilder.resolveSecret("sk-literal"), "sk-literal")
        XCTAssertNil(await ModelCatalogBuilder.resolveSecret("!exit 1"))
        XCTAssertEqual(await ModelCatalogBuilder.resolveSecret("!printf hello"), "hello")
    }),

    // MARK: Resuming a session
    //
    // Resume's failure mode is that it works and is subtly wrong: a conversation that differs
    // from the recorded one makes the model behave oddly while the transcript still looks
    // fine. These pin the departures the replay is allowed to make, and the two shapes that
    // are not valid to send at all.

    ("resume: a plain exchange replays in wire order with no system message", {
        // The agent builds its own system prompt from the current skills and context files;
        // a replayed one would silently override it.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"first"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}
        {"type":"message","id":"a3","parentId":"a2","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"second"}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(r.messages.map(\.plainText), ["first", "reply", "second"])
        XCTAssertFalse(r.messages.contains { $0.role == .system })
        XCTAssertNil(r.caveat)
        XCTAssertEqual(r.turnCount, 3)
    }),

    ("resume: a tool call and its result replay as an assistant turn then a tool turn", {
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"count"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"running"},{"type":"toolCall","id":"tc1","name":"ipython","arguments":{"code":"print(1)"}}]}}
        {"type":"message","id":"a3","parentId":"a2","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"toolResult","toolCallId":"tc1","toolName":"ipython","content":[{"type":"text","text":"1"}],"isError":false}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.messages.map(\.role), [.user, .assistant, .tool])
        // The call stays attached to the assistant turn that made it.
        XCTAssertEqual(r.messages[1].toolCalls.count, 1)
        XCTAssertEqual(r.messages[1].toolCalls.first?.id, "tc1")
        XCTAssertEqual(r.messages[1].toolCalls.first?.arguments["code"]?.stringValue, "print(1)")
        guard case let .toolResult(id, name, text, isError) = r.messages[2].content[0] else {
            return XCTFail("expected a tool result, got \(r.messages[2].content)")
        }
        XCTAssertEqual(id, "tc1")
        XCTAssertEqual(name, "ipython")
        XCTAssertEqual(text, "1")
        XCTAssertFalse(isError)
        XCTAssertNil(r.caveat)
    }),

    ("resume: an interrupted tool call gets a synthetic result", {
        // A call with no result is not a valid request — providers reject it. The run that
        // died mid-tool is exactly the one worth resuming, so this cannot just drop the turn.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc1","name":"ipython","arguments":{"code":"sleep(999)"}}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(r.synthesizedToolResults, 1)
        guard case let .toolResult(id, _, text, isError) = r.messages[2].content[0] else {
            return XCTFail("expected a synthetic tool result")
        }
        XCTAssertEqual(id, "tc1")
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("No result recorded"), "got \(text)")
        XCTAssertEqual(r.caveat, "1 unfinished tool call marked as interrupted")
    }),

    ("resume: an empty tool result is kept, because empty is a real result", {
        // Distinguishing "" from nil is the whole reason the synthetic path is safe.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc1","name":"ipython","arguments":{"code":"pass"}}]}}
        {"type":"message","id":"a3","parentId":"a2","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"toolResult","toolCallId":"tc1","toolName":"ipython","content":[{"type":"text","text":""}],"isError":false}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.synthesizedToolResults, 0)
        guard case let .toolResult(_, _, text, isError) = r.messages[2].content[0] else {
            return XCTFail("expected a tool result")
        }
        XCTAssertEqual(text, "")
        XCTAssertFalse(isError)
    }),

    ("models: a test completion is a diagnostic and moves no selection", {
        // Reported as "sending a test completion to the gateway moves the workshop agent onto
        // the gateway's first model". It does not: `ProviderTester` opens a socket and nothing
        // else. What actually happened is that the workshop agent named no model at all, so it
        // resolved to the first model of the first provider in models.json — which is also what
        // the Models screen's test button defaults to. Two independent defaults agreeing looks
        // exactly like one writing the other, so this pins the half that must stay inert: after
        // a completed round trip, every file that could hold a selection is byte-identical.
        guard let server = try FakeProviderServer(script: [["text": "ok"]])
        else { print("      skipped: no fixture"); return }
        defer { server.stop() }

        let home = scratchHome()
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home.root) }

        try Data("""
            {"defaultProvider":"openai-codex","defaultModel":"gpt-5.6-terra",
             "recentModels":["openai-codex/gpt-5.6-terra"]}
            """.utf8).write(to: home.settingsFile)
        try Data("""
            {"providers":{"gateway":{"baseUrl":"\(server.baseURL.absoluteString)/",
             "apiKey":"sk-test","models":[{"id":"aaa-first"},{"id":"zzz-last"}]}}}
            """.utf8).write(to: home.modelsFile)
        let prefsStore = ModelPreferencesStore(
            directory: home.root.appending(path: "prefs", directoryHint: .isDirectory))
        prefsStore.save(ModelPreferences(order: ["gateway/zzz-last"]))

        let watched = [home.settingsFile, home.modelsFile, prefsStore.fileURL]
        let before = watched.map { FileManager.default.contents(atPath: $0.path) }

        let config = ModelsConfig.load(home: home, auth: nil)
        let provider = try XCTUnwrap(config.providers.first { $0.id == "gateway" })
        // The button's own default, so the test sends what a click sends.
        let result = await ProviderTester.test(provider: provider, model: provider.models.first)
        XCTAssertEqual(result.httpStatus, 200, "the round trip has to have happened: \(result.detail)")
        XCTAssertEqual(result.modelID, "aaa-first")

        XCTAssertEqual(
            watched.map { FileManager.default.contents(atPath: $0.path) }, before,
            "a diagnostic wrote to disk")
        // Said again through the readers, because a byte comparison would not catch a write
        // that happened to reproduce the same bytes in a different file.
        let settings = HarnessSettings.load(home: home)
        XCTAssertEqual(settings.defaultProvider, "openai-codex")
        XCTAssertEqual(settings.defaultModel, "gpt-5.6-terra")
        XCTAssertEqual(settings.recentModels, ["openai-codex/gpt-5.6-terra"])
        XCTAssertEqual(prefsStore.load().order, ["gateway/zzz-last"])
        // And no models.json backup, which is how any write through `ModelsConfig.write`
        // would announce itself.
        let strays = try FileManager.default.contentsOfDirectory(atPath: home.root.path)
            .filter { $0.hasPrefix("models.json.") }
        XCTAssertTrue(strays.isEmpty, "unexpected: \(strays)")
    }),

    ("catalog: a refresh hands a picker the same values, not merely the same names", {
        // Underneath the flashing Live submenus. `RunOptionsMenu` refuses to rebuild its
        // NSMenu while the models it draws compare equal, and `refreshRuntimeModels` rebuilds
        // the catalogue from scratch every time it runs — so `ModelSpec` equality across two
        // independent loads is the precondition the whole fix rests on. Names matching is not
        // enough: one field that differs per load (a date, a resolved key, an identity) and
        // the menu is rebuilt on every refresh again.
        //
        // It does not prove the submenu stays open. Nothing here can; that needs a mouse.
        let home = scratchHome()
        try FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home.root) }
        try Data("""
            {"providers":{
              "zeta":{"apiKey":"sk-a","models":[{"id":"m2"},{"id":"m1"}]},
              "alpha":{"apiKey":"sk-b","models":[{"id":"only"}]}}}
            """.utf8).write(to: home.modelsFile)

        let prefs = ModelPreferences(order: ["zeta/m2"])
        func offered() -> [ModelSpec] {
            ModelCatalogBuilder.build(
                config: ModelsConfig.load(home: home, auth: nil), auth: nil,
                credentialed: ["zeta", "alpha"], preferences: prefs).enabled
        }
        let first = offered(), second = offered()
        XCTAssertEqual(first.map(\.qualifiedID), ["zeta/m2", "alpha/only", "zeta/m1"])
        XCTAssertEqual(first, second, "two loads of one file disagree, so a picker rebuilds")
    }),

]

let cases5: [Case] = [
    ("resume: visible thinking is dropped rather than re-sent", {
        // The routes that produce reasoning want their own encrypted form echoed back, and
        // Codex's `reasoning.encrypted_content` is deliberately not persisted. Sending the
        // human-readable summary in its place would be a quiet lie about what it thought.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me think"},{"type":"text","text":"done"}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.droppedThinkingBlocks, 1)
        XCTAssertEqual(r.messages[1].content.count, 1)
        XCTAssertEqual(r.messages[1].plainText, "done")
    }),

    ("resume: an assistant turn that was only thinking is not sent as an empty message", {
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"only thoughts"}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.messages.map(\.role), [.user])
    }),

    ("resume: a compaction marker cuts history to first task plus summary", {
        // Mirrors the in-process shape exactly — `compactIfNeeded` keeps [system, first task],
        // replaces the middle with one user turn, and keeps the tail. A resumed run whose
        // history differs in shape from a run that compacted while alive is a divergence
        // nobody would ever see.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"the original task"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"lots of middle"}]}}
        {"type":"message","id":"a3","parentId":"a2","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"more middle"}]}}
        {"type":"compaction","id":"a4","parentId":"a3","timestamp":"2026-08-20T10:00:04.000Z","summary":"Established X and Y.","tokensBefore":90000}
        {"type":"message","id":"a5","parentId":"a4","timestamp":"2026-08-20T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"after the cut"}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertTrue(r.resumedAfterCompaction)
        XCTAssertEqual(r.messages.map(\.role), [.user, .user, .assistant])
        XCTAssertEqual(r.messages[0].plainText, "the original task")
        XCTAssertEqual(r.messages[1].plainText, "[Earlier work, compacted]\n\nEstablished X and Y.")
        XCTAssertEqual(r.messages[2].plainText, "after the cut")
        XCTAssertEqual(r.caveat, "resuming from a compaction summary")
    }),

    ("resume: a departure before the compaction cut is not reported", {
        // The interrupted call was dropped along with everything else the summary replaced,
        // so reporting it would describe something that is not being sent.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"task"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc1","name":"ipython","arguments":{}}]}}
        {"type":"compaction","id":"a3","parentId":"a2","timestamp":"2026-08-20T10:00:03.000Z","summary":"Summary."}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.synthesizedToolResults, 0)
        XCTAssertEqual(r.caveat, "resuming from a compaction summary")
    }),

    ("resume: only the active branch is replayed", {
        // A session file is every conversation the session ever had. Replaying an abandoned
        // branch would resurrect work the person deliberately backed out of.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"root"}]}}
        {"type":"message","id":"dead","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"abandoned branch"}]}}
        {"type":"message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"kept branch"}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.messages.map(\.plainText), ["root", "kept branch"])
    }),

    ("resume: an agent message replays as a user turn", {
        // A message *to* this agent is the user role on the wire, whoever sent it. This is how
        // a Workshop request that arrived mid-session survives a resume.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"message","id":"a1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
        {"type":"custom_message","id":"a2","parentId":"a1","timestamp":"2026-08-20T10:00:02.000Z","customType":"agent_message","content":[{"type":"text","text":"from ryan: also do Z"}]}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.messages.map(\.role), [.user, .user])
        XCTAssertEqual(r.messages[1].plainText, "from ryan: also do Z")
    }),

    ("resume: a session with nothing to replay is empty rather than a failure", {
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        let r = SessionResume.replay(t)
        XCTAssertTrue(r.isEmpty)
        XCTAssertNil(r.caveat)
    }),

    ("resume: the agent seeds history after its system prompt and never from it", {
        let history: [ChatMessage] = [
            .system("a stale prompt from the recorded run"),
            .user("earlier"),
            ChatMessage(role: .assistant, content: [.text("earlier reply")]),
        ]
        let spec: ModelSpec = ModelSpec(rpc: .object([
            "id": .string("m"), "provider": .string("p"), "name": .string("m"),
        ]))
        var config = Agent.Configuration(
            model: spec, cwd: "/tmp", systemPrompt: "the freshly built prompt")
        config.resumedHistory = history
        XCTAssertEqual(config.resumedHistory.count, 3)
        // The filter lives in Agent's init; assert the contract it enforces so a refactor
        // that drops it fails here rather than in a run that mysteriously ignores its skills.
        let seeded = [ChatMessage.system(config.systemPrompt)]
            + config.resumedHistory.filter { $0.role != .system }
        XCTAssertEqual(seeded.map(\.role), [.system, .user, .assistant])
        XCTAssertEqual(seeded[0].plainText, "the freshly built prompt")
    }),

    ("resume: a model switch is on the active branch and names its model", {
        // Two bugs that hid each other. An unparented `model_change` is not on the active
        // branch, so the row never rendered — which meant nobody noticed that the writer's
        // `model` key did not match the parser's `modelId` and every Aviary-written session
        // recorded an empty model.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","provider":"openai-codex","modelId":"gpt-5.6-terra"}
        {"type":"message","id":"a1","parentId":"m1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        XCTAssertEqual(t.modelChanges.count, 1)
        XCTAssertEqual(t.lastModel, "gpt-5.6-terra")
        XCTAssertEqual(t.lastProvider, "openai-codex")
        XCTAssertTrue(t.items.contains { $0.text == "Model → openai-codex/gpt-5.6-terra" })
        // A state change carries no model-visible content, so it is skipped, not replayed.
        let r = SessionResume.replay(t)
        XCTAssertEqual(r.messages.map(\.role), [.user])
        XCTAssertEqual(r.skippedEntries, 1)
        XCTAssertEqual(r.lastModel, "gpt-5.6-terra")
    }),

    ("resume: the legacy `model` key still renders", {
        // Sessions already on disk were written with `model`. They should not show blanks.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp/p"}
        {"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-20T10:00:01.000Z","provider":"p","model":"legacy-model"}
        {"type":"message","id":"a1","parentId":"m1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        """
        let t = try XCTUnwrap(SessionParser.parse(data: Data(jsonl.utf8), fallbackID: "s1"))
        XCTAssertEqual(t.lastModel, "legacy-model")
    }),

    // MARK: Markdown block structure
    //
    // The transcript rendered inline-only markdown, so every block construct arrived as its
    // own literal syntax. These pin the shape of what replaced it, and in particular the two
    // ways a block parser goes wrong on agent output: eating newlines it should keep, and
    // finding structure in prose that has none.

    ("markdown: a plain paragraph keeps its hard line breaks", {
        // The reason the old renderer used inlineOnlyPreservingWhitespace at all. If this
        // regresses, every multi-line answer in the transcript reflows into one blob.
        let blocks = MarkdownParser.blocks(from: "first line\nsecond line\nthird")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first, .paragraph("first line\nsecond line\nthird"))
    }),

    ("markdown: blank lines separate paragraphs and are not themselves blocks", {
        let blocks = MarkdownParser.blocks(from: "one\n\n\ntwo\n")
        XCTAssertEqual(blocks, [.paragraph("one"), .paragraph("two")])
    }),

    ("markdown: ATX headings need the space, so #hashtag stays prose", {
        XCTAssertEqual(
            MarkdownParser.blocks(from: "## Results"), [.heading(level: 2, text: "Results")])
        XCTAssertEqual(
            MarkdownParser.blocks(from: "###### deep"), [.heading(level: 6, text: "deep")])
        // Seven hashes is not a heading in CommonMark and is usually a divider in practice.
        XCTAssertEqual(
            MarkdownParser.blocks(from: "####### too deep"),
            [.paragraph("####### too deep")])
        XCTAssertEqual(
            MarkdownParser.blocks(from: "#hashtag"), [.paragraph("#hashtag")])
        // Closing hashes are decoration.
        XCTAssertEqual(
            MarkdownParser.blocks(from: "## Middle ##"), [.heading(level: 2, text: "Middle")])
    }),

    ("markdown: a heading interrupts the paragraph above it", {
        let blocks = MarkdownParser.blocks(from: "intro text\n## Section\nbody")
        XCTAssertEqual(
            blocks,
            [.paragraph("intro text"), .heading(level: 2, text: "Section"), .paragraph("body")])
    }),

    ("markdown: a fenced block is opaque and keeps its own indentation", {
        let source = """
        Here:

        ```python
        def f():
            # not a heading
            return "- not a list"
        ```

        done
        """
        let blocks = MarkdownParser.blocks(from: source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph("Here:"))
        guard case let .code(language, body) = blocks[1] else {
            XCTFail("expected a code block, got \(blocks[1])")
            return
        }
        XCTAssertEqual(language, "python")
        XCTAssertEqual(body, "def f():\n    # not a heading\n    return \"- not a list\"")
        XCTAssertEqual(blocks[2], .paragraph("done"))
    }),

    ("markdown: an unclosed fence runs to the end rather than swallowing everything", {
        // A truncated reply is the common cause. Showing the code beats showing nothing.
        let blocks = MarkdownParser.blocks(from: "```\nhalf a thing")
        XCTAssertEqual(blocks, [.code(language: nil, source: "half a thing")])
    }),

    ("markdown: a longer fence contains a shorter one", {
        // How a model shows fenced markdown at all.
        let blocks = MarkdownParser.blocks(from: "````md\n```\ninner\n```\n````")
        XCTAssertEqual(blocks, [.code(language: "md", source: "```\ninner\n```")])
    }),

    ("markdown: inline triple backticks do not open a block", {
        let blocks = MarkdownParser.blocks(from: "use ```code``` inline")
        XCTAssertEqual(blocks, [.paragraph("use ```code``` inline")])
    }),

    ("markdown: bullet lists carry markers, and dashes in prose do not start one", {
        guard case let .list(list) = MarkdownParser.blocks(from: "- one\n- two\n* three")[0]
        else { return XCTFail("expected a list") }
        XCTAssertFalse(list.ordered)
        XCTAssertEqual(list.items.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(list.items.map(\.depth), [0, 0, 0])
        // No space after the dash: prose, not a list.
        XCTAssertEqual(MarkdownParser.blocks(from: "-not a list"),
                       [.paragraph("-not a list")])
    }),

    ("markdown: ordered lists keep the literal marker so numbering survives", {
        // A list that starts at 3 is usually a continuation the model meant.
        guard case let .list(list) = MarkdownParser.blocks(from: "3. three\n4) four")[0]
        else { return XCTFail("expected a list") }
        XCTAssertTrue(list.ordered)
        XCTAssertEqual(list.items.map(\.marker), ["3.", "4)"])
    }),

    ("markdown: nesting depth follows the indent columns actually used", {
        // Models mix two- and four-space steps, sometimes in one reply, so depth is derived
        // from the order of columns seen rather than from an assumed step size.
        let source = "- a\n   - b\n      - c\n   - d\n- e"
        guard case let .list(list) = MarkdownParser.blocks(from: source)[0]
        else { return XCTFail("expected a list") }
        XCTAssertEqual(list.items.map(\.text), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(list.items.map(\.depth), [0, 1, 2, 1, 0])
    }),

    ("markdown: task list items carry their checkbox state", {
        guard case let .list(list) = MarkdownParser.blocks(from: "- [x] done\n- [ ] todo\n- plain")[0]
        else { return XCTFail("expected a list") }
        XCTAssertEqual(list.items.map(\.checked), [true, false, nil])
        XCTAssertEqual(list.items.map(\.text), ["done", "todo", "plain"])
    }),

    ("markdown: a wrapped list item keeps its continuation", {
        guard case let .list(list) = MarkdownParser.blocks(from: "- first\n  wrapped\n- second")[0]
        else { return XCTFail("expected a list") }
        XCTAssertEqual(list.items.map(\.text), ["first\nwrapped", "second"])
    }),

    ("markdown: a rule is a rule, and three dashes are not a one-item list", {
        XCTAssertEqual(MarkdownParser.blocks(from: "---"), [.rule])
        XCTAssertEqual(MarkdownParser.blocks(from: "***"), [.rule])
        XCTAssertEqual(MarkdownParser.blocks(from: "- - -"), [.rule])
        XCTAssertEqual(MarkdownParser.blocks(from: "--"), [.paragraph("--")])
    }),

    ("markdown: quotes nest their own blocks", {
        guard case let .quote(inner) = MarkdownParser.blocks(from: "> ## Q\n> - a\n> - b")[0]
        else { return XCTFail("expected a quote") }
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(inner[0], .heading(level: 2, text: "Q"))
        guard case let .list(list) = inner[1] else { return XCTFail("expected a nested list") }
        XCTAssertEqual(list.items.map(\.text), ["a", "b"])
    }),

    ("markdown: a table needs its delimiter row, so piped prose stays prose", {
        let source = "| name | count |\n| :--- | ----: |\n| a | 1 |\n| b | 2 |"
        guard case let .table(table) = MarkdownParser.blocks(from: source)[0]
        else { return XCTFail("expected a table") }
        XCTAssertEqual(table.header, ["name", "count"])
        XCTAssertEqual(table.alignments, [.leading, .trailing])
        XCTAssertEqual(table.rows, [["a", "1"], ["b", "2"]])
        // Prose containing a pipe is far more common in agent output than a table is.
        XCTAssertEqual(MarkdownParser.blocks(from: "run a | b to pipe"),
                       [.paragraph("run a | b to pipe")])
    }),

    ("markdown: a ragged table row is padded rather than rejected", {
        // A table with one short row is still a table; the alternative shows raw pipes.
        let source = "| a | b |\n| - | - |\n| only |\n| x | y | z |"
        guard case let .table(table) = MarkdownParser.blocks(from: source)[0]
        else { return XCTFail("expected a table") }
        XCTAssertEqual(table.rows, [["only", ""], ["x", "y"]])
    }),

    ("markdown: an escaped pipe stays inside its cell", {
        let source = "| pattern |\n| --- |\n| a \\| b |"
        guard case let .table(table) = MarkdownParser.blocks(from: source)[0]
        else { return XCTFail("expected a table") }
        XCTAssertEqual(table.rows, [["a | b"]])
    }),

]

let cases6: [Case] = [
    ("markdown: centre alignment is read from the delimiter", {
        guard case let .table(table) =
            MarkdownParser.blocks(from: "| a |\n| :-: |\n| x |")[0]
        else { return XCTFail("expected a table") }
        XCTAssertEqual(table.alignments, [.center])
    }),

    ("markdown: a realistic reply parses into the blocks it looks like", {
        let source = """
        Here is what I found.

        ## Causes

        1. The first one
        2. The second one

        > Worth noting.

        ```bash
        just shots
        ```

        | file | size |
        | --- | ---: |
        | a.png | 12K |

        Done.
        """
        let blocks = MarkdownParser.blocks(from: source)
        let kinds = blocks.map { block -> String in
            switch block {
            case .heading: return "heading"
            case .paragraph: return "paragraph"
            case .list: return "list"
            case .quote: return "quote"
            case .code: return "code"
            case .rule: return "rule"
            case .table: return "table"
            }
        }
        XCTAssertEqual(
            kinds,
            ["paragraph", "heading", "list", "quote", "code", "table", "paragraph"])
    }),

    ("markdown: text with no structure produces exactly one paragraph", {
        // The degradation path. Anything this parser cannot recognise must come out as the
        // old inline-only behaviour rather than disappearing.
        let odd = "a stray ] bracket, 50% of things, C:\\path, and an <html> tag"
        XCTAssertEqual(MarkdownParser.blocks(from: odd), [.paragraph(odd)])
        XCTAssertEqual(MarkdownParser.blocks(from: ""), [])
        XCTAssertEqual(MarkdownParser.blocks(from: "   \n  \n"), [])
    }),


    // MARK: Claude Code driving

    ("claude-code: a per-session shim is not mistaken for an install", {
        // A terminal multiplexer or IDE integration commonly puts a shim on PATH under
        // /var/folders. Resolving to one gives a path that works today and is gone tomorrow,
        // so `locate()` filters them and this is the predicate that does it.
        XCTAssertTrue(ClaudeCode.isEphemeral(
            "/var/folders/2r/673rpyjj/T/cmux-cli-shims/666DD599/claude"))
        XCTAssertTrue(ClaudeCode.isEphemeral("/private/var/folders/x/T/shim/claude"))
        XCTAssertTrue(ClaudeCode.isEphemeral("/tmp/claude"))
        XCTAssertFalse(ClaudeCode.isEphemeral("/opt/homebrew/bin/claude"))
        XCTAssertFalse(ClaudeCode.isEphemeral("/usr/local/bin/claude"))
        XCTAssertFalse(ClaudeCode.isEphemeral(
            NSString(string: "~/.claude/local/claude").expandingTildeInPath))
    }),

    ("claude-code: the environment scrub removes what outranks the subscription", {
        let base = [
            "ANTHROPIC_API_KEY": "sk-ant-leaked",
            "ANTHROPIC_AUTH_TOKEN": "t",
            "ANTHROPIC_BASE_URL": "http://elsewhere",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_SESSION_ID": "parent-session",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc.sock",
            "CLAUDE_CODE_OAUTH_TOKEN": "keep-me",
            "PATH": "/usr/bin",
            "HOME": "/Users/somebody",
        ]
        let env = ClaudeCode.scrubbedEnvironment(base: base)
        // The whole point: an API key silently outranks subscription OAuth, so a driven run
        // would bill metered credit while every visible sign said it worked.
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["CLAUDE_CODE_USE_BEDROCK"])
        // A parent Claude Code session's own state must not be inherited: Aviary is developed
        // from inside Claude Code, so these are routinely present.
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_SESSION_ID"])
        XCTAssertNil(env["CLAUDE_CODE_MESSAGING_SOCKET"])
        // Kept: it is the documented way to authenticate a headless subscription session, so
        // somebody who set one meant it.
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "keep-me")
        XCTAssertEqual(env["HOME"], "/Users/somebody")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        // An empty PATH gets a usable one rather than being left to fail obscurely.
        XCTAssertFalse(ClaudeCode.scrubbedEnvironment(base: ["PATH": ""])["PATH"]!.isEmpty)
        XCTAssertEqual(
            ClaudeCode.scrubbedEnvironment(base: [:], adding: ["X": "1"])["X"], "1")
    }),

    ("claude-code: the invocation carries the flags that make it cheap, and not --bare", {
        let invocation = ClaudeCode.Invocation(
            model: "sonnet", cwd: "/tmp", systemPrompt: "You are Aviary.",
            mcpServers: .object(["aviary": .object(["command": .string("/bin/x")])]),
            allowedTools: ["mcp__aviary__python", "mcp__aviary__other"],
            effort: "high", resume: "sid-1")
        let args = invocation.arguments
        func flag(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // These three together are the difference between 286 input tokens and 80–106k: the
        // developer's own CLAUDE.md, plugins, skills and MCP connectors being read in.
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(flag("--setting-sources"), "")
        XCTAssertTrue(args.contains("--disable-slash-commands"))
        XCTAssertEqual(flag("--tools"), "", "the built-in tool set must be emptied")
        // The documented mode for scripted runs is exactly the one that drops subscription
        // auth, which is the whole reason this session type exists.
        XCTAssertFalse(args.contains("--bare"))
        XCTAssertEqual(flag("--model"), "sonnet")
        XCTAssertEqual(flag("--system-prompt"), "You are Aviary.")
        XCTAssertEqual(flag("--output-format"), "stream-json")
        XCTAssertEqual(flag("--input-format"), "stream-json")
        XCTAssertTrue(args.contains("--include-partial-messages"),
                      "thinking text only arrives as deltas")
        XCTAssertEqual(flag("--effort"), "high")
        XCTAssertEqual(flag("--resume"), "sid-1")
        // Comma-joined, not space-separated: --allowedTools is variadic and would swallow
        // whatever came next.
        XCTAssertEqual(flag("--allowedTools"), "mcp__aviary__python,mcp__aviary__other")
        let config = try XCTUnwrap(flag("--mcp-config"))
        XCTAssertTrue(config.contains("mcpServers"))
        XCTAssertTrue(config.contains("aviary"))
        // No servers means no flag at all, rather than an empty object Claude Code has to
        // interpret.
        let bare = ClaudeCode.Invocation(model: "haiku", cwd: "/tmp", systemPrompt: "x")
        XCTAssertFalse(bare.arguments.contains("--mcp-config"))
        XCTAssertFalse(bare.arguments.contains("--allowedTools"))
    }),

    ("claude-code: the init frame decodes, and reports what the run actually got", {
        let line = """
            {"type":"system","subtype":"init","cwd":"/repo","session_id":"abc-123",\
            "tools":["mcp__aviary__python"],"mcp_servers":[{"name":"aviary","status":"connected"}],\
            "model":"claude-sonnet-5","apiKeySource":"none","claude_code_version":"2.1.234"}
            """.replacingOccurrences(of: "\\\n", with: "")
        guard case .initialized(let info) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(line.utf8))) else {
            XCTFail("expected an init frame"); return
        }
        XCTAssertEqual(info.sessionID, "abc-123")
        XCTAssertEqual(info.model, "claude-sonnet-5")
        XCTAssertEqual(info.apiKeySource, "none")
        XCTAssertEqual(info.version, "2.1.234")
        XCTAssertEqual(info.cwd, "/repo")
        XCTAssertEqual(info.mcpServers.first?.status, "connected")
        // A clean strip-down complains about nothing.
        XCTAssertNil(info.complaint(expecting: ["mcp__aviary__python"]))
    }),

    ("claude-code: init complains about a leaked key, a missing tool, and extra tools", {
        func frame(tools: [String], apiKeySource: String, servers: String = "[]")
            -> ClaudeCode.Frame.Init
        {
            let json = "{\"type\":\"system\",\"subtype\":\"init\",\"tools\":["
                + tools.map { "\"\($0)\"" }.joined(separator: ",")
                + "],\"mcp_servers\":\(servers),\"apiKeySource\":\"\(apiKeySource)\"}"
            guard case .initialized(let info) = ClaudeCode.decode(line: Data(json.utf8))! else {
                fatalError("not an init frame")
            }
            return info
        }
        // Checked against the run's own report rather than the flags passed, because a hook has
        // been observed firing even with --setting-sources "".
        let leaked = frame(tools: ["mcp__aviary__python"], apiKeySource: "ANTHROPIC_API_KEY")
        XCTAssertTrue(try XCTUnwrap(leaked.complaint(expecting: ["mcp__aviary__python"]))
            .contains("metered"))
        let missing = frame(tools: [], apiKeySource: "none")
        let complaint = try XCTUnwrap(missing.complaint(expecting: ["mcp__aviary__python"]))
        XCTAssertTrue(complaint.contains("mcp__aviary__python"))
        XCTAssertTrue(complaint.contains("No MCP server connected"))
        // A server that connected but offered nothing is a different diagnosis, so it says so.
        let noTools = frame(
            tools: [], apiKeySource: "none",
            servers: "[{\"name\":\"aviary\",\"status\":\"failed\"}]")
        XCTAssertTrue(try XCTUnwrap(noTools.complaint(expecting: ["mcp__aviary__python"]))
            .contains("aviary (failed)"))
        // Built-ins leaking back in is the other direction of the same failure.
        let extra = frame(tools: ["mcp__aviary__python", "Bash"], apiKeySource: "none")
        XCTAssertTrue(try XCTUnwrap(extra.complaint(expecting: ["mcp__aviary__python"]))
            .contains("Bash"))
    }),

    ("claude-code: assistant frames are per-block, so a turn needs assembling", {
        // Measured, not assumed: two frames share one message id and carry one block each.
        // Writing each as its own transcript entry would split one reply into three.
        let thinking = #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"weighing it up"}]}}"#
        let text = #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"the answer"}],"stop_reason":"end_turn"}}"#
        let call = #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"mcp__aviary__python","input":{"code":"1+1"}}]}}"#

        guard case .assistantBlock(let id1, let b1, _) =
            try XCTUnwrap(ClaudeCode.decode(line: Data(thinking.utf8))),
              case .thinking(let thought) = b1 else { XCTFail("thinking"); return }
        XCTAssertEqual(id1, "msg_1")
        XCTAssertEqual(thought, "weighing it up")

        guard case .assistantBlock(let id2, let b2, let stop) =
            try XCTUnwrap(ClaudeCode.decode(line: Data(text.utf8))),
              case .text(let body) = b2 else { XCTFail("text"); return }
        XCTAssertEqual(id2, id1, "the same message id across blocks is the whole problem")
        XCTAssertEqual(body, "the answer")
        XCTAssertEqual(stop, "end_turn")

        guard case .assistantBlock(_, let b3, _) =
            try XCTUnwrap(ClaudeCode.decode(line: Data(call.utf8))),
              case .toolCall(let callID, let name, let arguments) = b3 else {
            XCTFail("tool call"); return
        }
        XCTAssertEqual(callID, "toolu_9")
        XCTAssertEqual(name, "mcp__aviary__python")
        XCTAssertEqual(arguments["code"]?.stringValue, "1+1")
    }),

    ("claude-code: the finished token counts come from message_delta, not the block frames", {
        // The `assistant` frames carry the message_start snapshot, whose output_tokens is a
        // stub and which has no output_tokens_details at all. Captured from a live run: the two
        // message_deltas summed exactly to the result frame's 6840/137/61.
        let delta = #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":3345,"cache_creation_input_tokens":11,"cache_read_input_tokens":22,"output_tokens":97,"output_tokens_details":{"thinking_tokens":33}}}}"#
        guard case .messageDone(let usage, let stop) =
            try XCTUnwrap(ClaudeCode.decode(line: Data(delta.utf8))) else {
            XCTFail("expected messageDone"); return
        }
        let u = try XCTUnwrap(usage)
        XCTAssertEqual(u.input, 3345)
        XCTAssertEqual(u.output, 97)
        XCTAssertEqual(u.cacheWrite, 11)
        XCTAssertEqual(u.cacheRead, 22)
        XCTAssertEqual(u.reasoning, 33)
        // Cache-inclusive. Claude Code caches hard and Anthropic reports cached context
        // outside input_tokens, so summing input and output only would report 83 tokens for a
        // turn that really processed about four thousand.
        XCTAssertEqual(u.totalTokens, 3345 + 97 + 22 + 11)
        XCTAssertEqual(stop, "tool_use")
        // A route that says nothing about reasoning leaves it nil, which is not zero.
        let quiet = #"{"type":"stream_event","event":{"type":"message_delta","delta":{},"usage":{"input_tokens":5,"output_tokens":6}}}"#
        guard case .messageDone(let plain, _) =
            try XCTUnwrap(ClaudeCode.decode(line: Data(quiet.utf8))) else {
            XCTFail("expected messageDone"); return
        }
        XCTAssertNil(try XCTUnwrap(plain).reasoning)
        // Cost stays zero: a subscription run's tokens were never billed at list price, and
        // total_cost_usd in the stream is documented as a client-side estimate.
        XCTAssertEqual(try XCTUnwrap(plain).cost.total, 0)
    }),

    ("claude-code: text and thinking deltas both carry content", {
        let text = #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello"}}}"#
        guard case .textDelta(let t) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(text.utf8))) else { XCTFail("text"); return }
        XCTAssertEqual(t, "hello")
        // The research this was built on concluded thinking comes back empty in `-p`. That is
        // true of the *complete* block on some routes; the deltas carry the real text, which is
        // why --include-partial-messages is not optional here.
        let think = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me count"}}}"#
        guard case .thinkingDelta(let th) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(think.utf8))) else { XCTFail("thinking"); return }
        XCTAssertEqual(th, "let me count")
        // A half-parsed argument object, which is what a tool call's arguments look like on
        // the wire before the block completes.
        let partial = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"co"}}}"#
        guard case .toolArgumentsDelta(let p) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(partial.utf8))) else { XCTFail("args"); return }
        XCTAssertEqual(p, #"{"co"#)
    }),

    ("claude-code: a tool result is read back off the user frame", {
        // The call is executed on Aviary's side but the *result message* is composed on Claude
        // Code's, so this echo is the only place a driven run can see what its own tool
        // returned.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","is_error":false,"content":[{"type":"text","text":"4"}]}]}}"#
        guard case .toolResult(let id, let text, let isError) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(line.utf8))) else { XCTFail("tool result"); return }
        XCTAssertEqual(id, "toolu_9")
        XCTAssertEqual(text, "4")
        XCTAssertFalse(isError)
        let failed = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"boom"}]}]}}"#
        guard case .toolResult(_, _, let bad) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(failed.utf8))) else { XCTFail("error result"); return }
        XCTAssertTrue(bad)
    }),

    ("claude-code: the rate-limit frame says plan or extra usage", {
        // The single most important thing this session type can report, so it is a decoded
        // field rather than something inferred from a cost estimate.
        let plan = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787445000,"rateLimitType":"five_hour","isUsingOverage":false}}"#
        guard case .rateLimit(let limit) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(plan.utf8))) else { XCTFail("rate limit"); return }
        XCTAssertEqual(limit.type, "five_hour")
        XCTAssertFalse(limit.usingOverage)
        XCTAssertTrue(limit.summary.contains("plan usage"))
        XCTAssertEqual(limit.resetsAt, Date(timeIntervalSince1970: 1_787_445_000))
        let overage = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","isUsingOverage":true}}"#
        guard case .rateLimit(let over) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(overage.utf8))) else { XCTFail("overage"); return }
        XCTAssertTrue(over.usingOverage)
        XCTAssertTrue(over.summary.contains("extra usage"))
    }),

    ("claude-code: the result frame carries denials, and retries name auth trouble", {
        let line = #"{"type":"result","subtype":"success","session_id":"s1","is_error":false,"result":"done","num_turns":3,"duration_ms":1983,"permission_denials":[{"tool_name":"Bash"}],"usage":{"input_tokens":6840,"output_tokens":137,"output_tokens_details":{"thinking_tokens":61}}}"#
        guard case .result(let result) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(line.utf8))) else { XCTFail("result"); return }
        XCTAssertEqual(result.sessionID, "s1")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(result.turns, 3)
        XCTAssertEqual(result.durationMS, 1983)
        XCTAssertEqual(result.usage.input, 6840)
        XCTAssertEqual(result.usage.reasoning, 61)
        // A denial matters because Claude Code then answers *around* the refusal rather than
        // stopping, which reads like a working run that quietly did less.
        XCTAssertEqual(result.permissionDenials, ["Bash"])
        // Auth failure is machine-detectable mid-run rather than a mysterious stall.
        let retry = #"{"type":"system","subtype":"api_retry","error":{"category":"authentication_failed","message":"login expired"}}"#
        guard case .retry(let category, let detail) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(retry.utf8))) else { XCTFail("retry"); return }
        XCTAssertEqual(category, "authentication_failed")
        XCTAssertEqual(detail, "login expired")
        // A retry frame whose field names this version does not recognise still has to say
        // something usable, so the whole frame becomes the detail. A banner reading
        // "retrying: unknown" reports trouble while withholding the actionable part — which is
        // exactly what an earlier version did on a real run.
        let strange = #"{"type":"system","subtype":"api_retry","attempt":2,"delayMs":500}"#
        guard case .retry(let blank, let raw) = try XCTUnwrap(
            ClaudeCode.decode(line: Data(strange.utf8))) else { XCTFail("retry"); return }
        XCTAssertTrue(blank.isEmpty)
        XCTAssertTrue(raw.contains("attempt"))
        XCTAssertTrue(raw.contains("delayMs"))
    }),

    ("claude-code: frames this version does not model are named, not dropped", {
        // Counted rather than ignored, so a Claude Code release that starts saying something
        // new shows up as a number instead of as absence. These are the ones a real run emits.
        for (line, expected) in [
            (#"{"type":"system","subtype":"status","status":"requesting"}"#, "system/status"),
            (#"{"type":"stream_event","event":{"type":"message_stop"}}"#, "event/message_stop"),
            (#"{"type":"stream_event","event":{"type":"content_block_start","index":0}}"#,
             "event/content_block_start"),
            (#"{"type":"nonsense"}"#, "nonsense"),
        ] {
            guard case .other(let type) = try XCTUnwrap(
                ClaudeCode.decode(line: Data(line.utf8))) else {
                XCTFail("expected other for \(expected)"); continue
            }
            XCTAssertEqual(type, expected)
        }
        // Not JSON at all is nil rather than a protocol error: the CLI does occasionally write
        // unstructured text to stdout, and ending a run over that would be absurd.
        XCTAssertNil(ClaudeCode.decode(line: Data("Warning: something\n".utf8)))
    }),

    ("claude-code: MCP namespacing is stripped before anything is recorded", {
        // The mcp__<server>__ prefix is MCP's namespacing, not part of the tool. Leaving it in
        // would make a driven run's transcript disagree with an in-house one about the name of
        // the same tool.
        XCTAssertEqual(ClaudeCodeRun.display(tool: "mcp__aviary__python"), "python")
        XCTAssertEqual(ClaudeCodeRun.display(tool: "python"), "python")
        XCTAssertEqual(ClaudeCodeRun.display(tool: "mcp__srv__odd__name"), "odd__name")
        XCTAssertEqual(ClaudeCodeRun.display(tool: "mcp__broken"), "mcp__broken")
        // And the run offers exactly one tool, because the kernel can already do anything a
        // file-editing tool could.
        XCTAssertEqual(ClaudeCodeRun.toolNames, ["mcp__aviary__python"])
    }),

    ("claude-code: a driven run is recorded as its own provider, with no prices", {
        let spec = ClaudeCodeRun.modelSpec(for: "sonnet")
        // Not "anthropic": which client Anthropic sees is exactly what decides whether the
        // tokens came out of the plan or out of metered credit.
        XCTAssertEqual(spec.providerID, "claude-code")
        XCTAssertEqual(spec.id, "sonnet")
        XCTAssertEqual(spec.qualifiedID, "claude-code/sonnet")
        XCTAssertEqual(spec.contextWindow, 1_000_000)
        XCTAssertTrue(spec.reasoning)
        // No rates, so `sessionsWithoutPricing` keeps meaning "no rates published" rather than
        // "cost zero" — which is the true thing to say about a subscription run.
        XCTAssertNil(spec.costInput)
        XCTAssertNil(spec.costOutput)
        XCTAssertEqual(spec.priced(Usage()).cost.total, 0)
        XCTAssertEqual(ClaudeCodeRun.modelSpec(for: "haiku").contextWindow, 200_000)
        XCTAssertNil(ClaudeCodeRun.modelSpec(for: "some-future-model").contextWindow)
    }),

    ("claude-code: auth tells a subscription apart from a key", {
        var auth = ClaudeCode.Auth(
            loggedIn: true, method: "claude.ai", apiProvider: "firstParty",
            email: "x@y.com", organization: "Duckbill", subscription: "team")
        XCTAssertTrue(auth.isSubscription)
        XCTAssertEqual(auth.summary, "Team · Duckbill")
        // An API-key login is a working login that bills differently, which is the distinction
        // the whole session type turns on.
        auth.method = "apiKey"
        auth.subscription = nil
        XCTAssertFalse(auth.isSubscription)
        auth.loggedIn = false
        XCTAssertEqual(auth.summary, "Not signed in")
        XCTAssertFalse(auth.isSubscription)
    }),

    ("claude-code: the kernel is described identically to the in-house one, minus spawn", {
        // Two engines describing the same kernel differently would make a transcript's meaning
        // depend on which one wrote it, so this is an invariant worth pinning.
        // Same catalogue, same context, same words. A driven session is always a Claude
        // model, so it always has vision; an in-house run has it only if its model does, which
        // is a difference in the *run*, not in how the two engines describe one.
        let driven = ClaudeCodeKernel.description(cwd: "/repo", hasMemory: true)
        let inHouse = try XCTUnwrap(Agent.tools(
            cwd: "/repo", hasMemory: true, supportsImages: true).first).description
        XCTAssertEqual(driven, inHouse)
        // Without memory, both drop the same paragraph.
        XCTAssertEqual(
            ClaudeCodeKernel.description(cwd: "/repo", hasMemory: false),
            try XCTUnwrap(Agent.tools(
                cwd: "/repo", hasMemory: false, supportsImages: true).first).description)
        // And a text-only run differs by exactly one name, rather than by a paragraph of
        // prose somebody rewrote in one place and not the other.
        let textOnly = try XCTUnwrap(Agent.tools(cwd: "/repo", hasMemory: true).first).description
        XCTAssertFalse(textOnly.contains("attach_image("))
        XCTAssertTrue(driven.contains("attach_image("))
        XCTAssertFalse(driven.contains("spawn("), "a driven session has no runner to spawn with")
        XCTAssertTrue(driven.contains("remember("))
        XCTAssertTrue(driven.contains("/repo"))
    }),

    ("claude-code: the bridge serves an authenticated courier and refuses everybody else", {
        // A local integration test rather than a mock: the thing worth testing is that a token
        // is actually required, and a fake transport would test the mock instead.
        let bridge = KernelBridge()
        await bridge.offer([KernelBridge.Tool(
            name: "python",
            description: "Run Python.",
            schema: .object(["type": .string("object")])
        ) { arguments in
            let code = arguments["code"]?.stringValue ?? ""
            return code == "fail"
                ? KernelBridge.Result(text: "boom", isError: true)
                : KernelBridge.Result(text: "ran: " + code)
        }])
        let endpoint = try await bridge.start()
        defer { Task { await bridge.stop() } }
        XCTAssertTrue(endpoint.port > 0)
        XCTAssertEqual(endpoint.environment["AVIARY_BRIDGE_PORT"], String(endpoint.port))
        XCTAssertEqual(endpoint.environment["AVIARY_BRIDGE_TOKEN"]?.count, 48)

        // A wrong token gets nothing. This is the property that keeps a port running arbitrary
        // Python out of reach of every other process on the machine.
        let intruder = try BridgeTestClient(port: endpoint.port)
        XCTAssertNil(intruder.request(["op": .string("hello"), "token": .string("wrong")])?["ok"])
        // And an unauthenticated connection cannot skip straight to a call.
        let sneak = try BridgeTestClient(port: endpoint.port)
        XCTAssertNotNil(sneak.request([
            "op": .string("call"), "name": .string("python"),
            "arguments": .object(["code": .string("1")]),
        ])?["error"])

        let client = try BridgeTestClient(port: endpoint.port)
        XCTAssertEqual(
            client.request(["op": .string("hello"), "token": .string(endpoint.token)])?["ok"],
            .bool(true))
        let listed = try XCTUnwrap(
            client.request(["op": .string("tools")])?["tools"]?.arrayValue)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["name"]?.stringValue, "python")
        // `inputSchema`, which is the key MCP's tools/list uses — the courier forwards this
        // object verbatim, so the name has to be right here.
        XCTAssertNotNil(listed[0]["inputSchema"])

        let ran = try XCTUnwrap(client.request([
            "op": .string("call"), "name": .string("python"),
            "arguments": .object(["code": .string("2+2")]),
        ]))
        XCTAssertEqual(ran["text"]?.stringValue, "ran: 2+2")
        XCTAssertEqual(ran["isError"]?.boolValue, false)
        // A tool that fails is a result, not a transport error.
        let failed = try XCTUnwrap(client.request([
            "op": .string("call"), "name": .string("python"),
            "arguments": .object(["code": .string("fail")]),
        ]))
        XCTAssertEqual(failed["isError"]?.boolValue, true)
        // An unknown tool is answered rather than dropped, so the model reads a reason instead
        // of waiting out a timeout.
        let unknown = try XCTUnwrap(client.request([
            "op": .string("call"), "name": .string("nope"), "arguments": .object([:]),
        ]))
        XCTAssertEqual(unknown["isError"]?.boolValue, true)
        XCTAssertTrue(try XCTUnwrap(unknown["text"]?.stringValue).contains("No such tool"))

        // Two served calls; the unknown-tool attempt is counted separately, because "the model
        // called the kernel twice" and "the model asked for a tool that is not there" are
        // different diagnoses.
        XCTAssertEqual(await bridge.calls, 2)
        XCTAssertEqual(await bridge.unknownToolCalls, 1)
        XCTAssertEqual(await bridge.connections, 1)
        XCTAssertEqual(await bridge.rejectedConnections, 1)
    }),


    // MARK: Reloading after a workshop request

    ("reload: a request already done at launch is not a completion", {
        // The bug this prevents is the loud one: without a baseline, every request that was
        // finished before the window opened reads as fresh news and the app rebuilds itself
        // on every launch.
        let done = WorkshopRequest(
            id: "wr-1", createdAt: Date(), title: "Earlier work", body: "",
            kind: .change, status: .done, statusChangedAt: Date())
        let board = WorkshopBoard(requests: [done], logExists: true)

        let first = WorkshopReload.completion(board: board, lastSeen: [:])
        XCTAssertNil(first.completed, "seen for the first time is not a transition")
        XCTAssertEqual(first.lastSeen["wr-1"], .done)

        // And a later log write that merely mentions it still says nothing.
        let again = WorkshopReload.completion(board: board, lastSeen: first.lastSeen)
        XCTAssertNil(again.completed)
    }),

    ("reload: the transition into done is what fires a build", {
        var request = WorkshopRequest(
            id: "wr-2", createdAt: Date(), title: "Add a thing", body: "",
            kind: .change, status: .building, statusChangedAt: Date())
        var seen = WorkshopReload.completion(
            board: WorkshopBoard(requests: [request]), lastSeen: [:]).lastSeen
        XCTAssertEqual(seen["wr-2"], .building)

        request.status = .done
        let fired = WorkshopReload.completion(
            board: WorkshopBoard(requests: [request]), lastSeen: seen)
        XCTAssertEqual(fired.completed?.id, "wr-2")
        seen = fired.lastSeen

        // Not twice for the same finish.
        XCTAssertNil(WorkshopReload.completion(
            board: WorkshopBoard(requests: [request]), lastSeen: seen).completed)

        // Reopened and finished again is a genuine second completion: the agent revised its
        // work and there is a new binary to look at.
        request.status = .building
        seen = WorkshopReload.completion(
            board: WorkshopBoard(requests: [request]), lastSeen: seen).lastSeen
        request.status = .done
        XCTAssertEqual(WorkshopReload.completion(
            board: WorkshopBoard(requests: [request]), lastSeen: seen).completed?.id, "wr-2")

        // A request that ends `declined` is not a completion — nothing was built.
        var declined = request
        declined.id = "wr-3"
        declined.status = .declined
        XCTAssertNil(WorkshopReload.completion(
            board: WorkshopBoard(requests: [declined]),
            lastSeen: ["wr-3": .building]).completed)
    }),

    ("reload: the launch mode is read from the running image, not guessed", {
        // Rebuilding the *other* configuration would succeed and change nothing visible,
        // which is the most confusing outcome available.
        XCTAssertEqual(
            WorkshopReload.launchMode(
                executablePath: "/Users/r/aviary/build/Aviary.app/Contents/MacOS/Aviary",
                bundlePath: "/Users/r/aviary/build/Aviary.app", hasCheckout: true),
            .bundle(path: "/Users/r/aviary/build/Aviary.app"))
        XCTAssertEqual(
            WorkshopReload.launchMode(
                executablePath: "/Users/r/aviary/app/.build/debug/Aviary",
                bundlePath: "/Users/r/aviary/app/.build/debug", hasCheckout: true),
            .binary(path: "/Users/r/aviary/app/.build/debug/Aviary", release: false))
        XCTAssertEqual(
            WorkshopReload.launchMode(
                executablePath: "/Users/r/aviary/app/.build/release/Aviary",
                bundlePath: "/Users/r/aviary/app/.build/release", hasCheckout: true),
            .binary(path: "/Users/r/aviary/app/.build/release/Aviary", release: true))
        // Whole path components, not a substring: a checkout living under a directory called
        // `release` is still a debug build.
        XCTAssertEqual(
            WorkshopReload.launchMode(
                executablePath: "/Users/r/release/aviary/app/.build/debug/Aviary",
                bundlePath: "/x", hasCheckout: true),
            .binary(path: "/Users/r/release/aviary/app/.build/debug/Aviary", release: false))
        // No checkout, nothing to rebuild from, so the feature reports itself unavailable
        // rather than running a build that cannot work.
        XCTAssertNil(WorkshopReload.launchMode(
            executablePath: "/usr/local/bin/Aviary", bundlePath: "/usr/local/bin",
            hasCheckout: false))
    }),

    ("reload: each launch mode rebuilds itself the way it was built", {
        let root = URL(fileURLWithPath: "/repo")
        let bundle = WorkshopReload.buildCommand(
            for: .bundle(path: "/repo/build/Aviary.app"), repoRoot: root)
        // The whole bundle: the plist, icon and ad-hoc signature are part of what makes the
        // running app the app, so a fresh Mach-O in a stale bundle is not what `just build`
        // produces.
        XCTAssertEqual(bundle.executable, "/bin/bash")
        XCTAssertTrue(bundle.arguments.contains("/repo/scripts/bundle-app.sh"))
        XCTAssertTrue(bundle.arguments.contains("release"))

        let debug = WorkshopReload.buildCommand(
            for: .binary(path: "/repo/app/.build/debug/Aviary", release: false), repoRoot: root)
        XCTAssertEqual(debug.executable, "/usr/bin/swift")
        XCTAssertEqual(debug.arguments, ["build", "--product", "Aviary"])
        XCTAssertEqual(debug.cwd.path, "/repo/app")

        let release = WorkshopReload.buildCommand(
            for: .binary(path: "/repo/app/.build/release/Aviary", release: true), repoRoot: root)
        XCTAssertTrue(release.arguments.contains("-c"))
        XCTAssertTrue(release.arguments.contains("release"))

        // And the executable a rebuild is expected to replace.
        XCTAssertEqual(
            WorkshopReload.LaunchMode.bundle(path: "/repo/build/Aviary.app").executablePath,
            "/repo/build/Aviary.app/Contents/MacOS/Aviary")
        XCTAssertEqual(
            WorkshopReload.LaunchMode.binary(path: "/x/Aviary", release: false).executablePath,
            "/x/Aviary")
    }),

    ("reload: a failed build reports the first real errors, not the tail", {
        // The tail of a failed swift build is "error: emit-module command failed", which says
        // nothing about what is wrong — so showing the last lines shows the least useful ones.
        let output = """
            [3/6] Compiling Aviary AppModel.swift
            /repo/app/Sources/Aviary/AppModel.swift:12:9: error: cannot find 'nope' in scope
               |         `- error: cannot find 'nope' in scope
            /repo/app/Sources/Aviary/AppModel.swift:12:9: error: cannot find 'nope' in scope
            /repo/app/Sources/Aviary/RootView.swift:4:1: error: missing brace
            note: this is only a note
            error: emit-module command failed with exit code 1
            """
        let reported = WorkshopReload.firstErrors(in: output)
        // Explicit closure rather than `map(String.init)`: the initializer's overload set makes
        // the expression expensive enough to trip the type-checker's time limit as this file
        // grows, which fails as a compiler error in an unrelated test.
        let lines: [String] = reported.split(separator: "\n").map { String($0) }
        XCTAssertTrue(lines[0].contains("cannot find 'nope' in scope"))
        XCTAssertTrue(reported.contains("missing brace"))
        // One mistake repeats once per compilation its file takes part in, so duplicates are
        // collapsed or four lines of banner describe a single error.
        XCTAssertEqual(lines.filter { $0.contains("cannot find 'nope'") }.count, 1)
        XCTAssertEqual(WorkshopReload.firstErrors(in: output, limit: 1)
            .split(separator: "\n").count, 1)
        // Failing in a way this does not model still has to say something.
        let mystery = "linking failed\nld: framework not found\nexit 1"
        XCTAssertTrue(WorkshopReload.firstErrors(in: mystery).contains("ld: framework not found"))
    }),

    ("reload: an unchanged binary is not offered as something to relaunch into", {
        // A request that only touched docs, the agent's brief, or the board itself builds
        // cleanly and changes nothing. Offering a restart for that teaches you to ignore the
        // banner, which is how you miss the one that matters.
        XCTAssertFalse(WorkshopReload.binaryChanged(before: "100@5", after: "100@5"))
        XCTAssertTrue(WorkshopReload.binaryChanged(before: "100@5", after: "100@6"))
        XCTAssertTrue(WorkshopReload.binaryChanged(before: "100@5", after: "220@5"))
        // An unreadable stamp counts as changed: better a needless relaunch offered than a
        // real one withheld.
        XCTAssertTrue(WorkshopReload.binaryChanged(before: nil, after: "100@5"))
        XCTAssertTrue(WorkshopReload.binaryChanged(before: "100@5", after: nil))

        // And the stamp itself moves when a real file does.
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "aviary-reload-\(UUID().uuidString)")
        try Data("one".utf8).write(to: tmp)
        let before = WorkshopReload.stamp(ofFileAt: tmp.path)
        XCTAssertNotNil(before)
        try Data("substantially longer contents".utf8).write(to: tmp)
        XCTAssertTrue(WorkshopReload.binaryChanged(
            before: before, after: WorkshopReload.stamp(ofFileAt: tmp.path)))
        try? FileManager.default.removeItem(at: tmp)
        XCTAssertNil(WorkshopReload.stamp(ofFileAt: tmp.path))
    }),


    ("claude-code: it is a provider in the catalogue, reachable only when signed in", {
        // The point of it being here at all: "which model is answering" is the same question
        // for a driven run as for any other, and answering it somewhere else would mean two
        // model pickers that can disagree.
        let empty = ModelsConfig(
            providers: [], raw: .object([:]),
            fileURL: URL(fileURLWithPath: "/nonexistent/models.json"), exists: false)
        let signedOut = ModelCatalogBuilder.build(
            config: empty, auth: nil, credentialed: [], preferences: ModelPreferences())
        XCTAssertFalse(signedOut.reachable.contains { $0.id == "claude-code" })
        XCTAssertTrue(signedOut.unreachable.contains { $0.id == "claude-code" },
                      "configured-but-unusable is more useful to say than showing nothing")

        // Reachability comes from the caller, because the credential lives in the `claude`
        // binary's own keychain entry — not in auth.json, and not in a key expression.
        let signedIn = ModelCatalogBuilder.build(
            config: empty, auth: nil, credentialed: ["claude-code"],
            preferences: ModelPreferences())
        let provider = try XCTUnwrap(signedIn.reachable.first { $0.id == "claude-code" })
        XCTAssertTrue(provider.isBuiltIn)
        XCTAssertNil(provider.baseURL, "not an HTTP route")
        XCTAssertNil(provider.apiKeyExpression, "Aviary never sees the credential")
        XCTAssertEqual(provider.api, "claude-code-cli")
        XCTAssertTrue(provider.hasStoredAuth)
        XCTAssertEqual(provider.authKind, "claude.ai")

        let ids = provider.models.map(\.id).sorted()
        XCTAssertEqual(ids, ["haiku", "opus", "sonnet"], "Claude Code's own --model aliases")
        let sonnet = try XCTUnwrap(provider.models.first { $0.id == "sonnet" })
        XCTAssertEqual(sonnet.qualifiedID, "claude-code/sonnet")
        XCTAssertEqual(sonnet.contextWindow, 1_000_000)
        XCTAssertTrue(sonnet.reasoning)
        // No prices, so `sessionsWithoutPricing` keeps meaning "no rates published" rather
        // than "cost zero" — the true thing to say about a subscription run.
        XCTAssertNil(sonnet.costInput)
        XCTAssertEqual(sonnet.priced(Usage()).cost.total, 0)
    }),

    ("claude-code: its models order and disable like every other model", {
        // The whole reason it belongs in the catalogue rather than in a picker of its own.
        var preferences = ModelPreferences()
        let empty = ModelsConfig(
            providers: [], raw: .object([:]),
            fileURL: URL(fileURLWithPath: "/nonexistent/models.json"), exists: false)
        let catalog = ModelCatalogBuilder.build(
            config: empty, auth: nil, credentialed: ["claude-code"],
            preferences: preferences)
        let haiku = try XCTUnwrap(catalog.find("claude-code/haiku"))
        preferences.setEnabled(false, for: haiku)
        let narrowed = ModelCatalogBuilder.build(
            config: empty, auth: nil, credentialed: ["claude-code"],
            preferences: preferences)
        XCTAssertFalse(narrowed.enabled.contains { $0.qualifiedID == "claude-code/haiku" })
        XCTAssertEqual(narrowed.disabledCount, 1)
        // Disabling hides a model from pickers; it must not break reading back a session that
        // already used it.
        XCTAssertNotNil(narrowed.find("claude-code/haiku"))

        // And pinning works on it like anything else.
        preferences.pin([haiku])
        let reordered = ModelCatalogBuilder.build(
            config: empty, auth: nil, credentialed: ["claude-code"],
            preferences: preferences)
        XCTAssertEqual(reordered.models.first?.qualifiedID, "claude-code/haiku")
    }),


    ("in-house: every configured api maps to a client that exists", {
        // The Codex route is the one this pins. Its api is `openai-codex-responses`, and a
        // driver that falls through to the completions client posts to
        // `chatgpt.com/backend-api/chat/completions` and gets 404 {"detail":"Not Found"} —
        // which reads as a broken model rather than as an unhandled provider. That is exactly
        // what the GUI did while the CLI handled it correctly.
        func spec(_ api: String, baseURL: String? = "https://example.test/v1") -> ProviderSpec {
            ProviderSpec(
                id: "p-" + api, name: nil, baseURL: baseURL, api: api, apiKeyExpression: nil,
                authHeader: nil, headers: [:], models: [])
        }
        let model = ModelSpec(rpc: .object(["id": .string("m"), "provider": .string("p")]))
        let home = AgentHome(root: FileManager.default.temporaryDirectory
            .appending(path: "routing-\(UUID().uuidString)"))

        // Anthropic and the default both build a client from `baseUrl`.
        for api in ["anthropic-messages", "openai-completions", "some-new-vendor-api"] {
            let routed = await ChatProviderRouting.makeProvider(
                spec: spec(api), model: model, home: home, resolveSecret: { _ in "k" })
            guard case .success = routed else {
                XCTFail("no client for \(api)"); continue
            }
            XCTAssertTrue(ChatProviderRouting.needsBaseURL(api))
        }
        // Missing baseUrl is a real configuration error for those, reported up front rather
        // than as a malformed request later.
        let noURL = await ChatProviderRouting.makeProvider(
            spec: spec("openai-completions", baseURL: nil), model: model, home: home,
            resolveSecret: { _ in nil })
        guard case .failure(.noBaseURL) = noURL else {
            XCTFail("a missing baseUrl should be named as such"); return
        }

        // Codex carries its own endpoint, so a missing baseUrl must not stop it — and with no
        // stored OAuth it fails as "not signed in", never by falling through to the
        // completions client, which posts to chatgpt.com/backend-api/chat/completions and gets
        // 404 {"detail":"Not Found"}. That fall-through was the bug.
        XCTAssertFalse(ChatProviderRouting.needsBaseURL("openai-codex-responses"))
        let codex = await ChatProviderRouting.makeProvider(
            spec: spec("openai-codex-responses", baseURL: nil), model: model, home: home,
            resolveSecret: { _ in nil })
        guard case .failure(.notSignedIn(let who)) = codex else {
            XCTFail("Codex with no credentials must say so, not route elsewhere"); return
        }
        XCTAssertEqual(who, "p-openai-codex-responses")
    }),

    ("codex: the built-in model catalogue matches the harness's", {
        // Transcribed, not invented: a model id this client sends that no known harness sends
        // is an anomaly.
        let provider = BuiltInProviders.openAICodex()
        XCTAssertEqual(provider.id, "openai-codex")
        XCTAssertEqual(provider.api, "openai-codex-responses")
        XCTAssertEqual(provider.baseURL, "https://chatgpt.com/backend-api")
        XCTAssertTrue(provider.isBuiltIn)
        let ids = provider.models.map(\.id)
        for expected in ["gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4",
                         "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.3-codex-spark", "gpt-5.2-codex",
                         "gpt-5.2", "gpt-5.1", "gpt-5.1-codex-max", "gpt-5.1-codex-mini"] {
            XCTAssertTrue(ids.contains(expected), "missing \(expected)")
        }
        let terra = try XCTUnwrap(provider.models.first { $0.id == "gpt-5.6-terra" })
        XCTAssertEqual(terra.contextWindow, 272_000)
        XCTAssertEqual(terra.maxTokens, 128_000)
        XCTAssertEqual(terra.costInput, 2.5)
        XCTAssertEqual(terra.costCacheWrite, 3.125)
        XCTAssertTrue(terra.reasoning)
        // The null in this map is the load-bearing part.
        XCTAssertTrue(terra.thinkingLevelMap?["minimal"] == .some(nil))
        let spark = try XCTUnwrap(provider.models.first { $0.id == "gpt-5.3-codex-spark" })
        XCTAssertEqual(spark.contextWindow, 128_000, "the one model with a smaller window")
    }),
]

let casesBuiltins: [Case] = [

    ("builtins: everything in the namespace is in the sentence that makes it real", {
        // The bug this pins: `spawn()` was bound in the namespace and missing from the tool
        // description, and a real run spent twenty turns grepping the codebase for it. A
        // capability the model is not told about does not exist — so the description is
        // rendered from the same list the namespace is built from, and this asserts the two
        // cannot come apart.
        for (memory, spawn, vision) in [
            (false, false, false), (true, false, false), (false, true, false),
            (true, true, false), (true, true, true), (false, false, true),
        ] {
            let ctx = Builtins.Context(
                cwd: "/repo", hasMemory: memory, canSpawn: spawn, spawnBudget: 2,
                supportsImages: vision)
            let text = Builtins.description(ctx)
            for name in Builtins.names(ctx) {
                XCTAssertTrue(text.contains(name + "("), "\(name) is bound but undescribed")
            }
            for entry in Builtins.all(ctx) where !entry.isAvailable {
                XCTAssertFalse(
                    text.contains(entry.name + "("),
                    "\(entry.name) is described but not bound")
            }
        }
    }),

    ("builtins: the remaining sub-agent budget is a number the model can read", {
        // A budget the model cannot see is the worst kind of ceiling: silent, arbitrary, and
        // indistinguishable from success when it is hit.
        let two = Builtins.description(
            Builtins.Context(cwd: "/repo", canSpawn: true, spawnBudget: 2))
        XCTAssertTrue(two.contains("nest 2 more level(s)"))
        let none = Builtins.description(Builtins.Context(cwd: "/repo", canSpawn: false))
        XCTAssertFalse(none.contains("more level(s)"))
    }),

    ("builtins: both engines render the one catalogue rather than describing it twice", {
        let ctx = Builtins.Context(cwd: "/repo", hasMemory: true, supportsImages: true)
        XCTAssertEqual(ClaudeCodeKernel.description(cwd: "/repo", hasMemory: true),
                       Builtins.description(ctx))
        XCTAssertEqual(
            try XCTUnwrap(Agent.tools(
                cwd: "/repo", hasMemory: true, supportsImages: true).first).description,
            Builtins.description(ctx))
    }),

    ("skills: what a run gets is not what the Library found", {
        // The screen used to show one list of 22 and imply all of them were available. They
        // were not: every run path passes `enginePackageRoot: nil`, so the engine bundle's
        // own skills — which teach the harness's namespace, not Aviary's builtins — are
        // discovered for display only. Both sets are correct; showing their union was not.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "aviary-reach-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let project = dir.appending(path: "project", directoryHint: .isDirectory)
        let engine = dir.appending(path: "engine", directoryHint: .isDirectory)
        for path in ["project/.agents/skills/mine", "engine/skills/theirs"] {
            try fm.createDirectory(
                at: dir.appending(path: path, directoryHint: .isDirectory),
                withIntermediateDirectories: true)
        }
        try "---\nname: mine\n---\nUse sh().".write(
            to: dir.appending(path: "project/.agents/skills/mine/SKILL.md"),
            atomically: true, encoding: .utf8)
        try "---\nname: theirs\n---\nUse rlm_heartbeat.create().".write(
            to: dir.appending(path: "engine/skills/theirs/SKILL.md"),
            atomically: true, encoding: .utf8)

        let home = AgentHome(root: dir.appending(path: "home", directoryHint: .isDirectory))
        let settings = HarnessSettings.load(home: home)
        let shown = Library.discover(
            home: home, settings: settings, projectRoot: project, enginePackageRoot: engine,
            userHome: dir.appending(path: "nobody", directoryHint: .isDirectory))
        XCTAssertEqual(shown.skills.count, 2, "the Library sees both")
        XCTAssertEqual(shown.reachableSkills.map(\.name), ["mine"])
        XCTAssertEqual(shown.engineOnlySkills.map(\.name), ["theirs"])

        // What a run actually discovers — the three run paths all pass nil.
        let run = Library.discover(
            home: home, settings: settings, projectRoot: project, enginePackageRoot: nil,
            userHome: dir.appending(path: "nobody", directoryHint: .isDirectory))
        XCTAssertEqual(run.skills.map(\.name), ["mine"])
        XCTAssertTrue(run.engineOnlySkills.isEmpty,
                      "an Aviary run must never be told about the harness's namespace")
    }),

    ("builtins: the kernel binds every name the catalogue promises", {
        // The catalogue is Swift and the namespace is Python, so the invariant that made
        // `Builtins` worth writing — one list, no drift — stops at the language boundary
        // unless something checks across it. host.py keeps its own frozenset so `inspect` can
        // hide the host's helpers from the agent's own variables; a name in the catalogue and
        // missing there is a name the model is told about and never given.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AviarySelfTest
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
        let host = repo.appending(path: "runtime-hosts/python3/host.py")
        let source = try String(contentsOf: host, encoding: .utf8)
        let marker = "_AVIARY_INJECTED = frozenset({"
        let start = try XCTUnwrap(source.range(of: marker))
        let rest = source[start.upperBound...]
        let literal = String(rest[..<(try XCTUnwrap(rest.firstIndex(of: "}")))])
        let bound = Set(literal.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
        })
        for name in Builtins.names(.reference) {
            XCTAssertTrue(bound.contains(name),
                          "\(name) is described to the model but host.py never binds it")
        }
        // The reverse is allowed: `ask_app` is the general form the specific callbacks are
        // built from, deliberately unadvertised so the model does not guess at kinds.
        XCTAssertTrue(bound.contains("ask_app"))
    }),

    ("builtins: the catalogue says how each name is served, not just that it exists", {
        // The Library shows this, and it is the difference between a free call and one that
        // blocks the cell on a round trip through the app.
        let all = Builtins.all(.reference)
        let sh = try XCTUnwrap(all.first { $0.name == "sh" })
        XCTAssertEqual(sh.mechanism, .kernel)
        let remember = try XCTUnwrap(all.first { $0.name == "remember" })
        XCTAssertEqual(remember.mechanism, .callback)
        XCTAssertEqual(remember.requirement, .memory)
        // The reference context is the whole shelf, so nothing is filtered out of it.
        XCTAssertTrue(all.allSatisfy(\.isAvailable))
        XCTAssertTrue(all.allSatisfy { !$0.summary.isEmpty && !$0.signature.isEmpty })
    }),
]


// MARK: - Library usage, read back out of the trajectories

private func usageFixture() throws -> (dir: URL, transcripts: [URL]) {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "aviary-usage-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func cell(_ code: String, at: String) -> String {
        let escaped = code.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"type":"message","timestamp":"\#(at)","message":{"role":"assistant","#
            + #""content":[{"type":"toolCall","name":"python","id":"t1","#
            + #""arguments":{"code":"\#(escaped)"}}]}}"#
    }
    let one = dir.appending(path: "one.jsonl")
    try [
        #"{"type":"session","id":"one","timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}"#,
        cell("print(sh('ls'))", at: "2026-08-20T10:00:01.000Z"),
        cell("sh('git status')\nsh('git diff')", at: "2026-08-20T10:00:02.000Z"),
        #"{"type":"message","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"sh( is not a call here"}]}}"#,
        cell("open('skills/writer/SKILL.md').read()", at: "2026-08-21T09:00:00.000Z"),
    ].joined(separator: "\n").write(to: one, atomically: true, encoding: .utf8)

    let two = dir.appending(path: "two.jsonl")
    try [
        #"{"type":"session","id":"two","timestamp":"2026-08-21T10:00:00.000Z","cwd":"/tmp"}"#,
        cell("remember('a thing')", at: "2026-08-21T10:00:01.000Z"),
        "not json at all",
    ].joined(separator: "\n").write(to: two, atomically: true, encoding: .utf8)

    return (dir, [one, two])
}

let casesLibraryUsage: [Case] = [

    ("usage: a call site is a call, and a suffix collision is not", {
        // `foo.sh(` and `my_sh(` are somebody else's function. Getting this wrong inflates
        // every number on the screen, and an inflated number is worse than no number.
        XCTAssertEqual(LibraryUsage.callSites(of: "sh", in: "sh('a'); sh('b')"), 2)
        XCTAssertEqual(LibraryUsage.callSites(of: "sh", in: "proc.sh('a')"), 0)
        XCTAssertEqual(LibraryUsage.callSites(of: "sh", in: "my_sh('a')"), 0)
        XCTAssertEqual(LibraryUsage.callSites(of: "sh", in: "sh ('a')"), 1, "whitespace is fine")
        XCTAssertEqual(LibraryUsage.callSites(of: "sh", in: "shell('a')"), 0)
        XCTAssertEqual(LibraryUsage.callSites(of: "sh", in: "sh"), 0, "a name is not a call")
        // Documented upper bound: prose inside a string is indistinguishable from source.
        XCTAssertEqual(LibraryUsage.callSites(of: "sh", in: "x = 'call sh() first'"), 1)
    }),

    ("usage: counted per day, per cell, per session, from the transcripts themselves", {
        let fixture = try usageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let usage = LibraryUsage.scan(
            transcripts: fixture.transcripts, builtins: ["sh", "remember", "spawn"], skills: [])
        XCTAssertEqual(usage.transcriptsScanned, 2)
        XCTAssertEqual(usage.cellsScanned, 4)
        let sh = try XCTUnwrap(usage.builtin(named: "sh"))
        XCTAssertEqual(sh.calls, 3, "two in one cell, one in another")
        XCTAssertEqual(sh.cells, 2, "the assistant's prose is not a cell")
        XCTAssertEqual(sh.sessions, 1)
        XCTAssertEqual(sh.byDay.count, 1)
        let remember = try XCTUnwrap(usage.builtin(named: "remember"))
        XCTAssertEqual(remember.calls, 1)
        XCTAssertEqual(remember.sessions, 1, "a different transcript is a different session")
        let spawn = try XCTUnwrap(usage.builtin(named: "spawn"))
        XCTAssertFalse(spawn.wasEverUsed)
        XCTAssertNil(spawn.lastUsed)
        // A line that is not JSON ends that line, not the scan.
        XCTAssertNotNil(usage.lastActivity)
    }),

    ("usage: a skill is credited by its path, never by its name", {
        // Bundled skills are called `edit`, `goal`, `compact` — ordinary English words that
        // would match half the corpus if a bare name counted.
        let fixture = try usageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let writer = SkillEntry(
            name: "writer", description: "", url: URL(fileURLWithPath: "/x/skills/writer/SKILL.md"),
            sourceLabel: "test", precedence: 0, bodyLength: 0, hasPythonBacking: false,
            allowedTools: [])
        let ls = SkillEntry(
            name: "ls", description: "", url: URL(fileURLWithPath: "/x/skills/ls/SKILL.md"),
            sourceLabel: "test", precedence: 0, bodyLength: 0, hasPythonBacking: false,
            allowedTools: [])
        let usage = LibraryUsage.scan(
            transcripts: fixture.transcripts, builtins: ["sh"], skills: [writer, ls])
        XCTAssertEqual(usage.skill(named: "writer")?.calls, 1)
        XCTAssertEqual(usage.skill(named: "ls")?.calls, 0, "`sh('ls')` is not the `ls` skill")
    }),

    ("usage: the window is dense, because the gaps are the information", {
        // Three calls spread over a month look like a habit if only the busy days are drawn.
        var series = LibraryUsage.Series(name: "sh", calls: 2, cells: 2, sessions: 1)
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(DateComponents(
            calendar: calendar, year: 2026, month: 8, day: 20, hour: 12).date)
        let today = calendar.startOfDay(for: now)
        let earlier = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        series.byDay = [
            LibraryUsage.Day(day: earlier, count: 1), LibraryUsage.Day(day: today, count: 1),
        ]
        let days = series.days(last: 7, calendar: calendar, now: now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.count), [0, 0, 0, 1, 0, 0, 1])
        XCTAssertEqual(days.last?.day, today, "the window ends today, not at the last call")
    }),

    ("usage: skills are filed under the builtins they actually teach", {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "aviary-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ body: String) throws -> SkillEntry {
            let skillDir = dir.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let url = skillDir.appending(path: "SKILL.md")
            try body.write(to: url, atomically: true, encoding: .utf8)
            return SkillEntry(
                name: name, description: "", url: url, sourceLabel: "test", precedence: 0,
                bodyLength: body.count, hasPythonBacking: false, allowedTools: [])
        }
        let notes = try write("notes", "Call remember('x') when you learn something.")
        let foreign = try write("foreign", "Call rlm_heartbeat.create('x') from IPython.")
        let index = SkillBuiltinIndex.build(
            skills: [notes, foreign], builtins: ["sh", "remember", "recall"])
        XCTAssertEqual(index.skills(for: "remember"), ["notes"])
        XCTAssertTrue(index.skills(for: "sh").isEmpty)
        // The inverse of the undescribed-capability bug: a skill teaching names this runtime
        // never binds. Worth surfacing rather than hiding behind an empty list.
        XCTAssertEqual(index.unattached, ["foreign"])
    }),
]

let casesArtifact: [Case] = [

    ("artifact: a document lands in the session's own artifacts directory", {
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ArtifactStore(home: home, sessionID: "s-1")

        let written = try store.write(
            text: "# Findings\n\nThe cache key misses the parser.\n",
            title: "Cache findings", format: "md")
        XCTAssertEqual(written.id, "cache-findings")
        XCTAssertEqual(written.format, .markdown)
        XCTAssertEqual(
            written.url.deletingLastPathComponent().path,
            home.artifactDocuments(forSession: "s-1").path,
            "not the artifacts root, which already holds scheduled-jobs.json and sub-*/")
        XCTAssertEqual(
            try String(contentsOf: written.url, encoding: .utf8),
            "# Findings\n\nThe cache key misses the parser.\n")
        XCTAssertEqual(written.byteCount, 45)
    }),

    ("artifact: the same title twice is two documents, not one overwritten", {
        // The loss this prevents is total and silent: the second write would destroy a report
        // the run already paid to produce, and nothing anywhere would say so.
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ArtifactStore(home: home, sessionID: "s-1")

        let first = try store.write(text: "one", title: "Report", format: "md")
        let second = try store.write(text: "two", title: "Report", format: "md")
        XCTAssertNotEqual(first.url.path, second.url.path)
        XCTAssertEqual(first.id, "report")
        XCTAssertEqual(second.id, "report-2")
        XCTAssertEqual(try String(contentsOf: first.url, encoding: .utf8), "one")
        XCTAssertEqual(store.list().count, 2)

        // A title is model-written text: it may hold slashes, dots and leading hyphens, all of
        // which mean something to a filesystem.
        let awkward = try store.write(
            text: "x", title: "../../etc/passwd — v2.1", format: "txt")
        XCTAssertEqual(awkward.id, "etc-passwd-v2-1")
        XCTAssertEqual(
            awkward.url.deletingLastPathComponent().path, store.directory.path,
            "the slug cannot climb out of the directory")

        // An untitled document still gets a findable name, taken from its own first heading.
        let untitled = try store.write(
            text: "# Migration plan\n\nStep one.", title: nil, format: "md")
        XCTAssertEqual(untitled.title, "Migration plan")
        XCTAssertEqual(untitled.id, "migration-plan")
    }),

    ("artifact: a format nobody supports is an error the agent can read", {
        // The agent is blocked on a line of code, so a payload it can branch on beats an
        // exception that reaches it as a traceback with no list of what would have worked.
        guard let host = try makeHost(.reference) else { return }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "fake", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
            host: host, writer: writer, hostSession: "none",
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s"))
        await agent.setArtifacts(ArtifactStore(home: home, sessionID: writer.sessionID))

        let bad = await agent.serveCallback(kind: "artifact", payload: .object([
            "text": .string("body"), "title": .string("T"), "format": .string("pdf"),
        ]))
        let message = bad["error"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("pdf"), "names what was asked for")
        XCTAssertTrue(message.contains("'md'") && message.contains("'html'"),
                      "and what would have worked")
        XCTAssertNil(bad["path"])

        let empty = await agent.serveCallback(kind: "artifact", payload: .object([
            "text": .string("   \n"), "format": .string("md"),
        ]))
        XCTAssertTrue((empty["error"]?.stringValue ?? "").contains("text"))

        // 'markdown' for 'md' is the mistake that would otherwise lose a finished report.
        let alias = await agent.serveCallback(kind: "artifact", payload: .object([
            "text": .string("body"), "title": .string("Alias"),
            "format": .string("markdown"),
        ]))
        XCTAssertEqual(alias["format"]?.stringValue, "md")
        await writer.close()
    }),

    ("artifact: the in-house engine writes the file and records it in the transcript", {
        guard let host = try makeHost(.reference) else { return }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "fake", baseURL: URL(string: "http://127.0.0.1:1/v1")!, apiKey: nil),
            host: host, writer: writer, hostSession: "none",
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "s"))
        await agent.setArtifacts(ArtifactStore(home: home, sessionID: writer.sessionID))

        let reply = await agent.serveCallback(kind: "artifact", payload: .object([
            "text": .string("# Q3\n\nRevenue is up."),
            "title": .string("Q3 review"),
            "format": .string("md"),
        ]))
        XCTAssertNil(reply["error"])
        XCTAssertEqual(reply["id"]?.stringValue, "q3-review")
        XCTAssertEqual(reply["title"]?.stringValue, "Q3 review")
        XCTAssertEqual(reply["bytes"]?.intValue, 20)
        let path = try XCTUnwrap(reply["path"]?.stringValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await writer.close()

        // A file nobody can see is a dead end, so the transcript says one was made — and says
        // it in a form a reader that has never heard of an artifact still renders usefully.
        let transcript = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        let note = try XCTUnwrap(transcript.items.compactMap(\.artifact).last)
        XCTAssertEqual(note.title, "Q3 review")
        XCTAssertEqual(note.format, "md")
        XCTAssertEqual(note.byteCount, 20)
        XCTAssertEqual(note.path, path)
        let raw = try XCTUnwrap(transcript.items.last { $0.artifact != nil }).plainText
        XCTAssertTrue(raw.contains("Artifact: Q3 review") && raw.contains(path))
    }),

    ("artifact: a driven session writes it the same way an in-house one does", {
        // Both engines serve the same verbs against the same store. An artifact that landed
        // somewhere else depending on who was driving would make a session's output depend on
        // a choice the person who asked for the report never made.
        guard let host = try makeHost(.reference) else { return }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let sid = writer.sessionID
        let kernel = ClaudeCodeKernel(
            host: host, hostSession: "none", memory: nil,
            sessionFile: writer.fileURL, sessionID: sid,
            artifacts: ArtifactStore(home: home, sessionID: sid))
        let noted = OutputCollector()
        await kernel.onNote { text, customType in noted.record(stream: customType, text: text) }

        let reply = await kernel.serveCallback(kind: "artifact", payload: .object([
            "text": .string("<h1>Ledger</h1>"), "title": .string("Ledger"),
            "format": .string("html"),
        ]))
        XCTAssertEqual(reply["format"]?.stringValue, "html")
        let path = try XCTUnwrap(reply["path"]?.stringValue)
        XCTAssertEqual(
            path, home.artifactDocuments(forSession: sid).appending(path: "ledger.html").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(noted.streams, [ArtifactNote.customType])
        XCTAssertNotNil(ArtifactNote.parse(noted.text))
        await writer.close()
    }),

    ("artifact: the name bound in the interpreter reaches the store that writes it", {
        // The seam no Swift-only test can see: `artifact` is a lambda in host.py whose keyword
        // arguments have to match what the callback reads. A mismatch there compiles fine and
        // fails the first time an agent calls it.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let store = ArtifactStore(home: home, sessionID: "s-live")
        await host.onCallback { _, kind, payload in
            guard kind == "artifact" else {
                return .object(["error": .string("unexpected callback \(kind)")])
            }
            guard let written = try? store.write(
                text: payload["text"]?.stringValue ?? "",
                title: payload["title"]?.stringValue,
                format: payload["format"]?.stringValue ?? "md")
            else { return .object(["error": .string("the store refused it")]) }
            return written.payload
        }
        let session = try await host.createSession(cwd: "/tmp")
        defer { Task { await host.destroySessionQuietly(session) } }

        let result = try await host.execute(
            "artifact('# Live\\n\\nbody', title='Live run', format='md')['path']",
            in: session)
        XCTAssertNil(result.exception, result.exception ?? "")
        let path = (result.value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        XCTAssertEqual(
            path, home.artifactDocuments(forSession: "s-live")
                .appending(path: "live-run.md").path)
        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8), "# Live\n\nbody")

        // And it is hidden from `inspect`, like every other name the host injects — the
        // namespace is supposed to show what the agent put there, not what Aviary did.
        let namespace = try await host.inspect(session)
        XCTAssertFalse(namespace.bindings.contains { $0.name == "artifact" })
    }),

    ("artifact: both engines tell the model it exists, in every configuration", {
        // The rule this repo enforces structurally: a capability the model is not told about
        // does not exist. `artifact` is bound in every session, so it must be described in
        // every one — including the runs with no memory and no sub-agent depth.
        for (memory, spawn) in [(false, false), (true, false), (false, true), (true, true)] {
            let text = Builtins.description(Builtins.Context(
                cwd: "/repo", hasMemory: memory, canSpawn: spawn, spawnBudget: 1))
            XCTAssertTrue(text.contains("artifact(text, title=None, format='md')"))
            XCTAssertTrue(text.contains("'html'"), "the formats are named, not implied")
            XCTAssertTrue(text.contains("extended piece of writing"),
                          "and when to reach for it, which is the whole point of adding it")
        }
        XCTAssertTrue(
            ClaudeCodeKernel.description(cwd: "/repo", hasMemory: false).contains("artifact("))
        XCTAssertTrue(
            try XCTUnwrap(Agent.tools(cwd: "/repo").first).description.contains("artifact("))

        let entry = try XCTUnwrap(Builtins.all(.reference).first { $0.name == "artifact" })
        XCTAssertEqual(entry.requirement, .always)
        XCTAssertEqual(entry.mechanism, .callback,
                       "storage is the app's; the kernel does not know the session id")
    }),
]


/// A real encoded PNG of a given size — the point of these tests is the decode/scale path, so
/// a hand-written byte array would test nothing.
private func writePNG(width: Int, height: Int, to url: URL) throws {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
}

// MARK: - Looking at an image

let casesAttachImage: [Case] = [

    ("attach_image: a huge screenshot is scaled to something worth sending", {
        // Images bill by area. A retina screenshot is 3024x1964 before anything has happened,
        // and sending it untouched is several thousand tokens for a picture whose legible
        // content survives being halved.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "aviary-img-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appending(path: "screenshot.png")
        try writePNG(width: 3024, height: 1964, to: big)

        let image = try AttachedImage.read(path: big.path)
        XCTAssertEqual(max(image.width, image.height), AttachedImage.maxEdge)
        XCTAssertEqual(image.width, 1568)
        XCTAssertEqual(image.height, 1018, "the aspect ratio survives")
        XCTAssertNotNil(image.scaledFrom, "and the agent is told it was scaled")
        XCTAssertFalse(image.base64.isEmpty)

        // Small enough to send as-is is left alone: rescaling a diagram blurs the text on it.
        let small = dir.appending(path: "small.png")
        try writePNG(width: 320, height: 200, to: small)
        let untouched = try AttachedImage.read(path: small.path)
        XCTAssertEqual(untouched.width, 320)
        XCTAssertNil(untouched.scaledFrom)
    }),

    ("attach_image: a missing or undecodable file is an error the agent can act on", {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "aviary-img-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var missingSaid: String?
        do {
            _ = try AttachedImage.read(path: dir.appending(path: "nope.png").path)
        } catch { missingSaid = error.localizedDescription }
        XCTAssertTrue(missingSaid?.contains("No file at") == true,
                      "a path typo must read as a path typo")

        let notAnImage = dir.appending(path: "notes.txt")
        try "these are not pixels".write(to: notAnImage, atomically: true, encoding: .utf8)
        var undecodableSaid: String?
        do {
            _ = try AttachedImage.read(path: notAnImage.path)
        } catch { undecodableSaid = error.localizedDescription }
        // Names the formats rather than saying "unreadable": the usual causes are a wrong
        // path and a file that is not an image, and the fix differs.
        XCTAssertTrue(undecodableSaid?.contains("PNG") == true, undecodableSaid ?? "no error")
    }),

    ("attach_image: a text-only model is not offered it at all", {
        // The failure mode this avoids is a provider 400 the agent cannot read. A name that
        // is absent is a fact the model can work with; a name that exists and always fails
        // is not.
        let vision = Builtins.description(
            Builtins.Context(cwd: "/repo", supportsImages: true))
        XCTAssertTrue(vision.contains("attach_image("))
        let textOnly = Builtins.description(Builtins.Context(cwd: "/repo"))
        XCTAssertFalse(textOnly.contains("attach_image("))
        let entry = try XCTUnwrap(Builtins.all(.reference).first { $0.name == "attach_image" })
        XCTAssertEqual(entry.requirement, .vision)
        XCTAssertEqual(entry.mechanism, .callback)
    }),

    ("attach_image: the kernel carries the picture back inside the tool result", {
        // A driven session is the interesting case: Aviary owns no part of Claude Code's
        // message list, so the result of the call the model just made is the only channel
        // into its context.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "aviary-img-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "chart.png")
        try writePNG(width: 64, height: 48, to: file)
        let image = try AttachedImage.read(path: file.path)

        let result = KernelBridge.Result(text: "ran", images: [image])
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images.first?.mimeType, "image/png")
        XCTAssertFalse(result.isError)
        // The summary handed back to Python is what the cell prints, so it must be readable.
        let summary = image.summary
        XCTAssertEqual(summary["width"]?.doubleValue, 64)
        XCTAssertEqual(summary["height"]?.doubleValue, 48)
        XCTAssertNotNil(summary["path"]?.stringValue)
    }),

    ("attach_image: the transcript keeps the picture, not a note saying there was one", {
        // A session replayed tomorrow has to show what the agent was looking at, or the
        // reasoning that followed it is unreadable.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "aviary-img-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "shot.png")
        try writePNG(width: 32, height: 32, to: file)
        let image = try AttachedImage.read(path: file.path)

        let home = AgentHome(root: dir.appending(path: "home", directoryHint: .isDirectory))
        let writer = try SessionWriter(home: home, cwd: dir.path, model: nil)
        try await writer.appendImage(
            mimeType: image.mimeType, base64: image.base64, path: image.path,
            note: "the failing dialog")
        await writer.close()

        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        let images = parsed.items.flatMap { item -> [(String, String)] in
            item.blocks.compactMap {
                if case .image(let mime, let data) = $0 { return (mime, data) } else { return nil }
            }
        }
        XCTAssertEqual(images.count, 1, "the image is in the file, decodable")
        XCTAssertEqual(images.first?.0, "image/png")
        XCTAssertEqual(images.first?.1, image.base64)
    }),
]


// MARK: - MCP, both eras

private func mcpFixture(_ name: String) -> String? {
    guard let root = EngineLocator.repoRoot() else { return nil }
    let path = root.appending(path: "test-fixtures/\(name)").path
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

let casesMCPVersions: [Case] = [

    ("mcp: a modern server is served statelessly, and gets the metadata it demands", {
        // The fixture refuses any request without the per-request `_meta` the 2026-07-28
        // revision requires, so this passing is evidence the metadata actually crossed the
        // wire rather than that both sides agreed to skip it.
        guard let fixture = mcpFixture("mcp-modern.py") else {
            print("      skipped: no modern fixture"); return
        }
        let client = MCPClient(
            name: "modern", executable: "/usr/bin/env", arguments: ["python3", fixture])
        let tools = try await client.start(timeout: 20)
        let era = try XCTUnwrap(await client.era)
        XCTAssertTrue(era.isModern, "server/discover answered, so no handshake was needed")
        XCTAssertEqual(era.version, "2026-07-28")
        XCTAssertEqual(await client.serverInfo?.contains("modern-fixture"), true)
        XCTAssertEqual(tools.map(\.name).sorted(),
                       ["broken_shot", "needs_input", "shot", "whoami"])
        // The freshness hint is recorded rather than discarded.
        XCTAssertEqual(await client.toolsTTL, 60)

        let who = try await client.callTool("whoami", arguments: .object([:]))
        XCTAssertEqual(who.text, "2026-07-28 aviary",
                       "the server saw our version and our identity on the call itself")
        await client.stop()
    }),

    ("mcp: an interim result is not mistaken for an answer", {
        // resultType "input_required" means the server wants sampling or elicitation back.
        // Aviary declares no such capabilities, so the honest outcome is a readable error —
        // treating the interim result as complete would hand the agent an empty answer and
        // let it carry on as though the call had worked.
        guard let fixture = mcpFixture("mcp-modern.py") else {
            print("      skipped: no modern fixture"); return
        }
        let client = MCPClient(
            name: "modern", executable: "/usr/bin/env", arguments: ["python3", fixture])
        _ = try await client.start(timeout: 20)
        var said: String?
        do {
            _ = try await client.callTool("needs_input", arguments: .object([:]))
            XCTFail("an input_required result must not read as a completed call")
        } catch { said = error.localizedDescription }
        XCTAssertTrue(said?.contains("sampling/createMessage") == true, said ?? "no error")
        await client.stop()
    }),

    ("mcp: a handshake-era server still works, and is detected as one", {
        // The echo fixture answers *any* unknown method with an empty object rather than
        // -32601 — which is exactly the trap: a probe that took that for a DiscoverResult
        // would go stateless against a server that ignores _meta entirely.
        guard let fixture = mcpFixture("mcp-echo.py") else {
            print("      skipped: no echo fixture"); return
        }
        let client = MCPClient(
            name: "echo", executable: "/usr/bin/env", arguments: ["python3", fixture])
        let tools = try await client.start(timeout: 20)
        let era = try XCTUnwrap(await client.era)
        XCTAssertFalse(era.isModern, "an empty reply is not a DiscoverResult")
        XCTAssertEqual(era.version, "2024-11-05", "the version the server itself named")
        XCTAssertEqual(tools.map(\.name).sorted(), ["echo", "explode"])
        let ok = try await client.callTool("echo", arguments: .object(["text": .string("hi")]))
        XCTAssertEqual(ok.text, "hi")
        await client.stop()
    }),

    ("mcp: a tool that answers with a picture answers with the picture", {
        // "[image content]" in a transcript is a description of an answer nobody can see. The
        // fixture returns a 2400x1200 PNG it generates itself, so this also exercises the
        // client doing something about a size that is somebody else's choice.
        guard let fixture = mcpFixture("mcp-modern.py") else {
            print("      skipped: no modern fixture"); return
        }
        let client = MCPClient(
            name: "modern", executable: "/usr/bin/env", arguments: ["python3", fixture])
        _ = try await client.start(timeout: 20)

        let shot = try await client.callTool("shot", arguments: .object([:]))
        XCTAssertEqual(shot.text, "here is the screen", "text and image are separate")
        XCTAssertEqual(shot.images.count, 1)
        let image = try XCTUnwrap(shot.images.first)
        XCTAssertEqual(max(image.width, image.height), AttachedImage.maxEdge,
                       "scaled on the way in, like any other image")
        XCTAssertNotNil(image.scaledFrom)
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertTrue(image.path.contains("shot"), "labelled by where it came from")
        XCTAssertTrue(shot.skipped.isEmpty)

        // An image that will not decode is named, not dropped: a tool whose whole answer was
        // a picture has answered nothing, and an empty result reads as "no findings".
        let broken = try await client.callTool("broken_shot", arguments: .object([:]))
        XCTAssertTrue(broken.images.isEmpty)
        XCTAssertEqual(broken.skipped, ["undecodable image (image/png)"])
        XCTAssertTrue(broken.text.contains("undecodable"),
                      "and it reaches the agent, rather than reading as an empty answer")
        await client.stop()
    }),

    ("mcp: the picture reaches the model, not a sentence about a picture", {
        // The end-to-end claim, asserted against what actually went on the wire. Everything
        // up to here proves the client decoded an image; only the outgoing request proves the
        // model was shown one.
        guard let fixture = mcpFixture("mcp-modern.py") else {
            print("      skipped: no modern fixture"); return
        }
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "mcp__modern__shot", "arguments": [:]]],
            ["text": "I can see it."],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        var visionModel = fakeModel()
        visionModel.inputModalities = ["text", "image"]
        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: visionModel)
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "fake", baseURL: server.baseURL, apiKey: "test-key"),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: visionModel, cwd: "/tmp", systemPrompt: "be brief"))

        let client = MCPClient(
            name: "modern", executable: "/usr/bin/env", arguments: ["python3", fixture])
        let tools = try await client.start(timeout: 20)
        await agent.addMCPTools(tools, from: client)
        await agent.send("show me the screen")
        await client.stop()

        let sent = try server.recordedRequests()
        XCTAssertEqual(sent.count, 2)
        let messages = try XCTUnwrap(sent.last?["messages"]?.arrayValue)
        // The image rides as its own user message after the tool result — the one shape all
        // three provider wire formats accept.
        let imageParts = messages.flatMap { message -> [JSONValue] in
            (message["content"]?.arrayValue ?? []).filter {
                $0["type"]?.stringValue == "image_url"
            }
        }
        XCTAssertEqual(imageParts.count, 1, "exactly one picture reached the model")
        let url = try XCTUnwrap(imageParts.first?["image_url"]?["url"]?.stringValue)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"), String(url.prefix(40)))
        XCTAssertTrue(url.count > 1000, "and it is the image, not a placeholder")
        // The tool result itself still says what happened, so the text alone is coherent.
        let toolText = messages.compactMap { $0["content"]?.stringValue }
            .first { $0.contains("here is the screen") }
        XCTAssertTrue(toolText?.contains("1 image attached below") == true, toolText ?? "none")
    }),

    ("mcp: a model that cannot see is told so rather than shown nothing", {
        // The failure this prevents is quiet: an agent that believes it was shown a screenshot
        // will answer confidently about a picture it never received.
        guard let fixture = mcpFixture("mcp-modern.py") else {
            print("      skipped: no modern fixture"); return
        }
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "mcp__modern__shot", "arguments": [:]]],
            ["text": "I cannot see it."],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        // fakeModel() declares no input modalities, so it cannot read images.
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "fake", baseURL: server.baseURL, apiKey: "test-key"),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "be brief"))
        let client = MCPClient(
            name: "modern", executable: "/usr/bin/env", arguments: ["python3", fixture])
        await agent.addMCPTools(try await client.start(timeout: 20), from: client)
        await agent.send("show me the screen")
        await client.stop()

        let messages = try XCTUnwrap(
            try server.recordedRequests().last?["messages"]?.arrayValue)
        let imageParts = messages.flatMap { message in
            (message["content"]?.arrayValue ?? []).filter {
                $0["type"]?.stringValue == "image_url"
            }
        }
        XCTAssertTrue(imageParts.isEmpty, "no image is sent to a model that would reject it")
        let toolText = messages.compactMap { $0["content"]?.stringValue }
            .first { $0.contains("here is the screen") }
        XCTAssertTrue(toolText?.contains("cannot read") == true, toolText ?? "none")
    }),

    ("mcp: the bridge answers both eras, because its client is not ours to choose", {
        // Claude Code is on the other end of this one. Bumping the bridge to modern-only
        // would have broken the driven engine on whatever version Claude Code happens to
        // speak, so it serves whichever opening arrives.
        let discover = MCPBridge.complete([
            "supportedVersions": .array(
                ([MCPBridge.modernVersion] + MCPBridge.legacyVersions).map { .string($0) }),
        ])
        XCTAssertEqual(discover["resultType"]?.stringValue, "complete")
        XCTAssertEqual(
            discover["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.stringValue,
            "aviary-kernel")
        let versions = (discover["supportedVersions"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertTrue(versions.contains("2026-07-28"))
        XCTAssertTrue(versions.contains("2024-11-05"), "and the era Claude Code may still use")
    }),

    ("mcp: configured servers are what a run actually gets", {
        // The config reader predates any caller. This pins the shape it reads, since a typo
        // here is a server that silently never starts.
        let config = try XCTUnwrap(JSONValue.parse(Data("""
            {"mcpServers": {
              "linear": {"command": "npx", "args": ["-y", "linear-mcp"], "env": {"K": "v"}},
              "off": {"command": "x", "disabled": true},
              "remote": {"type": "http", "url": "https://example.com"}
            }}
            """.utf8)))
        let servers = MCPConfiguration.parse(config)
        XCTAssertEqual(servers.map(\.name), ["linear", "off", "remote"].filter { $0 != "remote" },
                       "a transport this client cannot speak is skipped, not half-started")
        let linear = try XCTUnwrap(servers.first { $0.name == "linear" })
        XCTAssertEqual(linear.arguments, ["-y", "linear-mcp"])
        XCTAssertEqual(linear.environment["K"], "v")
        XCTAssertTrue(linear.enabled)
        XCTAssertFalse(try XCTUnwrap(servers.first { $0.name == "off" }).enabled)
    }),
]


// MARK: - Changing a run's model

let casesDispatched: [Case] = [

    ("dispatch: a run does not finish on a promise it asked to be told about", {
        // The third mode, end to end: start something slow, stop waiting, be told later. The
        // first live run of this ended two seconds before its own shell command answered,
        // which is what the hold exists to prevent.
        guard let server = try FakeProviderServer(script: [
            ["tool": ["name": "python", "arguments": [
                "code": "sh('sleep 1; echo LATE').notify()"]]],
            ["text": "started"],
            ["text": "the task finished"],
        ]) else { print("      skipped: no fixture"); return }
        defer { server.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        var config = Agent.Configuration(
            model: fakeModel(), cwd: "/tmp", systemPrompt: "be brief")
        config.dispatchedWorkTimeout = 30
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "fake", baseURL: server.baseURL, apiKey: "k"),
            host: host, writer: writer, hostSession: hostSession, config: config)
        // The channel the prelude's `.notify()` speaks over. Without it the announcement never
        // reaches the agent and the run finishes exactly as it did before the fix — which is
        // how the first version of this test silently passed nothing.
        await host.onCallback { _, kind, payload in
            await agent.serveCallback(kind: kind, payload: payload)
        }

        let log = EventLog()
        await agent.observe { log.record($0) }
        await agent.send("dispatch something slow")

        // It held rather than finishing, and the third model call only happened because the
        // notification came back and reopened the turn.
        XCTAssertTrue(log.names.contains("awaitingDispatched"),
                      "the run must announce that it is holding: \(log.names)")
        // Three, not four: the hold happens before the follow-up is taken, so the run does
        // not spend a model call re-asking an unchanged conversation on the way to noticing
        // the message waiting for it.
        XCTAssertEqual(try server.recordedRequests().count, 3,
                       "a third call means the result was delivered and answered")
        XCTAssertEqual(
            log.names,
            ["started", "inputCommitted", "turn", "tool:python", "tool-ok", "turn", "awaitingDispatched",
             "steered", "turn", "finished:stop"])

        // And it arrived in the conversation as a message, carrying the command's output.
        await writer.close()
        let parsed = try XCTUnwrap(SessionParser.parse(fileURL: writer.fileURL))
        let delivered = parsed.items.contains { $0.plainText.contains("LATE") }
        XCTAssertTrue(delivered, "the shell output should be in the transcript")
    }),

    ("dispatch: nothing dispatched, nothing to wait for", {
        // The hold must not turn every ordinary run into one that pauses at the end.
        guard let server = try FakeProviderServer(script: [
            ["text": "done immediately"],
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
            provider: OpenAICompletionsProvider(
                id: "fake", baseURL: server.baseURL, apiKey: "k"),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "be brief"))
        let log = EventLog()
        await agent.observe { log.record($0) }
        let started = Date()
        await agent.send("just answer")
        XCTAssertFalse(log.names.contains("awaitingDispatched"))
        XCTAssertTrue(Date().timeIntervalSince(started) < 10, "it must not pause at the end")
    }),
]


/// Counts and keeps what crossed into the conversation. Callbacks arrive on their own threads.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func record(_ text: String) {
        lock.lock(); seen.append(text); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}

let casesCrossingLaws: [Case] = [

    ("crossing: notify is idempotent, so one event is one model call", {
        // Two deliveries for one event is two model calls, which is the expensive kind of
        // duplicate. Driven through the real prelude rather than asserted about the source.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let counter = Counter()
        await host.onCallback { _, kind, payload in
            if kind == "notify" {
                counter.record(payload["text"]?.stringValue ?? "")
            }
            return .object(["ok": .bool(true)])
        }
        let s = try await host.createSession(cwd: "/tmp")
        _ = try await host.execute(
            "job = sh('echo hi')\njob.result()\njob.notify()\njob.notify()\njob.notify()",
            in: s)
        // Give the delivery threads a moment; they are not daemons and resolve promptly.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(counter.count, 1, "three notify() calls, one delivery")
        // A label given later still lands, because updating it is not the same as re-arming.
        XCTAssertTrue(counter.texts.first?.contains("hi") == true, counter.texts.first ?? "none")
    }),

    ("crossing: nothing unbounded enters a conversation", {
        // sh('cat big').notify() used to put the whole file into the transcript, permanently,
        // re-sent as context on every later turn.
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }
        let counter = Counter()
        await host.onCallback { _, kind, payload in
            if kind == "notify" { counter.record(payload["text"]?.stringValue ?? "") }
            return .object(["ok": .bool(true)])
        }
        let s = try await host.createSession(cwd: "/tmp")
        _ = try await host.execute(
            "job = sh('python3 -c \"print(chr(120) * 200000)\"')\n"
                + "job.result()\njob.notify()", in: s)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(counter.count, 1)
        let delivered = try XCTUnwrap(counter.texts.first)
        XCTAssertTrue(delivered.count < 2_500,
                      "200k characters must not cross: got \(delivered.count)")
        XCTAssertTrue(delivered.contains("truncated"), "and it must say so")
        XCTAssertTrue(delivered.contains(".result()"),
                      "and say where the whole value still is")
    }),

    ("crossing: the boundary enforces the bound whatever calls it", {
        // The prelude's limit keeps a megabyte off the callback channel. This one is what
        // makes the guarantee true for any caller, including a future one.
        let small = "already short"
        XCTAssertEqual(Agent.bounded(small), small)
        let big = String(repeating: "x", count: Agent.notifyLimit * 3)
        let cut = Agent.bounded(big)
        XCTAssertTrue(cut.count < Agent.notifyLimit + 120)
        XCTAssertTrue(cut.contains("\(big.count) characters in total"))
    }),
]

let casesWebSearch: [Case] = [

    ("web: the request uses the field names Parallel documents, nesting and all", {
        // The expensive failure mode is a misspelled key: Parallel accepts the request,
        // ignores the field, and the only symptom is slightly worse results. So the body is a
        // pure function and the names are pinned here rather than discovered live.
        let body = WebSearch.searchBody(
            objective: "when was the UN founded", queries: ["UN founding date"],
            mode: "fast", maxResults: 5, maxCharsPerResult: 1200,
            includeDomains: ["un.org"], excludeDomains: ["example.com"],
            afterDate: "2020-01-01")
        XCTAssertEqual(body["objective"]?.stringValue, "when was the UN founded")
        XCTAssertEqual(body["mode"]?.stringValue, "fast")
        XCTAssertEqual(body["search_queries"]?.arrayValue?.count, 1)
        // Optional settings are nested under advanced_settings, which is their shape not ours.
        XCTAssertEqual(body.path("advanced_settings.max_results")?.intValue, 5)
        XCTAssertEqual(
            body.path("advanced_settings.excerpt_settings.max_chars_per_result")?.intValue,
            1200)
        XCTAssertEqual(
            body.path("advanced_settings.source_policy.after_date")?.stringValue, "2020-01-01")
        XCTAssertEqual(
            body.path("advanced_settings.source_policy.include_domains")?.arrayValue?.count, 1)

        // Nothing optional given, nothing sent — an empty advanced_settings would be noise.
        let bare = WebSearch.searchBody(
            objective: "x", queries: ["x"], mode: "fast", maxResults: nil,
            maxCharsPerResult: nil, includeDomains: [], excludeDomains: [], afterDate: nil)
        XCTAssertNil(bare["advanced_settings"])

        // An unknown mode falls back rather than being sent through to be rejected.
        let odd = WebSearch.searchBody(
            objective: "x", queries: ["x"], mode: "ludicrous", maxResults: nil,
            maxCharsPerResult: nil, includeDomains: [], excludeDomains: [], afterDate: nil)
        XCTAssertEqual(odd["mode"]?.stringValue, "fast")
    }),

    ("web: a page read asks for excerpts unless the whole thing is wanted", {
        let focused = WebSearch.extractBody(
            urls: ["https://example.com/a"], objective: "the pricing", queries: [], full: false)
        XCTAssertEqual(focused["urls"]?.arrayValue?.count, 1)
        XCTAssertEqual(focused["full_content"]?.boolValue, false)
        XCTAssertEqual(focused["objective"]?.stringValue, "the pricing")
        XCTAssertNil(focused["search_queries"], "not sent when there are none")

        let whole = WebSearch.extractBody(
            urls: ["a", "b"], objective: nil, queries: ["price"], full: true)
        XCTAssertEqual(whole["full_content"]?.boolValue, true)
        XCTAssertEqual(whole["search_queries"]?.arrayValue?.count, 1)
        XCTAssertNil(whole["objective"])
    }),

    ("web: replies are flattened to what an agent can act on", {
        // Parallel's bookkeeping — search_id, session_id, usage — is not forwarded. Spending
        // the agent's context on somebody else's telemetry buys nothing.
        let reply = try XCTUnwrap(JSONValue.parse(Data("""
            {"search_id": "s1", "session_id": "x", "usage": [{"name": "sku_search", "count": 1}],
             "results": [{"url": "https://un.org/history", "title": "History",
                          "publish_date": "1945-10-24", "excerpts": ["founded in 1945"]}]}
            """.utf8)))
        let flat = WebSearch.searchPayload(reply)
        let rows = try XCTUnwrap(flat.arrayValue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["url"]?.stringValue, "https://un.org/history")
        XCTAssertEqual(rows[0]["excerpts"]?.arrayValue?.count, 1)
        XCTAssertEqual(rows[0]["published"]?.stringValue, "1945-10-24")
        XCTAssertNil(rows[0]["search_id"])

        // A URL that failed is reported in the list. A silently shorter list reads as "that
        // page had nothing", which is a different fact from "that page could not be read".
        let extracted = try XCTUnwrap(JSONValue.parse(Data("""
            {"extract_id": "e1",
             "results": [{"url": "https://a", "title": "A", "excerpts": ["x"],
                          "full_content": "# A"}],
             "errors": [{"url": "https://b", "message": "timed out"}]}
            """.utf8)))
        let out = try XCTUnwrap(WebSearch.extractPayload(extracted).arrayValue)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0]["content"]?.stringValue, "# A")
        XCTAssertEqual(out[1]["url"]?.stringValue, "https://b")
        XCTAssertEqual(out[1]["error"]?.stringValue, "timed out")
    }),

    ("web: no key, no names", {
        // The alternative is a capability that exists right up until it is called.
        XCTAssertNil(WebSearch.configuredKey(environment: [:]))
        XCTAssertNil(WebSearch.configuredKey(environment: ["PARALLEL_API_KEY": "   "]))
        XCTAssertEqual(WebSearch.configuredKey(environment: ["PARALLEL_API_KEY": "k"]), "k")

        let without = Builtins.description(Builtins.Context(cwd: "/repo"))
        XCTAssertFalse(without.contains("search("))
        XCTAssertFalse(without.contains("read_url("))
        let with = Builtins.description(Builtins.Context(cwd: "/repo", hasWeb: true))
        XCTAssertTrue(with.contains("search(objective"))
        XCTAssertTrue(with.contains("read_url("))
        // Same Future shape as spawn, which is the point: one idiom for fan-out.
        let entry = try XCTUnwrap(Builtins.all(.reference).first { $0.name == "search" })
        XCTAssertTrue(entry.bullet.contains("Future"))
    }),

    ("web: the description names no vendor, so switching one is free", {
        // The recommendation this was built on turns on being able to change provider by
        // editing the request and nothing the model reads — no prompt-cache invalidation, no
        // re-teaching. Leaking the vendor into the text is what would make that expensive.
        let text = Builtins.description(Builtins.Context(cwd: "/repo", hasWeb: true))
        for vendor in ["Parallel", "parallel.ai", "Brave", "Exa", "Tavily"] {
            XCTAssertFalse(text.lowercased().contains(vendor.lowercased()), vendor)
        }
    }),
]

let casesBackgroundSpawn: [Case] = [

    ("spawn: one non-blocking primitive, and Python decides whether to wait", {
        // The agent here writes Python rather than calling a sub-agent tool, so waiting is its
        // script's decision. There is no blocking variant to conform to any more — the Swift
        // side only knows how to start one and how to report on it.
        final class Fake: Agent.SpawnDelegate, @unchecked Sendable {
            let lock = NSLock()
            var started: [String] = []
            var finished = false

            func startBackground(
                prompt: String, name: String?, model: String?, depth: Int
            ) async -> Agent.SpawnStartResult {
                lock.withLock { started.append(prompt) }
                return .running(childID: "c-bg", name: name ?? "c-bg")
            }

            func children() async -> [Agent.ChildStatus] {
                let done = lock.withLock { finished }
                return [Agent.ChildStatus(
                    id: "c-bg", name: "researcher",
                    state: done ? "done" : "running",
                    answer: done ? "found it" : nil)]
            }
        }
        let fake = Fake()
        let bg = await fake.startBackground(
            prompt: "research this", name: "researcher", model: nil, depth: 1)
        guard case .running(let childID, let childName) = bg else {
            XCTFail("the fake runner should admit the child")
            return
        }
        XCTAssertEqual(childID, "c-bg")
        XCTAssertEqual(childName, "researcher")

        // Running: a state and no answer. This is what the Future's poller reads, and the
        // absent key is what stops it resolving early.
        let running = try XCTUnwrap(await fake.children().first)
        XCTAssertEqual(running.state, "running")
        XCTAssertNil(running.payload["answer"])

        fake.lock.withLock { fake.finished = true }
        let done = try XCTUnwrap(await fake.children().first)
        XCTAssertEqual(done.state, "done")
        XCTAssertEqual(done.payload["answer"]?.stringValue, "found it")
    }),

    ("spawn: the Future's watcher thread cannot be a daemon", {
        // Found by a real run, not by reading: 3.12 sub-interpreters refuse daemon threads
        // outright, and the model wrote a two-child fan-out the moment the API invited one.
        // A non-daemon thread has to end by itself, so the deadline and the error branch are
        // load-bearing rather than defensive.
        guard let root = EngineLocator.repoRoot() else {
            print("      skipped: no checkout"); return
        }
        let host = try String(
            contentsOf: root.appending(path: "runtime-hosts/python3/host.py"), encoding: .utf8)
        let watcher = try XCTUnwrap(host.range(of: "def __aviary_watch")).lowerBound
        let tail = String(host[watcher...].prefix(2400))
        XCTAssertTrue(tail.contains("_th.Thread(target=__aviary_watch)"))
        XCTAssertFalse(tail.contains("daemon=True"),
                       "a sub-interpreter refuses daemon threads")
        XCTAssertTrue(tail.contains("deadline"), "it must be able to stop on its own")
        XCTAssertTrue(tail.contains("set_exception"),
                      "and resolve rather than hang when the host goes away")
    }),

    ("spawn: the description promises a Future, and children() is not in the namespace", {
        let ctx = Builtins.Context(cwd: "/repo", canSpawn: true, spawnBudget: 2)
        let text = Builtins.description(ctx)
        XCTAssertTrue(text.contains("concurrent.futures.Future"))
        XCTAssertTrue(text.contains(".result()"))
        // `children` is how the Future's own thread polls. Binding it as well would describe
        // a second way to do the same thing and charge for it on every request.
        XCTAssertFalse(Builtins.names(.reference).contains("children"))
        XCTAssertFalse(text.contains("children()"))
        let entry = try XCTUnwrap(Builtins.all(.reference).first { $0.name == "spawn" })
        XCTAssertTrue(entry.note?.contains("costs a model call") == true,
                      "polling across turns is the expensive mistake and must be named")
        // Still gated: no depth left, no name.
        XCTAssertFalse(
            Builtins.description(Builtins.Context(cwd: "/repo", canSpawn: false))
                .contains("spawn("))
    }),
]

let casesPeers: [Case] = [

    ("peers: a solo run is not told about a room with nobody in it", {
        // Every builtin is described on every request, so an empty capability is a standing
        // token cost for nothing. The gate is the peer count, not whether the feature exists.
        let alone = Builtins.description(Builtins.Context(cwd: "/repo"))
        XCTAssertFalse(alone.contains("agents()"))
        XCTAssertFalse(alone.contains("message("))
        let accompanied = Builtins.description(
            Builtins.Context(cwd: "/repo", peerCount: 2))
        XCTAssertTrue(accompanied.contains("agents()"))
        XCTAssertTrue(accompanied.contains("message(to, text)"))
    }),

    ("peers: the roster and delivery both run through the app, not the agent", {
        // An agent that could enumerate runs itself would be reaching out of its own session.
        // This is the same reason spawning is delegated.
        final class Fake: Agent.PeerDelegate, @unchecked Sendable {
            let peers: [Agent.Peer]
            var delivered: [(String, String, String)] = []
            init(peers: [Agent.Peer]) { self.peers = peers }
            func peers(excluding sessionID: String) async -> [Agent.Peer] {
                peers.filter { $0.session != sessionID }
            }
            func deliver(
                to peer: String, text: String, from sessionID: String
            ) async -> (session: String, error: String?) {
                delivered.append((peer, text, sessionID))
                return peer == "gone" ? ("", "No run matches 'gone'.") : (peer, nil)
            }
        }
        let fake = Fake(peers: [
            Agent.Peer(session: "s-2", title: "Workshop", model: "m", working: true,
                       engine: "in-house"),
        ])
        let listed = await fake.peers(excluding: "s-1")
        XCTAssertEqual(listed.map(\.session), ["s-2"])
        // The payload the agent's Python actually receives.
        let payload = try XCTUnwrap(listed.first).payload
        XCTAssertEqual(payload["title"]?.stringValue, "Workshop")
        XCTAssertEqual(payload["working"]?.boolValue, true)
        XCTAssertEqual(payload["engine"]?.stringValue, "in-house")

        let ok = await fake.deliver(to: "s-2", text: "hello", from: "s-1")
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.session, "s-2")
        // A refusal is a payload the agent can read, not silence it has to time out on.
        let bad = await fake.deliver(to: "gone", text: "hello", from: "s-1")
        XCTAssertNotNil(bad.error)
    }),

    ("peers: the kernel binds both names, and the catalogue describes both", {
        let ctx = Builtins.Context(cwd: "/repo", peerCount: 1)
        for name in ["agents", "message"] {
            XCTAssertTrue(Builtins.names(ctx).contains(name))
        }
        let entry = try XCTUnwrap(Builtins.all(.reference).first { $0.name == "message" })
        XCTAssertEqual(entry.requirement, .peers)
        XCTAssertEqual(entry.mechanism, .callback)
        // The note is the load-bearing part: it says the message arrives at a turn boundary
        // and reads like a person typed it, which is what stops it being used as an RPC.
        XCTAssertTrue(entry.note?.contains("turn boundary") == true)
    }),
]

let casesMCPSurface: [Case] = [

    ("mcp: the configured servers are read with the library", {
        // The config is a fact about a file and is always safe to show. What a server *is*
        // needs it started, which is why probing is a button.
        let config = try XCTUnwrap(JSONValue.parse(Data("""
            {"mcpServers": {"notes": {"command": "npx", "args": ["-y", "notes-mcp"],
                                      "env": {"TOKEN": "x"}}}}
            """.utf8)))
        let servers = MCPConfiguration.parse(config)
        XCTAssertEqual(servers.count, 1)
        let notes = try XCTUnwrap(servers.first)
        XCTAssertEqual(notes.command, "npx")
        XCTAssertEqual(notes.environment.keys.sorted(), ["TOKEN"])
    }),

    ("mcp: probing a real server fills the card, and a broken one explains itself", {
        // The pane only displays an MCPProbe, so this drives the same sequence the button
        // does — start, read, stop — against the strict fixture and against a package that
        // does not exist. A snapshot cannot click, and the populated card is the interesting
        // half of the screen.
        guard let fixture = mcpFixture("mcp-modern.py") else {
            print("      skipped: no modern fixture"); return
        }
        let good = MCPClient(
            name: "fixture", executable: "/usr/bin/env", arguments: ["python3", fixture])
        let tools = try await good.start(timeout: 20)
        let ok = MCPProbe(
            era: await good.era?.label, serverInfo: await good.serverInfo,
            tools: tools.map(\.qualifiedName).sorted(), error: nil, diagnostics: "")
        await good.stop()
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.era, "2026-07-28 (stateless)")
        XCTAssertEqual(ok.serverInfo?.contains("modern-fixture"), true)
        XCTAssertTrue(ok.tools.allSatisfy { $0.hasPrefix("mcp__fixture__") },
                      "the card shows the namespaced names the model is actually given")
        XCTAssertTrue(ok.tools.contains("mcp__fixture__whoami"))

        let bad = MCPClient(
            name: "broken", executable: "/usr/bin/env",
            arguments: ["python3", "/nonexistent/not-a-server.py"])
        var failure: MCPProbe?
        do {
            _ = try await bad.start(timeout: 8)
        } catch {
            failure = MCPProbe(
                era: nil, serverInfo: nil, tools: [], error: error.localizedDescription,
                diagnostics: String((await bad.diagnostics).suffix(600)))
        }
        await bad.stop()
        let seen = try XCTUnwrap(failure)
        XCTAssertNotNil(seen.error)
        XCTAssertTrue(seen.tools.isEmpty)
        XCTAssertNil(seen.era, "an unreachable server has no era to report")
    }),

    ("mcp: a probe records what it found, and a failure keeps its diagnostics", {
        // The most common failure is the most boring one — an npx package never fetched on
        // this machine — and its explanation is on the server's stderr, not in the error.
        let ok = MCPProbe(
            era: "2026-07-28 (stateless)", serverInfo: "notes 1",
            tools: ["mcp__notes__search"], error: nil, diagnostics: "")
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.tools, ["mcp__notes__search"])

        let bad = MCPProbe(
            era: nil, serverInfo: nil, tools: [],
            error: "Could not start the MCP server: launch failed",
            diagnostics: "npm ERR! 404 Not Found")
        XCTAssertNotNil(bad.error)
        XCTAssertTrue(bad.diagnostics.contains("404"),
                      "stderr is where the real reason lives")
        XCTAssertTrue(bad.tools.isEmpty)
    }),
]

let casesAgentHome: [Case] = [

    ("home: the data directory is Aviary's own, and flat", {
        // It was ~/.prime/agent while Aviary ran on a fork of Prime Agent and shared its
        // store. The nested `agent` level existed because the agent was one of several things
        // a prime-agent install kept; there is no second thing here.
        XCTAssertEqual(AgentHome.default.root.lastPathComponent, ".aviary")
        XCTAssertFalse(AgentHome.default.root.path.contains(".prime"))
        // The old location is still nameable, so an empty new home can say where to look
        // rather than reading as lost data.
        XCTAssertTrue(AgentHome.legacyPrimeHome.root.path.hasSuffix(".prime/agent"))

        // Everything a run needs hangs off the root, so re-pointing the root moves all of it.
        let home = AgentHome(root: URL(fileURLWithPath: "/tmp/aviary-home-test"))
        for path in [home.sessionsDir, home.artifactsDir, home.rlmLedgerDir, home.modelsFile,
                     home.settingsFile, home.authFile, home.skillsDir, home.promptsDir] {
            XCTAssertTrue(path.path.hasPrefix("/tmp/aviary-home-test/"), path.path)
        }
    }),

    ("home: the migration carried what is read and left what is not", {
        // Asserted against the real directories, because the point of the copy was to bring
        // the live data and leave 297MB of the harness's IPython venv behind. If a future
        // change starts reading one of the skipped paths, this fails and says so.
        let home = AgentHome.default
        guard home.exists else { print("      skipped: no data directory"); return }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.sessionsDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.artifactsDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.settingsFile.path))
        for skipped in ["kernel-venv", "daemon-workers", "session-leases", "bin"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: home.root.appending(path: skipped).path),
                "\(skipped) is the harness's, and nothing reads it")
        }
    }),
]

let casesRepoRoot: [Case] = [

    ("repoRoot: the marker is the runtime host, not the vendored harness", {
        // Both surviving engines locate host.py through repoRoot(), so keying it on the
        // harness made them depend on a fork neither uses. Removing the harness would have
        // broken in-house and Claude Code at once, which is the sort of coupling that only
        // shows up the day you try to delete something.
        guard let root = EngineLocator.repoRoot() else {
            print("      skipped: no checkout"); return
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "runtime-hosts/python3/host.py").path))
        XCTAssertEqual(EngineLocator.rootMarker, "runtime-hosts/python3/host.py")

        // A directory with the old marker but no runtime host is not a root.
        let fake = FileManager.default.temporaryDirectory
            .appending(path: "aviary-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fake) }
        try FileManager.default.createDirectory(
            at: fake.appending(path: "harness/packages/coding-agent", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        try "{}".write(
            to: fake.appending(path: "harness/packages/coding-agent/package.json"),
            atomically: true, encoding: .utf8)
        let found = EngineLocator.repoRoot(startingAt: fake)
        XCTAssertNotEqual(found?.path, fake.path,
                          "a vendored harness alone must no longer identify a checkout")
    }),
]

let casesBuildStamp: [Case] = [

    ("build: the app can tell when the source has moved past it", {
        // The failure this exists to prevent: three rounds of fixes to a menu were judged
        // against a bundle four hours older than the code that fixed them. A correct fix and
        // a missing rebuild look identical from the outside.
        guard let root = EngineLocator.repoRoot() else {
            print("      skipped: no checkout"); return
        }
        let head = BuildStamp(builtAt: Date(), commit: "HEAD")
        XCTAssertNil(BuildStamp.commitsSinceBuild(repoRoot: root, stamp: head),
                     "a build of HEAD is not behind anything")

        // One commit back is one commit behind, which is the smallest true answer.
        let previous = BuildStamp(builtAt: Date(), commit: "HEAD~1")
        XCTAssertEqual(BuildStamp.commitsSinceBuild(repoRoot: root, stamp: previous), 1)

        // A stamp that names nothing cannot be compared, and must not produce a warning that
        // never clears.
        let unstamped = BuildStamp(builtAt: nil, commit: nil)
        XCTAssertFalse(unstamped.isStamped)
        XCTAssertNil(BuildStamp.commitsSinceBuild(repoRoot: root, stamp: unstamped))
        XCTAssertEqual(unstamped.summary, "unstamped build")

        // A commit that does not exist is not "zero behind" — it is unanswerable.
        let bogus = BuildStamp(builtAt: Date(), commit: "0000000")
        XCTAssertNil(BuildStamp.commitsSinceBuild(repoRoot: root, stamp: bogus))
    }),

    ("build: the bundler stamps what it built and from where", {
        // Asserted against the script rather than a rendered plist, so the two cannot drift
        // without this failing.
        guard let root = EngineLocator.repoRoot() else {
            print("      skipped: no checkout"); return
        }
        let script = try String(
            contentsOf: root.appending(path: "scripts/bundle-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("AviaryBuildStamp"))
        XCTAssertTrue(script.contains("AviaryBuildCommit"))
        XCTAssertTrue(script.contains("rev-parse --short HEAD"),
                      "the commit must come from git, not be typed in")
    }),
]

let casesMirrorChurn: [Case] = [

    ("live: re-reading an unchanged transcript produces equal items", {
        // The precondition the whole no-flash fix rests on. LiveRun's mirror copies the
        // driver's state every 250ms and now assigns only on change — but `@Observable`
        // notifies on assignment, so if two parses of the same bytes ever compared unequal,
        // the guard would never fire and every run's views would go back to being invalidated
        // four times a second. Which is what tore down an open menu.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "aviary-churn-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "session.jsonl")
        let lines = [
            #"{"type":"session","id":"s","version":1,"timestamp":"2026-08-20T10:00:00.000Z","cwd":"/tmp"}"#,
            #"{"type":"message","id":"m1","timestamp":"2026-08-20T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#,
            #"{"type":"message","id":"m2","parentId":"m1","timestamp":"2026-08-20T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"python","id":"t1","arguments":{"code":"1+1"}}]}}"#,
            #"{"type":"message","id":"m3","parentId":"m2","timestamp":"2026-08-20T10:00:03.000Z","message":{"role":"tool","toolCallId":"t1","content":[{"type":"text","text":"2"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let first = try XCTUnwrap(SessionParser.parse(fileURL: file))
        let second = try XCTUnwrap(SessionParser.parse(fileURL: file))
        XCTAssertFalse(first.items.isEmpty)
        XCTAssertEqual(first.items, second.items,
                       "two parses of the same bytes must compare equal, or the guard is dead")

        // And a real change is still seen, or the guard would freeze the transcript.
        try (lines + [
            #"{"type":"message","id":"m4","parentId":"m3","timestamp":"2026-08-20T10:00:04.000Z","message":{"role":"user","content":[{"type":"text","text":"again"}]}}"#
        ]).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let third = try XCTUnwrap(SessionParser.parse(fileURL: file))
        XCTAssertNotEqual(first.items, third.items)
    }),

    ("live: an image on a tool result is a value, not a tuple", {
        // Named so TranscriptItem can synthesise Equatable at all. A tuple field silently
        // blocks synthesis, and the absence of Equatable is what made the mirror unable to
        // ask whether anything had changed.
        var item = TranscriptItem(id: "a", kind: .tool, timestamp: Date(timeIntervalSince1970: 0))
        item.toolResultImages = [ToolResultImage(mimeType: "image/png", base64: "aGk=")]
        var same = TranscriptItem(id: "a", kind: .tool, timestamp: Date(timeIntervalSince1970: 0))
        same.toolResultImages = [ToolResultImage(mimeType: "image/png", base64: "aGk=")]
        XCTAssertEqual(item, same)
        same.toolResultImages = [ToolResultImage(mimeType: "image/png", base64: "different")]
        XCTAssertNotEqual(item, same)
    }),
]

let casesModelSwitch: [Case] = [

    ("switch: a new model answers the next turn, on the same conversation", {
        // The conversation, the interpreter and its variables are the expensive things in a
        // session. Swapping the model is not, so a switch must not cost a restart — that is
        // the whole difference between this and starting a new run.
        guard let first = try FakeProviderServer(script: [
            ["text": "answered by the first model.", "input_tokens": 10, "output_tokens": 4],
        ]) else { print("      skipped: no fixture"); return }
        defer { first.stop() }
        guard let second = try FakeProviderServer(script: [
            ["text": "answered by the second model.", "input_tokens": 20, "output_tokens": 5],
        ]) else { print("      skipped: no fixture"); return }
        defer { second.stop() }
        guard let host = try makeHost(.reference) else { return }
        _ = try await host.start()
        defer { Task { await host.stop() } }

        let home = scratchHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let hostSession = try await host.createSession(cwd: "/tmp")
        let writer = try SessionWriter(home: home, cwd: "/tmp", model: fakeModel())
        let agent = Agent(
            provider: OpenAICompletionsProvider(
                id: "first", baseURL: first.baseURL, apiKey: "k"),
            host: host, writer: writer, hostSession: hostSession,
            config: .init(model: fakeModel(), cwd: "/tmp", systemPrompt: "be brief"))
        await agent.send("hello")

        var swapped = fakeModel()
        swapped.id = "second-model"
        swapped.providerID = "second"
        swapped.maxTokens = 4096
        await agent.switchModel(
            to: swapped,
            provider: OpenAICompletionsProvider(
                id: "second", baseURL: second.baseURL, apiKey: "k"))
        await agent.send("and again")

        // The second request went to the second server, and carried the first exchange with
        // it — a switch that dropped the history would be a new run wearing the same id.
        let sent = try second.recordedRequests()
        XCTAssertEqual(sent.count, 1, "the new provider answered the second prompt")
        let messages = try XCTUnwrap(sent.first?["messages"]?.arrayValue)
        let text = messages.compactMap { $0["content"]?.stringValue }.joined(separator: "|")
        XCTAssertTrue(text.contains("hello"), "the conversation carried over")
        XCTAssertTrue(text.contains("answered by the first model."),
                      "including what the previous model said")
        XCTAssertEqual(try first.recordedRequests().count, 1, "and the old one was not called")

        // The transcript names the switch, or half a conversation was answered by a model the
        // file never mentions.
        await writer.close()
        let raw = try String(contentsOf: writer.fileURL, encoding: .utf8)
        let changes = raw.split(separator: "\n").filter { $0.contains("\"model_change\"") }
        XCTAssertEqual(changes.count, 2, "one at launch, one at the switch")
        XCTAssertTrue(try XCTUnwrap(changes.last).contains("second-model"))
    }),

    ("switch: the workshop agent's model is a setting, not whatever sorts first", {
        // The bug this pins: the workshop launcher passed no model reference at all, and the
        // resolver reads an absent one as the first model of the first provider by id. The
        // agent spent weeks on a model nobody had chosen.
        let defaults = UserDefaults.standard
        let key = "aviary.workshopModel"
        let original = defaults.string(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        XCTAssertNil(defaults.string(forKey: key), "unset means follow the global default")
        defaults.set("openai-codex/gpt-5.6-terra", forKey: key)
        XCTAssertEqual(defaults.string(forKey: key), "openai-codex/gpt-5.6-terra")
        // Stored as a reference rather than a ModelSpec: the catalogue is rebuilt every launch
        // and a remembered object would be a stale copy of a row that may no longer exist.
        XCTAssertTrue(defaults.string(forKey: key)?.contains("/") == true)
    }),
    ("switch: a failed journal blocks provider resolution before its effects", {
        try await test_modelSwitchCoordinatorFailsClosedBeforeProviderResolution()
    }),
]

let casesPhase0SessionControl: [Case] = [
    ("phase0: session/work/run identities remain distinct", {
        try test_sessionWorkIdentityAllocatesIndependentStableReferences()
    }),
    ("phase0: commands are admitted and acknowledged in one order", {
        try await test_sessionCommandControllerSerializesAdmissionAndAcknowledgements()
    }),
    ("phase0: duplicate dispatch waiters execute exactly once", {
        try await test_sessionCommandControllerDispatchIsExactlyOnceForDuplicateWaiters()
    }),
    ("phase0: stale command failures cannot corrupt newer lifecycle state", {
        try await test_sessionCommandControllerIgnoresStaleFailureAfterNewerSendOrEnd()
    }),
    ("phase0: failed preparation destroys its runtime session", {
        try await test_agentRunnerDestroysRuntimeSessionWhenWriterSetupFails()
    }),
    ("phase0: cancellation-insensitive providers cannot execute late tools", {
        try await test_agentCancellationWaitsForProviderAndPreventsLateToolExecution()
    }),
    ("phase0: cooperative provider cancellation is not a failure", {
        try await test_cooperativeProviderCancellationIsNotReportedAsFailure()
    }),
    ("phase0: Claude input requires a live stdin delivery boundary", {
        try await test_claudeInputWithoutLiveStdinIsRejected()
    }),
    ("phase0: cancellation requires a declared capability", {
        try await test_sessionCommandControllerRequiresDeclaredCancellationCapability()
    }),
    ("phase0: steer and queue require declared capabilities", {
        try await test_sessionCommandControllerRequiresDeclaredSteeringAndQueues()
    }),
    ("phase0: control contract matrix covers engines, lifecycle, and action scope", {
        try await test_sessionCommandControllerCoversTheControlContractMatrix()
    }),
    ("phase0: the local Work Host identity is durable", {
        try test_agentHomeWorkHostIdentityIsDurable()
    }),
    ("phase0: session headers preserve Work identity across resume", {
        try await test_sessionWriterPersistsAndRecoversIdentityWithoutChangingLegacyShape()
    }),
    ("phase0: assistant commit acknowledgement names the durable row", {
        try await test_sessionWriterReturnsTheDurableAssistantIdentity()
    }),
    ("phase0: live overlays converge without duplicate rows", {
        try LiveTranscriptOverlaySelfTests.run()
    }),
    ("phase0: Claude terminal outcomes survive cold reload", {
        try await ClaudeCodeOutcomeSelfTests.run()
    }),
    ("phase0: scripted adapter turn preserves queue, steer, cancel, and reload semantics", {
        try await Phase0InteractionSelfTests.run()
    }),
    ("phase1 bridge: command intent stays raw-readable and conversation-hidden", {
        try await test_sessionWriterCommandIntentIsRawReadableButConversationHidden()
    }),
    ("phase1 bridge: writer failures latch across every ambiguous boundary", {
        try await test_sessionWriterLatchesBeforePartialAndPostWriteSyncFailures()
    }),
    ("phase1 bridge: controller commits intent and fails closed", {
        try await test_sessionCommandControllerCommitsIntentAndFailsClosedOnAmbiguity()
    }),
    ("phase1 bridge: command-journal seam preserves admission and delivery boundaries", {
        try await test_sessionCommandControllerJournalSeamPreservesIdentityAndDeliveryBoundaries()
    }),
    ("phase1 bridge: launch journal installs only before admission", {
        try await test_sessionCommandControllerInstallsLaunchJournalOnlyBeforeAdmission()
    }),
    ("phase1 bridge: delivery-journal failure fails closed after crossing", {
        try await test_sessionCommandControllerJournalDeliveryFailureFailsClosedAfterCrossing()
    }),
    ("phase1 bridge: concurrent delivery outcomes honor the first terminal receipt", {
        try await test_sessionCommandControllerDeliveryWaitersHonorTheFirstTerminalOutcome()
    }),
    ("phase1 bridge: SessionWriter remains the legacy command journal", {
        try await test_sessionWriterCanBePassedThroughCommandJournalSeam()
    }),
    ("phase1 bridge: journal failure releases queued dispatch waiters", {
        try await test_sessionCommandControllerFailsQueuedWaitersWhenIntentCommitLatchesJournal()
    }),
    ("phase1 bridge: End bypasses a held intent commit and remains terminal", {
        try await test_sessionCommandControllerEndBypassesHeldCommitAndStaysEnded()
    }),
    ("phase1 bridge: superseded End permits cannot dispatch after teardown", {
        try await test_sessionCommandControllerLateEndCannotDispatchAfterNewerEndCompletes()
    }),
    ("phase1 bridge: resume quarantines an unterminated partial journal tail", {
        try await test_sessionWriterResumeQuarantinesPartialTailBeforeNewRun()
    }),
    ("phase1 bridge: End remains dispatchable across every journal ambiguity", {
        try await test_sessionCommandControllerEndIntentFailuresRemainTeardownPermits()
    }),
    ("phase1 bridge: held steer and queue commits preserve lifecycle acknowledgements", {
        try await test_sessionCommandControllerLifecycleAckSurvivesHeldSteerAndQueueCommit()
    }),
    ("phase1 bridge: late non-End commit failure remains terminal", {
        try await test_sessionCommandControllerHeldSteerFailureAfterTurnFinishMarksFailed()
    }),
]

let casesPhase1Timeline: [Case] = [
    ("phase1: linked Session and Work reducers preserve distinct identities", {
        try test_timelineReducersLinkSessionsAndWork()
    }),
    ("phase1: timeline order, evidence links, and suffix quarantine are deterministic", {
        try test_timelineReducerTracksCausalOrderAndBoundsLinks()
    }),
    ("phase1: unknown events and legacy identities remain inspectable", {
        try test_timelineReducersPreserveUnknownEventsAndLegacyIdentity()
    }),
    ("phase1: live and cold timeline prefixes reduce identically", {
        try test_timelineReducersLiveAndColdPrefixEquivalence()
    }),
    ("phase1: malformed Session attention stays unknown", {
        try test_sessionAttentionMalformedPayloadIsUnknownNotNone()
    }),
    ("phase1: one Session supports many Work attachments with isolated detach", {
        try test_timelineSessionSupportsManyAttachmentsAndDetachIsolation()
    }),
    ("phase1: journal reader preserves bytes, legacy provenance, and tail status", {
        try test_timelineJournalReaderPreservesBytesAndLegacyTailSemantics()
    }),
    ("phase1: action, context, terminality, and semantic tips are validated", {
        try test_timelineValidatesActionLifecycleContextAndSemanticTip()
    }),
    ("phase1: concurrent command receipts preserve host order and retry identity", {
        try test_timelineProjectsCommandReceiptsAndRejectsHostReordering()
    }),
    ("phase1: journal authority and command receipt provenance cannot disagree", {
        try test_timelineJournalAuthorityAndCommandReceiptProvenance()
    }),
    ("phase1: command receipts require exact causal references", {
        try test_timelineCommandReceiptsRequireExactCausalReferencesAndRetainThem()
    }),
    ("phase1: terminal Work is immutable and requires quiescence", {
        test_timelineWorkTerminalLifecycleIsImmutableAndRequiresQuiescence()
    }),
    ("phase1: Timeline v2 100k baseline", {
        try test_timelineV2HundredThousandBaseline()
    }),
    ("phase1: Timeline v2 adversarial incremental equivalence", {
        try test_timelineV2IncrementalAdversarialEquivalence()
    }),
    ("phase1 catalog: canonical rows preserve attached Work truth", {
        try test_canonicalSessionCatalogPreservesAttachedWorkIdentityAndTruth()
    }),
    ("phase1 attention: canonical rows preserve qualified Session identity", {
        try test_canonicalAttentionInboxUsesQualifiedSessionIdentity()
    }),
    ("phase1 attention: no attention is distinct from unknown", {
        try test_canonicalAttentionInboxReportsNoAttentionSeparatelyFromUnknown()
    }),
    ("phase1 attention: missing and unaligned Work fail closed", {
        try test_canonicalAttentionInboxFailsClosedForMissingAndUnalignedWork()
    }),
    ("phase1 attention: unknown domains and tails fail closed", {
        try test_canonicalAttentionInboxFailsClosedForUnknownDomainsAndTails()
    }),
    ("phase1 attention: foreign, ahead, and divergent Work fail closed", {
        try test_canonicalAttentionInboxRejectsForeignAheadAndDivergentWork()
    }),
    ("phase1 attention: attachment identity qualifies duplicate Work rows", {
        try test_canonicalAttentionInboxQualifiesRowsByAttachmentIdentity()
    }),
    ("phase1 attention: aggregate bounds preserve Session authority identity", {
        try test_canonicalAttentionInboxBoundsAcrossSessionsAndKeepsAuthoritiesDistinct()
    }),
    ("phase1 attention: bounded rows remain deterministic and qualified", {
        try test_canonicalAttentionInboxIsBoundedDeterministicAndAuthorityQualified()
    }),
    ("phase1 attention: evidence and reasons remain bounded", {
        try test_canonicalAttentionInboxBoundsEvidenceAndReasons()
    }),
    ("phase1 attention: duplicate journal summaries become conflicts", {
        try test_canonicalAttentionInboxCoalescesDuplicateJournalSummariesAsConflict()
    }),
    ("phase1 notifications: classify canonical transitions and preserve action identity", {
        try test_canonicalNotificationsClassifyAndRetainActionIdentity()
    }),
    ("phase1 notifications: delivery baselines and withholds incomplete scans", {
        try test_canonicalNotificationDeliveryBaselinesDeduplicatesAndWithholdsIncompleteScans()
    }),
    ("phase1 notifications: unknowns conflicts and source transitions stay exact", {
        try test_canonicalNotificationsRetainUnknownsConflictsAndTransitionProvenance()
    }),
    ("phase1 notifications: delivery commits only after acknowledgement and persists", {
        try test_canonicalNotificationDeliveryCommitsOnlyAfterAcknowledgementAndPersists()
    }),
    ("phase1 notifications: new Sessions notify after the initial baseline", {
        try test_canonicalNotificationDeliveryEmitsForSessionCreatedAfterInitialBaseline()
    }),
    ("phase1 notifications: identities are injective and request ids bounded", {
        try test_canonicalNotificationIdentityIsInjectiveAndRequestIDsBounded()
    }),
    ("phase1 notifications: routes are bounded and identity validated", {
        try test_canonicalNotificationRouteRejectsOversizedOrForeignPayloads()
    }),
    ("phase1 notifications: checkpoint state stays bounded", {
        try test_canonicalNotificationCheckpointIsBoundedAndCurrentKeysSurvivePruning()
    }),
    ("phase1 notifications: live turn completion becomes exact ready-for-review", {
        try await test_runJournalBundleFinishedTurnPublishesExactReadyForReviewWhileRunRemainsActive()
    }),
    ("phase1 catalog: detached active Work remains unprojected", {
        try test_canonicalSessionCatalogDoesNotProjectDetachedActiveWork()
    }),
    ("phase1 catalog: corrupt active Work remains unprojected", {
        try test_canonicalSessionCatalogDoesNotProjectCorruptActiveWork()
    }),
    ("phase1 catalog: production scan crosses explicit legacy projection boundary", {
        try await test_sessionCatalogScanUsesExplicitLegacyProjectionBoundary()
    }),
    ("phase1 catalog: legacy projection does not invent Work or attention", {
        try test_legacyProjectionDoesNotInventWorkOrEffectiveAttention()
    }),
    ("phase1 catalog: canonical-only rows survive list display adaptation", {
        try test_canonicalOnlyProjectionSurvivesListDisplayAdapter()
    }),
    ("phase1 catalog: untitled legacy rows stay searchable", {
        try test_untitledLegacyProjectionRemainsNonblankAndSearchable()
    }),
    ("phase1 catalog: duplicate projection ids are explicit", {
        try test_duplicateProjectionIDsAreReportedWithoutTrapping()
    }),
    ("phase1 catalog: delayed remote Work remains visible", {
        try test_canonicalSessionCatalogDoesNotHideDelayedRemoteWork()
    }),
    ("phase1 catalog: cursor misalignment hides unproven Work state", {
        try test_canonicalSessionCatalogSeparatesCursorAlignmentAndHidesUnalignedWork()
    }),
    ("phase1 catalog: attached Work identity must agree across projections", {
        try test_canonicalSessionCatalogRequiresAllAttachedWorkIdentitiesToAgree()
    }),
    ("phase1 catalog: unknown Session domains suppress affected facts", {
        try test_canonicalSessionCatalogSuppressesUnknownSessionAndAttachmentDomains()
    }),
    ("phase1 catalog: read integrity requires an exact canonical Work read", {
        try test_canonicalSessionCatalogOnlyReportsExactCanonicalWorkReads()
    }),
    ("phase1 catalog: duplicate event IDs preserve reducer truth", {
        try test_canonicalSessionCatalogRetainsReducerDuplicateTruthWithoutTrapping()
    }),
    ("phase1 catalog: Session snapshot and read cursors must align", {
        try test_canonicalSessionCatalogCorrelatesSessionSnapshotAndReadCursors()
    }),
    ("phase1 catalog: authority qualifies identity and rejects owner mismatch", {
        try test_canonicalSessionCatalogQualifiesSessionIDsAndRejectsOwnerMismatch()
    }),
    ("phase1 catalog: companion keeps one legacy-backed display row", {
        try test_companionProjectionIsOneLegacyBackedDisplayRow()
    }),
    ("phase1 catalog: companion title falls back to legacy", {
        try test_companionTitleFallsBackToLegacyWhenCanonicalIsEmpty()
    }),
    ("phase1 catalog: companion keeps canonical and legacy facts separate", {
        try test_companionKeepsCanonicalFactsSeparateFromHealthierLegacyFacts()
    }),
    ("phase1 catalog: unknown companion Session facts stay unknown", {
        try test_companionUnknownSessionDomainDoesNotRefillFactsFromLegacy()
    }),
    ("phase1 catalog: companion index maps display identity to canonical truth", {
        try test_companionIndexHasOneRowAndMapsLegacyIDToCanonicalSummary()
    }),
    ("phase1 catalog: companion refuses mismatched Session identities", {
        try test_companionFactoryRefusesMismatchedSessionIDs()
    }),
    ("phase1 catalog: pure canonical and legacy projections remain compatible", {
        try test_pureCanonicalAndLegacyProjectionBehaviorRemainsUnchanged()
    }),
    ("phase1 catalog: companion duplicates remain explicit and non-trapping", {
        try test_companionAndDuplicateRowsRemainExplicitAndNonTrapping()
    }),
    ("phase1 catalog: native and legacy stores join into one companion", {
        try await test_sessionCatalogScanCatalogJoinsNativeAndLegacyIntoOneCompanion()
    }),
    ("phase1 catalog: native-only Session remains observe-only", {
        try await test_sessionCatalogScanCatalogRetainsNativeOnlyRowsAsCanonicalOnly()
    }),
    ("phase1 catalog: legacy-only Session behavior remains unchanged", {
        try await test_sessionCatalogScanCatalogLeavesLegacyOnlyRowsUnchanged()
    }),
    ("phase1 catalog: independent Work survives without a Session", {
        try await test_sessionCatalogScanCatalogKeepsIndependentWorkWithoutSession()
    }),
    ("phase1 catalog: unknown native Session remains visible with facts suppressed", {
        try await test_sessionCatalogScanCatalogKeepsUnknownSessionVisibleButSuppressesItsFacts()
    }),
    ("phase1 catalog: conflicting native authority cannot form a companion", {
        try await test_sessionCatalogScanCatalogDoesNotPairConflictingNativeAuthority()
    }),
    ("phase1 catalog: corrupt native tail cannot replace healthy legacy", {
        try await test_sessionCatalogScanCatalogCorruptNativeTailCannotReplaceHealthyLegacy()
    }),
    ("phase1 catalog: Trash shares the native Session owner lock", {
        try await test_sessionCatalogTrashSharesTheNativeSessionOwnerLock()
    }),
    ("phase1 census: canonical SessionCatalog projection is registered", {
        try test_readerCensusRegistersCanonicalSessionCatalogProjection()
    }),
    ("phase1 census: linked fixture reports canonical state planes", {
        try test_readerCensusFixtureProjectsCorePlanes()
    }),
    ("phase1 census: positive ready projection crosses delivery gate", {
        try test_readerCensusProjectsPositiveReadyNotificationAndDeliveryTransition()
    }),
    ("phase1 census: canonical Flock rejects unaligned or foreign Work", {
        try test_readerCensusFlockRejectsUnalignedOrForeignWork()
    }),
    ("phase1 census: production Flock uses qualified canonical Work rows", {
        try test_canonicalFlockCatalogQualifiesChildIDsAndSessionLinks()
    }),
    ("phase1 census: Flock suppresses children for unknown Work domains", {
        try test_canonicalFlockCatalogSuppressesChildrenForUnknownAffectedDomains()
    }),
    ("phase1 census: Flock treats Work and external effects as child domains", {
        test_canonicalFlockUnknownWorkAndExternalEffectsSuppressChildCompleteness()
    }),
    ("phase1 census: Flock keeps legacy roots only by explicit companion provenance", {
        test_canonicalFlockLegacyCompatibilityRequiresExplicitNativeCompanionProvenance()
    }),
    ("phase1 census: Flock duplicate Work rows stay deterministic", {
        try test_canonicalFlockDuplicateWorkPresentationIDsAreStableAcrossInputOrder()
    }),
    ("phase1 census: Flock attention is deduplicated per Session", {
        try test_canonicalFlockAttentionCountDeduplicatesAuthorityQualifiedSessions()
    }),
    ("phase1 census: legacy Flock preserves duplicate child IDs by parent", {
        try test_legacyAgentTreePreservesDuplicateChildIDsPerParentSession()
    }),
    ("phase1 census: malformed child ownership cannot be silently omitted", {
        try test_readerCensusRejectsMalformedChildOwnershipInsteadOfOmittingIt()
    }),
    ("phase1 census: indeterminate actions override authored attention", {
        try test_readerCensusIndeterminateActionOverridesAuthoredAttention()
    }),
    ("phase1 census: retained-body evidence must match the actual artifact", {
        try test_readerCensusRejectsContradictoryRetainedBodyMetadata()
    }),
    ("phase1 census: incremental byte chunks match whole reads", {
        try test_readerCensusIncrementalChunksMatchWholeRead()
    }),
    ("phase1 census: malformed and truncated tails remain visible", {
        try test_readerCensusMalformedAndTruncatedTailsStayVisible()
    }),
    ("phase1 census: legacy records retain synthetic durable identity", {
        try test_readerCensusLegacyJournalKeepsSyntheticIdentity()
    }),
    ("phase1 census: manifest and retained bodies round-trip", {
        try test_readerCensusManifestAndRetainedBodiesRoundTrip()
    }),
]

let casesCanonicalSessionSearch: [Case] = [
    ("phase1 search: authority-qualified same IDs remain distinct", {
        try test_canonicalSessionSearchSeparatesAuthorityQualifiedSameIDs()
    }),
    ("phase1 search: unknown companion facts never refill from legacy", {
        try test_canonicalSessionSearchUnknownNeverRefillsCompanionLegacyFacts()
    }),
    ("phase1 search: non-exact native facts are withheld", {
        try test_canonicalSessionSearchWithholdsNonExactOrInvalidNativeFacts()
    }),
    ("phase1 search: large fields are bounded before indexing", {
        try test_canonicalSessionSearchBoundsLargeFieldsBeforeIndexing()
    }),
    ("phase1 search: legacy agent prompts are bounded and sanitized", {
        test_legacyAgentSearchIsBoundedAndExcludesInjectedPromptContext()
    }),
    ("phase1 search: visible conversation is whitelisted and bounded", {
        try test_canonicalSessionSearchWhitelistsVisibleConversationAndBoundsIt()
    }),
    ("phase1 search: legacy compatibility is explicit and sanitized", {
        try test_canonicalSessionSearchLegacyCompatibilityIsExplicitAndSanitized()
    }),
    ("phase1 search: duplicate rows and global bounds are deterministic", {
        try test_canonicalSessionSearchDuplicateRowsAreWithheldAndGlobalBoundsAreDeterministic()
    }),
    ("phase1 search: conversation lifecycle stays separate from Work liveness", {
        try test_canonicalSessionSearchKeepsConversationLifecycleSeparateFromWorkLiveness()
    }),
]

let casesContextManifest: [Case] = [
    ("phase1 context: manifest is stable measured and secret safe", {
        try test_contextManifestIsStableMeasuredAndSecretSafe()
    }),
    ("phase1 context: contradictory body metadata is omitted", {
        try test_contextManifestRejectsContradictoryBodyMetadata()
    }),
    ("phase1 context: crossing verifies bodies and exact cumulative totals", {
        try await test_contextCrossingRejectsMissingRetainedBodyAndFalseCumulativeClaims()
    }),
    ("phase1 context: cold replay applies canonical manifest validation", {
        try test_contextManifestColdReplayUsesCanonicalValidationAndRunScopedTotals()
    }),
    ("phase1 context: cold reopen restores per-Run context totals", {
        try await test_runJournalBundleRestoresPerRunContextTotalsOnColdReopen()
    }),
    ("phase1 context: bundle persists metadata before provider requests", {
        try await test_runJournalBundlePersistsContextManifestWithoutBodyText()
    }),
    ("phase1 context: Work action failure cannot issue a provider permit", {
        try await test_contextWorkIntentFailureCannotIssueProviderPermit()
    }),
    ("phase1 context: manifest and causal action precede provider invocation", {
        try await test_contextManifestAndCausalActionAreDurableBeforeProviderCall()
    }),
    ("phase1 context: manifest failure prevents provider call", {
        try await test_contextManifestFailurePreventsProviderCall()
    }),
]

let casesPromptProvenance: [Case] = [
    ("phase1 prompt provenance: producer assembly preserves exact prompt bytes", {
        try test_systemPromptAssemblyMatchesLegacyForEveryRenderedSection()
    }),
    ("phase1 prompt provenance: source status and Unicode truncation are explicit", {
        try test_systemPromptAssemblyReportsContextStatesAndCharacterTruncation()
    }),
    ("phase1 prompt provenance: source identity is stable and distinct from content", {
        try test_systemPromptAssemblyUsesDistinctStableIdentityAndContentDigests()
    }),
    ("phase1 prompt provenance: duplicate sources and raw-body encoding are refused", {
        try test_systemPromptAssemblyRejectsDuplicateIDsAndDoesNotEncodeBodies()
    }),
    ("phase1 prompt provenance: source observation is causal bounded and secret safe", {
        try await test_promptSourceManifestCrossingIsCausalBoundedAndSecretSafe()
    }),
    ("phase1 prompt provenance: forged source observation is quarantined", {
        try await test_promptSourceManifestReducerRejectsForgedOrMismatchedObservation()
    }),
    ("phase1 prompt provenance: swapped and empty source assemblies are refused", {
        try await test_promptSourceManifestRejectsSwappedAssemblyAndEmptySourcesBeforeAppend()
    }),
    ("phase1 prompt provenance: contradictory source metadata and media are refused", {
        try await test_promptSourceManifestRejectsContradictorySourceMetadataAndMedia()
    }),
    ("phase1 prompt provenance: truncated source must be a retained prefix", {
        try await test_promptSourceManifestRejectsTruncatedBodyThatIsNotAFullPrefix()
    }),
    ("phase1 prompt provenance: runtime bytes and generated goal source stay exact", {
        try await test_promptProvenanceRuntimePreservesProviderBytesAndGeneratedGoalSource()
    }),
    ("phase1 prompt provenance: runtime mismatch prevents provider effect", {
        try await test_promptProvenanceRuntimeMismatchPreventsProviderEffect()
    }),
    ("phase1 prompt provenance: Reader Census context is metadata only and bounded", {
        try test_readerCensusNextModelContextIsMetadataOnlyAndBounded()
    }),
    ("phase1 prompt provenance: Reader Census preserves order and legacy unknowns", {
        try test_readerCensusNextModelContextPreservesCanonicalOrderAndLegacyUnknowns()
    }),
    ("phase1 prompt provenance: Reader Census uses accepted compaction boundary", {
        try test_readerCensusCompactionBoundaryComesFromLastAcceptedEvent()
    }),
    ("phase1 prompt provenance: cold resume uses retained source bodies", {
        try await test_promptProvenanceColdResumeUsesRetainedBodiesAfterSourceFilesChange()
    }),
    ("phase1 prompt provenance: cold resume refuses unavailable source bodies", {
        try await test_promptProvenanceColdResumeRefusesMissingOrCorruptSourceBody()
    }),
    ("phase1 prompt provenance: cold resume rechecks truncated source prefix", {
        try await test_promptProvenanceColdResumeRechecksTruncatedFullBodyPrefix()
    }),
    ("phase1 prompt provenance: cold resume requires exact source observation", {
        try await test_promptProvenanceColdResumeRefusesForgedMissingAndMismatchedObservation()
    }),
    ("phase1 prompt provenance: legacy cold resume remains opaque", {
        try await test_promptProvenanceColdResumeLeavesLegacyAssemblyNil()
    }),
]

let casesNativeColdResume: [Case] = [
    ("phase1 native resume: producer context reports six-plane coverage", {
        try await test_nativeColdResumeReconstructsProducerContextAndReportsCoverage()
    }),
    ("phase1 native resume: exact user suffix is appended after boundary", {
        try await test_nativeColdResumeAcceptsExactUserSuffixAfterBoundary()
    }),
    ("phase1 native resume: missing message or tool bodies refuse", {
        try await test_nativeColdResumeRefusesMissingOrCorruptMessageAndToolBodies()
    }),
    ("phase1 native resume: stale cursors and tails refuse", {
        try await test_nativeColdResumeRefusesStaleCursorAndTailedRead()
    }),
    ("phase1 native resume: assistant structure must be provable", {
        try await test_nativeColdResumeRefusesTextOnlyOrDanglingStructuredAssistant()
    }),
    ("phase1 native resume: action gaps and compaction crossings refuse", {
        try await test_nativeColdResumeRefusesPostBoundaryActionAndCompactionCrossing()
    }),
    ("phase1 native resume: pre-Start seed wins over legacy and sends prompt once", {
        try await test_nativeLaunchCapturesPreStartSeedAndRunnerNeverFallsBackToLegacy()
    }),
    ("phase1 native resume: corrupt seed refuses before commands or runtime effects", {
        try await test_nativeLaunchRefusesUnavailableSeedBeforeCommandOrRuntimeEffect()
    }),
]

let casesLocalTimelineCatalog: [Case] = [
    ("phase1 local catalog: discovers native Session and independent Work", {
        try test_localTimelineCatalogDiscoversNativeSessionAndIndependentWork()
    }),
    ("phase1 local catalog: preserves active Work across absent or stale Session cursor", {
        try test_localTimelineCatalogKeepsActiveWorkWhenSessionCursorIsAbsentOrStale()
    }),
    ("phase1 local catalog: rejects owner authority and locator mismatches locally", {
        try test_localTimelineCatalogRejectsOwnerAuthorityAndLocatorMismatchesLocally()
    }),
    ("phase1 local catalog: retains truncated and corrupt files", {
        try test_localTimelineCatalogKeepsTruncatedAndCorruptFilesVisible()
    }),
    ("phase1 local catalog: tailed Session remains visible but non-projectable", {
        try test_localTimelineCatalogKeepsTailedSessionVisibleButNonProjectable()
    }),
    ("phase1 local catalog: semantically invalid Session withholds summary", {
        try test_localTimelineCatalogKeepsSemanticallyInvalidSessionVisibleButWithholdsSummary()
    }),
    ("phase1 local catalog: unterminated first event remains visible as tail", {
        try test_localTimelineCatalogClassifiesUnterminatedFirstEventAsTail()
    }),
    ("phase1 local catalog: malformed native Session blocks legacy actions", {
        try test_localTimelineCatalogBlocksMalformedNativeSessionAtLegacyActionBoundary()
    }),
    ("phase1 local catalog: unknown domains suppress affected Work facts", {
        try test_localTimelineCatalogSuppressesFactsInUnknownDeclaredDomains()
    }),
    ("phase1 local catalog: unreadable catalog directories are diagnosed", {
        try test_localTimelineCatalogReportsUnreadableCatalogDirectories()
    }),
    ("phase1 local catalog: rejects symlink escapes", {
        try test_localTimelineCatalogRejectsSymlinkEscapes()
    }),
    ("phase1 local catalog: symlinked home roots cannot establish authority", {
        try test_localTimelineCatalogRejectsSymlinkedHomeRootAuthority()
    }),
    ("phase1 local catalog: reports duplicate event identity without blocking other rows", {
        try test_localTimelineCatalogReportsDuplicateEventIdentityWithoutBlockingOtherRows()
    }),
    ("phase1 local catalog: round trips unsafe encoded Work IDs", {
        try test_localTimelineCatalogRoundTripsUnsafeEncodedWorkIDs()
    }),
    ("phase1 local catalog: Work row IDs are injective across slash boundaries", {
        try test_localTimelineCatalogWorkRowIDsAreInjectiveAcrossSlashBoundaries()
    }),
    ("phase1 local catalog: ordering bounds and metadata are deterministic", {
        try test_localTimelineCatalogOrderingBoundsAndMetadataAreDeterministic()
    }),
]

let casesTimelineWriter: [Case] = [
    ("phase1 writer: fresh appendBatch bytes, reducer, and reopen", {
        try await test_timelineJournalWriterFreshBatchReopenAndReducer()
    }),
    ("phase1 writer: draft identity and evidence validation", {
        try await test_timelineJournalWriterValidatesIdentityAndEvidenceBeforeWriting()
    }),
    ("phase1 writer: invalid journals are refused without repair", {
        try await test_timelineJournalWriterRefusesEmptyLegacyForeignCorruptAndNoncontiguousReopen()
    }),
    ("phase1 writer: lock and failure boundaries fail closed", {
        try await test_timelineJournalWriterLocksAndLatchesEveryFailureBoundary()
    }),
    ("phase1 writer: owner lock survives data path replacement", {
        try await test_timelineJournalWriterOwnerLockSurvivesJournalPathReplacement()
    }),
    ("phase1 writer: empty fresh crash window recovers", {
        try await test_timelineJournalWriterReopensEmptyAfterFreshCrashWindow()
    }),
    ("phase1 writer: JournalRef construction fails safely", {
        try test_timelineJournalRefPublicConstructionCannotTrap()
    }),
    ("phase1 writer: deterministic seams and persisted authority", {
        try await test_timelineJournalWriterDeterministicSeamsAndAgentHomeAuthority()
    }),
]

let casesRunJournalBundle: [Case] = [
    ("phase1 bundle: paired native genesis and exact assembly", {
        try await test_runJournalBundleFreshGenesisAndExactAssembly()
    }),
    ("phase1 bundle: execution identity creates then reopens one attachment", {
        try await test_runJournalBundleExecutionOpenCreatesThenReopensTheMirroredAttachment()
    }),
    ("phase1 bundle: execution identity refuses foreign and partial authority", {
        try await test_runJournalBundleExecutionOpenRefusesForeignAuthorityAndIncompletePair()
    }),
    ("phase1 bundle: input and assistant tips retain the visible chain", {
        try await test_runJournalBundleInputAndAssistantTipsRemainOneVisibleChain()
    }),
    ("phase1 bundle: queued delivery preserves the accepted command", {
        try await test_runJournalBundleQueuedDeliveryUsesOriginalReceiptAndNoSecondInput()
    }),
    ("phase1 bundle: non-conversation commands do not become chat messages", {
        try await test_runJournalBundleNonConversationalCommandDoesNotCreateAUserMessage()
    }),
    ("phase1 bundle: every action kind receives a post-start permit", {
        try await test_runJournalBundleAllActionKindsPermitOnlyAfterDurableStart()
    }),
    ("phase1 bundle: reopen retains single-use action identities", {
        try await test_runJournalBundleReopenRetainsSingleUseActionIdentities()
    }),
    ("phase1 bundle: semantic gate serializes concurrent mutations", {
        try await test_runJournalBundleSemanticGateSerializesConcurrentMutations()
    }),
    ("phase1 bundle: queued command terminalizes before finished-run reopen", {
        try await test_runJournalBundleQueuedCommandMustTerminalizeBeforeFinishedRunReopen()
    }),
    ("phase1 bundle: terminal run outcomes remain typed", {
        try await test_runJournalBundleTerminalRunOutcomesRemainTyped()
    }),
    ("phase1 bundle: turn outcomes reach catalog notifications and deduplicate", {
        try await test_runJournalBundleTurnOutcomesReachCatalogNotificationsAndDeduplicate()
    }),
    ("phase1 bundle: partial prefixes latch and refuse permits", {
        try await test_runJournalBundlePartialPrefixesLatchAndRefusePermits()
    }),
    ("phase1 bundle: outcome failure metadata and retry remain truthful", {
        try await test_runJournalBundleOutcomeFailureRequiresMetadataButCanContinue()
    }),
    ("phase1 bundle: reopen, counterpart, and active-writer checks", {
        try await test_runJournalBundleReopenNPlusOneAndRefusesIncompletePairsOrActiveWriters()
    }),
    ("phase1 bundle: reopen continues from semantic tip", {
        try await test_runJournalBundleReopenContinuesFromSemanticTipNotPhysicalTail()
    }),
    ("phase1 bundle: checked close reports a partial close", {
        try await test_runJournalBundleCheckedCloseReportsPartialClose()
    }),
    ("phase1 bundle: native producers record attention transitions", {
        try await test_runJournalBundleProducesCanonicalAttentionTransitions()
    }),
    ("phase1 bundle: canceled teardown still finishes and closes", {
        try await test_runJournalBundleCanceledTaskStillFinishesAndCloses()
    }),
]

await Harness.run(
    cases0 + cases1 + cases2 + cases3 + cases4 + cases5 + cases6 + casesBuiltins
        + casesLibraryUsage + casesArtifact + casesAttachImage + casesMCPVersions
        + casesModelSwitch + casesMirrorChurn + casesBuildStamp
        + casesRepoRoot + casesAgentHome
        + casesPeers + casesMCPSurface
        + casesBackgroundSpawn + casesWebSearch + casesDispatched
        + casesCrossingLaws + casesPhase0SessionControl + casesPhase1Timeline
        + casesContextManifest + casesPromptProvenance + casesNativeColdResume
        + casesCanonicalSessionSearch
        + casesLocalTimelineCatalog + casesTimelineWriter + casesRunJournalBundle + casesNativeExecutionIntegration
        + casesNativeEffectFailure + casesNativeLaunchJournal
        + casesRuntimeHostCallbackQuiescence + casesNativeTurnModel
        + casesNativeIndeterminateEffects + casesChildLifecycle
        + casesCommandDeliveryOutcome)
