import Foundation

/// Provider usage is kept separate from the transcript's historical `Usage` shape.
///
/// A provider report is a wire observation, not yet an accounting result.  In particular,
/// missing counts are not zero and cache-inclusive/exclusive routes cannot be inferred from
/// the presence of cache fields.  This namespace is intentionally pure so provider adapters
/// can hand one bounded report to the same validator and pricing calculation.
public enum ProviderUsage {
    /// Report finality is independent of task success: a terminal failed response may still
    /// report final usage, while a transport EOF supplies no such evidence.
    public enum ReportFinality: String, Codable, Sendable {
        case finalReport = "final_report"
        case unconfirmed
    }

    public enum Field: String, Codable, CaseIterable, Hashable, Sendable {
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheWriteTokens
        case reasoningTokens
        case reportedTotalTokens
    }

    public enum ObservationState: String, Codable, CaseIterable, Hashable, Sendable {
        case known
        case missing
        case invalid
    }

    public enum ObservationReason: String, Codable, CaseIterable, Hashable, Sendable {
        case notReported
        case noReport
        case malformed
        case negative
        case arithmeticOverflow
        case inconsistentCachePartition
        case reasoningExceedsOutput
    }

    public enum AccountingIssue: String, Codable, Hashable, Sendable {
        case unknownAccounting
        case arithmeticOverflow
        case inconsistentCachePartition
        case reportedTotalMismatch
        case reasoningExceedsOutput
    }

    /// A report as received from a provider adapter.  Values remain raw until `account` so a
    /// negative or malformed field cannot silently turn into a zero-valued transcript count.
    public struct RawReport: Codable, Hashable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadTokens: Int?
        public var cacheWriteTokens: Int?
        public var reasoningTokens: Int?
        public var reportedTotalTokens: Int?
        /// The adapter's declared interpretation of `inputTokens`, retained with the report.
        public var inputAccounting: ProviderUsageAccounting
        public var malformedFields: Set<Field>

