import Foundation

// MARK: - Usage

public struct Usage: Sendable, Hashable, Codable {
    /// Whether a numeric projection is exact, a known floor, absent, or from a record written
    /// before Aviary retained accounting evidence. `neutral` is only the additive identity.
    public enum Completeness: String, Sendable, Hashable, Codable {
        case neutral
        case complete
        case lowerBound = "lower_bound"
        case unavailable
        case unclassified
    }

    /// Compact provenance for merging normalized cache-inclusive and cache-exclusive reports.
    /// Numeric `Usage.input` is always ordinary (non-cache) input for classified records.
    public enum InputAccountingSummary: String, Sendable, Hashable, Codable {
        case neutral
        case cacheInclusive = "cache_inclusive"
        case cacheExclusive = "cache_exclusive"
        case unknown
        case mixed
    }

    public struct CompletenessMetadata: Sendable, Hashable, Codable {
        public var tokenTotal: Completeness
        public var breakdown: Completeness
        public var cost: Completeness
        public var inputAccounting: InputAccountingSummary

        public init(
            tokenTotal: Completeness, breakdown: Completeness, cost: Completeness,
            inputAccounting: InputAccountingSummary
        ) {
            self.tokenTotal = tokenTotal
            self.breakdown = breakdown
            self.cost = cost
            self.inputAccounting = inputAccounting
        }

        public static let neutral = CompletenessMetadata(
            tokenTotal: .neutral, breakdown: .neutral, cost: .neutral,
            inputAccounting: .neutral)
        public static let unclassified = CompletenessMetadata(
            tokenTotal: .unclassified, breakdown: .unclassified, cost: .unclassified,
            inputAccounting: .unknown)
    }

    public var input: Int = 0
    public var output: Int = 0
    public var cacheRead: Int = 0
    public var cacheWrite: Int = 0
    /// Reasoning tokens, when the route reports them. Already counted inside `output`.
    ///
    /// nil means the provider did not say — which is not zero. A route that returns
    /// thinking as text lets you measure it directly; on an encrypted-reasoning route this
    /// is the only evidence the tokens existed.
    public var reasoning: Int?
    public var totalTokens: Int = 0
    public var cost: Cost = Cost()
    public var completeness: CompletenessMetadata = .neutral

    public struct Cost: Sendable, Hashable, Codable {
        public var input: Double = 0
        public var output: Double = 0
        public var cacheRead: Double = 0
        public var cacheWrite: Double = 0
        public var total: Double = 0

        public init() {}

        public init(json: JSONValue?) {
            func imported(_ value: JSONValue?) -> Double {
                guard let value = value?.doubleValue, value.isFinite, value >= 0 else { return 0 }
                return value
            }
            input = imported(json?["input"])
            output = imported(json?["output"])
            cacheRead = imported(json?["cacheRead"])
            cacheWrite = imported(json?["cacheWrite"])
            let first = Usage.saturatingAdd(input, output)
            let second = Usage.saturatingAdd(first.value, cacheRead)
            let sum = Usage.saturatingAdd(second.value, cacheWrite).value
            if let reported = json?["total"]?.doubleValue,
               reported.isFinite, reported >= 0 {
                total = reported
            } else {
                total = sum
            }
        }

        public static func + (a: Cost, b: Cost) -> Cost {
            var c = Cost()
            c.input = Usage.saturatingAdd(a.input, b.input).value
            c.output = Usage.saturatingAdd(a.output, b.output).value
            c.cacheRead = Usage.saturatingAdd(a.cacheRead, b.cacheRead).value
            c.cacheWrite = Usage.saturatingAdd(a.cacheWrite, b.cacheWrite).value
            c.total = Usage.saturatingAdd(a.total, b.total).value
            return c
        }

