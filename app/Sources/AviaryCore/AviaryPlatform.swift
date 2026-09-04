import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

#if canImport(Glibc)
// Glibc imports both the `flock(2)` function and the `struct flock` type under the same Swift
// spelling, so the function is not callable as `Glibc.flock`. This declaration is only a thin
// name-boundary for the real libc operation; it does not emulate locking.
@_silgen_name("flock")
private func aviaryLinuxFlock(_ descriptor: Int32, _ operation: Int32) -> Int32
#endif

/// Small cross-platform primitives used by the Work Host boundary.
///
/// CryptoKit is available on macOS but is not part of the Swift Linux toolchain.  Keeping the
/// digest type behind this narrow API lets the shared journal code use the same bytes on both
/// systems without pretending that an unavailable module is present.  The Linux implementation
/// below is the SHA-256 algorithm itself (not a test stub or a zero-filled compatibility value).
public enum AviarySHA256 {
    public struct Digest: Sequence, Hashable, Sendable, CustomStringConvertible {
        fileprivate let bytes: [UInt8]

        fileprivate init(bytes: [UInt8]) {
            precondition(bytes.count == 32)
            self.bytes = bytes
        }

        public var description: String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        public func makeIterator() -> IndexingIterator<[UInt8]> {
            bytes.makeIterator()
        }
    }

    public static func hash(data: Data) -> Digest {
        #if canImport(CryptoKit)
        return Digest(bytes: Array(CryptoKit.SHA256.hash(data: data)))
        #else
        return Digest(bytes: SHA256Implementation.hash(data))
        #endif
    }
}

/// OS-backed random bytes for protocol identities and other security-sensitive nonces.
///
/// Linux uses the kernel's `/dev/urandom` source.  macOS uses Security.framework's
/// `SecRandomCopyBytes`.  Neither branch falls back to a pseudo-random generator.
public enum AviarySecureRandom {
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidCount
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .invalidCount: return "Random byte count is invalid."
            case .unavailable: return "The operating system secure random source is unavailable."
            }
        }
    }

    public static func bytes(count: Int) throws -> [UInt8] {
        guard count >= 0, count <= 1_048_576 else { throw Error.invalidCount }
        guard count > 0 else { return [] }

        #if canImport(Security)
        var result = [UInt8](repeating: 0, count: count)
        let status = result.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Error.unavailable }
        return result
        #else
        // FileHandle reads from the kernel device directly.  Read until the requested bounded
        // count is filled because a device read is permitted to return a short Data value.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/urandom"))
        } catch {
            throw Error.unavailable
        }
        defer { try? handle.close() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            do {
                guard let chunk = try handle.read(upToCount: count - result.count),
                      !chunk.isEmpty else {
                    throw Error.unavailable
                }
                result.append(chunk)
            } catch let error as Error {
                throw error
            } catch {
                throw Error.unavailable
            }
        }
        return Array(result)
        #endif
    }

    /// A UUID-shaped identifier sourced from the operating system CSPRNG.
    public static func uuidString() -> String {
        guard var bytes = try? bytes(count: 16) else {
            // Foundation's UUID is itself OS-backed.  This branch is only an emergency fallback
            // for an unavailable device and never manufactures deterministic bytes.
            return UUID().uuidString.lowercased()
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20)),
        ]
        return parts.joined(separator: "-")
    }
}

