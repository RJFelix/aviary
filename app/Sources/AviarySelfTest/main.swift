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
])