        private enum CodingKeys: String, CodingKey {
            case input, output, cacheRead, cacheWrite, total
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            input = try values.decode(Double.self, forKey: .input)
            output = try values.decode(Double.self, forKey: .output)
            cacheRead = try values.decode(Double.self, forKey: .cacheRead)
            cacheWrite = try values.decode(Double.self, forKey: .cacheWrite)
            total = try values.decode(Double.self, forKey: .total)
            guard Self.hasValidNumbers(self) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .total, in: values,
                    debugDescription: "Usage cost must contain finite nonnegative values.")
            }
        }

        public func encode(to encoder: Encoder) throws {
            guard Self.hasValidNumbers(self) else {
                throw EncodingError.invalidValue(
                    self, EncodingError.Context(
                        codingPath: [],
                        debugDescription: "Usage cost must contain finite nonnegative values."))
            }
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(input, forKey: .input)
            try values.encode(output, forKey: .output)
            try values.encode(cacheRead, forKey: .cacheRead)
            try values.encode(cacheWrite, forKey: .cacheWrite)
            try values.encode(total, forKey: .total)
        }

        private static func hasValidNumbers(_ value: Cost) -> Bool {
            [value.input, value.output, value.cacheRead, value.cacheWrite, value.total]
                .allSatisfy { $0.isFinite && $0 >= 0 }
        }
    }

    public init() {}

    /// A compatibility record that had an assistant crossing but no Aviary completeness block.
    /// Numeric fields remain untouched; callers may display them as reported, never exact.
    static var unclassifiedRecord: Usage {
        var usage = Usage()
        usage.completeness = .unclassified
        return usage
    }

    /// Project one validated provider crossing into non-overlapping, known-lower-bound values.
    /// Raw reports, rates, and issue detail deliberately do not enter transcript persistence.
    public init(finality: ProviderUsage.ReportFinality, accounted crossing: ProviderUsage.AccountedCrossing) {
        let partitionInvalid = crossing.issues.contains(.inconsistentCachePartition)
        input = crossing.ordinaryInputTokens ?? 0
        output = crossing.outputTokens ?? 0
        // A contradictory inclusive partition cannot contribute a defensible cache floor.
        // The AccountedCrossing remains the audit record; Usage retains only safe projections.
        cacheRead = partitionInvalid ? 0 : (crossing.cacheReadTokens ?? 0)
        cacheWrite = partitionInvalid ? 0 : (crossing.cacheWriteTokens ?? 0)
        reasoning = crossing.reasoningTokens

        var componentOverflow = false
        let cache = Self.saturatingAdd(cacheRead, cacheWrite)
        componentOverflow = componentOverflow || cache.overflow
        let contextLowerBound: Int
        switch crossing.inputAccounting {
        case .cacheInclusive:
            // `input` could not be normalized when a cache field is missing, but the cache
            // observations remain a disjoint known subset of that inclusive context.
            contextLowerBound = crossing.ordinaryInputTokens.map {
                let sum = Self.saturatingAdd($0, cache.value)
                componentOverflow = componentOverflow || sum.overflow
                return sum.value
            } ?? cache.value
        case .cacheExclusive:
            let sum = Self.saturatingAdd(input, cache.value)
            componentOverflow = componentOverflow || sum.overflow
            contextLowerBound = sum.value
        case .unknown:
            // Input may include or exclude cache; max is a safe floor while addition is not.
            contextLowerBound = max(crossing.inputTokens ?? 0, cache.value)
        }
        let components = Self.saturatingAdd(contextLowerBound, output)
        componentOverflow = componentOverflow || components.overflow

        let arithmeticInvalid = crossing.issues.contains(.arithmeticOverflow)
        let totalConflicted = crossing.issues.contains(.reportedTotalMismatch)
        if totalConflicted {
            totalTokens = 0
        } else if let exact = crossing.totalTokens, !arithmeticInvalid {
            totalTokens = exact
        } else {
            totalTokens = components.value
        }

        cost.input = partitionInvalid ? 0 : (crossing.price.input.amount ?? 0)
        cost.output = crossing.price.output.amount ?? 0
        cost.cacheRead = partitionInvalid ? 0 : (crossing.price.cacheRead.amount ?? 0)
        cost.cacheWrite = partitionInvalid ? 0 : (crossing.price.cacheWrite.amount ?? 0)
        let safeCost = Self.saturatingAdd(cost.input, cost.output)
        let safeCostWithRead = Self.saturatingAdd(safeCost.value, cost.cacheRead)
        let safeCostTotal = Self.saturatingAdd(safeCostWithRead.value, cost.cacheWrite)
        cost.total = safeCostTotal.value
        let costProjectionOverflow = safeCost.overflow || safeCostWithRead.overflow
            || safeCostTotal.overflow

        let hasKnownToken = [crossing.inputTokens, crossing.outputTokens,
                             crossing.cacheReadTokens, crossing.cacheWriteTokens]
            .contains { $0 != nil }
        let totalState: Completeness
        if totalConflicted {
            totalState = .unclassified
        } else if crossing.totalTokens != nil, !arithmeticInvalid {
            totalState = .complete
        } else if hasKnownToken {
            totalState = .lowerBound
        } else {
            totalState = .unavailable
        }
        let breakdownComplete = crossing.ordinaryInputTokens != nil
            && crossing.outputTokens != nil && crossing.cacheReadTokens != nil
            && crossing.cacheWriteTokens != nil && !arithmeticInvalid && !partitionInvalid
            && !componentOverflow
        let breakdownState: Completeness = breakdownComplete
            ? .complete : (hasKnownToken ? .lowerBound : .unavailable)
        var costState: Completeness
        switch crossing.price.completeness {
        case .complete: costState = arithmeticInvalid || partitionInvalid ? .lowerBound : .complete
        case .partial: costState = .lowerBound
        case .unavailable: costState = .unavailable
        }
        if costProjectionOverflow { costState = .lowerBound }
        let accounting: InputAccountingSummary
        switch crossing.inputAccounting {
        case .cacheInclusive: accounting = .cacheInclusive
        case .cacheExclusive: accounting = .cacheExclusive
        case .unknown: accounting = .unknown
        }
        completeness = CompletenessMetadata(
            tokenTotal: totalState, breakdown: breakdownState, cost: costState,
            inputAccounting: accounting)
        if finality == .unconfirmed {
            if completeness.tokenTotal == .complete { completeness.tokenTotal = .lowerBound }
            if completeness.breakdown == .complete { completeness.breakdown = .lowerBound }
            if completeness.cost == .complete { completeness.cost = .lowerBound }
        }
    }

    public init(json: JSONValue?) {
        guard let json else { return }
        let inputField = Self.importedCount(json["input"])
        let outputField = Self.importedCount(json["output"])
        let cacheReadField = Self.importedCount(json["cacheRead"])
        let cacheWriteField = Self.importedCount(json["cacheWrite"])
        input = inputField.value
        output = outputField.value
        cacheRead = cacheReadField.value
        cacheWrite = cacheWriteField.value
        let importedReasoning = Self.importedOptionalCount(json["reasoning"])
        let reasoningField: (value: Int?, valid: Bool)
        if let value = importedReasoning.value, value > output {
            reasoningField = (nil, false)
        } else {
            reasoningField = importedReasoning
        }
        reasoning = reasoningField.value
        let first = Self.saturatingAdd(input, output)
        let second = Self.saturatingAdd(cacheRead, cacheWrite)
        let fallbackTotal = Self.saturatingAdd(first.value, second.value)
        let totalField = Self.importedCount(json["totalTokens"])
        totalTokens = totalField.present ? totalField.value : fallbackTotal.value
        let costFields = Self.importedCost(json["cost"])
        cost = costFields.cost
        let fieldsValid = [inputField, outputField, cacheReadField, cacheWriteField]
            .allSatisfy { $0.valid } && reasoningField.valid
            && totalField.present && totalField.valid && !fallbackTotal.overflow
            && costFields.valid
        let decoded = Self.decodeCompleteness(json["completeness"])
        if fieldsValid, let decoded,
           Self.hasValidInvariants(
               input: input, output: output, cacheRead: cacheRead,
               cacheWrite: cacheWrite, reasoning: reasoning,
               totalTokens: totalTokens, cost: cost, completeness: decoded) {
            completeness = decoded
        } else {
            completeness = .unclassified
        }
    }

    public static func + (a: Usage, b: Usage) -> Usage {
        var u = Usage()
        var overflow = false
        let input = saturatingAdd(a.input, b.input); u.input = input.value; overflow = overflow || input.overflow
        let output = saturatingAdd(a.output, b.output); u.output = output.value; overflow = overflow || output.overflow
        let cacheRead = saturatingAdd(a.cacheRead, b.cacheRead)
        u.cacheRead = cacheRead.value; overflow = overflow || cacheRead.overflow
        let cacheWrite = saturatingAdd(a.cacheWrite, b.cacheWrite)
        u.cacheWrite = cacheWrite.value; overflow = overflow || cacheWrite.overflow
        // nil + nil stays nil; a known value plus an unknown one is still the known part.
        if a.reasoning != nil || b.reasoning != nil {
            let reasoning = saturatingAdd(a.reasoning ?? 0, b.reasoning ?? 0)
            u.reasoning = reasoning.value; overflow = overflow || reasoning.overflow
        }
        let total = saturatingAdd(a.totalTokens, b.totalTokens)
        u.totalTokens = total.value; overflow = overflow || total.overflow
        let costInput = saturatingAdd(a.cost.input, b.cost.input)
        let costOutput = saturatingAdd(a.cost.output, b.cost.output)
        let costRead = saturatingAdd(a.cost.cacheRead, b.cost.cacheRead)
        let costWrite = saturatingAdd(a.cost.cacheWrite, b.cost.cacheWrite)
        let costTotal = saturatingAdd(a.cost.total, b.cost.total)
        u.cost.input = costInput.value; u.cost.output = costOutput.value
        u.cost.cacheRead = costRead.value; u.cost.cacheWrite = costWrite.value
        u.cost.total = costTotal.value
        let costOverflow = [costInput, costOutput, costRead, costWrite, costTotal]
            .contains { $0.overflow }
        u.completeness = CompletenessMetadata(
            tokenTotal: merge(a.completeness.tokenTotal, b.completeness.tokenTotal),
            breakdown: merge(a.completeness.breakdown, b.completeness.breakdown),
            cost: merge(a.completeness.cost, b.completeness.cost),
            inputAccounting: merge(a.completeness.inputAccounting, b.completeness.inputAccounting))
        if overflow {
            u.completeness.tokenTotal = downgrade(u.completeness.tokenTotal)
            u.completeness.breakdown = downgrade(u.completeness.breakdown)
        }
        if costOverflow { u.completeness.cost = downgrade(u.completeness.cost) }
        return u
    }

    public static func += (a: inout Usage, b: Usage) { a = a + b }

    public var isEmpty: Bool {
        guard totalTokens == 0, cost.total == 0 else { return false }
        let visuallySettled: Set<Completeness> = [.neutral, .complete]
        return visuallySettled.contains(completeness.tokenTotal)
            && visuallySettled.contains(completeness.cost)
    }
    public var isTokenTotalComplete: Bool { completeness.tokenTotal == .complete }
    public var isCostComplete: Bool { completeness.cost == .complete }
    public var isBreakdownComplete: Bool { completeness.breakdown == .complete }

    /// Fraction of input tokens served from cache — the single most useful efficiency
    /// number in a long agent session, and one the harness never displays.
    public var cacheHitRate: Double? {
        guard isBreakdownComplete else { return nil }
        let first = Self.saturatingAdd(input, cacheRead)
        let total = Self.saturatingAdd(first.value, cacheWrite)
        guard !first.overflow, !total.overflow else { return nil }
        let considered = total.value
        guard considered > 0 else { return nil }
        return Double(cacheRead) / Double(considered)
    }

    private enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, reasoning, totalTokens, cost, completeness
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = try values.decode(Int.self, forKey: .input)
        output = try values.decode(Int.self, forKey: .output)
        cacheRead = try values.decode(Int.self, forKey: .cacheRead)
        cacheWrite = try values.decode(Int.self, forKey: .cacheWrite)
        reasoning = try values.decodeIfPresent(Int.self, forKey: .reasoning)
        totalTokens = try values.decode(Int.self, forKey: .totalTokens)
        cost = try values.decode(Cost.self, forKey: .cost)
        completeness = try values.decode(CompletenessMetadata.self, forKey: .completeness)
        guard Self.hasValidInvariants(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
            reasoning: reasoning, totalTokens: totalTokens, cost: cost,
            completeness: completeness)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .completeness, in: values,
                debugDescription: "Usage violates its numeric or completeness invariants.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validateForPersistence()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(input, forKey: .input)
        try values.encode(output, forKey: .output)
        try values.encode(cacheRead, forKey: .cacheRead)
        try values.encode(cacheWrite, forKey: .cacheWrite)
        try values.encodeIfPresent(reasoning, forKey: .reasoning)
        try values.encode(totalTokens, forKey: .totalTokens)
        try values.encode(cost, forKey: .cost)
        try values.encode(completeness, forKey: .completeness)
    }

    var completenessJSON: JSONValue {
        .object([
            "tokenTotal": .string(completeness.tokenTotal.rawValue),
            "breakdown": .string(completeness.breakdown.rawValue),
            "cost": .string(completeness.cost.rawValue),
            "inputAccounting": .string(completeness.inputAccounting.rawValue),
        ])
    }

    func validateForPersistence() throws {
        guard Self.hasValidInvariants(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
            reasoning: reasoning, totalTokens: totalTokens, cost: cost,
            completeness: completeness)
        else {
            throw EncodingError.invalidValue(
                self, EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Usage violates its numeric or completeness invariants."))
        }
    }

    func validateForTranscript() throws {
        try validateForPersistence()
        guard completeness != .neutral else {
            throw EncodingError.invalidValue(
                self, EncodingError.Context(
                    codingPath: [],
                    debugDescription: "A transcript usage entry cannot be the neutral accumulator."))
        }
    }

    static func transcriptInteger(_ value: Int) -> JSONValue {
        // JSONValue stores numbers as Double. Decimal strings retain exact Int identity outside
        // the IEEE-754 integer range and are accepted only by Usage's strict integer reader.
        value >= -9_007_199_254_740_991 && value <= 9_007_199_254_740_991
            ? .number(Double(value)) : .string(String(value))
    }

    private static func decodeCompleteness(_ json: JSONValue?) -> CompletenessMetadata? {
        guard let json,
              let tokenValue = json["tokenTotal"]?.stringValue,
              let breakdownValue = json["breakdown"]?.stringValue,
              let costValue = json["cost"]?.stringValue,
              let accountingValue = json["inputAccounting"]?.stringValue,
              let token = Completeness(rawValue: tokenValue),
              let breakdown = Completeness(rawValue: breakdownValue),
              let cost = Completeness(rawValue: costValue),
              let accounting = InputAccountingSummary(rawValue: accountingValue),
              token != .neutral, breakdown != .neutral, cost != .neutral,
              accounting != .neutral
        else { return nil }
        return CompletenessMetadata(
            tokenTotal: token, breakdown: breakdown, cost: cost,
            inputAccounting: accounting)
    }

    private static func importedCount(
        _ json: JSONValue?
    ) -> (value: Int, present: Bool, valid: Bool) {
        guard let json else { return (0, false, false) }
        let value: Int?
        let exact: Bool
        switch json {
        case .number(let number):
            value = json.intValue
            exact = number.isFinite && number >= 0
                && number <= 9_007_199_254_740_991
        case .string(let string):
            value = Int(string)
            exact = value.map(String.init) == string
        default:
            value = nil
            exact = false
        }
        guard let value, value >= 0 else { return (0, true, false) }
        return (value, true, exact)
    }

    private static func importedOptionalCount(
        _ json: JSONValue?
    ) -> (value: Int?, valid: Bool) {
        guard let json, !json.isNull else { return (nil, true) }
        let field = importedCount(json)
        return field.valid ? (field.value, true) : (nil, false)
    }

    private static func importedCost(
        _ json: JSONValue?
    ) -> (cost: Cost, valid: Bool) {
        guard let json, !json.isNull else { return (Cost(), false) }
        guard json.objectValue != nil else { return (Cost(), false) }
        func field(_ key: String) -> (Double, Bool) {
            switch json[key] {
            case .number(let value) where value.isFinite && value >= 0:
                return (value, true)
            case .string(let string):
                guard let value = Double(string), value.isFinite, value >= 0 else {
                    return (0, false)
                }
                // Preserve an old numeric string for display, but it cannot authenticate
                // current completeness metadata. Owned writers emit JSON numbers for cost.
                return (value, false)
            default:
                return (0, false)
            }
        }
        let input = field("input"), output = field("output")
        let read = field("cacheRead"), write = field("cacheWrite"), total = field("total")
        var cost = Cost()
        cost.input = input.0; cost.output = output.0
        cost.cacheRead = read.0; cost.cacheWrite = write.0; cost.total = total.0
        return (cost, [input.1, output.1, read.1, write.1, total.1].allSatisfy { $0 })
    }

    private static func hasValidInvariants(
        input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int?,
        totalTokens: Int, cost: Cost, completeness: CompletenessMetadata
    ) -> Bool {
        guard [input, output, cacheRead, cacheWrite, totalTokens].allSatisfy({ $0 >= 0 }),
              reasoning.map({ $0 >= 0 && $0 <= output }) ?? true,
              [cost.input, cost.output, cost.cacheRead, cost.cacheWrite, cost.total]
                .allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return false }

        let states = [completeness.tokenTotal, completeness.breakdown, completeness.cost]
        if states.allSatisfy({ $0 == .neutral }) {
            return completeness.inputAccounting == .neutral
                && input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0
                && reasoning == nil && totalTokens == 0
                && cost.input == 0 && cost.output == 0 && cost.cacheRead == 0
                && cost.cacheWrite == 0 && cost.total == 0
        }
        guard states.allSatisfy({ $0 != .neutral }),
              completeness.inputAccounting != .neutral else { return false }
        if completeness.tokenTotal == .unavailable, totalTokens != 0 { return false }
        if completeness.breakdown == .unavailable,
           input != 0 || output != 0 || cacheRead != 0 || cacheWrite != 0 { return false }
        if completeness.cost == .unavailable,
           cost.input != 0 || cost.output != 0 || cost.cacheRead != 0
               || cost.cacheWrite != 0 || cost.total != 0 { return false }
        if completeness.cost == .complete || completeness.cost == .lowerBound {
            let costInputOutput = saturatingAdd(cost.input, cost.output)
            let costWithRead = saturatingAdd(costInputOutput.value, cost.cacheRead)
            let costSum = saturatingAdd(costWithRead.value, cost.cacheWrite)
            let overflow = costInputOutput.overflow || costWithRead.overflow || costSum.overflow
            if overflow {
                guard completeness.cost == .lowerBound,
                      cost.total == Double.greatestFiniteMagnitude else { return false }
            } else {
                if cost.total == 0 || costSum.value == 0 {
                    guard cost.total == costSum.value else { return false }
                } else {
                    let scale = max(cost.total, costSum.value)
                    guard abs(cost.total - costSum.value) <= scale * 1e-12 else { return false }
                }
            }
        }
        if completeness.tokenTotal == .complete {
            let first = saturatingAdd(input, output)
            let second = saturatingAdd(cacheRead, cacheWrite)
            let sum = saturatingAdd(first.value, second.value)
            guard !first.overflow, !second.overflow, !sum.overflow,
                  totalTokens >= sum.value else { return false }
        }
        if completeness.breakdown == .complete {
            guard completeness.inputAccounting != .unknown else { return false }
            let first = saturatingAdd(input, output)
            let second = saturatingAdd(cacheRead, cacheWrite)
            let sum = saturatingAdd(first.value, second.value)
            guard !first.overflow, !second.overflow, !sum.overflow else { return false }
            if completeness.tokenTotal == .complete, sum.value != totalTokens { return false }
        }
        return true
    }

    private static func merge(_ a: Completeness, _ b: Completeness) -> Completeness {
        if a == .neutral { return b }
        if b == .neutral { return a }
        if a == .unclassified || b == .unclassified { return .unclassified }
        if a == .complete && b == .complete { return .complete }
        if a == .unavailable && b == .unavailable { return .unavailable }
        return .lowerBound
    }

    private static func merge(
        _ a: InputAccountingSummary, _ b: InputAccountingSummary
    ) -> InputAccountingSummary {
        if a == .neutral { return b }
        if b == .neutral { return a }
        return a == b ? a : .mixed
    }

    private static func downgrade(_ value: Completeness) -> Completeness {
        switch value {
        case .neutral, .unavailable: return .unavailable
        case .complete, .lowerBound: return .lowerBound
        case .unclassified: return .unclassified
        }
    }

    private static func saturatingAdd(_ a: Int, _ b: Int) -> (value: Int, overflow: Bool) {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return (value, false) }
        return (b >= 0 ? Int.max : Int.min, true)
    }

    private static func saturatingAdd(
        _ a: Double, _ b: Double
    ) -> (value: Double, overflow: Bool) {
        guard a.isFinite, b.isFinite else {
            return (a.sign == .minus || b.sign == .minus
                    ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude, true)
        }
        let value = a + b
        guard value.isFinite else {
            return (value.sign == .minus
                    ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude, true)
        }
        return (value, false)
    }
}

