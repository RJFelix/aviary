import Foundation

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

    public struct Capabilities: Sendable, Hashable {
        public var protocolVersion: Int
        public var runtime: String
        public var runtimeVersion: String
        public var features: [String: Bool]

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

        public var errorDescription: String? {
            switch self {
            case .notRunning: return "The runtime host is not running."
            case .launchFailed(let s): return "Could not start the runtime host: \(s)"
            case .rejected(let code, let detail): return "\(code): \(detail)"
            case .timedOut(let op): return "The runtime host did not answer \(op) in time."
            case .malformedReply: return "The runtime host sent a reply that could not be read."
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
        _ session: String, _ kind: String, _ payload: JSONValue
    ) async throws -> JSONValue

    // MARK: State

    private let executable: String
    private let arguments: [String]
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [String: CheckedContinuation<JSONValue?, Error>] = [:]
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
    private var nextCallbackResponseID = 0
    private var callbackResponseTasks: [Int: Task<Void, Never>] = [:]
    private var stderrTail: [String] = []
    /// One consumer for stdout. A Task per line can enter this actor out of wire order even
    /// though actor mutation itself is serialized; deltas, replies, and callbacks must retain
    /// the order in which the host wrote them.
    private var outputPump: Task<Void, Never>?

    public private(set) var capabilities: Capabilities?
    public private(set) var isRunning = false

    /// Whether newly received runtime callbacks may start their application-side effect.
    public var isCallbackAdmissionOpen: Bool { callbackAdmissionOpen }

    /// Number of admitted callback effects that have not yet been observed as complete.
    public var activeCallbackCount: Int { callbackTasks.count }

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The bundled CPython host, if this checkout has it.
    public static func bundledPython(
        repoRoot: URL, python: String = "/usr/bin/env", variant: String = "python3"
    ) -> RuntimeHost? {
        let script = repoRoot.appending(path: "runtime-hosts/\(variant)/host.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return RuntimeHost(executable: python, arguments: ["python3", script.path])
    }

    // MARK: Lifecycle

    /// Launch, and wait for the host to announce itself.
    ///
    /// The `ready` event doubles as a handshake: a host that cannot start its runtime never
    /// sends one, so a caller learns at launch rather than on first use.
    public func start(timeout: TimeInterval = 20) async throws -> Capabilities {
        guard !isRunning else {
            if let capabilities { return capabilities }
            throw HostError.notRunning
        }
        // A RuntimeHost may be restarted after a clean stop. A stopped instance starts a new
        // callback admission epoch; no callback from the prior process is retained.
        callbackAdmissionOpen = true
        callbackErrors.removeAll()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env = ProcessEnvironment.shared.snapshot
        // Unbuffered, or the host's replies sit in a pipe buffer and every call looks hung.
        env["PYTHONUNBUFFERED"] = "1"
        // A usable PATH even when the login-shell snapshot has not been taken — otherwise
        // `env python3` cannot find an interpreter and the failure looks like a protocol
        // problem rather than a missing variable. The same class of bug as the harness
        // sending an unset variable's name as an API key.
        if (env["PATH"] ?? "").isEmpty {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let framer = LineFramer()
        let (outputLines, outputContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded)
        outputPump = Task { [weak self] in
            for await line in outputLines {
                guard let self else { return }
                await self.ingest(line)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                outputContinuation.finish()
                return
            }
            for line in framer.feed(chunk) {
                outputContinuation.yield(line)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            if let s = String(data: chunk, encoding: .utf8) {
                Task { await self?.noteStderr(s) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            Task { await self?.handleExit() }
        }

        do {
            try p.run()
        } catch {
            outputContinuation.finish()
            outputPump?.cancel()
            outputPump = nil
            throw HostError.launchFailed(error.localizedDescription)
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        isRunning = true

        return try await withThrowingTaskGroup(of: Capabilities.self) { group in
            group.addTask { try await self.awaitReady() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.failReady(HostError.timedOut(op: "startup"))
                throw HostError.timedOut(op: "startup")
            }
            let caps = try await group.next()!
            group.cancelAll()
            return caps
        }
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

    /// Ask the host to stop, then make sure it did.
    public func stop() async {
        // The process may emit a callback between the caller deciding to stop and the shutdown
        // request being handled. Close admission first, then wait for effects already admitted,
        // so the shutdown response cannot race a callback's journal writes.
        closeCallbackAdmission()
        do {
            try await waitUntilCallbacksQuiescent()
        } catch {
            // `stop` predates the throwing drain API and remains a cleanup operation. Preserve
            // the failure in diagnostics; owners that need typed failure must call the throwing
            // drain seam before closing their journal.
            stderrTail.append("callback failed during shutdown: \(error.localizedDescription)\n")
        }
        await waitForCallbackResponses()
        guard isRunning, let p = process else { return }
        _ = try? await send("shutdown", timeout: 5)
        try? stdin?.close()
        stdin = nil
        for _ in 0..<20 where p.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning { p.terminate() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        isRunning = false
        outputPump?.cancel()
        outputPump = nil
    }

    // MARK: Reading

    private func ingest(_ data: Data) {
        guard let v = JSONValue.parse(data) else { return }

        if let event = v["event"]?.stringValue {
            switch event {
            case "ready":
                let caps = Self.capabilities(from: v)
                capabilities = caps
                readyContinuation?.resume(returning: caps)
                readyContinuation = nil
            case "callback":
                let rid = v["rid"]?.stringValue ?? ""
                let kind = v["kind"]?.stringValue ?? ""
                let payload = v["payload"] ?? .object([:])
                let session = v["session"]?.stringValue ?? ""
                guard callbackAdmissionOpen else {
                    // Admission is a one-way lifecycle boundary. The host is normally already
                    // stopping here, so do not run an application callback merely to answer an
                    // event that arrived after the owner closed its journal. The protocol still
                    // gets an explicit refusal, avoiding a blocked runtime request.
                    nextCallbackResponseID += 1
                    let responseID = nextCallbackResponseID
                    let task = Task { [weak self] in
                        guard let self else { return }
                        do {
                            _ = try await self.send("callback.result", [
                                "rid": .string(rid),
                                "result": .object([
                                    "error": .string(
                                        "This runtime callback was refused after admission closed."),
                                ]),
                            ], timeout: 30)
                        } catch {
                            await self.callbackResponseFailed(responseID, error: error)
                        }
                        await self.callbackResponseFinished(responseID)
                    }
                    callbackResponseTasks[responseID] = task
                    return
                }
                nextCallbackID += 1
                let callbackID = nextCallbackID
                let task = Task { [weak self] in
                    guard let self else { return }
                    var failure: Error?
                    do {
                        try await Self.$activeCallbackID.withValue(callbackID) {
                            try await self.serveCallback(
                                rid: rid, kind: kind, payload: payload, session: session)
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
                stderrTail.append("event \(event): \(v.prettyPrinted)")
            }
            return
        }

        guard let id = v["id"]?.stringValue, let waiter = pending.removeValue(forKey: id) else {
            return
        }
        if v["ok"]?.boolValue == true {
            waiter.resume(returning: v["data"])
        } else {
            waiter.resume(throwing: HostError.rejected(
                code: v.path("error.code")?.stringValue ?? "error",
                detail: v.path("error.detail")?.stringValue ?? "no detail"))
        }
    }

    private func noteStderr(_ s: String) {
        stderrTail.append(s)
        if stderrTail.count > 100 { stderrTail.removeFirst(stderrTail.count - 100) }
    }

    private func handleExit() {
        isRunning = false
        // A dead runtime cannot legitimately originate another application effect. Existing
        // callbacks remain tracked and drainable; anything still queued on the output pump is
        // refused by the same admission boundary used for orderly shutdown.
        callbackAdmissionOpen = false
        outputPump?.cancel()
        outputPump = nil
        let error = HostError.notRunning
        for (_, waiter) in pending { waiter.resume(throwing: error) }
        pending.removeAll()
        failReady(error)
    }

    /// Whatever the host wrote to stderr — where a Python traceback from the host itself
    /// (as opposed to from agent code) shows up.
    public var diagnostics: String { stderrTail.joined() }

    // MARK: Sending

    @discardableResult
    private func send(
        _ op: String, _ fields: [String: JSONValue] = [:], timeout: TimeInterval = 120
    ) async throws -> JSONValue? {
        guard isRunning, let stdin else { throw HostError.notRunning }
        nextID += 1
        let id = "av-\(nextID)"
        var obj = fields
        obj["id"] = .string(id)
        obj["op"] = .string(op)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(JSONValue.object(obj)) else {
            throw HostError.malformedReply
        }
        data.append(UInt8(ascii: "\n"))

        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task {
                        await self.register(id, cont)
                        do {
                            try stdin.write(contentsOf: data)
                        } catch {
                            await self.fail(id, HostError.notRunning)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.fail(id, HostError.timedOut(op: op))
                throw HostError.timedOut(op: op)
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func register(_ id: String, _ cont: CheckedContinuation<JSONValue?, Error>) {
        pending[id] = cont
    }

    private func fail(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
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

    private func callbackFinished(_ id: Int, error: Error?) {
        callbackTasks.removeValue(forKey: id)
        if let error { callbackErrors.append(error) }
    }

    private func callbackResponseFailed(_ id: Int, error: Error) {
        stderrTail.append("callback \(id) refusal response failed: \(error.localizedDescription)\n")
    }

    private func callbackResponseFinished(_ id: Int) {
        callbackResponseTasks.removeValue(forKey: id)
    }

    private func waitForCallbackResponses() async {
        while !callbackResponseTasks.isEmpty {
            let tasks = Array(callbackResponseTasks.values)
            for task in tasks { await task.value }
        }
    }

    private func serveCallback(
        rid: String, kind: String, payload: JSONValue, session: String
    ) async throws {
        let result: JSONValue
        if let callbackHandler {
            do {
                result = try await callbackHandler(session, kind, payload)
            } catch {
                // Keep the protocol live for the runtime's blocked request, while preserving the
                // typed handler failure for waitUntilCallbacksQuiescent(). If even this response
                // cannot be delivered, that transport error is also propagated by the task.
                _ = try await send("callback.result", [
                    "rid": .string(rid),
                    "result": .object(["error": .string(error.localizedDescription)]),
                ], timeout: 30)
                throw error
            }
        } else {
            // An honest refusal rather than a timeout. A runtime whose client serves no
            // callbacks should learn that immediately, in words the agent can act on.
            result = .object([
                "error": .string("This client does not serve \(kind) requests."),
            ])
        }
        _ = try await send("callback.result", [
            "rid": .string(rid), "result": result,
        ], timeout: 30)
    }

    public func hello() async throws -> Capabilities {
        guard let data = try await send("hello", timeout: 20) else { throw HostError.malformedReply }
        let caps = Self.capabilities(from: data)
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

    public func sessions() async throws -> [String] {
        guard let data = try await send("session.list", timeout: 20) else { return [] }
        return (data["sessions"]?.arrayValue ?? []).compactMap { $0.stringValue }
    }

    /// Run code. An exception in agent code comes back in `exception`, not as a thrown error:
    /// the agent failing is an outcome to render, not a fault of the machinery.
    public func execute(
        _ code: String, in session: String, mode: String = "exec", timeout: TimeInterval = 600
    ) async throws -> ExecResult {
        guard let data = try await send("exec", [
            "session": .string(session),
            "code": .string(code),
            "mode": .string(mode),
        ], timeout: timeout) else { throw HostError.malformedReply }
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
        return Capabilities(
            protocolVersion: v["protocol"]?.intValue ?? 0,
            runtime: v["runtime"]?.stringValue ?? "unknown",
            runtimeVersion: v["runtimeVersion"]?.stringValue ?? "",
            features: features)
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
                    ? error.localizedDescription
                    : String(diagnostics.suffix(400)))
        }
    }
}
