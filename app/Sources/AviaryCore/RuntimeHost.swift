import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum UnixSocketFailure: Error {
    case invalidPath
    case system(Int32)
    case closed
}

/// A small, blocking POSIX socket wrapper. The actor owns the connection's lifecycle; this
/// object only makes the descriptor's two inherently blocking operations safe to call from
/// detached read/write callbacks. It deliberately has no process semantics: closing a client
/// socket is not a request to stop the host process.
private final class UnixSocketConnection: @unchecked Sendable {
    let path: String
    private let handle: FileHandle
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var closed = false
    private var handleClosed = false

    init(path: String) throws {
        self.path = path
        let pathData = Data(path.utf8)
        // Darwin's sockaddr_un has a 104-byte sun_path. Leave one byte for its NUL terminator.
        guard !pathData.isEmpty, pathData.count <= 103 else {
            throw UnixSocketFailure.invalidPath
        }

        let descriptor = AviaryPOSIX.streamSocket()
        guard descriptor >= 0 else { throw UnixSocketFailure.system(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        do {
            // A peer can disappear while a write is in flight. Prevent SIGPIPE from taking the
            // entire GUI down; the write must surface as a typed transport failure instead.
            guard AviaryPOSIX.setNoSigPipe(descriptor) == 0 else {
                throw UnixSocketFailure.system(errno)
            }
            var bytes = pathData
            bytes.append(0)
            let copied = withUnsafeMutableBytes(of: &address.sun_path) { target in
                bytes.withUnsafeBytes { source in
                    target.copyBytes(from: source)
                }
                return bytes.count
            }
            guard copied == bytes.count else {
                throw UnixSocketFailure.invalidPath
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw UnixSocketFailure.system(errno)
            }
            // Keep the descriptor non-blocking for both directions. FileHandle's readability
            // callback is only scheduled when data/EOF is available, while writes below can use
            // poll to impose their own deadline instead of relying on FileHandle's opaque retry
            // loop (which can ignore SO_SNDTIMEO for a large payload).
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                throw UnixSocketFailure.system(errno)
            }
        } catch {
            // This is the sole close path for a descriptor that failed before FileHandle owns it.
            _ = AviaryPOSIX.close(descriptor)
            throw error
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed() else { throw UnixSocketFailure.closed }
        // FileHandle.write can ignore SO_SNDTIMEO while it retries a short socket write. Use
        // non-blocking send attempts and a bounded poll instead, while leaving the descriptor's
        // read mode untouched for FileHandle's readability handler.
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let sent = send(
                        handle.fileDescriptor, base.advanced(by: offset), rawBuffer.count - offset,
                        AviaryPOSIX.sendFlags)
                    if sent > 0 {
                        offset += sent
                        continue
                    }
                    if sent < 0 && errno == EINTR { continue }
                    if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard now < deadline else { throw UnixSocketFailure.system(EAGAIN) }
                        var descriptor = pollfd(
                            fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                        let remainingMilliseconds = Int32(
                            min(100, max(1, (deadline - now) / 1_000_000)))
                        let ready = poll(&descriptor, 1, remainingMilliseconds)
                        if ready == 0 { continue }
                        if ready < 0 {
                            if errno == EINTR { continue }
                            throw UnixSocketFailure.system(errno)
                        }
                        if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                            throw UnixSocketFailure.system(EPIPE)
                        }
                        continue
                    }
                    throw UnixSocketFailure.system(errno)
                }
            }
        } catch {
            _ = claimClosed()
            closeHandleLocked()
            throw error
        }
    }

    func startReading(
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        handle.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            // Yield the callback queue after at most 1 MiB, including under a continuous sender.
            for _ in 0..<16 {
                guard let (count, readError) = self.receive(into: &buffer) else { break }
                if count > 0 {
                    onData(Data(buffer[0..<count]))
                    continue
                }
                if count == 0 {
                    if self.markClosed() { onClose() }
                    break
                }
                if readError == EINTR { continue }
                if readError == EAGAIN || readError == EWOULDBLOCK { break }
                if self.markClosed() { onClose() }
                break
            }
        }
    }

    private func receive(into buffer: inout [UInt8]) -> (Int, Int32)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return nil }
        let count = recv(handle.fileDescriptor, &buffer, buffer.count, Int32(MSG_DONTWAIT))
        return (count, errno)
    }

    func close() {
        guard claimClosed() else { return }
        finishClose()
    }

    /// The readability callback must not synchronously tear down its own FileHandle source.
    /// Callers already executing on that callback queue use this deferred form instead.
    func deferClose() {
        guard claimClosed() else { return }
        DispatchQueue.global(qos: .utility).async {
            self.finishClose()
        }
    }

    @discardableResult
    private func markClosed() -> Bool {
        // ``markClosed`` runs on Foundation's readability callback queue. FileHandle's
        // readability-handler mutation and close path synchronously coordinate with that queue;
        // doing either reentrantly traps on Linux in ``__DISPATCH_WAIT_FOR_QUEUE__``. Claim the
        // state above, then finish cleanup only after this callback has returned.
        guard claimClosed() else { return false }
        DispatchQueue.global(qos: .utility).async {
            self.finishClose()
        }
        return true
    }

    private func claimClosed() -> Bool {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return false
        }
        closed = true
        stateLock.unlock()
        return true
    }

    private func isClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func finishClose() {
        writeLock.lock()
        closeHandleLocked()
        writeLock.unlock()
    }

    /// Must be called while `writeLock` is held. Keeping `closed` separate from
    /// `handleClosed` makes an I/O error followed by lifecycle cleanup idempotent and ensures
    /// the underlying descriptor is not leaked or accidentally closed twice.
    private func closeHandleLocked() {
        guard !handleClosed else { return }
        // Every caller has already claimed `closed` under `stateLock`. That claim waits for an
        // admitted recv to finish and prevents the readability callback from starting another,
        // so the descriptor cannot be reused beneath a read after the lock is released here.
        // Foundation may synchronously wait for that callback from both the handler setter and
        // `close()` on Linux; do not hold the callback's state lock across either operation.
        handle.readabilityHandler = nil
        try? handle.close()
        handleClosed = true
    }
}