// MARK: - Content blocks

public enum ContentBlock: Sendable, Hashable, Identifiable {
    case text(String)
    case thinking(String)
    case toolCall(ToolCall)
    case image(mimeType: String, base64: String)

    public var id: String {
        switch self {
        case .text(let s): return "t:\(s.hashValue)"
        case .thinking(let s): return "k:\(s.hashValue)"
        case .toolCall(let c): return "c:\(c.id)"
        case .image(let m, let d): return "i:\(m):\(d.prefix(24))"
        }
    }

    public static func parse(_ blocks: JSONValue?) -> [ContentBlock] {
        // A bare string is a valid `content` for user messages.
        if let s = blocks?.stringValue { return s.isEmpty ? [] : [.text(s)] }
        guard let arr = blocks?.arrayValue else { return [] }
        return arr.compactMap { b in
            switch b["type"]?.stringValue {
            case "text":
                let t = b["text"]?.stringValue ?? ""
                return t.isEmpty ? nil : .text(t)
            case "thinking":
                let t = b["thinking"]?.stringValue ?? ""
                return t.isEmpty ? nil : .thinking(t)
            case "toolCall":
                return .toolCall(ToolCall(
                    id: b["id"]?.stringValue ?? UUID().uuidString,
                    name: b["name"]?.stringValue ?? "tool",
                    arguments: b["arguments"] ?? .object([:])))
            case "image":
                return .image(
                    mimeType: b["mimeType"]?.stringValue ?? "image/png",
                    base64: b["data"]?.stringValue ?? "")
            default:
                // Unknown block type: keep any text-ish payload rather than dropping it.
                if let t = b["text"]?.stringValue, !t.isEmpty { return .text(t) }
                return nil
            }
        }
    }
}

