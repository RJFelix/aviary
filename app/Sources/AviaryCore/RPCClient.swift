import Foundation

/// How to launch a run.
public struct RunConfiguration: Sendable, Hashable {
    public var cwd: String
    public var provider: String?
    public var model: String?
    public var thinkingLevel: String?
    /// Session id or path to resume. Nil starts fresh.
    public var resume: String?
    public var persistSession: Bool = true
    /// Skip AGENTS.md / CLAUDE.md discovery.
    public var noContextFiles: Bool = false
    public var extraArguments: [String] = []

    public init(
        cwd: String,
        provider: String? = nil,
        model: String? = nil,
        thinkingLevel: String? = nil,
        resume: String? = nil,
        persistSession: Bool = true,
        noContextFiles: Bool = false,
        extraArguments: [String] = []
    ) {
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.resume = resume
        self.persistSession = persistSession
        self.noContextFiles = noContextFiles
        self.extraArguments = extraArguments
    }

    func arguments(engine: EngineLocation) -> [String] {
        var a = engine.leadingArguments + ["--mode", "rpc", "--cwd", cwd]
        if let provider { a += ["--provider", provider] }
        if let model { a += ["--model", model] }
        if let thinkingLevel { a += ["--thinking", thinkingLevel] }
        if let resume { a += ["--resume", resume] }
        if !persistSession { a.append("--no-session") }
        if noContextFiles { a.append("-nc") }
        a += extraArguments
        return a
    }
}

/// An event from a live run: either a protocol event or a reply to one of our commands.
public enum RPCMessage: Sendable {
    case event(type: String, payload: JSONValue)
    case response(id: String?, command: String, success: Bool, data: JSONValue?, error: String?)
    /// A line the engine wrote that wasn't protocol JSON — usually a startup diagnostic.
    case stderr(String)
    case exited(code: Int32, stderr: String)
}

public enum RPCError: LocalizedError {
    case notLaunched
    case launchFailed(String)
    case commandRejected(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notLaunched: return "The run is not connected."
        case .launchFailed(let s): return "Could not start the engine: \(s)"
        case .commandRejected(let s): return s
        case .timedOut: return "The engine did not answer in time."
        }
    }
}

