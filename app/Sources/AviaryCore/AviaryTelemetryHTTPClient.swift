import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenTelemetryProtocolExporterHttp

/// Fixed, payload-free failures from the bounded telemetry transport.
internal enum AviaryTelemetryHTTPClientError: Error, Equatable, Sendable {
    case overloaded
    case shutDown
    case invalidResponse
    case nonSuccessStatus
    case responseTooLarge
    case redirectRefused
    case timedOut
    case cancelled
    case transportFailure
}

/// A bounded HTTP adapter for the opt-in OTLP exporter.
///
/// It intentionally retains no response body. URLSession delivers response chunks to the delegate,
/// which counts at most 64 KiB before canceling the task. Errors are reduced to the fixed enum above
/// so a collector response, URL, credential challenge, or Foundation diagnostic cannot enter logs or
/// telemetry through this boundary.
internal final class AviaryTelemetryHTTPClient: OpenTelemetryProtocolExporterHttp.HTTPClient,
    @unchecked Sendable
{
    static let maximumResponseBytes = 64 * 1024
    static let maximumConcurrentRequests = 2
    static let maximumTimeout: TimeInterval = 2

    private struct Pending {
        let task: URLSessionDataTask
        var completion: ((Result<HTTPURLResponse, Error>) -> Void)?
        var response: HTTPURLResponse?
        var receivedBytes = 0
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
        @unchecked Sendable
    {
        weak var owner: AviaryTelemetryHTTPClient?

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let owner else {
                completionHandler(.cancel)
                return
            }
            owner.receive(
                response: response, for: dataTask, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
        ) {
            owner?.receive(data: data, for: dataTask)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let owner else {
                completionHandler(nil)
                return
            }
            owner.refuseRedirect(for: task, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            owner?.complete(task: task, error: error)
        }
    }

    private let lock = NSLock()
    private let responseByteLimit: Int
    private let requestLimit: Int
    private let timeout: TimeInterval
    private let delegate: Delegate
    private let session: URLSession
    private var pending: [Int: Pending] = [:]
    private var isShutDown = false

    internal init(
        configuration template: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int = AviaryTelemetryHTTPClient.maximumResponseBytes,
        maximumConcurrentRequests: Int = AviaryTelemetryHTTPClient.maximumConcurrentRequests,
        timeout: TimeInterval = AviaryTelemetryHTTPClient.maximumTimeout
    ) {
        responseByteLimit = min(max(1, maximumResponseBytes), Self.maximumResponseBytes)
        requestLimit = min(max(1, maximumConcurrentRequests), Self.maximumConcurrentRequests)
        self.timeout = min(max(0.001, timeout), Self.maximumTimeout)

        let configuration = (template.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = self.timeout
        configuration.timeoutIntervalForResource = self.timeout
        configuration.httpMaximumConnectionsPerHost = Self.maximumConcurrentRequests

        let delegate = Delegate()
        let queue = OperationQueue()
        queue.name = "aviary.telemetry.http"
        queue.maxConcurrentOperationCount = 1
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        delegate.owner = self
    }

    deinit {
        shutDown()
    }

    func send(
        request: URLRequest,
        completion: @escaping (Result<HTTPURLResponse, Error>) -> Void
    ) {
        var boundedRequest = request
        boundedRequest.timeoutInterval = min(max(0.001, request.timeoutInterval), timeout)

        lock.lock()
        if isShutDown {
            lock.unlock()
            completion(.failure(AviaryTelemetryHTTPClientError.shutDown))
            return
        }
        guard pending.count < requestLimit else {
            lock.unlock()
            completion(.failure(AviaryTelemetryHTTPClientError.overloaded))
            return
        }
        let task = session.dataTask(with: boundedRequest)
        pending[task.taskIdentifier] = Pending(task: task, completion: completion)
        lock.unlock()
        task.resume()
    }

    /// Cancel all outstanding exporter requests. Removing the completion records first makes the
    /// later URLSession cancellation callbacks harmless and guarantees exactly one completion.
    internal func shutDown() {
        let outstanding: [Pending]
        lock.lock()
        guard !isShutDown else {
            lock.unlock()
            return
        }
        isShutDown = true
        outstanding = Array(pending.values)
        pending.removeAll()
        lock.unlock()

        for item in outstanding { item.task.cancel() }
        session.invalidateAndCancel()
        for item in outstanding {
            item.completion?(.failure(AviaryTelemetryHTTPClientError.cancelled))
        }
    }

    private func receive(
        response: URLResponse, for task: URLSessionDataTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            let completion = claimCompletion(task.taskIdentifier)
            completionHandler(.cancel)
            task.cancel()
            completion?(.failure(AviaryTelemetryHTTPClientError.invalidResponse))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            let completion = claimCompletion(task.taskIdentifier)
            completionHandler(.cancel)
            task.cancel()
            completion?(.failure(AviaryTelemetryHTTPClientError.nonSuccessStatus))
            return
        }
        guard response.expectedContentLength <= Int64(responseByteLimit) else {
            let completion = claimCompletion(task.taskIdentifier)
            completionHandler(.cancel)
            task.cancel()
            completion?(.failure(AviaryTelemetryHTTPClientError.responseTooLarge))
            return
        }

        lock.lock()
        guard var item = pending[task.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        item.response = response
        pending[task.taskIdentifier] = item
        lock.unlock()
        completionHandler(.allow)
    }

    private func receive(data: Data, for task: URLSessionDataTask) {
        var completion: ((Result<HTTPURLResponse, Error>) -> Void)?
        lock.lock()
        guard var item = pending[task.taskIdentifier], item.completion != nil else {
            lock.unlock()
            return
        }
        if data.count > responseByteLimit - item.receivedBytes {
            completion = item.completion
            item.completion = nil
            pending[task.taskIdentifier] = item
        } else {
            item.receivedBytes += data.count
            pending[task.taskIdentifier] = item
        }
        lock.unlock()

        if let completion {
            task.cancel()
            completion(.failure(AviaryTelemetryHTTPClientError.responseTooLarge))
        }
    }

    private func refuseRedirect(
        for task: URLSessionTask, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let completion = claimCompletion(task.taskIdentifier)
        completionHandler(nil)
        guard let completion else { return }
        task.cancel()
        completion(.failure(AviaryTelemetryHTTPClientError.redirectRefused))
    }

    private func complete(task: URLSessionTask, error: Error?) {
        guard let item = takePending(task.taskIdentifier), let completion = item.completion else {
            return
        }
        if let error {
            completion(.failure(Self.fixedFailure(for: error)))
        } else if let response = item.response {
            completion(.success(response))
        } else {
            completion(.failure(AviaryTelemetryHTTPClientError.invalidResponse))
        }
    }

    /// Consume only the callback while retaining the task in the concurrency budget until
    /// URLSession confirms completion. This prevents a stream of refused responses from briefly
    /// exceeding the two-live-request bound while cancellation is still in flight.
    private func claimCompletion(
        _ identifier: Int
    ) -> ((Result<HTTPURLResponse, Error>) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard var item = pending[identifier], let completion = item.completion else { return nil }
        item.completion = nil
        pending[identifier] = item
        return completion
    }

    private func takePending(_ identifier: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: identifier)
    }

    private static func fixedFailure(for error: Error) -> AviaryTelemetryHTTPClientError {
        guard let urlError = error as? URLError else { return .transportFailure }
        switch urlError.code {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        default: return .transportFailure
        }
    }
}