public struct ToolCall: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Aviary's current tool is `python`; older transcripts called the same thing `ipython`.
    /// Treat both as a Python cell so live and historical runs keep first-class rendering.
    public var pythonCode: String? {
        guard name == "python" || name == "ipython" else { return nil }
        return arguments["code"]?.stringValue
            ?? arguments["cell"]?.stringValue
            ?? arguments["source"]?.stringValue
    }

    /// A one-line label for collapsed rows.
    public var summary: String {
        if let code = pythonCode {
            let firstMeaningful = code
                .split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            return (firstMeaningful?.trimmingCharacters(in: .whitespaces)) ?? "python"
        }
        if let obj = arguments.objectValue {
            for key in ["command", "path", "query", "prompt", "task", "file_path"] {
                if let v = obj[key]?.stringValue { return v }
            }
        }
        return name
    }
}

// MARK: - Transcript items

/// A renderable transcript row. Deliberately not a 1:1 mapping of session entries: a
/// tool call and its result are two entries but one thing a person wants to look at,
/// and 1,800 `agent_status` entries are one thing (the latest status), not 1,800 rows.
/// One image carried on a tool result.
///
/// A named struct rather than the tuple this used to be, so `TranscriptItem` can synthesise
/// `Equatable`. That matters well beyond tidiness: without it the Live mirror had no way to
/// ask "did anything actually change?" and re-published the whole transcript four times a
/// second, which re-rendered every run's view — and tore down any menu that happened to be
/// open at the time.
public struct ToolResultImage: Sendable, Hashable {
    public var mimeType: String
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }
}

