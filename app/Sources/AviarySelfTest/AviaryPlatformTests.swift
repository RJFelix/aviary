#if os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import AviaryCore

/// FoundationNetworking marks URLProtocol as non-Sendable on Swift 6.3. The fixtures serialize
/// their mutable state with locks, so capture the protocol object through this explicit test-only
/// synchronization boundary instead of crossing it directly in a dispatch closure.
private final class URLProtocolSendableBox: @unchecked Sendable {
    let value: URLProtocol

    init(_ value: URLProtocol) {
        self.value = value
    }
}

/// URLProtocol fixtures exercise the Linux delegate path without depending on a public network
/// service. Each fixture emits real URLSession callbacks; the production adapter still owns the
/// response budget, callback queue, and cancellation decisions.
private final class ContentLengthOversizedURLProtocol: URLProtocol {
    private static let body = Data(repeating: 0x41, count: 128)
    private static let metricsLock = NSLock()
    private static var bodyBytesSent = 0
    private static var stopCount = 0

    private let stopSignal = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var stopped = false

    static func reset() {
        metricsLock.lock()
        bodyBytesSent = 0
        stopCount = 0
        metricsLock.unlock()
    }

    static func metrics() -> (bodyBytesSent: Int, stopCount: Int) {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return (bodyBytesSent, stopCount)
    }

    private static func recordBody(_ count: Int) {
        metricsLock.lock()
        bodyBytesSent += count
        metricsLock.unlock()
    }

