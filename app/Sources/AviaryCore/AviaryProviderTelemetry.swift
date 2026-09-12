import Foundation

/// One bounded observation per provider crossing. Usage updates replace, rather than add to,
/// the latest provider-adapter report. No streamed content is retained here.
internal struct AviaryProviderTelemetry {
    private let started: UInt64
    private var firstOutputSeconds: Double?
    private var latestUsage: Usage?
    private var usageUpdates = 0
    private var finished = false

    init(now: UInt64 = DispatchTime.now().uptimeNanoseconds) { started = now }

    mutating func observe(_ event: ChatEvent, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        switch event {
        case .usage(let usage):
            latestUsage = usage
            if usageUpdates < Int.max { usageUpdates += 1 }
        case .done: finished = true
        case .textDelta(let value), .thinkingDelta(let value):
            if !value.isEmpty { observeOutput(now: now) }
        case .toolCall: observeOutput(now: now)
        case .requestBody: break
        }
    }

    private mutating func observeOutput(now: UInt64) {
        guard firstOutputSeconds == nil, now >= started else { return }
        firstOutputSeconds = Double(now - started) / 1_000_000_000
    }

    func record(model: ModelSpec, accounting: ProviderUsageAccounting = .unknown) {
        var attributes: [String: AviaryTraceValue] = [
            "aviary.usage.updates": .int(usageUpdates),
            "aviary.usage.input_accounting": .string(accounting.rawValue),
            "aviary.provider.done_observed": .bool(finished),
        ]
        if let firstOutputSeconds {
            // A delta is not necessarily one token; thinking and tool output count too.
            attributes["aviary.provider.first_output.seconds"] = .double(firstOutputSeconds)
        }
        guard let usage = latestUsage else {
            attributes["aviary.usage.state"] = .string("unreported")
            AviaryTelemetry.event("aviary.agent.provider.measurements", attributes: attributes)
            return
        }
        guard [usage.input, usage.output, usage.cacheRead, usage.cacheWrite, usage.totalTokens]
                .allSatisfy({ $0 >= 0 }), (usage.reasoning ?? 0) >= 0 else {
            attributes["aviary.usage.state"] = .string("invalid")
            AviaryTelemetry.event("aviary.agent.provider.measurements", attributes: attributes)
            return
        }
        attributes["aviary.usage.state"] = .string("reported")
        attributes["aviary.usage.input_tokens"] = .int(usage.input)
        attributes["aviary.usage.output_tokens"] = .int(usage.output)
        attributes["aviary.usage.cache_read_tokens"] = .int(usage.cacheRead)
        attributes["aviary.usage.cache_write_tokens"] = .int(usage.cacheWrite)
        attributes["aviary.usage.total_tokens"] = .int(usage.totalTokens)
        if let reasoning = usage.reasoning {
            attributes["aviary.usage.reasoning_tokens"] = .int(reasoning)
        }
        // These are adapter counts, not an independent billing meter. Zero fields
        // may reflect absent upstream fields; the Usage type does not retain field presence.
        AviaryTelemetry.event("aviary.agent.provider.measurements", attributes: attributes)
        recordPriceEstimate(usage: usage, model: model, accounting: accounting)
    }

    private func recordPriceEstimate(usage: Usage, model: ModelSpec, accounting: ProviderUsageAccounting) {
        let rates = [model.costInput, model.costOutput,
            model.costCacheRead ?? model.costInput, model.costCacheWrite ?? model.costInput]
        let ordinaryInput: Int?
        switch accounting {
        case .cacheExclusive: ordinaryInput = usage.input
        case .cacheInclusive:
            if usage.cacheRead <= usage.input, usage.cacheWrite <= usage.input - usage.cacheRead {
                ordinaryInput = usage.input - usage.cacheRead - usage.cacheWrite
            } else { ordinaryInput = nil }
        case .unknown: ordinaryInput = nil
        }
        let counts = [ordinaryInput ?? 0, usage.output, usage.cacheRead, usage.cacheWrite]
        let hasRate = rates.contains { $0 != nil }
        let usable = ordinaryInput != nil && zip(counts, rates).allSatisfy { count, rate in
            if let rate { return rate.isFinite && rate >= 0 }
            return count == 0
        }
        var price: [String: AviaryTraceValue] = [
            "aviary.pricing.source": .string("model_spec"),
            "aviary.pricing.state": .string(hasRate && usable ? "estimated" : "unavailable"),
        ]
        guard hasRate, usable else {
            AviaryTelemetry.event("aviary.agent.provider.price", attributes: price)
            return
        }
        let estimate = zip(counts, rates).reduce(0.0) { sum, pair in
            sum + Double(pair.0) * ((pair.1 ?? 0) / 1_000_000)
        }
        guard estimate.isFinite else {
            price["aviary.pricing.state"] = .string("unavailable")
            AviaryTelemetry.event("aviary.agent.provider.price", attributes: price)
            return
        }
        // Bit-pattern identity includes absent rates and the effective cache fallback; never
        // claims these configured rates are published prices or the actual charged amount.
        let rateIdentity = rates.map { $0.map { String($0.bitPattern, radix: 16) } ?? "absent" }
            .joined(separator: ":")
        price["aviary.pricing.id"] = .string(AviaryTelemetry.identity("usd-per-million:v1:" + rateIdentity))
        price["aviary.pricing.estimated_usd"] = .double(estimate)
        let rateKeys = ["input", "output", "cache_read", "cache_write"]
        for (key, rate) in zip(rateKeys, rates) {
            if let rate { price["aviary.pricing.\(key)_per_million_usd"] = .double(rate) }
        }
        price["aviary.pricing.cache_fallback"] = .bool(
            (usage.cacheRead > 0 && model.costCacheRead == nil)
                || (usage.cacheWrite > 0 && model.costCacheWrite == nil))
        AviaryTelemetry.event("aviary.agent.provider.price", attributes: price)
    }
}
