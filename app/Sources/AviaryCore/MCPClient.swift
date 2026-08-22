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

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let s): return "Could not start the MCP server: \(s)"
            case .protocolError(let s): return "The MCP server misbehaved: \(s)"
            case .timedOut(let s): return "The MCP server did not answer \(s) in time."
            }
        }
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

        _ = try await send("initialize", params: .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object(["tools": .object([:])]),
            "clientInfo": .object([
                "name": .string("aviary"), "version": .string("1"),
            ]),
        ]), timeout: timeout)
        // A notification, so no id and no reply expected. Servers that wait for it before
        // answering anything else are common enough that skipping it looks like a hang.
        notify("notifications/initialized")

        let listed = try await send("tools/list", params: .object([:]), timeout: timeout)
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

    public func callTool(_ toolName: String, arguments: JSONValue, timeout: TimeInterval = 300)
        async throws -> (text: String, isError: Bool)
    {
        let result = try await send("tools/call", params: .object([
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
            waiter.resume(throwing: MCPError.protocolError(
                error["message"]?.stringValue ?? error.compactJSON))
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