/// A small URLSession streaming seam for the provider implementations.
///
/// FoundationNetworking on Linux currently exposes ``data(for:)`` but not Apple's
/// ``bytes(for:)``. Linux therefore uses a delegate-backed byte stream with a strict response
/// budget, canceling the real request as soon as that budget is crossed. Darwin keeps the
/// incremental URLSession byte stream supplied by Foundation.
public enum AviaryURLSession {
    /// The Linux delegate path bounds application-held response bytes while preserving the
    /// existing Darwin AsyncBytes behavior. Callers can lower this for a stricter provider
    /// budget; the default is deliberately finite for headless execution. Linux also keeps a
    /// separate bounded chunk window so a live response can be consumed before its HTTP body
    /// finishes.
    public static let defaultMaximumResponseBytes = 8 * 1024 * 1024
    public static let defaultMaximumBufferedBytes = 64 * 1024

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidMaximumResponseBytes
        case responseTooLarge(limit: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidMaximumResponseBytes:
                return "The URL response byte limit is invalid."
            case .responseTooLarge(let limit):
                return "The URL response exceeded the \(limit)-byte limit."
            }
        }
    }

    public static func bytes(
        for request: URLRequest, using session: URLSession,
        maxResponseBytes: Int = defaultMaximumResponseBytes,
        maxBufferedBytes: Int = defaultMaximumBufferedBytes
    ) async throws -> (AviaryByteStream, URLResponse) {
        guard maxResponseBytes > 0, maxBufferedBytes > 0 else {
            throw Error.invalidMaximumResponseBytes
        }
        #if os(Linux)
        // FoundationNetworking does not expose URLSession.AsyncBytes on Linux. Recreating the
        // session with a data delegate lets us cancel as soon as the bounded response budget is
        // crossed; `data(for:)` would allocate the complete body before this seam could inspect
        // it. The delegate publishes its response at headers, then makes the serial delegate
        // callback wait behind the full bounded queue when the consumer is slow. This keeps
        // storage bounded by the response budget plus at most one in-flight callback chunk,
        // rather than millions of individually buffered UInt8 elements, without relying on
        // URLSession's suspension counter to make progress.
        let delegate = BoundedLinuxURLSessionDelegate(
            maximumBytes: maxResponseBytes,
            maximumBufferedBytes: min(maxBufferedBytes, maxResponseBytes))
        return try await delegate.start(request: request, template: session)
        #else
        _ = maxResponseBytes
        _ = maxBufferedBytes
        let (bytes, response) = try await session.bytes(for: request)
        // Preserve Foundation's native demand-driven iterator. Re-pumping it through a default
        // AsyncThrowingStream would introduce an unbounded application buffer on Darwin while
        // presenting this API as a streaming seam.
        return (AviaryByteStream(native: bytes), response)
        #endif
    }
}

/// A byte-oriented async sequence whose Linux representation is a bounded Data-chunk queue and
/// whose Darwin representation retains the native incremental stream. Keeping the Linux
/// iterator over Data avoids per-byte AsyncStream bookkeeping while preserving provider call
/// sites (`for try await byte in bytes`).
public struct AviaryByteStream: AsyncSequence, Sendable {
    public typealias Element = UInt8

    #if os(Linux)
    private let state: LinuxByteStreamState
    private let lifetime: LinuxByteStreamLifetime

    fileprivate init(state: LinuxByteStreamState) {
        self.state = state
        self.lifetime = LinuxByteStreamLifetime(state: state)
    }
    #else
    private let native: URLSession.AsyncBytes

    fileprivate init(native: URLSession.AsyncBytes) {
        self.native = native
    }
    #endif

    public struct AsyncIterator: AsyncIteratorProtocol {
        #if os(Linux)
        private let state: LinuxByteStreamState
        // The iterator owns one Data chunk at a time. The queue itself never stores individual
        // bytes; this local chunk is the one in-flight consumer chunk while it is being parsed.
        private let lifetime: LinuxByteStreamLifetime
        private var chunk: Data?
        private var offset: Int = 0

        fileprivate init(state: LinuxByteStreamState, lifetime: LinuxByteStreamLifetime) {
            self.state = state
            self.lifetime = lifetime
        }

        public mutating func next() async throws -> UInt8? {
            while true {
                if Task.isCancelled {
                    state.cancel()
                    throw CancellationError()
                }
                if let chunk, offset < chunk.count {
                    defer { offset += 1 }
                    return chunk[chunk.index(chunk.startIndex, offsetBy: offset)]
                }
                self.chunk = try await state.nextChunk()
                offset = 0
                if self.chunk == nil { return nil }
            }
        }
        #else
        private var native: URLSession.AsyncBytes.AsyncIterator

        fileprivate init(native: URLSession.AsyncBytes) {
            self.native = native.makeAsyncIterator()
        }

        public mutating func next() async throws -> UInt8? {
            try await native.next()
        }
        #endif
    }

    public func makeAsyncIterator() -> AsyncIterator {
        #if os(Linux)
        return AsyncIterator(state: state, lifetime: lifetime)
        #else
        return AsyncIterator(native: native)
        #endif
    }

    /// Stop a response that the caller no longer intends to consume (for example after an HTTP
    /// error status). Linux cancels the underlying URLSession task; Darwin's native stream keeps
    /// its existing cancellation semantics through the surrounding URLSession task.
    public func cancel() {
        #if os(Linux)
        lifetime.cancel()
        #endif
    }

