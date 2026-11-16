import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Applies a second provider-local byte fence on Darwin, where Foundation's native byte stream
/// currently does not enforce the limit passed to ``AviaryURLSession.bytes``.
private struct XAIBoundedByteStream: AsyncSequence {
    typealias Element = UInt8
    let base: AviaryByteStream
    let maximumBytes: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: AviaryByteStream.AsyncIterator
        let maximumBytes: Int
        var count = 0

        mutating func next() async throws -> UInt8? {
            guard let byte = try await base.next() else { return nil }
            count += 1
            guard count <= maximumBytes else {
                throw AviaryURLSession.Error.responseTooLarge(limit: maximumBytes)
            }
            return byte
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), maximumBytes: maximumBytes)
    }
}

/// Native xAI Responses API support for Grok models.
///
/// xAI documents `/v1/responses` as the primary interface for text generation, reasoning, and
/// tool use. This adapter deliberately uses the stateless form (`store: false`) and sends the
/// complete Aviary conversation on every crossing. That keeps retry and cold-resume semantics in
/// Aviary's journal rather than in a provider-side conversation whose lifetime we cannot prove.
///
/// xAI reasoning items may contain encrypted reasoning content. Aviary's current ChatContent
/// model has no field for that opaque provider token, so this adapter exposes visible reasoning
/// summary deltas but does not claim encrypted-reasoning replay. It never fabricates a reasoning
/// block from ciphertext.
public struct XAIResponsesProvider: ChatProvider {
    public let id: String
    public let baseURL: URL
    private let apiKey: String?
    public let session: URLSession
    public let maxResponseBytes: Int

    public static let defaultBaseURL = URL(string: "https://api.x.ai/v1/responses")!
    public static let defaultMaximumResponseBytes = 8 * 1024 * 1024
    public static let supportsEncryptedReasoningReplay = false

    public init(
        id: String = "xai-responses", baseURL: URL = XAIResponsesProvider.defaultBaseURL,
        apiKey: String?, session: URLSession = .shared,
        maxResponseBytes: Int = XAIResponsesProvider.defaultMaximumResponseBytes
    ) {
        self.id = id
        self.baseURL = Self.resolveURL(baseURL)
        self.apiKey = apiKey
        self.session = session
        self.maxResponseBytes = maxResponseBytes
    }

    /// Accept either the complete endpoint or an xAI API root/base URL.
    public static func resolveURL(_ url: URL) -> URL {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("responses") { return url }
        if path.hasSuffix("v1") { return url.appendingPathComponent("responses") }
        return url.appendingPathComponent("v1").appendingPathComponent("responses")
    }

    // MARK: Request encoding