public struct TranscriptItem: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable {
        case user
        case assistant
        case tool
        case bash
        case custom
        case agentMessage
        case compaction
        case branchSummary
        case stateChange
        case note
    }

    public let id: String
    public let kind: Kind
    public let timestamp: Date
    public var blocks: [ContentBlock] = []
    /// Assistant metadata.
    public var model: String?
    public var provider: String?
    public var usage: Usage?
    public var stopReason: String?
    public var errorMessage: String?
    /// Tool pairing.
    public var toolCall: ToolCall?
    public var toolResultText: String?
    public var toolResultImages: [ToolResultImage] = []
    public var toolIsError: Bool = false
    public var toolDetails: JSONValue?
    public var toolDuration: TimeInterval?
    /// Bash execution.
    public var command: String?
    public var exitCode: Int?
    /// Custom / agent-message metadata.
    public var customType: String?
    public var senderName: String?
    /// Plain text for one-line rows (state changes, notes).
    public var text: String = ""
    /// Exact Work-command delivery evidence for a canonical user message. Nil means this
    /// transcript source does not participate in the Work/Session delivery join; it must not be
    /// interpreted as either delivered or pending.
    public var inputDelivery: CanonicalInputDeliveryRow?
    /// The raw entry, for the inspector.
    public var raw: JSONValue?

    public init(id: String, kind: Kind, timestamp: Date) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }

    public var plainText: String {
        let fromBlocks = blocks.compactMap { b -> String? in
            switch b {
            case .text(let s): return s
            case .thinking(let s): return s
            default: return nil
            }
        }.joined(separator: "\n")
        if !fromBlocks.isEmpty { return fromBlocks }
        if !text.isEmpty { return text }
        return toolResultText ?? ""
    }
}

// MARK: - Session header & agent status

public struct SessionHeader: Sendable, Hashable {
    public var id: String
    public var version: Int
    public var timestamp: Date
    public var cwd: String
    public var parentSession: String?
    public var rlmDepth: Int
    public var gitCommit: String?
    public var gitBranch: String?

    public init(json: JSONValue, fallbackID: String) {
        id = json["id"]?.stringValue ?? fallbackID
        version = json["version"]?.intValue ?? 1
        timestamp = ISO8601.date(json["timestamp"]?.stringValue) ?? Date.distantPast
        cwd = json["cwd"]?.stringValue ?? ""
        parentSession = json["parentSession"]?.stringValue
        rlmDepth = json["rlmDepth"]?.intValue ?? 0
        gitCommit = json.path("git.commit")?.stringValue
        gitBranch = json.path("git.branch")?.stringValue
    }

    public var projectName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

public struct AgentStatus: Sendable, Hashable {
    public var summary: String
    public var taskState: String?
    public var basedOnMessageCount: Int?
    public var timestamp: Date

    /// `needs_input`, `working`, `done`… mapped to something a UI can colour.
    public var isAwaitingUser: Bool { taskState == "needs_input" }
    public var isDone: Bool { taskState == "done" || taskState == "completed" }
}

/// The last durable terminal outcome for a session's active branch. This is deliberately
/// separate from transcript rows: a failed or cancelled turn may have no assistant row to
/// reconcile, while a synthetic note would make cold reload look like a model message.
public struct TranscriptOutcome: Sendable, Hashable, Equatable {
    public enum State: String, Sendable, Hashable, Codable {
        case failed
        case cancelled
    }

    public let id: String
    public let state: State
    public let detail: String?
    public let timestamp: Date