    private static func recordStop() {
        metricsLock.lock()
        stopCount += 1
        metricsLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Length": String(Self.body.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let client = self.client
        let fixture = URLProtocolSendableBox(self)
        DispatchQueue.global(qos: .utility).async {
            let fixture = fixture.value as! ContentLengthOversizedURLProtocol
            client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            _ = fixture.stopSignal.wait(timeout: .now() + 3)

            fixture.stateLock.lock()
            let wasStopped = fixture.stopped
            fixture.stateLock.unlock()
            guard !wasStopped else { return }

            Self.recordBody(Self.body.count)
            client?.urlProtocol(fixture, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(fixture)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let shouldSignal = !stopped
        stopped = true
        stateLock.unlock()
        if shouldSignal {
            Self.recordStop()
            stopSignal.signal()
        }
    }
}

private final class NoLengthOversizedURLProtocol: URLProtocol {
    private static let body = Data(repeating: 0x42, count: 128)
    private static let metricsLock = NSLock()
    private static var bodyBytesSent = 0
    private static var stopCount = 0

    private let stateLock = NSLock()
    private var stopped = false

    static func reset() {
        metricsLock.lock()
        bodyBytesSent = 0
        stopCount = 0
        metricsLock.unlock()
    }

    static func metrics() -> (bodyBytesSent: Int, stopCount: Int) {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return (bodyBytesSent, stopCount)
    }

    private static func recordBody(_ count: Int) {
        metricsLock.lock()
        bodyBytesSent += count
        metricsLock.unlock()
    }

    private static func recordStop() {
        metricsLock.lock()
        stopCount += 1
        metricsLock.unlock()
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let client = self.client
        let fixture = URLProtocolSendableBox(self)
        DispatchQueue.global(qos: .utility).async {
            let fixture = fixture.value as! NoLengthOversizedURLProtocol
            client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            for start in stride(from: 0, to: Self.body.count, by: 8) {
                guard !fixture.isStopped() else { return }
                let end = min(start + 8, Self.body.count)
                let chunk = Self.body[start..<end]
                Self.recordBody(chunk.count)
                client?.urlProtocol(fixture, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard !fixture.isStopped() else { return }
            client?.urlProtocolDidFinishLoading(fixture)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let shouldRecord = !stopped
        stopped = true
        stateLock.unlock()
        if shouldRecord { Self.recordStop() }
    }
}

private final class SlowURLProtocol: URLProtocol {
    private static let body = Data((0..<128).map(UInt8.init))

    private let stateLock = NSLock()
    private var stopped = false

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Length": String(Self.body.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let client = self.client
        let fixture = URLProtocolSendableBox(self)
        DispatchQueue.global(qos: .utility).async {
            let fixture = fixture.value as! SlowURLProtocol
            client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            for start in stride(from: 0, to: Self.body.count, by: 8) {
                guard !fixture.isStopped() else { return }
                let end = min(start + 8, Self.body.count)
                client?.urlProtocol(fixture, didLoad: Self.body[start..<end])
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard !fixture.isStopped() else { return }
            client?.urlProtocolDidFinishLoading(fixture)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

/// Delivers one callback payload larger than the adapter's queue window. The production adapter
/// must split that single callback before admitting any piece to the bounded queue.
private final class SingleOversizedChunkURLProtocol: URLProtocol {
    private static let body = Data((0..<128).map(UInt8.init))
    private static let metricsLock = NSLock()
    private static var callbackCount = 0
    private static var callbackBytes = 0
    private static var callbackReturned = false

    private let stateLock = NSLock()
    private var stopped = false

    static func reset() {
        metricsLock.lock()
        callbackCount = 0
        callbackBytes = 0
        callbackReturned = false
        metricsLock.unlock()
    }

    static var metrics: (callbackCount: Int, callbackBytes: Int, callbackReturned: Bool) {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return (callbackCount, callbackBytes, callbackReturned)
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Length": String(Self.body.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let client = self.client
        let fixture = URLProtocolSendableBox(self)
        DispatchQueue.global(qos: .utility).async {
            let fixture = fixture.value as! SingleOversizedChunkURLProtocol
            client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard !fixture.isStopped() else { return }

            // Exactly one URLProtocol callback carries all 128 bytes, intentionally exceeding the
            // 16-byte adapter window used by the adversarial test below.
            Self.metricsLock.lock()
            Self.callbackCount += 1
            Self.callbackBytes += Self.body.count
            Self.metricsLock.unlock()
            client?.urlProtocol(fixture, didLoad: Self.body)
            Self.metricsLock.lock()
            Self.callbackReturned = true
            Self.metricsLock.unlock()
            guard !fixture.isStopped() else { return }
            client?.urlProtocolDidFinishLoading(fixture)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}

/// Fills the bounded queue and then enters one callback that must wait for consumer cancellation.
/// This is intentionally separate from ``SlowURLProtocol``: it proves the condition wait itself
/// is interruptible instead of only proving that a cooperative consumer eventually drains bytes.
private final class BlockedProducerURLProtocol: URLProtocol {
    private static let body = Data((0..<32).map(UInt8.init))
    private static let metricsLock = NSLock()
    private static var ready = false
    private static var callbackReturned = false
    private static var stopCount = 0

    private let stateLock = NSLock()
    private var stopped = false

    static func reset() {
        metricsLock.lock()
        ready = false
        callbackReturned = false
        stopCount = 0
        metricsLock.unlock()
    }

    static var didEnterBlockedCallback: Bool {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return ready
    }

    static var didReturnFromBlockedCallback: Bool {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return callbackReturned
    }

    static var stops: Int {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return stopCount
    }

    private static func markReady() {
        metricsLock.lock()
        ready = true
        metricsLock.unlock()
    }

    private static func markCallbackReturned() {
        metricsLock.lock()
        callbackReturned = true
        metricsLock.unlock()
    }

    private static func markStop() {
        metricsLock.lock()
        stopCount += 1
        metricsLock.unlock()
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Length": String(Self.body.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let client = self.client
        let fixture = URLProtocolSendableBox(self)
        DispatchQueue.global(qos: .utility).async {
            let fixture = fixture.value as! BlockedProducerURLProtocol
            client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard !fixture.isStopped() else { return }
            client?.urlProtocol(fixture, didLoad: Self.body.prefix(8))
            guard !fixture.isStopped() else { return }
            client?.urlProtocol(fixture, didLoad: Self.body.dropFirst(8).prefix(8))

            // The next callback enters the adapter while its queue is exactly at the configured
            // buffer limit.
            // mark. The test cancels the returned stream after observing this marker, which must
            // wake this synchronous URLProtocol call and let the worker exit.
            Self.markReady()
            client?.urlProtocol(fixture, didLoad: Self.body.dropFirst(16).prefix(8))
            Self.markCallbackReturned()
            // Cancellation is the terminal event for this fixture. Do not send a later finish
            // callback after URLSession has removed the canceled task from its registry.
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let shouldRecord = !stopped
        stopped = true
        stateLock.unlock()
        if shouldRecord { Self.markStop() }
    }
}

private final class FirstByteURLProtocol: URLProtocol {
    private static let body = Data((0..<16).map(UInt8.init))
    private static let stateLock = NSLock()
    private static var finished = false
    private static let releaseFinish = DispatchSemaphore(value: 0)

    private let stateLock = NSLock()
    private var stopped = false

    static func reset() {
        stateLock.lock()
        finished = false
        stateLock.unlock()
        // Drain a signal left by a previous test, if any.
        while releaseFinish.wait(timeout: .now()) == .success {}
    }

    static func releaseServerFinish() {
        releaseFinish.signal()
    }

    static var didFinish: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finished
    }

    private func isStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Length": String(Self.body.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let client = self.client
        let fixture = URLProtocolSendableBox(self)
        DispatchQueue.global(qos: .utility).async {
            let fixture = fixture.value as! FirstByteURLProtocol
            client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(fixture, didLoad: Self.body.prefix(4))
            _ = Self.releaseFinish.wait(timeout: .now() + 3)
            guard !fixture.isStopped() else { return }
            client?.urlProtocol(fixture, didLoad: Self.body.dropFirst(4))
            client?.urlProtocolDidFinishLoading(fixture)
            Self.stateLock.lock()
            Self.finished = true
            Self.stateLock.unlock()
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        Self.releaseFinish.signal()
    }
}

private final class HTTPErrorURLProtocol: URLProtocol {
    private static let stateLock = NSLock()
    private static var stopCount = 0

    private let stopSignal = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var stopped = false

    static func reset() {
        stateLock.lock()
        stopCount = 0
        stateLock.unlock()
    }

    static var stops: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "http"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 503, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let client = self.client
        let fixture = URLProtocolSendableBox(self)
        DispatchQueue.global(qos: .utility).async {
            let fixture = fixture.value as! HTTPErrorURLProtocol
            client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            _ = fixture.stopSignal.wait(timeout: .now() + 3)
            fixture.stateLock.lock()
            let wasStopped = fixture.stopped
            fixture.stateLock.unlock()
            guard !wasStopped else { return }
            client?.urlProtocol(fixture, didLoad: Data("error body".utf8))
            client?.urlProtocolDidFinishLoading(fixture)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        let shouldRecord = !stopped
        stopped = true
        stateLock.unlock()
        if shouldRecord {
            Self.stateLock.lock()
            Self.stopCount += 1
            Self.stateLock.unlock()
            stopSignal.signal()
        }
    }
}

private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
}

func test_linuxURLSessionStreamingBoundsAndCancellation() async throws {
    // The response continuation must be released at headers, and the first body chunk must be
    // consumable while the fixture deliberately holds the server's finish callback.
    FirstByteURLProtocol.reset()
    let firstConfiguration = URLSessionConfiguration.ephemeral
    firstConfiguration.protocolClasses = [FirstByteURLProtocol.self]
    let firstSession = URLSession(configuration: firstConfiguration)
    let firstRequest = URLRequest(url: URL(string: "http://aviary.invalid/first-byte")!)
    let (firstStream, firstResponse) = try await AviaryURLSession.bytes(
        for: firstRequest, using: firstSession, maxResponseBytes: 64, maxBufferedBytes: 8)
    XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 200)
    var firstIterator = firstStream.makeAsyncIterator()
    let firstByte = try await firstIterator.next()
    XCTAssertEqual(firstByte ?? UInt8.max, 0)
    XCTAssertFalse(FirstByteURLProtocol.didFinish, "first byte arrived only after server finish")
    defer { FirstByteURLProtocol.releaseServerFinish() }
    FirstByteURLProtocol.releaseServerFinish()
    var firstCount = 1
    while try await firstIterator.next() != nil { firstCount += 1 }
    XCTAssertEqual(firstCount, 16)

    // A slow consumer must drain a valid under-cap response without a false overflow. The
    // diagnostics measure queued Data bytes/chunks, not the iterator's individual UInt8 steps.
    let slowConfiguration = URLSessionConfiguration.ephemeral
    slowConfiguration.protocolClasses = [SlowURLProtocol.self]
    let slowSession = URLSession(configuration: slowConfiguration)
    let slowRequest = URLRequest(url: URL(string: "http://aviary.invalid/slow")!)
    let (slowStream, slowResponse) = try await AviaryURLSession.bytes(
        for: slowRequest, using: slowSession, maxResponseBytes: 256, maxBufferedBytes: 16)
    XCTAssertEqual((slowResponse as? HTTPURLResponse)?.statusCode, 200)
    var slowIterator = slowStream.makeAsyncIterator()
    var slowCount = 0
    while try await slowIterator.next() != nil {
        slowCount += 1
        try await Task.sleep(nanoseconds: 500_000)
    }
    XCTAssertEqual(slowCount, 128)
    XCTAssertTrue(slowStream.peakBufferedByteCountForTesting <= 16)
    XCTAssertTrue(slowStream.peakBufferedChunkCountForTesting <= 2)
    XCTAssertEqual(slowStream.bufferedByteCountForTesting, 0)

    // A single callback can be larger than the queue window. The adapter must split it while the
    // callback is synchronously waiting for the consumer, keeping the measured queue peak bounded.
    SingleOversizedChunkURLProtocol.reset()
    let singleChunkConfiguration = URLSessionConfiguration.ephemeral
    singleChunkConfiguration.protocolClasses = [SingleOversizedChunkURLProtocol.self]
    let singleChunkSession = URLSession(configuration: singleChunkConfiguration)
    let singleChunkRequest = URLRequest(url: URL(string: "http://aviary.invalid/single-chunk")!)
    let (singleChunkStream, singleChunkResponse) = try await AviaryURLSession.bytes(
        for: singleChunkRequest, using: singleChunkSession,
        maxResponseBytes: 256, maxBufferedBytes: 16)
    XCTAssertEqual((singleChunkResponse as? HTTPURLResponse)?.statusCode, 200)
    var singleChunkIterator = singleChunkStream.makeAsyncIterator()
    var singleChunkCount = 0
    while try await singleChunkIterator.next() != nil { singleChunkCount += 1 }
    XCTAssertEqual(singleChunkCount, 128)
    XCTAssertEqual(singleChunkStream.acceptedByteCountForTesting, 128)
    XCTAssertTrue(
        singleChunkStream.peakBufferedByteCountForTesting <= 16,
        "one oversized callback exceeded the strict queue window")
    XCTAssertEqual(singleChunkStream.bufferedByteCountForTesting, 0)
    XCTAssertEqual(SingleOversizedChunkURLProtocol.metrics.callbackCount, 1)
    XCTAssertEqual(SingleOversizedChunkURLProtocol.metrics.callbackBytes, 128)
    XCTAssertTrue(SingleOversizedChunkURLProtocol.metrics.callbackReturned)

    // Cancellation must wake a delegate callback that is blocked behind the full buffer limit.
    BlockedProducerURLProtocol.reset()
    let blockedConfiguration = URLSessionConfiguration.ephemeral
    blockedConfiguration.protocolClasses = [BlockedProducerURLProtocol.self]
    let blockedSession = URLSession(configuration: blockedConfiguration)
    let blockedRequest = URLRequest(url: URL(string: "http://aviary.invalid/blocked")!)
    let (blockedStream, blockedResponse) = try await AviaryURLSession.bytes(
        for: blockedRequest, using: blockedSession,
        maxResponseBytes: 64, maxBufferedBytes: 16)
    XCTAssertEqual((blockedResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(await eventually({ BlockedProducerURLProtocol.didEnterBlockedCallback }))
    XCTAssertTrue(
        await eventually({ blockedStream.producerWaitingForTesting }),
        "delegate callback did not wait at the full buffer limit")
    XCTAssertTrue(blockedStream.peakBufferedByteCountForTesting <= 16)
    XCTAssertTrue(blockedStream.peakBufferedChunkCountForTesting <= 2)
    blockedStream.cancel()
    XCTAssertTrue(
        await eventually({ !blockedStream.producerWaitingForTesting }),
        "stream cancellation did not wake the producer callback")
    XCTAssertTrue(await eventually({ BlockedProducerURLProtocol.didReturnFromBlockedCallback }))
    XCTAssertTrue(await eventually({ BlockedProducerURLProtocol.stops > 0 }))

    // A truthful Content-Length is rejected at headers. The fixture waits for cancellation before
    // sending body bytes, proving the delegate stops the request rather than merely reporting an
    // eventual size error after buffering it.
    ContentLengthOversizedURLProtocol.reset()
    let lengthConfiguration = URLSessionConfiguration.ephemeral
    lengthConfiguration.protocolClasses = [ContentLengthOversizedURLProtocol.self]
    let lengthSession = URLSession(configuration: lengthConfiguration)
    let lengthRequest = URLRequest(url: URL(string: "http://aviary.invalid/oversized")!)
    do {
        _ = try await AviaryURLSession.bytes(
            for: lengthRequest, using: lengthSession, maxResponseBytes: 64, maxBufferedBytes: 16)
        XCTFail("Content-Length oversized response unexpectedly returned a stream")
    } catch let error as AviaryURLSession.Error {
        XCTAssertEqual(error, .responseTooLarge(limit: 64))
    } catch {
        XCTFail("unexpected Content-Length error: \(error)")
    }
    XCTAssertTrue(await eventually({ ContentLengthOversizedURLProtocol.metrics().stopCount > 0 }))
    XCTAssertEqual(ContentLengthOversizedURLProtocol.metrics().bodyBytesSent, 0)

    // Without a length header, the delegate accepts only the prefix that fits the total budget,
    // cancels on the first over-budget chunk, and never exposes more than that prefix to the
    // consumer. The fixture emits 8-byte chunks so the full queue limit is independently tested.
    NoLengthOversizedURLProtocol.reset()
    let noLengthConfiguration = URLSessionConfiguration.ephemeral
    noLengthConfiguration.protocolClasses = [NoLengthOversizedURLProtocol.self]
    let noLengthSession = URLSession(configuration: noLengthConfiguration)
    let noLengthRequest = URLRequest(url: URL(string: "http://aviary.invalid/oversized-no-length")!)
    var noLengthStream: AviaryByteStream?
    var noLengthObserved = 0
    do {
        let (stream, _) = try await AviaryURLSession.bytes(
            for: noLengthRequest, using: noLengthSession,
            maxResponseBytes: 64, maxBufferedBytes: 16)
        noLengthStream = stream
        var iterator = stream.makeAsyncIterator()
        while try await iterator.next() != nil { noLengthObserved += 1 }
        XCTFail("no-length oversized response unexpectedly completed")
    } catch let error as AviaryURLSession.Error {
        XCTAssertEqual(error, .responseTooLarge(limit: 64))
    } catch {
        XCTFail("unexpected no-length error: \(error)")
    }
    XCTAssertTrue(noLengthObserved <= 64)
    XCTAssertTrue((noLengthStream?.acceptedByteCountForTesting ?? Int.max) <= 64)
    XCTAssertTrue(await eventually({ NoLengthOversizedURLProtocol.metrics().stopCount > 0 }))
    XCTAssertTrue(NoLengthOversizedURLProtocol.metrics().bodyBytesSent >= 64)

    // Dropping an HTTP-error response must terminate the real task/session even when the caller
    // intentionally does not consume its body.
    HTTPErrorURLProtocol.reset()
    let errorConfiguration = URLSessionConfiguration.ephemeral
    errorConfiguration.protocolClasses = [HTTPErrorURLProtocol.self]
    let errorSession = URLSession(configuration: errorConfiguration)
    let errorRequest = URLRequest(url: URL(string: "http://aviary.invalid/http-error")!)
    let (errorStream, errorResponse) = try await AviaryURLSession.bytes(
        for: errorRequest, using: errorSession, maxResponseBytes: 64, maxBufferedBytes: 16)
    XCTAssertEqual((errorResponse as? HTTPURLResponse)?.statusCode, 503)
    errorStream.cancel()
    XCTAssertTrue(await eventually({ HTTPErrorURLProtocol.stops > 0 }))
}
#endif
