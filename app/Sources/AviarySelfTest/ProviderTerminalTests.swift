import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import AviaryCore

/// Provider streams are deliberately exercised through URLProtocol rather than a parser-only
/// helper. The failure mode here is at the transport boundary: a response can contain useful
/// deltas and usage and still not prove that the provider completed the crossing.
private final class ProviderTerminalURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var body = Data()

    static func configure(_ body: String) {
        lock.lock()
        self.body = Data(body.utf8)
        lock.unlock()
    }

    private static func configuredBody() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return body
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "provider-terminal.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.configuredBody()
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct ProviderTerminalResult {
    var text = ""
    var reports: [ProviderUsage.RawReport] = []
    var toolCalls: [String] = []
    var done = false
    var error: ChatError?
}

private func collectProvider<P: ChatProvider>(_ provider: P) async -> ProviderTerminalResult {
    var result = ProviderTerminalResult()
    do {
        for try await event in provider.stream(ChatRequest(model: "fixture", messages: [])) {
            switch event {
            case .textDelta(let text): result.text += text
            case .usage(let report): result.reports.append(report)
            case .toolCall(_, let name, _): result.toolCalls.append(name)
            case .done: result.done = true
            case .requestBody, .thinkingDelta: break
            }
        }
    } catch let error as ChatError {
        result.error = error
    } catch {
        result.error = .transport("unexpected provider error")
    }
    return result
}

private func providerTerminalSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderTerminalURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func openAIResult(_ body: String) async -> ProviderTerminalResult {
    ProviderTerminalURLProtocol.configure(body)
    let session = providerTerminalSession()
    defer { session.invalidateAndCancel() }
    return await collectProvider(OpenAICompletionsProvider(
        id: "fixture", baseURL: URL(string: "http://provider-terminal.invalid/v1/")!,
        apiKey: nil, session: session))
}

private func anthropicResult(_ body: String) async -> ProviderTerminalResult {
    ProviderTerminalURLProtocol.configure(body)
    let session = providerTerminalSession()
    defer { session.invalidateAndCancel() }
    return await collectProvider(AnthropicMessagesProvider(
        id: "fixture", baseURL: URL(string: "http://provider-terminal.invalid/v1/")!,
        apiKey: nil, session: session))
}

#if !os(Linux)
private func codexResult(_ body: String) async throws -> ProviderTerminalResult {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aviary-provider-terminal-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }

    let store = CodexAuth.Store(url: root.appendingPathComponent("auth.json"))
    try store.save(.init(
        access: "fixture-only", refresh: "fixture-only",
        expires: Int(Date().addingTimeInterval(600).timeIntervalSince1970 * 1000),
        accountId: "fixture"))
    ProviderTerminalURLProtocol.configure(body)
    let session = providerTerminalSession()
    defer { session.invalidateAndCancel() }
    return await collectProvider(CodexResponsesProvider(
        id: "fixture", store: store, baseURL: "http://provider-terminal.invalid",
        session: session))
}
#endif

private func assertTransport(_ result: ProviderTerminalResult, contains text: String) {
    guard case .transport(let message) = result.error else {
        XCTFail("expected a bounded transport error, got \(String(describing: result.error))")
        return
    }
    XCTAssertTrue(message.contains(text), "transport error should identify the missing terminal proof")
}

private func openAIToolFrame(arguments: String, finish: String?) -> String {
    "data: " + JSONValue.object([
        "choices": .array([.object([
            "delta": .object([
                "content": .string("partial tool response"),
                "tool_calls": .array([.object([
                    "index": .number(0), "id": .string("call-1"),
                    "function": .object(["name": .string("python"), "arguments": .string(arguments)])
                ])])
            ]),
            "finish_reason": finish.map(JSONValue.string) ?? .null
        ])])
    ]).compactJSON + "\n\n"
}