    public init(id: String, state: State, detail: String? = nil, timestamp: Date) {
        self.id = id
        self.state = state
        self.detail = detail
        self.timestamp = timestamp
    }
}

// MARK: - Transcript

public struct Transcript: Sendable {
    public var header: SessionHeader
    public var items: [TranscriptItem]
    public var sessionName: String?
    public var status: AgentStatus?
    public var sessionState: String?
    /// The most recent durable failure/cancellation marker on the active branch, if any.
    public var outcome: TranscriptOutcome?
    public var usage: Usage
    /// Usage contributed by RLM children and folded into parent messages.
    public var childUsage: Usage
    public var modelChanges: [(date: Date, provider: String, model: String)]
    public var lastModel: String?
    public var lastProvider: String?
    public var counts: Counts
    public var labels: [String: String]
    /// Entries we could not parse. Surfaced rather than hidden, because a nonzero count
    /// here means Aviary is behind a harness format change.
    public var unparsedLines: Int

    public struct Counts: Sendable, Hashable {
        public var user = 0
        public var assistant = 0
        public var toolCalls = 0
        public var toolErrors = 0
        public var bash = 0
        public var compactions = 0
        public var agentMessages = 0
        public var entries = 0
    }

    public var duration: TimeInterval? {
        guard let first = items.first?.timestamp, let last = items.last?.timestamp,
              last > first else { return nil }
        return last.timeIntervalSince(first)
    }
}

// MARK: - Parser

public enum SessionParser {
    /// Parse a session JSONL file into a renderable transcript.
    ///
    /// Sessions are trees (`id`/`parentId`) that branch in place, so the file is not a
    /// conversation — it is every conversation the session has ever had. The active path
    /// is the chain from the last written entry back to the root; anything hanging off an
    /// abandoned branch is deliberately not rendered.
    public static func parse(fileURL: URL) -> Transcript? {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        return parse(data: data, fallbackID: fileURL.deletingPathExtension().lastPathComponent)
    }

    public static func parse(data: Data, fallbackID: String) -> Transcript? {
        var header: SessionHeader?
        var entries: [(id: String, parentID: String?, value: JSONValue)] = []
        var byID: [String: Int] = [:]
        var unparsed = 0

        // Split on LF only. The harness's own RPC docs call this out: generic line
        // readers that also break on U+2028/U+2029 corrupt records, because those are
        // legal inside JSON strings.
        for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var slice = Data(chunk)
            if slice.last == UInt8(ascii: "\r") { slice.removeLast() }
            guard !slice.isEmpty else { continue }
            guard let v = JSONValue.parse(slice) else { unparsed += 1; continue }
            if v["type"]?.stringValue == "session", header == nil {
                header = SessionHeader(json: v, fallbackID: fallbackID)
                continue
            }
            guard let id = v["id"]?.stringValue else { unparsed += 1; continue }
            byID[id] = entries.count
            entries.append((id: id, parentID: v["parentId"]?.stringValue, value: v))
        }

        guard let header else { return nil }

        // Walk the active branch: last entry → root, then reverse.
        var activeIndices: [Int] = []
        if let lastID = entries.last?.id {
            var cursor: String? = lastID
            var guardCount = 0
            var seen = Set<String>()
            while let cur = cursor, let idx = byID[cur], guardCount < entries.count + 8 {
                if seen.contains(cur) { break }  // malformed cycle; stop rather than hang
                seen.insert(cur)
                activeIndices.append(idx)
                cursor = entries[idx].parentID
                guardCount += 1
            }
            activeIndices.reverse()
        }

        var t = Transcript(
            header: header, items: [], sessionName: nil, status: nil, sessionState: nil,
            outcome: nil,
            usage: Usage(), childUsage: Usage(), modelChanges: [], lastModel: nil,
            lastProvider: nil, counts: Transcript.Counts(), labels: [:], unparsedLines: unparsed)
        t.counts.entries = entries.count

        // Tool results are matched to their call so the UI can show code and output as
        // one unit. Results always follow their call on the active path.
        var pendingCalls: [String: Int] = [:]  // toolCallId -> index in t.items
        var callTimestamps: [String: Date] = [:]