    public static func body(for request: ChatRequest) -> JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(encodeInput(request.messages)),
            "stream": .bool(true),
            // Stateless requests are intentional: provider-side retention is not Aviary's
            // durable transcript and cannot be used as cold-resume evidence.
            "store": .bool(false),
        ]
        if let maxTokens = request.maxTokens, maxTokens > 0 {
            object["max_output_tokens"] = .number(Double(maxTokens))
        }
        if let temperature = request.temperature {
            object["temperature"] = .number(temperature)
        }
        if let effort = request.reasoningEffort,
           !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !["none", "off"].contains(effort.lowercased()) {
            // Responses uses the nested reasoning object; reasoning_effort is the Chat
            // Completions spelling and is not sent on this route.
            object["reasoning"] = .object(["effort": .string(effort)])
        }
        if !request.tools.isEmpty {
            object["tool_choice"] = .string("auto")
            object["parallel_tool_calls"] = .bool(true)
            object["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                ])
            })
        }
        return .object(object)
    }

    /// Encode the complete stateless conversation as Responses input items.
    public static func encodeInput(_ messages: [ChatMessage]) -> [JSONValue] {
        var result: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .system, .user:
                let content = message.content.compactMap { block -> JSONValue? in
                    switch block {
                    case .text(let text) where !text.isEmpty:
                        return .object(["type": .string("input_text"),
                                        "text": .string(sanitize(text))])
                    case .image(let mime, let base64):
                        return .object([
                            "type": .string("input_image"),
                            "image_url": .string("data:\(mime);base64,\(base64)"),
                        ])
                    default:
                        return nil
                    }
                }
                guard !content.isEmpty else { continue }
                result.append(.object([
                    "role": .string(message.role.rawValue),
                    "content": .array(content),
                ]))

            case .assistant:
                for block in message.content {
                    switch block {
                    case .text(let text) where !text.isEmpty:
                        result.append(.object([
                            "role": .string("assistant"),
                            "content": .array([.object([
                                "type": .string("output_text"),
                                "text": .string(sanitize(text)),
                            ])]),
                        ]))
                    case .toolCall(let id, let name, let arguments):
                        result.append(.object([
                            "type": .string("function_call"),
                            "call_id": .string(id.split(separator: "|").first.map(String.init) ?? id),
                            "name": .string(name),
                            "arguments": .string(arguments.compactJSON),
                        ]))
                    case .thinking:
                        // Visible summaries are intentionally not replayed as model-authored
                        // content. Encrypted reasoning requires the original opaque item.
                        continue
                    default:
                        continue
                    }
                }

            case .tool:
                for block in message.content {
                    guard case .toolResult(let id, _, let text, _) = block else { continue }
                    result.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(id.split(separator: "|").first.map(String.init) ?? id),
                        "output": .string(sanitize(text)),
                    ]))
                }
            }
        }
        return result
    }

    private static func sanitize(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !($0.value >= 0xD800 && $0.value <= 0xDFFF)
        })
    }

    // MARK: Streaming

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: ChatRequest, yield: (ChatEvent) -> Void) async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw ChatError.notConfigured("An xAI API key is required for Grok")
        }
        guard maxResponseBytes > 0 else {
            throw ChatError.notConfigured("The xAI response size limit must be positive")
        }
        if let effort = request.reasoningEffort?.lowercased(), effort == "none" || effort == "off" {
            throw ChatError.notConfigured("xAI reasoning models cannot disable reasoning")
        }

        let payload = Self.body(for: request)
        yield(.requestBody(payload))
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(payload)
        urlRequest.timeoutInterval = 600

        let (bytes, response) = try await AviaryURLSession.bytes(
            for: urlRequest, using: session, maxResponseBytes: maxResponseBytes)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Read enough look-ahead to redact a secret which straddles the presentation limit;
            // redact first, then bound the diagnostic string exposed through ChatError.
            let body = try await boundedBody(bytes, limit: 64 * 1024)
            bytes.cancel()
            throw ChatError.http(status: status, body: Self.redact(body, secret: apiKey))
        }
        do {
            try await consume(
                bytes: XAIBoundedByteStream(base: bytes, maximumBytes: maxResponseBytes),
                secret: apiKey, yield: yield)
        } catch {
            // A canceled consumer or malformed terminal stream must release the bounded
            // URLSession task promptly; otherwise a provider can keep the Work turn alive.
            bytes.cancel()
            throw error
        }
    }

    private func boundedBody<S: AsyncSequence>(_ bytes: S, limit: Int) async throws -> String
    where S.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            if data.count < limit { data.append(byte) }
            if data.count >= limit { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func redact(_ text: String, secret: String) -> String {
        let redacted = secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "<redacted>")
        return String(redacted.prefix(16_384))
    }

    private func consume<S: AsyncSequence>(
        bytes: S, secret: String, yield: (ChatEvent) -> Void
    ) async throws where S.Element == UInt8 {
        var parser = SSEParser()
        var calls: [String: (id: String, name: String, arguments: String)] = [:]
        var seenItemIDs: Set<String> = []
        var seenCallIDs: Set<String> = []
        var completedItemIDs: Set<String> = []
        var pendingToolCalls: [(id: String, name: String, arguments: JSONValue)] = []
        var terminal = false
        var completedResponse = false
        var stopReason: String?

        func usage(_ value: JSONValue?) {
            guard let report = ProviderUsageWire.responses(value) else { return }
            yield(.usage(report))
        }

        func process(_ payload: String) throws {
            if payload == "[DONE]" {
                return
            }
            guard let value = JSONValue.parse(Data(payload.utf8)) else {
                throw ChatError.decoding("xAI sent malformed SSE JSON")
            }
            usage(value.path("response.usage") ?? value["usage"])
            let type = value["type"]?.stringValue ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = value["delta"]?.stringValue, !delta.isEmpty {
                    yield(.textDelta(delta))
                }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = value["delta"]?.stringValue, !delta.isEmpty {
                    yield(.thinkingDelta(delta))
                }
            case "response.output_item.added":
                let item = value["item"] ?? .null
                if item["type"]?.stringValue == "function_call" {
                    let itemID = item["id"]?.stringValue ?? ""
                    guard !itemID.isEmpty else {
                        throw ChatError.decoding("xAI returned a function call without an item id")
                    }
                    let callID = item["call_id"]?.stringValue ?? itemID
                    guard !seenItemIDs.contains(itemID), !seenCallIDs.contains(callID) else {
                        throw ChatError.decoding("xAI repeated a function call identity")
                    }
                    seenItemIDs.insert(itemID)
                    seenCallIDs.insert(callID)
                    calls[itemID] = (
                        id: callID,
                        name: item["name"]?.stringValue ?? "",
                        arguments: item["arguments"]?.stringValue ?? "")
                }
            case "response.function_call_arguments.delta":
                let itemID = value["item_id"]?.stringValue ?? ""
                guard calls[itemID] != nil else {
                    throw ChatError.decoding("xAI returned function arguments for an unknown item")
                }
                calls[itemID]?.arguments += value["delta"]?.stringValue ?? ""
            case "response.output_item.done":
                let item = value["item"] ?? .null
                guard item["type"]?.stringValue == "function_call" else { break }
                let itemID = item["id"]?.stringValue ?? ""
                guard !completedItemIDs.contains(itemID),
                      let prior = calls.removeValue(forKey: itemID) else {
                    throw ChatError.decoding("xAI repeated or unknown function completion")
                }
                let callID = item["call_id"]?.stringValue ?? prior.id
                let name = item["name"]?.stringValue ?? prior.name
                let raw = item["arguments"]?.stringValue ?? prior.arguments
                guard callID == prior.id, name == prior.name || prior.name.isEmpty else {
                    throw ChatError.decoding("xAI changed a function call at completion")
                }
                let arguments = raw.isEmpty ? .object([:]) : JSONValue.parse(Data(raw.utf8))
                guard let arguments else {
                    throw ChatError.decoding("xAI ended with malformed function arguments")
                }
                guard !name.isEmpty, !callID.isEmpty else {
                    throw ChatError.decoding("xAI returned an incomplete function call")
                }
                completedItemIDs.insert(itemID)
                pendingToolCalls.append((id: callID, name: name, arguments: arguments))
            case "response.completed":
                let response = value["response"] ?? .null
                guard response["status"]?.stringValue == "completed" else {
                    throw ChatError.decoding("xAI completed event had a non-completed status")
                }
                stopReason = "completed"
                completedResponse = true
                terminal = true
            case "response.incomplete":
                let response = value["response"] ?? .null
                guard response["status"]?.stringValue == "incomplete",
                      let reason = response.path("incomplete_details.reason")?.stringValue,
                      !reason.isEmpty else {
                    throw ChatError.decoding("xAI incomplete event omitted its reason")
                }
                // Agent treats .done as successful completion, not merely a stream ending.
                // Usage was emitted above; retain that evidence without committing a partial
                // answer or dispatching buffered tools as a completed turn.
                throw ChatError.transport("xAI response was incomplete: " + Self.redact(reason, secret: secret))
            case "response.failed", "response.error":
                let error = value["error"] ?? value["response"]?["error"] ?? .null
                let message = error["message"]?.stringValue ?? "xAI response failed"
                throw ChatError.http(status: 200, body: Self.redact(message, secret: secret))
            default:
                break
            }
        }

        for try await line in bytes.sseLines {
            guard let payload = parser.feed(line: line) else { continue }
            try process(payload)
            if terminal { break }
        }
        if !terminal, let tail = parser.flush() { try process(tail) }
        try Task.checkCancellation()
        guard terminal else {
            throw ChatError.transport("xAI stream ended before a terminal response")
        }
        guard calls.isEmpty else {
            throw ChatError.decoding("xAI stream ended with an incomplete function call")
        }
        guard completedResponse || pendingToolCalls.isEmpty else {
            throw ChatError.decoding("xAI incomplete response cannot yield a function call")
        }
        for call in pendingToolCalls {
            yield(.toolCall(id: call.id, name: call.name, arguments: call.arguments))
        }
        yield(.done(stopReason: stopReason))
    }
}