    #if os(Linux)
    // Internal diagnostics are deliberately test-only seams. They let the Linux self-test
    // assert the bounded queue contract without making security/resource accounting part of the
    // public Work protocol.
    var bufferedByteCountForTesting: Int { state.bufferedByteCount }
    var bufferedChunkCountForTesting: Int { state.bufferedChunkCount }
    var peakBufferedByteCountForTesting: Int { state.peakBufferedByteCount }
    var peakBufferedChunkCountForTesting: Int { state.peakBufferedChunkCount }
    var acceptedByteCountForTesting: Int { state.acceptedByteCount }
    var producerWaitingForTesting: Bool { state.producerWaitingForTesting }
    #endif
}

#if os(Linux)
private final class LinuxByteStreamLifetime: @unchecked Sendable {
    private let state: LinuxByteStreamState

    init(state: LinuxByteStreamState) {
        self.state = state
    }

    func cancel() {
        state.cancel()
    }

    deinit {
        state.cancel()
    }
}

/// FoundationNetworking schedules delegate callbacks as operations on the delegate queue. A
/// serial queue alone does not bound that operation backlog: the libcurl work queue can enqueue
/// many `didReceive` operations while the first one is waiting for the consumer. This gate keeps
/// one callback operation in flight and blocks the producer at `addOperation` until that callback
/// finishes, so the condition wait below also applies at the transport boundary.
private final class BoundedLinuxDelegateQueue: OperationQueue, @unchecked Sendable {
    private let slot = DispatchSemaphore(value: 1)

    override init() {
        super.init()
        maxConcurrentOperationCount = 1
    }

    override func addOperation(_ op: Operation) {
        slot.wait()
        let priorCompletion = op.completionBlock
        op.completionBlock = { [weak self] in
            // Release before running a caller completion block so a completion callback may
            // enqueue follow-up work without self-deadlocking on the single slot.
            self?.slot.signal()
            priorCompletion?()
        }
        super.addOperation(op)
    }

    override func addOperations(_ ops: [Operation], waitUntilFinished wait: Bool) {
        for op in ops { addOperation(op) }
        if wait { waitUntilAllOperationsAreFinished() }
    }
}

private final class LinuxByteStreamState: @unchecked Sendable {
    private let maximumBytes: Int
    private let bufferLimit: Int
    private let condition = NSCondition()

    private var chunks: [Data] = []
    private var firstChunkIndex = 0
    private var bufferedBytes = 0
    private var totalReceivedBytes = 0
    private var peakBufferedBytesValue = 0
    private var peakBufferedChunkCountValue = 0
    private var producerWaitingValue = false
    private var nextChunkWaiter: CheckedContinuation<Data?, Swift.Error>?
    private var responseWaiter: CheckedContinuation<(AviaryByteStream, URLResponse), Swift.Error>?
    private var finished = false
    private var terminalError: Swift.Error?
    // The URLSession retains its delegate (which retains this state). Weak links avoid a
    // state-session-delegate cycle so dropping a response stream can cancel promptly.
    private weak var task: URLSessionDataTask?
    private weak var session: URLSession?

    init(maximumBytes: Int, maximumBufferedBytes: Int) {
        self.maximumBytes = maximumBytes
        self.bufferLimit = max(1, maximumBufferedBytes)
    }

    func install(
        responseWaiter: CheckedContinuation<(AviaryByteStream, URLResponse), Swift.Error>,
        request: URLRequest,
        template: URLSession,
        delegate: URLSessionDataDelegate
    ) {
        condition.lock()
        if finished {
            let error = terminalError ?? CancellationError()
            condition.unlock()
            responseWaiter.resume(throwing: error)
            return
        }
        self.responseWaiter = responseWaiter
        let configuration = template.configuration
        let delegateQueue = BoundedLinuxDelegateQueue()
        let ownedSession = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        self.session = ownedSession
        let task = ownedSession.dataTask(with: request)
        self.task = task
        condition.unlock()
        task.resume()
    }

    /// The response continuation is resumed as soon as headers arrive. A known body larger than
    /// the total budget is refused before any body callback is accepted.
    func receiveResponse(_ response: URLResponse) -> URLSession.ResponseDisposition {
        var continuation: CheckedContinuation<(AviaryByteStream, URLResponse), Swift.Error>?
        var taskToCancel: URLSessionDataTask?
        var sessionToInvalidate: URLSession?

        condition.lock()
        guard !finished else {
            condition.unlock()
            return .cancel
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            let error = AviaryURLSession.Error.responseTooLarge(limit: maximumBytes)
            finished = true
            terminalError = error
            clearQueuedChunks()
            continuation = responseWaiter
            responseWaiter = nil
            let nextWaiter = nextChunkWaiter
            nextChunkWaiter = nil
            taskToCancel = task
            sessionToInvalidate = session
            condition.broadcast()
            condition.unlock()
            continuation?.resume(throwing: error)
            nextWaiter?.resume(throwing: error)
            cancelTaskOutsideDelegateQueue(taskToCancel)
            invalidateSessionOutsideDelegateQueue(sessionToInvalidate)
            return .cancel
        }

        continuation = responseWaiter
        responseWaiter = nil
        condition.unlock()
        continuation?.resume(returning: (AviaryByteStream(state: self), response))
        return .allow
    }

