import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import AviaryCore

private final class AviaryTelemetryHTTPCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var resultStorage: Result<HTTPURLResponse, Error>?
    private var countStorage = 0

    func receive(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        countStorage += 1
        if resultStorage == nil { resultStorage = result }
        lock.unlock()
    }

    var result: Result<HTTPURLResponse, Error>? {
        lock.lock(); defer { lock.unlock() }
        return resultStorage
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return countStorage
    }
}

private final class AviaryTelemetryHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case response(status: Int, body: Data, declaredLength: Int?)
        case hold
    }

    private static let lock = NSLock()
    private static var modeStorage: Mode = .hold
    private static var startsStorage = 0
    private static var stopsStorage = 0

    static func reset(_ mode: Mode) {
        lock.lock()
        modeStorage = mode
        startsStorage = 0
        stopsStorage = 0
        lock.unlock()
    }

    static var starts: Int {
        lock.lock(); defer { lock.unlock() }
        return startsStorage
    }

    static var stops: Int {
        lock.lock(); defer { lock.unlock() }
        return stopsStorage
    }

    private static func begin() -> Mode {
        lock.lock(); defer { lock.unlock() }
        startsStorage += 1
        return modeStorage
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "aviary-telemetry.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.begin() {
        case .hold:
            return
        case .response(let status, let body, let declaredLength):
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let headers = declaredLength.map { ["Content-Length": String($0)] }
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopsStorage += 1
        Self.lock.unlock()
    }
}

/// A real loopback redirect, because Linux FoundationNetworking does not implement the custom
/// URLProtocol redirect callback used by the other HTTP fixtures. The target writes a marker only
/// when contacted, so refusal is proved by the absence of that marker rather than by trusting a
/// mocked callback.
private final class AviaryTelemetryLocalRedirectServer: @unchecked Sendable {
    private let process: Process
    private let portFileURL: URL
    private let targetHitURL: URL
    let port: Int

    private init(process: Process, portFileURL: URL, targetHitURL: URL, port: Int) {
        self.process = process
        self.portFileURL = portFileURL
        self.targetHitURL = targetHitURL
        self.port = port
    }

    static func make() async throws -> AviaryTelemetryLocalRedirectServer {
        let portFileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-telemetry-port-\(UUID().uuidString).txt")
        let targetHitURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "aviary-telemetry-target-\(UUID().uuidString).marker")
        let script = #"""
import http.server
import sys

port_path = sys.argv[1]
marker = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/target":
            with open(marker, "w", encoding="ascii") as output:
                output.write("contacted")
            body = b"unexpected target"
            self.send_response(200)
        elif self.path == "/redirect":
            body = b"redirect"
            self.send_response(302)
            self.send_header("Location", "/target")
        else:
            body = b"not found"
            self.send_response(404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="ascii") as output:
    output.write(str(server.server_address[1]))
server.serve_forever()
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", script, portFileURL.path, targetHitURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.environment = ProcessEnvironment.shared.snapshot
        try process.run()

        for _ in 0..<200 {
            if let data = try? Data(contentsOf: portFileURL),
               let line = String(data: data, encoding: .utf8),
               let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)),
               (1...65_535).contains(port), process.isRunning
            {
                return AviaryTelemetryLocalRedirectServer(
                    process: process, portFileURL: portFileURL, targetHitURL: targetHitURL,
                    port: port)
            }
            guard process.isRunning else { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        terminateProcess(process)
        cleanupProcessFiles(portFileURL: portFileURL, targetHitURL: targetHitURL)
        throw UnwrapFailure(description: "local redirect server did not publish a port")
    }

    var redirectURL: URL {
        URL(string: "http://127.0.0.1:\(port)/redirect")!
    }

    var targetWasContacted: Bool {
        FileManager.default.fileExists(atPath: targetHitURL.path)
    }

    var isRunning: Bool { process.isRunning }

    func stop() async {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if process.isRunning { terminateProcess(process) }
        }
        cleanupProcessFiles(portFileURL: portFileURL, targetHitURL: targetHitURL)
    }

    func terminateIfRunning() {
        if process.isRunning { terminateProcess(process) }
        cleanupProcessFiles(portFileURL: portFileURL, targetHitURL: targetHitURL)
    }

    deinit { terminateIfRunning() }
}

private func terminateProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    #if canImport(Darwin)
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
    #elseif canImport(Glibc)
    _ = Glibc.kill(process.processIdentifier, SIGKILL)
    #endif
}

private func cleanupProcessFiles(portFileURL: URL, targetHitURL: URL) {
    try? FileManager.default.removeItem(at: portFileURL)
    try? FileManager.default.removeItem(at: targetHitURL)
}

private func aviaryTelemetryHTTPConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AviaryTelemetryHTTPURLProtocol.self]
    return configuration
}

