import Foundation
@testable import AviaryCore

let casesCodexUsageCrossing: [Case] = [
    ("provider usage wire: Codex failed crossing retains usage and is not done", {
        let result = try await codexUsageProbe(status: 200, body:
            "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"input_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1}}}}\n\n")
        XCTAssertTrue(result.failed)
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.requests, 1)
        XCTAssertEqual(result.reports.count, 1)
        XCTAssertEqual(result.reports.first?.cacheWriteTokens, 1)
        XCTAssertEqual(result.reports.first?.outputTokens, 4)
    }),
    ("provider usage wire: Codex HTTP errors do not hide retry crossings", {
        let result = try await codexUsageProbe(status: 503, body: "fixture unavailable")
        XCTAssertTrue(result.failed)
        XCTAssertFalse(result.done)
        XCTAssertTrue(result.reports.isEmpty)
        XCTAssertEqual(result.requests, 1)
    }),
]

private func codexUsageProbe(status: Int, body: String) async throws
    -> (reports: [ProviderUsage.RawReport], failed: Bool, done: Bool, requests: Int)
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acu-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CodexAuth.Store(url: root.appendingPathComponent("auth.json"))
    try store.save(.init(access: "fixture-only", refresh: "fixture-only",
        expires: Int(Date().addingTimeInterval(600).timeIntervalSince1970 * 1000), accountId: "fixture"))
    CodexUsageURLProtocol.configure(status: status, body: Data(body.utf8))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CodexUsageURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let provider = CodexResponsesProvider(store: store, baseURL: "http://codex-usage-fixture.invalid", session: session)
    var reports: [ProviderUsage.RawReport] = []
    var failed = false
    var done = false
    do {
        for try await event in provider.stream(ChatRequest(model: "fixture", messages: [])) {
            if case .usage(let report) = event { reports.append(report) }
            if case .done = event { done = true }
        }
    } catch { failed = true }
    return (reports, failed, done, CodexUsageURLProtocol.requestCount())
}

private final class CodexUsageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var body = Data()
    private static var status = 200
    private static var requests = 0
    static func configure(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        self.body = body; self.status = status; requests = 0
    }
    static func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "codex-usage-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let body = Self.body; let status = Self.status; Self.requests += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