        for idx in activeIndices {
            let e = entries[idx]
            let v = e.value
            let type = v["type"]?.stringValue ?? ""
            let ts = ISO8601.date(v["timestamp"]?.stringValue) ?? header.timestamp

            switch type {
            case "message", "custom_message":
                let msg = type == "custom_message" ? v : (v["message"] ?? .null)
                let role = type == "custom_message" ? "custom" : (msg["role"]?.stringValue ?? "")
                switch role {
                case "user":
                    // A later prompt starts a new attempt; the previous terminal outcome no
                    // longer describes the active branch's work.
                    t.outcome = nil
                    var item = TranscriptItem(id: e.id, kind: .user, timestamp: ts)
                    item.blocks = ContentBlock.parse(msg["content"])
                    item.raw = v
                    t.items.append(item)
                    t.counts.user += 1

                case "assistant":
                    var item = TranscriptItem(id: e.id, kind: .assistant, timestamp: ts)
                    item.blocks = ContentBlock.parse(msg["content"])
                    item.model = msg["model"]?.stringValue
                    item.provider = msg["provider"]?.stringValue
                    let u = msg["usage"].map { Usage(json: $0) } ?? .unclassifiedRecord
                    item.usage = u
                    item.stopReason = msg["stopReason"]?.stringValue
                    item.errorMessage = msg["errorMessage"]?.stringValue
                    item.raw = v
                    t.usage += u
                    t.lastModel = item.model ?? t.lastModel
                    t.lastProvider = item.provider ?? t.lastProvider
                    t.counts.assistant += 1
                    t.items.append(item)

                    // Emit a tool row per call so results have somewhere to land.
                    for block in item.blocks {
                        if case .toolCall(let call) = block {
                            var tool = TranscriptItem(id: "tool:\(call.id)", kind: .tool, timestamp: ts)
                            tool.toolCall = call
                            pendingCalls[call.id] = t.items.count
                            callTimestamps[call.id] = ts
                            t.items.append(tool)
                            t.counts.toolCalls += 1
                        }
                    }

                case "toolResult":
                    let callID = msg["toolCallId"]?.stringValue ?? ""
                    let blocks = ContentBlock.parse(msg["content"])
                    let textOut = blocks.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
                        .joined(separator: "\n")
                    let images = blocks.compactMap { b -> (String, String)? in
                        if case .image(let m, let d) = b { return (m, d) } else { return nil }
                    }
                    let isError = msg["isError"]?.boolValue ?? false
                    if isError { t.counts.toolErrors += 1 }

                    if let slot = pendingCalls[callID], t.items.indices.contains(slot) {
                        t.items[slot].toolResultText = Ansi.strip(textOut)
                        t.items[slot].toolResultImages = images.map { ToolResultImage(mimeType: $0.0, base64: $0.1) }
                        t.items[slot].toolIsError = isError
                        t.items[slot].toolDetails = msg["details"]
                        if let started = callTimestamps[callID] {
                            t.items[slot].toolDuration = ts.timeIntervalSince(started)
                        }
                        pendingCalls.removeValue(forKey: callID)
                    } else {
                        // Orphaned result (call lived on a pruned branch). Still show it.
                        var item = TranscriptItem(id: e.id, kind: .tool, timestamp: ts)
                        item.toolCall = ToolCall(
                            id: callID, name: msg["toolName"]?.stringValue ?? "tool",
                            arguments: .object([:]))
                        item.toolResultText = Ansi.strip(textOut)
                        item.toolIsError = isError
                        item.raw = v
                        t.items.append(item)
                    }

                case "bashExecution":
                    var item = TranscriptItem(id: e.id, kind: .bash, timestamp: ts)
                    item.command = msg["command"]?.stringValue
                    item.text = Ansi.strip(msg["output"]?.stringValue ?? "")
                    item.exitCode = msg["exitCode"]?.intValue
                    item.raw = v
                    t.items.append(item)
                    t.counts.bash += 1

                case "custom":
                    let ctype = (type == "custom_message"
                        ? v["customType"]?.stringValue
                        : msg["customType"]?.stringValue) ?? "extension"
                    let content = (type == "custom_message" ? v["content"] : msg["content"])
                    // Controller intents are durable audit records, not conversation turns. They
                    // remain available in the raw JSONL for recovery and diagnostics but must not
                    // create empty custom rows in the human-facing transcript.
                    if ctype == "aviary.command-intent.v1" { continue }
                    if ctype == "aviary.outcome" {
                        let state = v["outcomeState"]?.stringValue
                            ?? msg["outcomeState"]?.stringValue
                        if let state, let outcomeState = TranscriptOutcome.State(rawValue: state) {
                            let detail = v["detail"]?.stringValue
                                ?? msg["detail"]?.stringValue
                                ?? content?.textContent
                            t.outcome = TranscriptOutcome(
                                id: e.id, state: outcomeState, detail: detail, timestamp: ts)
                        }
                        continue
                    }
                    let isAgentMessage = ctype == "agent_message"
                    var item = TranscriptItem(
                        id: e.id, kind: isAgentMessage ? .agentMessage : .custom, timestamp: ts)
                    item.customType = ctype
                    item.blocks = ContentBlock.parse(content)
                    item.text = content?.textContent ?? ""
                    item.senderName = AgentMessageHeader.senderName(from: item.text)
                    item.raw = v
                    if isAgentMessage { t.counts.agentMessages += 1 }
                    t.items.append(item)

                case "compactionSummary":
                    var item = TranscriptItem(id: e.id, kind: .compaction, timestamp: ts)
                    item.text = msg["summary"]?.stringValue ?? ""
                    item.raw = v
                    t.items.append(item)
                    t.counts.compactions += 1

                case "branchSummary":
                    var item = TranscriptItem(id: e.id, kind: .branchSummary, timestamp: ts)
                    item.text = msg["summary"]?.stringValue ?? ""
                    item.raw = v
                    t.items.append(item)

                default:
                    break
                }

            case "compaction":
                var item = TranscriptItem(id: e.id, kind: .compaction, timestamp: ts)
                item.text = v["summary"]?.stringValue ?? ""
                item.usage = {
                    var fields: [String: JSONValue] = [
                        "input": .number(0), "output": .number(0),
                        "cacheRead": .number(0), "cacheWrite": .number(0),
                    ]
                    if let tokens = v["tokensBefore"] { fields["totalTokens"] = tokens }
                    // This is retained context size, not a provider billing crossing.
                    // The tolerant importer sanitizes malformed historical counts and leaves it
                    // explicitly unclassified rather than manufacturing accounting evidence.
                    return Usage(json: .object(fields))
                }()
                item.raw = v
                t.items.append(item)
                t.counts.compactions += 1

            case "branch_summary":
                var item = TranscriptItem(id: e.id, kind: .branchSummary, timestamp: ts)
                item.text = v["summary"]?.stringValue ?? ""
                item.raw = v
                t.items.append(item)

            case "model_change":
                let provider = v["provider"]?.stringValue ?? ""
                // `model` is accepted too: Aviary wrote that key for a while, and sessions
                // already on disk should render rather than showing an empty switch.
                let model = v["modelId"]?.stringValue ?? v["model"]?.stringValue ?? ""
                t.modelChanges.append((date: ts, provider: provider, model: model))
                t.lastModel = model
                t.lastProvider = provider
                var item = TranscriptItem(id: e.id, kind: .stateChange, timestamp: ts)
                item.text = "Model → \(provider)/\(model)"
                item.raw = v
                t.items.append(item)

            case "run_start":
                // A resumed run is a new attempt. Keep the session/work identity in the
                // durable marker, but do not carry a prior attempt's failure into it.
                t.outcome = nil

            case "thinking_level_change":
                var item = TranscriptItem(id: e.id, kind: .stateChange, timestamp: ts)
                item.text = "Thinking → \(v["thinkingLevel"]?.stringValue ?? "?")"
                item.raw = v
                t.items.append(item)

            case "service_tier_change":
                var item = TranscriptItem(id: e.id, kind: .stateChange, timestamp: ts)
                item.text = "Service tier → \(v["serviceTier"]?.stringValue ?? "?")"
                item.raw = v
                t.items.append(item)

            case "session_info":
                t.sessionName = v["name"]?.stringValue ?? t.sessionName

            case "session_state":
                t.sessionState = v.path("state.status")?.stringValue ?? t.sessionState

            case "agent_status":
                // Thousands of these accumulate; only the latest is meaningful.
                t.status = AgentStatus(
                    summary: v.path("status.summary")?.stringValue ?? "",
                    taskState: v.path("status.taskState")?.stringValue,
                    basedOnMessageCount: v.path("status.basedOnMessageCount")?.intValue,
                    timestamp: ts)

            case "child_usage_attributed":
                t.childUsage += v["childUsage"].map { Usage(json: $0) }
                    ?? .unclassifiedRecord

            case "label":
                if let target = v["targetId"]?.stringValue {
                    if let label = v["label"]?.stringValue {
                        t.labels[target] = label
                    } else {
                        t.labels.removeValue(forKey: target)
                    }
                }

            case "git_state", "custom":
                break  // bookkeeping; not shown inline

            default:
                break
            }
        }

        return t
    }
}

// MARK: - Helpers

public enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return withFraction.date(from: s) ?? plain.date(from: s)
    }

    public static func string(_ d: Date) -> String { withFraction.string(from: d) }
}