    /// Accept one delegate callback. URLSession invokes these callbacks serially for this
    /// delegate queue, so waiting here applies backpressure directly at the callback boundary.
    /// Every queued piece is split to fit the remaining buffer capacity; unlike a high-water
    /// trigger, ``bufferedBytes`` therefore never exceeds the configured window even when one
    /// callback delivers a much larger Data value. Cancellation broadcasts so a producer callback
    /// can never be stranded behind a dead consumer.
    func receiveData(_ data: Data) {
        guard !data.isEmpty else { return }

        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        let remaining = maximumBytes - totalReceivedBytes
        guard data.count <= remaining else {
            let error = AviaryURLSession.Error.responseTooLarge(limit: maximumBytes)
            finished = true
            terminalError = error
            clearQueuedChunks()
            let continuation = nextChunkWaiter
            nextChunkWaiter = nil
            let headerWaiter = responseWaiter
            responseWaiter = nil
            let taskToCancel = task
            let sessionToInvalidate = session
            condition.broadcast()
            condition.unlock()
            continuation?.resume(throwing: error)
            headerWaiter?.resume(throwing: error)
            cancelTaskOutsideDelegateQueue(taskToCancel)
            invalidateSessionOutsideDelegateQueue(sessionToInvalidate)
            return
        }

        totalReceivedBytes += data.count
        condition.unlock()

        var offset = 0
        while offset < data.count {
            var continuation: CheckedContinuation<Data?, Swift.Error>?
            var deliveredChunk: Data?
            var shouldStop = false

            condition.lock()
            while !finished {
                // ``nextChunkWaiter`` is installed only when the queue is empty. Delivering a
                // bounded piece directly avoids an unnecessary queue round-trip and still keeps
                // the consumer's in-flight Data within the same limit.
                if let nextChunkWaiter, bufferedBytes == 0 {
                    let length = min(bufferLimit, data.count - offset)
                    self.nextChunkWaiter = nil
                    continuation = nextChunkWaiter
                    deliveredChunk = Data(data.dropFirst(offset).prefix(length))
                    offset += length
                    break
                }

                let available = bufferLimit - bufferedBytes
                if available > 0 {
                    let length = min(available, data.count - offset)
                    let chunk = Data(data.dropFirst(offset).prefix(length))
                    chunks.append(chunk)
                    bufferedBytes += length
                    peakBufferedBytesValue = max(peakBufferedBytesValue, bufferedBytes)
                    peakBufferedChunkCountValue = max(
                        peakBufferedChunkCountValue, currentBufferedChunkCount)
                    offset += length
                    break
                }

                producerWaitingValue = true
                condition.wait()
                producerWaitingValue = false
            }
            shouldStop = finished
            condition.unlock()

            if let continuation, let deliveredChunk {
                continuation.resume(returning: deliveredChunk)
            }
            if shouldStop { return }
        }
    }

