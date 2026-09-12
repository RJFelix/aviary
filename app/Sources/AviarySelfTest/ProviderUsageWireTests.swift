import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AviaryCore

let casesProviderUsageWire: [Case] = [
    ("provider usage wire: missing zero malformed and cache writes", {
        XCTAssertFalse(Fmt.tokens(Int.min).isEmpty)
        let missing = try XCTUnwrap(ProviderUsageWire.openAICompletions(.object([:])))
        XCTAssertNil(missing.inputTokens)
        XCTAssertNil(missing.cacheWriteTokens)
        XCTAssertEqual(missing.inputAccounting, .cacheInclusive)
        let report = try XCTUnwrap(ProviderUsageWire.responses(.object([
            "input_tokens": .number(100), "output_tokens": .number(20),
            "input_tokens_details": .object(["cached_tokens": .number(50), "cache_write_tokens": .number(10)]),
            "output_tokens_details": .object(["reasoning_tokens": .number(0)]),
        ])))
        XCTAssertEqual(report.cacheWriteTokens, 10)
        XCTAssertEqual(report.reasoningTokens, 0)
        XCTAssertNil(report.reportedTotalTokens)
        for bad in [JSONValue.bool(true), .string("12"), .number(1.5), .number(.infinity),
                    .number(9_007_199_254_740_992), .array([])] {
            let value = try XCTUnwrap(ProviderUsageWire.openAICompletions(.object(["prompt_tokens": bad])))
            XCTAssertNil(value.inputTokens)
            XCTAssertTrue(value.malformedFields.contains(.inputTokens))
        }
        let negative = try XCTUnwrap(ProviderUsageWire.responses(.object(["input_tokens": .number(-1)])))
        XCTAssertEqual(negative.inputTokens, -1, "Raw negative evidence is not converted to zero")
        let badDetails = try XCTUnwrap(ProviderUsageWire.responses(.object(["input_tokens_details": .bool(false)])))
        XCTAssertEqual(badDetails.malformedFields, [.cacheReadTokens, .cacheWriteTokens])
        XCTAssertNil(ProviderUsageWire.responses(.null))
    }),
    ("provider usage wire: Anthropic cumulative updates replace and preserve presence", {
        let first = try XCTUnwrap(ProviderUsageWire.anthropicMessages(.object([
            "input_tokens": .number(2), "cache_read_input_tokens": .number(100),
            "cache_creation_input_tokens": .number(20), "output_tokens": .number(1),
        ])))
        let second = try XCTUnwrap(ProviderUsageWire.anthropicMessages(
            .object(["output_tokens": .number(5)]), merging: first))
        XCTAssertEqual(second.inputAccounting, .cacheExclusive)
        XCTAssertEqual(second.inputTokens, 2)
        XCTAssertEqual(second.outputTokens, 5, "Cumulative 5 replaces 1, not 6")
        XCTAssertEqual(second.cacheWriteTokens, 20)
        let invalid = try XCTUnwrap(ProviderUsageWire.anthropicMessages(
            .object(["output_tokens": .string("bad")]), merging: second))
        XCTAssertNil(invalid.outputTokens)
        XCTAssertTrue(invalid.malformedFields.contains(.outputTokens))
        let cleared = try XCTUnwrap(ProviderUsageWire.anthropicMessages(
            .object(["output_tokens": .null]), merging: invalid))
        XCTAssertNil(cleared.outputTokens)
        XCTAssertFalse(cleared.malformedFields.contains(.outputTokens))
        let zero = try XCTUnwrap(ProviderUsageWire.anthropicMessages(
            .object(["output_tokens": .number(0)]), merging: cleared))
        XCTAssertEqual(zero.outputTokens, 0)
        XCTAssertNil(zero.reasoningTokens)
        let deltaOnly = try XCTUnwrap(ProviderUsageWire.anthropicMessages(.object(["output_tokens": .number(9)])))
        XCTAssertNil(deltaOnly.inputTokens)
        XCTAssertEqual(deltaOnly.outputTokens, 9)
        let foreign = ProviderUsage.RawReport(inputTokens: 100, inputAccounting: .cacheInclusive)
        let reset = try XCTUnwrap(ProviderUsageWire.anthropicMessages(
            .object(["output_tokens": .number(1)]), merging: foreign))
        XCTAssertNil(reset.inputTokens, "different accounting reports cannot be merged")
    }),
    ("provider usage wire: Anthropic yields partial usage before stream failure", {
        let body = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":2,"cache_read_input_tokens":30,"cache_creation_input_tokens":0,"output_tokens":1}}}

        data: {"type":"message_delta","usage":{"output_tokens":7}}

        data: {"type":"error","error":{"message":"fixture failed"}}


        """
        let session = usageWireSession(body)
        defer { session.invalidateAndCancel() }
        let provider = AnthropicMessagesProvider(id: "fixture", baseURL: URL(string: "http://usage-fixture.invalid")!,
            apiKey: nil, session: session)
        var reports: [ProviderUsage.RawReport] = []
        var failed = false
        do {
            for try await event in provider.stream(ChatRequest(model: "fixture", messages: [])) {
                if case .usage(let report) = event { reports.append(report) }
            }
        } catch { failed = true }
        XCTAssertTrue(failed)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.outputTokens, 1)
        XCTAssertEqual(reports.last?.outputTokens, 7)
        XCTAssertEqual(reports.last?.cacheReadTokens, 30)
    }),
    ("provider usage wire: completion stream does not fabricate absent categories", {
        let body = "data: {\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4},\"choices\":[]}\n\ndata: [DONE]\n\n"
        let session = usageWireSession(body)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompletionsProvider(id: "fixture", baseURL: URL(string: "http://usage-fixture.invalid")!,
            apiKey: nil, session: session)
        var reports: [ProviderUsage.RawReport] = []
        for try await event in provider.stream(ChatRequest(model: "fixture", messages: [])) {
            if case .usage(let report) = event { reports.append(report) }
        }
        XCTAssertEqual(reports.count, 1)
        XCTAssertNil(reports.first?.cacheReadTokens)
        XCTAssertNil(reports.first?.cacheWriteTokens)
        XCTAssertNil(reports.first?.reportedTotalTokens)
    }),
]

private func usageWireSession(_ body: String) -> URLSession {
    UsageWireURLProtocol.lock.lock()
    UsageWireURLProtocol.body = Data(body.utf8)
    UsageWireURLProtocol.lock.unlock()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UsageWireURLProtocol.self]
    return URLSession(configuration: config)
}

private final class UsageWireURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "usage-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let data = Self.body; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
