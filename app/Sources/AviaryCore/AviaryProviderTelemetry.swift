import Foundation

/// One bounded observation per crossing. Cumulative updates replace the latest report.
internal struct AviaryProviderTelemetry {
    private let started: UInt64
    private var firstOutputSeconds: Double?
    private(set) var latestUsage: ProviderUsage.RawReport?
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

    func record(model: ModelSpec) {
        let accounted = ProviderUsage.account(report: latestUsage, model: model)
        var attributes: [String: AviaryTraceValue] = [
            "aviary.usage.updates": .int(usageUpdates),
            "aviary.usage.input_accounting": .string(accounted.inputAccounting.rawValue),
            "aviary.provider.done_observed": .bool(finished),
        ]
        if let firstOutputSeconds {
            attributes["aviary.provider.first_output.seconds"] = .double(firstOutputSeconds)
        }
        let fields: [(ProviderUsage.Field, String)] = [
            (.inputTokens, "input_tokens"), (.outputTokens, "output_tokens"),
            (.cacheReadTokens, "cache_read_tokens"), (.cacheWriteTokens, "cache_write_tokens"),
            (.reasoningTokens, "reasoning_tokens"), (.reportedTotalTokens, "reported_total_tokens"),
        ]
        var invalid = false
        var coverage: [String: AviaryTraceValue] = [
            "aviary.usage.finality": .string(finished ? "final_report" : "unconfirmed")
        ]
        for (field, key) in fields {
            let observation = accounted.observations[field]
            coverage["aviary.usage.\(key).state"] = .string(observation.state.rawValue)
            if let reason = observation.reason {
                coverage["aviary.usage.\(key).reason"] = .string(reason.rawValue)
            }
            if let value = observation.value { attributes["aviary.usage.\(key)"] = .int(value) }
            invalid = invalid || observation.state == .invalid
        }
        attributes["aviary.usage.state"] = .string(latestUsage == nil ? "unreported"
            : invalid ? "invalid" : accounted.totalTokens == nil ? "partial" : "reported")
        if let value = accounted.totalTokens { attributes["aviary.usage.total_tokens"] = .int(value) }
        if let value = accounted.contextTokens { attributes["aviary.usage.context_tokens"] = .int(value) }
        if let value = accounted.ordinaryInputTokens { attributes["aviary.usage.ordinary_input_tokens"] = .int(value) }
        attributes["aviary.usage.issue_count"] = .int(accounted.issues.count)
        AviaryTelemetry.event("aviary.agent.provider.measurements", attributes: attributes)
        // Keep each event within the SDK's 16-attribute limit. Numeric measurements and
        // field-presence evidence belong to the same crossing span without silent truncation.
        AviaryTelemetry.event("aviary.agent.provider.usage_coverage", attributes: coverage)

        let completePrice = finished ? accounted.price.total : nil
        var price: [String: AviaryTraceValue] = [
            "aviary.pricing.source": .string("model_spec"),
            "aviary.pricing.state": .string(completePrice == nil
                ? (accounted.price.completeness == .unavailable ? "unavailable" : "partial") : "estimated"),
            "aviary.pricing.known_lower_bound_usd": .double(accounted.price.knownTotal),
            "aviary.pricing.complete": .bool(completePrice != nil),
            "aviary.pricing.issue_count": .int(accounted.price.issues.count),
        ]
        if let estimate = completePrice { price["aviary.pricing.estimated_usd"] = .double(estimate) }
        let rates = [accounted.rateSnapshot.inputPerMillion, accounted.rateSnapshot.outputPerMillion,
            accounted.rateSnapshot.cacheReadPerMillion, accounted.rateSnapshot.cacheWritePerMillion]
        let categories: [ProviderUsage.PricingCategory] = [.input, .output, .cacheRead, .cacheWrite]
        let identity = zip(categories, rates).map { category, rate in
            accounted.rateSnapshot.invalidRates.contains(category)
                ? "invalid" : rate.map { String($0.bitPattern, radix: 16) } ?? "absent"
        }.joined(separator: ":")
        price["aviary.pricing.id"] = .string(AviaryTelemetry.identity("configured-usd-per-million:v2:" + identity))
        for (key, rate) in zip(["input", "output", "cache_read", "cache_write"], rates) {
            if let rate, rate.isFinite, rate >= 0 {
                price["aviary.pricing.\(key)_per_million_usd"] = .double(rate)
            }
        }
        AviaryTelemetry.event("aviary.agent.provider.price", attributes: price)
    }
}