/// Cancellation handlers run outside the actor, while reply continuations are actor-owned. This
/// tiny synchronized flag lets the waiting task preserve CancellationError even if finishing an
/// AsyncThrowingStream is observed as an empty stream on a particular Swift runtime.
private final class RuntimeHostCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCanceled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A client for a runtime host: the process where agent code actually runs.
///
/// The contract is `docs/runtime-host-protocol.md`, and it is deliberately the *only* thing
/// Aviary knows about a runtime. A Lua, QuickJS or WASM host that speaks the same lines is a
/// drop-in — the runtime becomes something to experiment with rather than a foundation to
/// commit to. Two hosts already exist for one language, trading isolation against C-extension
/// compatibility, and `RuntimeCapabilities` is how a caller tells them apart at runtime
/// instead of guessing.
///
/// Why a separate process rather than linking a runtime in: a segfault in a C extension would
/// otherwise take the window, the board and the transcripts with it — and this is not
/// hypothetical, a `polars` import inside a sub-interpreter aborted the whole process during
/// development. Aviary's invariant is that it stays usable when the agent side is wedged,
/// which is exactly when you want to read what happened.
public actor RuntimeHost {

    /// Lets a callback handler re-enter the host's lifecycle without waiting on its own task.
    /// A handler may ask the owner to close admission; that call can drain every *other*
    /// callback, while this callback continues to its protocol response and then completes.
    @TaskLocal private static var activeCallbackID: Int?

    // MARK: Types

    /// The logical host and the particular process instance serving it. `hostID` is supplied by
    /// the launcher, while `instanceID` is generated by the Python process. A PID is deliberately
    /// absent: it is a diagnostic and can be reused, never an authority for adoption.
    public struct HostIdentity: Sendable, Hashable, Codable {
        public let hostID: String
        public let instanceID: String

        public init(hostID: String, instanceID: String) {
            self.hostID = hostID
            self.instanceID = instanceID
        }
    }

    /// A local endpoint that can be persisted with an adoption descriptor. The path is an
    /// address, not an identity; callers must retain and verify `HostIdentity` as well.
    public struct SocketEndpoint: Sendable, Hashable, Codable {
        public let path: String

        public init(path: String) { self.path = path }
    }

    /// The reconnect material a later GUI needs. It is intentionally Codable and contains no
    /// PID or bearer token. The host instance identity is checked again during `connect`.
    public struct AdoptionDescriptor: Sendable, Hashable, Codable {
        public let endpoint: SocketEndpoint
        public let identity: HostIdentity
        public let protocolVersion: Int

        public init(
            endpoint: SocketEndpoint, identity: HostIdentity, protocolVersion: Int = 3
        ) {
            self.endpoint = endpoint
            self.identity = identity
            self.protocolVersion = protocolVersion
        }
    }

    public static let protocolVersion = 3
    public static let maxFrameBytes = 4 * 1024 * 1024

    /// A hostile or wedged host must not be able to make the client retain an unbounded number
    /// of complete frames while the actor catches up. The input pump closes the transport when
    /// this finite queue fills; dropping a frame would otherwise silently reorder or lose a
    /// request/event.
    private static let maxBufferedIncomingFrames = 256
    /// A callback is application work, not just another input frame. Keep the number of admitted
    /// handler tasks bounded even when a host emits a callback flood faster than the GUI can
    /// service it. Excess callbacks receive a small direct refusal through the same bounded socket
    /// writer; there is no second Task pool that can fill and silently lose the callback RID.
    private static let maxActiveCallbackTasks = 32

    public struct Capabilities: Sendable, Hashable {
        public var protocolVersion: Int
        public var runtime: String
        public var runtimeVersion: String
        public var features: [String: Bool]
        public var identity: HostIdentity?
        public var transport: String?

        /// Never assume an undeclared capability. A host that cannot interrupt a running loop
        /// says so, and a UI that offered a Stop button anyway would be lying to whoever
        /// pressed it.
        public func has(_ feature: String) -> Bool { features[feature] ?? false }

        public var summary: String {
            "\(runtime) \(runtimeVersion) · protocol \(protocolVersion)"
        }
    }

    public struct ExecResult: Sendable, Hashable {
        public var stdout: String
        public var stderr: String
        /// The repr of a trailing expression, echoed the way a REPL would.
        public var value: String?
        /// A formatted traceback. Agent code that raises is *data*, never a host failure.
        public var exception: String?

        public var failed: Bool { exception != nil }
    }

    public struct Binding: Sendable, Hashable, Identifiable {
        public var name: String
        public var type: String
        public var repr: String
        public var length: Int?
        public var id: String { name }
    }

    public struct Namespace: Sendable, Hashable {
        public var bindings: [Binding]
        /// The session's shell working directory — persistent, unlike a subprocess's.
        public var cwd: String?
    }

    public enum HostError: LocalizedError {
        case notRunning
        case launchFailed(String)
        case rejected(code: String, detail: String)
        case timedOut(op: String)
        case malformedReply
        case frameTooLarge(op: String, bytes: Int, limit: Int)
        case transportWriteFailed(op: String, detail: String)
        case invalidEndpoint(String)
        case connectionFailed(String)
        case staleSocket(String)
        case protocolMismatch(expected: Int, actual: Int)
        case identityMismatch(expected: HostIdentity, actual: HostIdentity?)
        case adoptionDescriptorMismatch(expected: Int, actual: Int)

        private static func bounded(_ value: String, limit: Int = 500) -> String {
            String(value.prefix(limit))
        }

        public var errorDescription: String? {
            switch self {
            case .notRunning: return "The runtime host is not running."
            case .launchFailed(let s):
                return "Could not start the runtime host: \(Self.bounded(s, limit: 240))"
            case .rejected(let code, let detail):
                return "\(Self.bounded(code, limit: 120)): \(Self.bounded(detail))"
            case .timedOut(let op):
                return "The runtime host did not answer \(Self.bounded(op, limit: 120)) in time."
            case .malformedReply: return "The runtime host sent a reply that could not be read."
            case .frameTooLarge(let op, let bytes, let limit):
                return "Runtime host \(Self.bounded(op, limit: 120)) request is too large "
                    + "(\(bytes) bytes; limit \(limit))."
            case .transportWriteFailed(let op, let detail):
                return "Runtime host write failed during \(Self.bounded(op, limit: 120)): "
                    + Self.bounded(detail, limit: 240)
            case .invalidEndpoint(let detail):
                return "Invalid runtime host endpoint: \(Self.bounded(detail, limit: 240))"
            case .connectionFailed(let detail):
                return "Could not connect to the runtime host: \(Self.bounded(detail, limit: 240))"
            case .staleSocket(let detail):
                return "Runtime host socket is stale or occupied: \(Self.bounded(detail, limit: 240))"
            case .protocolMismatch(let expected, let actual):
                return "Runtime host protocol mismatch (expected \(expected), got \(actual))."
            case .identityMismatch(let expected, let actual):
                let expectedText = "\(Self.bounded(expected.hostID, limit: 120))/\(Self.bounded(expected.instanceID, limit: 120))"
                let actualText = actual.map {
                    "\(Self.bounded($0.hostID, limit: 120))/\(Self.bounded($0.instanceID, limit: 120))"
                } ?? "unknown"
                return "Runtime host identity mismatch (expected \(expectedText), got \(actualText))."
            case .adoptionDescriptorMismatch(let expected, let actual):
                return "Adoption descriptor protocol mismatch (expected \(expected), got \(actual))."
            }
        }
    }

    /// Output as it arrives, before the request settles. A caller that only wants the final
    /// result can ignore these; a UI wants them.
    public typealias OutputHandler = @Sendable (_ session: String, _ stream: String, _ text: String) -> Void

    /// Serves a request *from* the runtime: a sub-agent spawn, a look at the conversation, a
    /// question for a person.
    ///
    /// The direction that makes the runtime more than a calculator. Agent code calls
    /// `spawn(...)` and blocks; this is what unblocks it. Returning a payload with an `error`
    /// key is how a refusal reaches the agent as something it can read and react to, rather
    /// than as a hang.
    public typealias CallbackHandler = @Sendable (
        _ session: String, _ rid: String, _ kind: String, _ payload: JSONValue
    ) async throws -> JSONValue

    // MARK: State

    private let executable: String?
    private let arguments: [String]
    private let parentLifetimeLeaseEnabled: Bool
    private var expectedIdentity: HostIdentity?
    private let expectedProtocolVersion: Int
    private var process: Process?
    private var socket: UnixSocketConnection?
    private var endpointStorage: SocketEndpoint?
    private var identityStorage: HostIdentity?
    private typealias ReplyStream = AsyncThrowingStream<JSONValue, Error>
    private var pending: [String: ReplyStream.Continuation] = [:]
    private var nextID = 0
    private var readyContinuation: CheckedContinuation<Capabilities, Error>?
    private var outputHandler: OutputHandler?
    private var callbackHandler: CallbackHandler?
    /// Callback admission is closed before a run's durable journals are closed. Events already
    /// admitted continue to run, but a callback arriving after the boundary is refused and can
    /// never touch the owner's state.
    private var callbackAdmissionOpen = true
    private var nextCallbackID = 0
    private var callbackTasks: [Int: Task<Void, Error>] = [:]
    private var callbackErrors: [Error] = []
    /// Responses to callbacks rejected after admission closes do not run application effects,
    /// but remain tracked so shutdown does not race their protocol reply.
    private var stderrTail: [String] = []
    /// One consumer for socket input. A Task per line can enter this actor out of wire order even
    /// though actor mutation itself is serialized; deltas, replies, and callbacks must retain
    /// the order in which the host wrote them.
    private var outputPump: Task<Void, Never>?
    /// Every socket gets a monotonically increasing generation. Readability callbacks from an
    /// old socket may run after reconnect; they must not tear down the newly verified transport.
    private var connectionGeneration: UInt64 = 0
    /// Every owned process gets its own generation. Process.terminationHandler is delivered
    /// asynchronously and can arrive after a clean stop has already launched a replacement; an
    /// old handler must never mark the replacement dead or tear down its connection.
    private var processGeneration: UInt64 = 0

    public private(set) var capabilities: Capabilities?
    public private(set) var isRunning = false
    /// True only while this client has a live transport. It says nothing about a detached host
    /// after `disconnect`; use the persisted adoption descriptor to reconnect and verify it.
    public private(set) var isConnected = false
    /// The process is known to be ours only for a client that launched it. An adopted client does
    /// not infer process liveness from a PID or from a successful socket connect.
    public private(set) var hostProcessIsRunning = false
    private var ownedProcessExitVerified = false
    private var childExecutionOwnershipClaimed = false
    private var teardownDepth = 0

    public var endpoint: SocketEndpoint? { endpointStorage }
    public var hostIdentity: HostIdentity? { identityStorage }
    public var adoptionDescriptor: AdoptionDescriptor? {
        guard let endpointStorage, let identityStorage else { return nil }
        return AdoptionDescriptor(
            endpoint: endpointStorage, identity: identityStorage,
            protocolVersion: Self.protocolVersion)
    }

    /// Whether newly received runtime callbacks may start their application-side effect.
    public var isCallbackAdmissionOpen: Bool { callbackAdmissionOpen }

    /// Number of admitted callback effects that have not yet been observed as complete.
    public var activeCallbackCount: Int { callbackTasks.count }

    public init(
        executable: String, arguments: [String], parentLifetimeLease: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.parentLifetimeLeaseEnabled = parentLifetimeLease
        self.expectedIdentity = nil
        self.expectedProtocolVersion = Self.protocolVersion
        self.endpointStorage = nil
        self.identityStorage = nil
        self.ownedProcessExitVerified = true
    }

    /// Construct a client that can adopt an already-running host. `connect()` validates the
    /// descriptor's protocol and both identity components before exposing it to callers.
    public init(endpoint: SocketEndpoint, expectedIdentity: HostIdentity) {
        self.executable = nil
        self.arguments = []
        self.parentLifetimeLeaseEnabled = false
        self.expectedIdentity = expectedIdentity
        self.expectedProtocolVersion = Self.protocolVersion
        self.endpointStorage = endpoint
        self.identityStorage = nil
    }

    public static func adopt(_ descriptor: AdoptionDescriptor) throws -> RuntimeHost {
        guard descriptor.protocolVersion == Self.protocolVersion else {
            throw HostError.adoptionDescriptorMismatch(
                expected: Self.protocolVersion, actual: descriptor.protocolVersion)
        }
        return RuntimeHost(
            endpoint: descriptor.endpoint, expectedIdentity: descriptor.identity,
            expectedProtocolVersion: descriptor.protocolVersion)
    }

    private init(
        endpoint: SocketEndpoint, expectedIdentity: HostIdentity, expectedProtocolVersion: Int
    ) {
        self.executable = nil
        self.arguments = []
        self.parentLifetimeLeaseEnabled = false
        self.expectedIdentity = expectedIdentity
        self.expectedProtocolVersion = expectedProtocolVersion
        self.endpointStorage = endpoint
        self.identityStorage = nil
    }

    /// The bundled CPython host, if this checkout has it.
    public static func bundledPython(
        repoRoot: URL, python: String = "/usr/bin/env", variant: String = "python3",
        parentLifetimeLease: Bool = false
    ) -> RuntimeHost? {
        let script = repoRoot.appending(path: "runtime-hosts/\(variant)/host.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return RuntimeHost(
            executable: python, arguments: ["python3", script.path],
            parentLifetimeLease: parentLifetimeLease)
    }

    // MARK: Lifecycle

    /// A child executor may take ownership only of a fresh launcher, never an adopted,
    /// already-started, or previously claimed runtime. This is an in-process ownership check,
    /// not an authorization or sandbox boundary.
    public func claimChildExecutionOwnership() -> Bool {
        guard executable != nil, parentLifetimeLeaseEnabled,
              process == nil, processGeneration == 0,
              !isRunning, !isConnected, endpointStorage == nil,
              !childExecutionOwnershipClaimed else { return false }
        childExecutionOwnershipClaimed = true
        return true
    }

    /// Launch, and wait for the host to announce itself.
    ///
    /// The `ready` event doubles as a handshake: a host that cannot start its runtime never
    /// sends one, so a caller learns at launch rather than on first use.
    public func start(timeout: TimeInterval = 20) async throws -> Capabilities {
        guard teardownDepth == 0 else {
            throw HostError.launchFailed("The previous runtime is still stopping.")
        }
        guard !isRunning else {
            if let capabilities { return capabilities }
            throw HostError.notRunning
        }
        if let process {
            guard !process.isRunning else {
                throw HostError.launchFailed("The previous owned runtime has not exited.")
            }
            self.process = nil
        }
        // A RuntimeHost may be restarted after a clean stop. A stopped instance starts a new
        // callback admission epoch only after its fresh ready identity is verified below.
        callbackAdmissionOpen = false
        callbackErrors.removeAll()

        if executable == nil {
            return try await connect(timeout: timeout)
        }

        // This is a new owned process, not a reconnect. `expectedIdentity` is learned from the
        // previous ready frame and belongs only to reconnect/adoption; retaining it here would
        // reject the fresh host identity generated below.
        expectedIdentity = nil
        identityStorage = nil

        let hostID = UUID().uuidString.lowercased()
        let directory = try Self.kernelSocketDirectory()
        // Keep generous headroom under Darwin's 104-byte sun_path limit. The full host ID is
        // still sent in the handshake; only its first 64 bits name this disposable endpoint.
        let socketToken = String(hostID.filter { $0 != "-" }.prefix(16))
        let path = directory.appending(path: "h-\(socketToken).s")
        try Self.prepareSocketPath(path)
        endpointStorage = SocketEndpoint(path: path.path)

        let p = Process()
        processGeneration &+= 1
        let generation = processGeneration
        p.executableURL = URL(fileURLWithPath: executable!)
        var launchArguments = arguments + ["--socket", path.path, "--host-id", hostID]
        if parentLifetimeLeaseEnabled {
            launchArguments += [
                "--parent-lifetime-pid", String(ProcessInfo.processInfo.processIdentifier),
            ]
        }
        p.arguments = launchArguments
        var env = ProcessEnvironment.shared.snapshot
        // Keep this for Python's own background work; the transport is a socket, not stdio.
        env["PYTHONUNBUFFERED"] = "1"
        // A usable PATH even when the login-shell snapshot has not been taken — otherwise
        // `env python3` cannot find an interpreter and the failure looks like a protocol
        // problem rather than a missing variable. The same class of bug as the harness
        // sending an unset variable's name as an API key.
        if (env["PATH"] ?? "").isEmpty {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        p.environment = env

        // No stdin/stdout/stderr pipe belongs to this client. Those descriptors disappear when
        // the GUI exits and can make a supposedly detached host block or receive EOF. The host
        // is responsible for its socket and keeps diagnostics bounded on its own side.
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            Task { await self?.handleExit(generation: generation) }
        }

        do {
            try p.run()
        } catch {
            try? Self.removeSocketIfSafe(path)
            endpointStorage = nil
            throw HostError.launchFailed(Self.boundedErrorDescription(error))
        }
        process = p
        hostProcessIsRunning = true
        ownedProcessExitVerified = false

        do {
            return try await connect(timeout: timeout)
        } catch {
            // Startup failed before a client could adopt this process. This is an explicit
            // cleanup path; an ordinary client disconnect below never does this.
            await terminateOwnedProcess()
            try? Self.removeSocketIfSafe(path)
            endpointStorage = nil
            throw error
        }
    }

    /// Connect to the host socket and validate its ready handshake. A newly launched host and a
    /// later adopter use this exact path, which prevents reconnect from becoming a special,
    /// weaker code path.
    @discardableResult
    public func connect(timeout: TimeInterval = 20) async throws -> Capabilities {
        guard let endpointStorage else { throw HostError.invalidEndpoint("missing socket path") }
        guard expectedProtocolVersion == Self.protocolVersion else {
            throw HostError.adoptionDescriptorMismatch(
                expected: Self.protocolVersion, actual: expectedProtocolVersion)
        }
        try Self.validateSocketPath(endpointStorage.path)
        guard !isConnected else {
            if let capabilities { return capabilities }
            throw HostError.notRunning
        }

        // `capabilities` belongs to one connection's ready frame. Never let a reconnect reuse a
        // previous frame and accidentally skip identity/protocol validation for the new socket.
        capabilities = nil
        readyContinuation = nil
        // No unsolicited callback is trusted until this connection's ready identity has been
        // verified. `ingest` opens the new admission epoch atomically with that verification.
        callbackAdmissionOpen = false
        connectionGeneration &+= 1
        socket?.close()
        socket = nil
        outputPump?.cancel()
        outputPump = nil

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var lastFailure = "endpoint is not ready"
        while Date() < deadline {
            var terminalFailure: HostError?
            do {
                let connection = try UnixSocketConnection(path: endpointStorage.path)
                connectionGeneration &+= 1
                let generation = connectionGeneration
                socket = connection
                isConnected = true
                isRunning = true
                let framer = LineFramer(maxLineBytes: Self.maxFrameBytes)
                let (inputLines, inputContinuation) = AsyncStream<Data>.makeStream(
                    bufferingPolicy: .bufferingOldest(Self.maxBufferedIncomingFrames))
                outputPump = Task { [weak self] in
                    for await line in inputLines {
                        guard let self else { return }
                        await self.ingest(line, generation: generation)
                    }
                }
                connection.startReading(
                    onData: { [weak self] chunk in
                        for line in framer.feed(chunk) {
                            switch inputContinuation.yield(line) {
                            case .enqueued:
                                break
                            case .dropped:
                                // Never silently lose an ordered frame. A full bounded pump is
                                // a transport failure; close it so pending requests fail and a
                                // later reconnect can establish a clean stream.
                                inputContinuation.finish()
                                connection.deferClose()
                                Task { await self?.handleTransportClose(generation: generation) }
                                return
                            case .terminated:
                                return
                            @unknown default:
                                inputContinuation.finish()
                                connection.deferClose()
                                Task { await self?.handleTransportClose(generation: generation) }
                                return
                            }
                        }
                        if framer.takeOverflowCount() > 0 {
                            // A host frame that cannot be bounded is not a valid response. Close
                            // this client transport so pending calls fail promptly instead of
                            // retaining an unbounded partial line or waiting for a timeout.
                            inputContinuation.finish()
                            connection.deferClose()
                            Task { await self?.handleTransportClose(generation: generation) }
                        }
                    },
                    onClose: { [weak self] in
                        inputContinuation.finish()
                        Task { await self?.handleTransportClose(generation: generation) }
                    })
                let caps = try await awaitReadyWithTimeout(
                    max(0.1, deadline.timeIntervalSinceNow))
                return caps
            } catch let error as HostError {
                if case .protocolMismatch = error { terminalFailure = error }
                if case .identityMismatch = error { terminalFailure = error }
                if case .invalidEndpoint = error { terminalFailure = error }
                if case .malformedReply = error { terminalFailure = error }
                lastFailure = error.localizedDescription
            } catch let error as UnixSocketFailure {
                lastFailure = Self.socketFailureDescription(error)
            } catch {
                lastFailure = Self.boundedErrorDescription(error)
            }
            // Clear every per-attempt resource before retrying. In particular, a failed ready
            // handshake must not leave the old output pump or socket capable of affecting a later
            // attempt at the same endpoint.
            closeTransport(HostError.connectionFailed(lastFailure))
            if let terminalFailure { throw terminalFailure }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        throw HostError.connectionFailed(String(lastFailure.prefix(240)))
    }

    /// Reconnect this client after an intentional `disconnect`. The host/process identity learned
    /// before disconnect is still required, so a new process at the same path cannot be adopted.
    @discardableResult
    public func reconnect(timeout: TimeInterval = 20) async throws -> Capabilities {
        guard expectedIdentity != nil || identityStorage != nil else {
            throw HostError.invalidEndpoint("reconnect requires a verified host identity")
        }
        return try await connect(timeout: timeout)
    }

    private func awaitReady() async throws -> Capabilities {
        if let capabilities { return capabilities }
        return try await withCheckedThrowingContinuation { cont in
            readyContinuation = cont
        }
    }

    private func failReady(_ error: Error) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }

    private func awaitReadyWithTimeout(_ timeout: TimeInterval) async throws -> Capabilities {
        if let capabilities { return capabilities }
        return try await withThrowingTaskGroup(of: Capabilities.self) { group in
            group.addTask { try await self.awaitReady() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
                await self.failReady(HostError.timedOut(op: "startup"))
                throw HostError.timedOut(op: "startup")
            }
            do {
                do {
                    let result = try await group.next()!
                    group.cancelAll()
                    if Task.isCancelled { throw CancellationError() }
                    return result
                } catch {
                    group.cancelAll()
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            } catch {
                // A throwing timeout child can win before the response iterator. Cancel the
                // iterator before leaving the group; otherwise structured-task teardown waits
                // for a stream that is still waiting for a socket frame/EOF.
                group.cancelAll()
                throw error
            }
        }
    }

    /// Ask the host to stop, then make sure it did. Callback application code is not trusted to
    /// return, so the drain has a finite deadline; after it expires, close and owned-process
    /// termination proceed while the admitted callback remains truthfully observable.
    public func stop(callbackDrainTimeout: TimeInterval = 2) async {
        teardownDepth += 1
        defer { teardownDepth -= 1 }
        // Invalidate the current process handler before any suspension. A termination callback
        // from this process may already be queued, and must not race a subsequent start.
        processGeneration &+= 1
        // The process may emit a callback between the caller deciding to stop and the shutdown
        // request being handled. Close admission first, then wait for effects already admitted,
        // so the shutdown response cannot race a callback's journal writes.
        closeCallbackAdmission()
        let deadline = Date().addingTimeInterval(max(0.001, callbackDrainTimeout))
        let callbacksDrained = await waitUntilCallbacksQuiescent(until: deadline)
        if !callbacksDrained {
            // Do not cancel or remove the task: activeCallbackCount remains a truthful account of
            // an admitted effect that did not finish. Transport/process teardown must still make
            // progress, because a callback handler is application code and may never return.
            noteDiagnostic("callback drain deadline exceeded; \(callbackTasks.count) admitted callback(s) remain")
        }
        // `stop` is the explicit host shutdown operation. `disconnect` below is intentionally
        // separate and never sends this request or kills a process.
        if callbacksDrained, isConnected {
            _ = try? await send("shutdown", timeout: 5)
        }
        closeTransport(HostError.notRunning)
        // A callback timeout means the host may be wedged in application code. Do not wait for a
        // graceful process exit or send a shutdown request that could itself await that callback;
        // terminate the owned process promptly after closing this client's transport.
        await terminateOwnedProcess(gracePeriod: callbacksDrained ? 2 : 0)
        // An owned stop ends this process identity. A later start launches a fresh host and must
        // not send the old instance ID as an adoption constraint.
        if executable != nil {
            expectedIdentity = nil
            identityStorage = nil
            endpointStorage = nil
        }
    }

    public struct StopReceipt: Sendable, Equatable {
        public let ownedProcessExitVerified: Bool
        public let callbacksQuiescent: Bool
    }

    /// A transport close or a sent signal alone is not resource quiescence. This receipt
    /// distinguishes an observed owned-process exit from callbacks that remain in this host.
    /// An adopted/disconnected process cannot be certified through this owned-process seam.
    public func stopWithReceipt(callbackDrainTimeout: TimeInterval = 2) async -> StopReceipt {
        await stop(callbackDrainTimeout: callbackDrainTimeout)
        return StopReceipt(ownedProcessExitVerified: ownedProcessExitVerified,
                           callbacksQuiescent: callbackTasks.isEmpty)
    }

    /// Drop this GUI client's transport while leaving the host and all Python namespaces alive.
    /// The returned adoption descriptor remains valid until the host is explicitly shut down or
    /// exits; no PID is consulted and no lifecycle message is sent over the socket.
    public func disconnect() async {
        closeCallbackAdmission()
        closeTransport(HostError.notRunning)
        // A detached host is no longer ours to terminate. Releasing Process also prevents a GUI
        // teardown path from accidentally treating client ownership as host ownership.
        process = nil
        hostProcessIsRunning = false
    }

    // MARK: Reading

    private func ingest(_ data: Data, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        guard let v = JSONValue.parse(data) else { return }

        if let event = v["event"]?.stringValue {
            switch event {
            case "ready":
                let protocolVersion = v["protocol"]?.intValue ?? 0
                guard protocolVersion == Self.protocolVersion else {
                    let error = HostError.protocolMismatch(
                        expected: Self.protocolVersion, actual: protocolVersion)
                    failReady(error)
                    socket?.close()
                    return
                }
                let caps = Self.capabilities(from: v)
                guard let actualIdentity = caps.identity else {
                    let error = HostError.malformedReply
                    failReady(error)
                    socket?.close()
                    return
                }
                if let expectedIdentity, expectedIdentity != actualIdentity {
                    let error = HostError.identityMismatch(
                        expected: expectedIdentity, actual: actualIdentity)
                    failReady(error)
                    socket?.close()
                    return
                }
                identityStorage = actualIdentity
                // A launched client learns the expected process identity at the first handshake;
                // later reconnects to the same path must prove it again.
                if expectedIdentity == nil { expectedIdentity = actualIdentity }
                // Identity/protocol checks above are the admission gate. Open this fresh epoch
                // before the ordered pump can ingest the next frame on a reconnect.
                callbackAdmissionOpen = true
                callbackErrors.removeAll()
                capabilities = caps
                readyContinuation?.resume(returning: caps)
                readyContinuation = nil
            case "callback":
                let rid = v["rid"]?.stringValue ?? ""
                let kind = v["kind"]?.stringValue ?? ""
                let payload = v["payload"] ?? .object([:])
                let session = v["session"]?.stringValue ?? ""
                let callbackParent = v["traceparent"]?.stringValue.flatMap {
                    AviaryTraceContext(traceparent: $0)
                }
                guard callbackAdmissionOpen else {
                    // Admission is a one-way lifecycle boundary. The host is normally already
                    // stopping here, so do not run an application callback merely to answer an
                    // event that arrived after the owner closed its journal. The protocol still
                    // gets an explicit refusal, avoiding a blocked runtime request.
                    refuseCallback(
                        rid: rid,
                        detail: "This runtime callback was refused after admission closed.")
                    return
                }
                guard callbackTasks.count < Self.maxActiveCallbackTasks else {
                    refuseCallback(
                        rid: rid,
                        detail: "This runtime callback was refused because callback capacity is full.")
                    return
                }
                nextCallbackID += 1
                let callbackID = nextCallbackID
                let task = Task { [weak self] in
                    guard let self else { return }
                    var failure: Error?
                    do {
                        try await Self.$activeCallbackID.withValue(callbackID) {
                            try await AviaryTelemetry.withSpan(
                                "aviary.runtime.callback",
                                kind: .server,
                                attributes: [
                                    "aviary.runtime.session.id": .string(AviaryTelemetry.identity(session)),
                                    "aviary.request.id": .string(AviaryTelemetry.identity(rid)),
                                ],
                                parent: callbackParent
                            ) {
                                try await self.serveCallback(
                                    rid: rid, kind: kind, payload: payload, session: session)
                            }
                        }
                    } catch {
                        failure = error
                    }
                    await self.callbackFinished(callbackID, error: failure)
                    if let failure { throw failure }
                }
                callbackTasks[callbackID] = task
            case "output":
                outputHandler?(
                    v["session"]?.stringValue ?? "",
                    v["stream"]?.stringValue ?? "stdout",
                    v["text"]?.stringValue ?? "")
            default:
                // host_error, bad_request and anything a future host invents. Recorded, not
                // fatal: an unknown event must never be able to wedge the client.
                noteDiagnostic("event \(event): \(v.prettyPrinted)")
            }
            return
        }

        guard let id = v["id"]?.stringValue, let waiter = pending.removeValue(forKey: id) else {
            return
        }
        if v["ok"]?.boolValue == true {
            waiter.yield(v["data"] ?? .null)
            waiter.finish()
        } else {
            waiter.finish(throwing: HostError.rejected(
                code: v.path("error.code")?.stringValue ?? "error",
                detail: v.path("error.detail")?.stringValue ?? "no detail"))
        }
    }

    private func noteDiagnostic(_ value: String) {
        // Diagnostics are for operators, not an unbounded second transport. Keep each entry and
        // the retained tail bounded even when a host echoes a huge traceback or payload.
        let entry = String(value.prefix(1_000))
        guard !entry.isEmpty else { return }
        stderrTail.append(entry.hasSuffix("\n") ? entry : entry + "\n")
        if stderrTail.count > 100 { stderrTail.removeFirst(stderrTail.count - 100) }
    }

    private static func boundedErrorDescription(_ error: Error) -> String {
        String((error as? LocalizedError)?.errorDescription
            ?? String(describing: error)).prefix(500).description
    }

    private func handleExit(generation: UInt64) {
        guard generation == processGeneration else { return }
        ownedProcessExitVerified = true
        hostProcessIsRunning = false
        isRunning = false
        isConnected = false
        // A dead runtime cannot legitimately originate another application effect. Existing
        // callbacks remain tracked and drainable; anything still queued on the output pump is
        // refused by the same admission boundary used for orderly shutdown.
        callbackAdmissionOpen = false
        outputPump?.cancel()
        outputPump = nil
        let error = HostError.notRunning
        for (_, waiter) in pending { waiter.finish(throwing: error) }
        pending.removeAll()
        failReady(error)
    }

    private func handleTransportClose(generation: UInt64) {
        guard generation == connectionGeneration, isConnected else { return }
        // A client disconnect is not a host shutdown, so do not touch `process` or send a
        // lifecycle request. Pending request continuations are transport failures only.
        closeTransport(HostError.notRunning)
    }

    /// Tear down only this client's transport. This is deliberately separate from process
    /// termination: an EOF or a failed write must not destroy the host's Python namespaces.
    /// Incrementing the generation fences late callbacks from the old socket from a newly
    /// connected socket on the same actor.
    private func closeTransport(_ error: Error) {
        connectionGeneration &+= 1
        socket?.close()
        socket = nil
        isConnected = false
        isRunning = false
        callbackAdmissionOpen = false
        for (_, waiter) in pending { waiter.finish(throwing: error) }
        pending.removeAll()
        failReady(error)
        outputPump?.cancel()
        outputPump = nil
    }

    /// Whatever the host wrote to stderr — where a Python traceback from the host itself
    /// (as opposed to from agent code) shows up.
    public var diagnostics: String { stderrTail.joined() }

    // MARK: Sending

    @discardableResult
    private func send(
        _ op: String,
        _ fields: [String: JSONValue] = [:],
        timeout: TimeInterval = 120,
        diagnosticFields: [String: JSONValue] = [:]
    ) async throws -> JSONValue? {
        guard isConnected, let socket else { throw HostError.notRunning }
        nextID += 1
        let id = "av-\(nextID)"
        var baseObject = fields
        baseObject["id"] = .string(id)
        baseObject["op"] = .string(op)
        var tracedObject = baseObject
        for (key, value) in diagnosticFields where tracedObject[key] == nil {
            tracedObject[key] = value
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func encodedFrame(_ object: [String: JSONValue]) throws -> Data {
            guard var data = try? encoder.encode(JSONValue.object(object)) else {
                throw HostError.malformedReply
            }
            data.append(UInt8(ascii: "\n"))
            guard data.count <= Self.maxFrameBytes else {
                throw HostError.frameTooLarge(op: op, bytes: data.count, limit: Self.maxFrameBytes)
            }
            return data
        }

        // Trace context is diagnostic only. If it is the sole reason a request exceeds the
        // frame bound, preserve the base request and send it once without context. This all
        // happens before pending registration and the first write, so there is no post-write
        // retry or ambiguity about how many requests were delivered.
        let data: Data
        do {
            data = try encodedFrame(tracedObject)
        } catch let error as HostError {
            guard !diagnosticFields.isEmpty, case .frameTooLarge = error else { throw error }
            data = try encodedFrame(baseObject)
            AviaryTelemetry.event("aviary.transport.context_omitted")
        }

        // Register the reply stream before the first suspension or write. The previous
        // unstructured registration Task could lose a zero-timeout race: the timeout removed
        // nothing, then registration installed a continuation nobody could ever resume.
        let (stream, continuation) = ReplyStream.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        pending[id] = continuation
        if Task.isCancelled {
            pending.removeValue(forKey: id)?.finish(throwing: CancellationError())
            throw CancellationError()
        }
        do {
            try socket.write(data)
        } catch {
            let failure = HostError.transportWriteFailed(
                op: op, detail: Self.boundedErrorDescription(error))
            pending.removeValue(forKey: id)?.finish(throwing: failure)
            closeTransport(failure)
            throw failure
        }

        let cancellationFlag = RuntimeHostCancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    guard let value = try await iterator.next() else {
                        if cancellationFlag.isCanceled {
                            throw CancellationError()
                        }
                        throw HostError.notRunning
                    }
                    return value
                }
                group.addTask {
                    let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    await self.fail(id, HostError.timedOut(op: op))
                    throw HostError.timedOut(op: op)
                }
                do {
                    let result = try await group.next()!
                    group.cancelAll()
                    if cancellationFlag.isCanceled || Task.isCancelled {
                        throw CancellationError()
                    }
                    return result
                } catch {
                    group.cancelAll()
                    if cancellationFlag.isCanceled || Task.isCancelled {
                        throw CancellationError()
                    }
                    throw error
                }
            }
        }, onCancel: {
            // The cancellation callback cannot mutate this actor synchronously. Finishing the
            // one stored continuation is the idempotent cancellation boundary: a reply, timeout,
            // transport close, and cancellation all remove the same pending ID at most once.
            cancellationFlag.cancel()
            Task { await self.fail(id, CancellationError()) }
        })
    }

    private func fail(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.finish(throwing: error)
    }

    // MARK: Operations

    public func onOutput(_ handler: OutputHandler?) {
        outputHandler = handler
    }

    public func onCallback(_ handler: CallbackHandler?) {
        callbackHandler = handler
    }

    /// Stop admitting new callback effects. This is intentionally separate from process stop so
    /// an owner can close admission, drain callbacks, and then close a native journal while
    /// retaining control over the rest of teardown.
    public func closeCallbackAdmission() {
        callbackAdmissionOpen = false
    }

    /// Wait for all callbacks admitted before `closeCallbackAdmission()` to finish.
    ///
    /// Callers must close admission first. If admission remains open, a callback can arrive
    /// after this actor observes an empty task set and the caller has no quiescence boundary.
    /// The combined method below performs both operations atomically. Handler and response
    /// transport errors are rethrown after every admitted task has been awaited. If a callback
    /// handler itself re-enters this method, its own task is excluded to avoid self-deadlock; it
    /// still must finish its protocol response before the caller can observe full quiescence.
    public func waitUntilCallbacksQuiescent() async throws {
        var firstError: Error?
        let currentCallbackID = Self.activeCallbackID
        while true {
            let tasks = callbackTasks
                .filter { $0.key != currentCallbackID }
                .map(\.value)
            if tasks.isEmpty { break }
            for task in tasks {
                do {
                    try await task.value
                } catch {
                    firstError = firstError ?? error
                }
            }
        }
        if let callbackError = callbackErrors.first {
            firstError = firstError ?? callbackError
        }
        callbackErrors.removeAll()
        if let firstError { throw firstError }
    }

    /// Atomically close callback admission and drain all callbacks already in flight.
    public func closeCallbackAdmissionAndWait() async throws {
        closeCallbackAdmission()
        try await waitUntilCallbacksQuiescent()
    }

    /// Poll the actor-owned callback table until a bounded deadline. This deliberately does not
    /// await callback task values: application callback code is not cancellation-cooperative, so
    /// a permanently stuck handler must not keep lifecycle teardown from closing the transport or
    /// terminating an owned process.
    private func waitUntilCallbacksQuiescent(until deadline: Date) async -> Bool {
        while true {
            let currentCallbackID = Self.activeCallbackID
            let hasOutstanding = callbackTasks.keys.contains { $0 != currentCallbackID }
            if !hasOutstanding {
                do {
                    try await waitUntilCallbacksQuiescent()
                } catch {
                    noteDiagnostic(
                        "callback failed during shutdown: \(Self.boundedErrorDescription(error))")
                }
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            try? await Task.sleep(nanoseconds: UInt64(min(0.01, remaining) * 1_000_000_000))
        }
    }

    private func callbackFinished(_ id: Int, error: Error?) {
        callbackTasks.removeValue(forKey: id)
        if let error { callbackErrors.append(error) }
    }

    private func refuseCallback(rid: String, detail: String) {
        guard isConnected, let socket else {
            noteDiagnostic("callback refusal could not be delivered without a live transport")
            return
        }
        // A refusal is already the terminal answer to the host's blocked callback. Do not spend
        // another long-lived Task waiting for its acknowledgement: that merely moves an overload
        // from the handler pool into a second pool which can itself saturate and drop RIDs. Send
        // the small callback.result frame directly through bounded socket I/O. The acknowledgement
        // carries an unregistered ID and is intentionally ignored by `ingest`.
        nextID += 1
        let object: JSONValue = .object([
            "id": .string("av-\(nextID)"),
            "op": .string("callback.result"),
            "rid": .string(rid),
            "result": .object(["error": .string(detail)]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(object) else {
            let failure = HostError.malformedReply
            noteDiagnostic("callback refusal encoding failed")
            closeTransport(failure)
            return
        }
        data.append(UInt8(ascii: "\n"))
        guard data.count <= Self.maxFrameBytes else {
            let failure = HostError.frameTooLarge(
                op: "callback.result", bytes: data.count, limit: Self.maxFrameBytes)
            noteDiagnostic("callback refusal exceeded the frame limit")
            closeTransport(failure)
            return
        }
        do {
            try socket.write(data)
        } catch {
            let failure = HostError.transportWriteFailed(
                op: "callback.result", detail: Self.boundedErrorDescription(error))
            noteDiagnostic("callback refusal write failed: \(Self.boundedErrorDescription(error))")
            closeTransport(failure)
        }
    }

    private func serveCallback(
        rid: String, kind: String, payload: JSONValue, session: String
    ) async throws {
        let result: JSONValue
        if let callbackHandler {
            do {
                // `rid` is stable across at-least-once replay. Consumers that perform durable
                // effects can use it as their idempotency key; the transport itself cannot
                // promise exactly-once across a client disconnect or process crash.
                result = try await callbackHandler(session, rid, kind, payload)
            } catch {
                // Keep the protocol live for the runtime's blocked request, while preserving the
                // typed handler failure for waitUntilCallbacksQuiescent(). If even this response
                // cannot be delivered, that transport error is also propagated by the task.
                do {
                    _ = try await send("callback.result", [
                        "rid": .string(rid),
                        "result": .object([
                            "error": .string(Self.boundedErrorDescription(error)),
                        ]),
                    ], timeout: 30)
                } catch {
                    AviaryTelemetry.outcome("indeterminate")
                    throw error
                }
                throw error
            }
        } else {
            // An honest refusal rather than a timeout. A runtime whose client serves no
            // callbacks should learn that immediately, in words the agent can act on.
            result = .object([
                "error": .string("This client does not serve \(kind) requests."),
            ])
        }
        do {
            let reply = try await send("callback.result", [
                "rid": .string(rid), "result": result,
            ], timeout: 30)
            // This describes the callback exchange, not success of an arbitrary Python effect.
            let status = reply?["status"]?.stringValue ?? "unknown"
            AviaryTelemetry.event("aviary.runtime.callback.reply", attributes: [
                "aviary.runtime.callback.reply_state": .string(status),
            ])
            AviaryTelemetry.outcome(status == "accepted" || status == "duplicate"
                ? "completed" : "indeterminate")
        } catch {
            // The handler has returned; loss of its reply must not imply it was never invoked.
            AviaryTelemetry.outcome("indeterminate")
            throw error
        }
    }

    private func validateHandshake(_ caps: Capabilities) throws {
        guard caps.protocolVersion == Self.protocolVersion else {
            throw HostError.protocolMismatch(
                expected: Self.protocolVersion, actual: caps.protocolVersion)
        }
        guard let actual = caps.identity else { throw HostError.malformedReply }
        if let expectedIdentity, expectedIdentity != actual {
            throw HostError.identityMismatch(expected: expectedIdentity, actual: actual)
        }
    }

    private static func kernelSocketDirectory() throws -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appending(path: "Aviary/k", directoryHint: .isDirectory)
        return try secureKernelSocketDirectory(at: directory)
    }

    /// Establish the directory in which launcher-owned host endpoints live. This is kept as a
    /// small internal seam so the path policy can be exercised without mutating a user's real
    /// Application Support tree. `lstat`/`O_NOFOLLOW` make a pre-existing symlink fail closed;
    /// `fchmod` changes only the directory opened and verified below, never an arbitrary target
    /// reached by a path swap.
    static func secureKernelSocketDirectory(at directory: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch let error as HostError {
            throw error
        } catch {
            throw HostError.invalidEndpoint("cannot create socket directory")
        }

        // The final component must be an actual directory owned by this user. Opening with
        // O_NOFOLLOW also closes the lstat -> chmod race for a swapped final path.
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        let descriptor = open(directory.path, flags)
        guard descriptor >= 0 else {
            throw HostError.invalidEndpoint("socket directory is not a real directory")
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid()
        else {
            throw HostError.invalidEndpoint("socket directory is not owned by this user")
        }
        let mode = info.st_mode & 0o777
        if mode != 0o700 {
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw HostError.invalidEndpoint("cannot secure socket directory")
            }
        }
        return directory
    }

    private static func validateSocketPath(_ path: String) throws {
        let bytes = Data(path.utf8)
        guard !bytes.isEmpty else { throw HostError.invalidEndpoint("empty socket path") }
        guard bytes.count <= 103 else {
            throw HostError.invalidEndpoint("socket path is too long")
        }
    }

    private static func prepareSocketPath(_ path: URL) throws {
        try validateSocketPath(path.path)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            throw HostError.staleSocket("cannot inspect existing endpoint")
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw HostError.staleSocket("endpoint is not a Unix socket")
        }

        // A successful probe proves a live endpoint; never unlink it. Refused/no-route means a
        // stale socket inode and is the only case in which this launcher may remove the path.
        do {
            let probe = try UnixSocketConnection(path: path.path)
            probe.close()
            throw HostError.staleSocket("endpoint already serves a host")
        } catch let error as HostError {
            throw error
        } catch {
            try removeSocketIfSafe(path)
        }
    }

    private static func removeSocketIfSafe(_ path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        var info = stat()
        guard lstat(path.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK
        else { return }
        try FileManager.default.removeItem(at: path)
    }

    private static func socketFailureDescription(_ error: UnixSocketFailure) -> String {
        switch error {
        case .invalidPath: return "invalid socket path"
        case .closed: return "socket closed"
        case .system(let code):
            let text = String(cString: strerror(code))
            return String(text.prefix(160))
        }
    }

    private func terminateOwnedProcess(gracePeriod: TimeInterval = 2) async {
        guard let process else { return }
        teardownDepth += 1
        defer { teardownDepth -= 1 }
        self.process = nil
        let checks = max(0, Int(gracePeriod / 0.1))
        for _ in 0..<checks where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { process.terminate() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Keep the Foundation child-process object alive until its termination is observed.
        // Cleanup often follows cancellation, so use an owned wait whose sleeps cannot be
        // skipped by the canceled caller. Never convert a sent SIGKILL into an exit fact.
        let exited = await Task.detached {
            for _ in 0..<40 {
                if !process.isRunning { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return !process.isRunning
        }.value
        ownedProcessExitVerified = exited
        hostProcessIsRunning = !exited
        if !exited { self.process = process }
    }

    public func hello() async throws -> Capabilities {
        var fields: [String: JSONValue] = [
            "protocol": .number(Double(Self.protocolVersion)),
        ]
        if let expectedIdentity {
            fields["expectedIdentity"] = .object([
                "hostID": .string(expectedIdentity.hostID),
                "instanceID": .string(expectedIdentity.instanceID),
            ])
        }
        guard let data = try await send("hello", fields, timeout: 20) else {
            throw HostError.malformedReply
        }
        let caps = Self.capabilities(from: data)
        try validateHandshake(caps)
        capabilities = caps
        return caps
    }

    /// Open a session. Its state persists until it is destroyed — that is the whole premise.
    @discardableResult
    public func createSession(id: String? = nil, cwd: String? = nil) async throws -> String {
        var fields: [String: JSONValue] = [:]
        if let id { fields["session"] = .string(id) }
        if let cwd { fields["cwd"] = .string(cwd) }
        guard let data = try await send("session.create", fields, timeout: 30),
              let sid = data["session"]?.stringValue
        else { throw HostError.malformedReply }
        return sid
    }

    public func destroySession(_ id: String) async throws {
        _ = try await send("session.destroy", ["session": .string(id)], timeout: 30)
    }

    /// Associate a session's callback delivery with this client. A reconnecting GUI should call
    /// this after verifying the host identity; unanswered callbacks are re-emitted by the host.
    @discardableResult
    public func attachSession(_ id: String) async throws -> Bool {
        guard let data = try await send(
            "session.attach", ["session": .string(id)], timeout: 30)
        else { throw HostError.malformedReply }
        return data["attached"]?.boolValue ?? false
    }

    /// Stop routing new callback events to this client without destroying the Python session.
    public func detachSession(_ id: String) async throws {
        _ = try await send("session.detach", ["session": .string(id)], timeout: 30)
    }

    public func sessions() async throws -> [String] {
        guard let data = try await send("session.list", timeout: 20) else { return [] }
        return (data["sessions"]?.arrayValue ?? []).compactMap { $0.stringValue }
    }

    /// Run code. An exception in agent code comes back in `exception`, not as a thrown error:
    /// the agent failing is an outcome to render, not a fault of the machinery.
    public func execute(
        _ code: String, in session: String, mode: String = "exec", timeout: TimeInterval = 600
    ) async throws -> ExecResult {
        try await AviaryTelemetry.withSpan("aviary.runtime.execute", attributes: [
            "aviary.runtime.session.id": .string(AviaryTelemetry.identity(session)),
            "aviary.input.bytes": .int(code.utf8.count),
            "aviary.timeout.seconds": .double(timeout),
        ]) {
            let result = try await self.executeUntraced(code, in: session, mode: mode, timeout: timeout)
            AviaryTelemetry.outcome(result.exception == nil ? "completed" : "failed")
            AviaryTelemetry.event("aviary.runtime.result", attributes: [
                "aviary.output.bytes": .int(result.stdout.utf8.count + result.stderr.utf8.count),
                "aviary.exception.present": .bool(result.exception != nil),
            ])
            return result
        }
    }

    private func executeUntraced(
        _ code: String, in session: String, mode: String, timeout: TimeInterval
    ) async throws -> ExecResult {
        var diagnosticFields: [String: JSONValue] = [:]
        if let traceparent = AviaryTelemetry.traceparent {
            diagnosticFields["traceparent"] = .string(traceparent)
        }
        guard let data = try await send("exec", [
            "session": .string(session),
            "code": .string(code),
            "mode": .string(mode),
        ], timeout: timeout, diagnosticFields: diagnosticFields) else {
            throw HostError.malformedReply
        }
        return ExecResult(
            stdout: data["stdout"]?.stringValue ?? "",
            stderr: data["stderr"]?.stringValue ?? "",
            value: data["value"]?.stringValue,
            exception: data["exception"]?.stringValue)
    }

    /// Read the session's namespace without running anything the agent wrote.
    ///
    /// The capability that a host you own buys and a Jupyter kernel cannot: listing names
    /// there meant executing a cell, which mutated `In`/`Out` and could shadow the very names
    /// being listed — observation perturbed the observed.
    /// Load hook files into the host's hook interpreter.
    ///
    /// Returns which loaded and which did not, because a hook that silently failed to load is
    /// indistinguishable from one that decided to do nothing — and the difference matters when
    /// the hook was supposed to be blocking something.
    @discardableResult
    public func loadHooks(_ paths: [String], timeout: TimeInterval = 60) async throws
        -> (loaded: [(path: String, events: [String])], failed: [(path: String, detail: String)])
    {
        guard let data = try await send("hook.load", [
            "paths": .array(paths.map { .string($0) }),
        ], timeout: timeout) else { return ([], []) }
        let loaded = (data["loaded"]?.arrayValue ?? []).map { entry in
            (path: entry["path"]?.stringValue ?? "",
             events: (entry["events"]?.arrayValue ?? []).compactMap { $0.stringValue })
        }
        let failed = (data["failed"]?.arrayValue ?? []).map { entry in
            (path: entry["path"]?.stringValue ?? "",
             detail: entry["detail"]?.stringValue ?? "unknown")
        }
        return (loaded, failed)
    }

    /// Call every hook that handles `event`. Returns their combined decision, or nil if none
    /// handled it.
    public func callHook(
        _ event: String, payload: JSONValue, timeout: TimeInterval = 60
    ) async throws -> JSONValue? {
        guard let data = try await send("hook.call", [
            "event": .string(event), "payload": payload,
        ], timeout: timeout) else { return nil }
        return (data["handled"]?.boolValue ?? false) ? data : nil
    }

    public func inspect(_ session: String, timeout: TimeInterval = 60) async throws -> Namespace {
        guard let data = try await send("inspect", ["session": .string(session)], timeout: timeout)
        else { throw HostError.malformedReply }
        let bindings = (data["names"]?.arrayValue ?? []).compactMap { entry -> Binding? in
            guard let name = entry["name"]?.stringValue else { return nil }
            return Binding(
                name: name,
                type: entry["type"]?.stringValue ?? "?",
                repr: entry["repr"]?.stringValue ?? "",
                length: entry["length"]?.intValue)
        }
        return Namespace(bindings: bindings, cwd: data["cwd"]?.stringValue)
    }

    // MARK: Parsing

    static func capabilities(from v: JSONValue) -> Capabilities {
        var features: [String: Bool] = [:]
        if case .object(let obj)? = v["features"] {
            for (k, val) in obj { features[k] = val.boolValue ?? false }
        }
        let identity: HostIdentity?
        if let hostID = v["hostID"]?.stringValue,
           let instanceID = v["instanceID"]?.stringValue,
           !hostID.isEmpty, !instanceID.isEmpty
        {
            identity = HostIdentity(hostID: hostID, instanceID: instanceID)
        } else if let object = v["identity"],
                  let hostID = object["hostID"]?.stringValue,
                  let instanceID = object["instanceID"]?.stringValue,
                  !hostID.isEmpty, !instanceID.isEmpty
        {
            identity = HostIdentity(hostID: hostID, instanceID: instanceID)
        } else {
            identity = nil
        }
        return Capabilities(
            protocolVersion: v["protocol"]?.intValue ?? 0,
            runtime: v["runtime"]?.stringValue ?? "unknown",
            runtimeVersion: v["runtimeVersion"]?.stringValue ?? "",
            features: features,
            identity: identity,
            transport: v["transport"]?.stringValue)
    }
}

/// A one-shot check that the in-house engine can actually run.
///
/// Exists because "no engine configured" was a diagnosable state for the harness and silence
/// for Aviary's own runtime — and a runtime that fails at first use rather than at inspection
/// is the same failure the harness's daemon-version conflict was: invisible until it costs you
/// a run.
public struct RuntimeProbe: Sendable {
    public var variant: String
    public var scriptPath: String
    public var exists: Bool
    public var capabilities: RuntimeHost.Capabilities?
    public var error: String?

    public var ok: Bool { capabilities != nil }

    public var summary: String {
        if let capabilities { return capabilities.summary }
        if !exists { return "host script missing" }
        return error ?? "did not start"
    }

    public static func probe(repoRoot: URL?, variant: String = "python3") async -> RuntimeProbe {
        guard let repoRoot else {
            return RuntimeProbe(
                variant: variant, scriptPath: "—", exists: false, capabilities: nil,
                error: "no Aviary checkout found")
        }
        let script = repoRoot.appending(path: "runtime-hosts/\(variant)/host.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return RuntimeProbe(
                variant: variant, scriptPath: script.path, exists: false, capabilities: nil,
                error: "not present in this checkout")
        }
        let host = RuntimeHost(executable: "/usr/bin/env", arguments: ["python3", script.path])
        do {
            let capabilities = try await host.start(timeout: 15)
            await host.stop()
            return RuntimeProbe(
                variant: variant, scriptPath: script.path, exists: true,
                capabilities: capabilities, error: nil)
        } catch {
            let diagnostics = await host.diagnostics
            await host.stop()
            return RuntimeProbe(
                variant: variant, scriptPath: script.path, exists: true, capabilities: nil,
                // The host's own stderr, when there is any — a Python traceback says far more
                // than "did not start".
                error: diagnostics.isEmpty
                    ? String(error.localizedDescription.prefix(500))
                    : String(diagnostics.suffix(400)))
        }
    }
}