/// Splits a byte stream into LF-delimited records, holding a partial trailing record
/// across reads.
///
/// LF only, and a trailing CR tolerated. The harness's RPC docs are explicit that generic
/// line readers are not protocol-compliant here, because they also break on U+2028 and
/// U+2029 — which are legal inside JSON strings and do occur in agent transcripts.
final class LineFramer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aviary.line-framer")
    private var carry = Data()

    func feed(_ chunk: Data) -> [Data] {
        queue.sync {
            carry.append(chunk)
            var lines: [Data] = []
            while let nl = carry.firstIndex(of: UInt8(ascii: "\n")) {
                var line = carry.subdata(in: carry.startIndex..<nl)
                carry.removeSubrange(carry.startIndex...nl)
                if line.last == UInt8(ascii: "\r") { line.removeLast() }
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }
}

/// Drives one live agent run over the harness's RPC mode.
///
/// RPC mode is the harness's documented embedding contract: LF-delimited JSON commands in,
/// events out. Aviary speaks it directly rather than reimplementing the agent loop, because
/// that loop is the part worth keeping — an IPython kernel, a hundred provider routes,
/// compaction, sub-agent spawning. Everything *around* it is native.
///
/// One deliberate detail: records are split on `\n` only. The harness's own docs warn that
/// generic line readers which also break on U+2028/U+2029 corrupt records, because those
/// characters are legal inside JSON strings — and agent transcripts contain arbitrary text.
public actor RPCSession {
    public let id = UUID()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [String: CheckedContinuation<JSONValue?, Error>] = [:]
    private var continuation: AsyncStream<RPCMessage>.Continuation?
    private var stderrBuffer = ""
    private var nextCommandID = 0
    private var isRunning = false

    public private(set) var launchCommand: String = ""

    public init() {}

    /// Start the engine and return the event stream.
    public func start(engine: EngineLocation, config: RunConfiguration) throws -> AsyncStream<RPCMessage> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: engine.path)
        p.arguments = config.arguments(engine: engine)
        p.currentDirectoryURL = URL(fileURLWithPath: config.cwd, isDirectory: true)
        // The login-shell environment, not launchd's. See ProcessEnvironment.
        p.environment = ProcessEnvironment.shared.snapshot

        launchCommand = ([engine.path] + (p.arguments ?? [])).joined(separator: " ")

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let (stream, cont) = AsyncStream<RPCMessage>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        process = p
        stdinHandle = inPipe.fileHandleForWriting

        // stdout: protocol lines.
        let framer = LineFramer()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in framer.feed(chunk) {
                Task { await self?.handleLine(line) }
            }
        }

        // stderr: diagnostics. Kept, because the useful failures (a 401 naming an
        // unexpanded variable, a version-conflict refusal) arrive here, not as events.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let s = String(data: chunk, encoding: .utf8) {
                Task { await self?.handleStderr(s) }
            }
        }

        p.terminationHandler = { [weak self] proc in
            Task { await self?.handleExit(code: proc.terminationStatus) }
        }

        do {
            try p.run()
        } catch {
            cont.finish()
            throw RPCError.launchFailed(error.localizedDescription)
        }
        isRunning = true
        return stream
    }

    private func handleLine(_ data: Data) {
        guard let v = JSONValue.parse(data) else {
            if let s = String(data: data, encoding: .utf8) {
                continuation?.yield(.stderr(s))
            }
            return
        }
        let type = v["type"]?.stringValue ?? ""
        if type == "response" {
            let cmdID = v["id"]?.stringValue
            let success = v["success"]?.boolValue ?? false
            let command = v["command"]?.stringValue ?? ""
            let error = v["error"]?.stringValue
            continuation?.yield(.response(
                id: cmdID, command: command, success: success, data: v["data"], error: error))
            if let cmdID, let waiter = pending.removeValue(forKey: cmdID) {
                if success {
                    waiter.resume(returning: v["data"])
                } else {
                    waiter.resume(throwing: RPCError.commandRejected(
                        error ?? "\(command) was rejected"))
                }
            }
        } else {
            continuation?.yield(.event(type: type, payload: v))
        }
    }

    private func handleStderr(_ s: String) {
        stderrBuffer += s
        if stderrBuffer.count > 64_000 {
            stderrBuffer = String(stderrBuffer.suffix(32_000))
        }
        continuation?.yield(.stderr(s))
    }

    private func handleExit(code: Int32) {
        isRunning = false
        for (_, waiter) in pending {
            waiter.resume(throwing: RPCError.notLaunched)
        }
        pending.removeAll()
        continuation?.yield(.exited(code: code, stderr: stderrBuffer))
        continuation?.finish()
        continuation = nil
    }

    // MARK: Commands

    /// Send a command and wait for its response.
    @discardableResult
    public func send(_ type: String, _ fields: [String: JSONValue] = [:], timeout: TimeInterval = 120) async throws -> JSONValue? {
        guard isRunning, let stdin = stdinHandle else { throw RPCError.notLaunched }
        nextCommandID += 1
        let cmdID = "aviary-\(nextCommandID)"

        var obj = fields
        obj["id"] = .string(cmdID)
        obj["type"] = .string(type)
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? enc.encode(JSONValue.object(obj)) else {
            throw RPCError.commandRejected("could not encode \(type)")
        }
        data.append(UInt8(ascii: "\n"))

        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { cont in
                    Task { await self?.register(cmdID, cont) }
                    do {
                        try stdin.write(contentsOf: data)
                    } catch {
                        Task { await self?.fail(cmdID, RPCError.notLaunched) }
                    }
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.fail(cmdID, RPCError.timedOut)
                throw RPCError.timedOut
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Fire and forget — for commands where waiting adds nothing (abort).
    public func post(_ type: String, _ fields: [String: JSONValue] = [:]) {
        guard isRunning, let stdin = stdinHandle else { return }
        var obj = fields
        obj["type"] = .string(type)
        let enc = JSONEncoder()
        guard var data = try? enc.encode(JSONValue.object(obj)) else { return }
        data.append(UInt8(ascii: "\n"))
        try? stdin.write(contentsOf: data)
    }

    private func register(_ id: String, _ cont: CheckedContinuation<JSONValue?, Error>) {
        pending[id] = cont
    }

    private func fail(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: Convenience

    public func prompt(_ message: String, streamingBehavior: String? = nil) async throws {
        var fields: [String: JSONValue] = ["message": .string(message)]
        if let streamingBehavior { fields["streamingBehavior"] = .string(streamingBehavior) }
        _ = try await send("prompt", fields)
    }

    public func steer(_ message: String) async throws {
        _ = try await send("steer", ["message": .string(message)])
    }

    public func followUp(_ message: String) async throws {
        _ = try await send("follow_up", ["message": .string(message)])
    }

    public func abort() {
        post("abort")
    }

    public func state() async throws -> JSONValue? {
        try await send("get_state", timeout: 30)
    }

    public func stats() async throws -> JSONValue? {
        try await send("get_session_stats", timeout: 30)
    }

    public func availableModels() async throws -> [ModelSpec] {
        let data = try await send("get_available_models", timeout: 60)
        return (data?["models"]?.arrayValue ?? []).map(ModelSpec.init(rpc:))
    }

    public func setModel(provider: String, model: String) async throws {
        _ = try await send("set_model", [
            "provider": .string(provider), "model": .string(model),
        ])
    }

    public func setThinkingLevel(_ level: String) async throws {
        _ = try await send("set_thinking_level", ["level": .string(level)])
    }

    public func setSessionName(_ name: String) async throws {
        _ = try await send("set_session_name", ["name": .string(name)])
    }

    public func compact() async throws {
        _ = try await send("compact", timeout: 600)
    }

    public func runBash(_ command: String) async throws -> JSONValue? {
        try await send("bash", ["command": .string(command)], timeout: 300)
    }

    public func commands() async throws -> JSONValue? {
        try await send("get_commands", timeout: 30)
    }

    /// Close stdin so the engine exits cleanly at EOF; escalate only if it lingers.
    public func stop() async {
        guard let p = process else { return }
        try? stdinHandle?.close()
        stdinHandle = nil
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if p.isRunning { p.terminate() }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    public var pid: Int32? { process?.processIdentifier }
}
