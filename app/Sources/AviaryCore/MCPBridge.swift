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
    /// What this server speaks, newest first.
    ///
    /// Dual-era on purpose. 2026-07-28 removed the `initialize` handshake, but the client on
    /// the other end of this pipe is Claude Code, whose era is not ours to choose — so the
    /// bridge answers whichever opening it gets: a request carrying modern `_meta` is served
    /// statelessly, an `initialize` selects handshake semantics. The spec's own guidance for
    /// a dual-era server, and the only version of this that cannot break the driven engine.
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2024-11-05"]
    /// Kept for the legacy handshake, whose reply must name a version the client asked about.
    static let protocolVersion = "2024-11-05"

    static let serverInfo = JSONValue.object([
        "name": .string("aviary-kernel"), "version": .string("1"),
    ])

    /// Every modern result carries `resultType` and identifies its sender. Additive JSON, so
    /// a handshake-era client simply ignores both rather than choking on them.
    static func complete(_ fields: [String: JSONValue]) -> JSONValue {
        var out = fields
        out["resultType"] = .string("complete")
        var meta = out["_meta"]?.objectValue ?? [:]
        meta["io.modelcontextprotocol/serverInfo"] = serverInfo
        out["_meta"] = .object(meta)
        return .object(out)
    }

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
        case "server/discover":
            // Servers MUST implement this in 2026-07-28, and on stdio it doubles as the
            // client's era probe: answering it at all is what tells a dual-era client it does
            // not need the handshake.
            respond(id: id, result: Self.complete([
                "supportedVersions": .array(
                    ([Self.modernVersion] + Self.legacyVersions).map { .string($0) }),
                "capabilities": .object(["tools": .object([:])]),
                "instructions": .string(
                    "Aviary's Python kernel. One tool, `python`, running in a persistent "
                        + "interpreter that keeps its variables between calls."),
                // The tool list changes only when a run's capabilities change, which cannot
                // happen mid-session. Private: it is this run's kernel, not a public service.
                "ttlMs": .number(300_000),
                "cacheScope": .string("private"),
            ]))

        case "initialize":
            // A legacy client. Echo a version it actually asked for where we can, because a
            // handshake client has no way to fall forward and this reply is all it gets.
            let asked = message.path("params.protocolVersion")?.stringValue
            let agreed = Self.legacyVersions.contains(asked ?? "")
                ? (asked ?? Self.protocolVersion)
                : Self.protocolVersion
            respond(id: id, result: .object([
                "protocolVersion": .string(agreed),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": Self.serverInfo,
            ]))

        case "notifications/initialized", "notifications/cancelled":
            // Notifications carry no id and take no reply. Answering one is a protocol error.
            break

        case "tools/list":
            respond(id: id, result: Self.complete([
                "tools": .array(tools),
                "ttlMs": .number(300_000),
                "cacheScope": .string("private"),
            ]))

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
            var content: [JSONValue] = [.object([
                "type": .string("text"), "text": .string(text),
            ])]
            // Images ride back inside the tool result, which is how a driven session sees one
            // at all: Aviary owns no part of Claude Code's message list, so the only channel
            // into its context is the result of the call it just made. MCP's own image block,
            // not a data: URI in the text — the client decodes this and the model sees a
            // picture rather than eighty thousand characters of base64.
            for image in reply?["images"]?.arrayValue ?? [] {
                guard let data = image["data"]?.stringValue,
                      let mime = image["mimeType"]?.stringValue
                else { continue }
                content.append(.object([
                    "type": .string("image"),
                    "data": .string(data),
                    "mimeType": .string(mime),
                ]))
            }
            respond(id: id, result: Self.complete([
                "content": .array(content),
                "isError": .bool(reply?["isError"]?.boolValue ?? (reply == nil)),
            ]))

        case "ping":
            // Removed in 2026-07-28, kept because a handshake-era client may still send it
            // and a "method not found" would read as a dead server.
            respond(id: id, result: Self.complete([:]))

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
