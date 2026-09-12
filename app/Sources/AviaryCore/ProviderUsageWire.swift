import Foundation

/// Fixed-schema wire decoding. Field absence and explicit zero remain distinct, and malformed
/// cumulative updates replace old observations rather than leaving a stale valid count behind.
public enum ProviderUsageWire {
    public static func openAICompletions(_ value: JSONValue?) -> ProviderUsage.RawReport? {
        decode(value, accounting: .cacheInclusive, paths: [
            (.inputTokens, ["prompt_tokens"]), (.outputTokens, ["completion_tokens"]),
            (.cacheReadTokens, ["prompt_tokens_details", "cached_tokens"]),
            (.cacheWriteTokens, ["prompt_tokens_details", "cache_write_tokens"]),
            (.reasoningTokens, ["completion_tokens_details", "reasoning_tokens"]),
            (.reportedTotalTokens, ["total_tokens"]),
        ])
    }

    public static func responses(_ value: JSONValue?) -> ProviderUsage.RawReport? {
        decode(value, accounting: .cacheInclusive, paths: [
            (.inputTokens, ["input_tokens"]), (.outputTokens, ["output_tokens"]),
            (.cacheReadTokens, ["input_tokens_details", "cached_tokens"]),
            (.cacheWriteTokens, ["input_tokens_details", "cache_write_tokens"]),
            (.reasoningTokens, ["output_tokens_details", "reasoning_tokens"]),
            (.reportedTotalTokens, ["total_tokens"]),
        ])
    }

    /// Anthropic message_start and message_delta usage fields are cumulative snapshots of the
    /// fields they supply. An absent field keeps the previous observation; null clears it.
    public static func anthropicMessages(
        _ value: JSONValue?, merging previous: ProviderUsage.RawReport? = nil
    ) -> ProviderUsage.RawReport? {
        decode(value, accounting: .cacheExclusive, paths: [
            (.inputTokens, ["input_tokens"]), (.outputTokens, ["output_tokens"]),
            (.cacheReadTokens, ["cache_read_input_tokens"]),
            (.cacheWriteTokens, ["cache_creation_input_tokens"]),
        ], previous: previous)
    }

    /// The driven Claude Code stream exposes Anthropic-style cache-exclusive counts and
    /// may additionally report a thinking subset. It does not establish a billed price.
    public static func claudeCode(_ value: JSONValue?) -> ProviderUsage.RawReport? {
        decode(value, accounting: .cacheExclusive, paths: [
            (.inputTokens, ["input_tokens"]), (.outputTokens, ["output_tokens"]),
            (.cacheReadTokens, ["cache_read_input_tokens"]),
            (.cacheWriteTokens, ["cache_creation_input_tokens"]),
            (.reasoningTokens, ["output_tokens_details", "thinking_tokens"]),
        ])
    }

    private enum WireField { case absent, missing, invalid, count(Int) }

    private static func field(_ root: JSONValue, path: [String]) -> WireField {
        var current = root
        for key in path {
            if current.isNull { return .missing }
            guard let object = current.objectValue else { return .invalid }
            guard let next = object[key] else { return .absent }
            current = next
        }
        if current.isNull { return .missing }
        // JSONValue stores numbers as Double. Larger integers can already have been rounded
        // during decoding, so they cannot establish an exact token count.
        guard case .number(let number) = current, number.isFinite,
              number.rounded() == number, abs(number) <= 9_007_199_254_740_991,
              let integer = Int(exactly: number) else { return .invalid }
        return .count(integer)
    }

    private static func decode(
        _ value: JSONValue?, accounting: ProviderUsageAccounting,
        paths: [(ProviderUsage.Field, [String])], previous: ProviderUsage.RawReport? = nil
    ) -> ProviderUsage.RawReport? {
        guard let value, !value.isNull else { return nil }
        let prior = previous.flatMap { $0.inputAccounting == accounting ? $0 : nil }
        var report = prior ?? ProviderUsage.RawReport(inputAccounting: accounting)
        report.inputAccounting = accounting
        for (key, path) in paths {
            let observation = field(value, path: path)
            if case .absent = observation { continue }
            let count: Int?
            switch observation {
            case .count(let integer): count = integer; report.malformedFields.remove(key)
            case .invalid: count = nil; report.malformedFields.insert(key)
            case .missing: count = nil; report.malformedFields.remove(key)
            case .absent: continue
            }
            switch key {
            case .inputTokens: report.inputTokens = count
            case .outputTokens: report.outputTokens = count
            case .cacheReadTokens: report.cacheReadTokens = count
            case .cacheWriteTokens: report.cacheWriteTokens = count
            case .reasoningTokens: report.reasoningTokens = count
            case .reportedTotalTokens: report.reportedTotalTokens = count
            }
        }
        return report
    }
}
