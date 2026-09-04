import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `anthropic-messages` wire format.
///
/// A second provider, and the point of having one is partly to prove `ChatProvider` is a real
/// abstraction rather than a rename of the first implementation. It differs from
/// chat-completions in every way that matters: the system prompt is a top-level field rather
/// than a message, tool results are user-role content blocks rather than their own role,
/// thinking is a first-class block type, and the stream is typed events rather than deltas on
/// a choice.
public struct AnthropicMessagesProvider: ChatProvider {
    public let id: String
    public let baseURL: URL
    public let apiKey: String?
    public let version: String
    public let extraHeaders: [String: String]
    public let session: URLSession

    public init(
        id: String, baseURL: URL, apiKey: String?, version: String = "2023-06-01",
        extraHeaders: [String: String] = [:], session: URLSession = .shared
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.version = version
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, yield: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: ChatRequest, yield: (ChatEvent) -> Void) async throws {
        var url = baseURL
        url.append(path: "messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        if let apiKey, !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let payload = Self.body(for: request)
        req.httpBody = try JSONEncoder().encode(payload)
        req.timeoutInterval = 600
        yield(.requestBody(payload))

        let (bytes, response) = try await AviaryURLSession.bytes(for: req, using: session)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 16_384 { break } }
            bytes.cancel()
            throw ChatError.http(
                status: http.statusCode, body: String(data: body, encoding: .utf8) ?? "")
        }

        var parser = SSEParser()
        // Content blocks arrive as start/delta/stop by index, so a tool call's arguments are
        // accumulated per block and only emitted once its block closes.
        var blocks: [Int: (type: String, id: String, name: String, buffer: String)] = [:]
        var stopReason: String?
        var usage = Usage()
        var sawUsage = false