private func awaitTelemetryHTTPResult(
    _ completion: AviaryTelemetryHTTPCompletion
) async -> Result<HTTPURLResponse, Error>? {
    for _ in 0..<400 {
        if let result = completion.result { return result }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return completion.result
}

private func telemetryHTTPError(
    _ result: Result<HTTPURLResponse, Error>?
) -> AviaryTelemetryHTTPClientError? {
    guard case .failure(let error)? = result else { return nil }
    return error as? AviaryTelemetryHTTPClientError
}

func test_aviaryTelemetryHTTPClientAcceptsOnlyBoundedSuccess() async throws {
    let limit = AviaryTelemetryHTTPClient.maximumResponseBytes
    AviaryTelemetryHTTPURLProtocol.reset(
        .response(status: 200, body: Data(repeating: 0x41, count: limit), declaredLength: limit))
    let client = AviaryTelemetryHTTPClient(configuration: aviaryTelemetryHTTPConfiguration())
    defer { client.shutDown() }
    let completion = AviaryTelemetryHTTPCompletion()
    client.send(request: URLRequest(url: URL(string: "http://aviary-telemetry.invalid/success")!)) {
        completion.receive($0)
    }
    let result = await awaitTelemetryHTTPResult(completion)
    guard case .success(let response)? = result else {
        XCTFail("bounded telemetry response did not succeed")
        return
    }
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(completion.count, 1)
}

func test_aviaryTelemetryHTTPClientRejectsStatusAndOverflowWithoutDetails() async throws {
    AviaryTelemetryHTTPURLProtocol.reset(
        .response(status: 503, body: Data("collector secret body".utf8), declaredLength: nil))
    let statusClient = AviaryTelemetryHTTPClient(configuration: aviaryTelemetryHTTPConfiguration())
    let statusCompletion = AviaryTelemetryHTTPCompletion()
    statusClient.send(
        request: URLRequest(url: URL(string: "http://aviary-telemetry.invalid/status")!),
        completion: statusCompletion.receive)
    XCTAssertEqual(
        telemetryHTTPError(await awaitTelemetryHTTPResult(statusCompletion)),
        .nonSuccessStatus)
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(statusCompletion.count, 1)
    statusClient.shutDown()

    let overflow = Data(
        repeating: 0x42, count: AviaryTelemetryHTTPClient.maximumResponseBytes + 1)
    AviaryTelemetryHTTPURLProtocol.reset(
        .response(status: 200, body: overflow, declaredLength: nil))
    let overflowClient = AviaryTelemetryHTTPClient(configuration: aviaryTelemetryHTTPConfiguration())
    let overflowCompletion = AviaryTelemetryHTTPCompletion()
    overflowClient.send(
        request: URLRequest(url: URL(string: "http://aviary-telemetry.invalid/overflow")!),
        completion: overflowCompletion.receive)
    XCTAssertEqual(
        telemetryHTTPError(await awaitTelemetryHTTPResult(overflowCompletion)),
        .responseTooLarge)
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(overflowCompletion.count, 1)
    overflowClient.shutDown()
}

func test_aviaryTelemetryHTTPClientRefusesRedirects() async throws {
    let server = try await AviaryTelemetryLocalRedirectServer.make()
    defer { server.terminateIfRunning() }
    let client = AviaryTelemetryHTTPClient()
    defer { client.shutDown() }
    let completion = AviaryTelemetryHTTPCompletion()
    client.send(
        request: URLRequest(url: server.redirectURL),
        completion: completion.receive)
    XCTAssertEqual(
        telemetryHTTPError(await awaitTelemetryHTTPResult(completion)),
        .redirectRefused)
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(completion.count, 1)
    XCTAssertTrue(server.isRunning)
    XCTAssertFalse(server.targetWasContacted)
    await server.stop()
}

func test_aviaryTelemetryHTTPClientCapsConcurrencyAndCancelsExactlyOnce() async throws {
    AviaryTelemetryHTTPURLProtocol.reset(.hold)
    let client = AviaryTelemetryHTTPClient(
        configuration: aviaryTelemetryHTTPConfiguration(), timeout: 2)
    let first = AviaryTelemetryHTTPCompletion()
    let second = AviaryTelemetryHTTPCompletion()
    let overloaded = AviaryTelemetryHTTPCompletion()
    let request = URLRequest(url: URL(string: "http://aviary-telemetry.invalid/hold")!)
    client.send(request: request, completion: first.receive)
    client.send(request: request, completion: second.receive)
    client.send(request: request, completion: overloaded.receive)

    XCTAssertEqual(
        telemetryHTTPError(await awaitTelemetryHTTPResult(overloaded)),
        .overloaded)
    XCTAssertNil(first.result)
    XCTAssertNil(second.result)
    client.shutDown()
    XCTAssertEqual(telemetryHTTPError(await awaitTelemetryHTTPResult(first)), .cancelled)
    XCTAssertEqual(telemetryHTTPError(await awaitTelemetryHTTPResult(second)), .cancelled)
    try? await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(second.count, 1)
    XCTAssertEqual(overloaded.count, 1)
}

let casesAviaryTelemetryHTTPClient: [Case] = [
    ("telemetry HTTP client: bounded success", {
        try await test_aviaryTelemetryHTTPClientAcceptsOnlyBoundedSuccess()
    }),
    ("telemetry HTTP client: status and overflow are fixed failures", {
        try await test_aviaryTelemetryHTTPClientRejectsStatusAndOverflowWithoutDetails()
    }),
    ("telemetry HTTP client: redirects are refused", {
        try await test_aviaryTelemetryHTTPClientRefusesRedirects()
    }),
    ("telemetry HTTP client: concurrency and cancellation are bounded", {
        try await test_aviaryTelemetryHTTPClientCapsConcurrencyAndCancelsExactlyOnce()
    }),
]
