import Foundation

extension ClaudeCode {

    /// One decoded frame from `--output-format stream-json`.
    ///
    /// Everything Claude Code will say about a run arrives as one of these. The set is
    /// deliberately narrow: frames Aviary has no use for decode to `.other` and are counted
    /// rather than dropped silently, so a Claude Code release that starts saying something new
    /// shows up as a number instead of as absence.
    public enum Frame: Sendable {
        /// The handshake. Answers what the run actually got, as opposed to what was asked for.
        case initialized(Init)
        /// A completed content block on an assistant message. Authoritative for content.
        case assistantBlock(messageID: String, block: Block, stopReason: String?)
        /// An assistant message ended, with the usage that actually applies to it.
        ///
        /// Separate from `assistantBlock` because those frames carry the `message_start`
        /// snapshot, whose `output_tokens` is a stub — 2 or 3, before anything was generated —
        /// and which has no `output_tokens_details` at all. The finished output and reasoning
        /// counts exist only here.
        case messageDone(usage: Usage?, stopReason: String?)
        /// Streaming text, for display only. The `assistantBlock` is what gets recorded.
        case textDelta(String)
        case thinkingDelta(String)
        /// A tool call's arguments arriving in pieces.
        case toolArgumentsDelta(String)
        /// A tool result Claude Code fed back to itself, echoed so it can be recorded.
        case toolResult(id: String, text: String, isError: Bool)
        /// Which bucket the run is drawing on. The reason this session type exists.
        case rateLimit(RateLimit)
        /// The turn ended.
        case result(Result)
        /// A retry, including authentication trouble — machine-detectable mid-run.
        case retry(category: String, detail: String)
        /// A frame this version does not model.
        case other(type: String)

        /// One block of an assistant message.
        public enum Block: Sendable {
            case text(String)
            case thinking(String)
            case toolCall(id: String, name: String, arguments: JSONValue)
        }

        public struct Init: Sendable {
            public var sessionID: String
            public var model: String
            public var tools: [String]
            public var mcpServers: [(name: String, status: String)]
            /// `"none"` is the one we want: it means no environment variable outranked the
            /// subscription login. Anything else means the run is spending metered credit.
            public var apiKeySource: String
            public var version: String
            public var cwd: String

            /// Whether the strip-down actually took. Checked against the run's own report
            /// rather than against the flags that were passed, because a `SettingsStart` hook
            /// has been observed firing even with `--setting-sources ""`.
            public func complaint(expecting expectedTools: [String]) -> String? {
                if apiKeySource != "none" {
                    return "This run is authenticating with \(apiKeySource), not the "
                        + "subscription — it will bill metered credit."
                }
                let missing = expectedTools.filter { !tools.contains($0) }
                if !missing.isEmpty {
                    return "Claude Code did not attach \(missing.joined(separator: ", ")). "
                        + (mcpServers.isEmpty
                            ? "No MCP server connected."
                            : "Servers: " + mcpServers
                                .map { "\($0.name) (\($0.status))" }.joined(separator: ", "))
                }
                let unexpected = tools.filter { !expectedTools.contains($0) }
                if !unexpected.isEmpty {
                    return "Claude Code brought its own tools: "
                        + unexpected.joined(separator: ", ") + "."
                }
                return nil
            }
        }

        public struct RateLimit: Sendable, Equatable {
            /// `five_hour`, `weekly`, …
            public var type: String
            public var status: String
            /// True when the plan allowance is spent and this is costing extra.
            public var usingOverage: Bool
            public var resetsAt: Date?

            public var summary: String {
                let bucket = type.replacingOccurrences(of: "_", with: "-")
                return usingOverage
                    ? "extra usage (\(bucket) allowance spent)"
                    : "plan usage (\(bucket))"
            }
        }

        public struct Result: Sendable {
            public var sessionID: String
            public var isError: Bool
            public var text: String
            public var turns: Int
            public var usage: Usage
            /// Tool calls Claude Code made and was not allowed to run. A non-empty list means
            /// the model tried to do something the invocation forbade — worth surfacing, not
            /// swallowing, because Claude Code then answers *around* the denial.
            public var permissionDenials: [String]
            public var apiErrorStatus: String?
            public var durationMS: Int
        }
    }

    /// Decode one line of Claude Code's stream-json output.
    ///
    /// Returns nil for a line that is not JSON at all — the CLI does occasionally write
    /// unstructured text to stdout, and a decoder that treated that as a protocol error would
    /// end runs over a cosmetic warning.
    public static func decode(line: Data) -> Frame? {
        guard let json = JSONValue.parse(line) else { return nil }
        return decode(json)
    }

