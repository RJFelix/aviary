import Foundation

// The model side of an in-house agent: message shapes, tool schemas, and a streaming client.
//
// Deliberately narrow. This is not a general provider abstraction — it is the smallest surface
// an agent loop needs, which is: send a conversation plus tool schemas, receive text, thinking,
// tool calls and usage as they arrive. Everything provider-specific lives behind `ChatProvider`
// so a second wire format is a new conformance rather than a change here.

// MARK: - Conversation

public enum ChatRole: String, Sendable, Codable {
    case system, user, assistant, tool
}

public enum ChatContent: Sendable, Hashable {
    case text(String)
    /// Visible reasoning. Absent on routes that encrypt it — where `Usage.reasoning` is the
    /// only evidence the tokens existed at all.
    case thinking(String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case toolResult(id: String, name: String, text: String, isError: Bool)
    case image(mimeType: String, base64: String)
}

public struct ChatMessage: Sendable, Hashable {
    public var role: ChatRole
    public var content: [ChatContent]

    public init(role: ChatRole, content: [ChatContent]) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: [.text(text)]) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: [.text(text)]) }

    public var plainText: String {
        content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
    }

    public var toolCalls: [(id: String, name: String, arguments: JSONValue)] {
        content.compactMap {
            if case .toolCall(let i, let n, let a) = $0 { return (i, n, a) } else { return nil }
        }
    }
}

public struct ChatTool: Sendable, Hashable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments object.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatRequest: Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ChatTool]
    public var maxTokens: Int?
    public var temperature: Double?
    /// Provider-specific effort label ("low"/"medium"/"high"/…). Ignored where unsupported.
    public var reasoningEffort: String?

    public init(
        model: String, messages: [ChatMessage], tools: [ChatTool] = [],
        maxTokens: Int? = nil, temperature: Double? = nil, reasoningEffort: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
    }
}

// MARK: - Streaming

public enum ChatEvent: Sendable {
    /// The exact serialized request, before it goes out.
    ///
    /// The harness could only offer this through an extension hook, and even then the payload
    /// was whatever the harness had already built. Owning the provider means the "what was
    /// sent" breakdown is a first-class event rather than a debugging side channel — and it is
    /// emitted whether or not anybody is recording, because a caller that ignores it pays
    /// nothing.
    case requestBody(JSONValue)
    case textDelta(String)
    case thinkingDelta(String)
    /// A tool call, only once its arguments are complete — the loop has no use for a partial
    /// argument string, and assembling fragments is the provider's problem, not the caller's.
    case toolCall(id: String, name: String, arguments: JSONValue)
    case usage(Usage)
    case done(stopReason: String?)
}

public enum ChatError: LocalizedError {
    case notConfigured(String)
    case http(status: Int, body: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .http(let status, let body):
            // The body matters more than the code: a 401 whose body names an unexpanded
            // variable is a config bug, not a credential bug.
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "The provider answered \(status).\(trimmed.isEmpty ? "" : " \(trimmed.prefix(600))")"
        case .transport(let s): return "Could not reach the provider: \(s)"
        case .decoding(let s): return "Could not read the provider's response: \(s)"
        }
    }
}

