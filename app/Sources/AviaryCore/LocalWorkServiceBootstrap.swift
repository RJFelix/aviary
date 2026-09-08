import Foundation
import Dispatch

private final class LocalWorkServiceBootstrapWait<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Explicit failures from local Work-service bootstrap. A GUI can render these without
/// confusing a missing daemon, incompatible daemon, and a launch helper failure.
public enum LocalWorkServiceBootstrapError: Error, LocalizedError, Equatable, Sendable {
    case launcherUnavailable
    case launchFailed
    case launcherFailed(LocalAviaryDaemonLauncherError)
    case timedOut
    case discoveryFailed
    case transportFailed
    case connectionFailed(WorkServiceClientSessionError)
    case canceled

    public var errorDescription: String? {
        switch self {
        case .launcherUnavailable: return "No local Work Host launcher was supplied."
        case .launchFailed: return "The local Work Host could not be launched."
        case .launcherFailed(let error):
            return error.errorDescription ?? "The local Work Host could not be launched."
        case .timedOut: return "The local Work Host did not become reachable before the timeout."
        case .discoveryFailed: return "The local Work Host could not be discovered."
        case .transportFailed: return "The local Work Host connection failed at the transport boundary."
        case .connectionFailed(let error): return "The local Work Host connection failed: \(error)"
        case .canceled: return "Work Host bootstrap was canceled."
        }
    }
}