    public static func decode(_ json: JSONValue) -> Frame? {
        switch json["type"]?.stringValue {
        case "system":
            switch json["subtype"]?.stringValue {
            case "init":
                return .initialized(Frame.Init(
                    sessionID: json["session_id"]?.stringValue ?? "",
                    model: json["model"]?.stringValue ?? "",
                    tools: (json["tools"]?.arrayValue ?? []).compactMap(\.stringValue),
                    mcpServers: (json["mcp_servers"]?.arrayValue ?? []).map {
                        ($0["name"]?.stringValue ?? "?", $0["status"]?.stringValue ?? "?")
                    },
                    apiKeySource: json["apiKeySource"]?.stringValue ?? "unknown",
                    version: json["claude_code_version"]?.stringValue ?? "",
                    cwd: json["cwd"]?.stringValue ?? ""))
            case "api_retry":
                // Several spellings tried, and the whole frame as the last resort. A retry
                // whose category this version does not recognise still has to say something
                // usable — a banner reading "retrying: unknown" is worse than no banner,
                // because it reports trouble while withholding the only part that would let
                // you act on it.
                let category = json.path("error.category")?.stringValue
                    ?? json["errorCategory"]?.stringValue
                    ?? json["category"]?.stringValue
                    ?? json["error"]?.stringValue
                let detail = json.path("error.message")?.stringValue
                    ?? json["message"]?.stringValue
                    ?? json["error"]?.stringValue
                if category == nil, detail == nil {
                    return .retry(category: "", detail: json.compactJSON)
                }
                return .retry(category: category ?? "", detail: detail ?? "")
            default:
                return .other(type: "system/" + (json["subtype"]?.stringValue ?? "?"))
            }

        case "assistant":
            // One frame per completed content block, all sharing a message id — not a
            // cumulative snapshot. Whoever consumes this has to accumulate.
            guard let message = json["message"] else { return .other(type: "assistant") }
            let id = message["id"]?.stringValue ?? ""
            let blocks = message["content"]?.arrayValue ?? []
            guard let first = blocks.first, let block = decodeBlock(first) else {
                return .other(type: "assistant/empty")
            }
            return .assistantBlock(
                messageID: id, block: block,
                stopReason: message["stop_reason"]?.stringValue)

        case "user":
            // Claude Code echoing the tool result it fed itself. The only place a driven run
            // can see what its own tool returned, since the call is executed on our side but
            // the *result message* is composed on theirs.
            guard let blocks = json.path("message.content")?.arrayValue else {
                return .other(type: "user")
            }
            for entry in blocks where entry["type"]?.stringValue == "tool_result" {
                return .toolResult(
                    id: entry["tool_use_id"]?.stringValue ?? "",
                    text: entry["content"]?.textContent ?? "",
                    isError: entry["is_error"]?.boolValue ?? false)
            }
            return .other(type: "user")

        case "stream_event":
            guard let event = json["event"] else { return .other(type: "stream_event") }
            switch event["type"]?.stringValue {
            case "content_block_delta":
                switch event.path("delta.type")?.stringValue {
                case "text_delta":
                    return .textDelta(event.path("delta.text")?.stringValue ?? "")
                case "thinking_delta":
                    // Present, and with real content — which the flags-only research had
                    // concluded was impossible in `-p`. The *complete* block is sometimes
                    // redacted; the deltas are not.
                    return .thinkingDelta(event.path("delta.thinking")?.stringValue ?? "")
                case "input_json_delta":
                    return .toolArgumentsDelta(
                        event.path("delta.partial_json")?.stringValue ?? "")
                default:
                    return .other(type: "delta/"
                        + (event.path("delta.type")?.stringValue ?? "?"))
                }
            case "message_delta":
                return .messageDone(
                    usage: usage(from: event["usage"]),
                    stopReason: event.path("delta.stop_reason")?.stringValue)
            default:
                return .other(type: "event/" + (event["type"]?.stringValue ?? "?"))
            }

        case "rate_limit_event":
            let info = json["rate_limit_info"]
            return .rateLimit(Frame.RateLimit(
                type: info?["rateLimitType"]?.stringValue ?? "unknown",
                status: info?["status"]?.stringValue ?? "unknown",
                usingOverage: info?["isUsingOverage"]?.boolValue ?? false,
                resetsAt: info?["resetsAt"]?.doubleValue.map {
                    Date(timeIntervalSince1970: $0)
                }))

        case "result":
            return .result(Frame.Result(
                sessionID: json["session_id"]?.stringValue ?? "",
                isError: json["is_error"]?.boolValue ?? false,
                text: json["result"]?.stringValue ?? "",
                turns: json["num_turns"]?.intValue ?? 0,
                usage: usage(from: json["usage"]) ?? Usage.unclassifiedRecord,
                permissionDenials: (json["permission_denials"]?.arrayValue ?? []).map {
                    $0["tool_name"]?.stringValue ?? "?"
                },
                apiErrorStatus: json["api_error_status"]?.stringValue,
                durationMS: json["duration_ms"]?.intValue ?? 0))

        default:
            return .other(type: json["type"]?.stringValue ?? "?")
        }
    }

    private static func decodeBlock(_ value: JSONValue) -> Frame.Block? {
        switch value["type"]?.stringValue {
        case "text":
            return .text(value["text"]?.stringValue ?? "")
        case "thinking":
            return .thinking(value["thinking"]?.stringValue ?? "")
        case "tool_use":
            return .toolCall(
                id: value["id"]?.stringValue ?? "",
                name: value["name"]?.stringValue ?? "",
                arguments: value["input"] ?? .object([:]))
        default:
            return nil
        }
    }

    /// Normalize reported counts without treating an absent field as zero. Subscription
    /// billing is not established by the stream's list-price estimate, so rates stay unknown.
    static func usage(from value: JSONValue?) -> Usage? {
        guard let report = ProviderUsageWire.claudeCode(value) else { return nil }
        let unpriced = ModelSpec(rpc: .object([
            "id": .string("reported"), "provider": .string("claude-code")]))
        return Usage(finality: .finalReport, accounted: ProviderUsage.account(report: report, model: unpriced))
    }
}