        for try await line in bytes.sseLines {
            guard let payload = parser.feed(line: line) else { continue }
            guard let v = JSONValue.parse(Data(payload.utf8)) else { continue }
            let type = v["type"]?.stringValue ?? ""

            switch type {
            case "error":
                throw ChatError.http(
                    status: 200, body: v.path("error.message")?.stringValue ?? payload)

            case "message_start":
                // Input tokens are reported here, at the start, and never repeated.
                if let u = v.path("message.usage") {
                    usage.input = u["input_tokens"]?.intValue ?? 0
                    usage.cacheRead = u["cache_read_input_tokens"]?.intValue ?? 0
                    usage.cacheWrite = u["cache_creation_input_tokens"]?.intValue ?? 0
                    sawUsage = true
                }

            case "content_block_start":
                let index = v["index"]?.intValue ?? 0
                let block = v["content_block"] ?? .null
                blocks[index] = (
                    type: block["type"]?.stringValue ?? "text",
                    id: block["id"]?.stringValue ?? "",
                    name: block["name"]?.stringValue ?? "",
                    buffer: "")

            case "content_block_delta":
                let index = v["index"]?.intValue ?? 0
                let delta = v["delta"] ?? .null
                switch delta["type"]?.stringValue {
                case "text_delta":
                    let t = delta["text"]?.stringValue ?? ""
                    if !t.isEmpty { yield(.textDelta(t)) }
                case "thinking_delta":
                    let t = delta["thinking"]?.stringValue ?? ""
                    if !t.isEmpty { yield(.thinkingDelta(t)) }
                case "input_json_delta":
                    blocks[index]?.buffer += delta["partial_json"]?.stringValue ?? ""
                default:
                    break
                }

            case "content_block_stop":
                let index = v["index"]?.intValue ?? 0
                if let block = blocks.removeValue(forKey: index), block.type == "tool_use" {
                    // An empty buffer means a tool with no arguments, which is legal — so an
                    // empty object rather than a failure.
                    let parsed = block.buffer.isEmpty
                        ? JSONValue.object([:])
                        : (JSONValue.parse(Data(block.buffer.utf8)) ?? .object([:]))
                    yield(.toolCall(id: block.id, name: block.name, arguments: parsed))
                }

            case "message_delta":
                if let reason = v.path("delta.stop_reason")?.stringValue { stopReason = reason }
                if let u = v["usage"] {
                    usage.output = u["output_tokens"]?.intValue ?? usage.output
                    sawUsage = true
                }

            case "message_stop":
                if sawUsage {
                    usage.totalTokens = usage.input + usage.output
                    yield(.usage(usage))
                }
                yield(.done(stopReason: stopReason))
                return

            default:
                break
            }
        }
        if sawUsage {
            usage.totalTokens = usage.input + usage.output
            yield(.usage(usage))
        }
        yield(.done(stopReason: stopReason))
    }

    // MARK: Encoding

    public static func body(for request: ChatRequest) -> JSONValue {
        // The system prompt is a top-level field here, not a message — sending it as one is
        // rejected, and it is the first thing that differs from chat-completions.
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.plainText)
            .joined(separator: "\n\n")
        let conversation = request.messages.filter { $0.role != .system }

        var obj: [String: JSONValue] = [
            "model": .string(request.model),
            // Required here, unlike chat-completions. A conservative default rather than an
            // error, so a caller that does not care still works.
            "max_tokens": .number(Double(request.maxTokens ?? 8192)),
            "messages": .array(Self.encode(conversation)),
            "stream": .bool(true),
        ]
        if !systemText.isEmpty { obj["system"] = .string(systemText) }
        if let temperature = request.temperature { obj["temperature"] = .number(temperature) }
        if !request.tools.isEmpty {
            obj["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters,
                ])
            })
        }
        // Extended thinking is a budget here, not a label. Mapped from the effort word so a
        // caller does not have to know which provider it is talking to.
        if let effort = request.reasoningEffort, let budget = Self.thinkingBudget(effort) {
            obj["thinking"] = .object([
                "type": .string("enabled"),
                "budget_tokens": .number(Double(budget)),
            ])
            // The budget has to fit inside max_tokens, and a request where it does not is
            // rejected — so raise the ceiling rather than let the caller trip over it.
            if (request.maxTokens ?? 8192) <= budget {
                obj["max_tokens"] = .number(Double(budget + 4096))
            }
        }
        return .object(obj)
    }

    static func thinkingBudget(_ effort: String) -> Int? {
        switch effort.lowercased() {
        case "minimal", "none", "off": return nil
        case "low": return 4_000
        case "medium": return 10_000
        case "high": return 24_000
        case "max", "xhigh": return 32_000
        default: return nil
        }
    }

    /// Consecutive same-role messages must merge, and a tool result is a `user` block rather
    /// than its own role — both differences from chat-completions that produce a 400 if missed.
    public static func encode(_ messages: [ChatMessage]) -> [JSONValue] {
        var out: [(role: String, blocks: [JSONValue])] = []

        func append(role: String, block: JSONValue) {
            if out.last?.role == role {
                out[out.count - 1].blocks.append(block)
            } else {
                out.append((role: role, blocks: [block]))
            }
        }

        for message in messages {
            for content in message.content {
                switch content {
                case .text(let t):
                    guard !t.isEmpty else { continue }
                    append(role: message.role == .assistant ? "assistant" : "user",
                           block: .object(["type": .string("text"), "text": .string(t)]))
                case .thinking:
                    // Not replayed: a thinking block without its original signature is
                    // rejected, and reconstructing one is not possible from the text.
                    continue
                case .toolCall(let id, let name, let arguments):
                    append(role: "assistant", block: .object([
                        "type": .string("tool_use"),
                        "id": .string(id),
                        "name": .string(name),
                        "input": arguments,
                    ]))
                case .toolResult(let id, _, let text, let isError):
                    append(role: "user", block: .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(id),
                        "content": .string(text),
                        "is_error": .bool(isError),
                    ]))
                case .image(let mimeType, let base64):
                    append(role: "user", block: .object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("base64"),
                            "media_type": .string(mimeType),
                            "data": .string(base64),
                        ]),
                    ]))
                }
            }
        }
        return out.map { .object(["role": .string($0.role), "content": .array($0.blocks)]) }
    }
}
