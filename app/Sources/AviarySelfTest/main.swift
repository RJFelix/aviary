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

// MARK: - Runner

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
])
