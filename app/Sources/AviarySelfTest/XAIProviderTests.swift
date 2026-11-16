import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import AviaryCore

/// A real URLSession/URLProtocol seam keeps these tests independent of xAI credentials while
/// exercising request headers, bounded response transport, SSE framing, and terminal proof.
private final class XAIProviderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var status = 200
    private static var body = Data()
    private static var request: URLRequest?

    static func configure(status: Int = 200, body: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.body = Data(body.utf8)
        request = nil
    }

    static func lastRequest() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "xai-provider-fixture.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let status = Self.status
        let body = Self.body
        Self.request = request
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func xaiProviderSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [XAIProviderURLProtocol.self]
    return URLSession(configuration: configuration)
}

private struct XAICollectedEvents {
    var body: JSONValue?
    var text = ""
    var thinking = ""
    var toolCalls: [(String, String, JSONValue)] = []
    var usage: [ProviderUsage.RawReport] = []
    var done: String?
    var error: Error?
}

private func collectXAI(_ provider: XAIResponsesProvider) async -> XAICollectedEvents {
    var result = XAICollectedEvents()
    do {
        for try await event in provider.stream(ChatRequest(model: "grok-4.7", messages: [])) {
            switch event {
            case .requestBody(let body): result.body = body
            case .textDelta(let text): result.text += text
            case .thinkingDelta(let text): result.thinking += text
            case .toolCall(let id, let name, let arguments):
                result.toolCalls.append((id, name, arguments))
            case .usage(let report): result.usage.append(report)
            case .done(let stopReason): result.done = stopReason
            }
        }
    } catch { result.error = error }
    return result
}