/// Connects a GUI to a local Work Host, starting an injected helper only when discovery cannot
/// produce a usable connection. The helper is deliberately fire-and-forget from this boundary:
/// this coordinator owns neither the daemon process nor Work/Session lifecycle. A GUI closing
/// or calling ``disconnect()`` only closes its client connection.
public actor LocalWorkServiceBootstrap {
    public typealias Launcher = @Sendable () async throws -> Void

    private struct Pending: Sendable {
        let token: UInt64
        let task: Task<WorkServiceClientSession, Error>
        var waiterCount: Int
    }

    public let client: ClientRef
    public let session: WorkServiceClientSession

    private let launcher: Launcher?
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let attemptCompletionGate: (@Sendable () async -> Void)?
    private let waiterResultGate: (@Sendable () async -> Void)?
    private var pending: Pending?
    private var activeAttemptToken: UInt64?
    private var nextToken: UInt64 = 0

    public init(
        locator: any WorkServiceHostLocating,
        client: ClientRef,
        build: String? = nil,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.05,
        launcher: Launcher? = nil,
        connectionFactory: @escaping WorkServiceClientSession.ConnectionFactory =
            { @Sendable location, client in
                try await WorkServiceClientSession.unixConnection(location, client)
            }
    ) throws {
        self.client = client
        self.session = try WorkServiceClientSession(
            locator: locator, client: client, build: build,
            connectionFactory: connectionFactory)
        self.timeout = Self.boundTimeout(timeout)
        self.pollInterval = Self.boundPollInterval(pollInterval)
        self.launcher = launcher
        self.attemptCompletionGate = nil
        self.waiterResultGate = nil
    }

    /// Internal seam used to place an explicit disconnect after transport establishment but
    /// before a shared attempt publishes success. Production callers use the public initializer.
    init(
        locator: any WorkServiceHostLocating,
        client: ClientRef,
        build: String? = nil,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.05,
        launcher: Launcher? = nil,
        attemptCompletionGate: (@Sendable () async -> Void)?,
        waiterResultGate: (@Sendable () async -> Void)? = nil,
        connectionFactory: @escaping WorkServiceClientSession.ConnectionFactory =
            { @Sendable location, client in
                try await WorkServiceClientSession.unixConnection(location, client)
            }
    ) throws {
        self.client = client
        self.session = try WorkServiceClientSession(
            locator: locator, client: client, build: build,
            connectionFactory: connectionFactory)
        self.timeout = Self.boundTimeout(timeout)
        self.pollInterval = Self.boundPollInterval(pollInterval)
        self.launcher = launcher
        self.attemptCompletionGate = attemptCompletionGate
        self.waiterResultGate = waiterResultGate
    }

    public init(
        locator: any WorkServiceHostLocating,
        identityStore: WorkServiceClientIdentityStore,
        build: String? = nil,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.05,
        launcher: Launcher? = nil,
        connectionFactory: @escaping WorkServiceClientSession.ConnectionFactory =
            { @Sendable location, client in
                try await WorkServiceClientSession.unixConnection(location, client)
            }
    ) throws {
        try self.init(
            locator: locator, client: identityStore.loadOrCreate(), build: build,
            timeout: timeout, pollInterval: pollInterval, launcher: launcher,
            connectionFactory: connectionFactory)
    }

    /// Concurrent callers share one discovery/launch/connect operation. No operation is replayed
    /// after a transport loss; callers retain the session and reconcile mutations explicitly.
    @discardableResult
    public func connect() async throws -> WorkServiceClientSession {
        if case .connected = await session.state {
            return session
        }
        if var shared = pending {
            shared.waiterCount += 1
            pending = shared
            return try await finish(shared)
        }
        nextToken = nextToken == UInt64.max ? 1 : nextToken + 1
        let token = nextToken
        let session = self.session
        let launcher = self.launcher
        let timeout = self.timeout
        let pollInterval = self.pollInterval
        let completionGate = attemptCompletionGate
        let task = Task<WorkServiceClientSession, Error> {
            let result = try await Self.establish(
                session: session, launcher: launcher,
                timeout: timeout, pollInterval: pollInterval)
            await completionGate?()
            return result
        }
        let attempt = Pending(token: token, task: task, waiterCount: 1)
        pending = attempt
        activeAttemptToken = token
        return try await finish(attempt)
    }

    /// Disconnects this GUI only. It never calls a Work lifecycle command and never terminates
    /// the injected helper; a later GUI can discover and attach to the same daemon.
    public func disconnect() async {
        activeAttemptToken = nil
        pending?.task.cancel()
        pending = nil
        await session.disconnect()
    }

    private func finish(_ attempt: Pending) async throws -> WorkServiceClientSession {
        let result: WorkServiceClientSession
        do {
            result = try await Self.waitForSharedTask(attempt.task)
        } catch {
            // A canceled waiter leaves the shared attempt intact for other coalesced callers.
            // Explicit disconnect invalidates the token before canceling the shared task.
            if Task.isCancelled {
                await releaseCanceledWaiter(attempt)
                throw LocalWorkServiceBootstrapError.canceled
            }
            guard activeAttemptToken == attempt.token else {
                throw LocalWorkServiceBootstrapError.canceled
            }
            releaseWaiter(attempt)
            if error is CancellationError {
                throw LocalWorkServiceBootstrapError.canceled
            }
            throw error
        }
        await waiterResultGate?()
        guard !Task.isCancelled else {
            await releaseCanceledWaiter(attempt)
            throw LocalWorkServiceBootstrapError.canceled
        }
        guard activeAttemptToken == attempt.token else {
            throw LocalWorkServiceBootstrapError.canceled
        }
        guard case .connected = await session.state else {
            releaseWaiter(attempt)
            throw LocalWorkServiceBootstrapError.connectionFailed(.notConnected)
        }
        releaseWaiter(attempt)
        return result
    }

    private func releaseWaiter(_ attempt: Pending) {
        guard var current = pending, current.token == attempt.token else { return }
        current.waiterCount -= 1
        pending = current.waiterCount > 0 ? current : nil
    }

    private func releaseCanceledWaiter(_ attempt: Pending) async {
        guard var current = pending, current.token == attempt.token else { return }
        current.waiterCount -= 1
        guard current.waiterCount == 0 else {
            pending = current
            return
        }
        pending = nil
        activeAttemptToken = nil
        current.task.cancel()
        await session.disconnect()
    }

    private static func waitForSharedTask(
        _ task: Task<WorkServiceClientSession, Error>
    ) async throws -> WorkServiceClientSession {
        let wait = LocalWorkServiceBootstrapWait<WorkServiceClientSession>()
        Task.detached {
            do { wait.resolve(.success(try await task.value)) }
            catch { wait.resolve(.failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await wait.value()
        } onCancel: {
            wait.resolve(.failure(CancellationError()))
        }
    }

    private static func establish(
        session: WorkServiceClientSession,
        launcher: Launcher?,
        timeout: TimeInterval,
        pollInterval: TimeInterval
    ) async throws -> WorkServiceClientSession {
        do {
            _ = try await session.connect()
            return session
        } catch is CancellationError {
            throw LocalWorkServiceBootstrapError.canceled
        } catch WorkServiceClientSessionError.incompatibleProtocol {
            throw LocalWorkServiceBootstrapError.connectionFailed(.incompatibleProtocol)
        } catch WorkServiceClientSessionError.hostInstanceMismatch {
            // A descriptor can be replaced between discovery and the handshake. Give the
            // locator a bounded chance to publish and return the new generation; accepting the
            // stale candidate itself is never allowed.
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(timeout * 1_000_000_000)
            while true {
                try Task.checkCancellation()
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    throw LocalWorkServiceBootstrapError.connectionFailed(.hostInstanceMismatch)
                }
                let sleep = min(UInt64(pollInterval * 1_000_000_000), deadline - now)
                do { try await Task.sleep(nanoseconds: sleep) }
                catch { throw LocalWorkServiceBootstrapError.canceled }
                do {
                    _ = try await session.connect()
                    return session
                } catch WorkServiceClientSessionError.hostInstanceMismatch {
                    continue
                } catch WorkServiceClientSessionError.incompatibleProtocol {
                    throw LocalWorkServiceBootstrapError.connectionFailed(.incompatibleProtocol)
                } catch WorkServiceClientSessionError.unavailable {
                    throw LocalWorkServiceBootstrapError.connectionFailed(.unavailable)
                } catch let error as WorkServiceClientSessionError {
                    throw LocalWorkServiceBootstrapError.connectionFailed(error)
                } catch {
                    throw LocalWorkServiceBootstrapError.transportFailed
                }
            }
        } catch WorkServiceClientSessionError.unavailable {
            // A missing or not-yet-reachable daemon is the only condition which authorizes
            // invoking the injected launcher below.
        } catch WorkServiceTransportError.endpointUnavailable {
            // A discovery record can outlive an abruptly stopped daemon.  The transport has
            // proved that this was a pre-handshake dead endpoint, so starting a replacement is
            // as safe as starting after an absent discovery record.  Other transport failures
            // remain fail-closed: they may belong to a live but incompatible or unhealthy host.
        } catch let error as WorkServiceClientSessionError {
            throw LocalWorkServiceBootstrapError.connectionFailed(error)
        } catch {
            throw LocalWorkServiceBootstrapError.transportFailed
        }

        guard let launcher else { throw LocalWorkServiceBootstrapError.launcherUnavailable }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        try await runLauncher(launcher, deadline: deadline)
        while true {
            try Task.checkCancellation()
            do {
                _ = try await session.connect()
                return session
            } catch WorkServiceClientSessionError.incompatibleProtocol {
                throw LocalWorkServiceBootstrapError.connectionFailed(.incompatibleProtocol)
            } catch WorkServiceClientSessionError.hostInstanceMismatch {
                throw LocalWorkServiceBootstrapError.connectionFailed(.hostInstanceMismatch)
            } catch WorkServiceClientSessionError.unavailable {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw LocalWorkServiceBootstrapError.timedOut }
                let sleep = min(UInt64(pollInterval * 1_000_000_000), deadline - now)
                do { try await Task.sleep(nanoseconds: sleep) }
                catch { throw LocalWorkServiceBootstrapError.canceled }
            } catch WorkServiceTransportError.endpointUnavailable {
                // The replacement daemon publishes atomically, but polling may still race the
                // old descriptor before that publication.  Keep retrying within the same bound.
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw LocalWorkServiceBootstrapError.timedOut }
                let sleep = min(UInt64(pollInterval * 1_000_000_000), deadline - now)
                do { try await Task.sleep(nanoseconds: sleep) }
                catch { throw LocalWorkServiceBootstrapError.canceled }
            } catch let error as WorkServiceClientSessionError {
                throw LocalWorkServiceBootstrapError.connectionFailed(error)
            } catch {
                throw LocalWorkServiceBootstrapError.transportFailed
            }
        }
    }

    private static func runLauncher(
        _ launcher: @escaping Launcher, deadline: UInt64
    ) async throws {
        let task = Task<Void, Error> {
            do { try await launcher() }
            catch is CancellationError { throw LocalWorkServiceBootstrapError.canceled }
            catch let error as LocalAviaryDaemonLauncherError {
                // Launcher failures are deliberately path-free and non-secret. Preserve their
                // typed classification so the caller can distinguish a damaged bundle from an
                // invalid AgentHome or an operating-system spawn failure.
                throw LocalWorkServiceBootstrapError.launcherFailed(error)
            }
            catch { throw LocalWorkServiceBootstrapError.launchFailed }
        }
        let wait = LocalWorkServiceBootstrapWait<Void>()
        Task.detached {
            do { wait.resolve(.success(try await task.value)) }
            catch { wait.resolve(.failure(error)) }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline {
            task.cancel()
            throw LocalWorkServiceBootstrapError.timedOut
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .nanoseconds(Int(deadline - now))) {
                task.cancel()
                wait.resolve(.failure(LocalWorkServiceBootstrapError.timedOut))
            }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await wait.value()
            } onCancel: {
                task.cancel()
                wait.resolve(.failure(CancellationError()))
            }
        } catch is CancellationError {
            throw LocalWorkServiceBootstrapError.canceled
        }
    }

    private static func boundTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return value.isNaN || value < 0 ? 0 : 30 }
        return max(0, min(value, 30))
    }

    private static func boundPollInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return value.isNaN || value < 0 ? 0.01 : 2 }
        return max(0.001, min(value, 2))
    }
}