        public init(
            inputTokens: Int? = nil,
            outputTokens: Int? = nil,
            cacheReadTokens: Int? = nil,
            cacheWriteTokens: Int? = nil,
            reasoningTokens: Int? = nil,
            reportedTotalTokens: Int? = nil,
            inputAccounting: ProviderUsageAccounting = .unknown,
            malformedFields: Set<Field> = []
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.reportedTotalTokens = reportedTotalTokens
            self.inputAccounting = inputAccounting
            self.malformedFields = malformedFields
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
            case reasoningTokens, reportedTotalTokens, inputAccounting, malformedFields
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
            outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
            cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
            cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens)
            reasoningTokens = try c.decodeIfPresent(Int.self, forKey: .reasoningTokens)
            reportedTotalTokens = try c.decodeIfPresent(Int.self, forKey: .reportedTotalTokens)
            if let raw = try c.decodeIfPresent(String.self, forKey: .inputAccounting) {
                guard let accounting = ProviderUsageAccounting(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .inputAccounting, in: c, debugDescription: "unknown accounting mode")
                }
                inputAccounting = accounting
            } else {
                inputAccounting = .unknown
            }
            malformedFields = try c.decodeIfPresent(Set<Field>.self, forKey: .malformedFields) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(inputTokens, forKey: .inputTokens)
            try c.encodeIfPresent(outputTokens, forKey: .outputTokens)
            try c.encodeIfPresent(cacheReadTokens, forKey: .cacheReadTokens)
            try c.encodeIfPresent(cacheWriteTokens, forKey: .cacheWriteTokens)
            try c.encodeIfPresent(reasoningTokens, forKey: .reasoningTokens)
            try c.encodeIfPresent(reportedTotalTokens, forKey: .reportedTotalTokens)
            try c.encode(inputAccounting.rawValue, forKey: .inputAccounting)
            try c.encode(malformedFields, forKey: .malformedFields)
        }

        public var isEmpty: Bool {
            inputTokens == nil && outputTokens == nil && cacheReadTokens == nil
                && cacheWriteTokens == nil && reasoningTokens == nil && reportedTotalTokens == nil
                && inputAccounting.rawValue == ProviderUsageAccounting.unknown.rawValue
                && malformedFields.isEmpty
        }
    }

    public struct Observation: Hashable, Sendable {
        public let value: Int?
        public let state: ObservationState
        public let reason: ObservationReason?

        fileprivate init(value: Int?, state: ObservationState, reason: ObservationReason?) {
            self.value = value
            self.state = state
            self.reason = reason
        }

        public static var missing: Observation {
            Observation(value: nil, state: .missing, reason: .notReported)
        }
    }

    public struct Observations: Hashable, Sendable {
        public let inputTokens: Observation
        public let outputTokens: Observation
        public let cacheReadTokens: Observation
        public let cacheWriteTokens: Observation
        public let reasoningTokens: Observation
        public let reportedTotalTokens: Observation

        fileprivate init(
            inputTokens: Observation,
            outputTokens: Observation,
            cacheReadTokens: Observation,
            cacheWriteTokens: Observation,
            reasoningTokens: Observation,
            reportedTotalTokens: Observation
        ) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.reportedTotalTokens = reportedTotalTokens
        }

        public subscript(_ field: Field) -> Observation {
            switch field {
            case .inputTokens: return inputTokens
            case .outputTokens: return outputTokens
            case .cacheReadTokens: return cacheReadTokens
            case .cacheWriteTokens: return cacheWriteTokens
            case .reasoningTokens: return reasoningTokens
            case .reportedTotalTokens: return reportedTotalTokens
            }
        }
    }

    /// The configured rate identity is copied into an accounting result.  It makes a result
    /// self-describing even when the mutable model catalog changes later.
    public struct RateSnapshot: Codable, Hashable, Sendable {
        public let providerID: String
        public let modelID: String
        public let inputPerMillion: Double?
        public let outputPerMillion: Double?
        public let cacheReadPerMillion: Double?
        public let cacheWritePerMillion: Double?
        public let invalidRates: Set<PricingCategory>

        public init(model: ModelSpec) {
            providerID = Self.boundedIdentity(model.providerID)
            modelID = Self.boundedIdentity(model.id)
            var invalid: Set<PricingCategory> = []
            func normalize(_ value: Double?, _ category: PricingCategory) -> Double? {
                guard let value else { return nil }
                guard value.isFinite, value >= 0 else {
                    invalid.insert(category)
                    return nil
                }
                return value
            }
            inputPerMillion = normalize(model.costInput, .input)
            outputPerMillion = normalize(model.costOutput, .output)
            cacheReadPerMillion = normalize(model.costCacheRead, .cacheRead)
            cacheWritePerMillion = normalize(model.costCacheWrite, .cacheWrite)
            invalidRates = invalid
        }

        private static func boundedIdentity(_ value: String) -> String {
            guard value.utf8.count > 256 else { return value }
            return AviarySHA256.hash(data: Data(value.utf8)).description
        }

        private enum CodingKeys: String, CodingKey {
            case providerID, modelID, inputPerMillion, outputPerMillion
            case cacheReadPerMillion, cacheWritePerMillion, invalidRates
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            providerID = try c.decode(String.self, forKey: .providerID)
            modelID = try c.decode(String.self, forKey: .modelID)
            guard providerID.utf8.count <= 256, modelID.utf8.count <= 256 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modelID, in: c, debugDescription: "oversized rate identity")
            }
            invalidRates = try c.decodeIfPresent(Set<PricingCategory>.self, forKey: .invalidRates) ?? []
            func rate(_ key: CodingKeys) throws -> Double? {
                guard let value = try c.decodeIfPresent(Double.self, forKey: key) else { return nil }
                guard value.isFinite, value >= 0 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: c, debugDescription: "non-finite or negative rate")
                }
                return value
            }
            inputPerMillion = try rate(.inputPerMillion)
            outputPerMillion = try rate(.outputPerMillion)
            cacheReadPerMillion = try rate(.cacheReadPerMillion)
            cacheWritePerMillion = try rate(.cacheWritePerMillion)
            let rates: [(PricingCategory, Double?)] = [
                (.input, inputPerMillion), (.output, outputPerMillion),
                (.cacheRead, cacheReadPerMillion), (.cacheWrite, cacheWritePerMillion),
            ]
            guard rates.allSatisfy({ category, value in
                !invalidRates.contains(category) || value == nil
            }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .invalidRates, in: c, debugDescription: "invalid rate has a value")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(providerID, forKey: .providerID)
            try c.encode(modelID, forKey: .modelID)
            try c.encodeIfPresent(inputPerMillion, forKey: .inputPerMillion)
            try c.encodeIfPresent(outputPerMillion, forKey: .outputPerMillion)
            try c.encodeIfPresent(cacheReadPerMillion, forKey: .cacheReadPerMillion)
            try c.encodeIfPresent(cacheWritePerMillion, forKey: .cacheWritePerMillion)
            try c.encode(invalidRates, forKey: .invalidRates)
        }
    }

    public enum PricingCategory: String, Codable, Hashable, Sendable {
        case input
        case output
        case cacheRead
        case cacheWrite
    }

    public enum PricingIssue: String, Codable, Hashable, Sendable {
        case noReport
        case missingCount
        case invalidCount
        case missingRate
        case invalidRate
        case arithmeticOverflow
        case arithmeticUnderflow
    }

    public enum PricingCompleteness: String, Codable, Hashable, Sendable {
        case complete
        case partial
        case unavailable
    }

    public struct CategoryPrice: Hashable, Sendable {
        public let category: PricingCategory
        public let count: Int?
        public let ratePerMillion: Double?
        /// Nil means this category could not be priced.  A known zero count has amount zero
        /// even when its rate is not configured.
        public let amount: Double?

        fileprivate init(category: PricingCategory, count: Int?, ratePerMillion: Double?, amount: Double?) {
            self.category = category
            self.count = count
            self.ratePerMillion = ratePerMillion
            self.amount = amount
        }

    }

    public struct Price: Hashable, Sendable {
        public let input: CategoryPrice
        public let output: CategoryPrice
        public let cacheRead: CategoryPrice
        public let cacheWrite: CategoryPrice
        /// Sum of categories with known prices, even when the complete total is unavailable.
        public let knownTotal: Double
        /// True when `knownTotal` is only a finite subtotal because a later category overflowed.
        /// Consumers must never use such a subtotal as an authoritative cap or bill.
        public let knownTotalIsLowerBound: Bool
        public let total: Double?
        public let completeness: PricingCompleteness
        public let issues: Set<PricingIssue>

        fileprivate init(
            input: CategoryPrice,
            output: CategoryPrice,
            cacheRead: CategoryPrice,
            cacheWrite: CategoryPrice,
            knownTotal: Double, knownTotalIsLowerBound: Bool,
            total: Double?,
            completeness: PricingCompleteness,
            issues: Set<PricingIssue>
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.knownTotal = knownTotal
            self.knownTotalIsLowerBound = knownTotalIsLowerBound
            self.total = total
            self.completeness = completeness
            self.issues = issues
        }
    }

    public struct AccountedCrossing: Hashable, Sendable, Codable {
        public let rawReport: RawReport?
        public let rateSnapshot: RateSnapshot
        public let inputAccounting: ProviderUsageAccounting
        public let observations: Observations
        /// Input tokens not attributable to a separately reported cache category.  For a
        /// cache-inclusive report this is `input - cacheRead - cacheWrite`; for a
        /// cache-exclusive report it is the ordinary input field itself.
        public let ordinaryInputTokens: Int?
        public let contextTokens: Int?
        public let totalTokens: Int?
        public let issues: Set<AccountingIssue>
        public let price: Price

        fileprivate init(
            rawReport: RawReport?, rateSnapshot: RateSnapshot,
            inputAccounting: ProviderUsageAccounting, observations: Observations,
            ordinaryInputTokens: Int?, contextTokens: Int?, totalTokens: Int?,
            issues: Set<AccountingIssue>, price: Price
        ) {
            self.rawReport = rawReport
            self.rateSnapshot = rateSnapshot
            self.inputAccounting = inputAccounting
            self.observations = observations
            self.ordinaryInputTokens = ordinaryInputTokens
            self.contextTokens = contextTokens
            self.totalTokens = totalTokens
            self.issues = issues
            self.price = price
        }

        private enum CodingKeys: String, CodingKey { case schema, rawReport, rateSnapshot }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let schema = try c.decode(Int.self, forKey: .schema)
            guard schema == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schema, in: c, debugDescription: "unsupported provider usage schema")
            }
            let raw = try c.decodeIfPresent(RawReport.self, forKey: .rawReport)
            let snapshot = try c.decode(RateSnapshot.self, forKey: .rateSnapshot)
            self = ProviderUsage.makeAccountedCrossing(report: raw, snapshot: snapshot)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(1, forKey: .schema)
            try c.encodeIfPresent(rawReport, forKey: .rawReport)
            try c.encode(rateSnapshot, forKey: .rateSnapshot)
        }

        public var reportedTotalTokens: Int? { observations.reportedTotalTokens.value }
        public var inputTokens: Int? { observations.inputTokens.value }
        public var outputTokens: Int? { observations.outputTokens.value }
        public var cacheReadTokens: Int? { observations.cacheReadTokens.value }
        public var cacheWriteTokens: Int? { observations.cacheWriteTokens.value }
        public var reasoningTokens: Int? { observations.reasoningTokens.value }
    }

    public static func account(
        report: RawReport?, model: ModelSpec
    ) -> AccountedCrossing {
        makeAccountedCrossing(report: report, snapshot: RateSnapshot(model: model))
    }

    /// Account a report against the exact pinned rate identity captured at admission.  Unlike
    /// rebuilding a ``ModelSpec``, this preserves the snapshot's invalid-rate classifications
    /// and every rate bit pattern without consulting the mutable model catalog.
    public static func account(
        report: RawReport?, rates: RateSnapshot
    ) -> AccountedCrossing {
        makeAccountedCrossing(report: report, snapshot: rates)
    }

    private static func makeAccountedCrossing(
        report: RawReport?, snapshot: RateSnapshot
    ) -> AccountedCrossing {
        let effectiveAccounting = report?.inputAccounting ?? .unknown
        let observations = makeObservations(report)
        var issues: Set<AccountingIssue> = []
        if effectiveAccounting.rawValue == ProviderUsageAccounting.unknown.rawValue {
            issues.insert(.unknownAccounting)
        }

        var contextTokens: Int?
        var ordinaryInputTokens: Int?
        var totalTokens: Int?
        let input = observations.inputTokens.value
        let output = observations.outputTokens.value
        switch effectiveAccounting {
        case .cacheInclusive:
            // The input field is the context total in this mode. Cache categories are separate
            // pricing components; missing cache fields do not poison this exact context total.
            contextTokens = input
            if let input {
                // A known subset can already contradict the inclusive total even when the
                // other cache field is absent. Zero here is only the minimum unknown subset,
                // never a report or a price for that missing field.
                let read = observations.cacheReadTokens.value
                let write = observations.cacheWriteTokens.value
                let (afterRead, readUnderflow) = input.subtractingReportingOverflow(read ?? 0)
                let (ordinary, writeUnderflow) = afterRead.subtractingReportingOverflow(write ?? 0)
                if readUnderflow || writeUnderflow || ordinary < 0 {
                    issues.insert(.inconsistentCachePartition)
                } else if read != nil && write != nil { ordinaryInputTokens = ordinary }
            }
            if let input, let output {
                let (sum, overflow) = input.addingReportingOverflow(output)
                if overflow { issues.insert(.arithmeticOverflow) } else { totalTokens = sum }
            }
        case .cacheExclusive:
            ordinaryInputTokens = input
            if let input, let read = observations.cacheReadTokens.value,
               let write = observations.cacheWriteTokens.value {
                if let context = checkedAdd(input, read).flatMap({ checkedAdd($0, write) }) {
                    contextTokens = context
                    if let output {
                        let (sum, overflow) = context.addingReportingOverflow(output)
                        if overflow { issues.insert(.arithmeticOverflow) } else { totalTokens = sum }
                    }
                } else { issues.insert(.arithmeticOverflow) }
            }
        case .unknown:
            break
        }

        if let reported = observations.reportedTotalTokens.value, let totalTokens, reported != totalTokens {
            issues.insert(.reportedTotalMismatch)
        }
        if observations.reasoningTokens.reason == .reasoningExceedsOutput {
            issues.insert(.reasoningExceedsOutput)
        }

        let price = makePrice(
            observations: observations, ordinaryInputTokens: ordinaryInputTokens,
            inputAccounting: effectiveAccounting, snapshot: snapshot,
            inconsistentPartition: issues.contains(.inconsistentCachePartition))
        return AccountedCrossing(
            rawReport: report, rateSnapshot: snapshot,
            inputAccounting: effectiveAccounting, observations: observations,
            ordinaryInputTokens: ordinaryInputTokens, contextTokens: contextTokens,
            totalTokens: totalTokens, issues: issues, price: price)
    }

    private static func makeObservations(_ report: RawReport?) -> Observations {
        func make(_ field: Field, _ value: Int?) -> Observation {
            guard let report else {
                return Observation(value: nil, state: .missing, reason: .noReport)
            }
            if report.malformedFields.contains(field) {
                return Observation(value: nil, state: .invalid, reason: .malformed)
            }
            guard let value else {
                return Observation(value: nil, state: .missing, reason: .notReported)
            }
            guard value >= 0 else {
                return Observation(value: nil, state: .invalid, reason: .negative)
            }
            return Observation(value: value, state: .known, reason: nil)
        }

        var reasoning = make(.reasoningTokens, report?.reasoningTokens)
        if let reasoningValue = reasoning.value, let output = make(.outputTokens, report?.outputTokens).value,
           reasoningValue > output {
            reasoning = Observation(value: nil, state: .invalid, reason: .reasoningExceedsOutput)
        }
        return Observations(
            inputTokens: make(.inputTokens, report?.inputTokens),
            outputTokens: make(.outputTokens, report?.outputTokens),
            cacheReadTokens: make(.cacheReadTokens, report?.cacheReadTokens),
            cacheWriteTokens: make(.cacheWriteTokens, report?.cacheWriteTokens),
            reasoningTokens: reasoning,
            reportedTotalTokens: make(.reportedTotalTokens, report?.reportedTotalTokens))
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func makePrice(
        observations: Observations, ordinaryInputTokens: Int?,
        inputAccounting: ProviderUsageAccounting, snapshot: RateSnapshot,
        inconsistentPartition: Bool
    ) -> Price {
        var issues: Set<PricingIssue> = []
        if observations.inputTokens.reason == .noReport && observations.outputTokens.reason == .noReport {
            issues.insert(.noReport)
        }

        func category(
            _ category: PricingCategory, _ observation: Observation, _ rate: Double?
        ) -> CategoryPrice {
            let invalidRate = snapshot.invalidRates.contains(category)
            if invalidRate { issues.insert(.invalidRate) }
            guard observation.state == .known, let count = observation.value else {
                issues.insert(observation.state == .missing ? .missingCount : .invalidCount)
                if rate == nil && !invalidRate { issues.insert(.missingRate) }
                return CategoryPrice(category: category, count: nil, ratePerMillion: rate, amount: nil)
            }
            if count == 0 {
                if invalidRate {
                    return CategoryPrice(category: category, count: 0, ratePerMillion: nil, amount: nil)
                }
                return CategoryPrice(category: category, count: 0, ratePerMillion: rate, amount: 0)
            }
            if invalidRate {
                return CategoryPrice(category: category, count: count, ratePerMillion: nil, amount: nil)
            }
            guard let rate else {
                issues.insert(.missingRate)
                return CategoryPrice(category: category, count: count, ratePerMillion: nil, amount: nil)
            }
            guard rate.isFinite, rate >= 0 else {
                issues.insert(.invalidRate)
                return CategoryPrice(category: category, count: count, ratePerMillion: rate, amount: nil)
            }
            let amount = (Double(count) / 1_000_000.0) * rate
            guard amount.isFinite else {
                issues.insert(.arithmeticOverflow)
                return CategoryPrice(category: category, count: count, ratePerMillion: rate, amount: nil)
            }
            if rate > 0 && amount == 0 {
                issues.insert(.arithmeticUnderflow)
                return CategoryPrice(category: category, count: count, ratePerMillion: rate, amount: nil)
            }
            return CategoryPrice(category: category, count: count, ratePerMillion: rate, amount: amount)
        }

        let ordinaryInput: Observation
        if let ordinaryInputTokens {
            ordinaryInput = Observation(value: ordinaryInputTokens, state: .known, reason: nil)
        } else if inconsistentPartition {
            ordinaryInput = Observation(
                value: nil, state: .invalid, reason: .inconsistentCachePartition)
        } else if observations.inputTokens.state == .invalid
                    || observations.cacheReadTokens.state == .invalid
                    || observations.cacheWriteTokens.state == .invalid {
            ordinaryInput = Observation(value: nil, state: .invalid, reason: .arithmeticOverflow)
        } else {
            ordinaryInput = Observation(value: nil, state: .missing, reason: .notReported)
        }
        let input = category(.input, ordinaryInput, snapshot.inputPerMillion)
        let output = category(.output, observations.outputTokens, snapshot.outputPerMillion)
        let invalidPartition = Observation(value: nil, state: .invalid, reason: .inconsistentCachePartition)
        let cacheRead = category(.cacheRead,
            inconsistentPartition ? invalidPartition : observations.cacheReadTokens, snapshot.cacheReadPerMillion)
        let cacheWrite = category(.cacheWrite,
            inconsistentPartition ? invalidPartition : observations.cacheWriteTokens, snapshot.cacheWritePerMillion)
        let categories = [input, output, cacheRead, cacheWrite]
        var knownTotal = 0.0
        var knownTotalIsLowerBound = false
        for item in categories {
            guard let amount = item.amount else { continue }
            let next = knownTotal + amount
            if !next.isFinite {
                issues.insert(.arithmeticOverflow)
                knownTotalIsLowerBound = true
            } else {
                knownTotal = next
            }
        }

        let categoryAmountsKnown = categories.allSatisfy { $0.amount != nil }
        let completeness: PricingCompleteness
        if issues == [.noReport] || (issues.contains(.noReport) && knownTotal == 0) {
            completeness = .unavailable
        } else if issues.isEmpty && categoryAmountsKnown {
            completeness = .complete
        } else if !categoryAmountsKnown && knownTotal == 0 {
            completeness = .unavailable
        } else {
            completeness = .partial
        }
        return Price(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
            knownTotal: knownTotal, knownTotalIsLowerBound: knownTotalIsLowerBound,
            total: completeness == .complete ? knownTotal : nil,
            completeness: completeness, issues: issues)
    }
}
