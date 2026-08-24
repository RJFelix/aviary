import Foundation

/// A stdio MCP client: tools from another process, exposed to the agent.
///
/// Kept small on purpose. MCP is a large specification and an agent needs three verbs from it
/// — what tools do you have, run one, and stay alive — so that is what this implements.
/// Resources, prompts, sampling and notifications are absent rather than half-present, because
/// a half-implemented capability is worse than a missing one: it looks available.
///
/// Why bother when the runtime can already run any Python: an MCP server is *someone else's*
/// tool with a schema, and the difference matters for things the runtime cannot reach —
/// authenticated services, another app's state, a vendor's own client.
public actor MCPClient {
    public struct Tool: Sendable, Hashable {
        public var name: String
        public var description: String
        public var schema: JSONValue
        /// The server this came from, so a name collision between servers is resolvable.
        public var server: String

        /// The name the model sees. Namespaced, because two servers may both offer `search`
        /// and a bare name would make the collision silent.
        public var qualifiedName: String { "mcp__\(server)__\(name)" }
    }

    public enum MCPError: LocalizedError {
        case launchFailed(String)
        case protocolError(String)
        case timedOut(String)
        /// The server needs something back from us mid-request. See `Era.modern`.
        case inputRequired(String)
        case noMutualVersion(supported: [String])

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let s): return "Could not start the MCP server: \(s)"
            case .protocolError(let s): return "The MCP server misbehaved: \(s)"
            case .timedOut(let s): return "The MCP server did not answer \(s) in time."
            case .inputRequired(let s):
                return "The MCP server asked for input Aviary does not provide (\(s)). "
                    + "Sampling, roots and elicitation are all deprecated in 2026-07-28 and "
                    + "this client declares none of them."
            case .noMutualVersion(let supported):
                return "No protocol version in common. The server speaks "
                    + "\(supported.joined(separator: ", ")); Aviary speaks "
                    + "\(MCPClient.supportedVersions.joined(separator: ", "))."
            }
        }
    }

    /// Which era of the protocol a server turned out to speak.
    ///
    /// 2026-07-28 removed the `initialize` handshake outright: version, identity and
    /// capabilities now ride in `_meta` on every request, and nothing is inferred from the
    /// connection. That is a genuine improvement for a client like this one — a server is a
    /// process we may reuse across unrelated sessions, and the old model quietly assumed a
    /// connection *was* a conversation.
    ///
    /// But most servers in the wild are still handshake-based, so this is dual-era: prefer
    /// modern, fall back rather than fail.
    public enum Era: Sendable, Hashable {
        case modern(version: String)
        case legacy(version: String)

        public var version: String {
            switch self {
            case .modern(let v), .legacy(let v): return v
            }
        }

        public var isModern: Bool {
            if case .modern = self { return true }
            return false
        }

        public var label: String {
            switch self {
            case .modern(let v): return "\(v) (stateless)"
            case .legacy(let v): return "\(v) (handshake)"
            }
        }
    }

    /// Newest first. Modern versions are tried before legacy ones.
    public static let supportedVersions = ["2026-07-28"]
    /// What we will settle for behind an `initialize` handshake, newest first.
    public static let supportedLegacyVersions = ["2025-11-25", "2025-06-18", "2024-11-05"]

    /// JSON-RPC error codes the 2026-07-28 spec reserves. Seeing one of these *is* the
    /// evidence that a server is modern, which is what makes the stdio probe work.
    enum ErrorCode {
        static let methodNotFound = -32601
        static let headerMismatch = -32020
        static let missingClientCapability = -32021
        static let unsupportedProtocolVersion = -32022

        /// The range the spec reserves for itself. Anything in it identifies a modern server
        /// even if this client does not recognise the specific code.
        static func isModernSpecCode(_ code: Int) -> Bool { (-32099...(-32020)).contains(code) }
    }

    /// A JSON-RPC error with its code kept, because the code is load-bearing here rather than
    /// merely informative: it decides which era the server is.
    struct RPCFailure: LocalizedError {
        var code: Int
        var message: String
        var data: JSONValue?

        var errorDescription: String? { "The MCP server refused (\(code)): \(message)" }
    }

    public let name: String
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [Int: CheckedContinuation<JSONValue?, Error>] = [:]
    private var nextID = 0
    public private(set) var tools: [Tool] = []
    public private(set) var isRunning = false
    /// Settled once, at start, and cached for the life of the process — the spec is explicit
    /// that era is a property of the server, not of a request.
    public private(set) var era: Era?
    /// What the server said it is, for the Library and for diagnostics.
    public private(set) var serverInfo: String?
    public private(set) var instructions: String?
    /// The freshness hint from `tools/list`, kept so a future cache has something to key on
    /// rather than re-deriving a policy the server already stated.
    public private(set) var toolsTTL: TimeInterval?
    private var stderrTail: [String] = []

    public init(
        name: String, executable: String, arguments: [String],
        environment: [String: String] = [:]
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// Start, handshake, and list tools. One call because a server that starts and cannot
    /// list tools is of no use, so there is nothing to do between the two steps.
    @discardableResult
    public func start(timeout: TimeInterval = 30) async throws -> [Tool] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env = ProcessEnvironment.shared.snapshot
        for (k, v) in environment { env[k] = v }
        if (env["PATH"] ?? "").isEmpty {
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let framer = LineFramer()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for line in framer.feed(chunk) {
                Task { await self?.ingest(line) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            if let s = String(data: chunk, encoding: .utf8) {
                Task { await self?.noteStderr(s) }
            }
        }
        p.terminationHandler = { [weak self] _ in Task { await self?.handleExit() } }

        do { try p.run() } catch { throw MCPError.launchFailed(error.localizedDescription) }
        process = p
        stdin = inPipe.fileHandleForWriting
        isRunning = true

        era = try await settleEra(timeout: timeout)

        let listed = try await call("tools/list", params: .object([:]), timeout: timeout)
        if let ttl = listed?["ttlMs"]?.doubleValue, ttl > 0 { toolsTTL = ttl / 1000 }
        tools = (listed?["tools"]?.arrayValue ?? []).compactMap { entry in
            guard let toolName = entry["name"]?.stringValue else { return nil }
            return Tool(
                name: toolName,
                description: entry["description"]?.stringValue ?? "",
                schema: entry["inputSchema"] ?? .object(["type": .string("object")]),
                server: name)
        }
        return tools
    }

    /// Work out which protocol the server on the other end speaks, once.
    ///
    /// The algorithm is the spec's own stdio probe. `server/discover` is a method only a
    /// modern server has, and on stdio there is no status code to read, so the *shape of the
    /// failure* is the signal: a recognised modern error code means a modern server that
    /// merely disliked something, and anything else — unknown method, silence, a timeout —
    /// means a handshake-era server.
    ///
    /// Falling back rather than failing is the whole point. Nearly every server published
    /// today is still handshake-based, and a client that only spoke the new protocol would
    /// have an ecosystem of one.
    private func settleEra(timeout: TimeInterval) async throws -> Era {
        let preferred = Self.supportedVersions[0]
        do {
            let result = try await call(
                "server/discover", params: .object([:]),
                timeout: min(timeout, 10), version: preferred)
            let offered = (result?["supportedVersions"]?.arrayValue ?? [])
                .compactMap(\.stringValue)
            serverInfo = result?["_meta"]?["io.modelcontextprotocol/serverInfo"]
                .map { "\($0["name"]?.stringValue ?? "?") \($0["version"]?.stringValue ?? "")" }
            instructions = result?["instructions"]?.stringValue
            // A reply without `supportedVersions` is not a DiscoverResult. Plenty of
            // handshake-era servers answer *any* unknown method with an empty object rather
            // than -32601 — the repo's own echo fixture does — and treating that as "modern,
            // use my preferred version" would send `_meta` to a server that ignores it and
            // then fail confusingly at the first real call.
            guard !offered.isEmpty else { return try await legacyHandshake(timeout: timeout) }
            guard let agreed = offered.first(where: { Self.supportedVersions.contains($0) })
            else {
                // Modern server, no version in common. Legacy is still worth a try — a
                // dual-era server that dropped our modern version may still handshake.
                if let legacy = try? await legacyHandshake(timeout: timeout) { return legacy }
                throw MCPError.noMutualVersion(supported: offered)
            }
            return .modern(version: agreed)
        } catch let failure as RPCFailure {
            if failure.code == ErrorCode.unsupportedProtocolVersion {
                let supported = (failure.data?["supported"]?.arrayValue ?? [])
                    .compactMap(\.stringValue)
                if let agreed = supported.first(where: { Self.supportedVersions.contains($0) }) {
                    return .modern(version: agreed)
                }
                if let legacy = try? await legacyHandshake(timeout: timeout) { return legacy }
                throw MCPError.noMutualVersion(supported: supported)
            }
            // Any other reserved-range code still identifies a modern server: it understood
            // the method and objected to something else.
            if ErrorCode.isModernSpecCode(failure.code) { return .modern(version: preferred) }
            return try await legacyHandshake(timeout: timeout)
        } catch is MCPError {
            // Silence or a timeout on an unknown method. Handshake-era.
            return try await legacyHandshake(timeout: timeout)
        }
    }

    /// The pre-2026 opening: `initialize`, then a notification the server may be waiting on.
    private func legacyHandshake(timeout: TimeInterval) async throws -> Era {
        var lastError: Error?
        // Offered newest-first. A server that dislikes a version it does not know is supposed
        // to answer with one it does, but enough of them error instead that walking down the
        // list is cheaper than arguing about whose fault that is.
        for candidate in Self.supportedLegacyVersions {
            do {
                let result = try await call("initialize", params: .object([
                    "protocolVersion": .string(candidate),
                    "capabilities": .object(["tools": .object([:])]),
                    "clientInfo": .object([
                        "name": .string("aviary"), "version": .string("1"),
                    ]),
                ]), timeout: timeout, version: nil)
                // A notification, so no id and no reply expected. Servers that wait for it
                // before answering anything else are common enough that skipping it looks
                // like a hang.
                notify("notifications/initialized")
                if let info = result?["serverInfo"] {
                    serverInfo = "\(info["name"]?.stringValue ?? "?") "
                        + "\(info["version"]?.stringValue ?? "")"
                }
                instructions = result?["instructions"]?.stringValue
                // Whatever it answered with is what it is speaking, not what we asked for.
                return .legacy(version: result?["protocolVersion"]?.stringValue ?? candidate)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MCPError.protocolError("initialize failed")
    }

    public func callTool(_ toolName: String, arguments: JSONValue, timeout: TimeInterval = 300)
        async throws -> (text: String, isError: Bool)
    {
        let result = try await call("tools/call", params: .object([
            "name": .string(toolName),
            "arguments": arguments,
        ]), timeout: timeout)
        // Content is a list of typed blocks; text is what an agent can act on, and anything
        // else is named rather than dropped so a caller can see something arrived.
        let blocks = result?["content"]?.arrayValue ?? []
        let text = blocks.compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text": return block["text"]?.stringValue
            case let other?: return "[\(other) content]"
            default: return nil
            }
        }.joined(separator: "\n")
        let isError = result?["isError"]?.boolValue ?? false
        return (text.isEmpty ? "(no content)" : text, isError)
    }

    public func stop() async {
        guard let p = process else { return }
        try? stdin?.close()
        stdin = nil
        try? await Task.sleep(nanoseconds: 300_000_000)
        if p.isRunning { p.terminate() }
        isRunning = false
    }

    public var diagnostics: String { stderrTail.joined() }

    // MARK: JSON-RPC

    /// One request, with whatever the settled era requires attached.
    ///
    /// `version` overrides the settled one — used by the probe, which has to declare a
    /// version before it knows whether the server understands the concept.
    private func call(
        _ method: String, params: JSONValue, timeout: TimeInterval, version: String? = nil
    ) async throws -> JSONValue? {
        var params = params
        let declared = version ?? (era?.isModern == true ? era?.version : nil)
        if let declared {
            // Every request carries its own version, identity and capabilities. Nothing is
            // remembered between them — that is the entire point of the 2026-07-28 model, and
            // it is why there is no longer a handshake to get wrong.
            var meta = params["_meta"]?.objectValue ?? [:]
            meta["io.modelcontextprotocol/protocolVersion"] = .string(declared)
            meta["io.modelcontextprotocol/clientInfo"] = .object([
                "name": .string("aviary"), "version": .string("1"),
            ])
            // Declared empty and meaning it: Aviary implements none of roots, sampling or
            // elicitation — all three deprecated in this revision anyway — so a server that
            // needs one must say so with -32021 rather than discover it mid-call.
            meta["io.modelcontextprotocol/clientCapabilities"] = .object([:])
            var object = params.objectValue ?? [:]
            object["_meta"] = .object(meta)
            params = .object(object)
        }
        let result = try await send(method, params: params, timeout: timeout)
        // Absent means "complete" — that is what the spec requires of clients talking to
        // earlier-protocol servers, and it is what keeps one code path serving both eras.
        switch result?["resultType"]?.stringValue ?? "complete" {
        case "complete":
            return result
        case "input_required":
            let asked = (result?["inputRequests"]?.arrayValue ?? [])
                .compactMap { $0["method"]?.stringValue }
            throw MCPError.inputRequired(
                asked.isEmpty ? method : asked.joined(separator: ", "))
        case let other:
            // An unrecognised result type MUST be treated as invalid rather than guessed at.
            throw MCPError.protocolError("unknown resultType '\(other)' from \(method)")
        }
    }

    private func send(
        _ method: String, params: JSONValue, timeout: TimeInterval
    ) async throws -> JSONValue? {
        guard isRunning, let stdin else { throw MCPError.launchFailed("not running") }
        nextID += 1
        let id = nextID
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(message) else {
            throw MCPError.protocolError("could not encode \(method)")
        }
        data.append(UInt8(ascii: "\n"))

        return try await withThrowingTaskGroup(of: JSONValue?.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task {
                        await self.register(id, cont)
                        do { try stdin.write(contentsOf: data) }
                        catch { await self.fail(id, MCPError.launchFailed("stdin closed")) }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.fail(id, MCPError.timedOut(method))
                throw MCPError.timedOut(method)
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func notify(_ method: String) {
        guard let stdin else { return }
        let message = JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string(method),
            "params": .object([:]),
        ])
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(UInt8(ascii: "\n"))
        try? stdin.write(contentsOf: data)
    }

    private func ingest(_ data: Data) {
        guard let v = JSONValue.parse(data) else { return }
        // A notification from the server: no id, nothing waiting. Recorded rather than
        // dropped so an unexpected one is at least visible in diagnostics.
        guard let id = v["id"]?.intValue, let waiter = pending.removeValue(forKey: id) else {
            if v["method"] != nil { stderrTail.append("server notification: \(v.compactJSON)\n") }
            return
        }
        if let error = v["error"] {
            // The code is kept, not flattened into a message: which era the server belongs to
            // is decided by the code, and a string would have to be re-parsed to find out.
            waiter.resume(throwing: RPCFailure(
                code: error["code"]?.intValue ?? 0,
                message: error["message"]?.stringValue ?? error.compactJSON,
                data: error["data"]))
        } else {
            waiter.resume(returning: v["result"])
        }
    }

    private func register(_ id: Int, _ cont: CheckedContinuation<JSONValue?, Error>) {
        pending[id] = cont
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func noteStderr(_ s: String) {
        stderrTail.append(s)
        if stderrTail.count > 80 { stderrTail.removeFirst(stderrTail.count - 80) }
    }

    private func handleExit() {
        isRunning = false
        for (_, waiter) in pending {
            waiter.resume(throwing: MCPError.launchFailed("the server exited"))
        }
        pending.removeAll()
    }
}

/// MCP servers declared in the harness's `settings.json`, so a config that already works keeps
/// working rather than needing a second one.
///
/// Reads the shape `{"mcpServers": {"name": {"command": …, "args": [...], "env": {...}}}}`,
/// which is the de-facto standard across clients. Servers of any other transport (`sse`,
/// `http`) are skipped rather than half-started: this client speaks stdio, and pretending
/// otherwise would fail at the first call instead of at load.
public enum MCPConfiguration {
    public struct Server: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var command: String
        public var arguments: [String]
        public var environment: [String: String]
        public var enabled: Bool
    }

    public static func load(home: AgentHome) -> [Server] {
        guard let data = FileManager.default.contents(atPath: home.settingsFile.path),
              let root = JSONValue.parse(data)
        else { return [] }
        return parse(root)
    }

    static func parse(_ root: JSONValue) -> [Server] {
        var found: [Server] = []
        for key in ["mcpServers", "mcp_servers", "mcp"] {
            guard case .object(let servers)? = root[key] else { continue }
            for (name, spec) in servers.sorted(by: { $0.key < $1.key }) {
                let transport = spec["type"]?.stringValue ?? "stdio"
                guard transport == "stdio" else { continue }
                guard let command = spec["command"]?.stringValue, !command.isEmpty else { continue }
                var env: [String: String] = [:]
                if case .object(let vars)? = spec["env"] {
                    for (k, v) in vars { env[k] = v.stringValue ?? "" }
                }
                found.append(Server(
                    name: name,
                    command: command,
                    arguments: (spec["args"]?.arrayValue ?? []).compactMap { $0.stringValue },
                    environment: env,
                    // `disabled` rather than `enabled`, matching the convention other clients
                    // use, so an existing config means what it already meant.
                    enabled: !(spec["disabled"]?.boolValue ?? false)))
            }
            if !found.isEmpty { break }
        }
        return found
    }
}