    func nextChunk() async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data?, Swift.Error>) in
                var immediate: Result<Data?, Swift.Error>?

                condition.lock()
                if let chunk = dequeueChunk() {
                    immediate = .success(chunk)
                } else if finished {
                    if let terminalError {
                        immediate = .failure(terminalError)
                    } else {
                        immediate = .success(nil)
                    }
                } else if nextChunkWaiter != nil {
                    immediate = .failure(AviaryByteStreamError.concurrentIteration)
                } else {
                    nextChunkWaiter = continuation
                }
                condition.unlock()

                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        }, onCancel: {
            self.cancel()
        })
    }

    func cancel() {
        var nextWaiter: CheckedContinuation<Data?, Swift.Error>?
        var headerWaiter: CheckedContinuation<(AviaryByteStream, URLResponse), Swift.Error>?
        var taskToCancel: URLSessionDataTask?
        var sessionToInvalidate: URLSession?

        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        terminalError = CancellationError()
        clearQueuedChunks()
        nextWaiter = nextChunkWaiter
        nextChunkWaiter = nil
        headerWaiter = responseWaiter
        responseWaiter = nil
        taskToCancel = task
        sessionToInvalidate = session
        condition.broadcast()
        condition.unlock()

        nextWaiter?.resume(throwing: CancellationError())
        headerWaiter?.resume(throwing: CancellationError())
        taskToCancel?.cancel()
        sessionToInvalidate?.invalidateAndCancel()
    }

    func complete(error: Swift.Error?) {
        var nextWaiter: CheckedContinuation<Data?, Swift.Error>?
        var headerWaiter: CheckedContinuation<(AviaryByteStream, URLResponse), Swift.Error>?
        var sessionToInvalidate: URLSession?
        var success = false

        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        if let error {
            terminalError = error
            clearQueuedChunks()
            nextWaiter = nextChunkWaiter
            nextChunkWaiter = nil
        } else {
            success = true
            if bufferedBytes == 0 {
                nextWaiter = nextChunkWaiter
                nextChunkWaiter = nil
            }
        }
        if responseWaiter != nil {
            headerWaiter = responseWaiter
            responseWaiter = nil
        }
        sessionToInvalidate = session
        condition.broadcast()
        condition.unlock()

        if let error {
            nextWaiter?.resume(throwing: error)
        } else if success {
            nextWaiter?.resume(returning: nil)
        }
        if let error {
            headerWaiter?.resume(throwing: error)
        } else {
            headerWaiter?.resume(throwing: URLError(.badServerResponse))
        }
        finishSessionOutsideDelegateQueue(sessionToInvalidate)
    }

    var bufferedByteCount: Int {
        condition.lock(); defer { condition.unlock() }
        return bufferedBytes
    }

    var bufferedChunkCount: Int {
        condition.lock(); defer { condition.unlock() }
        return currentBufferedChunkCount
    }

    var peakBufferedByteCount: Int {
        condition.lock(); defer { condition.unlock() }
        return peakBufferedBytesValue
    }

    var peakBufferedChunkCount: Int {
        condition.lock(); defer { condition.unlock() }
        return peakBufferedChunkCountValue
    }

    var acceptedByteCount: Int {
        condition.lock(); defer { condition.unlock() }
        return totalReceivedBytes
    }

    var producerWaitingForTesting: Bool {
        condition.lock(); defer { condition.unlock() }
        return producerWaitingValue
    }

    private var currentBufferedChunkCount: Int {
        chunks.count - firstChunkIndex
    }

    private func dequeueChunk() -> Data? {
        guard firstChunkIndex < chunks.count else { return nil }
        let chunk = chunks[firstChunkIndex]
        firstChunkIndex += 1
        bufferedBytes -= chunk.count
        if firstChunkIndex > 32 && firstChunkIndex * 2 > chunks.count {
            chunks.removeFirst(firstChunkIndex)
            firstChunkIndex = 0
        }
        // Wake a producer callback after every dequeue. It rechecks the strict buffer capacity
        // under the same lock, so spurious wakeups and a partial drain cannot over-admit data.
        condition.broadcast()
        return chunk
    }

    private func clearQueuedChunks() {
        chunks.removeAll(keepingCapacity: false)
        firstChunkIndex = 0
        bufferedBytes = 0
    }

    /// Corelibs URLSession's invalidation path synchronously touches its work queue. A delegate
    /// callback is itself running behind ``BoundedLinuxDelegateQueue``; invalidating inline here
    /// would let the work queue wait for this callback's slot while this callback waits for the
    /// work queue. Schedule the session operation after the callback has released its slot.
    private func invalidateSessionOutsideDelegateQueue(_ session: URLSession?) {
        guard let session else { return }
        DispatchQueue.global(qos: .utility).async {
            session.invalidateAndCancel()
        }
    }

    private func cancelTaskOutsideDelegateQueue(_ task: URLSessionDataTask?) {
        guard let task else { return }
        DispatchQueue.global(qos: .utility).async {
            task.cancel()
        }
    }

    private func finishSessionOutsideDelegateQueue(_ session: URLSession?) {
        guard let session else { return }
        DispatchQueue.global(qos: .utility).async {
            session.finishTasksAndInvalidate()
        }
    }
}

private enum AviaryByteStreamError: Swift.Error {
    case concurrentIteration
}

private final class BoundedLinuxURLSessionDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable {
    private let state: LinuxByteStreamState

