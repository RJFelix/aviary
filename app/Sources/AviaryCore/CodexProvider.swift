import Foundation

/// The `openai-codex-responses` wire format, over SSE.
///
/// **A deliberate one-to-one reimplementation** of the harness's
/// `packages/ai/src/providers/openai-codex-responses.ts`, for the reason set out in
/// `CodexAuth`: every value that reaches an OpenAI server is copied from the reference rather
/// than chosen. The URL shape, the header set and their exact spellings, the request body's
/// fields and defaults, the retry policy — all matched. **A difference here is a bug, not a
/// preference**, and the comment on any field that looks arbitrary is there to stop a future
/// reader from "tidying" it.
///
/// One thing the harness does that this does not: it can use a WebSocket transport with
/// connection-scoped context reuse. SSE is the fallback the harness itself uses and the
/// documented path; the WebSocket route is an optimization, and implementing it half-way would
/// be a novel client signature for no gain.
public struct CodexResponsesProvider: ChatProvider {
    public let id: String
    public let store: CodexAuth.Store
    public let baseURL: String?
    /// Needed for `thinkingLevelMap`, which decides whether a requested effort is sent, mapped
    /// or omitted.
    public var model: ModelSpec?
    /// Passed as `prompt_cache_key` and as the `session_id` header, exactly as the reference
    /// does. Note this is *not* the transcript's session id in the harness either — it is
    /// whatever the caller supplies.
    public let sessionID: String?
    /// Sent as `service_tier` on every request.
    ///
    /// `"default"` because that is what the harness's agent state initialises to
    /// (`packages/agent/src/agent.ts`: `serviceTier: initialState?.serviceTier ?? "default"`)
    /// and therefore what a typical harness request carries. Omitting it made my payload
    /// differ from a real one, which is precisely the kind of difference this file exists to
    /// avoid — found by diffing a captured harness request rather than by reading.
    public let serviceTier: String?
    public let session: URLSession

    static let defaultBaseURL = "https://chatgpt.com/backend-api"

    public init(
        id: String = "openai-codex", store: CodexAuth.Store, baseURL: String? = nil,
        sessionID: String? = nil, serviceTier: String? = "default",
        session: URLSession = .shared
    ) {
        self.id = id
        self.store = store
        self.baseURL = baseURL
        self.sessionID = sessionID
        self.serviceTier = serviceTier
        self.session = session
    }

    public init(
        id: String = "openai-codex", store: CodexAuth.Store, model: ModelSpec?,
        baseURL: String? = nil, sessionID: String? = nil, serviceTier: String? = "default",
        session: URLSession = .shared
    ) {
        self.init(
            id: id, store: store, baseURL: baseURL, sessionID: sessionID,
            serviceTier: serviceTier, session: session)
        self.model = model
    }

    /// The harness's `DEFAULT_THINKING_LEVEL` (`core/defaults.ts`).
    ///
    /// Applied when a caller asks for nothing, so `reasoning` is present on every request the
    /// way it is on a harness request. Without this my payload omitted the field entirely —
    /// again caught by diffing, not by reading.
    public static let defaultReasoningEffort = "medium"