/// ANSI escape removal.
///
/// The agent's tool is a shell-backed IPython kernel, so tool output is full of colour
/// codes (`ls`, `git`, `pytest`). Rendering them literally is unreadable; the codes are
/// stripped once, at parse time.
public enum Ansi {
    public static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return normalizeCR(s) }
        var out = String()
        out.reserveCapacity(s.count)
        var iter = s.makeIterator()
        var pending: Character?
        while let c = pending ?? iter.next() {
            pending = nil
            guard c == "\u{1B}" else { out.append(c); continue }
            guard let next = iter.next() else { break }
            if next == "[" {
                // CSI: consume parameter/intermediate bytes up to the final byte.
                while let p = iter.next() {
                    if ("\u{40}"..."\u{7E}").contains(p) { break }
                }
            } else if next == "]" {
                // OSC: runs until BEL or ST (ESC \).
                while let p = iter.next() {
                    if p == "\u{07}" { break }
                    if p == "\u{1B}" { _ = iter.next(); break }
                }
            } else if next == "\u{1B}" {
                pending = next
            }
        }
        return normalizeCR(out)
    }

    /// Terminal output arrives with CRLF and bare CR (progress bars). Keep it as lines.
    private static func normalizeCR(_ s: String) -> String {
        guard s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Agent-to-agent messages arrive as a `custom_message` whose body starts with a
/// generated provenance header. Pull the sender out so the UI can show "from
/// models-providers" instead of a wall of routing metadata.
enum AgentMessageHeader {
    static func senderName(from text: String) -> String? {
        guard let range = text.range(of: "[from ") else { return nil }
        let after = text[range.upperBound...]
        guard let close = after.firstIndex(of: "]") else { return nil }
        let raw = String(after[..<close])
        // Shapes seen: "child:models-providers", "parent", "peer:name".
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[raw.index(after: colon)...])
        }
        return raw
    }
}

// MARK: - Injected context

/// Separates a user prompt from context that a hook or extension prepended to it.
///
/// Harnesses inject context by wrapping it in a pseudo-XML block and gluing it to the front
/// of the user's message — `<duckbill-knowledge>…</duckbill-knowledge>`,
/// `<system-reminder>…</system-reminder>`, and whatever an extension invents. The result is
/// that a session's "first message" is several kilobytes of machine-generated preamble, so
/// every session in a list ends up with the same title and the actual question is invisible.
/// Splitting them apart makes the list readable and lets the transcript show the injection
/// as something you can expand rather than something you must scroll past.
public enum PromptText {
    public struct Block: Sendable, Hashable, Identifiable {
        public var id: String { tag + String(body.prefix(24)) }
        public var tag: String
        public var body: String
    }

    public struct Split: Sendable {
        public var injected: [Block] = []
        public var userText: String = ""

        public var hasInjection: Bool { !injected.isEmpty }
    }

    /// A prefix of the person-authored portion of a prompt. Unlike `split`, this projection does
    /// not copy injected block bodies, so catalog/search refreshes stay bounded even when a hook
    /// prepended a very large payload.
    public struct BoundedUserText: Sendable, Hashable {
        public let text: String
        public let omittedCharacterCount: Int
    }

    /// Peel leading (and trailing) wrapper blocks off a prompt.
    public static func split(_ text: String) -> Split {
        var result = Split()
        var rest = Substring(text)

        func peelLeading() -> Bool {
            let trimmed = rest.drop(while: { $0.isWhitespace || $0.isNewline })
            guard trimmed.first == "<" else { return false }
            // Read the tag name.
            let afterAngle = trimmed.dropFirst()
            guard let firstChar = afterAngle.first, firstChar.isLetter else { return false }
            let name = afterAngle.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            guard !name.isEmpty else { return false }
            let afterName = afterAngle.dropFirst(name.count)
            guard afterName.first == ">" else { return false }

            let closing = "</\(name)>"
            guard let closeRange = trimmed.range(of: closing) else { return false }

            let openEnd = afterName.index(after: afterName.startIndex)
            let inner = trimmed[openEnd..<closeRange.lowerBound]
            result.injected.append(Block(
                tag: String(name),
                body: String(inner).trimmingCharacters(in: .whitespacesAndNewlines)))
            rest = trimmed[closeRange.upperBound...]
            return true
        }

        var guardCount = 0
        while peelLeading(), guardCount < 8 { guardCount += 1 }

        result.userText = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)

        // If peeling consumed everything, the wrapper *was* the message — put it back
        // rather than showing an empty prompt.
        if result.userText.isEmpty, let first = result.injected.first {
            result.userText = first.body
            result.injected.removeFirst()
        }
        return result
    }

    /// Just the part a person wrote.
    public static func userFacing(_ text: String) -> String {
        split(text).userText
    }

    public static func boundedUserFacing(
        _ text: String, maximumCharacters: Int,
        fallbackToFirstInjectedBody: Bool = true
    ) -> BoundedUserText {
        let maximum = max(0, maximumCharacters)
        var rest = Substring(text)
        var firstBody: Substring?
        var peeled = 0

        while peeled < 8 {
            let leadingTrimmed = trim(rest)
            guard leadingTrimmed.first == "<" else { break }
            let afterAngle = leadingTrimmed.dropFirst()
            guard let firstChar = afterAngle.first, firstChar.isLetter else { break }
            let name = afterAngle.prefix {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
            }
            guard !name.isEmpty else { break }
            let afterName = afterAngle.dropFirst(name.count)
            guard afterName.first == ">" else { break }
            let closing = "</\(name)>"
            guard let closeRange = leadingTrimmed.range(of: closing) else { break }
            let openEnd = afterName.index(after: afterName.startIndex)
            if firstBody == nil {
                firstBody = trim(leadingTrimmed[openEnd..<closeRange.lowerBound])
            }
            rest = leadingTrimmed[closeRange.upperBound...]
            peeled += 1
        }

        let user = trim(rest)
        let selected = user.isEmpty && fallbackToFirstInjectedBody
            ? (firstBody ?? user)
            : user
        let total = selected.count
        return BoundedUserText(
            text: String(selected.prefix(maximum)),
            omittedCharacterCount: max(0, total - maximum))
    }

    private static func trim(_ value: Substring) -> Substring {
        var lower = value.startIndex
        while lower < value.endIndex, value[lower].isWhitespace {
            lower = value.index(after: lower)
        }
        var upper = value.endIndex
        while lower < upper {
            let previous = value.index(before: upper)
            guard value[previous].isWhitespace else { break }
            upper = previous
        }
        return value[lower..<upper]
    }
}