    init(maximumBytes: Int, maximumBufferedBytes: Int) {
        self.state = LinuxByteStreamState(
            maximumBytes: maximumBytes, maximumBufferedBytes: maximumBufferedBytes)
    }

    func start(
        request: URLRequest, template: URLSession
    ) async throws -> (AviaryByteStream, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (waiter: CheckedContinuation<(AviaryByteStream, URLResponse), Swift.Error>) in
                state.install(
                    responseWaiter: waiter,
                    request: request,
                    template: template,
                    delegate: self)
            }
        }, onCancel: {
            self.state.cancel()
        })

    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(state.receiveResponse(response))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.receiveData(data)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?
    ) {
        state.complete(error: error)
    }
}
#endif

/// The small POSIX seam shared by the headless Work Host sources.
///
/// The daemon only needs descriptor close/read, Unix stream socket creation, and an exclusive
/// lock. Keeping those differences here makes the platform choices explicit: Darwin's
/// ``O_EXLOCK`` is replaced by a blocking ``flock(LOCK_EX)`` on Linux, and Linux's typed
/// ``SOCK_STREAM`` is normalized before it reaches ``socket(2)``. No emulated filesystem or
/// socket behavior is provided.
public enum AviaryPOSIX {
    /// Flags used for non-blocking stream writes. Linux has no ``SO_NOSIGPIPE`` socket option,
    /// so ``MSG_NOSIGNAL`` is part of every send there; Darwin uses its socket option instead.
    public static var sendFlags: Int32 {
        #if canImport(Glibc)
        return Int32(MSG_DONTWAIT) | Int32(MSG_NOSIGNAL)
        #else
        return Int32(MSG_DONTWAIT)
        #endif
    }

    public static func open(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, flags)
        #elseif canImport(Glibc)
        return Glibc.open(path, flags)
        #else
        return -1
        #endif
    }

    public static func close(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(descriptor)
        #elseif canImport(Glibc)
        return Glibc.close(descriptor)
        #else
        return -1
        #endif
    }

    public static func read(
        _ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.read(descriptor, buffer, count)
        #else
        return -1
        #endif
    }

    public static func write(
        _ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.write(descriptor, buffer, count)
        #else
        return -1
        #endif
    }

    public static func streamSocket() -> Int32 {
        #if canImport(Darwin)
        return Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #elseif canImport(Glibc)
        return Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        return -1
        #endif
    }

    /// Apply the platform's no-SIGPIPE policy to a connected socket.
    ///
    /// Darwin has ``SO_NOSIGPIPE``. Linux has no socket option by that name; the transport uses
    /// ``MSG_NOSIGNAL`` for each send instead, so this operation is intentionally a no-op there.
    public static func setNoSigPipe(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        return withUnsafePointer(to: &enabled) {
            Darwin.setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0,
                socklen_t(MemoryLayout<Int32>.size))
        }
        #else
        _ = descriptor
        return 0
        #endif
    }

/// Open a private lock file and hold an exclusive lock for its lifetime.
    public static func openExclusiveLock(
        _ path: UnsafePointer<CChar>, flags: Int32, mode: mode_t
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, flags | O_EXLOCK, mode)
        #elseif canImport(Glibc)
        let descriptor = Glibc.open(path, flags, mode)
        guard descriptor >= 0 else { return descriptor }
        guard aviaryLinuxFlock(descriptor, Int32(LOCK_EX)) == 0 else {
            _ = Glibc.close(descriptor)
            return -1
        }
        return descriptor
        #else
        return -1
        #endif
    }
}

private enum SHA256Implementation {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    static func hash(_ input: Data) -> [UInt8] {
        var bytes = Array(input)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }

        var state = initialState
        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var schedule = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                schedule[index] = UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3])
            }
            for index in 16..<64 {
                let value = schedule[index - 15]
                let sigma0 = value.rotateRight(7) ^ value.rotateRight(18) ^ (value >> 3)
                let previous = schedule[index - 2]
                let sigma1 = previous.rotateRight(17) ^ previous.rotateRight(19) ^ (previous >> 10)
                schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]
            for index in 0..<64 {
                let sigma1 = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
                let choice = (e & f) ^ ((~e) & g)
                let temporary1 = h &+ sigma1 &+ choice &+ roundConstants[index]
                    &+ schedule[index]
                let sigma0 = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sigma0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        return state.flatMap { value in
            [
                UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
            ]
        }
    }
}

private extension UInt32 {
    func rotateRight(_ amount: UInt32) -> UInt32 {
        (self >> amount) | (self << (32 - amount))
    }
}