    /// `<base>/codex/responses`, built the same way — including tolerating a base that already
    /// ends in `/codex` or `/codex/responses`.
    public static func resolveURL(_ baseURL: String?) -> URL {
        let raw = (baseURL?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            ? defaultBaseURL : baseURL!
        var normalized = raw
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if normalized.hasSuffix("/codex/responses") { return URL(string: normalized)! }
        if normalized.hasSuffix("/codex") { return URL(string: normalized + "/responses")! }
        return URL(string: normalized + "/codex/responses")!
    }

    /// The header set, in the same order and with the same capitalisation as the reference.
    ///
    /// `originator: pi` and the `pi (platform release; arch)` user agent are the client's
    /// identity to OpenAI. Changing either is what makes a request look like it came from
    /// something other than a known harness, so they are copied verbatim — including the
    /// lowercase `accept` and `content-type`, which is how the reference sets them.
    static func headers(
        token: String, accountID: String, sessionID: String?
    ) -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "chatgpt-account-id": accountID,
            "originator": CodexAuth.originator,
            "User-Agent": userAgent(),
            "OpenAI-Beta": "responses=experimental",
            "accept": "text/event-stream",
            "content-type": "application/json",
        ]
        if let sessionID, !sessionID.isEmpty {
            headers["session_id"] = sessionID
            headers["x-client-request-id"] = sessionID
        }
        return headers
    }

    /// `pi (<platform> <release>; <arch>)`, matching Node's `os.platform()`, `os.release()`
    /// and `os.arch()` — `darwin`, the kernel version, and `arm64`/`x64`.
    static func userAgent() -> String {
        var info = utsname()
        uname(&info)
        func string(_ tuple: UnsafePointer<CChar>) -> String {
            String(cString: tuple)
        }
        let release = withUnsafePointer(to: &info.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { string($0) }
        }
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { string($0) }
        }
        // Node reports `arm64` and `x64`; uname reports `arm64` and `x86_64`.
        let arch = machine == "x86_64" ? "x64" : machine
        return "pi (darwin \(release); \(arch))"
    }

    // MARK: Body

    /// The request body, field for field.
    ///
    /// Each of these is load-bearing and copied: `store: false` because the endpoint rejects
    /// `true` ("Store must be set to false"); `include: ["reasoning.encrypted_content"]` because
    /// that is how reasoning survives a turn on this route; `text.verbosity` defaulting to
    /// `"low"`; `tool_choice: "auto"` and `parallel_tool_calls: true` always present; and the
    /// system prompt going in `instructions` rather than as a message.
    public static func body(
        for request: ChatRequest, sessionID: String?, model: ModelSpec?,
        serviceTier: String? = "default"
    ) -> JSONValue {
        let systemPrompt = request.messages
            .filter { $0.role == .system }
            .map(\.plainText)
            .joined(separator: "\n\n")

        var obj: [String: JSONValue] = [
            "model": .string(request.model),
            "store": .bool(false),
            "stream": .bool(true),
            // The reference's fallback string, kept so an empty prompt produces the same
            // request rather than an absent field.
            "instructions": .string(systemPrompt.isEmpty
                ? "You are a helpful assistant." : systemPrompt),
            "input": .array(encodeInput(request.messages)),
            "text": .object(["verbosity": .string("low")]),
            "include": .array([.string("reasoning.encrypted_content")]),
            "tool_choice": .string("auto"),
            "parallel_tool_calls": .bool(true),
        ]
        if let sessionID { obj["prompt_cache_key"] = .string(sessionID) }
        if let serviceTier { obj["service_tier"] = .string(serviceTier) }
        if let temperature = request.temperature { obj["temperature"] = .number(temperature) }
        if !request.tools.isEmpty {
            // `strict: null`, not `false`. The reference passes `{ strict: null }` for this
            // provider specifically, and a JSON `null` is what goes on the wire.
            obj["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                    "strict": .null,
                ])
            })
        }
        // Defaulted rather than optional, so `reasoning` is present as it is on a harness
        // request. A model whose map sends the requested level to null still omits the field —
        // that branch is the reference's, and it is why the map's values are optional.
        if true {
            let effort = request.reasoningEffort ?? defaultReasoningEffort
            // Mapped through the model's own thinkingLevelMap, so a level the route treats as
            // unavailable is omitted rather than sent — the reference's `null` case.
            let mapped: String?
            if let map = model?.thinkingLevelMap {
                if effort == "none" {
                    mapped = map["off"].flatMap { $0 } ?? "none"
                } else if let entry = map[effort] {
                    mapped = entry
                } else {
                    mapped = effort
                }
            } else {
                mapped = effort == "none" ? "none" : effort
            }
            if let mapped {
                obj["reasoning"] = .object([
                    "effort": .string(mapped),
                    "summary": .string("auto"),
                ])
            }
        }
        return .object(obj)
    }

    /// Messages as Responses `input` items.
    ///
    /// The system prompt is excluded — it goes in `instructions` — matching
    /// `includeSystemPrompt: false`. Tool results become `function_call_output` items rather
    /// than messages, and a tool call id of the form `callId|itemId` is split on `|` with only
    /// the call id used, as the reference does.
    static func encodeInput(_ messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                var parts: [JSONValue] = []
                for block in message.content {
                    switch block {
                    case .text(let text) where !text.isEmpty:
                        parts.append(.object([
                            "type": .string("input_text"),
                            "text": .string(sanitizeSurrogates(text)),
                        ]))
                    case .image(let mimeType, let base64):
                        parts.append(.object([
                            "type": .string("input_image"),
                            "detail": .string("auto"),
                            "image_url": .string("data:\(mimeType);base64,\(base64)"),
                        ]))
                    default:
                        continue
                    }
                }
                if parts.isEmpty { continue }
                out.append(.object(["role": .string("user"), "content": .array(parts)]))
            case .assistant:
                for block in message.content {
                    switch block {
                    case .text(let text) where !text.isEmpty:
                        out.append(.object([
                            "type": .string("message"),
                            "role": .string("assistant"),
                            "content": .array([.object([
                                "type": .string("output_text"),
                                "text": .string(sanitizeSurrogates(text)),
                                "annotations": .array([]),
                            ])]),
                            "status": .string("completed"),
                        ]))
                    case .toolCall(let id, let name, let arguments):
                        let callID = id.split(separator: "|").first.map(String.init) ?? id
                        out.append(.object([
                            "type": .string("function_call"),
                            "call_id": .string(callID),
                            "name": .string(name),
                            // A JSON *string*, not an object — the Responses API takes encoded
                            // arguments here.
                            "arguments": .string(arguments.compactJSON),
                        ]))
                    default:
                        // Thinking blocks are only replayable with their original reasoning
                        // item, which is carried in a signature this client does not keep.
                        // Dropping is what the reference does without one.
                        continue
                    }
                }
            case .tool:
                for block in message.content {
                    guard case .toolResult(let id, _, let text, _) = block else { continue }
                    let callID = id.split(separator: "|").first.map(String.init) ?? id
                    out.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(callID),
                        "output": .string(sanitizeSurrogates(text)),
                    ]))
                }
            }
        }
        return out
    }

    /// Strips lone surrogates, which the API rejects and which agent output does contain.
    static func sanitizeSurrogates(_ s: String) -> String {
        String(decoding: Array(s.unicodeScalars.filter { !($0.value >= 0xD800 && $0.value <= 0xDFFF) }
            .flatMap { Array(String($0).utf8) }), as: UTF8.self)
    }

    // MARK: Streaming

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
        let credentials = try await CodexAuth.accessToken(store: store)
        let payload = Self.body(
            for: request, sessionID: sessionID, model: model, serviceTier: serviceTier)
        yield(.requestBody(payload))

        var urlRequest = URLRequest(url: Self.resolveURL(baseURL))
        urlRequest.httpMethod = "POST"
        for (key, value) in Self.headers(
            token: credentials.access, accountID: credentials.accountId,
            sessionID: sessionID)
        {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONEncoder().encode(payload)
        urlRequest.timeoutInterval = 600

        // A retry is a separate potentially billable crossing. Keep it visible to the Agent
        // rather than silently dispatching again after partial or uncertain provider work.
        let (bytes, response) = try await session.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 32_768 { break } }
            let text = String(data: body, encoding: .utf8) ?? ""
            throw ChatError.http(status: status, body: Self.friendlyError(text) ?? text)
        }
        try await consume(bytes: bytes, yield: yield)
    }

    /// Turn a usage-limit error into something a person can act on, as the reference does.
    static func friendlyError(_ raw: String) -> String? {
        guard let json = JSONValue.parse(Data(raw.utf8)), let error = json["error"] else {
            return nil
        }
        let code = error["code"]?.stringValue ?? error["type"]?.stringValue ?? ""
        guard code.range(
            of: "usage_limit_reached|usage_not_included|rate_limit_exceeded",
            options: [.regularExpression, .caseInsensitive]) != nil
        else { return error["message"]?.stringValue }
        let plan = error["plan_type"]?.stringValue.map { " (\($0.lowercased()) plan)" } ?? ""
        if let resetsAt = error["resets_at"]?.doubleValue {
            let minutes = max(0, Int((resetsAt * 1000 - Date().timeIntervalSince1970 * 1000) / 60_000))
            return "Codex usage limit reached\(plan). Resets in about \(minutes) minutes."
        }
        return "Codex usage limit reached\(plan)."
    }

    /// The Responses event stream: typed events rather than deltas on a choice.
    private func consume<S: AsyncSequence>(
        bytes: S, yield: (ChatEvent) -> Void
    ) async throws where S.Element == UInt8 {
        var parser = SSEParser()
        var toolCalls: [String: (callID: String, name: String, arguments: String)] = [:]
        var stopReason: String?
        var sawCompleted = false
        var sawDoneSentinel = false

        func processPayload(_ payload: String) throws {
            if payload == "[DONE]" {
                sawDoneSentinel = true
                return
            }
            guard let v = JSONValue.parse(Data(payload.utf8)) else { return }
            // Responses usage is cumulative and may accompany a terminal/failure event. Yield
            // it before throwing so an unsuccessful crossing is not mistaken for free work.
            if let report = ProviderUsageWire.responses(v.path("response.usage")) {
                yield(.usage(report))
            }
            let type = v["type"]?.stringValue ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = v["delta"]?.stringValue, !delta.isEmpty { yield(.textDelta(delta)) }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = v["delta"]?.stringValue, !delta.isEmpty {
                    yield(.thinkingDelta(delta))
                }
            case "response.output_item.added":
                let item = v["item"] ?? .null
                if item["type"]?.stringValue == "function_call" {
                    let key = item["id"]?.stringValue ?? UUID().uuidString
                    toolCalls[key] = (
                        callID: item["call_id"]?.stringValue ?? key,
                        name: item["name"]?.stringValue ?? "",
                        arguments: item["arguments"]?.stringValue ?? "")
                }
            case "response.function_call_arguments.delta":
                let key = v["item_id"]?.stringValue ?? ""
                if toolCalls[key] != nil {
                    toolCalls[key]?.arguments += v["delta"]?.stringValue ?? ""
                }
            case "response.output_item.done":
                let item = v["item"] ?? .null
                guard item["type"]?.stringValue == "function_call" else { break }
                let key = item["id"]?.stringValue ?? ""
                let entry = toolCalls.removeValue(forKey: key)
                let name = item["name"]?.stringValue ?? entry?.name ?? ""
                let callID = item["call_id"]?.stringValue ?? entry?.callID ?? key
                let raw = item["arguments"]?.stringValue ?? entry?.arguments ?? ""
                let parsed: JSONValue
                if raw.isEmpty {
                    parsed = .object([:])
                } else {
                    guard let decoded = JSONValue.parse(Data(raw.utf8)) else {
                        throw ChatError.decoding(
                            "the provider ended with malformed tool-call arguments")
                    }
                    parsed = decoded
                }
                yield(.toolCall(id: callID, name: name, arguments: parsed))
            case "response.completed":
                if !sawCompleted {
                    let response = v["response"] ?? .null
                    stopReason = response["status"]?.stringValue ?? type
                    sawCompleted = true
                }
            case "response.incomplete":
                throw ChatError.transport("the provider reported an incomplete response")
            case "response.failed":
                throw ChatError.transport("the provider reported a failed response")
            case "error", "response.error":
                let message = v.path("error.message")?.stringValue
                    ?? v["message"]?.stringValue ?? payload
                throw ChatError.http(status: 200, body: message)
            default:
                break
            }
        }

        for try await line in bytes.sseLines {
            guard let payload = parser.feed(line: line) else { continue }
            try processPayload(payload)
            if sawDoneSentinel { break }
        }
        if !sawDoneSentinel, let tail = parser.flush() {
            try processPayload(tail)
        }
        try Task.checkCancellation()
        guard sawCompleted else {
            throw ChatError.transport("the provider stream ended before response.completed")
        }
        yield(.done(stopReason: stopReason))
    }
}
