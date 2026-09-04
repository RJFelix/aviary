import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Web search and page extraction, through Parallel.
///
/// Kept behind a vendor-neutral contract on purpose. The model is told it gets
/// `{'url', 'title', 'excerpts'}` back and never which company produced them, so swapping
/// providers later changes the request built here and nothing the model reads — which means no
/// prompt-cache invalidation and no re-teaching the agent how to call it. The temptation to
/// leak `source_policy`, `freshness` and the rest into the description is exactly the thing
/// that would make a switch expensive.
///
/// Two calls rather than one because they answer different questions. Search finds pages it has
/// never been told about; Extract is pointed at a URL you already have. An agent that only had
/// search would fetch and parse pages itself, which is where the expensive failures live — a
/// 404 body silently dropped, a rendered error page arriving as a success.
public struct WebSearch: Sendable {
    /// Environment variable the key is read from.
    ///
    /// Aviary captures the login shell's environment at startup, so this is the same key a
    /// terminal would see. There is no separate place to put it — one fewer thing to explain,
    /// and the capability is simply absent when the variable is.
    public static let keyVariable = "PARALLEL_API_KEY"

    public var apiKey: String
    public var session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Whether the key is present, which is what gates the builtins.
    public static func configuredKey(
        environment: [String: String] = ProcessEnvironment.shared.snapshot
    ) -> String? {
        let key = environment[keyVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    /// `fast` by default: ~700ms and a tenth the price of the deliberative modes, which is the
    /// right trade for a call an agent makes to orient itself rather than to conclude.
    public static let defaultMode = "fast"
    public static let modes = ["turbo", "fast", "basic", "advanced"]

    public enum Failure: LocalizedError {
        case badStatus(Int, String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code, let body):
                return "Parallel answered \(code). \(body)"
            case .malformed(let what):
                return "Parallel's reply was not the shape this expects: \(what)."
            }
        }
    }

    // MARK: Search

    /// Built as a pure function so the field names can be checked without a network or a key.
    ///
    /// They are the most expensive thing here to get wrong: a misspelled key is accepted,
    /// silently ignored, and shows up as slightly worse results rather than as an error.
    public static func searchBody(
        objective: String?, queries: [String], mode: String, maxResults: Int?,
        maxCharsPerResult: Int?, includeDomains: [String], excludeDomains: [String],
        afterDate: String?
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "search_queries": .array(queries.map { .string($0) }),
            "mode": .string(modes.contains(mode) ? mode : defaultMode),
        ]
        if let objective, !objective.isEmpty { body["objective"] = .string(objective) }

        // Everything optional lives under `advanced_settings`, which is Parallel's shape rather
        // than ours; the model never sees this nesting.
        var advanced: [String: JSONValue] = [:]
        if let maxResults { advanced["max_results"] = .number(Double(maxResults)) }
        if let maxCharsPerResult {
            advanced["excerpt_settings"] = .object([
                "max_chars_per_result": .number(Double(maxCharsPerResult)),
            ])
        }
        var policy: [String: JSONValue] = [:]
        if !includeDomains.isEmpty {
            policy["include_domains"] = .array(includeDomains.map { .string($0) })
        }
        if !excludeDomains.isEmpty {
            policy["exclude_domains"] = .array(excludeDomains.map { .string($0) })
        }
        if let afterDate, !afterDate.isEmpty { policy["after_date"] = .string(afterDate) }
        if !policy.isEmpty { advanced["source_policy"] = .object(policy) }
        if !advanced.isEmpty { body["advanced_settings"] = .object(advanced) }
        return .object(body)
    }

    public func search(
        objective: String?, queries: [String], mode: String, maxResults: Int?,
        maxCharsPerResult: Int?, includeDomains: [String], excludeDomains: [String],
        afterDate: String?
    ) async throws -> JSONValue {
        let reply = try await post(path: "search", body: Self.searchBody(
            objective: objective, queries: queries, mode: mode, maxResults: maxResults,
            maxCharsPerResult: maxCharsPerResult, includeDomains: includeDomains,
            excludeDomains: excludeDomains, afterDate: afterDate))
        return Self.searchPayload(reply)
    }

    /// Flattened to what an agent can act on. `search_id`, `session_id`, `usage` and the rest
    /// are Parallel's bookkeeping, and forwarding them would spend the agent's context on
    /// somebody else's telemetry.
    static func searchPayload(_ reply: JSONValue) -> JSONValue {
        let results = (reply["results"]?.arrayValue ?? []).map { row -> JSONValue in
            var out: [String: JSONValue] = [
                "url": .string(row["url"]?.stringValue ?? ""),
                "title": .string(row["title"]?.stringValue ?? ""),
                "excerpts": .array(row["excerpts"]?.arrayValue ?? []),
            ]
            if let date = row["publish_date"]?.stringValue { out["published"] = .string(date) }
            return .object(out)
        }
        return .array(results)
    }

    // MARK: Extract

    public static func extractBody(
        urls: [String], objective: String?, queries: [String], full: Bool
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "urls": .array(urls.map { .string($0) }),
            "full_content": .bool(full),
        ]
        if let objective, !objective.isEmpty { body["objective"] = .string(objective) }
        if !queries.isEmpty { body["search_queries"] = .array(queries.map { .string($0) }) }
        return .object(body)
    }

    public func extract(
        urls: [String], objective: String?, queries: [String], full: Bool
    ) async throws -> JSONValue {
        let reply = try await post(path: "extract", body: Self.extractBody(
            urls: urls, objective: objective, queries: queries, full: full))
        return Self.extractPayload(reply)
    }

    static func extractPayload(_ reply: JSONValue) -> JSONValue {
        var rows = (reply["results"]?.arrayValue ?? []).map { row -> JSONValue in
            var out: [String: JSONValue] = [
                "url": .string(row["url"]?.stringValue ?? ""),
                "title": .string(row["title"]?.stringValue ?? ""),
                "excerpts": .array(row["excerpts"]?.arrayValue ?? []),
            ]
            if let text = row["full_content"]?.stringValue { out["content"] = .string(text) }
            if let date = row["publish_date"]?.stringValue { out["published"] = .string(date) }
            return .object(out)
        }
        // A URL that failed is reported in the list rather than dropped. A silently shorter
        // list reads as "that page had nothing", which is a different fact.
        for failure in reply["errors"]?.arrayValue ?? [] {
            rows.append(.object([
                "url": .string(failure["url"]?.stringValue ?? ""),
                "error": .string(
                    failure["message"]?.stringValue
                        ?? failure["detail"]?.stringValue
                        ?? failure.compactJSON),
            ]))
        }
        return .array(rows)
    }

    // MARK: Transport

    private func post(path: String, body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://api.parallel.ai/v1/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("aviary", forHTTPHeaderField: "User-Agent")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        // Generous: `advanced` mode is documented at about three seconds, and a live fetch
        // behind it can be slower still.
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.badStatus(status, String(decoding: data.prefix(400), as: UTF8.self))
        }
        guard let parsed = JSONValue.parse(data) else {
            throw Failure.malformed("not JSON")
        }
        return parsed
    }
}