let casesXAIProvider: [Case] = [
    ("provider xAI: tool-free requests omit tool selection options", {
        let body = XAIResponsesProvider.body(for: ChatRequest(
            model: "grok-4.7", messages: [.user("Reply with ok")], maxTokens: 512))
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["parallel_tool_calls"])
        XCTAssertEqual(body["max_output_tokens"]?.intValue, 512)
    }),

    ("provider xAI: Responses body is stateless and replays tools", {
        let request = ChatRequest(
            model: "grok-4.7",
            messages: [
                .system("system instruction"),
                .user("hello"),
                ChatMessage(role: .assistant, content: [
                    .toolCall(id: "call-1|item-1", name: "python", arguments: .object(["x": .number(2)]))
                ]),
                ChatMessage(role: .tool, content: [
                    .toolResult(id: "call-1|item-1", name: "python", text: "4", isError: false)
                ]),
            ],
            tools: [ChatTool(
                name: "python", description: "run Python", parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["x": .object(["type": .string("number")])]),
                    "required": .array([.string("x")]),
                ]))],
            maxTokens: 321,
            temperature: 0.2,
            reasoningEffort: "high")
        let body = XAIResponsesProvider.body(for: request)
        XCTAssertEqual(body["model"]?.stringValue, "grok-4.7")
        XCTAssertEqual(body["store"]?.boolValue, false)
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertFalse(XAIResponsesProvider.supportsEncryptedReasoningReplay)
        XCTAssertEqual(body["max_output_tokens"]?.intValue, 321)
        XCTAssertEqual(body["reasoning"]?["effort"]?.stringValue, "high")
        XCTAssertEqual(body["input"]?.arrayValue?.count, 4)
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["name"]?.stringValue, "python")
        XCTAssertEqual(body["tool_choice"]?.stringValue, "auto")
        XCTAssertEqual(body["parallel_tool_calls"]?.boolValue, true)
        XCTAssertEqual(body["tools"]?.arrayValue?.first?["parameters"]?["type"]?.stringValue, "object")
        XCTAssertEqual(
            body["input"]?.arrayValue?.last?["type"]?.stringValue, "function_call_output")
        XCTAssertEqual(
            body["input"]?.arrayValue?.last?["call_id"]?.stringValue, "call-1")
    }),

    ("provider xAI: Responses SSE yields text reasoning tool usage and terminal", {
        XAIProviderURLProtocol.configure(body:
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n"
            + "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"plan\"}\n\n"
            + "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"item-1\",\"call_id\":\"call-1\",\"name\":\"python\"}}\n\n"
            + "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"item-1\",\"delta\":\"{\\\"x\\\":2}\"}\n\n"
            + "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"item-1\"}}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":7,\"input_tokens_details\":{\"cached_tokens\":2},\"output_tokens_details\":{\"reasoning_tokens\":3},\"total_tokens\":17}}}\n\n")
        let session = xaiProviderSession()
        defer { session.invalidateAndCancel() }
        let result = await collectXAI(XAIResponsesProvider(
            baseURL: URL(string: "http://xai-provider-fixture.invalid/v1")!,
            apiKey: "xai-fixture-secret", session: session))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.thinking, "plan")
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.0, "call-1")
        XCTAssertEqual(result.toolCalls.first?.1, "python")
        XCTAssertEqual(result.toolCalls.first?.2["x"]?.intValue, 2)
        XCTAssertEqual(result.usage.last?.inputTokens, 10)
        XCTAssertEqual(result.usage.last?.cacheReadTokens, 2)
        XCTAssertEqual(result.usage.last?.reasoningTokens, 3)
        XCTAssertEqual(result.done, "completed")
        XCTAssertEqual(result.body?["store"]?.boolValue, false)
        XCTAssertEqual(XAIProviderURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer xai-fixture-secret")
    }),

    ("provider xAI: HTTP errors are bounded and redact the key", {
        XAIProviderURLProtocol.configure(
            status: 401,
            body: "invalid key xai-fixture-secret and extra server detail")
        let session = xaiProviderSession()
        defer { session.invalidateAndCancel() }
        let result = await collectXAI(XAIResponsesProvider(
            baseURL: URL(string: "http://xai-provider-fixture.invalid/v1")!,
            apiKey: "xai-fixture-secret", session: session, maxResponseBytes: 1024))
        XCTAssertNil(result.done)
        guard case .http(_, let body) = result.error as? ChatError else {
            XCTFail("expected an HTTP error")
            return
        }
        XCTAssertFalse(body.contains("xai-fixture-secret"))
        XCTAssertTrue(body.contains("<redacted>"))
    }),

    ("provider xAI: missing credentials fail before transport", {
        let result = await collectXAI(XAIResponsesProvider(
            baseURL: URL(string: "http://xai-provider-fixture.invalid/v1")!, apiKey: nil))
        guard case .notConfigured(let message) = result.error as? ChatError else {
            XCTFail("missing xAI credentials should be a configuration error")
            return
        }
        XCTAssertTrue(message.contains("API key"))
    }),

    ("provider xAI: failed terminal preserves usage and redacts remote detail", {
        XAIProviderURLProtocol.configure(body:
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
            + "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2},\"error\":{\"message\":\"secret xai-fixture-secret\"}}}\n\n")
        let session = xaiProviderSession()
        defer { session.invalidateAndCancel() }
        let result = await collectXAI(XAIResponsesProvider(
            baseURL: URL(string: "http://xai-provider-fixture.invalid/v1")!,
            apiKey: "xai-fixture-secret", session: session))
        XCTAssertEqual(result.text, "partial")
        XCTAssertEqual(result.usage.last?.inputTokens, 5)
        XCTAssertNil(result.done)
        guard case .http(_, let body) = result.error as? ChatError else {
            XCTFail("failed Responses event should surface as a provider error")
            return
        }
        XCTAssertFalse(body.contains("xai-fixture-secret"))
        XCTAssertTrue(body.contains("<redacted>"))
    }),

    ("provider xAI: incomplete response preserves usage but cannot finish a turn", {
        XAIProviderURLProtocol.configure(body:
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
            + "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"usage\":{\"input_tokens\":5,\"output_tokens\":2},\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n")
        let session = xaiProviderSession()
        defer { session.invalidateAndCancel() }
        let result = await collectXAI(XAIResponsesProvider(
            baseURL: URL(string: "http://xai-provider-fixture.invalid/v1")!,
            apiKey: "fixture", session: session))
        XCTAssertEqual(result.text, "partial")
        XCTAssertEqual(result.usage.last?.inputTokens, 5)
        XCTAssertNil(result.done)
        XCTAssertTrue(result.toolCalls.isEmpty)
        guard case .transport = result.error as? ChatError else {
            XCTFail("incomplete response must not commit successful turn completion")
            return
        }
    }),

    ("provider xAI: duplicate function completion is not silently replayed", {
        XAIProviderURLProtocol.configure(body:
            "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"item-1\",\"call_id\":\"call-1\",\"name\":\"python\",\"arguments\":\"{}\"}}\n\n"
            + "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"item-1\"}}\n\n"
            + "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"item-1\",\"call_id\":\"call-1\",\"name\":\"python\",\"arguments\":\"{}\"}}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n")
        let session = xaiProviderSession()
        defer { session.invalidateAndCancel() }
        let result = await collectXAI(XAIResponsesProvider(
            baseURL: URL(string: "http://xai-provider-fixture.invalid/v1")!,
            apiKey: "fixture", session: session))
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertNil(result.done)
        guard case .decoding = result.error as? ChatError else {
            XCTFail("duplicate tool completion should fail closed")
            return
        }
    }),

    ("provider xAI: EOF without completed response is not success", {
        XAIProviderURLProtocol.configure(body:
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
            + "data: [DONE]\n\n")
        let session = xaiProviderSession()
        defer { session.invalidateAndCancel() }
        let result = await collectXAI(XAIResponsesProvider(
            baseURL: URL(string: "http://xai-provider-fixture.invalid/v1")!,
            apiKey: "fixture", session: session))
        XCTAssertEqual(result.text, "partial")
        XCTAssertNil(result.done)
        guard case .transport = result.error as? ChatError else {
            XCTFail("EOF without response.completed must remain an uncertain crossing")
            return
        }
    }),
]