private let casesProviderTerminalBase: [Case] = [
    ("provider terminal: OpenAI truncated text and final usage never become done", {
        // The final usage event is intentionally unblanked. SSEParser.flush must route it through
        // the same payload path as a normally framed event before the terminal proof is checked.
        let result = await openAIResult(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
                + "data: {\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3},\"choices\":[]}")
        XCTAssertEqual(result.text, "partial")
        XCTAssertEqual(result.reports.count, 1)
        XCTAssertEqual(result.reports.last?.inputTokens, 7)
        XCTAssertFalse(result.done)
        assertTransport(result, contains: "terminal response")
    }),

    ("provider terminal: OpenAI buffers tool calls until a terminal proof", {
        let result = await openAIResult(openAIToolFrame(arguments: "{bad", finish: nil))
        XCTAssertEqual(result.text, "partial tool response", "the outer protocol frame must be valid")
        XCTAssertTrue(result.toolCalls.isEmpty, "an EOF partial call must never become actionable")
        XCTAssertFalse(result.done)
        assertTransport(result, contains: "terminal response")
    }),

    ("provider terminal: OpenAI unblanked finish reason is a terminal proof", {
        let result = await openAIResult(
            "data: {\"choices\":[{\"delta\":{\"content\":\"complete\"},\"finish_reason\":\"stop\"}]}\n")
        XCTAssertEqual(result.text, "complete")
        XCTAssertTrue(result.done)
        XCTAssertNil(result.error)
    }),

    ("provider terminal: OpenAI length cutoff cannot execute an incomplete tool call", {
        for reason in ["length", "content_filter"] {
            for arguments in ["{bad", "{}"] {
                let result = await openAIResult(openAIToolFrame(arguments: arguments, finish: reason))
                XCTAssertEqual(result.text, "partial tool response")
                XCTAssertTrue(result.toolCalls.isEmpty)
                XCTAssertFalse(result.done)
                guard case .decoding = result.error else {
                    XCTFail("cutoff tool call should fail even when its argument prefix parses")
                    continue
                }
            }
        }
    }),

    ("provider terminal: Anthropic malformed tool arguments never become an empty object", {
        let result = await anthropicResult(
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-1\",\"name\":\"python\"}}\n\n"
                + "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{bad\"}}\n\n"
                + "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                + "data: {\"type\":\"message_stop\"}\n\n")
        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertFalse(result.done)
        guard case .decoding(let message) = result.error else {
            XCTFail("malformed Anthropic tool arguments should be a decoding failure")
            return
        }
        XCTAssertTrue(message.contains("malformed"))
    }),

    ("provider terminal: Anthropic truncated usage is retained but message_stop is required", {
        let result = await anthropicResult(
            "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n\n"
                + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null},\"usage\":{\"output_tokens\":4}}")
        XCTAssertEqual(result.reports.count, 2)
        XCTAssertEqual(result.reports.last?.outputTokens, 4)
        XCTAssertFalse(result.done)
        assertTransport(result, contains: "message_stop")
    }),

    ("provider terminal: Anthropic unblanked message_stop is processed by flush", {
        let result = await anthropicResult(
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n"
                + "data: {\"type\":\"message_stop\"}")
        XCTAssertTrue(result.done)
        XCTAssertNil(result.error)
    }),
]

#if !os(Linux)
private let casesProviderTerminalCodex: [Case] = [
    ("provider terminal: Codex incomplete retains usage and throws instead of done", {
        let result = try await codexResult(
            "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4}}}\n\n")
        XCTAssertEqual(result.reports.count, 1)
        XCTAssertEqual(result.reports.first?.outputTokens, 4)
        XCTAssertFalse(result.done)
        assertTransport(result, contains: "incomplete response")
    }),

    ("provider terminal: Codex malformed tool arguments never become an empty object", {
        let result = try await codexResult(
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"item-1\",\"call_id\":\"call-1\",\"name\":\"python\"}}\n\n"
                + "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"item-1\",\"delta\":\"{bad\"}\n\n"
                + "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"item-1\"}}\n\n"
                + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n")
        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertFalse(result.done)
        guard case .decoding(let message) = result.error else {
            XCTFail("malformed Codex tool arguments should be a decoding failure")
            return
        }
        XCTAssertTrue(message.contains("malformed"))
    }),

    ("provider terminal: Codex DONE sentinel without response.completed is not completion", {
        let result = try await codexResult("data: [DONE]\n\n")
        XCTAssertFalse(result.done)
        assertTransport(result, contains: "response.completed")
    }),

    ("provider terminal: Codex completed event without a trailing blank is complete", {
        let result = try await codexResult(
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n")
        XCTAssertTrue(result.done)
        XCTAssertNil(result.error)
    }),
]
#else
private let casesProviderTerminalCodex: [Case] = []
#endif

let casesProviderTerminal = casesProviderTerminalBase + casesProviderTerminalCodex
