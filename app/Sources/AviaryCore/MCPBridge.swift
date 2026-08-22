import Foundation
import Network

/// The courier: an MCP server on stdio that forwards every tool call to a running Aviary.
///
/// Claude Code spawns this as `Aviary --mcp-bridge`, so it is the same binary in a different
/// mode rather than a second artifact to keep in step. It holds no state and makes no
/// decisions: the tool list and every result come from the Aviary that opened the
/// `KernelBridge`, because that is where the kernel lives.
///
/// Deliberately not an `MCPClient` in reverse. The client half of MCP in this codebase does
/// three verbs; this does the same three from the other side, and resources, prompts and
/// sampling are absent rather than stubbed — a half-answered capability advertises itself as
/// working.
public final class MCPBridge: @unchecked Sendable {

    /// MCP protocol version. Matches what `MCPClient` speaks, so both halves move together.
    static let protocolVersion = "2024-11-05"

    private let port: UInt16
    private let token: String
    private var connection: NWConnection?
    private let framer = LineFramer()
    private let lock = NSLock()
    private var pending: [Int: (JSONValue) -> Void] = [:]
    private var nextID = 1
    /// Tools as the running Aviary described them, fetched once at handshake.
    private var tools: [JSONValue] = []

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    /// Read the endpoint out of the environment.
    ///
    /// Environment rather than argv: this process's command line is visible in `ps` to every
    /// user on the machine, and the token is what stops any of them from reaching a kernel
    /// that runs arbitrary Python.
    public static func fromEnvironment() -> MCPBridge? {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["AVIARY_BRIDGE_PORT"].flatMap(UInt16.init),
              let token = env["AVIARY_BRIDGE_TOKEN"], !token.isEmpty
        else { return nil }
        return MCPBridge(port: port, token: token)
    }

    // MARK: Talking to Aviary

    private func connect() throws {
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        connection.start(queue: .global())
        _ = ready.wait(timeout: .now() + 10)
        guard case .ready = connection.state else {
            throw BridgeFailure.unreachable("no answer on 127.0.0.1:\(port)")
        }
        self.connection = connection
        receive()

        guard let hello = request(["op": .string("hello"), "token": .string(token)], timeout: 10),
              hello["ok"]?.boolValue == true
        else { throw BridgeFailure.unreachable("the bridge refused this token") }

        tools = request(["op": .string("tools")], timeout: 20)?["tools"]?.arrayValue ?? []
    }

    enum BridgeFailure: LocalizedError {
        case unreachable(String)
        var errorDescription: String? {
            switch self {
            case .unreachable(let s): return "Aviary's kernel bridge is unreachable: \(s)"
            }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for line in self.framer.feed(data) {
                    guard let value = JSONValue.parse(line) else { continue }
                    let id = value["id"]?.intValue ?? -1
                    self.lock.lock()
                    let handler = self.pending.removeValue(forKey: id)
                    self.lock.unlock()
                    handler?(value)
                }
            }
            if isComplete || error != nil { return }
            self.receive()
        }
    }

    /// One round trip, synchronously.
    ///
    /// Blocking is right here and nowhere else in this codebase: this process is a courier
    /// whose whole job is one request at a time, it has no UI and no actor to starve, and MCP
    /// on stdio is itself sequential. A semaphore that blocks the only thread doing work is
    /// simpler than a continuation, and cannot deadlock the way one bridging onto the
    /// MainActor would.
    private func request(_ body: [String: JSONValue], timeout: TimeInterval) -> JSONValue? {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()

        var payload = body
        payload["id"] = .number(Double(id))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(JSONValue.object(payload)) else { return nil }
        data.append(UInt8(ascii: "\n"))

        let done = DispatchSemaphore(value: 0)
        var answer: JSONValue?
        lock.lock()
        pending[id] = { value in
            answer = value
            done.signal()
        }
        lock.unlock()

        connection?.send(content: data, completion: .contentProcessed { _ in })
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            pending.removeValue(forKey: id)
            lock.unlock()
            return nil
        }
        return answer
    }

    // MARK: Serving MCP on stdio

    /// Run until stdin closes. Never returns.
    public func serve() -> Never {
        do {
            try connect()
        } catch {
            // Reported on stderr and then kept alive: Claude Code treats an MCP server that
            // exits at startup as a connection failure and says nothing useful about why. A
            // server that stays up and answers every call with the reason puts the actual
            // problem in front of the model, and therefore in the transcript.
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        }

        let stdin = FileHandle.standardInput
        let inFramer = LineFramer()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { exit(0) }
            for line in inFramer.feed(chunk) {
                guard let message = JSONValue.parse(line) else { continue }
                handle(message)
            }
        }
    }

    private func handle(_ message: JSONValue) {
        let method = message["method"]?.stringValue ?? ""
        let id = message["id"]

        switch method {
        case "initialize":
            respond(id: id, result: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("aviary-kernel"), "version": .string("1"),
                ]),
            ]))

        case "notifications/initialized", "notifications/cancelled":
            // Notifications carry no id and take no reply. Answering one is a protocol error.
            break

        case "tools/list":
            respond(id: id, result: .object(["tools": .array(tools)]))

        case "tools/call":
            let name = message.path("params.name")?.stringValue ?? ""
            let arguments = message.path("params.arguments") ?? .object([:])
            // Generous: a kernel call can legitimately run for minutes, and the ceiling that
            // matters is the runtime host's own, not a guess made here.
            let reply = request([
                "op": .string("call"), "name": .string(name), "arguments": arguments,
            ], timeout: 900)
            let text = reply?["text"]?.stringValue
                ?? reply?["error"]?.stringValue
                ?? "Aviary did not answer this call. The run may have ended."
            respond(id: id, result: .object([
                "content": .array([.object([
                    "type": .string("text"), "text": .string(text),
                ])]),
                "isError": .bool(reply?["isError"]?.boolValue ?? (reply == nil)),
            ]))

        case "ping":
            respond(id: id, result: .object([:]))

        default:
            guard id != nil else { break }
            respond(id: id, error: (-32_601, "Method not found: \(method)"))
        }
    }

    private func respond(id: JSONValue?, result: JSONValue) {
        write(.object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result]))
    }

    private func respond(id: JSONValue?, error: (code: Int, message: String)) {
        write(.object([
            "jsonrpc": .string("2.0"), "id": id ?? .null,
            "error": .object([
                "code": .number(Double(error.code)), "message": .string(error.message),
            ]),
        ]))
    }

    private func write(_ value: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }
}