public protocol ChatProvider: Sendable {
    var id: String { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

// MARK: - Server-sent events

/// Splits an SSE byte stream into payload strings.
///
/// Its own type because the framing is easy to get subtly wrong: events are separated by a
/// blank line, a single event may carry several `data:` lines that concatenate, and `[DONE]`
/// is a sentinel rather than JSON. Getting this wrong produces truncated tool arguments that
/// look like model misbehaviour.
public struct SSEParser {
    private var pending: [String] = []

    public init() {}

    public mutating func feed(line: String) -> String? {
        if line.isEmpty {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : pending.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        pending.append(value)
        return nil
    }

    /// Whatever is buffered when the stream ends without a trailing blank line.
    public mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : pending.joined(separator: "\n")
    }
}

/// Splits a byte stream into lines, **keeping empty ones**.
///
/// The distinction that matters for SSE: `AsyncLineSequence` drops blank lines, and a blank
/// line is how one event ends and the next begins.
struct SSELineSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String
    let base: Base

    struct AsyncIterator: AsyncIteratorProtocol {
        var inner: Base.AsyncIterator
        var buffer: [UInt8] = []
        var finished = false

        mutating func next() async throws -> String? {
            while true {
                guard let byte = try await inner.next() else {
                    if finished { return nil }
                    finished = true
                    // A trailing fragment with no newline is still a line.
                    if buffer.isEmpty { return nil }
                    let line = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll()
                    return line
                }
                if byte == UInt8(ascii: "\n") {
                    var bytes = buffer
                    buffer.removeAll(keepingCapacity: true)
                    if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
                    return String(decoding: bytes, as: UTF8.self)
                }
                buffer.append(byte)
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(inner: base.makeAsyncIterator())
    }
}

extension AsyncSequence where Element == UInt8 {
    var sseLines: SSELineSequence<Self> { SSELineSequence(base: self) }
}

// MARK: - OpenAI chat completions

/// The `openai-completions` wire format.
///
/// First and default because it is what every configured provider on this machine speaks,
/// including the LiteLLM gateway that fronts the rest — so one implementation reaches every
/// route that is actually in use, and keeps the gateway's metering intact.
public struct OpenAICompletionsProvider: ChatProvider {
    public let id: String
    public let baseURL: URL
    public let apiKey: String?
    public let extraHeaders: [String: String]
    public let session: URLSession

    public init(
        id: String, baseURL: URL, apiKey: String?, extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
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
        url.append(path: "chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let payload = Self.body(for: request)
        req.httpBody = try JSONEncoder().encode(payload)
        req.timeoutInterval = 600
        yield(.requestBody(payload))

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 16_384 { break } }
            throw ChatError.http(
                status: http.statusCode, body: String(data: body, encoding: .utf8) ?? "")
        }

        var parser = SSEParser()
        // Tool-call arguments arrive as fragments keyed by index, and only the first fragment
        // carries the id and name. Assembled here so the loop only ever sees whole calls.
        var callsByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
        var stopReason: String?
        var sawUsage = false

        func emitToolCalls() {
            for index in callsByIndex.keys.sorted() {
                guard let call = callsByIndex[index] else { continue }
                let parsed = JSONValue.parse(Data(call.arguments.utf8))
                    ?? .object([:])
                yield(.toolCall(id: call.id, name: call.name, arguments: parsed))
            }
            callsByIndex.removeAll()
        }

        // Raw bytes split by hand rather than `bytes.lines`.
        //
        // `AsyncLineSequence` **discards blank lines**, and in SSE the blank line *is* the
        // record separator — measured: five `data:` events arrived as five lines with no
        // separators between them, so a spec-correct parser emitted nothing at all and every
        // turn came back empty. Framing the stream is this function's job, not the stdlib's.
        for try await line in bytes.sseLines {
            guard let payload = parser.feed(line: line) else { continue }
            if payload == "[DONE]" { break }
            guard let v = JSONValue.parse(Data(payload.utf8)) else { continue }

            // An error can arrive mid-stream with a 200 status — LiteLLM does this when an
            // upstream route fails after headers are sent.
            if let message = v.path("error.message")?.stringValue {
                throw ChatError.http(status: v.path("error.code")?.intValue ?? 200, body: message)
            }

            if let usage = v["usage"], !usage.isNull {
                sawUsage = true
                yield(.usage(Self.usage(from: usage)))
            }

            guard let choice = (v["choices"]?.arrayValue ?? []).first else { continue }
            if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
                stopReason = reason
            }
            let delta: JSONValue = choice["delta"] ?? choice["message"] ?? .null

            if let text = delta["content"]?.stringValue, !text.isEmpty {
                yield(.textDelta(text))
            }
            // Two spellings in the wild: DeepSeek and LiteLLM use `reasoning_content`,
            // others `reasoning`. Both are visible thinking, unlike an encrypted route.
            for key in ["reasoning_content", "reasoning"] {
                if let t = delta[key]?.stringValue, !t.isEmpty { yield(.thinkingDelta(t)) }
            }

            for fragment in delta["tool_calls"]?.arrayValue ?? [] {
                let index = fragment["index"]?.intValue ?? 0
                var entry = callsByIndex[index] ?? (id: "", name: "", arguments: "")
                if let id = fragment["id"]?.stringValue, !id.isEmpty { entry.id = id }
                if let name = fragment.path("function.name")?.stringValue, !name.isEmpty {
                    entry.name = name
                }
                if let args = fragment.path("function.arguments")?.stringValue {
                    entry.arguments += args
                }
                callsByIndex[index] = entry
            }
        }
        if let tail = parser.flush(), tail != "[DONE]", let v = JSONValue.parse(Data(tail.utf8)),
           let usage = v["usage"], !usage.isNull, !sawUsage
        {
            yield(.usage(Self.usage(from: usage)))
        }

        emitToolCalls()
        yield(.done(stopReason: stopReason))
    }

    // MARK: Encoding

    public static func body(for request: ChatRequest) -> JSONValue {
        var obj: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(request.messages.flatMap { encode($0) }),
            "stream": .bool(true),
            // Without this most servers omit usage entirely when streaming, and a run with no
            // token counts cannot be costed or budgeted.
            "stream_options": .object(["include_usage": .bool(true)]),
        ]
        if let maxTokens = request.maxTokens { obj["max_tokens"] = .number(Double(maxTokens)) }
        if let temperature = request.temperature { obj["temperature"] = .number(temperature) }
        if let effort = request.reasoningEffort { obj["reasoning_effort"] = .string(effort) }
        if !request.tools.isEmpty {
            obj["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters,
                    ]),
                ])
            })
            obj["tool_choice"] = .string("auto")
        }
        return .object(obj)
    }

    /// One `ChatMessage` can become several wire messages: this format puts each tool result
    /// in its own message with a `tool_call_id`, rather than grouping them.
    public static func encode(_ message: ChatMessage) -> [JSONValue] {
        var out: [JSONValue] = []
        var text = ""
        var calls: [JSONValue] = []
        var images: [JSONValue] = []

        for block in message.content {
            switch block {
            case .text(let t):
                text += text.isEmpty ? t : "\n" + t
            case .thinking:
                // Not sent back. Providers reject foreign reasoning blocks, and on encrypted
                // routes the text was never the real thing anyway.
                continue
            case .toolCall(let id, let name, let arguments):
                calls.append(.object([
                    "id": .string(id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(name),
                        "arguments": .string(arguments.compactJSON),
                    ]),
                ]))
            case .toolResult(let id, _, let output, _):
                out.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(id),
                    "content": .string(output),
                ]))
            case .image(let mimeType, let base64):
                images.append(.object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:\(mimeType);base64,\(base64)"),
                    ]),
                ]))
            }
        }

        if !text.isEmpty || !calls.isEmpty || !images.isEmpty {
            var obj: [String: JSONValue] = ["role": .string(message.role.rawValue)]
            if images.isEmpty {
                obj["content"] = .string(text)
            } else {
                var parts: [JSONValue] = []
                if !text.isEmpty {
                    parts.append(.object(["type": .string("text"), "text": .string(text)]))
                }
                parts.append(contentsOf: images)
                obj["content"] = .array(parts)
            }
            if !calls.isEmpty { obj["tool_calls"] = .array(calls) }
            out.insert(.object(obj), at: 0)
        }
        return out
    }

    public static func usage(from v: JSONValue) -> Usage {
        var u = Usage()
        u.input = v["prompt_tokens"]?.intValue ?? 0
        u.output = v["completion_tokens"]?.intValue ?? 0
        u.cacheRead = v.path("prompt_tokens_details.cached_tokens")?.intValue ?? 0
        // Preserved rather than discarded — the one divergence the harness fork carried, for
        // the same reason: on an encrypted-reasoning route this is the only evidence the
        // tokens existed, and nil is not zero.
        u.reasoning = v.path("completion_tokens_details.reasoning_tokens")?.intValue
        u.totalTokens = v["total_tokens"]?.intValue ?? (u.input + u.output)
        return u
    }
}
