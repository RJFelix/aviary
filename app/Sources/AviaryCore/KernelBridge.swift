import Foundation
import Network
import Security

/// The channel that lets a driven Claude Code reach Aviary's live kernel.
///
/// The shape is forced by how MCP works: Claude Code *spawns* its MCP servers, so the process
/// that answers `tools/call` is a child of `claude`, not of Aviary. It therefore cannot hold
/// the kernel — the kernel is Aviary's, with its Python state, its skills and its `spawn`
/// callbacks. So the spawned process is a courier, and this is what it delivers to.
///
/// ```
/// Aviary ──▶ claude -p ──▶ Aviary --mcp-bridge   (MCP on stdio)
///    ▲                              │
///    └──────── this socket ─────────┘
///    │
///    └──▶ RuntimeHost (python3 host.py)         (the actual kernel)
/// ```
///
/// Loopback TCP rather than a Unix socket, and a token rather than file permissions: the token
/// reaches the courier through its **environment**, which another user cannot read, whereas
/// anything in `--mcp-config` is in the courier's argv and so is visible in `ps` to anybody on
/// the machine. Since this endpoint runs arbitrary Python on request, "anybody on the machine"
/// is the threat worth closing, and an argv-visible path to an unauthenticated port would have
/// left it open.
public actor KernelBridge {

    /// One tool this bridge offers, and what running it does.
    public struct Tool: Sendable {
        public var name: String
        public var description: String
        public var schema: JSONValue
        /// Runs the tool. Returns the text the model should see, and whether it failed.
        public var run: @Sendable (JSONValue) async -> (text: String, isError: Bool)

        public init(
            name: String, description: String, schema: JSONValue,
            run: @escaping @Sendable (JSONValue) async -> (text: String, isError: Bool)
        ) {
            self.name = name
            self.description = description
            self.schema = schema
            self.run = run
        }
    }

    /// Where a courier should connect, and with what.
    public struct Endpoint: Sendable {
        public var port: UInt16
        public var token: String

        /// The environment the courier needs. Passed through `--mcp-config`'s `env` block,
        /// which Claude Code hands to the server process it spawns.
        public var environment: [String: String] {
            ["AVIARY_BRIDGE_PORT": String(port), "AVIARY_BRIDGE_TOKEN": token]
        }
    }

    public enum BridgeError: LocalizedError {
        case listenFailed(String)

        public var errorDescription: String? {
            switch self {
            case .listenFailed(let s): return "Could not open the kernel bridge: \(s)"
            }
        }
    }

    private var tools: [String: Tool] = [:]
    private var listener: NWListener?
    private var token = ""
    /// Set once a courier has authenticated, so a failure to connect is distinguishable from
    /// a model that simply never called the tool.
    public private(set) var connections = 0
    public private(set) var calls = 0
    public private(set) var rejectedConnections = 0
    /// Calls for a tool this bridge does not offer. Kept apart from `calls` because "the model
    /// used the kernel" and "the model reached for something that is not there" are different
    /// diagnoses — the second usually means the system prompt is describing a tool that was
    /// never attached.
    public private(set) var unknownToolCalls = 0

    public init() {}

    public func offer(_ tools: [Tool]) {
        for tool in tools { self.tools[tool.name] = tool }
    }

    /// Start listening. Returns what the courier needs to reach us.
    public func start() async throws -> Endpoint {
        let token = Self.newToken()
        self.token = token

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only. Without pinning the local endpoint, NWListener binds every interface,
        // which would put a kernel that runs arbitrary Python on the local network.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw BridgeError.listenFailed(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { await self?.accept(connection) }
        }
        listener.start(queue: .global())

        // The port is assigned asynchronously, so wait for it rather than reading `.port`
        // immediately — it is nil until the listener is actually ready.
        let port = try await Self.awaitPort(of: listener)
        self.listener = listener
        return Endpoint(port: port, token: token)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func awaitPort(of listener: NWListener) async throws -> UInt16 {
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            if case .failed(let error) = listener.state {
                throw BridgeError.listenFailed(error.localizedDescription)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        throw BridgeError.listenFailed("the listener never reported a port")
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Serving one courier

    private func accept(_ connection: NWConnection) {
        receive(connection, framer: LineFramer())
    }

    private nonisolated func receive(_ connection: NWConnection, framer: LineFramer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let data, !data.isEmpty {
                for line in framer.feed(data) {
                    Task { await self.handle(line: line, on: connection) }
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, framer: framer)
        }
    }

    /// A connection is trusted once it has presented the token, and untrusted before.
    private var authenticatedConnections: Set<ObjectIdentifier> = []

    private func handle(line: Data, on connection: NWConnection) async {
        guard let request = JSONValue.parse(line) else {
            reply(.object(["error": .string("Malformed request.")]), on: connection)
            return
        }
        let id = request["id"] ?? .null
        let key = ObjectIdentifier(connection)

        switch request["op"]?.stringValue {
        case "hello":
            // Constant-time is overkill for a local token that is regenerated per run, but
            // comparing full length rather than a prefix costs nothing.
            guard request["token"]?.stringValue == token, !token.isEmpty else {
                rejectedConnections += 1
                reply(.object(["id": id, "error": .string("Unauthorized.")]), on: connection)
                connection.cancel()
                return
            }
            authenticatedConnections.insert(key)
            connections += 1
            reply(.object(["id": id, "ok": .bool(true)]), on: connection)

        case "tools":
            guard authenticatedConnections.contains(key) else {
                reply(.object(["id": id, "error": .string("Say hello first.")]), on: connection)
                return
            }
            let listed = tools.values.sorted { $0.name < $1.name }.map { tool in
                JSONValue.object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.schema,
                ])
            }
            reply(.object(["id": id, "tools": .array(listed)]), on: connection)

        case "call":
            guard authenticatedConnections.contains(key) else {
                reply(.object(["id": id, "error": .string("Say hello first.")]), on: connection)
                return
            }
            guard let name = request["name"]?.stringValue, let tool = tools[name] else {
                unknownToolCalls += 1
                reply(.object([
                    "id": id,
                    "text": .string("No such tool: \(request["name"]?.stringValue ?? "?")"),
                    "isError": .bool(true),
                ]), on: connection)
                return
            }
            calls += 1
            // Not awaited inline: a long kernel call must not stall this actor, or a second
            // tool call — or the run's own bookkeeping — waits behind it.
            let arguments = request["arguments"] ?? .object([:])
            Task {
                let result = await tool.run(arguments)
                self.reply(.object([
                    "id": id,
                    "text": .string(result.text),
                    "isError": .bool(result.isError),
                ]), on: connection)
            }

        default:
            reply(.object(["id": id, "error": .string("Unknown op.")]), on: connection)
        }
    }

    private nonisolated func reply(_ value: JSONValue, on connection: NWConnection) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else { return }
        data.append(UInt8(ascii: "\n"))
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
